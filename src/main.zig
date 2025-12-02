const std = @import("std");
const builtin = @import("builtin");
const DB = @import("axion").DB;
const SSTable = @import("axion").SSTable;

const PROMPT = "axion> ";
const HELP_TEXT =
    \\Available commands:
    \\  open <path>           Open database at path
    \\  close                 Close the current database
    \\  put <key> <value>     Store a key-value pair
    \\  get <key>             Retrieve a value by key
    \\  del <key>             Delete a key
    \\  scan <prefix> [lim]   Scan keys starting with prefix (default limit 20)
    \\  count                 Count all keys in the database (scan all)
    \\  stats                 Show database statistics
    \\  help                  Show this help message
    \\  exit / quit           Exit the REPL
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = try std.fs.openFileAbsolute("/dev/stdout", .{ .mode = .write_only });
    defer stdout.close();

    const stdin = try std.fs.openFileAbsolute("/dev/stdin", .{ .mode = .read_only });
    defer stdin.close();

    var db_instance: ?*DB = null;
    var db_path: ?[]u8 = null;

    defer {
        if (db_instance) |db| db.close();
        if (db_path) |p| allocator.free(p);
    }

    // Argument parsing
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        const path = args[1];
        db_path = try allocator.dupe(u8, path);
        db_instance = DB.open(allocator, path, .{ .wal_sync_mode = .Full }) catch |err| {
            try print(stdout, "Failed to open DB at '{s}': {}\n", .{ path, err });
            return;
        };
        try print(stdout, "Database opened at '{s}'\n", .{path});
    } else {
        try print(stdout, "Welcome to Axion DB CLI. Type 'help' for commands.\n", .{});
    }

    var buf: [4096]u8 = undefined;

    while (true) {
        try print(stdout, "{s}", .{PROMPT});

        const line_opt = readLine(stdin, &buf) catch |err| {
            try print(stdout, "Error reading input: {}\n", .{err});
            break;
        };

        const line = line_opt orelse break;

        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        var it = std.mem.tokenizeAny(u8, trimmed, " ");
        const cmd = it.next() orelse continue;

        if (std.mem.eql(u8, cmd, "exit") or std.mem.eql(u8, cmd, "quit")) {
            break;
        } else if (std.mem.eql(u8, cmd, "help")) {
            try print(stdout, "{s}\n", .{HELP_TEXT});
        } else if (std.mem.eql(u8, cmd, "open")) {
            const path = it.next();
            if (path) |p| {
                if (db_instance) |db| {
                    db.close();
                    db_instance = null;
                }
                if (db_path) |old_p| allocator.free(old_p);

                db_path = try allocator.dupe(u8, p);
                db_instance = DB.open(allocator, p, .{ .wal_sync_mode = .Full }) catch |err| {
                    try print(stdout, "Error opening DB: {}\n", .{err});
                    if (db_path) |dp| {
                        allocator.free(dp);
                        db_path = null;
                    }
                    continue;
                };
                try print(stdout, "Database opened at '{s}'\n", .{p});
            } else {
                try print(stdout, "Usage: open <path>\n", .{});
            }
        } else if (std.mem.eql(u8, cmd, "close")) {
            if (db_instance) |db| {
                db.close();
                db_instance = null;
                try print(stdout, "Database closed.\n", .{});
            } else {
                try print(stdout, "No database open.\n", .{});
            }
        } else {
            // Commands requiring open DB
            if (db_instance == null) {
                try print(stdout, "Error: No database open. Use 'open <path>' first.\n", .{});
                continue;
            }
            const db = db_instance.?;

            if (std.mem.eql(u8, cmd, "put")) {
                const key = it.next();
                const val = it.next();
                if (key != null and val != null) {
                    db.put(key.?, val.?) catch |err| {
                        try print(stdout, "Error: {}\n", .{err});
                    };
                    try print(stdout, "OK\n", .{});
                } else {
                    try print(stdout, "Usage: put <key> <value>\n", .{});
                }
            } else if (std.mem.eql(u8, cmd, "get")) {
                const key = it.next();
                if (key) |k| {
                    if (db.get(k) catch |err| {
                        try print(stdout, "Error: {}\n", .{err});
                        continue;
                    }) |val_ref| {
                        defer val_ref.deinit();
                        try print(stdout, "{s}\n", .{val_ref.data});
                    } else {
                        try print(stdout, "(not found)\n", .{});
                    }
                } else {
                    try print(stdout, "Usage: get <key>\n", .{});
                }
            } else if (std.mem.eql(u8, cmd, "del")) {
                const key = it.next();
                if (key) |k| {
                    db.delete(k) catch |err| {
                        try print(stdout, "Error: {}\n", .{err});
                    };
                    try print(stdout, "OK\n", .{});
                } else {
                    try print(stdout, "Usage: del <key>\n", .{});
                }
            } else if (std.mem.eql(u8, cmd, "scan")) {
                const prefix = it.next() orelse "";
                var limit: usize = 20;
                if (it.next()) |l_str| {
                    if (std.fmt.parseInt(usize, l_str, 10)) |l| {
                        limit = l;
                    } else |_| {}
                }

                const ver = db.tm.global_version.load(.acquire);
                var iter = db.createIterator(ver) catch |err| {
                    try print(stdout, "Error creating iterator: {}\n", .{err});
                    continue;
                };
                defer iter.deinit();

                iter.seek(prefix) catch |err| {
                    try print(stdout, "Error seeking: {}\n", .{err});
                    continue;
                };

                var count: usize = 0;
                while (count < limit) : (count += 1) {
                    const entry = iter.next() catch |err| {
                        try print(stdout, "Error during scan: {}\n", .{err});
                        break;
                    } orelse break;

                    if (!std.mem.startsWith(u8, entry.key, prefix)) break;

                    try print(stdout, "{s} = {s}\n", .{ entry.key, entry.value });
                }
            } else if (std.mem.eql(u8, cmd, "count")) {
                const ver = db.tm.global_version.load(.acquire);
                var iter = db.createIterator(ver) catch |err| {
                    try print(stdout, "Error creating iterator: {}\n", .{err});
                    continue;
                };
                defer iter.deinit();

                iter.seek("") catch |err| {
                    try print(stdout, "Error seeking: {}\n", .{err});
                    continue;
                };

                var count: usize = 0;
                while (true) {
                    const entry = iter.next() catch |err| {
                        try print(stdout, "Error during scan: {}\n", .{err});
                        break;
                    };
                    if (entry == null) break;
                    count += 1;
                    if (count % 100000 == 0) try print(stdout, "... {}\r", .{count});
                }
                try print(stdout, "Total keys: {}\n", .{count});
            } else if (std.mem.eql(u8, cmd, "stats")) {
                const v = db.versions.getCurrent();
                defer v.unref();
                try print(stdout, "Current Version Stats:\n", .{});
                try print(stdout, "  MemTable Size: {} bytes\n", .{v.memtable.approxSize()});
                try print(stdout, "  Immutable MemTables: {}\n", .{v.immutables.items.len});

                for (v.levels, 0..) |level, i| {
                    try print(stdout, "  Level {}: {} tables\n", .{ i, level.items.len });
                }
            } else {
                try print(stdout, "Unknown command: {s}\n", .{cmd});
            }
        }
    }
}

fn print(file: std.fs.File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const slice = try std.fmt.bufPrint(&buf, fmt, args);
    try file.writeAll(slice);
}

fn readLine(file: std.fs.File, buf: []u8) !?[]const u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        var byte: [1]u8 = undefined;
        const n = try file.read(&byte);
        if (n == 0) {
            if (pos == 0) return null;
            return buf[0..pos];
        }
        if (byte[0] == '\n') {
            return buf[0..pos];
        }
        buf[pos] = byte[0];
        pos += 1;
    }
    return error.StreamTooLong;
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(i32) = .{};
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
