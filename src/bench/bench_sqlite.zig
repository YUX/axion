const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const THREADS = 100;
const DURATION_SECONDS = 5;

const Mode = enum {
    Full,
    Normal,
    Off, // "Memory" sync mode interpretation
};

const Workload = enum {
    Write,
    Read,
    Mix,
};

// Global atomic counter for operations
var ops_count = std.atomic.Value(usize).init(0);
var should_stop = std.atomic.Value(bool).init(false);

fn panic(msg: []const u8) noreturn {
    std.debug.print("Error: {s}\n", .{msg});
    std.process.exit(1);
}

fn checkSqlite(rc: c_int, db: ?*c.sqlite3) void {
    if (rc != c.SQLITE_OK and rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) {
        const err_msg = c.sqlite3_errmsg(db);
        std.debug.print("SQLite Error: {s}\n", .{err_msg});
        std.process.exit(1);
    }
}

fn worker(db_path: [:0]const u8, workload: Workload, mode: Mode, seed: u64) void {
    var db: ?*c.sqlite3 = null;

    var rc = c.sqlite3_open(db_path.ptr, &db);
    checkSqlite(rc, db);
    defer _ = c.sqlite3_close(db);

    // Set Synchronous Mode for this connection
    const sync_pragma = switch (mode) {
        .Full => "PRAGMA synchronous = FULL;",
        .Normal => "PRAGMA synchronous = NORMAL;",
        .Off => "PRAGMA synchronous = OFF;",
    };
    _ = c.sqlite3_exec(db, sync_pragma.ptr, null, null, null);

    // Busy timeout to handle locking
    _ = c.sqlite3_busy_timeout(db, 5000);

    var rng = std.Random.DefaultPrng.init(seed);
    var random = rng.random();

    // Pre-prepare statements
    var stmt_insert: ?*c.sqlite3_stmt = null;
    var stmt_read: ?*c.sqlite3_stmt = null;

    const insert_sql = "INSERT OR REPLACE INTO bench (key, value) VALUES (?, ?)";
    const read_sql = "SELECT value FROM bench WHERE key = ?";

    rc = c.sqlite3_prepare_v2(db, insert_sql, -1, &stmt_insert, null);
    checkSqlite(rc, db);
    defer _ = c.sqlite3_finalize(stmt_insert);

    rc = c.sqlite3_prepare_v2(db, read_sql, -1, &stmt_read, null);
    checkSqlite(rc, db);
    defer _ = c.sqlite3_finalize(stmt_read);

    // Key space
    const max_key = 100000;
    var buf_key: [32]u8 = undefined;
    var buf_val: [128]u8 = undefined;

    while (!should_stop.load(.monotonic)) {
        const op_type = switch (workload) {
            .Write => 0, // All write
            .Read => 1, // All read
            .Mix => if (random.boolean()) @as(u8, 0) else @as(u8, 1),
        };

        if (op_type == 0) {
            // WRITE
            const k = random.intRangeAtMost(usize, 0, max_key);
            const key_str = std.fmt.bufPrintZ(&buf_key, "key_{}", .{k}) catch unreachable;
            const val_str = std.fmt.bufPrintZ(&buf_val, "value_{}_{}", .{ k, random.int(u32) }) catch unreachable;

            _ = c.sqlite3_reset(stmt_insert);
            _ = c.sqlite3_bind_text(stmt_insert, 1, key_str.ptr, -1, c.SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt_insert, 2, val_str.ptr, -1, c.SQLITE_STATIC);

            rc = c.sqlite3_step(stmt_insert);
            if (rc != c.SQLITE_DONE) {
                // Retry on busy? We set busy_timeout.
                // If it fails, we just continue/retry.
            }
        } else {
            // READ
            const k = random.intRangeAtMost(usize, 0, max_key);
            const key_str = std.fmt.bufPrintZ(&buf_key, "key_{}", .{k}) catch unreachable;

            _ = c.sqlite3_reset(stmt_read);
            _ = c.sqlite3_bind_text(stmt_read, 1, key_str.ptr, -1, c.SQLITE_STATIC);

            rc = c.sqlite3_step(stmt_read);
            if (rc == c.SQLITE_ROW) {
                const val = c.sqlite3_column_text(stmt_read, 0);
                // Force a read
                if (val != null and val[0] == 0) {}
            }
        }

        _ = ops_count.fetchAdd(1, .monotonic);
    }
}

fn runBenchmark(allocator: std.mem.Allocator, mode: Mode, workload: Workload) !void {
    const db_path = "bench.db";
    const db_path_c = "bench.db";

    // Clean previous
    std.fs.cwd().deleteFile(db_path) catch {};
    std.fs.cwd().deleteFile("bench.db-wal") catch {};
    std.fs.cwd().deleteFile("bench.db-shm") catch {};

    // Setup DB
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(db_path_c, &db);
    checkSqlite(rc, db);

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

    // Pre-populate for Read workload
    if (workload == .Read or workload == .Mix) {
        std.debug.print("  Pre-populating 10k rows...\n", .{});
        _ = c.sqlite3_exec(db, "BEGIN;", null, null, null);
        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "INSERT INTO bench VALUES (?, ?)", -1, &stmt, null);

        var i: usize = 0;
        var k_buf: [32]u8 = undefined;
        while (i < 10000) : (i += 1) {
            const k = std.fmt.bufPrintZ(&k_buf, "key_{}", .{i}) catch unreachable;
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_bind_text(stmt, 1, k.ptr, -1, c.SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 2, "initial_value", -1, c.SQLITE_STATIC);
            _ = c.sqlite3_step(stmt);
        }
        _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_exec(db, "COMMIT;", null, null, null);
        // Checkpoint
        _ = c.sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", null, null, null);
    }

    _ = c.sqlite3_close(db); // Close main handle, workers open their own

    // Reset Counters
    ops_count.store(0, .monotonic);
    should_stop.store(false, .monotonic);

    // Spawn Threads
    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(allocator);

    var i: usize = 0;
    while (i < THREADS) : (i += 1) {
        const t = try std.Thread.spawn(.{}, worker, .{ db_path_c, workload, mode, i });
        try threads.append(allocator, t);
    }

    // Run
    std.Thread.sleep(DURATION_SECONDS * std.time.ns_per_s);
    should_stop.store(true, .release);

    // Join
    for (threads.items) |t| {
        t.join();
    }

    // Report
    const total_ops = ops_count.load(.acquire);
    const qps = total_ops / DURATION_SECONDS;
    std.debug.print("  {s} - {s}: {d} ops/sec (Total: {d})\n", .{ switch (mode) {
        .Full => "FULL",
        .Normal => "NORMAL",
        .Off => "OFF",
    }, switch (workload) {
        .Write => "Write",
        .Read => "Read",
        .Mix => "Mix",
    }, qps, total_ops });

    // Cleanup DB file
    std.fs.cwd().deleteFile(db_path) catch {};
    std.fs.cwd().deleteFile("bench.db-wal") catch {};
    std.fs.cwd().deleteFile("bench.db-shm") catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    std.debug.print("Running SQLite Benchmarks (100 threads, 5s each).\n", .{});
    std.debug.print("---------------------------------------------------\n", .{});

    const modes = [_]Mode{ .Full, .Normal, .Off };
    const workloads = [_]Workload{ .Write, .Read, .Mix };

    for (modes) |m| {
        for (workloads) |w| {
            try runBenchmark(allocator, m, w);
        }
    }
}
