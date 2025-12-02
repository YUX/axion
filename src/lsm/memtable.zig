const std = @import("std");
const Allocator = std.mem.Allocator;
const Comparator = @import("comparator.zig");

/// Internal Shard implementation (Mini-MemTable).
const Shard = struct {
    const MAX_LEVEL = 12;
    const PROBABILITY = 0.5;

    const Node = struct {
        key: []const u8,
        value: []const u8,
        version: u64,
        next: [MAX_LEVEL]?*Node,
        level: usize,
    };

    parent_allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    allocator: Allocator,
    head: *Node,
    level: usize,
    lock: std.Thread.RwLock,
    rng: std.Random.DefaultPrng,
    size_bytes: usize,

    pub fn init(parent_allocator: Allocator) !*Shard {
        const self = try parent_allocator.create(Shard);
        self.parent_allocator = parent_allocator;
        self.arena = std.heap.ArenaAllocator.init(parent_allocator);
        self.allocator = self.arena.allocator();
        self.level = 0;
        self.lock = std.Thread.RwLock{};
        self.rng = std.Random.DefaultPrng.init(std.crypto.random.int(u64));
        self.size_bytes = 0;

        self.head = try self.allocator.create(Node);
        self.head.key = "";
        self.head.value = "";
        self.head.version = 0;
        self.head.level = MAX_LEVEL;
        @memset(&self.head.next, null);

        return self;
    }

    pub fn deinit(self: *Shard) void {
        // Arena frees all nodes and keys/values
        self.arena.deinit();
        self.parent_allocator.destroy(self);
    }

    fn randomLevel(self: *Shard) usize {
        var lvl: usize = 0;
        while (self.rng.random().float(f32) < PROBABILITY and lvl < MAX_LEVEL - 1) {
            lvl += 1;
        }
        return lvl;
    }

    pub fn put(self: *Shard, key: []const u8, value: []const u8, version: u64) !void {
        self.lock.lock();
        defer self.lock.unlock();

        var update: [MAX_LEVEL]?*Node = undefined;
        var current = self.head;
        var i: isize = @intCast(self.level);
        while (i >= 0) : (i -= 1) {
            while (current.next[@intCast(i)]) |next_node| {
                const cmp = Comparator.compare(next_node.key, key);
                if (cmp == .lt) {
                    current = next_node;
                } else if (cmp == .eq) {
                    if (next_node.version > version) {
                        current = next_node;
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            }
            update[@intCast(i)] = current;
        }

        const lvl = self.randomLevel();
        if (lvl > self.level) {
            var j = self.level + 1;
            while (j <= lvl) : (j += 1) {
                update[j] = self.head;
            }
            self.level = lvl;
        }

        const node_size = @sizeOf(Node);
        const total_size = node_size + key.len + value.len;
        
        // Single allocation for Node + Key + Value
        const buffer = try self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(Node)), total_size);
        const new_node = @as(*Node, @ptrCast(buffer.ptr));
        
        const key_dest = buffer[node_size..][0..key.len];
        const val_dest = buffer[node_size + key.len..][0..value.len];
        
        @memcpy(key_dest, key);
        @memcpy(val_dest, value);

        new_node.key = key_dest;
        new_node.value = val_dest;
        new_node.version = version;
        new_node.level = lvl;
        @memset(&new_node.next, null);

        self.size_bytes += total_size; // Use actual allocated size (slightly more accurate)

        var j: usize = 0;
        while (j <= lvl) : (j += 1) {
            new_node.next[j] = update[j].?.next[j];
            update[j].?.next[j] = new_node;
        }
    }

    pub fn get(self: *Shard, key: []const u8, snapshot_version: u64) ?[]const u8 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var current = self.head;
        var i: isize = @intCast(self.level);

        while (i >= 0) : (i -= 1) {
            while (current.next[@intCast(i)]) |next_node| {
                const cmp = Comparator.compare(next_node.key, key);
                if (cmp == .lt) {
                    current = next_node;
                } else if (cmp == .eq) {
                    if (next_node.version > snapshot_version) {
                        current = next_node;
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            }
        }

        if (current.next[0]) |node| {
            if (std.mem.eql(u8, node.key, key) and node.version <= snapshot_version) {
                return node.value;
            }
        }
        return null;
    }

    pub fn getLatestVersion(self: *Shard, key: []const u8) ?u64 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var current = self.head;
        var i: isize = @intCast(self.level);

        while (i >= 0) : (i -= 1) {
            while (current.next[@intCast(i)]) |next_node| {
                const cmp = Comparator.compare(next_node.key, key);
                if (cmp == .lt) {
                    current = next_node;
                } else {
                    break;
                }
            }
        }

        if (current.next[0]) |node| {
            if (std.mem.eql(u8, node.key, key)) {
                return node.version;
            }
        }
        return null;
    }
    
    pub const Iterator = struct {
        const BATCH_SIZE = 64;
        
        shard: *Shard,
        current: ?*Node,
        
        // Batching
        batch_buffer: [BATCH_SIZE]MemTable.Iterator.Entry = undefined,
        batch_len: usize = 0,
        batch_idx: usize = 0,

        pub fn seek(self: *Iterator, key: []const u8) void {
            // Skip List Search for >= key
            self.shard.lock.lockShared();
            defer self.shard.lock.unlockShared();

            var current = self.shard.head;
            var i: isize = @intCast(self.shard.level);

            while (i >= 0) : (i -= 1) {
                while (current.next[@intCast(i)]) |next_node| {
                    const cmp = Comparator.compare(next_node.key, key);
                    if (cmp == .lt) {
                        current = next_node;
                    } else {
                        break;
                    }
                }
            }
            // current.next[0] is the first node >= key (or null)
            self.current = current.next[0];
            self.batch_len = 0;
            self.batch_idx = 0;
        }

        pub fn next(self: *Iterator) !?MemTable.Iterator.Entry {
            if (self.batch_idx < self.batch_len) {
                const entry = self.batch_buffer[self.batch_idx];
                self.batch_idx += 1;
                return entry;
            }
            
            if (self.current == null) return null;

            // Refill Batch
            self.shard.lock.lockShared();
            defer self.shard.lock.unlockShared();

            // Re-check current in case it was removed (not possible in append-only, but good practice)
            // Actually, self.current is a pointer. If it's valid, we are good.
            
            self.batch_len = 0;
            self.batch_idx = 0;
            
            var ptr = self.current;
            while (ptr) |node| {
                if (self.batch_len >= BATCH_SIZE) break;
                
                self.batch_buffer[self.batch_len] = MemTable.Iterator.Entry{
                    .key = node.key,
                    .value = node.value,
                    .version = node.version,
                };
                self.batch_len += 1;
                ptr = node.next[0];
            }
            self.current = ptr;

            if (self.batch_len > 0) {
                const entry = self.batch_buffer[0];
                self.batch_idx = 1;
                return entry;
            }
            return null;
        }
        
        pub fn deinit(self: *Iterator) void {
            _ = self;
        }
    };

    pub fn iterator(self: *Shard) Iterator {
        return Iterator{ .shard = self, .current = self.head.next[0] };
    }
};

