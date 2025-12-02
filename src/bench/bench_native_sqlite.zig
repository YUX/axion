const std = @import("std");
const Config = @import("bench_config.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("unistd.h");
});

var ops_count = std.atomic.Value(usize).init(0);
var should_stop = std.atomic.Value(bool).init(false);

fn panic(msg: []const u8) noreturn {
    std.debug.print("Error: {s}\n", . { msg });
    std.process.exit(1);
}

fn worker(workload: Config.Workload, seed: u64, key_count: usize) void {
    var db: ?*c.sqlite3 = null;
    
    // Open connection to SAME db file
    const rc = c.sqlite3_open(Config.DB_PATH_SQLITE, &db);
    if (rc != c.SQLITE_OK) return;
    defer _ = c.sqlite3_close(db);

    _ = c.sqlite3_busy_timeout(db, 5000);

    var rng = std.Random.DefaultPrng.init(seed);
    var random = rng.random();

    var stmt_insert: ?*c.sqlite3_stmt = null;
    var stmt_read: ?*c.sqlite3_stmt = null;
    var stmt_scan: ?*c.sqlite3_stmt = null;

    _ = c.sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO bench (key, value) VALUES (?, ?)", -1, &stmt_insert, null);
    defer _ = c.sqlite3_finalize(stmt_insert);

    _ = c.sqlite3_prepare_v2(db, "SELECT value FROM bench WHERE key = ?", -1, &stmt_read, null);
    defer _ = c.sqlite3_finalize(stmt_read);
    
    _ = c.sqlite3_prepare_v2(db, "SELECT key, value FROM bench WHERE key >= ? LIMIT 100", -1, &stmt_scan, null);
    defer _ = c.sqlite3_finalize(stmt_scan);

    var buf_key: [64]u8 = undefined;
    var buf_val: [128]u8 = undefined;
    var seq_counter: usize = seed * 1000000;

    while (!should_stop.load(.monotonic)) {
        switch (workload) {
            .Write => {
                const k = random.intRangeAtMost(usize, 0, key_count);
                const k_str = std.fmt.bufPrintZ(&buf_key, Config.KEY_FMT, . { k }) catch unreachable;
                const v_str = std.fmt.bufPrintZ(&buf_val, Config.VAL_FMT, . { k }) catch unreachable;

                _ = c.sqlite3_reset(stmt_insert);
                _ = c.sqlite3_bind_text(stmt_insert, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                _ = c.sqlite3_bind_text(stmt_insert, 2, v_str.ptr, -1, c.SQLITE_STATIC);
                _ = c.sqlite3_step(stmt_insert);
            },
            .SeqWrite => {
                const k = seq_counter;
                seq_counter += 1;
                const k_str = std.fmt.bufPrintZ(&buf_key, Config.SEQ_KEY_FMT, . { k }) catch unreachable;
                const v_str = std.fmt.bufPrintZ(&buf_val, Config.VAL_FMT, . { k }) catch unreachable;

                _ = c.sqlite3_reset(stmt_insert);
                _ = c.sqlite3_bind_text(stmt_insert, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                _ = c.sqlite3_bind_text(stmt_insert, 2, v_str.ptr, -1, c.SQLITE_STATIC);
                _ = c.sqlite3_step(stmt_insert);
            },
            .Read => {
                const k = random.intRangeAtMost(usize, 0, key_count);
                const k_str = std.fmt.bufPrintZ(&buf_key, Config.KEY_FMT, . { k }) catch unreachable;

                _ = c.sqlite3_reset(stmt_read);
                _ = c.sqlite3_bind_text(stmt_read, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                if (c.sqlite3_step(stmt_read) == c.SQLITE_ROW) {
                    _ = c.sqlite3_column_text(stmt_read, 0);
                }
            },
             .RangeScan => {
                 const k = random.intRangeAtMost(usize, 0, key_count);
                 const k_str = std.fmt.bufPrintZ(&buf_key, Config.KEY_FMT, . { k }) catch unreachable;
                 
                 _ = c.sqlite3_reset(stmt_scan);
                 _ = c.sqlite3_bind_text(stmt_scan, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                 while (c.sqlite3_step(stmt_scan) == c.SQLITE_ROW) {
                     // consume
                 }
            },
            .Mix => {
                if (random.boolean()) {
                    const k = random.intRangeAtMost(usize, 0, key_count);
                    const k_str = std.fmt.bufPrintZ(&buf_key, Config.KEY_FMT, . { k }) catch unreachable;
                    const v_str = std.fmt.bufPrintZ(&buf_val, Config.VAL_FMT, . { k }) catch unreachable;
                    _ = c.sqlite3_reset(stmt_insert);
                    _ = c.sqlite3_bind_text(stmt_insert, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_bind_text(stmt_insert, 2, v_str.ptr, -1, c.SQLITE_STATIC);
                    _ = c.sqlite3_step(stmt_insert);
                } else {
                    const k = random.intRangeAtMost(usize, 0, key_count);
                    const k_str = std.fmt.bufPrintZ(&buf_key, Config.KEY_FMT, . { k }) catch unreachable;
                    _ = c.sqlite3_reset(stmt_read);
                    _ = c.sqlite3_bind_text(stmt_read, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                    if (c.sqlite3_step(stmt_read) == c.SQLITE_ROW) {}
                }
            }
        }
        _ = ops_count.fetchAdd(1, .monotonic);
    }
}

fn runBenchmark(allocator: std.mem.Allocator, mode: Config.Mode, workload: Config.Workload, config: Config.BenchmarkConfig) !void {
    const db_path = Config.DB_PATH_SQLITE;
    
    std.debug.print("  [SQLite] {s} - {s} (Threads: {}, Keys: {})...\n", .{
        switch(mode) {
            .Full => "FULL",
            .Normal => "NORMAL",
            .Off => "OFF"
        },
        @tagName(workload),
        config.threads,
        config.key_count,
    });

    // Clean previous
    std.fs.cwd().deleteFile(db_path) catch {};
    std.fs.cwd().deleteFile("bench_sqlite.db-wal") catch {};
    std.fs.cwd().deleteFile("bench_sqlite.db-shm") catch {};

    // Setup DB
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(db_path, &db);
    if (rc != c.SQLITE_OK) return;
    
    // Set PRAGMAs
    _ = c.sqlite3_exec(db, "PRAGMA journal_mode = WAL;", null, null, null);
    
    const sync_pragma = switch (mode) {
        .Full => "PRAGMA synchronous = FULL;",
        .Normal => "PRAGMA synchronous = NORMAL;",
        .Off => "PRAGMA synchronous = OFF;",
    };
    _ = c.sqlite3_exec(db, sync_pragma.ptr, null, null, null);

    // Init Schema
    _ = c.sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS bench (key TEXT PRIMARY KEY, value TEXT);", null, null, null);

    // Pre-populate
    if (workload == .Read or workload == .Mix or workload == .RangeScan) {
        _ = c.sqlite3_exec(db, "BEGIN;", null, null, null);
        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "INSERT INTO bench VALUES (?, ?)", -1, &stmt, null);
        
        var i: usize = 0;
        var k_buf: [64]u8 = undefined;
        var v_buf: [64]u8 = undefined;
        while (i < config.key_count) : (i += 1) {
            const k = std.fmt.bufPrintZ(&k_buf, Config.KEY_FMT, . { i }) catch unreachable;
            const v = std.fmt.bufPrintZ(&v_buf, Config.VAL_FMT, . { i }) catch unreachable;
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_bind_text(stmt, 1, k.ptr, -1, c.SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 2, v.ptr, -1, c.SQLITE_STATIC);
            _ = c.sqlite3_step(stmt);
        }
        _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_exec(db, "COMMIT;", null, null, null);
        _ = c.sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", null, null, null);
    }

    _ = c.sqlite3_close(db);

    ops_count.store(0, .monotonic);
    should_stop.store(false, .monotonic);

    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(allocator);

    var i: usize = 0;
    while (i < config.threads) : (i += 1) {
        const t = try std.Thread.spawn(.{}, worker, .{ workload, i, config.key_count });
        try threads.append(allocator, t);
    }

    _ = c.sleep(@intCast(config.duration));
    should_stop.store(true, .release);

    for (threads.items) |t| t.join();

    const total = ops_count.load(.acquire);
    const qps = total / config.duration;
    std.debug.print("  Result: {d} ops/sec\n", .{qps});

    std.fs.cwd().deleteFile(db_path) catch {};
    std.fs.cwd().deleteFile("bench_sqlite.db-wal") catch {};
    std.fs.cwd().deleteFile("bench_sqlite.db-shm") catch {};
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    std.debug.print("Running Native SQLite Benchmarks\n", .{});

    const config = try Config.BenchmarkConfig.parseArgs(allocator);

    const modes = [_]Config.Mode{ .Full, .Normal, .Off };
    const workloads = [_]Config.Workload{ .Write, .SeqWrite, .Read, .RangeScan, .Mix };

    for (modes) |m| {
        if (config.filter_mode) |fm| {
             if (fm != m) continue;
        }
        for (workloads) |w| {
            if (config.filter_workload) |fw| {
                 if (fw != w) continue;
             }
            try runBenchmark(allocator, m, w, config);
        }
    }
}