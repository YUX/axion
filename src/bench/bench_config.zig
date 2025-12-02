const std = @import("std");

pub const DEFAULT_THREADS = 100;
pub const DEFAULT_DURATION = 5;
pub const DEFAULT_KEYS = 50000;

pub const DB_PATH_NATIVE = "bench_axion_native";
pub const DB_PATH_VTAB = "bench_axion_vtab";
pub const DB_PATH_SQLITE = "bench_sqlite.db";

pub const KEY_FMT = "key_{:0>9}";
pub const VAL_FMT = "val_{:0>16}";
pub const SEQ_KEY_FMT = "seq_{:0>12}";

pub const Workload = enum {
    Write,      // Random Insert (Auto-commit/Single-txn)
    SeqWrite,   // Sequential Insert (Auto-commit/Single-txn)
    Read,       // Random Point Read
    RangeScan,  // Range Scan (Limit 100)
    Mix,        // 50/50 Read/Write
};

pub const Mode = enum {
    Full,   // Synchronous = FULL (Durability)
    Normal, // Synchronous = NORMAL (OS Cache)
    Off,    // Synchronous = OFF (Memory)
};

pub const BenchmarkConfig = struct {
    threads: usize = DEFAULT_THREADS,
    duration: u64 = DEFAULT_DURATION,
    key_count: usize = DEFAULT_KEYS,
    compaction_threads: usize = 8,
    
    // Optional Filters (if null, run all)
    filter_workload: ?Workload = null,
    filter_mode: ?Mode = null,

    pub fn parseArgs(allocator: std.mem.Allocator) !BenchmarkConfig {
        var config = BenchmarkConfig{};
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        _ = args.skip(); // Skip executable name

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--client-threads")) {
                if (args.next()) |val| {
                    config.threads = try std.fmt.parseInt(usize, val, 10);
                }
            } else if (std.mem.eql(u8, arg, "--compaction-threads")) {
                if (args.next()) |val| {
                    config.compaction_threads = try std.fmt.parseInt(usize, val, 10);
                }
            } else if (std.mem.eql(u8, arg, "--duration")) {
                if (args.next()) |val| {
                    config.duration = try std.fmt.parseInt(u64, val, 10);
                }
            } else if (std.mem.eql(u8, arg, "--keys")) {
                if (args.next()) |val| {
                    config.key_count = try std.fmt.parseInt(usize, val, 10);
                }
            } else if (std.mem.eql(u8, arg, "--workload")) {
                if (args.next()) |val| {
                    inline for (std.meta.fields(Workload)) |f| {
                        if (std.mem.eql(u8, val, f.name)) {
                            config.filter_workload = @enumFromInt(f.value);
                        }
                    }
                }
            } else if (std.mem.eql(u8, arg, "--mode")) {
                if (args.next()) |val| {
                     inline for (std.meta.fields(Mode)) |f| {
                        if (std.mem.eql(u8, val, f.name)) {
                            config.filter_mode = @enumFromInt(f.value);
                        }
                    }
                }
            }
        }
        return config;
    }
};
