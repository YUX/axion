const std = @import("std");
const log = @import("log.zig");
const metrics = @import("metrics.zig");
const MemTable = @import("lsm/memtable.zig").MemTable;
const WAL = @import("lsm/wal.zig").WAL;
const TransactionManager = @import("mvcc/transaction.zig").TransactionManager;
const Transaction = @import("mvcc/transaction.zig").Transaction;

const SSTable = @import("lsm/sstable.zig").SSTable;
const Compaction = @import("lsm/compaction.zig").Compaction;
const BlockCache = @import("lsm/block_cache.zig").BlockCache;

const Iterator = @import("lsm/iterator.zig").Iterator;
const MergedIterator = @import("lsm/merged_iterator.zig").MergedIterator;
const SnapshotIterator = @import("lsm/snapshot_iterator.zig").SnapshotIterator;
const Wrappers = @import("lsm/iterator_wrappers.zig");
const VersionSet = @import("lsm/version_set.zig").VersionSet;
const VersionEdit = @import("lsm/version_set.zig").VersionEdit;
const CompositeKey = @import("lsm/composite_key.zig");

pub const IndexUpdate = struct {
    id: u32,
    old_value: ?[]const u8,
    new_value: ?[]const u8,
};

pub const DB = struct {
    pub const DBOptions = struct {
        memtable_size_bytes: usize = 64 * 1024 * 1024,
        l0_file_limit: usize = 4,
        l1_size_bytes: u64 = 512 * 1024 * 1024,
        wal_sync_mode: WAL.SyncMode = .Full,
        block_size: usize = 64 * 1024, // New Option
        block_cache_size_bytes: usize = 10 * 1024 * 1024,
        compaction_threads: usize = 1,
    };

    allocator: std.mem.Allocator,
    options: DBOptions,

    versions: *VersionSet, // Manages Version, Manifest, MemTables

    wal: WAL,
    tm: *TransactionManager,
    db_path: []const u8,

    // Background Flush
    flush_thread: std.Thread,
    flush_mutex: std.Thread.Mutex,
    flush_cond: std.Thread.Condition,

    // Background Compaction
    compaction_threads: []std.Thread,
    compaction_mutex: std.Thread.Mutex,
    compaction_cond: std.Thread.Condition,

    running: std.atomic.Value(bool),
    bg_error: std.atomic.Value(usize),

    // Flow Control
    flow_mutex: std.Thread.Mutex,
    flow_cond: std.Thread.Condition,

    const MAX_PENDING_MEMTABLES = 8;

    pub fn open(allocator: std.mem.Allocator, dir_path: []const u8, options: DBOptions) !*DB {
        const self = try allocator.create(DB);
        self.allocator = allocator;
        self.options = options;
        self.db_path = try allocator.dupe(u8, dir_path);

        // Initialize Block Cache
        const block_cache = BlockCache.init(allocator, options.block_cache_size_bytes);
        const bc_ptr = try allocator.create(BlockCache);
        bc_ptr.* = block_cache;

        // Ensure directory exists
        std.fs.cwd().makePath(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Initialize MemTable
        const memtable = try MemTable.init(allocator);
        errdefer memtable.unref();

        // Initialize VersionSet
        // VersionSet.init calls Version.init, which REFs the memtable. ref=2.
        self.versions = try VersionSet.init(allocator, dir_path, bc_ptr, memtable);

        // We don't need our reference anymore.
        memtable.unref(); // ref=1 (held by Version)

        const wal_path = try std.fs.path.join(allocator, &.{ dir_path, "WAL" });
        defer allocator.free(wal_path);

        self.wal = try WAL.init(allocator, wal_path, options.wal_sync_mode);

        // Replay WAL
        var max_version: u64 = 0;
        {
            // Find max persisted version in Manifest
            var max_persisted: u64 = 0;
            self.versions.mutex.lock();
            for (self.versions.manifest.levels) |level| {
                for (level.items) |meta| {
                    if (meta.max_version > max_persisted) max_persisted = meta.max_version;
                }
            }
            self.versions.mutex.unlock();

            const v = self.versions.getCurrent();
            defer v.unref();
            max_version = try self.wal.replay(v.memtable, max_persisted);
        }

        // Initialize TransactionManager
        {
            const v = self.versions.getCurrent();
            defer v.unref();

            self.tm = try TransactionManager.create(allocator, v.memtable, &self.wal, self, storageGet, storageIterator, storageGetLatestVersion, max_version);
        }

        // Start Background Threads
        self.running = std.atomic.Value(bool).init(true);
        self.bg_error = std.atomic.Value(usize).init(0);

        self.flush_mutex = std.Thread.Mutex{};
        self.flush_cond = std.Thread.Condition{};

        self.compaction_mutex = std.Thread.Mutex{};
        self.compaction_cond = std.Thread.Condition{};

        self.flow_mutex = std.Thread.Mutex{};
        self.flow_cond = std.Thread.Condition{};

        self.flush_thread = try std.Thread.spawn(.{}, flushLoop, .{self});

        const num_compaction_threads = if (options.compaction_threads > 0) options.compaction_threads else 1;
        self.compaction_threads = try allocator.alloc(std.Thread, num_compaction_threads);
        for (self.compaction_threads) |*t| {
            t.* = try std.Thread.spawn(.{}, compactionLoop, .{self});
        }

        return self;
    }

    pub fn close(self: *DB) void {
        // Stop bg threads
        self.running.store(false, .release);

        self.flush_mutex.lock();
        self.flush_cond.signal();
        self.flush_mutex.unlock();

        self.compaction_mutex.lock();
        self.compaction_cond.broadcast();
        self.compaction_mutex.unlock();

        self.flush_thread.join();
        for (self.compaction_threads) |t| {
            t.join();
        }
        self.allocator.free(self.compaction_threads);

        self.tm.destroy();
        self.wal.deinit();

        // We should free the block cache pointer we allocated
        const bc_ptr = self.versions.block_cache;

        self.versions.deinit();

        bc_ptr.deinit();
        self.allocator.destroy(bc_ptr);

        self.allocator.free(self.db_path);
        self.allocator.destroy(self);
    }

    fn storageGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, version: u64) anyerror!?SSTable.ValueRef {
        const self: *DB = @ptrCast(@alignCast(ptr));
        const v = self.versions.getCurrent();
        defer v.unref();
        return v.get(allocator, key, version);
    }
    fn storageIterator(ptr: *anyopaque, read_version: u64) anyerror!Iterator {
        const self: *DB = @ptrCast(@alignCast(ptr));
        const snapshot_iter = try self.createIterator(read_version);
        const heap_iter = try self.allocator.create(SnapshotIterator);
        heap_iter.* = snapshot_iter;
        return heap_iter.iterator();
    }

    fn storageGetLatestVersion(ptr: *anyopaque, key: []const u8) ?u64 {
        const self: *DB = @ptrCast(@alignCast(ptr));
        const v = self.versions.getCurrent();
        defer v.unref();
        return v.getLatestVersion(key) catch null;
    }

    pub fn getLatestCommitVersion(self: *DB, key: []const u8) ?u64 {
        const v = self.versions.getCurrent();
        defer v.unref();
        return v.getLatestVersion(key) catch null;
    }

    pub fn checkBgError(self: *DB) !void {
        const err_int = self.bg_error.load(.acquire);
        if (err_int != 0) {
            return error.DatabaseCompromised;
        }
    }

    pub fn checkMemTableCapacity(self: *DB) !void {
        // Check flow control
        self.flow_mutex.lock();
        defer self.flow_mutex.unlock();

        while (true) {
            const v = self.versions.getCurrent();
            const pending = v.immutables.items.len;
            v.unref();

            if (pending < MAX_PENDING_MEMTABLES) break;

            self.flow_cond.wait(&self.flow_mutex);
            try self.checkBgError();
        }

        // Check current memtable size
        const v = self.versions.getCurrent();
        const size = v.memtable.approxSize();
        v.unref();

        if (size >= self.options.memtable_size_bytes) {
            try self.rotateMemTable();
        }
    }

    pub fn beginTransaction(self: *DB) !Transaction {
        try self.checkBgError();
        return self.tm.begin();
    }

    pub fn put(self: *DB, key: []const u8, value: []const u8) !void {
        metrics.global.put();
        try self.checkBgError();
        try self.checkMemTableCapacity();

        var txn = try self.beginTransaction();
        defer txn.deinit();
        try txn.put(key, value);
        try txn.commit();
    }

    pub fn delete(self: *DB, key: []const u8) !void {
        try self.checkBgError();
        try self.checkMemTableCapacity();

        var txn = try self.beginTransaction();
        defer txn.deinit();
        try txn.delete(key);
        try txn.commit();
    }

    /// Atomically updates a primary record and its associated secondary index entries.
    /// This ensures consistency between the data and the index.
    /// - key: The Primary Key.
    /// - value: The Primary Value.
    /// - updates: A list of index updates. For each index, provide the old value (to delete) and/or new value (to insert).
    pub fn putIndexed(self: *DB, key: []const u8, value: []const u8, updates: []const IndexUpdate) !void {
        try self.checkBgError();
        try self.checkMemTableCapacity();

        var txn = try self.beginTransaction();
        defer txn.deinit();

        // 1. Update Primary Record
        try txn.put(key, value);

        // 2. Update Indexes
        for (updates) |up| {
            // If there was an old value, remove the old index entry
            if (up.old_value) |old_val| {
                const old_idx_key = try CompositeKey.encodeIndexKey(self.allocator, up.id, old_val, key);
                defer self.allocator.free(old_idx_key);
                try txn.delete(old_idx_key);
            }

            // If there is a new value, add the new index entry
            if (up.new_value) |new_val| {
                const new_idx_key = try CompositeKey.encodeIndexKey(self.allocator, up.id, new_val, key);
                defer self.allocator.free(new_idx_key);
                // The value of the index entry is arbitrary but must be non-empty to distinguish from deletion (tombstone).
                try txn.put(new_idx_key, "\x01");
            }
        }

        try txn.commit();
    }

    /// Returns an iterator positioned at the start of the specified index (and optional value).
    /// The iterator will yield Index Keys. Use `CompositeKey.extractPrimaryKey` to get the PK.
    pub fn getIndexIterator(self: *DB, index_id: u32, start_value: ?[]const u8) !SnapshotIterator {
        // Create a base iterator using the current global version as the snapshot.
        const read_ver = self.tm.global_version.load(.acquire);
        var iter = try self.createIterator(read_ver);

        // Construct the seek key
        // If start_value is provided, we seek to that value.
        // If not, we seek to the start of the index (empty value).
        // Note: We use an empty PK for seeking to the start of the value group.
        const val = start_value orelse "";
        const seek_key = try CompositeKey.encodeIndexKey(self.allocator, index_id, val, "");
        defer self.allocator.free(seek_key);

        try iter.seek(seek_key);
        return iter;
    }

    fn rotateMemTable(self: *DB) !void {
        // Optimization: Init new memtable without lock
        const new_mem = try MemTable.init(self.allocator);
        errdefer new_mem.unref();

        // Lock commit to prevent writes during swap
        self.tm.batcher.lockExecution();
        defer self.tm.batcher.unlockExecution();

        // Double check size with fresh version
        const v = self.versions.getCurrent();
        if (v.memtable.approxSize() < self.options.memtable_size_bytes) {
            v.unref();
            new_mem.unref(); // Not needed
            return;
        }
        v.unref();

        var edit = VersionEdit.init(self.allocator);
        defer edit.deinit();
        edit.new_memtable = new_mem;

        try self.versions.logAndApply(edit);
        edit.release();

        // We unref new_mem. Version owns it now.
        new_mem.unref();

        // Update TM reference!
        self.tm.memtable = new_mem;

        // Signal Flush Thread
        self.flush_mutex.lock();
        self.flush_cond.signal();
        self.flush_mutex.unlock();
    }

    fn flushLoop(self: *DB) void {
        while (self.running.load(.monotonic)) {
            // Wait for work
            self.flush_mutex.lock();
            var has_work = false;
            {
                const v = self.versions.getCurrent();
                has_work = v.immutables.items.len > 0;
                v.unref();
            }

            if (!has_work and self.running.load(.monotonic)) {
                self.flush_cond.wait(&self.flush_mutex);
            }
            self.flush_mutex.unlock();

            if (!self.running.load(.monotonic)) break;

            // Process one memtable
            var mem_to_flush: ?*MemTable = null;
            {
                const ver = self.versions.getCurrent();
                defer ver.unref();
                // Flush the OLDEST immutable (last in list)
                if (ver.immutables.items.len > 0) {
                    mem_to_flush = ver.immutables.items[ver.immutables.items.len - 1];
                    mem_to_flush.?.ref();
                }
            }

            if (mem_to_flush) |mem| {
                self.flushMemTableToDisk(mem) catch |err| {
                    log.err(.db, "Critical Error flushing memtable: {}. System entering Read-Only mode.", .{err});
                    self.bg_error.store(1, .release);
                    mem.unref();
                    break;
                };
                metrics.global.flush();
                mem.unref();

                // Signal writers that space is available
                self.flow_mutex.lock();
                self.flow_cond.broadcast();
                self.flow_mutex.unlock();

                // Signal Compaction that new file exists
                self.compaction_mutex.lock();
                self.compaction_cond.signal();
                self.compaction_mutex.unlock();
            }
        }
    }

    fn compactionLoop(self: *DB) void {
        const CompactionPolicy = @import("lsm/compaction.zig").CompactionPolicy;

        while (self.running.load(.monotonic)) {
            // Wait for signal or timeout (to check periodically)
            self.compaction_mutex.lock();
            if (self.running.load(.monotonic)) {
                self.compaction_cond.timedWait(&self.compaction_mutex, 100 * std.time.ns_per_ms) catch {};
            }
            self.compaction_mutex.unlock();

            if (!self.running.load(.monotonic)) break;

            while (true) {
                if (self.bg_error.load(.acquire) != 0) break;

                // Check for compaction work
                var task_opt: ?CompactionPolicy.Task = null;
                {
                    // We MUST lock versions to ensure stable level view while picking
                    // and to atomic check-and-set is_compacting flags.
                    self.versions.mutex.lock();
                    defer self.versions.mutex.unlock();

                    const v = self.versions.current;
                    v.ref();
                    defer v.unref();

                    task_opt = CompactionPolicy.pick(self.allocator, &v.levels, &self.versions.compaction_cursors, .{
                        .l0_file_limit = self.options.l0_file_limit,
                        .l1_size_limit = self.options.l1_size_bytes,
                    }) catch null;
                }

                if (task_opt) |*task| {
                    // Run Compaction
                    self.executeCompaction(task) catch |err| {
                        log.err(.compaction, "Compaction Error: {}", .{err});
                        // Error handling done in executeCompaction cleanup
                    };
                    task.deinit(self.allocator);
                    // Loop again to check for more work
                } else {
                    break; // No more work
                }
            }
        }
    }

    pub fn getTablePath(self: *DB, file_id: u64) ![]const u8 {
        var buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, "table_{}.sst", .{file_id});
        return std.fs.path.join(self.allocator, &.{ self.db_path, filename });
    }

    fn flushMemTableToDisk(self: *DB, mem: *MemTable) !void {
        if (mem.approxSize() == 0) {
            var edit = VersionEdit.init(self.allocator);
            defer edit.deinit();
            edit.flushed_memtable = mem;
            try self.versions.logAndApply(edit);
            edit.release();
            return;
        }

        self.versions.mutex.lock();
        const file_id = self.versions.manifest.getNextFileId();
        self.versions.mutex.unlock();

        const path = try self.getTablePath(file_id);
        defer self.allocator.free(path);

        var builder = try SSTable.Builder.init(self.allocator, path, true, mem.count.load(.acquire), self.options.block_size);
        defer builder.deinit();

        var iter = try mem.iterator();
        defer iter.deinit();

        var min_key: ?[]const u8 = null;
        var max_key: ?[]const u8 = null;

        var max_version: u64 = 0;

        while (try iter.next()) |entry| {
            try builder.add(entry.key, entry.value, entry.version);

            if (min_key == null) min_key = entry.key;
            max_key = entry.key;
            if (entry.version > max_version) max_version = entry.version;
        }

        const f_size = try builder.finish();

        if (min_key) |min| {
            const min_dup = try self.allocator.dupe(u8, min);
            const max_dup = try self.allocator.dupe(u8, max_key.?);

            const reader = try SSTable.Reader.open(self.allocator, path, self.versions.block_cache);

            var edit = VersionEdit.init(self.allocator);
            defer edit.deinit();

            edit.flushed_memtable = mem;
            try edit.tables_to_add.append(self.allocator, .{
                .id = file_id,
                .level = 0,
                .min_key = min_dup,
                .max_key = max_dup,
                .file_size = f_size,
                .max_version = max_version,
                .reader = reader,
            });

            try self.versions.logAndApply(edit);
            edit.release();
        } else {
            var edit = VersionEdit.init(self.allocator);
            defer edit.deinit();
            edit.flushed_memtable = mem;
            try self.versions.logAndApply(edit);
            edit.release();
        }
    }

    fn dbIdGen(ctx: *anyopaque) u64 {
        const self: *DB = @ptrCast(@alignCast(ctx));
        self.versions.mutex.lock();
        defer self.versions.mutex.unlock();
        return self.versions.manifest.getNextFileId();
    }

    fn executeCompaction(self: *DB, task: *const @import("lsm/compaction.zig").CompactionPolicy.Task) !void {
        // Clean up is_compacting flags at the end, regardless of outcome.
        defer {
            for (task.source_tables.items) |tbl| tbl.is_compacting.store(false, .release);
            for (task.next_level_tables.items) |tbl| tbl.is_compacting.store(false, .release);
        }

        var inputs = std.ArrayListUnmanaged([]const u8){};
        var old_ids = std.ArrayListUnmanaged(u64){};

        defer {
            for (inputs.items) |p| self.allocator.free(p);
            inputs.deinit(self.allocator);
            old_ids.deinit(self.allocator);
        }

        for (task.source_tables.items) |tbl| {
            try old_ids.append(self.allocator, tbl.id);
            const p = try self.getTablePath(tbl.id);
            try inputs.append(self.allocator, p);
        }

        for (task.next_level_tables.items) |tbl| {
            try old_ids.append(self.allocator, tbl.id);
            const p = try self.getTablePath(tbl.id);
            try inputs.append(self.allocator, p);
        }

        const target_size = 64 * 1024 * 1024;

        var results = try Compaction.compact(self.allocator, inputs.items, self.db_path, self.tm.getMinActiveVersion(), target_size, self, dbIdGen);

        defer {
            for (results.items) |*r| {
                _ = r;
            }
            results.deinit(self.allocator);
        }

        if (results.items.len > 0) {
            metrics.global.compaction();
            var edit = VersionEdit.init(self.allocator);
            defer edit.deinit();

            try edit.tables_to_delete.appendSlice(self.allocator, old_ids.items);

            for (results.items) |res| {
                const path = try self.getTablePath(res.id);
                defer self.allocator.free(path);

                const reader = try SSTable.Reader.open(self.allocator, path, self.versions.block_cache);

                try edit.tables_to_add.append(self.allocator, .{
                    .id = res.id,
                    .level = task.level + 1,
                    .min_key = res.min_key,
                    .max_key = res.max_key,
                    .file_size = res.file_size,
                    .max_version = res.max_version,
                    .reader = reader,
                });
            }
            try self.versions.logAndApply(edit);
            edit.release();

            for (inputs.items) |p| {
                std.fs.cwd().deleteFile(p) catch |err| {
                    if (err != error.FileNotFound) {
                        log.warn(.compaction, "Failed to delete compacted file {s}: {}", .{ p, err });
                    }
                };
            }
        }
    }
    pub fn flushSync(self: *DB) !void {
        try self.rotateMemTable();

        while (true) {
            const v = self.versions.getCurrent();
            const len = v.immutables.items.len;
            v.unref();

            if (len == 0) break;
            std.Thread.yield() catch {};
        }
    }

    pub fn get(self: *DB, key: []const u8) !?SSTable.ValueRef {
        metrics.global.get();
        const txn = self.tm.beginReadOnly();
        defer self.tm.endReadOnly(txn);
        return self.getAtVersion(self.allocator, key, txn.read_version);
    }

    pub fn createIterator(self: *DB, read_version: u64) !SnapshotIterator {
        metrics.global.iterator();
        const v = self.versions.getCurrent();
        // Do not unref v here. SnapshotIterator takes ownership.
        const merged = try v.createIterator(read_version);
        return SnapshotIterator.init(self.allocator, merged, v);
    }

    fn getAtVersion(self: *DB, allocator: std.mem.Allocator, key: []const u8, version: u64) !?SSTable.ValueRef {
        const v = self.versions.getCurrent();
        defer v.unref();
        return v.get(allocator, key, version);
    }

    pub fn backup(self: *DB, backup_path: []const u8) !void {
        // 0. Flush to ensure consistency
        try self.flushSync();

        // 1. Create backup directory
        std.fs.cwd().makePath(backup_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
            // Else, path already exists, continue (allow backing up to existing dir)
        };

        // 2. Get a consistent snapshot of the current version
        const current_version = self.versions.getCurrent();
        defer current_version.unref(); // Release ref after backup is complete

        // 3. Copy MANIFEST file
        const manifest_src_path = try std.fs.path.join(self.allocator, &.{ self.db_path, "MANIFEST" });
        defer self.allocator.free(manifest_src_path);
        const manifest_dst_path = try std.fs.path.join(self.allocator, &.{ backup_path, "MANIFEST" });
        defer self.allocator.free(manifest_dst_path);

        std.fs.cwd().copyFile(manifest_src_path, std.fs.cwd(), manifest_dst_path, .{}) catch |err| {
            if (err != error.FileNotFound) return err; // If no manifest, then it's a fresh DB
        };

        // 4. Copy WAL file
        const wal_src_path = try std.fs.path.join(self.allocator, &.{ self.db_path, "WAL" });
        defer self.allocator.free(wal_src_path);
        const wal_dst_path = try std.fs.path.join(self.allocator, &.{ backup_path, "WAL" });
        defer self.allocator.free(wal_dst_path);

        std.fs.cwd().copyFile(wal_src_path, std.fs.cwd(), wal_dst_path, .{}) catch |err| {
            if (err != error.FileNotFound) return err; // If no wal, then it's a fresh DB
        };

        // 5. Copy all SSTable files referenced by this version
        for (current_version.levels) |level| {
            for (level.items) |table_info| {
                const sst_src_path = try self.getTablePath(table_info.id);
                defer self.allocator.free(sst_src_path);

                const sst_dst_filename = try std.fmt.allocPrint(self.allocator, "table_{}.sst", .{table_info.id});
                defer self.allocator.free(sst_dst_filename);
                const sst_dst_path = try std.fs.path.join(self.allocator, &.{ backup_path, sst_dst_filename });
                defer self.allocator.free(sst_dst_path);

                std.fs.cwd().copyFile(sst_src_path, std.fs.cwd(), sst_dst_path, .{}) catch |err| {
                    if (err != error.FileNotFound) return err; // Should not happen if manifest is correct
                };
            }
        }
    }
};

test "DB integration" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const test_path = try std.fmt.bufPrint(&buf, "test_db_dir_{}", .{std.crypto.random.int(u64)});

    std.fs.cwd().deleteTree(test_path) catch {};
    defer std.fs.cwd().deleteTree(test_path) catch {};

    // std.debug.print("Opening DB...\n", .{});
    {
        var db = try DB.open(allocator, test_path, .{});
        defer db.close();
        // std.debug.print("DB Opened.\n", .{});

        try db.put("user:1", "Alice");
        try db.put("user:2", "Bob");
        // std.debug.print("Puts done.\n", .{});

        if (try db.get("user:1")) |val| {
            defer val.deinit();
            try std.testing.expectEqualStrings("Alice", val.data);
        } else {
            try std.testing.expect(false);
        }
    }

    // Re-open to test durability
    {
        var db2 = try DB.open(allocator, test_path, .{});
        defer db2.close();

        if (try db2.get("user:1")) |val| {
            defer val.deinit();
            try std.testing.expectEqualStrings("Alice", val.data);
        } else {
            try std.testing.expect(false);
        }
    }
}

// ... other tests ...
