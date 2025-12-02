const std = @import("std");
const vtab = @import("axion").sqlite.vtab;
const c = @import("axion").sqlite.c;
const c_sys = @cImport(@cInclude("unistd.h"));

const THREADS = 100;
const DURATION_SECONDS = 5;
const DB_PATH = "bench_vtab_dir";

// Global atomic counter for operations
var ops_count = std.atomic.Value(usize).init(0);
var should_stop = std.atomic.Value(bool).init(false);

const Workload = enum {
    Insert,
    Read,
};

fn worker(workload: Workload, seed: u64) void {
    // Open independent SQLite connection
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_close(db);

    // Register Module
    if (vtab.register(db) != c.SQLITE_OK) return;

    // Connect to Shared Axion DB
    var sql_buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&sql_buf, "CREATE VIRTUAL TABLE t1 USING axion('{s}');", .{DB_PATH}) catch return;
    if (exec(db, sql) != c.SQLITE_OK) return;

    var rng = std.Random.DefaultPrng.init(seed);
    var random = rng.random();

    var k_buf: [64]u8 = undefined;
    var v_buf: [64]u8 = undefined;
    var q_buf: [128]u8 = undefined;

    // Batch size for inserts
    const BATCH_SIZE = 100; // Use smaller batches to allow some concurrency interleaving

    var i: usize = seed * 1000000;

    while (!should_stop.load(.monotonic)) {
        switch (workload) {
            .Insert => {
                // Wrap in transaction
                _ = exec(db, "BEGIN;");
                var b: usize = 0;
                while (b < BATCH_SIZE) : (b += 1) {
                    const k = std.fmt.bufPrint(&k_buf, "key_{}", .{i}) catch break;
                    const v = std.fmt.bufPrint(&v_buf, "val_{}", .{i}) catch break;

                    const ins = std.fmt.bufPrintZ(&q_buf, "INSERT INTO t1(key, value) VALUES ('{s}', '{s}');", .{ k, v }) catch break;
                    if (exec(db, ins) != c.SQLITE_OK) break;
                    i += 1;
                }
                _ = exec(db, "COMMIT;");
                _ = ops_count.fetchAdd(BATCH_SIZE, .monotonic);
            },
            .Read => {
                const k_idx = random.intRangeAtMost(usize, 0, 10000); // Assumes pre-populated
                const k = std.fmt.bufPrint(&k_buf, "key_{}", .{k_idx}) catch continue;
                const q = std.fmt.bufPrintZ(&q_buf, "SELECT * FROM t1 WHERE key = '{s}';", .{k}) catch continue;
                _ = exec(db, q);
                _ = ops_count.fetchAdd(1, .monotonic);
            },
        }
    }
}

fn runBenchmark(allocator: std.mem.Allocator, workload: Workload) !void {
    std.debug.print("  Starting VTab {s} (100 threads)...\n", .{@tagName(workload)});

    // Clean previous
    if (workload == .Insert) {
        std.fs.cwd().deleteTree(DB_PATH) catch {};
    }

    // If Read, we need to pre-populate
    if (workload == .Read) {
        // Pre-populate using single thread for simplicity
        var db: ?*c.sqlite3 = null;
        _ = c.sqlite3_open(":memory:", &db);
        _ = vtab.register(db);
        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(&sql_buf, "CREATE VIRTUAL TABLE t1 USING axion('{s}');", .{DB_PATH});
        _ = exec(db, sql);

        std.debug.print("    Pre-populating...\n", .{});
        _ = exec(db, "BEGIN;");
        var i: usize = 0;
        var k_buf: [64]u8 = undefined;
        var q_buf: [128]u8 = undefined;
        while (i < 20000) : (i += 1) {
            const k = try std.fmt.bufPrint(&k_buf, "key_{}", .{i});
            const ins = try std.fmt.bufPrintZ(&q_buf, "INSERT INTO t1(key, value) VALUES ('{s}', 'val');", .{k});
            _ = exec(db, ins);
        }
        _ = exec(db, "COMMIT;");
        _ = c.sqlite3_close(db);
    }

    ops_count.store(0, .monotonic);
    should_stop.store(false, .monotonic);

    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(allocator);

    var i: usize = 0;
    while (i < THREADS) : (i += 1) {
        const t = try std.Thread.spawn(.{}, worker, .{ workload, i });
        try threads.append(allocator, t);
    }

    // Run
    var timer = try std.time.Timer.start();
    const duration_ns = DURATION_SECONDS * std.time.ns_per_s;
    while (timer.read() < duration_ns) {
        _ = c_sys.usleep(100000);
    }
    should_stop.store(true, .release);

    for (threads.items) |t| {
        t.join();
    }

    const total = ops_count.load(.acquire);
    const qps = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(DURATION_SECONDS));
    std.debug.print("  VTab {s}: {d:.2} ops/sec (Total: {d})\n", .{ @tagName(workload), qps, total });

    // Cleanup if Insert (Read keeps it for debugging or next run?)
    // No, clean up always to be polite
    // But wait, vtab.zig shared logic relies on refcounts.
    // All threads joined -> all disconnected -> shared DB closed.
    // So we can delete tree.

    if (workload == .Read) {
        std.fs.cwd().deleteTree(DB_PATH) catch {};
    }
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    try runBenchmark(allocator, .Insert);
    // Wait a bit to ensure locks released?
    _ = c_sys.sleep(1);
    try runBenchmark(allocator, .Read);
}

fn exec(db: ?*c.sqlite3, sql: []const u8) c_int {
    var errMsg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, sql.ptr, null, null, &errMsg);
    if (rc != c.SQLITE_OK) {
        // std.debug.print("SQL Error: {s}\n", .{errMsg});
        c.sqlite3_free(errMsg);
    }
    return rc;
}
