const std = @import("std");

pub const RecordFormat = struct {
    pub const HEADER_SIZE = 4 + 8 + 4 + 4; // CRC(4), Ver(8), KLen(4), VLen(4)

    pub inline fn encode(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8, version: u64) !void {
        var crc = std.hash.Crc32.init();

        var version_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &version_bytes, version, .little);

        var key_len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &key_len_bytes, @as(u32, @intCast(key.len)), .little);

        var val_len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &val_len_bytes, @as(u32, @intCast(value.len)), .little);

        crc.update(&version_bytes);
        crc.update(&key_len_bytes);
        crc.update(&val_len_bytes);
        crc.update(key);
        crc.update(value);

        try buffer.ensureUnusedCapacity(allocator, HEADER_SIZE + key.len + value.len);

        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc.final(), .little);

        buffer.appendSliceAssumeCapacity(&crc_bytes);
        buffer.appendSliceAssumeCapacity(&version_bytes);
        buffer.appendSliceAssumeCapacity(&key_len_bytes);
        buffer.appendSliceAssumeCapacity(&val_len_bytes);
        buffer.appendSliceAssumeCapacity(key);
        buffer.appendSliceAssumeCapacity(value);
    }

    pub inline fn encodePlaceholders(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try buffer.ensureUnusedCapacity(allocator, HEADER_SIZE + key.len + value.len);

        // We need to write correct length fields though, otherwise recovery or patching might fail if offsets are calculated dynamically.
        // Actually Transaction.put wrote length fields.

        // Let's stick to what Transaction.put did but make it cleaner.
        // [CRC(4)][Ver(8)][KLen(4)][VLen(4)]

        // Placeholder CRC & Ver
        buffer.appendSliceAssumeCapacity(&[_]u8{0} ** 12);

        var klen: [4]u8 = undefined;
        std.mem.writeInt(u32, &klen, @as(u32, @intCast(key.len)), .little);
        buffer.appendSliceAssumeCapacity(&klen);

        var vlen: [4]u8 = undefined;
        std.mem.writeInt(u32, &vlen, @as(u32, @intCast(value.len)), .little);
        buffer.appendSliceAssumeCapacity(&vlen);

        buffer.appendSliceAssumeCapacity(key);
        buffer.appendSliceAssumeCapacity(value);
    }
};
