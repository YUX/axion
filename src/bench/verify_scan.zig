const std = @import("std");
const Config = @import("bench_config.zig");
const DB = @import("axion").DB;
const c = @import("axion").sqlite.c;
const vtab = @import("axion").sqlite.vtab;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const db_path = "verify_scan_db";

    std.debug.print("Setting up DB at {s}...\n", .{db_path});
    std.fs.cwd().deleteTree(db_path) catch {};

    // Populate using VTab (Composite Keys)
    {
        var db: ?*c.sqlite3 = null;
        _ = c.sqlite3_open(":memory:", &db);
        defer _ = c.sqlite3_close(db);
        _ = vtab.register(db);

        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(&sql_buf, "CREATE VIRTUAL TABLE t1 USING axion('{s}', 'OFF');", .{db_path});
        _ = c.sqlite3_exec(db, sql.ptr, null, null, null);
        _ = c.sqlite3_exec(db, "BEGIN;", null, null, null);

        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "INSERT INTO t1 VALUES (?, ?);", -1, &stmt, null);
        defer _ = c.sqlite3_finalize(stmt);

        var i: usize = 0;
        var k_buf: [64]u8 = undefined;
        var v_buf: [64]u8 = undefined;
        while (i < 1000) : (i += 1) {
            const k = try std.fmt.bufPrintZ(&k_buf, Config.KEY_FMT, .{i});
            const v = try std.fmt.bufPrintZ(&v_buf, Config.VAL_FMT, .{i});

            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_bind_text(stmt, 1, k.ptr, -1, c.SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 2, v.ptr, -1, c.SQLITE_STATIC);
            _ = c.sqlite3_step(stmt);
        }
        _ = c.sqlite3_exec(db, "COMMIT;", null, null, null);
    }

    // Verify VTab Scan
    std.debug.print("\n--- Verifying VTab Scan ---\n", .{});
    {
        var db: ?*c.sqlite3 = null;
        _ = c.sqlite3_open(":memory:", &db);
        defer _ = c.sqlite3_close(db);

        _ = vtab.register(db);

        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(&sql_buf, "CREATE VIRTUAL TABLE t1 USING axion('{s}', 'OFF');", .{db_path});
        _ = c.sqlite3_exec(db, sql.ptr, null, null, null);

        const seek_key = try std.fmt.allocPrint(allocator, Config.KEY_FMT, .{500});
        defer allocator.free(seek_key);

        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "SELECT key FROM t1 WHERE key >= ? LIMIT 5;", -1, &stmt, null);
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, seek_key.ptr, @intCast(seek_key.len), c.SQLITE_STATIC);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const k = c.sqlite3_column_text(stmt, 0);
            std.debug.print("VTab Found: {s}\n", .{k});
        }
    }

    // Verify Native Scan (Raw)
    std.debug.print("\n--- Verifying Native Scan (Raw) ---\n", .{});
    {
        var db = try DB.open(allocator, db_path, .{ .wal_sync_mode = .Off });
        defer db.close();

        const rot = db.tm.beginReadOnly();
        defer db.tm.endReadOnly(rot);

        var iter = try db.createIterator(rot.read_version);
        defer iter.deinit();

        // Native scan will see Composite Keys (prefixed with \x01)
        // We scan from start
        const seek_key = "";
        try iter.seek(seek_key);

        var count: usize = 0;
        while (count < 5) : (count += 1) {
            if (try iter.next()) |entry| {
                // Print bytes in hex for clarity
                std.debug.print("Native Found Raw: {any}\n", .{entry.key});
            } else {
                std.debug.print("Native EOF\n", .{});
                break;
            }
        }
    }
}