/// Sharded MemTable implementation.
pub const MemTable = struct {
    const SHARD_COUNT = 16;

    allocator: Allocator,
    shards: [SHARD_COUNT]*Shard,
    count: std.atomic.Value(usize),
    ref_count: std.atomic.Value(usize),

    pub fn init(allocator: Allocator) !*MemTable {
        const self = try allocator.create(MemTable);
        self.allocator = allocator;
        self.count = std.atomic.Value(usize).init(0);
        self.ref_count = std.atomic.Value(usize).init(1);
        for (0..SHARD_COUNT) |i| {
            self.shards[i] = try Shard.init(allocator);
        }
        return self;
    }

    pub fn ref(self: *MemTable) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn unref(self: *MemTable) void {
        const prev = self.ref_count.fetchSub(1, .release);
        if (prev == 1) {
            _ = self.ref_count.load(.acquire);
            self.deinit();
        }
    }

    pub fn deinit(self: *MemTable) void {
        for (self.shards) |shard| {
            shard.deinit();
        }
        self.allocator.destroy(self);
    }

    fn getShardIndex(key: []const u8) usize {
        var hash: u64 = 0xcbf29ce484222325;
        for (key) |b| {
            hash ^= b;
            hash *%= 0x100000001b3;
        }
        return hash % SHARD_COUNT;
    }

    pub fn approxSize(self: *MemTable) usize {
        var size: usize = 0;
        for (self.shards) |shard| {
            size += shard.size_bytes;
        }
        return size;
    }

    pub fn put(self: *MemTable, key: []const u8, value: []const u8, version: u64) !void {
        const shard_idx = getShardIndex(key);
        try self.shards[shard_idx].put(key, value, version);
        _ = self.count.fetchAdd(1, .monotonic);
    }

    pub fn get(self: *MemTable, key: []const u8, snapshot_version: u64) ?[]const u8 {
        const shard_idx = getShardIndex(key);
        return self.shards[shard_idx].get(key, snapshot_version);
    }

    pub fn getLatestVersion(self: *MemTable, key: []const u8) ?u64 {
        const shard_idx = getShardIndex(key);
        return self.shards[shard_idx].getLatestVersion(key);
    }

    pub const Iterator = struct {
        pub const Entry = struct {
            key: []const u8,
            value: []const u8,
            version: u64,
        };

        const HeapIter = @import("heap_merge.zig").HeapMergeIterator(Entry, Shard.Iterator, @import("heap_merge.zig").NoOpCloner);

        shard_iters: []Shard.Iterator,
        heap_iter: HeapIter,

        pub fn seek(self: *Iterator, key: []const u8) !void {
            for (self.shard_iters) |*it| {
                it.seek(key);
            }
            try self.heap_iter.reset();
        }
        
        pub fn next(self: *Iterator) !?Entry {
            return self.heap_iter.next();
        }

        pub fn deinit(self: *Iterator) void {
            self.heap_iter.deinit();
            for (self.shard_iters) |*it| {
                it.deinit();
            }
            self.heap_iter.allocator.free(self.shard_iters);
        }
    };

    pub fn iterator(self: *MemTable) !Iterator {
        const shard_iters = try self.allocator.alloc(Shard.Iterator, SHARD_COUNT);
        errdefer self.allocator.free(shard_iters);
        
        for (0..SHARD_COUNT) |i| {
            shard_iters[i] = self.shards[i].iterator();
        }
        
        var it = Iterator{
            .shard_iters = shard_iters,
            .heap_iter = undefined,
        };
        // Initialize heap iterator with slice to shard_iters
        it.heap_iter = try Iterator.HeapIter.init(self.allocator, it.shard_iters);
        return it;
    }
};

test "MemTable basic operations" {
    const allocator = std.testing.allocator;
    var memtable = try MemTable.init(allocator);
    defer memtable.deinit();

    try memtable.put("key1", "value1", 10);

    if (memtable.get("key1", 10)) |val| {
        try std.testing.expectEqualStrings("value1", val);
    } else {
        try std.testing.expect(false);
    }

    try std.testing.expect(memtable.get("key1", 5) == null);

    try memtable.put("key1", "value2", 20);

    if (memtable.get("key1", 20)) |val| {
        try std.testing.expectEqualStrings("value2", val);
    } else {
        try std.testing.expect(false);
    }

    if (memtable.get("key1", 15)) |val| {
        try std.testing.expectEqualStrings("value1", val);
    } else {
        try std.testing.expect(false);
    }
}