const std = @import("std");
const DB = @import("axion").DB;
const WAL = @import("axion").WAL;

const THREADS = 100;
const DURATION_SECONDS = 5;

const Workload = enum {
    Write, // Random
    Read,  // Random Point
    Mix,
    RangeScan,
    SeqWrite,
};

// Global atomic counter for operations
var ops_count = std.atomic.Value(usize).init(0);
var should_stop = std.atomic.Value(bool).init(false);

fn worker(db: *DB, workload: Workload, seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    var random = rng.random();

    const max_key = 100000;
    var buf_key: [64]u8 = undefined;
    var buf_val: [128]u8 = undefined;

    // For SeqWrite
    var seq_counter: usize = seed * 1000000; 

    while (!should_stop.load(.monotonic)) {
        switch (workload) {
            .Write => {
                const k = random.intRangeAtMost(usize, 0, max_key);
                const key_str = std.fmt.bufPrint(&buf_key, "key_{:0>9}", .{k}) catch unreachable;
                const val_str = std.fmt.bufPrint(&buf_val, "value_{}_{}", .{k, random.int(u32)}) catch unreachable;

                db.put(key_str, val_str) catch |err| {
                    if (err == error.Conflict) continue;
                    // std.debug.print("Put error: {}\n", .{err});
                };
            },
            .SeqWrite => {
                const k = seq_counter;
                seq_counter += 1;
                const key_str = std.fmt.bufPrint(&buf_key, "seq_{:0>12}", .{k}) catch unreachable;
                const val_str = std.fmt.bufPrint(&buf_val, "value_{}", .{k}) catch unreachable;
                
                db.put(key_str, val_str) catch |err| {
                     if (err == error.Conflict) continue;
                };
            },
            .Read => {
                const k = random.intRangeAtMost(usize, 0, max_key);
                const key_str = std.fmt.bufPrint(&buf_key, "key_{:0>9}", .{k}) catch unreachable;

                if (db.get(key_str)) |val| {
                    if (val) |v| db.allocator.free(v);
                } else |_| {}
            },
            .RangeScan => {
                 const k = random.intRangeAtMost(usize, 0, max_key);
                 const key_str = std.fmt.bufPrint(&buf_key, "key_{:0>9}", .{k}) catch unreachable;
                 
                 var txn = db.beginTransaction() catch continue;
                 
                 var iter = txn.scan(key_str) catch { txn.deinit(); continue; };
                 var count: usize = 0;
                 while (count < 100) : (count += 1) {
                     if (iter.next() catch break) |_| {
                         // consume
                     } else {
                         break;
                     }
                 }
                 iter.deinit();
                 txn.deinit();
            },
            .Mix => {
                if (random.boolean()) {
                    // Write
                    const k = random.intRangeAtMost(usize, 0, max_key);
                    const key_str = std.fmt.bufPrint(&buf_key, "key_{:0>9}", .{k}) catch unreachable;
                    const val_str = std.fmt.bufPrint(&buf_val, "value_{}_{}", .{k, random.int(u32)}) catch unreachable;
                    db.put(key_str, val_str) catch {};
                } else {
                    // Read
                    const k = random.intRangeAtMost(usize, 0, max_key);
                    const key_str = std.fmt.bufPrint(&buf_key, "key_{:0>9}", .{k}) catch unreachable;
                    if (db.get(key_str)) |val| {
                        if (val) |v| db.allocator.free(v);
                    } else |_| {}
                }
            }
        }

        _ = ops_count.fetchAdd(1, .monotonic);
    }
}

fn runBenchmark(allocator: std.mem.Allocator, mode: WAL.SyncMode, workload: Workload) !void {
    const db_path = "bench_axion_dir";
    std.debug.print("  [Bench] Starting {s} {s}...\n", .{
        switch(mode) { .Full => "Full", .Normal => "Normal", .Off => "Off" },
        @tagName(workload),
    });
    
    // Clean previous
    std.fs.cwd().deleteTree(db_path) catch {};
    
    // Setup DB
    var db = DB.open(allocator, db_path, mode) catch |err| {
        std.debug.print("  [Bench] Error opening DB: {}\n", .{err});
        return err;
    };

    // Pre-populate for Read/Scan/Mix workload
    if (workload == .Read or workload == .Mix or workload == .RangeScan) {
        // std.debug.print("  Pre-populating 100k rows...\n", .{});
        
        var txn = try db.beginTransaction();
        defer txn.deinit();
        
        var i: usize = 0;
        var k_buf: [32]u8 = undefined;
        while (i < 100000) : (i += 1) {
            const k = std.fmt.bufPrint(&k_buf, "key_{:0>9}", .{i}) catch unreachable;
            try txn.put(k, "initial_value");
            
            if (i % 1000 == 0) {
                try txn.commit();
                txn.deinit();
                txn = try db.beginTransaction();
            }
        }
        try txn.commit();
        // Flush to ensure SSTables exist for Scan tests
        try db.flushSync();
    }

    // Reset Counters
    ops_count.store(0, .monotonic);
    should_stop.store(false, .monotonic);

    // Spawn Threads
    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(allocator);

    var i: usize = 0;
    while (i < THREADS) : (i += 1) {
        const t = try std.Thread.spawn(.{}, worker, .{ db, workload, i });
        try threads.append(allocator, t);
    }

    // Run
    std.time.sleep(DURATION_SECONDS * std.time.ns_per_s);
    should_stop.store(true, .release);

    // Join
    for (threads.items) |t| {
        t.join();
    }

    // Report
    const total_ops = ops_count.load(.acquire);
    const qps = total_ops / DURATION_SECONDS;
    std.debug.print("  {s} - {s}: {d} ops/sec (Total: {d})\n", .{
        switch(mode) { .Full => "FULL", .Normal => "NORMAL", .Off => "OFF" },
        @tagName(workload),
        qps,
        total_ops
    });

    // Close DB before deleting files
    db.close();
    
    std.fs.cwd().deleteTree(db_path) catch {};
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("Running Axion Benchmarks (100 threads, 5s each)...\n", .{});
    std.debug.print("---------------------------------------------------\n", .{});

    const modes = [_]WAL.SyncMode{ .Full, .Normal, .Off };
    const workloads = [_]Workload{ .Write, .SeqWrite, .Read, .RangeScan, .Mix };

    for (modes) |m| {
        for (workloads) |w| {
            try runBenchmark(allocator, m, w);
        }
    }
}
