const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.Crc32;
const Format = @import("format.zig");
const BloomFilter = @import("filter.zig").BloomFilter;
const lz4 = @cImport({
    @cInclude("lz4.h");
});

pub const Builder = struct {
    file: std.fs.File,
    allocator: Allocator,
    current_block: std.ArrayListUnmanaged(u8),
    index: std.ArrayListUnmanaged(Format.IndexEntry),
    restarts: std.ArrayListUnmanaged(u32),
    restart_counter: usize,
    bloom: BloomFilter,
    block_start_offset: u64,
    enable_compression: bool,
    last_key: std.ArrayListUnmanaged(u8),
    
    final_path: []const u8,
    temp_path: []const u8,
    block_size: usize,
    finished: bool,

    pub fn init(allocator: Allocator, path: []const u8, enable_compression: bool, expected_elements: usize, block_size: usize) !Builder {
        const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        errdefer allocator.free(temp_path);

        const file = try std.fs.cwd().createFile(temp_path, .{ .read = true, .truncate = true });
        
        const bloom_elements = if (expected_elements > 0) expected_elements else 1000;
        
        var b = Builder{
            .file = file,
            .allocator = allocator,
            .current_block = .{},
            .index = .{},
            .restarts = .{},
            .restart_counter = 0,
            .bloom = try BloomFilter.init(allocator, bloom_elements),
            .block_start_offset = 0,
            .enable_compression = enable_compression,
            .last_key = .{},
            .final_path = try allocator.dupe(u8, path),
            .temp_path = temp_path,
            .block_size = if (block_size > 0) block_size else Format.BLOCK_SIZE,
            .finished = false,
        };
        try b.restarts.append(allocator, 0);
        return b;
    }

    pub fn deinit(self: *Builder) void {
        if (!self.finished) {
            self.file.close();
            std.fs.cwd().deleteFile(self.temp_path) catch {};
        }
        
        self.allocator.free(self.temp_path);
        self.allocator.free(self.final_path);

        self.current_block.deinit(self.allocator);
        for (self.index.items) |entry| {
            self.allocator.free(entry.key);
        }
        self.index.deinit(self.allocator);
        self.restarts.deinit(self.allocator);
        self.bloom.deinit();
        self.last_key.deinit(self.allocator);
    }

    pub fn add(self: *Builder, key: []const u8, value: []const u8, version: u64) !void {
        self.bloom.add(key);

        const entry_size = 4 + 4 + 4 + 8 + key.len + value.len;
        const estimated_restarts_size = self.restarts.items.len * 4 + 4;
        
        if (self.current_block.items.len > 0 and 
            self.current_block.items.len + entry_size + estimated_restarts_size > self.block_size) {
            try self.flushBlock();
        }

        var shared_len: u32 = 0;
        
        const is_start_of_block = (self.current_block.items.len == 0);
        const is_restart_interval = (self.restart_counter >= Format.RESTART_INTERVAL);

        if (is_start_of_block) {
            const key_copy = try self.allocator.dupe(u8, key);
            try self.index.append(self.allocator, .{
                .key = key_copy,
                .offset = self.block_start_offset,
                .length = 0,
            });
            self.restarts.clearRetainingCapacity();
            try self.restarts.append(self.allocator, 0);
            self.restart_counter = 0;
        } else if (is_restart_interval) {
            try self.restarts.append(self.allocator, @as(u32, @intCast(self.current_block.items.len)));
            self.restart_counter = 0;
        } else {
            const min_len = @min(self.last_key.items.len, key.len);
            var i: usize = 0;
            while (i < min_len) : (i += 1) {
                if (self.last_key.items[i] != key[i]) break;
            }
            shared_len = @intCast(i);
        }

        self.restart_counter += 1;

        const unshared_len = @as(u32, @intCast(key.len - shared_len));
        const value_len = @as(u32, @intCast(value.len));

        var buf4: [4]u8 = undefined;
        var buf8: [8]u8 = undefined;

        std.mem.writeInt(u32, &buf4, shared_len, .little);
        try self.current_block.appendSlice(self.allocator, &buf4);

        std.mem.writeInt(u32, &buf4, unshared_len, .little);
        try self.current_block.appendSlice(self.allocator, &buf4);

        std.mem.writeInt(u32, &buf4, value_len, .little);
        try self.current_block.appendSlice(self.allocator, &buf4);

        std.mem.writeInt(u64, &buf8, version, .little);
        try self.current_block.appendSlice(self.allocator, &buf8);

        try self.current_block.appendSlice(self.allocator, key[shared_len..]);
        try self.current_block.appendSlice(self.allocator, value);

        self.last_key.clearRetainingCapacity();
        try self.last_key.appendSlice(self.allocator, key);
    }

    fn flushBlock(self: *Builder) !void {
        if (self.current_block.items.len == 0) return;

        for (self.restarts.items) |offset| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, offset, .little);
            try self.current_block.appendSlice(self.allocator, &buf);
        }
        var num_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &num_buf, @as(u32, @intCast(self.restarts.items.len)), .little);
        try self.current_block.appendSlice(self.allocator, &num_buf);

        const uncompressed_len: i32 = @intCast(self.current_block.items.len);
        var compressed_slice: []const u8 = undefined;
        var dest_buffer: ?[]u8 = null;
        defer if (dest_buffer) |d| self.allocator.free(d);
        
        var compression_type: u8 = 0; 

        if (self.enable_compression) {
            const max_dst_size = lz4.LZ4_compressBound(uncompressed_len);
            dest_buffer = try self.allocator.alloc(u8, @intCast(max_dst_size));
            
            const compressed_size = lz4.LZ4_compress_default(
                self.current_block.items.ptr,
                dest_buffer.?.ptr,
                uncompressed_len,
                @intCast(max_dst_size)
            );

            if (compressed_size > 0) {
                    compressed_slice = dest_buffer.?[0..@intCast(compressed_size)];
                    compression_type = 1; 
            } else {
                compressed_slice = self.current_block.items;
                compression_type = 0;
            }
        } else {
            compressed_slice = self.current_block.items;
            compression_type = 0;
        }

        const checksum = Crc32.hash(compressed_slice);

        var type_buf: [1]u8 = .{compression_type};
        try self.file.writeAll(&type_buf);

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @as(u32, @intCast(uncompressed_len)), .little);
        try self.file.writeAll(&len_buf);

        try self.file.writeAll(compressed_slice);

        var crc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, checksum, .little);
        try self.file.writeAll(&crc_buf);

        const total_written = 1 + 4 + @as(u32, @intCast(compressed_slice.len)) + 4;

        if (self.index.items.len > 0) {
            self.index.items[self.index.items.len - 1].length = total_written;
        }

        self.block_start_offset += total_written;
        self.current_block.clearRetainingCapacity();
    }

    const FileWriter = struct {
        file: std.fs.File,
        pub fn writeAll(self: FileWriter, bytes: []const u8) !void {
            try self.file.writeAll(bytes);
        }
        pub fn writeInt(self: FileWriter, comptime T: type, value: T, endian: std.builtin.Endian) !void {
            var bytes: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &bytes, value, endian);
            try self.file.writeAll(&bytes);
        }
    };

    pub fn finish(self: *Builder) !u64 {
        if (self.finished) return error.AlreadyFinished;

        try self.flushBlock();

        const index_offset = try self.file.getPos();

        var writer = FileWriter{ .file = self.file };
        try writer.writeInt(u32, @as(u32, @intCast(self.index.items.len)), .little);
        for (self.index.items) |entry| {
            try writer.writeInt(u32, @as(u32, @intCast(entry.key.len)), .little);
            try writer.writeAll(entry.key);
            try writer.writeInt(u64, entry.offset, .little);
            try writer.writeInt(u32, entry.length, .little);
        }

        const filter_offset = try self.file.getPos();
        try self.bloom.write(writer);

        try writer.writeInt(u64, index_offset, .little);
        try writer.writeInt(u64, filter_offset, .little);
        try writer.writeInt(u64, Format.MAGIC, .little);
        try writer.writeInt(u32, Format.VERSION, .little);
        
        const final_size = try self.file.getPos();
        
        self.file.close();
        try std.fs.cwd().rename(self.temp_path, self.final_path);
        
        self.finished = true;
        return final_size;
    }
};
