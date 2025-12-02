const std = @import("std");
const Allocator = std.mem.Allocator;
const Comparator = @import("../comparator.zig");

const FixedBufferStream = struct {
    buffer: []const u8,
    pos: usize,

    pub fn init(buffer: []const u8) FixedBufferStream {
        return .{ .buffer = buffer, .pos = 0 };
    }

    pub fn read(self: *FixedBufferStream, dest: []u8) !usize {
        if (self.pos >= self.buffer.len) return 0;
        const end = @min(self.pos + dest.len, self.buffer.len);
        const count = end - self.pos;
        @memcpy(dest[0..count], self.buffer[self.pos..end]);
        self.pos += count;
        return count;
    }
    
    pub fn readInt(self: *FixedBufferStream, comptime T: type, endian: std.builtin.Endian) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        const n = try self.read(&bytes);
        if (n < @sizeOf(T)) return error.EndOfStream;
        return std.mem.readInt(T, &bytes, endian);
    }

    pub fn seekTo(self: *FixedBufferStream, pos: usize) !void {
        if (pos > self.buffer.len) return error.EndOfStream;
        self.pos = pos;
    }
};

pub const BlockIterator = struct {
    allocator: Allocator,
    block_data: []const u8,
    fbs: FixedBufferStream,
    restarts_limit: usize,
    
    key_buf_a: std.ArrayListUnmanaged(u8),
    key_buf_b: std.ArrayListUnmanaged(u8),
    use_buf_a: bool,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
        version: u64,
    };

    pub fn init(allocator: Allocator, block_data: []const u8) BlockIterator {
        var limit: usize = 0;
        if (block_data.len >= 4) {
            const num_restarts = std.mem.readInt(u32, block_data[block_data.len - 4..][0..4], .little);
            if (block_data.len >= 4 + num_restarts * 4) {
                limit = block_data.len - 4 - (num_restarts * 4);
            } else {
                limit = 0;
            }
        }

        return BlockIterator{
            .allocator = allocator,
            .block_data = block_data,
            .fbs = FixedBufferStream.init(block_data),
            .restarts_limit = limit,
            .key_buf_a = .{},
            .key_buf_b = .{},
            .use_buf_a = true,
        };
    }

    pub fn deinit(self: *BlockIterator) void {
        self.key_buf_a.deinit(self.allocator);
        self.key_buf_b.deinit(self.allocator);
    }
    
    fn currentKey(self: *BlockIterator) *std.ArrayListUnmanaged(u8) {
        return if (self.use_buf_a) &self.key_buf_a else &self.key_buf_b;
    }
    
    fn nextKeyBuf(self: *BlockIterator) *std.ArrayListUnmanaged(u8) {
        return if (self.use_buf_a) &self.key_buf_b else &self.key_buf_a;
    }
    
    fn swapKeys(self: *BlockIterator) void {
        self.use_buf_a = !self.use_buf_a;
    }

    pub fn seek(self: *BlockIterator, key: []const u8) !void {
            const start_offset = try self.findKeyRestartPoint(key);
            self.fbs.seekTo(start_offset) catch return error.CorruptBlock;
            self.currentKey().clearRetainingCapacity();
    }

    fn findKeyRestartPoint(self: *BlockIterator, key: []const u8) !usize {
        if (self.block_data.len < 4) return 0;
        const restarts_len = self.block_data.len - 4 - self.restarts_limit;
        const num_restarts = restarts_len / 4;
        
        if (num_restarts == 0) return 0;

        var left: u32 = 0;
        var right: u32 = @intCast(num_restarts);
        
        while (left < right) {
            const mid = left + (right - left) / 2;
            const offset_pos = self.restarts_limit + mid * 4;
            const offset = std.mem.readInt(u32, self.block_data[offset_pos..][0..4], .little);
            
            if (offset + 4 > self.restarts_limit) break; 
            
            const unshared_len = std.mem.readInt(u32, self.block_data[offset+4..][0..4], .little);
            const k_ptr = offset + 20; 
            
            if (k_ptr + unshared_len > self.restarts_limit) break;
            const k = self.block_data[k_ptr..][0..unshared_len];

            if (Comparator.compare(k, key) == .lt) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        const search_idx = if (left > 0) left - 1 else 0;
        const start_offset = std.mem.readInt(u32, self.block_data[self.restarts_limit + search_idx * 4..][0..4], .little);
        return start_offset;
    }

    pub fn seekForwardTo(self: *BlockIterator, key: []const u8) !void {
            // Use self.fbs directly
            while (self.fbs.pos < self.restarts_limit) {
            const start_pos = self.fbs.pos;
            if (start_pos + 20 > self.restarts_limit) break;

            const shared = try self.fbs.readInt(u32, .little);
            const unshared = try self.fbs.readInt(u32, .little);
            const v_len = try self.fbs.readInt(u32, .little);
            _ = try self.fbs.readInt(u64, .little); 

            const next_buf = self.nextKeyBuf();
            next_buf.clearRetainingCapacity();
            
            const curr_items = self.currentKey().items;
            if (shared > curr_items.len) return error.CorruptBlock;
            
            try next_buf.appendSlice(self.allocator, curr_items[0..shared]);
            
            if (self.fbs.pos + unshared > self.restarts_limit) return error.CorruptBlock;
            
            const key_suffix = self.block_data[self.fbs.pos..][0..unshared];
            try next_buf.appendSlice(self.allocator, key_suffix);
            
            if (Comparator.compare(next_buf.items, key) != .lt) {
                self.fbs.pos = start_pos;
                return;
            }
            
            self.fbs.pos += unshared;
            self.fbs.pos += v_len;
            
            self.swapKeys();
            }
    }

    pub fn next(self: *BlockIterator) !?Entry {
        if (self.fbs.pos >= self.restarts_limit) return null;
        if (self.restarts_limit - self.fbs.pos < 20) return null; 

        const shared = try self.fbs.readInt(u32, .little);
        const unshared = try self.fbs.readInt(u32, .little);
        const v_len = try self.fbs.readInt(u32, .little);
        const ver = try self.fbs.readInt(u64, .little);

        const next_buf = self.nextKeyBuf();
        next_buf.clearRetainingCapacity();
        
        const curr_items = self.currentKey().items;
        if (shared > curr_items.len) return error.CorruptBlock;
        
        try next_buf.appendSlice(self.allocator, curr_items[0..shared]);
        
        if (self.fbs.pos + unshared > self.restarts_limit) return error.CorruptBlock;
        
        const key_suffix = self.block_data[self.fbs.pos..][0..unshared];
        try next_buf.appendSlice(self.allocator, key_suffix);
        self.fbs.pos += unshared;
        
        const v_start = self.fbs.pos;
        if (v_start + v_len > self.restarts_limit) return error.CorruptBlock;
        const v = self.block_data[v_start..][0..v_len];
        self.fbs.pos += v_len;

        self.swapKeys();

        return Entry{
            .key = self.currentKey().items,
            .value = v,
            .version = ver,
        };
    }
};