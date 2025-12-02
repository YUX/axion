const std = @import("std");
const c = @import("axion").sqlite.c;
const DB = @import("axion").DB;
const AxionVTab = @import("axion").sqlite.vtab;

test "Secondary Index Range Scan" {
    const db_path = "test_secondary_idx_db";
    std.fs.cwd().deleteTree(db_path) catch {};
    defer std.fs.cwd().deleteTree(db_path) catch {};

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.SQLiteOpenFailed;
    defer _ = c.sqlite3_close(db);

    if (@import("axion").sqlite.vtab.register(db) != c.SQLITE_OK) return error.ModuleRegistrationFailed;

    // 1. Create Table with Index
    // Schema: id INT PK, age INT, name TEXT
    // Index: INDEX(age)
    const rc = c.sqlite3_exec(db, "CREATE VIRTUAL TABLE users USING axion('" ++ db_path ++ "', 'NORMAL', 'id INT PK, age INT, name TEXT, INDEX(age)')", null, null, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Create Error: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.CreateTableFailed;
    }

    // 2. Insert Data
    _ = c.sqlite3_exec(db, "INSERT INTO users VALUES (1, 30, 'User30');", null, null, null);
    _ = c.sqlite3_exec(db, "INSERT INTO users VALUES (2, 20, 'User20');", null, null, null);
    _ = c.sqlite3_exec(db, "INSERT INTO users VALUES (3, 40, 'User40');", null, null, null);
    _ = c.sqlite3_exec(db, "INSERT INTO users VALUES (4, 25, 'User25');", null, null, null);

    // 3. Query using Index Range (20 <= age <= 30)
    // Should return User20, User25, User30

    // Check Query Plan
    {
        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN SELECT id, age FROM users WHERE age >= 20 AND age <= 30 ORDER BY age", -1, &stmt, null);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const detail = c.sqlite3_column_text(stmt, 3);
            std.debug.print("PLAN: {s}\n", .{detail});
        }
        _ = c.sqlite3_finalize(stmt);
    }

    var stmt: ?*c.sqlite3_stmt = null;
    // FORCE INDEX usage if possible, or rely on stats.
    if (c.sqlite3_prepare_v2(db, "SELECT id, age FROM users WHERE age >= 20 AND age <= 30 ORDER BY age", -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("Prepare Error: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Expect: 20, 25, 30
    var rows: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const age = c.sqlite3_column_int64(stmt, 1);
        if (rows == 0) try std.testing.expectEqual(20, age);
        if (rows == 1) try std.testing.expectEqual(25, age);
        if (rows == 2) try std.testing.expectEqual(30, age);
        rows += 1;
    }

    try std.testing.expectEqual(3, rows);
}
