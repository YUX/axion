const std = @import("std");
const c = @import("axion").sqlite.c;
const DB = @import("axion").DB;
const AxionVTab = @import("axion").sqlite.vtab;

// A simple test to verify schema support integration in VTab
test "SQLite VTab Schema Integration" {
    const db_path = "test_vtab_schema_db";
    std.fs.cwd().deleteTree(db_path) catch {};
    defer std.fs.cwd().deleteTree(db_path) catch {};

    // Open In-Memory SQLite
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) {
        return error.SQLiteOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    // Register Axion Module
    if (@import("axion").sqlite.vtab.register(db) != c.SQLITE_OK) return error.ModuleRegistrationFailed;

    // 1. Create Virtual Table with Schema
    // Note: using single quotes for arguments inside the SQL string
    var rc = c.sqlite3_exec(db, "CREATE VIRTUAL TABLE users USING axion('" ++ db_path ++ "', 'NORMAL', 'id INT PRIMARY KEY, name TEXT, age REAL')", null, null, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Create Error: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.CreateTableFailed;
    }

    // 2. Insert Data (Typed)
    rc = c.sqlite3_exec(db, "INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30.5);", null, null, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Insert Error: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.InsertFailed;
    }

    rc = c.sqlite3_exec(db, "INSERT INTO users (id, name, age) VALUES (2, 'Bob', 40.0);", null, null, null);
    if (rc != c.SQLITE_OK) {
         return error.InsertFailed;
    }

    // 3. Select Data (Point Lookup)
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT name, age FROM users WHERE id = 1", -1, &stmt, null) != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = c.sqlite3_column_text(stmt, 0);
            const age = c.sqlite3_column_double(stmt, 1);
            
            const name_slice = std.mem.span(name);
            try std.testing.expectEqualStrings("Alice", name_slice);
            try std.testing.expectApproxEqAbs(30.5, age, 0.001);
        } else {
            return error.NotFound;
        }
    }

    // 4. Select Data (Full Scan)
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT id, name FROM users ORDER BY id", -1, &stmt, null) != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        // Row 1
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int64(stmt, 0);
            const name = c.sqlite3_column_text(stmt, 1);
            try std.testing.expectEqual(1, id);
            try std.testing.expectEqualStrings("Alice", std.mem.span(name));
        } else return error.MissingRow;

        // Row 2
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int64(stmt, 0);
            const name = c.sqlite3_column_text(stmt, 1);
            try std.testing.expectEqual(2, id);
            try std.testing.expectEqualStrings("Bob", std.mem.span(name));
        } else return error.MissingRow;
    }
    
    // 5. Update Data
    rc = c.sqlite3_exec(db, "UPDATE users SET name = 'Alice Cooper' WHERE id = 1;", null, null, null);
    if (rc != c.SQLITE_OK) return error.UpdateFailed;
    
    // Verify Update
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT name FROM users WHERE id = 1", -1, &stmt, null) != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = c.sqlite3_column_text(stmt, 0);
            try std.testing.expectEqualStrings("Alice Cooper", std.mem.span(name));
        } else return error.UpdateVerificationFailed;
    }
    
    // 6. Delete Data
    rc = c.sqlite3_exec(db, "DELETE FROM users WHERE id = 2;", null, null, null);
    if (rc != c.SQLITE_OK) return error.DeleteFailed;
    
    // Verify Delete
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT count(*) FROM users", -1, &stmt, null) != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const count = c.sqlite3_column_int64(stmt, 0);
            try std.testing.expectEqual(1, count);
        }
    }
}
