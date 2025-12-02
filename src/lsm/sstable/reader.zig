const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.Crc32;
const Format = @import("format.zig");
const BloomFilter = @import("filter.zig").BloomFilter;
const BlockIterator = @import("block_iterator.zig").BlockIterator;
const BlockCache = @import("../block_cache.zig").BlockCache;
const Comparator = @import("../comparator.zig");
const lz4 = @cImport({
    @cInclude("lz4.h");
});

pub const Reader = struct {
    file: std.fs.File,
    allocator: Allocator,
    file_size: u64,
    index: std.ArrayListUnmanaged(Format.IndexEntry),
    bloom: BloomFilter,
    block_cache: ?*BlockCache,
    file_id: u64,
    ref_count: std.atomic.Value(usize),
    mmap_ptr: ?[]align(4096) const u8,

    pub const ValueRef = struct {
        data: []const u8,
        handle: ?BlockCache.Handle,
        owned_buffer: ?[]u8,
        allocator: Allocator,

        pub fn deinit(self: ValueRef) void {
            if (self.handle) |h| h.release();
            if (self.owned_buffer) |b| self.allocator.free(b);
        }
    };

    pub fn open(allocator: Allocator, path: []const u8, block_cache: ?*BlockCache) !*Reader {
        const file = try std.fs.cwd().openFile(path, .{});
        const stat = try file.stat();
        const file_size = stat.size;

        if (file_size < Format.FOOTER_SIZE) return error.InvalidSSTable;

        const file_id = std.hash.Wyhash.hash(0, path);

        var mmap_ptr: ?[]align(4096) const u8 = null;
        if (file_size > 0) {
            mmap_ptr = std.posix.mmap(
                null,
                file_size,
                1, 
                .{ .TYPE = .PRIVATE },
                file.handle,
                0,
            ) catch null;
        }

        const self = try allocator.create(Reader);
        self.* = Reader{
            .file = file,
            .allocator = allocator,
            .file_size = file_size,
            .index = .{},
            .bloom = undefined,
            .block_cache = block_cache,
            .file_id = file_id,
            .ref_count = std.atomic.Value(usize).init(1),
            .mmap_ptr = mmap_ptr,
        };

        try self.readFooter();
        return self;
    }

    pub fn ref(self: *Reader) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn unref(self: *Reader) void {
        const prev = self.ref_count.fetchSub(1, .release);
        if (prev == 1) {
            _ = self.ref_count.load(.acquire);
            self.deinit();
        }
    }

    fn deinit(self: *Reader) void {
        if (self.mmap_ptr) |ptr| {
            std.posix.munmap(ptr);
        }
        self.file.close();
        for (self.index.items) |entry| {
            self.allocator.free(entry.key);
        }
        self.index.deinit(self.allocator);
        self.bloom.deinit();
        self.allocator.destroy(self);
    }

    const FileReader = struct {
        file: std.fs.File,
        mmap_ptr: ?[]const u8,
        pos: u64 = 0,

        pub fn readNoEof(self: *FileReader, buf: []u8) !void {
            if (self.mmap_ptr) |mem| {
                if (self.pos + buf.len > mem.len) return error.EndOfStream;
                @memcpy(buf, mem[self.pos..][0..buf.len]);
                self.pos += buf.len;
            } else {
                var index: usize = 0;
                while (index < buf.len) {
                    const n = try self.file.read(buf[index..]);
                    if (n == 0) return error.EndOfStream;
                    index += n;
                }
            }
        }
        
        pub fn readInt(self: *FileReader, comptime T: type, endian: std.builtin.Endian) !T {
            var bytes: [@sizeOf(T)]u8 = undefined;
            try self.readNoEof(&bytes);
            return std.mem.readInt(T, &bytes, endian);
        }
    };

    fn readFooter(self: *Reader) !void {
        var reader = FileReader{ .file = self.file, .mmap_ptr = self.mmap_ptr };
        
        if (self.mmap_ptr) |_| {
            reader.pos = self.file_size - Format.FOOTER_SIZE;
        } else {
            try self.file.seekTo(self.file_size - Format.FOOTER_SIZE);
        }

        const index_offset = try reader.readInt(u64, .little);
        const filter_offset = try reader.readInt(u64, .little);
        const magic = try reader.readInt(u64, .little);
        const version = try reader.readInt(u32, .little);

        if (magic != Format.MAGIC) return error.InvalidMagic;
        if (version != Format.VERSION) return error.UnsupportedVersion;

        if (self.mmap_ptr) |_| {
            reader.pos = index_offset;
        } else {
            try self.file.seekTo(index_offset);
        }
        
        const num_entries = try reader.readInt(u32, .little);
        try self.index.ensureTotalCapacity(self.allocator, num_entries);

        var i: u32 = 0;
        while (i < num_entries) : (i += 1) {
            const key_len = try reader.readInt(u32, .little);
            const key = try self.allocator.alloc(u8, key_len);
            try reader.readNoEof(key);
            const offset = try reader.readInt(u64, .little);
            const len = try reader.readInt(u32, .little);
            self.index.appendAssumeCapacity(.{
                .key = key,
                .offset = offset,
                .length = len,
            });
        }

        if (self.mmap_ptr) |_| {
            reader.pos = filter_offset;
        } else {
            try self.file.seekTo(filter_offset);
        }
        self.bloom = try BloomFilter.read(self.allocator, &reader);
    }

    pub fn get(self: *Reader, allocator: Allocator, key: []const u8, snapshot_version: u64) !?ValueRef {
        if (!self.bloom.contains(key)) return null;

        const block_idx = self.findBlockIndex(key);
        if (block_idx) |idx| {
            return try self.searchBlock(allocator, idx, key, snapshot_version);
        }
        return null;
    }

    pub fn getLatestVersion(self: *Reader, key: []const u8) !?u64 {
        if (!self.bloom.contains(key)) return null;

        const block_idx = self.findBlockIndex(key);
        if (block_idx) |idx| {
            return try self.searchBlockVersion(idx, key);
        }
        return null;
    }
    
    fn findBlockIndex(self: *Reader, key: []const u8) ?usize {
        var left: usize = 0;
        var right: usize = self.index.items.len;
        var block_idx: ?usize = null;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const cmp = Comparator.compare(self.index.items[mid].key, key);
            if (cmp != .gt) {
                block_idx = mid;
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return block_idx;
    }

    pub fn iterator(self: *Reader) Iterator {
        return Iterator.init(self);
    }

    pub fn getBlockData(self: *Reader, block_idx: usize) !struct { handle: ?BlockCache.Handle, buffer: ?[]u8, mmap_slice: ?[]const u8 } {
        const entry = self.index.items[block_idx];

        if (self.block_cache) |cache| {
            if (cache.get(self.file_id, entry.offset)) |handle| {
                return .{ .handle = handle, .buffer = null, .mmap_slice = null };
            }
        }

        const block_buf: []const u8 = if (self.mmap_ptr) |map| blk: {
            if (entry.offset + entry.length > map.len) return error.CorruptBlock;
            break :blk map[entry.offset..][0..entry.length];
        } else blk: {
                if (entry.length < 9) return error.CorruptBlock;
                const buf = try self.allocator.alloc(u8, entry.length);
                const n = try self.file.preadAll(buf, entry.offset);
                if (n != buf.len) {
                    self.allocator.free(buf);
                    return error.EndOfStream;
                }
                break :blk buf;
        };
        
        defer if (self.mmap_ptr == null) self.allocator.free(@constCast(block_buf));

        if (block_buf.len < 9) return error.CorruptBlock;

        const compression_type = block_buf[0];
        const uncompressed_len = std.mem.readInt(u32, block_buf[1..5], .little);
        const data_slice = block_buf[5..block_buf.len-4];
        const expected_crc = std.mem.readInt(u32, block_buf[block_buf.len-4..][0..4], .little);

        if (Crc32.hash(data_slice) != expected_crc) return error.ChecksumMismatch;

        if (compression_type == 0) {
            if (self.mmap_ptr) |map| {
                const start = entry.offset + 5;
                const end = start + uncompressed_len;
                if (end > map.len) return error.CorruptBlock;
                return .{ .handle = null, .buffer = null, .mmap_slice = map[start..end] };
            } else {
                const buf = try self.allocator.alloc(u8, uncompressed_len);
                @memcpy(buf, data_slice);
                
                if (self.block_cache) |cache| {
                    const handle = try cache.put(self.file_id, entry.offset, buf);
                    return .{ .handle = handle, .buffer = null, .mmap_slice = null };
                }
                return .{ .handle = null, .buffer = buf, .mmap_slice = null };
            }
        } else {
            const buf = try self.allocator.alloc(u8, uncompressed_len);
            errdefer self.allocator.free(buf);

            const res = lz4.LZ4_decompress_safe(
                data_slice.ptr,
                buf.ptr,
                @intCast(data_slice.len),
                @intCast(uncompressed_len)
            );
            if (res < 0 or res != uncompressed_len) return error.DecompressionFailed;

            if (self.block_cache) |cache| {
                const handle = try cache.put(self.file_id, entry.offset, buf);
                return .{ .handle = handle, .buffer = null, .mmap_slice = null };
            }
            return .{ .handle = null, .buffer = buf, .mmap_slice = null };
        }
    }

    fn searchBlock(self: *Reader, _: Allocator, block_idx: usize, key: []const u8, snapshot_version: u64) !?ValueRef {
        const res = try self.getBlockData(block_idx);
        
        var block_data: []const u8 = undefined;
        if (res.handle) |h| block_data = h.data
        else if (res.buffer) |b| block_data = b
        else block_data = res.mmap_slice.?;
        
        var keep_buffer = false;
        defer {
            if (res.handle) |h| h.release();
            if (res.buffer) |b| {
                if (!keep_buffer) self.allocator.free(b);
            }
        }

        var block_iter = BlockIterator.init(self.allocator, block_data);
        defer block_iter.deinit();

        try block_iter.seek(key);
        try block_iter.seekForwardTo(key);

        while (try block_iter.next()) |entry| {
            const cmp = Comparator.compare(entry.key, key);
            if (cmp == .gt) break;
            
            if (cmp == .eq) {
                if (entry.version <= snapshot_version) {
                    var val_ref = ValueRef{
                        .data = entry.value,
                        .handle = null,
                        .owned_buffer = null,
                        .allocator = self.allocator,
                    };

                    if (res.handle) |h| {
                        val_ref.handle = h.clone();
                    } else if (res.buffer) |b| {
                        val_ref.owned_buffer = b;
                        keep_buffer = true; 
                    }
                    return val_ref;
                }
            }
        }
        
        return null;
    }

    fn searchBlockVersion(self: *Reader, block_idx: usize, key: []const u8) !?u64 {
        const res = try self.getBlockData(block_idx);
            var block_data: []const u8 = undefined;
        if (res.handle) |h| block_data = h.data
        else if (res.buffer) |b| block_data = b
        else block_data = res.mmap_slice.?;

        defer {
            if (res.handle) |h| h.release();
            if (res.buffer) |b| self.allocator.free(b);
        }

        var block_iter = BlockIterator.init(self.allocator, block_data);
        defer block_iter.deinit();

        try block_iter.seek(key);
        try block_iter.seekForwardTo(key);

        while (try block_iter.next()) |entry| {
            const cmp = Comparator.compare(entry.key, key);
            if (cmp == .gt) break;
            if (cmp == .eq) return entry.version;
        }
        return null;
    }

    pub const Iterator = struct {
        reader: *Reader,
        current_block_idx: usize,
        block_handle: ?BlockCache.Handle,
        owned_buffer: ?[]u8,
        block_iter: ?BlockIterator,

        pub fn init(reader: *Reader) Iterator {
            return Iterator{
                .reader = reader,
                .current_block_idx = 0,
                .block_handle = null,
                .owned_buffer = null,
                .block_iter = null,
            };
        }

        pub fn deinit(self: *Iterator) void {
            if (self.block_iter) |*iter| iter.deinit();
            if (self.block_handle) |h| h.release();
            if (self.owned_buffer) |b| self.reader.allocator.free(b);
        }

        pub const Entry = BlockIterator.Entry;

        fn loadBlock(self: *Iterator, idx: usize) !void {
            if (idx >= self.reader.index.items.len) return;

            if (self.block_iter) |*iter| iter.deinit();
            self.block_iter = null;
            
            if (self.block_handle) |h| {
                h.release();
                self.block_handle = null;
            }
            if (self.owned_buffer) |b| {
                self.reader.allocator.free(b);
                self.owned_buffer = null;
            }

            const res = try self.reader.getBlockData(idx);
            self.block_handle = res.handle;
            self.owned_buffer = res.buffer;
            
            var current_data: []const u8 = undefined;
            if (res.handle) |h| current_data = h.data
            else if (res.buffer) |b| current_data = b
            else current_data = res.mmap_slice.?;

            self.block_iter = BlockIterator.init(self.reader.allocator, current_data);
            self.current_block_idx = idx;
        }

        pub fn seek(self: *Iterator, key: []const u8) !void {
            const block_idx = self.reader.findBlockIndex(key) orelse 0;
            // If block_idx is not exact, it points to block where key >= block.min_key.
            // Correct.
            
            try self.loadBlock(block_idx);

            if (self.block_iter) |*iter| {
                try iter.seek(key);
                try iter.seekForwardTo(key);
            }
        }

        pub fn next(self: *Iterator) !?Entry {
            while (true) {
                if (self.block_iter) |*iter| {
                    if (try iter.next()) |entry| {
                        return entry;
                    } else {
                        iter.deinit();
                        self.block_iter = null;
                        self.current_block_idx += 1;
                    }
                } else {
                    if (self.current_block_idx >= self.reader.index.items.len) {
                        return null;
                    }
                    try self.loadBlock(self.current_block_idx);
                }
            }
        }
    };
};
