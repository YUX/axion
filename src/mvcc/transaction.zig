const std = @import("std");
const log = @import("../log.zig");
const metrics = @import("../metrics.zig");
const MemTable = @import("../lsm/memtable.zig").MemTable;
const WAL = @import("../lsm/wal.zig").WAL;
const RecordFormat = @import("../lsm/wal/record.zig").RecordFormat;
const SSTable = @import("../lsm/sstable.zig").SSTable;
const Iterator = @import("../lsm/iterator.zig").Iterator;
const MergedIterator = @import("../lsm/merged_iterator.zig").MergedIterator;
const Wrappers = @import("../lsm/iterator_wrappers.zig");
const CommitBatcher = @import("batcher.zig").CommitBatcher;
const CommitRequest = @import("batcher.zig").CommitRequest;

pub const SHARD_COUNT = 64;

const ActiveTxnShard = struct {
    mutex: std.Thread.Mutex,
    map: std.AutoHashMap(u64, u64),
};

pub const TransactionManager = struct {
    allocator: std.mem.Allocator,
    memtable: *MemTable,
    wal: *WAL,
    storage_ptr: *anyopaque,
    storage_read_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, version: u64) anyerror!?SSTable.ValueRef,
    storage_iterator_fn: *const fn (ptr: *anyopaque, read_version: u64) anyerror!Iterator,
    storage_latest_ver_fn: *const fn (ptr: *anyopaque, key: []const u8) ?u64,
    global_version: std.atomic.Value(u64),
    
    // Replaced commit_mutex with batcher
    batcher: *CommitBatcher,
    
    // Sharded Active Transactions to reduce contention
    active_shards: []ActiveTxnShard,
    next_txn_id: std.atomic.Value(u64),

    pub fn create(
        allocator: std.mem.Allocator,
        memtable: *MemTable,
        wal: *WAL,
        storage_ptr: *anyopaque,
        storage_read_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, version: u64) anyerror!?SSTable.ValueRef,
        storage_iterator_fn: *const fn (ptr: *anyopaque, read_version: u64) anyerror!Iterator,
        storage_latest_ver_fn: *const fn (ptr: *anyopaque, key: []const u8) ?u64,
        initial_version: u64
    ) !*TransactionManager {
        const shards = try allocator.alloc(ActiveTxnShard, SHARD_COUNT);
        for (shards) |*s| {
            s.mutex = std.Thread.Mutex{};
            s.map = std.AutoHashMap(u64, u64).init(allocator);
        }

        const self = try allocator.create(TransactionManager);
        self.* = TransactionManager{
            .allocator = allocator,
            .memtable = memtable,
            .wal = wal,
            .storage_ptr = storage_ptr,
            .storage_read_fn = storage_read_fn,
            .storage_iterator_fn = storage_iterator_fn,
            .storage_latest_ver_fn = storage_latest_ver_fn,
            .global_version = std.atomic.Value(u64).init(if (initial_version > 0) initial_version else 1),
            .batcher = undefined,
            .active_shards = shards,
            .next_txn_id = std.atomic.Value(u64).init(1),
        };
        
        // Safe to initialize batcher now that self is on heap
        self.batcher = try CommitBatcher.init(allocator, self);
        
        return self;
    }
    
    // Deprecated: initBatcher is merged into create

    pub fn destroy(self: *TransactionManager) void {
        self.batcher.deinit();
        for (self.active_shards) |*s| {
            s.map.deinit();
        }
        self.allocator.free(self.active_shards);
        self.allocator.destroy(self);
    }

    // Deprecated: deinit replaced by destroy logic
    pub fn deinit(self: *TransactionManager) void {
        // For backward compat or internal use if needed, but destroy covers it.
        self.destroy();
    }

    pub fn begin(self: *TransactionManager) !Transaction {
        // Read version is the current global version.
        // We don't increment yet. We increment on commit.
        const ver = self.global_version.load(.acquire);
        const id = self.next_txn_id.fetchAdd(1, .monotonic);

        if (id == std.math.maxInt(u64)) {
            @panic("Transaction ID Overflow! System limit reached.");
        }

        const shard_idx = id % SHARD_COUNT;
        const shard = &self.active_shards[shard_idx];
        
        shard.mutex.lock();
        try shard.map.put(id, ver);
        shard.mutex.unlock();

        return Transaction.init(self.allocator, self, id, ver);
    }

    pub fn deregister(self: *TransactionManager, id: u64) void {
        const shard_idx = id % SHARD_COUNT;
        const shard = &self.active_shards[shard_idx];
        
        shard.mutex.lock();
        _ = shard.map.remove(id);
        shard.mutex.unlock();
    }

    pub fn getMinActiveVersion(self: *TransactionManager) u64 {
        var min: u64 = self.global_version.load(.acquire);
        
        for (self.active_shards) |*s| {
            s.mutex.lock();
            var it = s.map.valueIterator();
            while (it.next()) |ver| {
                if (ver.* < min) {
                    min = ver.*;
                }
            }
            s.mutex.unlock();
        }
        return min;
    }

    pub const ReadOnlyTransaction = struct {
        id: u64,
        read_version: u64,
    };

    pub fn beginReadOnly(self: *TransactionManager) ReadOnlyTransaction {
        const ver = self.global_version.load(.acquire);
        const id = self.next_txn_id.fetchAdd(1, .monotonic);

        const shard_idx = id % SHARD_COUNT;
        const shard = &self.active_shards[shard_idx];
        
        shard.mutex.lock();
        shard.map.put(id, ver) catch {}; 
        shard.mutex.unlock();

        return ReadOnlyTransaction{ .id = id, .read_version = ver };
    }

    pub fn endReadOnly(self: *TransactionManager, txn: ReadOnlyTransaction) void {
        self.deregister(txn.id);
    }

    pub fn commit(self: *TransactionManager, txn: *Transaction) !void {
        // Submit to Batcher
        var req = CommitRequest{ .txn = txn };
        self.batcher.submit(&req);
        
        // Wait for completion
        // Wait on Futex. 0 = Pending, 1 = Done.
        while (req.done.load(.acquire) == 0) {
            std.Thread.Futex.wait(&req.done, 0);
        }
        
        if (req.status == .Conflict) {
            return error.Conflict;
        }
    }
    
    // Helpers for Batcher
    pub fn prepareTxnBuffer(self: *TransactionManager, txn: *Transaction, commit_ver: u64) void {
        _ = self;
        const items = txn.wal_buffer.items;
        var i: usize = 0;
        while (i < items.len) {
            const ver_offset = i + 4;
            std.mem.writeInt(u64, items[ver_offset..][0..8], commit_ver, .little);
            
            const kl_offset = i + 12;
            const vl_offset = i + 16;
            const key_len = std.mem.readInt(u32, items[kl_offset..][0..4], .little);
            const val_len = std.mem.readInt(u32, items[vl_offset..][0..4], .little);
            
            const entry_len = RecordFormat.HEADER_SIZE + key_len + val_len;
            
            var crc = std.hash.Crc32.init();
            crc.update(items[ver_offset .. i + entry_len]);
            std.mem.writeInt(u32, items[i..][0..4], crc.final(), .little);
            
            i += entry_len;
        }
    }
    
    pub fn applyToMemTable(self: *TransactionManager, txn: *Transaction, commit_ver: u64) !void {
        var it = txn.buffer.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            try self.memtable.put(key, value, commit_ver);
        }
    }
};


