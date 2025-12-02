const std = @import("std");
const Allocator = std.mem.Allocator;

const SSTable = @import("sstable.zig").SSTable;

pub const Manifest = struct {
    pub const MAX_LEVELS = 7;

    pub const TableMetadata = struct {
        id: u64,
        level: usize,
        min_key: []u8, // Owned by Manifest
        max_key: []u8, // Owned by Manifest
        file_size: u64,
        max_version: u64,
        reader: ?*SSTable.Reader = null, // Runtime cache
    };

    allocator: Allocator,
    levels: [MAX_LEVELS]std.ArrayListUnmanaged(TableMetadata),
    next_file_id: u64,
    path: []const u8,

    pub fn init(allocator: Allocator, path: []const u8) !Manifest {
        var self = Manifest{
            .allocator = allocator,
            .levels = undefined,
            .next_file_id = 1,
            .path = try allocator.dupe(u8, path),
        };

        for (&self.levels) |*l| {
            l.* = .{};
        }

        // Try load
        self.load() catch |err| {
            if (err != error.FileNotFound) return err;
            // New manifest: create it
            try self.save();
        };

        return self;
    }

    pub fn deinit(self: *Manifest) void {
        for (&self.levels) |*l| {
            for (l.items) |*t| {
                self.allocator.free(t.min_key);
                self.allocator.free(t.max_key);
                if (t.reader) |r| {
                    r.unref();
                }
            }
            l.deinit(self.allocator);
        }
        self.allocator.free(self.path);
    }

    pub fn apply(self: *Manifest, tables_to_add: []const TableMetadata, tables_to_delete: []const u64) !void {
        // 1. Deletions
        if (tables_to_delete.len > 0) {
            for (tables_to_delete) |del_id| {
                for (&self.levels) |*level| {
                    var i: usize = 0;
                    while (i < level.items.len) {
                        if (level.items[i].id == del_id) {
                            const t = level.orderedRemove(i);
                            self.allocator.free(t.min_key);
                            self.allocator.free(t.max_key);
                            if (t.reader) |r| r.unref();
                            // Don't increment i
                        } else {
                            i += 1;
                        }
                    }
                }
            }
        }

        // 2. Additions
        for (tables_to_add) |meta| {
            if (meta.level >= MAX_LEVELS) return error.InvalidLevel;
            const min_copy = try self.allocator.dupe(u8, meta.min_key);
            const max_copy = try self.allocator.dupe(u8, meta.max_key);
            var new_meta = meta;
            new_meta.min_key = min_copy;
            new_meta.max_key = max_copy;
            try self.levels[meta.level].append(self.allocator, new_meta);

            if (meta.id >= self.next_file_id) {
                self.next_file_id = meta.id + 1;
            }
        }

        try self.save();
    }

    pub fn getNextFileId(self: *Manifest) u64 {
        const id = self.next_file_id;
        self.next_file_id += 1;
        return id;
    }

    const ArrayListWriter = struct {
        list: *std.ArrayListUnmanaged(u8),
        allocator: Allocator,
        pub const Error = Allocator.Error;

        pub fn writeAll(self: ArrayListWriter, bytes: []const u8) !void {
            try self.list.appendSlice(self.allocator, bytes);
        }

        pub fn writeByte(self: ArrayListWriter, byte: u8) !void {
            try self.list.append(self.allocator, byte);
        }

        pub fn write(self: ArrayListWriter, bytes: []const u8) !usize {
            try self.list.appendSlice(self.allocator, bytes);
            return bytes.len;
        }
    };

    fn save(self: *Manifest) !void {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(self.allocator);

        var writer = ArrayListWriter{ .list = &buffer, .allocator = self.allocator };

        // Simple JSON format
        // { "next_file_id": 123, "levels": [ [ { "id": 1, ... } ], ... ] }

        try writer.writeAll("{\"next_file_id\": ");
        var buf: [32]u8 = undefined;
        var s = try std.fmt.bufPrint(&buf, "{}", .{self.next_file_id});
        try writer.writeAll(s);

        try writer.writeAll(", \"levels\": [");

        for (self.levels, 0..) |level, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("[");
            for (level.items, 0..) |table, j| {
                if (j > 0) try writer.writeAll(",");

                try writer.writeAll("{\"id\": ");
                s = try std.fmt.bufPrint(&buf, "{}", .{table.id});
                try writer.writeAll(s);

                try writer.writeAll(", \"level\": ");
                s = try std.fmt.bufPrint(&buf, "{}", .{table.level});
                try writer.writeAll(s);

                try writer.writeAll(", \"min_key\": \"");
                for (table.min_key) |b| {
                    var hex_buf: [2]u8 = undefined;
                    _ = try std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{b});
                    try writer.writeAll(&hex_buf);
                }

                try writer.writeAll("\", \"max_key\": \"");
                for (table.max_key) |b| {
                    var hex_buf: [2]u8 = undefined;
                    _ = try std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{b});
                    try writer.writeAll(&hex_buf);
                }

                try writer.writeAll("\", \"file_size\": ");
                s = try std.fmt.bufPrint(&buf, "{}", .{table.file_size});
                try writer.writeAll(s);

                try writer.writeAll(", \"max_version\": ");
                s = try std.fmt.bufPrint(&buf, "{}", .{table.max_version});
                try writer.writeAll(s);

                try writer.writeAll("}");
            }
            try writer.writeAll("]");
        }

        try writer.writeAll("]}");

        // Atomic write: write to .tmp then rename
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.path});
        defer self.allocator.free(tmp_path);

        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll(buffer.items);
        try file.sync();

        try std.fs.cwd().rename(tmp_path, self.path);
    }

    pub fn load(self: *Manifest) !void {
        const file = std.fs.cwd().openFile(self.path, .{}) catch |err| return err;
        defer file.close();

        const size = (try file.stat()).size;
        const buffer = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buffer);

        const bytes_read = try readAll(file, buffer);
        if (bytes_read != buffer.len) return error.UnexpectedEOF;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, buffer, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidManifest;

        if (root.object.get("next_file_id")) |val| {
            if (val == .integer) self.next_file_id = @as(u64, @intCast(val.integer));
        }

        if (root.object.get("levels")) |levels_val| {
            if (levels_val == .array) {
                for (levels_val.array.items, 0..) |level_val, i| {
                    if (i >= MAX_LEVELS) break;
                    if (level_val == .array) {
                        for (level_val.array.items) |table_val| {
                            if (table_val != .object) continue;
                            const obj = table_val.object;

                            const id = obj.get("id").?.integer;
                            const level = obj.get("level").?.integer;
                            const min_key_hex = obj.get("min_key").?.string;
                            const max_key_hex = obj.get("max_key").?.string;
                            const file_size = obj.get("file_size").?.integer;

                            const max_ver = if (obj.get("max_version")) |v| @as(u64, @intCast(v.integer)) else 0;

                            // Decode Hex
                            if (min_key_hex.len % 2 != 0 or max_key_hex.len % 2 != 0) return error.InvalidManifest;

                            const min_key = try self.allocator.alloc(u8, min_key_hex.len / 2);
                            errdefer self.allocator.free(min_key);
                            _ = try std.fmt.hexToBytes(min_key, min_key_hex);

                            const max_key = try self.allocator.alloc(u8, max_key_hex.len / 2);
                            errdefer self.allocator.free(max_key);
                            _ = try std.fmt.hexToBytes(max_key, max_key_hex);

                            const meta = TableMetadata{
                                .id = @as(u64, @intCast(id)),
                                .level = @as(usize, @intCast(level)),
                                .min_key = min_key,
                                .max_key = max_key,
                                .file_size = @as(u64, @intCast(file_size)),
                                .max_version = max_ver,
                            };

                            try self.levels[i].append(self.allocator, meta);
                        }
                    }
                }
            }
        }
    }

    fn readAll(file: std.fs.File, buffer: []u8) !usize {
        var index: usize = 0;
        while (index < buffer.len) {
            const amt = try file.read(buffer[index..]);
            if (amt == 0) break;
            index += amt;
        }
        return index;
    }
};

test "Manifest basic flow" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "MANIFEST_TEST_{}", .{std.crypto.random.int(u64)});

    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    {
        var m = try Manifest.init(allocator, path);
        defer m.deinit();

        var tables_to_add = std.ArrayListUnmanaged(Manifest.TableMetadata){};
        defer tables_to_add.deinit(allocator);

        try tables_to_add.append(allocator, .{
            .id = 1,
            .level = 0,
            .min_key = @constCast("a"), // const cast because apply dupes
            .max_key = @constCast("z"),
            .file_size = 100,
            .max_version = 10,
        });

        try m.apply(tables_to_add.items, &.{});

        try std.testing.expectEqual(m.next_file_id, 2);
    }

    {
        var m = try Manifest.init(allocator, path);
        defer m.deinit();

        try std.testing.expectEqual(m.next_file_id, 2);
        try std.testing.expectEqual(m.levels[0].items.len, 1);
        try std.testing.expectEqual(m.levels[0].items[0].id, 1);
        try std.testing.expectEqualStrings(m.levels[0].items[0].min_key, "a");
    }
}
