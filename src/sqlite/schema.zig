const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ColumnType = enum(u8) {
    Integer = 1,
    Float = 2,
    Text = 3,
    Blob = 4,
    Null = 5,
};

pub const Column = struct {
    name: []const u8,
    type: ColumnType,
    id: u32, // Column ID for internal row format
    is_primary_key: bool,
};

pub const Index = struct {
    name: []const u8,
    column_ids: std.ArrayListUnmanaged(u32),
    id: u32,
    unique: bool,
};

pub const TableSchema = struct {
    name: []const u8,
    columns: std.ArrayListUnmanaged(Column),
    indexes: std.ArrayListUnmanaged(Index),
    next_column_id: u32,
    next_index_id: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8) !TableSchema {
        return TableSchema{
            .name = try allocator.dupe(u8, name),
            .columns = .{},
            .indexes = .{},
            .next_column_id = 1,
            .next_index_id = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TableSchema) void {
        self.allocator.free(self.name);
        for (self.columns.items) |c| {
            self.allocator.free(c.name);
        }
        self.columns.deinit(self.allocator);
        for (self.indexes.items) |*idx| {
            self.allocator.free(idx.name);
            idx.column_ids.deinit(self.allocator);
        }
        self.indexes.deinit(self.allocator);
    }

    pub fn addColumn(self: *TableSchema, name: []const u8, ctype: ColumnType, is_pk: bool) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.columns.append(self.allocator, .{
            .name = name_copy,
            .type = ctype,
            .id = self.next_column_id,
            .is_primary_key = is_pk,
        });
        self.next_column_id += 1;
    }

    pub fn addIndex(self: *TableSchema, name: []const u8, col_names: []const []const u8, unique: bool) !void {
        var ids = std.ArrayListUnmanaged(u32){};
        errdefer ids.deinit(self.allocator);

        for (col_names) |c_name| {
            var col_id: ?u32 = null;
            for (self.columns.items) |c| {
                if (std.mem.eql(u8, c.name, c_name)) {
                    col_id = c.id;
                    break;
                }
            }
            if (col_id == null) return error.ColumnNotFound;
            try ids.append(self.allocator, col_id.?);
        }

        const name_copy = try self.allocator.dupe(u8, name);
        try self.indexes.append(self.allocator, .{
            .name = name_copy,
            .column_ids = ids,
            .id = self.next_index_id,
            .unique = unique,
        });
        self.next_index_id += 1;
    }

    pub fn toJson(self: *TableSchema) ![]u8 {
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(self.allocator);

        const header = try std.fmt.allocPrint(self.allocator, 
            "{{\"name\": \"{s}\", \"next_column_id\": {}, \"next_index_id\": {}, \"columns\": [", 
            .{self.name, self.next_column_id, self.next_index_id});
        defer self.allocator.free(header);
        try list.appendSlice(self.allocator, header);

        for (self.columns.items, 0..) |col, i| {
            if (i > 0) try list.appendSlice(self.allocator, ", ");
            
            const col_str = try std.fmt.allocPrint(self.allocator, "{{\"name\": \"{s}\", \"type\": {}, \"id\": {}, \"is_primary_key\": {}}}", 
                .{col.name, @intFromEnum(col.type), col.id, col.is_primary_key});
            defer self.allocator.free(col_str);
            try list.appendSlice(self.allocator, col_str);
        }

        try list.appendSlice(self.allocator, "], \"indexes\": [");

        for (self.indexes.items, 0..) |idx, i| {
            if (i > 0) try list.appendSlice(self.allocator, ", ");
            
            try list.appendSlice(self.allocator, "{");
            const s = try std.fmt.allocPrint(self.allocator, "\"name\": \"{s}\", \"id\": {}, \"unique\": {}, \"column_ids\": [", .{idx.name, idx.id, idx.unique});
            try list.appendSlice(self.allocator, s);
            self.allocator.free(s);
            
            for (idx.column_ids.items, 0..) |cid, j| {
                if (j > 0) try list.appendSlice(self.allocator, ",");
                const cs = try std.fmt.allocPrint(self.allocator, "{}", .{cid});
                try list.appendSlice(self.allocator, cs);
                self.allocator.free(cs);
            }
            try list.appendSlice(self.allocator, "]}");
        }

        try list.appendSlice(self.allocator, "]}");
        return list.toOwnedSlice(self.allocator);
    }

    pub fn fromJson(allocator: Allocator, json: []const u8) !TableSchema {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{} );
        defer parsed.deinit();
        
        const root = parsed.value;
        if (root != .object) return error.InvalidSchema;
        
        const name = root.object.get("name").?.string;
        const next_id = root.object.get("next_column_id").?.integer;
        const next_idx_id = if (root.object.get("next_index_id")) |v| v.integer else 1;
        
        var schema = try TableSchema.init(allocator, name);
        schema.next_column_id = @intCast(next_id);
        schema.next_index_id = @intCast(next_idx_id);
        
        if (root.object.get("columns")) |cols_val| {
            if (cols_val == .array) {
                for (cols_val.array.items) |col_val| {
                    const obj = col_val.object;
                    const col_name = obj.get("name").?.string;
                    const col_type = @as(ColumnType, @enumFromInt(obj.get("type").?.integer));
                    const col_id = obj.get("id").?.integer;
                    const is_pk = obj.get("is_primary_key").?.bool;
                    
                    const name_copy = try allocator.dupe(u8, col_name);
                    try schema.columns.append(allocator, .{
                        .name = name_copy,
                        .type = col_type,
                        .id = @intCast(col_id),
                        .is_primary_key = is_pk,
                    });
                }
            }
        }

        if (root.object.get("indexes")) |idxs_val| {
            if (idxs_val == .array) {
                for (idxs_val.array.items) |idx_val| {
                    const obj = idx_val.object;
                    const idx_name = obj.get("name").?.string;
                    const id = obj.get("id").?.integer;
                    const unique = if (obj.get("unique")) |v| v.bool else false;

                    var ids = std.ArrayListUnmanaged(u32){};
                    
                    if (obj.get("column_ids")) |cids_val| {
                        if (cids_val == .array) {
                            for (cids_val.array.items) |cv| {
                                try ids.append(allocator, @intCast(cv.integer));
                            }
                        }
                    } else if (obj.get("column_id")) |cid_val| {
                        try ids.append(allocator, @intCast(cid_val.integer));
                    }

                    const name_copy = try allocator.dupe(u8, idx_name);
                    try schema.indexes.append(allocator, .{
                        .name = name_copy,
                        .column_ids = ids,
                        .id = @intCast(id),
                        .unique = unique,
                    });
                }
            }
        }

        return schema;
    }
};

test "Schema serialization" {
    const allocator = std.testing.allocator;
    
    var schema = try TableSchema.init(allocator, "users");
    defer schema.deinit();
    
    try schema.addColumn("id", .Integer, true);
    try schema.addColumn("email", .Text, false);
    
    const json = try schema.toJson();
    defer allocator.free(json);
    
    var loaded = try TableSchema.fromJson(allocator, json);
    defer loaded.deinit();
    
    try std.testing.expectEqualStrings("users", loaded.name);
    try std.testing.expectEqual(loaded.columns.items.len, 2);
    try std.testing.expectEqualStrings("id", loaded.columns.items[0].name);
    try std.testing.expectEqual(ColumnType.Integer, loaded.columns.items[0].type);
}