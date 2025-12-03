const std = @import("std");
const Allocator = std.mem.Allocator;
const MemTable = @import("memtable.zig").MemTable;
const SSTable = @import("sstable.zig").SSTable;
const Manifest = @import("manifest.zig").Manifest;
const BlockCache = @import("block_cache.zig").BlockCache;
const MergedIterator = @import("merged_iterator.zig").MergedIterator;
const Wrappers = @import("iterator_wrappers.zig");
const LevelIterator = @import("level_iterator.zig").LevelIterator;
const Comparator = @import("comparator.zig");
const TableInfo = @import("table_info.zig").TableInfo;

pub const TableMetadata = Manifest.TableMetadata;

pub const Version = struct {
    allocator: Allocator,
    memtable: *MemTable,
    immutables: std.ArrayListUnmanaged(*MemTable),
    levels: [Manifest.MAX_LEVELS]std.ArrayListUnmanaged(*TableInfo),
    ref_count: std.atomic.Value(usize),

    pub fn init(allocator: Allocator, mem: *MemTable) !*Version {
        const self = try allocator.create(Version);
        self.allocator = allocator;
        self.memtable = mem;
        self.memtable.ref(); // Strong reference
        self.immutables = .{};
        for (&self.levels) |*l| l.* = .{};
        self.ref_count = std.atomic.Value(usize).init(1);
        return self;
    }

    pub fn ref(self: *Version) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn unref(self: *Version) void {
        const prev = self.ref_count.fetchSub(1, .release);
        if (prev == 1) {
            _ = self.ref_count.load(.acquire);
            self.deinit();
        }
    }

    fn deinit(self: *Version) void {
        self.memtable.unref();
        for (self.immutables.items) |m| {
            m.unref();
        }
        self.immutables.deinit(self.allocator);
        for (&self.levels) |*l| {
            for (l.items) |t| {
                t.unref();
            }
            l.deinit(self.allocator);
        }
        self.allocator.destroy(self);
    }

    pub fn get(self: *Version, allocator: Allocator, key: []const u8, version: u64) !?SSTable.ValueRef {
        // 1. MemTable
        if (self.memtable.get(key, version)) |val| {
            if (val.len == 0) return null;
            const val_dup = try allocator.dupe(u8, val);
            return SSTable.ValueRef{
                .data = val_dup,
                .handle = null,
                .owned_buffer = val_dup,
                .allocator = allocator,
            };
        }

        // 2. Immutables
        var i = self.immutables.items.len;
        while (i > 0) {
            i -= 1;
            const mem = self.immutables.items[i];
            if (mem.get(key, version)) |val| {
                if (val.len == 0) return null;
                const val_dup = try allocator.dupe(u8, val);
                return SSTable.ValueRef{
                    .data = val_dup,
                    .handle = null,
                    .owned_buffer = val_dup,
                    .allocator = allocator,
                };
            }
        }

        // 3. SSTables
        for (self.levels, 0..) |level, level_idx| {
            if (level_idx == 0) {
                var j = level.items.len;
                while (j > 0) {
                    j -= 1;
                    const table = level.items[j];
                    if (keyInRange(key, table.min_key, table.max_key)) {
                        if (table.reader) |reader| {
                            if (try reader.get(allocator, key, version)) |val_ref| {
                                if (val_ref.data.len == 0) {
                                    val_ref.deinit();
                                    return null;
                                }
                                return val_ref;
                            }
                        }
                    }
                }
            } else {
                var left: usize = 0;
                var right: usize = level.items.len;
                var candidate_idx: ?usize = null;

                while (left < right) {
                    const mid = left + (right - left) / 2;
                    const cmp = Comparator.compare(level.items[mid].min_key, key);
                    if (cmp != .gt) {
                        candidate_idx = mid;
                        left = mid + 1;
                    } else {
                        right = mid;
                    }
                }

                if (candidate_idx) |idx| {
                    const table = level.items[idx];
                    if (Comparator.compare(key, table.max_key) != .gt) {
                        if (table.reader) |reader| {
                            if (try reader.get(allocator, key, version)) |val_ref| {
                                if (val_ref.data.len == 0) {
                                    val_ref.deinit();
                                    return null;
                                }
                                return val_ref;
                            }
                        }
                    }
                }
            }
        }
        return null;
    }

    pub fn getLatestVersion(self: *Version, key: []const u8) !?u64 {
        // 1. MemTable
        if (self.memtable.getLatestVersion(key)) |ver| return ver;

        // 2. Immutables
        var i = self.immutables.items.len;
        while (i > 0) {
            i -= 1;
            const mem = self.immutables.items[i];
            if (mem.getLatestVersion(key)) |ver| return ver;
        }

        // 3. SSTables
        for (self.levels, 0..) |level, level_idx| {
            if (level_idx == 0) {
                var j = level.items.len;
                while (j > 0) {
                    j -= 1;
                    const table = level.items[j];
                    if (keyInRange(key, table.min_key, table.max_key)) {
                        if (table.reader) |reader| {
                            if (reader.getLatestVersion(key) catch null) |ver| return ver;
                        }
                    }
                }
            } else {
                var left: usize = 0;
                var right: usize = level.items.len;
                var candidate_idx: ?usize = null;

                while (left < right) {
                    const mid = left + (right - left) / 2;
                    const cmp = Comparator.compare(level.items[mid].min_key, key);
                    if (cmp != .gt) {
                        candidate_idx = mid;
                        left = mid + 1;
                    } else {
                        right = mid;
                    }
                }

                if (candidate_idx) |idx| {
                    const table = level.items[idx];
                    if (Comparator.compare(key, table.max_key) != .gt) {
                        if (table.reader) |reader| {
                            if (reader.getLatestVersion(key) catch null) |ver| return ver;
                        }
                    }
                }
            }
        }
        return null;
    }

    pub fn createIterator(self: *Version, read_version: u64) !MergedIterator {
        var iter = MergedIterator.init(self.allocator, read_version);
        errdefer iter.deinit();

        // 1. Active MemTable
        try iter.add(try Wrappers.MemTableIteratorWrapper.create(self.allocator, try self.memtable.iterator()));

        // 2. Immutable MemTables
        for (self.immutables.items) |mem| {
            try iter.add(try Wrappers.MemTableIteratorWrapper.create(self.allocator, try mem.iterator()));
        }

        // 3. SSTables
        for (self.levels, 0..) |level, i| {
            if (i == 0) {
                for (level.items) |table| {
                    if (table.reader) |reader_ptr| {
                        const sst_iter = reader_ptr.iterator();
                        try iter.add(try Wrappers.SSTableIteratorWrapper.create(self.allocator, sst_iter));
                    }
                }
            } else {
                if (level.items.len > 0) {
                    const level_iter = try self.allocator.create(LevelIterator);
                    level_iter.* = LevelIterator.init(self.allocator, level.items);
                    try iter.add(level_iter.iterator());
                }
            }
        }
        return iter;
    }

    fn keyInRange(key: []const u8, min: []const u8, max: []const u8) bool {
        return Comparator.compare(key, min) != .lt and Comparator.compare(key, max) != .gt;
    }
};

