const std = @import("std");
const c = @import("axion").sqlite.c;
const DB = @import("axion").DB;
const AxionVTab = @import("axion").sqlite.vtab;

test "Savepoints and Nested Transactions" {
    const db_path = "test_savepoint_db";
    std.fs.cwd().deleteTree(db_path) catch {};
    defer std.fs.cwd().deleteTree(db_path) catch {};

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.SQLiteOpenFailed;
    defer _ = c.sqlite3_close(db);

    if (@import("axion").sqlite.vtab.register(db) != c.SQLITE_OK) return error.ModuleRegistrationFailed;

    const sql = "CREATE VIRTUAL TABLE users USING axion('" ++ db_path ++ "', 'NORMAL', 'id INT PRIMARY KEY, name TEXT')";
    if (c.sqlite3_exec(db, sql, null, null, null) != c.SQLITE_OK) return error.CreateTableFailed;

    // 1. Insert Alice (Base)
    _ = c.sqlite3_exec(db, "INSERT INTO users VALUES (1, 'Alice');", null, null, null);

    // 2. Transaction with Savepoints
    _ = c.sqlite3_exec(db, "BEGIN;", null, null, null);
    _ = c.sqlite3_exec(db, "INSERT INTO users VALUES (2, 'Bob');", null, null, null);
    
    // Savepoint 1
    _ = c.sqlite3_exec(db, "SAVEPOINT sp1;", null, null, null);
    _ = c.sqlite3_exec(db, "INSERT INTO users VALUES (3, 'Charlie');", null, null, null);
    _ = c.sqlite3_exec(db, "UPDATE users SET name = 'Alice 2' WHERE id = 1;", null, null, null);
    
    // Verify Charlie exists
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT count(*) FROM users WHERE name='Charlie'", -1, &stmt, null) == c.SQLITE_OK) {
            _ = c.sqlite3_step(stmt);
            try std.testing.expectEqual(1, c.sqlite3_column_int64(stmt, 0));
            _ = c.sqlite3_finalize(stmt);
        }
    }

    // Rollback to sp1
    _ = c.sqlite3_exec(db, "ROLLBACK TO sp1;", null, null, null);
    
    // Verify Charlie is GONE, Alice is restored
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT count(*) FROM users WHERE name='Charlie'", -1, &stmt, null) == c.SQLITE_OK) {
            _ = c.sqlite3_step(stmt);
            try std.testing.expectEqual(0, c.sqlite3_column_int64(stmt, 0));
            _ = c.sqlite3_finalize(stmt);
        }
        
        if (c.sqlite3_prepare_v2(db, "SELECT name FROM users WHERE id=1", -1, &stmt, null) == c.SQLITE_OK) {
            _ = c.sqlite3_step(stmt);
            const name = c.sqlite3_column_text(stmt, 0);
            try std.testing.expectEqualStrings("Alice", std.mem.span(name));
            _ = c.sqlite3_finalize(stmt);
        }
    }
    
    // Verify Bob remains
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT count(*) FROM users WHERE name='Bob'", -1, &stmt, null) == c.SQLITE_OK) {
            _ = c.sqlite3_step(stmt);
            try std.testing.expectEqual(1, c.sqlite3_column_int64(stmt, 0));
            _ = c.sqlite3_finalize(stmt);
        }
    }

    // Commit
    _ = c.sqlite3_exec(db, "COMMIT;", null, null, null);
    
    // Re-Verify persistence
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT count(*) FROM users", -1, &stmt, null) == c.SQLITE_OK) {
            _ = c.sqlite3_step(stmt);
            try std.testing.expectEqual(2, c.sqlite3_column_int64(stmt, 0)); // Alice + Bob
            _ = c.sqlite3_finalize(stmt);
        }
    }
}
