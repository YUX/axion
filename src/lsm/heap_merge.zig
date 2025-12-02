const std = @import("std");
const Order = std.math.Order;
const Allocator = std.mem.Allocator;
const PriorityQueue = std.PriorityQueue;
const Comparator = @import("comparator.zig");

pub const NoOpCloner = struct {
    pub const active = false;
    pub fn clone(allocator: Allocator, item: anytype) !@TypeOf(item) {
        _ = allocator;
        return item;
    }
    pub fn free(allocator: Allocator, item: anytype) void {
        _ = allocator;
        _ = item;
    }
};

/// A generic iterator that merges multiple sorted iterators using a min-heap.
/// The iterators must yield entries sorted by Key ASC.
/// When keys are equal, entries are sorted by Version DESC (newer first).
pub fn HeapMergeIterator(comptime EntryType: type, comptime SourceIteratorType: type, comptime _: type) type {
    return struct {
        const Self = @This();

        pub const HeapNode = struct {
            entry: EntryType,
            source_idx: usize,

            pub fn compare(context: void, a: HeapNode, b: HeapNode) Order {
                _ = context;
                // Primary Sort: Key ASC
                const key_cmp = Comparator.compare(a.entry.key, b.entry.key);
                if (key_cmp != .eq) {
                    return key_cmp;
                }
                // Secondary Sort: Version DESC (Higher version comes first)
                if (a.entry.version > b.entry.version) {
                    return .lt;
                } else if (a.entry.version < b.entry.version) {
                    return .gt;
                }
                return .eq;
            }
        };

        allocator: Allocator,
        heap: PriorityQueue(HeapNode, void, HeapNode.compare),
        sources: []SourceIteratorType,
        pending_source_idx: ?usize = null,

        pub fn init(allocator: Allocator, sources: []SourceIteratorType) !Self {
            var heap = PriorityQueue(HeapNode, void, HeapNode.compare).init(allocator, {});
            errdefer heap.deinit();

            // Pre-fill heap
            for (sources, 0..) |*src, i| {
                if (try src.next()) |entry| {
                    try heap.add(.{
                        .entry = entry,
                        .source_idx = i,
                    });
                }
            }

            return Self{
                .allocator = allocator,
                .heap = heap,
                .sources = sources,
                .pending_source_idx = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.heap.deinit();
        }

        /// Returns the next entry in merged order.
        pub fn next(self: *Self) !?EntryType {
            // Lazy replenishment: Advance the iterator we pulled from LAST time.
            // This ensures the buffer returned in the previous call was valid until now.
            if (self.pending_source_idx) |idx| {
                if (try self.sources[idx].next()) |next_entry| {
                    try self.heap.add(.{
                        .entry = next_entry,
                        .source_idx = idx,
                    });
                }
                self.pending_source_idx = null;
            }

            if (self.heap.removeOrNull()) |node| {
                self.pending_source_idx = node.source_idx;
                // Return the entry directly (Zero-Copy).
                // It is valid until this function is called again.
                return node.entry;
            }
            return null;
        }

        /// Reset and rebuild heap (useful after seeking sources)
        pub fn reset(self: *Self) !void {
            self.pending_source_idx = null;

            // Clear heap
            while (self.heap.removeOrNull()) |_| {}

            // Refill
            for (self.sources, 0..) |*src, i| {
                if (try src.next()) |entry| {
                    try self.heap.add(.{
                        .entry = entry,
                        .source_idx = i,
                    });
                }
            }
        }
    };
}
