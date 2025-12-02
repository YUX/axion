const std = @import("std");
const c = @import("axion").sqlite.c;
const DB = @import("axion").DB;
const AxionVTab = @import("axion").sqlite.vtab;

test "Secondary Indexing" {
    const db_path = "test_idx_db";
    std.fs.cwd().deleteTree(db_path) catch {};
    defer std.fs.cwd().deleteTree(db_path) catch {};

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.SQLiteOpenFailed;
    defer _ = c.sqlite3_close(db);

    if (@import("axion").sqlite.vtab.register(db) != c.SQLITE_OK) return error.ModuleRegistrationFailed;

    // 1. Create Table with Index
    // Syntax: INDEX(col_name)
    const sql = "CREATE VIRTUAL TABLE users USING axion('" ++ db_path ++ "', 'NORMAL', 'id INT PRIMARY KEY, email TEXT, INDEX(email)')";
    if (c.sqlite3_exec(db, sql, null, null, null) != c.SQLITE_OK) {
        std.debug.print("Create Error: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.CreateTableFailed;
    }

    // 2. Insert Data
    _ = c.sqlite3_exec(db, "INSERT INTO users (id, email) VALUES (1, 'alice@example.com');", null, null, null);
    _ = c.sqlite3_exec(db, "INSERT INTO users (id, email) VALUES (2, 'bob@example.com');", null, null, null);
    _ = c.sqlite3_exec(db, "INSERT INTO users (id, email) VALUES (3, 'charlie@example.com');", null, null, null);

    // 3. Query using Index (Point Lookup)
    // Note: Query planner integration is NOT yet implemented, so this will do a full scan.
    // BUT we are testing if the index MAINTENANCE works (i.e. no crash on insert/update).
    // Later we will verify index usage.
    
    // 4. Update Data (Update Indexed Column)
    // Bob -> bob.new@example.com
    if (c.sqlite3_exec(db, "UPDATE users SET email = 'bob.new@example.com' WHERE id = 2;", null, null, null) != c.SQLITE_OK) {
        return error.UpdateFailed;
    }

    // Verify Update via Primary Key
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT email FROM users WHERE id = 2", -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const email = c.sqlite3_column_text(stmt, 0);
            try std.testing.expectEqualStrings("bob.new@example.com", std.mem.span(email));
        } else return error.MissingRow;
    }
    
    // 5. Delete Data (Delete Indexed Row)
    // Delete Alice
    if (c.sqlite3_exec(db, "DELETE FROM users WHERE id = 1;", null, null, null) != c.SQLITE_OK) {
        return error.DeleteFailed;
    }
    
    // Verify Delete
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT count(*) FROM users", -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const count = c.sqlite3_column_int64(stmt, 0);
            try std.testing.expectEqual(2, count); // Bob + Charlie
        }
    }
}
