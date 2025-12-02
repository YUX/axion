const std = @import("std");

/// Encodes keys for Secondary Indexes.
/// Format: [KeyType: 1B] [IndexID: 4B] [Value1][Term]...[ValueN][Term] [PK][Term]
/// Uses null-byte escaping for Values and PKs to ensure they are memcomparable
/// and separable.
pub const KeyType = enum(u8) {
    Primary = 0x00,
    Index = 0x01,
};

/// Encodes an index key.
/// - index_id: Unique ID for the index.
/// - values: The values being indexed (e.g., ["Alice", "Smith"]).
/// - pk: The primary key of the record (e.g., "user:1"), used for uniqueness.
pub fn encodeIndexKey(allocator: std.mem.Allocator, index_id: u32, values: []const []const u8, pk: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);

    // 1. Type Prefix
    try buf.append(allocator, @intFromEnum(KeyType.Index));

    // 2. Index ID (Big Endian for sorting)
    var id_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &id_bytes, index_id, .big);
    try buf.appendSlice(allocator, &id_bytes);

    // 3. Indexed Values (Escaped)
    for (values) |val| {
        try encodeBytes(allocator, &buf, val);
    }

    // 4. Primary Key (Escaped)
    try encodeBytes(allocator, &buf, pk);

    return buf.toOwnedSlice(allocator);
}

/// Encodes a seek key for an index (prefix search).
/// Format: [KeyType: 1B] [IndexID: 4B] [Value1][Term]...
/// Used to check for existence of a value in a UNIQUE index or range scan.
pub fn encodeIndexSeekKey(allocator: std.mem.Allocator, index_id: u32, values: []const []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);

    // 1. Type Prefix
    try buf.append(allocator, @intFromEnum(KeyType.Index));

    // 2. Index ID (Big Endian)
    var id_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &id_bytes, index_id, .big);
    try buf.appendSlice(allocator, &id_bytes);

    // 3. Indexed Values (Escaped)
    for (values) |val| {
        try encodeBytes(allocator, &buf, val);
    }

    return buf.toOwnedSlice(allocator);
}

fn encodeBytes(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), data: []const u8) !void {
    for (data) |b| {
        if (b == 0x00) {
            try buf.appendSlice(allocator, &.{ 0x00, 0xFF });
        } else {
            try buf.append(allocator, b);
        }
    }
    // Terminator
    try buf.append(allocator, 0x00);
}

/// Decodes an Index Key to get the Primary Key.
/// We skip Type (1), IndexID (4), and N Values.
pub fn extractPrimaryKey(allocator: std.mem.Allocator, index_key: []const u8, num_columns: usize) ![]u8 {
    if (index_key.len < 5) return error.InvalidKey;
    if (index_key[0] != @intFromEnum(KeyType.Index)) return error.InvalidKeyType;

    // Skip IndexID
    var pos: usize = 5;
    var cols_skipped: usize = 0;

    while (cols_skipped < num_columns) {
        // Skip one value (scan for terminator)
        while (pos < index_key.len) {
            if (index_key[pos] == 0x00) {
                // Check next byte
                if (pos + 1 < index_key.len and index_key[pos + 1] == 0xFF) {
                    // Escaped 0x00. Skip both.
                    pos += 2;
                    continue;
                } else {
                    // Terminator found.
                    pos += 1; // Consume terminator
                    break;
                }
            } else {
                pos += 1;
            }
        }
        cols_skipped += 1;
    }

    if (pos >= index_key.len) return error.InvalidKeyStructure;

    // Remaining bytes are the Encoded PK.
    // We need to decode it.
    const encoded_pk = index_key[pos..];
    return decodeBytes(allocator, encoded_pk);
}

fn decodeBytes(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];
        if (b == 0x00) {
             if (i + 1 < data.len and data[i+1] == 0xFF) {
                 try buf.append(allocator, 0x00);
                 i += 2;
             } else {
                 // Terminator. Should be at the end.
                 if (i != data.len - 1) {
                     break; 
                 }
                 break;
             }
        } else {
            try buf.append(allocator, b);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

test "Composite Key Encoding" {
    const allocator = std.testing.allocator;
    
    const pk = "user:1";
    const values = [_][]const u8{"Alice"};
    const idx_id = 1;

    const encoded = try encodeIndexKey(allocator, idx_id, &values, pk);
    defer allocator.free(encoded);

    // Check prefix
    try std.testing.expectEqual(encoded[0], 0x01); // Type
    
    // Check ID
    const id = std.mem.readInt(u32, encoded[1..5], .big);
    try std.testing.expectEqual(id, 1);

    // Decode PK (1 column)
    const decoded_pk = try extractPrimaryKey(allocator, encoded, 1);
    defer allocator.free(decoded_pk);
    
    try std.testing.expectEqualStrings(pk, decoded_pk);
}

test "Multi-Column Key Encoding" {
    const allocator = std.testing.allocator;
    
    const pk = "user:1";
    const values = [_][]const u8{"Alice", "Smith"}; // 2 columns
    const idx_id = 1;

    const encoded = try encodeIndexKey(allocator, idx_id, &values, pk);
    defer allocator.free(encoded);

    // Decode PK (2 columns)
    const decoded_pk = try extractPrimaryKey(allocator, encoded, 2);
    defer allocator.free(decoded_pk);
    
    try std.testing.expectEqualStrings(pk, decoded_pk);
}

test "Composite Key Sort Order" {
    const allocator = std.testing.allocator;
    
    const k1 = try encodeIndexKey(allocator, 1, &.{ "Alice" }, "id1"); // "Alice"
    defer allocator.free(k1);
    
    const k2 = try encodeIndexKey(allocator, 1, &.{ "Bob" }, "id2");   // "Bob"
    defer allocator.free(k2);
    
    const k3 = try encodeIndexKey(allocator, 1, &.{ "Alice" }, "id3"); // "Alice" (diff PK)
    defer allocator.free(k3);

    // Alice < Bob
    try std.testing.expect(std.mem.order(u8, k1, k2) == .lt);
    
    // Alice(id1) < Alice(id3)
    try std.testing.expect(std.mem.order(u8, k1, k3) == .lt);
}