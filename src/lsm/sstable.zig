const Format = @import("sstable/format.zig");

pub const SSTable = struct {
    pub const BLOCK_SIZE = Format.BLOCK_SIZE;
    pub const RESTART_INTERVAL = Format.RESTART_INTERVAL;

    pub const Builder = @import("sstable/builder.zig").Builder;
    pub const Reader = @import("sstable/reader.zig").Reader;
    pub const ValueRef = Reader.ValueRef;
    pub const BlockIterator = @import("sstable/block_iterator.zig").BlockIterator;
};

test "SSTable basic flow" {
    const std = @import("std");
    const BlockCache = @import("block_cache.zig").BlockCache;

    const allocator = std.testing.allocator;
    var rnd = std.crypto.random;
    var buf: [64]u8 = undefined;
    const test_path = try std.fmt.bufPrint(&buf, "test_{x}.sst", .{rnd.int(u64)});

    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    var block_cache = BlockCache.init(allocator, 1024 * 1024);
    defer block_cache.deinit();

    // Build
    var builder = try SSTable.Builder.init(allocator, test_path, true, 3, 64 * 1024);
    try builder.add("key1", "value1", 10);
    try builder.add("key2", "value2", 20);
    try builder.add("key3", "value3", 30);
    _ = try builder.finish();
    builder.deinit();

    // Read
    var reader = try SSTable.Reader.open(allocator, test_path, &block_cache);
    defer reader.unref();

    if (try reader.get(allocator, "key1", 15)) |val| {
        defer val.deinit();
        try std.testing.expectEqualStrings("value1", val.data);
    } else {
        try std.testing.expect(false);
    }

    if (try reader.get(allocator, "key2", 25)) |val| {
        defer val.deinit();
        try std.testing.expectEqualStrings("value2", val.data);
    } else {
        try std.testing.expect(false);
    }

    if (try reader.get(allocator, "key2", 25)) |val| {
        defer val.deinit();
        try std.testing.expectEqualStrings("value2", val.data);
    }

    try std.testing.expect((try reader.get(allocator, "key99", 100)) == null);
}