pub const Transaction = struct {
    // Savepoint Support
    const UndoLogEntry = struct {
        key: []const u8,
        old_value: ?[]const u8, // null means key was not in buffer
    };
    const Savepoint = struct {
        id: c_int,
        wal_len: usize,
        undo_len: usize,
    };

    allocator: std.mem.Allocator,
    manager: *TransactionManager,
    id: u64,
    read_version: u64,
    buffer: std.StringHashMap([]const u8),
    wal_buffer: std.ArrayListUnmanaged(u8), // Pre-serialized log entries
    arena: std.heap.ArenaAllocator,
    
    undo_log: std.ArrayListUnmanaged(UndoLogEntry),
    savepoints: std.ArrayListUnmanaged(Savepoint),

    pub fn init(allocator: std.mem.Allocator, manager: *TransactionManager, id: u64, read_version: u64) Transaction {
        return Transaction{
            .allocator = allocator,
            .manager = manager,
            .id = id,
            .read_version = read_version,
            .buffer = std.StringHashMap([]const u8).init(allocator),
            .wal_buffer = .{},
            .arena = std.heap.ArenaAllocator.init(allocator),
            .undo_log = .{},
            .savepoints = .{},
        };
    }

    pub fn deinit(self: *Transaction) void {
        self.manager.deregister(self.id);
        self.buffer.deinit();
        self.wal_buffer.deinit(self.allocator);
        self.undo_log.deinit(self.allocator);
        self.savepoints.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn put(self: *Transaction, key: []const u8, value: []const u8) !void {
        const arena_alloc = self.arena.allocator();
        const key_copy = try arena_alloc.dupe(u8, key);
        const val_copy = try arena_alloc.dupe(u8, value);

        if (self.savepoints.items.len > 0) {
            var old_val: ?[]const u8 = null;
            // Check full state (buffer + storage) for previous value
            if (try self.get(key)) |ref| {
                defer ref.deinit();
                old_val = try arena_alloc.dupe(u8, ref.data);
            }
            
            try self.undo_log.append(self.allocator, .{
                .key = key_copy, 
                .old_value = old_val,
            });
        }

        try self.buffer.put(key_copy, val_copy);
        
        // Pre-serialize to WAL buffer
        try RecordFormat.encodePlaceholders(&self.wal_buffer, self.allocator, key, value);
    }

    pub fn delete(self: *Transaction, key: []const u8) !void {
        try self.put(key, "");
    }
    
    pub fn savepoint(self: *Transaction, id: c_int) !void {
        try self.savepoints.append(self.allocator, .{
            .id = id,
            .wal_len = self.wal_buffer.items.len,
            .undo_len = self.undo_log.items.len,
        });
    }
    
    pub fn releaseSavepoint(self: *Transaction, id: c_int) void {
        // Release means we commit this savepoint (merge it into parent or txn).
        // SQLite assumes savepoints are nested. Release id releases id AND all subsequent nested savepoints?
        // "The RELEASE command releases a savepoint... and any savepoints that have been created since."
        // So we remove 'id' and everything after it from the stack.
        // But we KEEP the changes (undo log remains).
        
        var i: usize = self.savepoints.items.len;
        while (i > 0) {
            i -= 1;
            if (self.savepoints.items[i].id == id) {
                self.savepoints.shrinkRetainingCapacity(i);
                return;
            }
        }
        // If not found? Ignore.
    }
    
    pub fn rollbackTo(self: *Transaction, id: c_int) !void {
        // Find savepoint
        var target_idx: ?usize = null;
        var i: usize = self.savepoints.items.len;
        while (i > 0) {
            i -= 1;
            if (self.savepoints.items[i].id == id) {
                target_idx = i;
                break;
            }
        }
        
        if (target_idx) |idx| {
            const sp = self.savepoints.items[idx];
            
            // 1. Truncate WAL Buffer
            self.wal_buffer.shrinkRetainingCapacity(sp.wal_len);
            
            // 2. Replay Undo Log
            var j: usize = self.undo_log.items.len;
            while (j > sp.undo_len) {
                j -= 1;
                const entry = self.undo_log.items[j];
                if (entry.old_value) |v| {
                    try self.buffer.put(entry.key, v);
                } else {
                    _ = self.buffer.remove(entry.key);
                }
            }
            self.undo_log.shrinkRetainingCapacity(sp.undo_len);
            
            // 3. Remove subsequent savepoints (BUT KEEP 'id' savepoint? No, SQLite says ROLLBACK TO retains the savepoint).
            // "The ROLLBACK TO command reverts the state... to what it was... The savepoint remains active."
            // So we remove everything AFTER `idx`.
            self.savepoints.shrinkRetainingCapacity(idx + 1);
        }
    }

    pub fn get(self: *Transaction, key: []const u8) !?SSTable.ValueRef {
        // 1. Check local buffer (Read-Your-Own-Writes)
        if (self.buffer.get(key)) |val| {
            return SSTable.ValueRef{
                .data = val,
                .handle = null,
                .owned_buffer = null,
                .allocator = self.allocator,
            };
        }

        // 2. Check Storage (MemTable + Immutable + SSTables)
        // Use self.allocator (GPA) instead of arena, so ValueRef.deinit can free owned buffers immediately.
        return self.manager.storage_read_fn(self.manager.storage_ptr, self.allocator, key, self.read_version);
    }

    pub fn commit(self: *Transaction) !void {
        try self.manager.commit(self);
    }

    pub fn scan(self: *Transaction, start_key: []const u8) !MergedIterator {
        var iter = MergedIterator.init(self.allocator, self.read_version);
        errdefer iter.deinit();
        
        const storage_iter = try self.manager.storage_iterator_fn(self.manager.storage_ptr, self.read_version);
        try iter.add(storage_iter);
        
        // Add local buffer iterator with current read_version (which is > any committed version visible)
        const buf_iter = try Wrappers.HashMapIteratorWrapper.create(self.allocator, self.buffer, self.read_version);
        try iter.add(buf_iter);
        
        try iter.seek(start_key);
        return iter;
    }
};

fn mockStorageRead(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, version: u64) anyerror!?SSTable.ValueRef {
    const memtable: *MemTable = @ptrCast(@alignCast(ptr));
    if (memtable.get(key, version)) |val| {
        const val_dup = try allocator.dupe(u8, val);
        return SSTable.ValueRef{
            .data = val_dup,
            .handle = null,
            .owned_buffer = val_dup,
            .allocator = allocator,
        };
    }
    return null;
}

const MockIterator = struct {
    inner: MergedIterator,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, read_version: u64) MockIterator {
        return .{
            .inner = MergedIterator.init(allocator, read_version),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *MockIterator) void {
        self.inner.deinit();
    }
    pub fn iterator(self: *MockIterator) Iterator {
         return Iterator{
            .ptr = self,
            .vtable = &vtable,
        };
    }
    const vtable = Iterator.VTable{
        .next = wrapNext,
        .seek = wrapSeek,
        .deinit = wrapDeinit,
    };
    fn wrapNext(ptr: *anyopaque) anyerror!?@import("../lsm/iterator.zig").Entry {
        const self: *MockIterator = @ptrCast(@alignCast(ptr));
        return self.inner.next();
    }
    fn wrapSeek(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *MockIterator = @ptrCast(@alignCast(ptr));
        return self.inner.seek(key);
    }
    fn wrapDeinit(ptr: *anyopaque) void {
        const self: *MockIterator = @ptrCast(@alignCast(ptr));
        self.deinit();
        self.allocator.destroy(self);
    }
};

fn mockStorageIterator(ptr: *anyopaque, read_version: u64) anyerror!Iterator {
    _ = ptr;
    const mock = try std.testing.allocator.create(MockIterator);
    mock.* = MockIterator.init(std.testing.allocator, read_version);
    return mock.iterator();
}

fn mockStorageLatestVer(ptr: *anyopaque, key: []const u8) ?u64 {
    const memtable: *MemTable = @ptrCast(@alignCast(ptr));
    return memtable.getLatestVersion(key);
}

test "Transaction basic flow" {
    const allocator = std.testing.allocator;

    // Setup
    var memtable = try MemTable.init(allocator);
    defer memtable.deinit();

    const test_path = "test_txn.wal";
    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    var wal = try WAL.init(allocator, test_path, .Full);
    defer wal.deinit();

    var tm = try TransactionManager.create(allocator, memtable, &wal, memtable, mockStorageRead, mockStorageIterator, mockStorageLatestVer, 0);
    defer tm.destroy();

    // Txn 1: Insert A=1
    var txn1 = try tm.begin();
    defer txn1.deinit();
    try txn1.put("A", "1");
    try txn1.commit();

    // Txn 2: Read A, Insert B=2
    var txn2 = try tm.begin();
    defer txn2.deinit();

    if (try txn2.get("A")) |valA| {
        defer valA.deinit();
        try std.testing.expectEqualStrings("1", valA.data);
    } else {
        try std.testing.expect(false);
    }

    try txn2.put("B", "2");

    // Txn 3: Concurrent read (should not see B)
    var txn3 = try tm.begin();
    defer txn3.deinit();
    const valB = try txn3.get("B");
    try std.testing.expect(valB == null);

    try txn2.commit();

    // Txn 4: Read B (should see it now)
    var txn4 = try tm.begin();
    defer txn4.deinit();
    if (try txn4.get("B")) |valB2| {
        defer valB2.deinit();
        try std.testing.expectEqualStrings("2", valB2.data);
    } else {
        try std.testing.expect(false);
    }
}

test "Transaction conflict detection" {
    const allocator = std.testing.allocator;

    // Setup
    var memtable = try MemTable.init(allocator);
    defer memtable.deinit();

    const test_path = "test_txn_conflict.wal";
    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    var wal = try WAL.init(allocator, test_path, .Full);
    defer wal.deinit();

    var tm = try TransactionManager.create(allocator, memtable, &wal, memtable, mockStorageRead, mockStorageIterator, mockStorageLatestVer, 0);
    defer tm.destroy();

    // Txn 1: Starts at v1
    var txn1 = try tm.begin();
    defer txn1.deinit();

    // Txn 2: Starts at v1 (same view as txn1)
    var txn2 = try tm.begin();
    defer txn2.deinit();

    // Txn 1 modifies "key1"
    try txn1.put("key1", "value1");
    try txn1.commit(); // Commits at v2. key1 is now v2.

    // Txn 2 tries to modify "key1"
    try txn2.put("key1", "value2");
    
    // Txn 2 should fail to commit because it read at v1, but key1 is at v2.
    try std.testing.expectError(error.Conflict, txn2.commit());
}