pub const VersionSet = struct {
    allocator: Allocator,
    current: *Version,
    manifest: Manifest,
    mutex: std.Thread.Mutex,
    block_cache: *BlockCache,
    db_path: []const u8,
    compaction_cursors: [Manifest.MAX_LEVELS]usize,

    pub fn init(allocator: Allocator, db_path: []const u8, block_cache: *BlockCache, mem: *MemTable) !*VersionSet {
        const self = try allocator.create(VersionSet);
        self.allocator = allocator;
        self.db_path = try allocator.dupe(u8, db_path);
        self.block_cache = block_cache;
        self.mutex = .{};
        self.compaction_cursors = [_]usize{0} ** Manifest.MAX_LEVELS;

        const manifest_path = try std.fs.path.join(allocator, &.{ db_path, "MANIFEST" });
        defer allocator.free(manifest_path);
        self.manifest = try Manifest.init(allocator, manifest_path);
        errdefer self.manifest.deinit();

        self.current = try Version.init(allocator, mem);
        errdefer self.current.unref();

        // Populate levels from manifest
        for (self.manifest.levels, 0..) |level, i| {
            for (level.items) |table_meta| {
                var reader: ?*SSTable.Reader = null;

                // Open reader if available
                const path = try getTablePath(allocator, db_path, table_meta.id);
                defer allocator.free(path);
                reader = SSTable.Reader.open(allocator, path, block_cache) catch null;

                // Create TableInfo (It takes ownership of keys, so we duplicate)
                // And it takes ownership of Reader reference (if any)
                const info = try TableInfo.init(allocator, table_meta.id, table_meta.level, table_meta.min_key, table_meta.max_key, table_meta.file_size, reader);

                // We don't need to manually ref the reader here because init does it.
                // But if we opened it, we have 1 ref. 'init' adds another.
                // So we should unref our local ref.
                if (reader) |r| r.unref();

                try self.current.levels[i].append(allocator, info);
            }
        }

        return self;
    }

    pub fn deinit(self: *VersionSet) void {
        self.current.unref();
        self.manifest.deinit();
        self.allocator.free(self.db_path);
        self.allocator.destroy(self);
    }

    pub fn getCurrent(self: *VersionSet) *Version {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.current.ref();
        return self.current;
    }

    pub fn logAndApply(self: *VersionSet, edit: VersionEdit) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Create new Version
        const v = try Version.init(self.allocator, edit.new_memtable orelse self.current.memtable);
        errdefer v.unref();

        // Copy Immutables
        if (edit.new_memtable != null) {
            self.current.memtable.ref();
            try v.immutables.append(self.allocator, self.current.memtable);
        }

        for (self.current.immutables.items) |m| {
            if (edit.flushed_memtable) |flushed| {
                if (m == flushed) continue;
            }
            m.ref();
            try v.immutables.append(self.allocator, m);
        }

        // Copy Levels (Shallow Copy of TableInfo pointers + Ref)
        for (self.current.levels, 0..) |l, i| {
            try v.levels[i].ensureTotalCapacity(self.allocator, l.items.len);
            for (l.items) |t| {
                t.ref();
                v.levels[i].appendAssumeCapacity(t);
            }
        }

        // Apply SSTable changes
        if (edit.tables_to_add.items.len > 0 or edit.tables_to_delete.items.len > 0) {
            for (edit.tables_to_delete.items) |del_id| {
                for (&v.levels) |*l| {
                    var i: usize = 0;
                    while (i < l.items.len) {
                        if (l.items[i].id == del_id) {
                            const t = l.orderedRemove(i);
                            t.unref();
                        } else {
                            i += 1;
                        }
                    }
                }
            }

            for (edit.tables_to_add.items) |meta| {
                // Convert Metadata -> TableInfo
                // We use init (copy keys) instead of stealing to allow VersionEdit to safely own its keys for retry/cleanup.
                // The cost of copying keys for a few new tables is negligible.
                const info = try TableInfo.init(self.allocator, meta.id, meta.level, meta.min_key, meta.max_key, meta.file_size, meta.reader);

                try v.levels[meta.level].append(self.allocator, info);
            }
        }

        // Update Manifest
        if (edit.tables_to_add.items.len > 0 or edit.tables_to_delete.items.len > 0) {
            try self.manifest.apply(edit.tables_to_add.items, edit.tables_to_delete.items);
        }

        const old = self.current;
        self.current = v;
        old.unref();
    }

    fn getTablePath(allocator: Allocator, db_path: []const u8, file_id: u64) ![]const u8 {
        var buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, "table_{}.sst", .{file_id});
        return std.fs.path.join(allocator, &.{ db_path, filename });
    }
};

pub const VersionEdit = struct {
    allocator: Allocator,
    new_memtable: ?*MemTable = null,
    flushed_memtable: ?*MemTable = null,
    tables_to_add: std.ArrayListUnmanaged(TableMetadata) = .{},
    tables_to_delete: std.ArrayListUnmanaged(u64) = .{},

    pub fn init(allocator: Allocator) VersionEdit {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *VersionEdit) void {
        for (self.tables_to_add.items) |t| {
            self.allocator.free(t.min_key);
            self.allocator.free(t.max_key);
            if (t.reader) |r| r.unref();
        }
        self.tables_to_add.deinit(self.allocator);
        self.tables_to_delete.deinit(self.allocator);
    }

    pub fn release(self: *VersionEdit) void {
        for (self.tables_to_add.items) |t| {
            self.allocator.free(t.min_key);
            self.allocator.free(t.max_key);
            if (t.reader) |r| r.unref();
        }
        self.tables_to_add.clearRetainingCapacity();
        self.tables_to_delete.clearRetainingCapacity();
    }
};
