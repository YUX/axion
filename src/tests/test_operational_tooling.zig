const std = @import("std");
const c = @import("axion").sqlite.c;
const DB = @import("axion").DB;
const AxionVTab = @import("axion").sqlite.vtab;

test "Integrity Check and Backup API" {
    const db_path = "test_integrity_backup_db";
    const backup_path = "test_integrity_backup_db_bak";

    std.fs.cwd().deleteTree(db_path) catch {};
    defer std.fs.cwd().deleteTree(db_path) catch {};
    std.fs.cwd().deleteTree(backup_path) catch {};
    defer std.fs.cwd().deleteTree(backup_path) catch {};

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.SQLiteOpenFailed;
    defer _ = c.sqlite3_close(db);

    if (@import("axion").sqlite.vtab.register(db) != c.SQLITE_OK) return error.ModuleRegistrationFailed;

    const sql = "CREATE VIRTUAL TABLE users USING axion('" ++ db_path ++ "', 'NORMAL', 'id INT PRIMARY KEY, name TEXT')";
    if (c.sqlite3_exec(db, sql, null, null, null) != c.SQLITE_OK) return error.CreateTableFailed;

    // 1. Insert some data
    _ = c.sqlite3_exec(db, "INSERT INTO users VALUES (1, 'Alice');", null, null, null);
    _ = c.sqlite3_exec(db, "INSERT INTO users VALUES (2, 'Bob');", null, null, null);

    // 2. Perform Integrity Check
    if (c.sqlite3_exec(db, "PRAGMA integrity_check(users);", null, null, null) != c.SQLITE_OK) {
        std.debug.print("Integrity Check Error: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.IntegrityCheckFailed;
    }

    // 3. Perform Backup
    // Must select from the virtual table so that xFindFunction is called on the specific vtab instance
    // We pass 'id' (a column) to ensure SQLite associates this function call with the virtual table.
    const backup_sql_slice = try std.fmt.allocPrint(std.testing.allocator, "SELECT axion_backup(id, '{s}') FROM users LIMIT 1;", .{backup_path});
    defer std.testing.allocator.free(backup_sql_slice);
    const backup_sql = try std.testing.allocator.dupeZ(u8, backup_sql_slice);
    defer std.testing.allocator.free(backup_sql);

    if (c.sqlite3_exec(db, backup_sql.ptr, null, null, null) != c.SQLITE_OK) {
        std.debug.print("Backup Error: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.BackupFailed;
    }
    
    // 4. Verify Backup (basic check: files exist)
    const backup_db_manifest = try std.fs.path.join(std.testing.allocator, &.{backup_path, "MANIFEST"});
    defer std.testing.allocator.free(backup_db_manifest);
    std.fs.cwd().access(backup_db_manifest, .{}) catch return error.ManifestMissing;

    const backup_db_wal = try std.fs.path.join(std.testing.allocator, &.{backup_path, "WAL"});
    defer std.testing.allocator.free(backup_db_wal);
    std.fs.cwd().access(backup_db_wal, .{}) catch return error.WALMissing;

    // SSTable check might fail if no flush happened.
    // const backup_db_sst = try std.fs.path.join(std.testing.allocator, &.{backup_path, "table_1.sst"}); 
    // defer std.testing.allocator.free(backup_db_sst);
    // std.fs.cwd().access(backup_db_sst, .{}) catch return error.SSTableMissing;


    // 5. Open Backup DB and verify data
    var backup_conn: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &backup_conn) != c.SQLITE_OK) return error.SQLiteOpenFailed;
    defer _ = c.sqlite3_close(backup_conn);
    if (AxionVTab.register(backup_conn) != c.SQLITE_OK) return error.ModuleRegistrationFailed;

    const backup_users_sql = "CREATE VIRTUAL TABLE users_bak USING axion('" ++ backup_path ++ "', 'NORMAL', 'id INT PRIMARY KEY, name TEXT')";
    if (c.sqlite3_exec(backup_conn, backup_users_sql, null, null, null) != c.SQLITE_OK) {
        std.debug.print("Backup Create Table Error: {s}\n", .{c.sqlite3_errmsg(backup_conn)});
        return error.CreateTableFailed;
    }

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(backup_conn, "SELECT name FROM users_bak WHERE id = 1", -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name = c.sqlite3_column_text(stmt, 0);
        try std.testing.expectEqualStrings("Alice", std.mem.span(name));
    } else return error.NotFound;
}
