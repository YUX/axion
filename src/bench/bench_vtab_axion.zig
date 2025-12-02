const std = @import("std");
const Config = @import("bench_config.zig");
const vtab = @import("axion").sqlite.vtab;
const c = @import("axion").sqlite.c;
const DB = @import("axion").DB;
const c_sys = @cImport(@cInclude("unistd.h"));

var ops_count = std.atomic.Value(usize).init(0);
var should_stop = std.atomic.Value(bool).init(false);

fn exec(db: ?*c.sqlite3, sql: []const u8) c_int {
    return c.sqlite3_exec(db, sql.ptr, null, null, null);
}

const WAL = @import("axion").WAL;

fn worker(workload: Config.Workload, seed: u64, key_count: usize, mode_str: []const u8) void {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) {
        std.debug.print("Thread {}: sqlite3_open failed\n", .{seed});
        return;
    }
    defer _ = c.sqlite3_close(db);

    if (vtab.register(db) != c.SQLITE_OK) {
        std.debug.print("Thread {}: vtab register failed\n", .{seed});
        return;
    }

    var sql_buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&sql_buf, "CREATE VIRTUAL TABLE t1 USING axion('{s}', '{s}');", .{Config.DB_PATH_VTAB, mode_str}) catch return;
    if (exec(db, sql) != c.SQLITE_OK) {
        const err = c.sqlite3_errmsg(db);
        std.debug.print("Thread {}: create vtable failed: {s}\n", .{seed, err});
        return;
    }

    var rng = std.Random.DefaultPrng.init(seed);
    var random = rng.random();
    
    var k_buf: [64]u8 = undefined;
    var v_buf: [64]u8 = undefined;
    
    var seq_counter: usize = seed * 1000000;

    var stmt_insert: ?*c.sqlite3_stmt = null;
    var stmt_read: ?*c.sqlite3_stmt = null;
    var stmt_scan: ?*c.sqlite3_stmt = null;

    // Prepare Statements
    if (c.sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO t1(key, value) VALUES (?, ?);", -1, &stmt_insert, null) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt_insert);

    if (c.sqlite3_prepare_v2(db, "SELECT value FROM t1 WHERE key = ?;", -1, &stmt_read, null) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt_read);

    if (c.sqlite3_prepare_v2(db, "SELECT * FROM t1 WHERE key >= ? LIMIT 100;", -1, &stmt_scan, null) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt_scan);

    while (!should_stop.load(.monotonic)) {
        switch (workload) {
            .Write => {
                const k = random.intRangeAtMost(usize, 0, key_count);
                const k_str = std.fmt.bufPrintZ(&k_buf, Config.KEY_FMT, .{k}) catch continue;
                const v_str = std.fmt.bufPrintZ(&v_buf, Config.VAL_FMT, .{k}) catch continue;
                
                _ = c.sqlite3_reset(stmt_insert);
                _ = c.sqlite3_bind_text(stmt_insert, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                _ = c.sqlite3_bind_text(stmt_insert, 2, v_str.ptr, -1, c.SQLITE_STATIC);
                _ = c.sqlite3_step(stmt_insert);
            },
            .SeqWrite => {
                const k = seq_counter;
                seq_counter += 1;
                const k_str = std.fmt.bufPrintZ(&k_buf, Config.SEQ_KEY_FMT, .{k}) catch continue;
                const v_str = std.fmt.bufPrintZ(&v_buf, Config.VAL_FMT, .{k}) catch continue;
                
                _ = c.sqlite3_reset(stmt_insert);
                _ = c.sqlite3_bind_text(stmt_insert, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                _ = c.sqlite3_bind_text(stmt_insert, 2, v_str.ptr, -1, c.SQLITE_STATIC);
                _ = c.sqlite3_step(stmt_insert);
            },
            .Read => {
                const k = random.intRangeAtMost(usize, 0, key_count);
                const k_str = std.fmt.bufPrintZ(&k_buf, Config.KEY_FMT, .{k}) catch continue;
                
                _ = c.sqlite3_reset(stmt_read);
                _ = c.sqlite3_bind_text(stmt_read, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                if (c.sqlite3_step(stmt_read) == c.SQLITE_ROW) {
                    // Consume result if needed (benchmark usually just steps)
                    _ = c.sqlite3_column_text(stmt_read, 0);
                }
            },
            .RangeScan => {
                 const k = random.intRangeAtMost(usize, 0, key_count);
                 const k_str = std.fmt.bufPrintZ(&k_buf, Config.KEY_FMT, .{k}) catch continue;
                 
                 _ = c.sqlite3_reset(stmt_scan);
                 _ = c.sqlite3_bind_text(stmt_scan, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                 while (c.sqlite3_step(stmt_scan) == c.SQLITE_ROW) {
                     // Consume
                 }
            },
            .Mix => {
                 if (random.boolean()) {
                     const k = random.intRangeAtMost(usize, 0, key_count);
                     const k_str = std.fmt.bufPrintZ(&k_buf, Config.KEY_FMT, .{k}) catch continue;
                     const v_str = std.fmt.bufPrintZ(&v_buf, Config.VAL_FMT, .{k}) catch continue;
                     
                     _ = c.sqlite3_reset(stmt_insert);
                     _ = c.sqlite3_bind_text(stmt_insert, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                     _ = c.sqlite3_bind_text(stmt_insert, 2, v_str.ptr, -1, c.SQLITE_STATIC);
                     _ = c.sqlite3_step(stmt_insert);
                 } else {
                     const k = random.intRangeAtMost(usize, 0, key_count);
                     const k_str = std.fmt.bufPrintZ(&k_buf, Config.KEY_FMT, .{k}) catch continue;
                     
                     _ = c.sqlite3_reset(stmt_read);
                     _ = c.sqlite3_bind_text(stmt_read, 1, k_str.ptr, -1, c.SQLITE_STATIC);
                     if (c.sqlite3_step(stmt_read) == c.SQLITE_ROW) {
                         _ = c.sqlite3_column_text(stmt_read, 0);
                     }
                 }
            }
        }
        _ = ops_count.fetchAdd(1, .monotonic);
    }
}

fn runBenchmark(allocator: std.mem.Allocator, mode: WAL.SyncMode, workload: Config.Workload, config: Config.BenchmarkConfig) !void {
    std.debug.print("  [VTab] {s} - {s}...\n", .{
        switch(mode) {
            .Full => "FULL",
            .Normal => "NORMAL",
            .Off => "OFF"
        },
        @tagName(workload)
    });
    
    std.fs.cwd().deleteTree(Config.DB_PATH_VTAB) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Failed to delete old DB: {}\n", .{err});
            return err;
        }
    };

    // Pre-populate using VTab INSERTs (slower but ensures correct format)
    if (workload == .Read or workload == .Mix or workload == .RangeScan) {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.Openerror;
        defer _ = c.sqlite3_close(db);
        
        if (vtab.register(db) != c.SQLITE_OK) return error.RegisterError;
        
        // We use OFF sync for pre-pop speed
        var sql_buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrintZ(&sql_buf, "CREATE VIRTUAL TABLE t1 USING axion('{s}', 'OFF');", .{Config.DB_PATH_VTAB}) catch return error.FmtError;
        if (exec(db, sql) != c.SQLITE_OK) return error.CreateError;
        
        _ = c.sqlite3_exec(db, "BEGIN;", null, null, null);
        
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO t1(key, value) VALUES (?, ?);", -1, &stmt, null) != c.SQLITE_OK) return error.PrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        var i: usize = 0;
        var k_buf: [64]u8 = undefined;
        var v_buf: [64]u8 = undefined;
        while (i < config.key_count) : (i += 1) {
            const k = std.fmt.bufPrintZ(&k_buf, Config.KEY_FMT, .{i}) catch unreachable;
            const v = std.fmt.bufPrintZ(&v_buf, Config.VAL_FMT, .{i}) catch unreachable;
            
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_bind_text(stmt, 1, k.ptr, -1, c.SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 2, v.ptr, -1, c.SQLITE_STATIC);
            _ = c.sqlite3_step(stmt);
            
            if (i % 1000 == 0) {
                _ = c.sqlite3_exec(db, "COMMIT;", null, null, null);
                _ = c.sqlite3_exec(db, "BEGIN;", null, null, null);
            }
        }
        _ = c.sqlite3_exec(db, "COMMIT;", null, null, null);
    }

    // We open DB just to ensure it exists for SQLite VTab (though vtab connects internally)
    // Actually, the benchmark tests VTab performance, so we need SQLite connection.
    // But the `worker` function uses `db: *DB`? No, wait.
    // Let's check worker signature in `bench_vtab_axion.zig`.
    // It uses `*c.sqlite3`.
    
    // The `runBenchmark` function opens `DB`?
    // Ah, `bench_vtab_axion.zig` likely opens `DB` to ensure path exists? 
    // Or it opens SQLite?
    
    // Let's look at the context provided by read_file (implied, or I can check).
    // The error was on line 118.
    // Line 118 was `DB.open`.
    
    // If I look at my previous thought, I just assumed `bench_vtab_axion` uses `DB.open`.
    // Yes, the error confirms it.
    
    // Wait, `bench_vtab_axion` tests VTab. Why does it open `DB` directly?
    // Ah, for pre-population (Native is faster than VTab INSERTs).
    // But what about the main run?
    // The main run uses SQLite connection.
    
    // Let's fix the compilation error first.
    
    // ... (Skipping thought, applied fix in previous turn for line 118) ...
    
    // Now I need to fix the other `DB.open` if it exists?
    // Or maybe `bench_vtab_axion` DOES NOT open `DB` for the main run?
    // Let's read the file to be sure.


    ops_count.store(0, .monotonic);
    should_stop.store(false, .monotonic);

    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(allocator);

    const mode_str = switch(mode) {
        .Full => "FULL",
        .Normal => "NORMAL",
        .Off => "OFF"
    };

    var i: usize = 0;
    while (i < config.threads) : (i += 1) {
        const t = try std.Thread.spawn(.{}, worker, .{ workload, i, config.key_count, mode_str });
        try threads.append(allocator, t);
    }

    _ = c_sys.sleep(@intCast(config.duration));
    should_stop.store(true, .release);

    for (threads.items) |t| t.join();

    const total = ops_count.load(.acquire);
    const qps = total / config.duration;
    std.debug.print("  Result: {d} ops/sec\n", .{qps});

    std.fs.cwd().deleteTree(Config.DB_PATH_VTAB) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Failed to delete old DB: {}\n", .{err});
            return err;
        }
    };
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    std.debug.print("Running Axion VTab Benchmarks\n", .{});
    
    const config = try Config.BenchmarkConfig.parseArgs(allocator);
    
    const modes = [_]WAL.SyncMode{ .Full, .Normal, .Off };
    const workloads = [_]Config.Workload{ .Write, .SeqWrite, .Read, .RangeScan, .Mix };

    for (modes) |m| {
        if (config.filter_mode) |fm| {
             const match = switch (fm) {
                 .Full => m == .Full,
                 .Normal => m == .Normal,
                 .Off => m == .Off,
             };
             if (!match) continue;
        }

        for (workloads) |w| {
            if (config.filter_workload) |fw| {
                 if (fw != w) continue;
            }
            try runBenchmark(allocator, m, w, config);
        }
    }
}