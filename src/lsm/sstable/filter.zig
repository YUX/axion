const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BloomFilter = struct {
    bitset: []u64,
    allocator: Allocator,
    k: usize,
    bits_count: usize,

    pub fn init(allocator: Allocator, expected_elements: usize) !BloomFilter {
        // 10 bits per element -> ~1% false positive rate
        const m = expected_elements * 10;
        const k = 7;
        const num_u64 = (m + 63) / 64;
        const bitset = try allocator.alloc(u64, num_u64);
        @memset(bitset, 0);

        return BloomFilter{
            .bitset = bitset,
            .allocator = allocator,
            .k = k,
            .bits_count = m,
        };
    }

    pub fn deinit(self: *BloomFilter) void {
        self.allocator.free(self.bitset);
    }

    pub fn add(self: *BloomFilter, key: []const u8) void {
        var h1 = std.hash.Wyhash.hash(0, key);
        const h2 = std.hash.Wyhash.hash(1, key);
        var i: usize = 0;
        while (i < self.k) : (i += 1) {
            const bit_idx = h1 % self.bits_count;
            const word_idx = bit_idx / 64;
            const bit_offset = @as(u6, @intCast(bit_idx % 64));
            self.bitset[word_idx] |= (@as(u64, 1) << bit_offset);
            h1 +%= h2;
        }
    }

    pub fn contains(self: *BloomFilter, key: []const u8) bool {
        var h1 = std.hash.Wyhash.hash(0, key);
        const h2 = std.hash.Wyhash.hash(1, key);
        var i: usize = 0;
        while (i < self.k) : (i += 1) {
            const bit_idx = h1 % self.bits_count;
            const word_idx = bit_idx / 64;
            const bit_offset = @as(u6, @intCast(bit_idx % 64));
            if ((self.bitset[word_idx] & (@as(u64, 1) << bit_offset)) == 0) return false;
            h1 +%= h2;
        }
        return true;
    }

    pub fn write(self: *BloomFilter, writer: anytype) !void {
        try writer.writeInt(u64, self.bits_count, .little);
        try writer.writeInt(u64, self.k, .little);
        try writer.writeInt(u64, self.bitset.len, .little);
        for (self.bitset) |word| {
            try writer.writeInt(u64, word, .little);
        }
    }

    pub fn read(allocator: Allocator, reader: anytype) !BloomFilter {
        const bits_count = try reader.readInt(u64, .little);
        const k = try reader.readInt(u64, .little);
        const num_u64 = try reader.readInt(u64, .little);

        const bitset = try allocator.alloc(u64, @intCast(num_u64));
        var i: usize = 0;
        while (i < num_u64) : (i += 1) {
            bitset[i] = try reader.readInt(u64, .little);
        }

        return BloomFilter{
            .bitset = bitset,
            .allocator = allocator,
            .k = @as(usize, @intCast(k)),
            .bits_count = @as(usize, @intCast(bits_count)),
        };
    }
};
