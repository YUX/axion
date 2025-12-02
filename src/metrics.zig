const std = @import("std");

pub const Metrics = struct {
    puts: std.atomic.Value(u64),
    gets: std.atomic.Value(u64),
    iterators: std.atomic.Value(u64),
    compactions: std.atomic.Value(u64),
    flushes: std.atomic.Value(u64),
    block_cache_hits: std.atomic.Value(u64),
    block_cache_misses: std.atomic.Value(u64),
    txn_success: std.atomic.Value(u64),
    txn_conflict: std.atomic.Value(u64),
    
    pub fn init() Metrics {
        return Metrics{
            .puts = std.atomic.Value(u64).init(0),
            .gets = std.atomic.Value(u64).init(0),
            .iterators = std.atomic.Value(u64).init(0),
            .compactions = std.atomic.Value(u64).init(0),
            .flushes = std.atomic.Value(u64).init(0),
            .block_cache_hits = std.atomic.Value(u64).init(0),
            .block_cache_misses = std.atomic.Value(u64).init(0),
            .txn_success = std.atomic.Value(u64).init(0),
            .txn_conflict = std.atomic.Value(u64).init(0),
        };
    }

    pub inline fn put(self: *Metrics) void { _ = self.puts.fetchAdd(1, .monotonic); }
    pub inline fn get(self: *Metrics) void { _ = self.gets.fetchAdd(1, .monotonic); }
    pub inline fn iterator(self: *Metrics) void { _ = self.iterators.fetchAdd(1, .monotonic); }
    pub inline fn compaction(self: *Metrics) void { _ = self.compactions.fetchAdd(1, .monotonic); }
    pub inline fn flush(self: *Metrics) void { _ = self.flushes.fetchAdd(1, .monotonic); }
    pub inline fn cacheHit(self: *Metrics) void { _ = self.block_cache_hits.fetchAdd(1, .monotonic); }
    pub inline fn cacheMiss(self: *Metrics) void { _ = self.block_cache_misses.fetchAdd(1, .monotonic); }
    pub inline fn txnSuccess(self: *Metrics) void { _ = self.txn_success.fetchAdd(1, .monotonic); }
    pub inline fn txnConflict(self: *Metrics) void { _ = self.txn_conflict.fetchAdd(1, .monotonic); }
};

pub var global: Metrics = Metrics.init();