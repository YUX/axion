const std = @import("std");
const metrics = @import("../metrics.zig");
const Allocator = std.mem.Allocator;

pub const BlockCache = struct {
    const SHARD_COUNT = 64;

    const Key = struct {
        file_id: u64,
        offset: u64,
    };

    const Entry = struct {
        key: Key,
        data: []u8,
        refs: std.atomic.Value(usize),
        next: ?*Entry,
        prev: ?*Entry,
        cache: *BlockCache, // Pointer back to owning cache
    };

    const Shard = struct {
        mutex: std.Thread.Mutex,
        map: std.AutoHashMap(Key, *Entry),
        head: ?*Entry,
        tail: ?*Entry,
        capacity_bytes: usize,
        current_bytes: usize,
    };

    allocator: Allocator,
    shards: []Shard,

    pub const Handle = struct {
        data: []const u8,
        entry: *Entry,
        
        pub fn clone(self: Handle) Handle {
            _ = self.entry.refs.fetchAdd(1, .acquire);
            return Handle{ .data = self.data, .entry = self.entry };
        }

        pub fn release(self: Handle) void {
            self.entry.cache.releaseEntry(self.entry);
        }
    };

    pub fn init(allocator: Allocator, capacity_bytes: usize) BlockCache {
        const shards = allocator.alloc(Shard, SHARD_COUNT) catch @panic("OOM");
        const shard_cap = capacity_bytes / SHARD_COUNT;

        for (shards) |*s| {
            s.mutex = std.Thread.Mutex{};
            s.map = std.AutoHashMap(Key, *Entry).init(allocator);
            s.head = null;
            s.tail = null;
            s.capacity_bytes = if (shard_cap > 0) shard_cap else 1024 * 1024; // Min 1MB per shard default
            s.current_bytes = 0;
        }

        return BlockCache{
            .allocator = allocator,
            .shards = shards,
        };
    }

    pub fn deinit(self: *BlockCache) void {
        for (self.shards) |*s| {
            var current = s.head;
            while (current) |entry| {
                const next = entry.next;
                // Force release cache's reference
                const prev = entry.refs.fetchSub(1, .release);
                if (prev == 1) {
                     self.allocator.free(entry.data);
                     self.allocator.destroy(entry);
                }
                current = next;
            }
            s.map.deinit();
        }
        self.allocator.free(self.shards);
    }

    pub fn get(self: *BlockCache, file_id: u64, offset: u64) ?Handle {
        const key = Key{ .file_id = file_id, .offset = offset };
        const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
        const shard_idx = hash % SHARD_COUNT;
        const s = &self.shards[shard_idx];

        s.mutex.lock();
        defer s.mutex.unlock();

        if (s.map.get(key)) |entry| {
            self.moveToHead(s, entry);
            metrics.global.cacheHit();
            
            // Increment ref for the caller
            _ = entry.refs.fetchAdd(1, .acquire);
            return Handle{ .data = entry.data, .entry = entry };
        }
        metrics.global.cacheMiss();
        return null;
    }

    pub fn put(self: *BlockCache, file_id: u64, offset: u64, data: []u8) !Handle {
        // Takes ownership of data!
        const key = Key{ .file_id = file_id, .offset = offset };
        const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
        const shard_idx = hash % SHARD_COUNT;
        const s = &self.shards[shard_idx];

        s.mutex.lock();
        defer s.mutex.unlock();

        if (s.map.get(key)) |entry| {
            self.moveToHead(s, entry);
            // Already exists. The caller provided 'data' which we own now, but we discard it
            // in favor of the cached one.
            self.allocator.free(data);
            
            _ = entry.refs.fetchAdd(1, .acquire);
            return Handle{ .data = entry.data, .entry = entry };
        }

        // Evict if needed
        while (s.current_bytes + data.len > s.capacity_bytes and s.tail != null) {
            self.removeTail(s);
        }
        
        // If still too big, we can't cache it, but we can return a handle that just wraps it.
        // Since it's not in the map, we set cache pointer anyway so release() works.
        if (data.len > s.capacity_bytes) {
             const entry = try self.allocator.create(Entry);
             entry.* = Entry{
                 .key = key,
                 .data = data,
                 .refs = std.atomic.Value(usize).init(1),
                 .next = null,
                 .prev = null,
                 .cache = self,
             };
             return Handle{ .data = data, .entry = entry };
        }

        const entry = try self.allocator.create(Entry);
        entry.* = Entry{
            .key = key,
            .data = data, // Ownership transferred
            .refs = std.atomic.Value(usize).init(2), // 1 for Cache, 1 for Caller
            .next = s.head,
            .prev = null,
            .cache = self,
        };

        if (s.head) |head| {
            head.prev = entry;
        }
        s.head = entry;
        if (s.tail == null) {
            s.tail = entry;
        }

        try s.map.put(key, entry);
        s.current_bytes += data.len;
        
        return Handle{ .data = data, .entry = entry };
    }
    
    pub fn releaseEntry(self: *BlockCache, entry: *Entry) void {
        // We don't need to lock to decrement ref count
        const prev = entry.refs.fetchSub(1, .release);
        if (prev == 1) {
            // Last ref was ours. It must have been evicted or never cached.
            self.allocator.free(entry.data);
            self.allocator.destroy(entry);
        }
    }

    fn moveToHead(self: *BlockCache, s: *Shard, entry: *Entry) void {
        _ = self;
        if (entry == s.head) return;

        if (entry.prev) |prev| prev.next = entry.next;
        if (entry.next) |next| next.prev = entry.prev;
        if (entry == s.tail) s.tail = entry.prev;

        entry.prev = null;
        entry.next = s.head;
        if (s.head) |head| head.prev = entry;
        s.head = entry;
        if (s.tail == null) s.tail = entry;
    }

    fn removeTail(self: *BlockCache, s: *Shard) void {
        const tail = s.tail orelse return;

        if (tail.prev) |prev| {
            prev.next = null;
            s.tail = prev;
        } else {
            s.head = null;
            s.tail = null;
        }

        _ = s.map.remove(tail.key);
        s.current_bytes -= tail.data.len;
        
        // Drop cache's reference
        const prev_ref = tail.refs.fetchSub(1, .release);
        if (prev_ref == 1) {
            self.allocator.free(tail.data);
            self.allocator.destroy(tail);
        }
    }
};

test "BlockCache basic usage" {
    const allocator = std.testing.allocator;
    var cache = BlockCache.init(allocator, 1024 * 64); 
    defer cache.deinit();

    const data1 = try allocator.dupe(u8, "hello");
    const data2 = try allocator.dupe(u8, "world");

    var h1 = try cache.put(1, 0, data1);
    h1.release(); 

    var h2 = try cache.put(1, 10, data2);
    defer h2.release();

    if (cache.get(1, 0)) |h| {
        defer h.release();
        try std.testing.expectEqualStrings("hello", h.data);
    } else {
        try std.testing.expect(false);
    }

    try std.testing.expect(cache.get(2, 0) == null);
}