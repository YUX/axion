const std = @import("std");
const Allocator = std.mem.Allocator;
const Schema = @import("schema.zig");

pub const Row = struct {
    pub const Value = union(Schema.ColumnType) {
        Integer: i64,
        Float: f64,
        Text: []const u8,
        Blob: []const u8,
        Null: void,
    };

    pub fn serialize(allocator: Allocator, values: []const Value) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);

        var header = std.ArrayListUnmanaged(u8){};
        defer header.deinit(allocator);
        
        var body = std.ArrayListUnmanaged(u8){};
        defer body.deinit(allocator);

        for (values) |val| {
            switch (val) {
                .Null => {
                    try header.append(allocator, @intFromEnum(Schema.ColumnType.Null)); 
                },
                .Integer => |v| {
                    try header.append(allocator, @intFromEnum(Schema.ColumnType.Integer));
                    var b: [8]u8 = undefined;
                    std.mem.writeInt(i64, &b, v, .little);
                    try body.appendSlice(allocator, &b);
                },
                .Float => |v| {
                    try header.append(allocator, @intFromEnum(Schema.ColumnType.Float));
                    var b: [8]u8 = undefined;
                    std.mem.writeInt(u64, &b, @as(u64, @bitCast(v)), .little);
                    try body.appendSlice(allocator, &b);
                },
                .Text => |v| {
                    try header.append(allocator, @intFromEnum(Schema.ColumnType.Text));
                    try writeVarint(allocator, &header, v.len);
                    try body.appendSlice(allocator, v);
                },
                .Blob => |v| {
                    try header.append(allocator, @intFromEnum(Schema.ColumnType.Blob));
                    try writeVarint(allocator, &header, v.len);
                    try body.appendSlice(allocator, v);
                },
            }
        }
        
        // Write Header Size first? No, we can just scan the header until we run out of columns.
        // But we don't know how many columns.
        // We can write num_columns.
        
        var final_buf = std.ArrayListUnmanaged(u8){};
        defer final_buf.deinit(allocator);
        
        try writeVarint(allocator, &final_buf, values.len);
        try final_buf.appendSlice(allocator, header.items);
        try final_buf.appendSlice(allocator, body.items);
        
        return final_buf.toOwnedSlice(allocator);
    }

    fn writeVarint(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), value: u64) !void {
        var v = value;
        while (true) {
            var byte = @as(u8, @intCast(v & 0x7F));
            v >>= 7;
            if (v != 0) {
                byte |= 0x80;
                try list.append(allocator, byte);
            } else {
                try list.append(allocator, byte);
                break;
            }
        }
    }

    pub fn deserializeBorrowed(allocator: Allocator, data: []const u8) ![]Value {
        var pos: usize = 0;
        
        if (pos >= data.len) return error.EndOfStream;
        
        const num_cols = try readVarint(data, &pos);
        
        var values = try std.ArrayListUnmanaged(Value).initCapacity(allocator, num_cols);
        errdefer values.deinit(allocator);

        // Header starts at pos
        var header_pos = pos;
        
        const ColMeta = struct { type: Schema.ColumnType, len: u64 };
        var metas = try std.ArrayListUnmanaged(ColMeta).initCapacity(allocator, num_cols);
        defer metas.deinit(allocator);
        
        var i: usize = 0;
        while (i < num_cols) : (i += 1) {
             if (header_pos >= data.len) return error.CorruptRow;
             const type_byte = data[header_pos];
             header_pos += 1;
             
             const ctype = @as(Schema.ColumnType, @enumFromInt(type_byte));
             var len: u64 = 0;
             
             switch (ctype) {
                 .Null => len = 0,
                 .Integer => len = 8,
                 .Float => len = 8,
                 .Text, .Blob => {
                     len = try readVarint(data, &header_pos);
                 },
             }
             try metas.append(allocator, .{ .type = ctype, .len = len });
        }
        
        var body_pos = header_pos;
        
        for (metas.items) |meta| {
             if (body_pos + meta.len > data.len) return error.CorruptRow;
             
             switch (meta.type) {
                 .Null => try values.append(allocator, .Null),
                 .Integer => {
                     const v = std.mem.readInt(i64, data[body_pos..][0..8], .little);
                     try values.append(allocator, .{ .Integer = v });
                 },
                 .Float => {
                     const bits = std.mem.readInt(u64, data[body_pos..][0..8], .little);
                     try values.append(allocator, .{ .Float = @as(f64, @bitCast(bits)) });
                 },
                 .Text => {
                     // Zero-copy: point to data directly
                     const str = data[body_pos..][0..@intCast(meta.len)];
                     try values.append(allocator, .{ .Text = str });
                 },
                 .Blob => {
                     // Zero-copy: point to data directly
                     const blob = data[body_pos..][0..@intCast(meta.len)];
                     try values.append(allocator, .{ .Blob = blob });
                 },
             }
             body_pos += meta.len;
        }
        
        return values.toOwnedSlice(allocator);
    }

    pub fn deserialize(allocator: Allocator, data: []const u8) ![]Value {
        var pos: usize = 0;
        
        if (pos >= data.len) return error.EndOfStream;
        
        const num_cols = try readVarint(data, &pos);
        
        var values = try std.ArrayListUnmanaged(Value).initCapacity(allocator, num_cols);
        errdefer values.deinit(allocator);

        // Header starts at pos
        var header_pos = pos;
        
        // We need to parse header to find body start?
        // It's interleaved in my design: Type + (Len).
        // But Body is separate?
        // Ah, serialize puts Header then Body.
        // So we need to parse the WHOLE header first to find Body Offset.
        
        // Let's parse header into a list of (Type, Length).
        const ColMeta = struct { type: Schema.ColumnType, len: u64 };
        var metas = try std.ArrayListUnmanaged(ColMeta).initCapacity(allocator, num_cols);
        defer metas.deinit(allocator);
        
        var i: usize = 0;
        while (i < num_cols) : (i += 1) {
             if (header_pos >= data.len) return error.CorruptRow;
             const type_byte = data[header_pos];
             header_pos += 1;
             
             const ctype = @as(Schema.ColumnType, @enumFromInt(type_byte));
             var len: u64 = 0;
             
             switch (ctype) {
                 .Null => len = 0,
                 .Integer => len = 8,
                 .Float => len = 8,
                 .Text, .Blob => {
                     len = try readVarint(data, &header_pos);
                 },
             }
             try metas.append(allocator, .{ .type = ctype, .len = len });
        }
        
        var body_pos = header_pos;
        
        for (metas.items) |meta| {
             if (body_pos + meta.len > data.len) return error.CorruptRow;
             
             switch (meta.type) {
                 .Null => try values.append(allocator, .Null),
                 .Integer => {
                     const v = std.mem.readInt(i64, data[body_pos..][0..8], .little);
                     try values.append(allocator, .{ .Integer = v });
                 },
                 .Float => {
                     const bits = std.mem.readInt(u64, data[body_pos..][0..8], .little);
                     try values.append(allocator, .{ .Float = @as(f64, @bitCast(bits)) });
                 },
                 .Text => {
                     const str = try allocator.dupe(u8, data[body_pos..][0..@intCast(meta.len)]);
                     try values.append(allocator, .{ .Text = str });
                 },
                 .Blob => {
                     const blob = try allocator.dupe(u8, data[body_pos..][0..@intCast(meta.len)]);
                     try values.append(allocator, .{ .Blob = blob });
                 },
             }
             body_pos += meta.len;
        }
        
        return values.toOwnedSlice(allocator);
    }

    pub fn deserializeColumn(_: Allocator, data: []const u8, col_idx: usize) !Value {
        var pos: usize = 0;
        if (pos >= data.len) return error.EndOfStream;

        const num_cols = try readVarint(data, &pos);
        if (col_idx >= num_cols) return error.ColumnIndexOutOfBounds;

        // Calculate Header Size and Body Offset for target column
        var current_col: usize = 0;
        var body_offset: u64 = 0;
        
        var target_type: Schema.ColumnType = .Null;
        var target_len: u64 = 0;

        // Scan header
        while (current_col < num_cols) : (current_col += 1) {
             if (pos >= data.len) return error.CorruptRow;
             const type_byte = data[pos];
             pos += 1;
             
             const ctype = @as(Schema.ColumnType, @enumFromInt(type_byte));
             var len: u64 = 0;
             
             switch (ctype) {
                 .Null => len = 0,
                 .Integer => len = 8,
                 .Float => len = 8,
                 .Text, .Blob => {
                     len = try readVarint(data, &pos);
                 },
             }

             if (current_col == col_idx) {
                 target_type = ctype;
                 target_len = len;
                 // We found the meta, but we must continue parsing header to find the START of the body
                 // Actually, the header continues until all columns are parsed. 
                 // So we can't jump yet. We just stop updating body_offset?
                 // No, body_offset is the sum of previous columns.
                 // So we stop adding to body_offset.
             } else if (current_col < col_idx) {
                 body_offset += len;
             }
        }
        
        // 'pos' is now at the start of Body
        const data_ptr = pos + body_offset;
        if (data_ptr + target_len > data.len) return error.CorruptRow;

        switch (target_type) {
             .Null => return .Null,
             .Integer => {
                 const v = std.mem.readInt(i64, data[data_ptr..][0..8], .little);
                 return .{ .Integer = v };
             },
             .Float => {
                 const bits = std.mem.readInt(u64, data[data_ptr..][0..8], .little);
                 return .{ .Float = @as(f64, @bitCast(bits)) };
             },
             .Text => {
                 const str = data[data_ptr..][0..@intCast(target_len)];
                 return .{ .Text = str };
             },
             .Blob => {
                 const blob = data[data_ptr..][0..@intCast(target_len)];
                 return .{ .Blob = blob };
             },
        }
    }

    fn readVarint(data: []const u8, pos: *usize) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (pos.* >= data.len) return error.EndOfStream;
            const byte = data[pos.*];
            pos.* += 1;
            
            result |= @as(u64, (byte & 0x7F)) << shift;
            if ((byte & 0x80) == 0) break;
            shift += 7;
            if (shift >= 64) return error.Overflow;
        }
        return result;
    }
};

test "Row serialization" {
    const allocator = std.testing.allocator;
    
    const values = [_]Row.Value{
        .{ .Integer = 123 },
        .{ .Text = "Hello" },
        .{ .Null = {} },
        .{ .Float = 3.14 },
    };
    
    const bytes = try Row.serialize(allocator, &values);
    defer allocator.free(bytes);
    
    const decoded = try Row.deserialize(allocator, bytes);
    defer {
        for (decoded) |v| {
            switch (v) {
                .Text => |s| allocator.free(s),
                .Blob => |b| allocator.free(b),
                else => {},
            }
        }
        allocator.free(decoded);
    }
    
    try std.testing.expectEqual(decoded.len, 4);
    try std.testing.expectEqual(decoded[0].Integer, 123);
    try std.testing.expectEqualStrings(decoded[1].Text, "Hello");
    try std.testing.expect(decoded[2] == .Null);
    try std.testing.expectApproxEqAbs(decoded[3].Float, 3.14, 0.001);
}
