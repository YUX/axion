const std = @import("std");
const Schema = @import("schema.zig");

pub fn parseSqliteSchema(alloc: std.mem.Allocator, sql: []const u8, table_name: []const u8) !*Schema.TableSchema {
    var schema = try alloc.create(Schema.TableSchema);
    schema.* = try Schema.TableSchema.init(alloc, table_name);
    errdefer {
        schema.deinit();
        alloc.destroy(schema);
    }

    var has_pk = false;
    var i: usize = 0;
    while (i < sql.len) {
        const start = i;
        var depth: usize = 0;
        var end = sql.len;

        var j = i;
        while (j < sql.len) : (j += 1) {
            const current_char = sql[j];
            if (current_char == '(') depth += 1;
            if (current_char == ')') {
                if (depth > 0) depth -= 1;
            }
            if (current_char == ',' and depth == 0) {
                end = j;
                break;
            }
        }

        const token_raw = sql[start..end];
        i = if (end == sql.len) end else end + 1;

        const token = std.mem.trim(u8, token_raw, " \n\r\t");
        if (token.len == 0) continue;

        // Handle INDEX(col1, col2) or UNIQUE INDEX(col1)
        if (std.mem.indexOf(u8, token, "INDEX(") != null) {
            const is_unique = std.mem.startsWith(u8, token, "UNIQUE");
            const open_paren = std.mem.indexOf(u8, token, "(") orelse continue;
            const close_paren = std.mem.lastIndexOf(u8, token, ")") orelse continue;

            if (close_paren < open_paren) continue;

            const inner = token[open_paren + 1 .. close_paren];

            var col_names = std.ArrayListUnmanaged([]const u8){};
            defer col_names.deinit(alloc);

            var split = std.mem.tokenizeAny(u8, inner, ",");
            while (split.next()) |part| {
                try col_names.append(alloc, std.mem.trim(u8, part, " \n\r\t"));
            }

            var name_buf = std.ArrayListUnmanaged(u8){};
            defer name_buf.deinit(alloc);
            try name_buf.appendSlice(alloc, if (is_unique) "uidx_" else "idx_");
            try name_buf.appendSlice(alloc, schema.name);
            for (col_names.items) |cn| {
                try name_buf.appendSlice(alloc, "_");
                try name_buf.appendSlice(alloc, cn);
            }

            try schema.addIndex(name_buf.items, col_names.items, is_unique);
            continue;
        }

        var parts = std.mem.tokenizeAny(u8, token, " \n\r\t");
        const name = parts.next() orelse continue;
        const type_str_in = parts.next() orelse "BLOB";
        var is_pk = false;
        var is_unique_col = false;

        while (parts.next()) |p| {
            if (std.mem.eql(u8, p, "PRIMARY") or std.mem.eql(u8, p, "KEY") or std.mem.eql(u8, p, "PK")) {
                is_pk = true;
            }
            if (std.mem.eql(u8, p, "UNIQUE")) {
                is_unique_col = true;
            }
        }

        var ctype: Schema.ColumnType = .Blob;
        if (std.ascii.eqlIgnoreCase(type_str_in, "INT") or std.ascii.eqlIgnoreCase(type_str_in, "INTEGER")) ctype = .Integer;
        if (std.ascii.eqlIgnoreCase(type_str_in, "REAL") or std.ascii.eqlIgnoreCase(type_str_in, "FLOAT")) ctype = .Float;
        if (std.ascii.eqlIgnoreCase(type_str_in, "TEXT")) ctype = .Text;

        if (is_pk) {
            if (has_pk) {}
            has_pk = true;
        }

        try schema.addColumn(name, ctype, is_pk);

        if (is_unique_col and !is_pk) {
            // Create implicit unique index for this column
            var name_buf = std.ArrayListUnmanaged(u8){};
            defer name_buf.deinit(alloc);
            try name_buf.appendSlice(alloc, "uidx_");
            try name_buf.appendSlice(alloc, schema.name);
            try name_buf.appendSlice(alloc, "_");
            try name_buf.appendSlice(alloc, name);

            const cols = [_][]const u8{name};
            try schema.addIndex(name_buf.items, &cols, true);
        }
    }
    return schema;
}
