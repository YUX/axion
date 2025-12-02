const std = @import("std");
const Config = @import("bench_config.zig");
const DB = @import("axion").DB;
const WAL = @import("axion").WAL;

var ops_count = std.atomic.Value(usize).init(0);
var should_stop = std.atomic.Value(bool).init(false);

fn worker(db: *DB, workload: Config.Workload, seed: u64, key_count: usize) void {
    var rng = std.Random.DefaultPrng.init(seed);
    var random = rng.random();

    var buf_key: [64]u8 = undefined;
    var buf_val: [128]u8 = undefined;

    var seq_counter: usize = seed * 1000000;

    while (!should_stop.load(.monotonic)) {
        switch (workload) {
            .Write => {
                const k = random.intRangeAtMost(usize, 0, key_count);
                const key_str = std.fmt.bufPrint(&buf_key, Config.KEY_FMT, .{k}) catch unreachable;
                const val_str = std.fmt.bufPrint(&buf_val, Config.VAL_FMT, .{k}) catch unreachable;
                db.put(key_str, val_str) catch {};
            },
            .SeqWrite => {
                const k = seq_counter;
                seq_counter += 1;
                const key_str = std.fmt.bufPrint(&buf_key, Config.SEQ_KEY_FMT, .{k}) catch unreachable;
                const val_str = std.fmt.bufPrint(&buf_val, Config.VAL_FMT, .{k}) catch unreachable;
                db.put(key_str, val_str) catch {};
            },
            .Read => {
                const k = random.intRangeAtMost(usize, 0, key_count);
                const key_str = std.fmt.bufPrint(&buf_key, Config.KEY_FMT, .{k}) catch unreachable;
                if (db.get(key_str)) |maybe_val| {
                    if (maybe_val) |val| val.deinit();
                } else |_| {}
            },
            .RangeScan => {
                 const k = random.intRangeAtMost(usize, 0, key_count);
                 const key_str = std.fmt.bufPrint(&buf_key, Config.KEY_FMT, .{k}) catch unreachable;
                 
                 // Use ReadOnlyTransaction to match VTab performance (avoiding RW overhead)
                 const rot = db.tm.beginReadOnly();
                 defer db.tm.endReadOnly(rot);
                 
                 var iter = db.createIterator(rot.read_version) catch continue;
                 
                 // We must seek manually as DB.createIterator returns a raw MergedIterator
                 iter.seek(key_str) catch { iter.deinit(); continue; };
                 
                 var count: usize = 0;
                 while (count < 100) : (count += 1) {
                     if (iter.next() catch break) |_| {} else break;
                 }
                 iter.deinit();
            },
            .Mix => {
                if (random.boolean()) {
                    const k = random.intRangeAtMost(usize, 0, key_count);
                    const key_str = std.fmt.bufPrint(&buf_key, Config.KEY_FMT, .{k}) catch unreachable;
                    const val_str = std.fmt.bufPrint(&buf_val, Config.VAL_FMT, .{k}) catch unreachable;
                    db.put(key_str, val_str) catch {};
                } else {
                    const k = random.intRangeAtMost(usize, 0, key_count);
                    const key_str = std.fmt.bufPrint(&buf_key, Config.KEY_FMT, .{k}) catch unreachable;
                    if (db.get(key_str)) |maybe_val| {
                        if (maybe_val) |val| val.deinit();
                    } else |_| {}
                }
            }
        }
        _ = ops_count.fetchAdd(1, .monotonic);
    }
}

var is_finished = std.atomic.Value(bool).init(false);
var run_id = std.atomic.Value(u32).init(0);

