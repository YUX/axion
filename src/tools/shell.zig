const std = @import("std");
const c = @import("axion").sqlite.c;
const vtab = @import("axion").sqlite.vtab;
const metrics = @import("axion").metrics;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var db_path: ?[]const u8 = null;
    var config_file: ?[]const u8 = null;
    var mem_mb: ?usize = null;
    var cache_mb: ?usize = null;
    var compaction_threads: ?usize = null;
    var sql_command: ?[]const u8 = null;
    var help_requested = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help_requested = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (i + 1 < args.len) {
                config_file = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--mem")) {
            if (i + 1 < args.len) {
                mem_mb = std.fmt.parseInt(usize, args[i + 1], 10) catch null;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--cache")) {
            if (i + 1 < args.len) {
                cache_mb = std.fmt.parseInt(usize, args[i + 1], 10) catch null;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--compaction-threads")) {
            if (i + 1 < args.len) {
                compaction_threads = std.fmt.parseInt(usize, args[i + 1], 10) catch null;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--sql")) {
            if (i + 1 < args.len) {
                sql_command = args[i + 1];
                i += 1;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (db_path == null) db_path = arg;
        }
    }

    if (help_requested) {
        printUsage();
        return;
    }

    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(":memory:", &db);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Can't open database: {s}\n", .{c.sqlite3_errmsg(db)});
        return;
    }
    defer _ = c.sqlite3_close(db);

    // Register Axion
    if (vtab.register(db) != c.SQLITE_OK) {
        std.debug.print("Failed to register Axion module\n", .{});
        return;
    }

    // Auto-mount DB if path provided
    if (db_path) |path| {
        var opts_buf = std.ArrayListUnmanaged(u8){};
        defer opts_buf.deinit(allocator);

        if (config_file) |cf| {
            const s = try std.fmt.allocPrint(allocator, "config_file={s};", .{cf});
            defer allocator.free(s);
            try opts_buf.appendSlice(allocator, s);
        }
        if (mem_mb) |m| {
            const s = try std.fmt.allocPrint(allocator, "memtable_mb={d};", .{m});
            defer allocator.free(s);
            try opts_buf.appendSlice(allocator, s);
        }
        if (cache_mb) |cm| {
            const s = try std.fmt.allocPrint(allocator, "cache_mb={d};", .{cm});
            defer allocator.free(s);
            try opts_buf.appendSlice(allocator, s);
        }
        if (compaction_threads) |t| {
            const s = try std.fmt.allocPrint(allocator, "compaction_threads={d};", .{t});
            defer allocator.free(s);
            try opts_buf.appendSlice(allocator, s);
        }

        const sql = try std.fmt.allocPrint(allocator, "CREATE VIRTUAL TABLE data USING axion('{s}', 'NORMAL', '', '{s}');", .{ path, opts_buf.items });
        defer allocator.free(sql);

        execute(db, sql);
        std.debug.print("Database mounted as table 'data'.\n", .{});
    }

    if (sql_command) |sql| {
        execute(db, sql);
    } else {
        // REPL Mode
        const stdin_file = std.fs.cwd().openFile("/dev/stdin", .{}) catch |err| {
            std.debug.print("Failed to open stdin: {}\n", .{err});
            return;
        };
        defer stdin_file.close();
        
        var buf: [4096]u8 = undefined;
        std.debug.print("Axion Shell.\nType SQL commands ending with ';'. Type .stats for metrics. Type .exit to quit.\n", .{});
        
        var query_buf = std.ArrayListUnmanaged(u8){};
        defer query_buf.deinit(allocator);

        var partial_buf = std.ArrayListUnmanaged(u8){};
        defer partial_buf.deinit(allocator);

        while (true) {
            if (query_buf.items.len == 0 and partial_buf.items.len == 0) {
                std.debug.print("axion> ", .{});
            } else if (partial_buf.items.len == 0) {
                std.debug.print("   ...> ", .{});
            }

            const n = stdin_file.read(&buf) catch |err| {
                std.debug.print("Read error: {}\n", .{err});
                break;
            };
            if (n == 0) break; // EOF

            try partial_buf.appendSlice(allocator, buf[0..n]);

            // Process lines from partial_buf
            while (true) {
                const items = partial_buf.items;
                if (std.mem.indexOf(u8, items, "\n")) |idx| {
                    const line = items[0..idx];
                    const trimmed = std.mem.trim(u8, line, " \r\t");
                    
                    if (std.mem.eql(u8, trimmed, ".exit") or std.mem.eql(u8, trimmed, ".quit")) return;
                    if (std.mem.eql(u8, trimmed, ".stats")) {
                        printMetrics();
                    } else if (trimmed.len > 0) {
                        try query_buf.appendSlice(allocator, trimmed);
                        if (std.mem.endsWith(u8, trimmed, ";")) {
                             execute(db, query_buf.items);
                             query_buf.clearRetainingCapacity();
                        } else {
                             try query_buf.append(allocator, ' ');
                        }
                    }
                    
                    try partial_buf.replaceRange(allocator, 0, idx + 1, &.{});
                } else {
                    break;
                }
            }
        }
    }
}

fn printUsage() void {
    std.debug.print(
        "Usage: axion [options] [db_path]\n" ++
        "\n" ++
        "Options:\n" ++
        "  --config <file>       Load configuration from file\n" ++
        "  --mem <MB>            Set memtable size limit (overrides config)\n" ++
        "  --cache <MB>          Set block cache size (overrides config)\n" ++
        "  --compaction-threads <num> Set number of background compaction threads (default: 1)\n" ++
        "  --sql <command>       Execute SQL command and exit\n" ++
        "  --help, -h            Show this help\n" ++
        "\n" ++
        "If db_path is provided, the database is mounted as table 'data'.\n"
        , .{}
    );
}

fn printMetrics() void {
    const m = metrics.global;
    std.debug.print(
        "--- Axion Metrics ---\n" ++
        "Puts: {}\n" ++
        "Gets: {}\n" ++
        "Iterators: {}\n" ++
        "Compactions: {}\n" ++
        "Flushes: {}\n" ++
        "BlockCache Hits: {}\n" ++
        "BlockCache Misses: {}\n" ++
        "Txn Success: {}\n" ++
        "Txn Conflict: {}\n" ++
        "---------------------\n"
        , .{
            m.puts.load(.monotonic),
            m.gets.load(.monotonic),
            m.iterators.load(.monotonic),
            m.compactions.load(.monotonic),
            m.flushes.load(.monotonic),
            m.block_cache_hits.load(.monotonic),
            m.block_cache_misses.load(.monotonic),
            m.txn_success.load(.monotonic),
            m.txn_conflict.load(.monotonic),
        }
    );
}

fn execute(db: ?*c.sqlite3, sql: []const u8) void {
    var errMsg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, sql.ptr, callback, null, &errMsg);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Error: {s}\n", .{errMsg});
        c.sqlite3_free(errMsg);
    }
}

fn callback(notUsed: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, azColName: [*c][*c]u8) callconv(.c) c_int {
    _ = notUsed;
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        const col = if (azColName[i] != null) std.mem.span(azColName[i]) else "NULL";
        const val = if (argv[i] != null) std.mem.span(argv[i]) else "NULL";
        std.debug.print("{s} = {s}", .{col, val});
        if (i < argc - 1) std.debug.print(" | ", .{});
    }
    std.debug.print("\n", .{});
    return 0;
}