fn runBenchmark(allocator: std.mem.Allocator, mode: WAL.SyncMode, workload: Config.Workload, config: Config.BenchmarkConfig) !void {
    const db_path = Config.DB_PATH_NATIVE;
    
    std.debug.print("  [Native] {s} - {s} (Threads: {}, Keys: {})...\n", .{
        switch(mode) {
            .Full => "FULL",
            .Normal => "NORMAL",
            .Off => "OFF"
        },
        @tagName(workload),
        config.threads,
        config.key_count,
    });
    
    std.fs.cwd().deleteTree(db_path) catch {};
    
    // Pre-populate using fast mode (Off) to avoid waiting forever on Full sync setup
    if (workload == .Read or workload == .Mix or workload == .RangeScan) {
        var db_prep = DB.open(allocator, db_path, .{ .wal_sync_mode = .Off }) catch return;
        
        var txn = try db_prep.beginTransaction();
        var i: usize = 0;
        var k_buf: [64]u8 = undefined;
        var v_buf: [64]u8 = undefined;
        while (i < config.key_count) : (i += 1) {
            const k = std.fmt.bufPrint(&k_buf, Config.KEY_FMT, .{i}) catch unreachable;
            const v = std.fmt.bufPrint(&v_buf, Config.VAL_FMT, .{i}) catch unreachable;
            try txn.put(k, v);
            if (i % 1000 == 0) {
                try txn.commit();
                txn.deinit();
                txn = try db_prep.beginTransaction();
            }
        }
        try txn.commit();
        txn.deinit();
        try db_prep.flushSync();
        db_prep.close();
    }

    var db = DB.open(allocator, db_path, .{ .wal_sync_mode = mode, .compaction_threads = config.compaction_threads }) catch return;

    ops_count.store(0, .monotonic);
    should_stop.store(false, .monotonic);
    is_finished.store(false, .monotonic);
    const current_run_id = run_id.fetchAdd(1, .monotonic) + 1;

    // Watchdog for hard timeout
    const watchdog = try std.Thread.spawn(.{}, struct {
        fn run(duration: u64, id: u32) void {
            const c = @cImport(@cInclude("unistd.h"));
            _ = c.sleep(@intCast(duration + 5));
            
            // Check if this is still the active run
            if (run_id.load(.acquire) != id) return;

            if (!is_finished.load(.acquire)) {
                std.debug.print("\nHARD TIMEOUT: Benchmark hung (Workers stuck). Forcing exit.\n", .{});
                std.process.exit(1);
            }
        }
    }.run, .{config.duration, current_run_id});
    watchdog.detach();

    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(allocator);

    var i: usize = 0;
    while (i < config.threads) : (i += 1) {
        const t = try std.Thread.spawn(.{}, worker, .{ db, workload, i, config.key_count });
        try threads.append(allocator, t);
    }

    // Sleep using libc sleep to avoid std issues
    const c = @cImport(@cInclude("unistd.h"));
    _ = c.sleep(@intCast(config.duration));
    should_stop.store(true, .release);

    for (threads.items) |t| t.join();
    is_finished.store(true, .release);

    const total = ops_count.load(.acquire);
    const qps = total / config.duration;
    std.debug.print("  Result: {d} ops/sec\n", .{qps});

    db.close();
    std.fs.cwd().deleteTree(db_path) catch {};
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    std.debug.print("Running Native Axion Benchmarks\n", .{});
    
    const config = try Config.BenchmarkConfig.parseArgs(allocator);

    const modes = [_]WAL.SyncMode{ .Full, .Normal, .Off };
    const workloads = [_]Config.Workload{ .Write, .SeqWrite, .Read, .RangeScan, .Mix };

    for (modes) |m| {
        // Filter Mode
        if (config.filter_mode) |fm| {
             const match = switch (fm) {
                 .Full => m == .Full,
                 .Normal => m == .Normal,
                 .Off => m == .Off,
             };
             if (!match) continue;
        }

        for (workloads) |w| {
             // Filter Workload
             if (config.filter_workload) |fw| {
                 if (fw != w) continue;
             }
             
            try runBenchmark(allocator, m, w, config);
        }
    }
}