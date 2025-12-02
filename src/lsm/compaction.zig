const std = @import("std");
const Allocator = std.mem.Allocator;
const SSTable = @import("sstable.zig").SSTable;
const MemTable = @import("memtable.zig").MemTable;
const Manifest = @import("manifest.zig").Manifest;
const Comparator = @import("comparator.zig");
const TableInfo = @import("table_info.zig").TableInfo;

pub const Compaction = struct {
    /// Iterator interface for merging
    pub const Iterator = struct {
        ptr: *anyopaque,
        nextFn: *const fn (ptr: *anyopaque) anyerror!?Entry,
        deinitFn: *const fn (ptr: *anyopaque) void,

        pub const Entry = struct {
            key: []const u8,
            value: []const u8,
            version: u64,
        };

        pub fn next(self: Iterator) !?Entry {
            return self.nextFn(self.ptr);
        }

        pub fn deinit(self: Iterator) void {
            self.deinitFn(self.ptr);
        }
    };

    /// Wrapper for SSTable Iterator
    pub const SSTableIteratorWrapper = struct {
        iter: SSTable.Reader.Iterator,

        pub fn init(iter: SSTable.Reader.Iterator) SSTableIteratorWrapper {
            return .{ .iter = iter };
        }

        pub fn next(ptr: *anyopaque) !?Iterator.Entry {
            const self: *SSTableIteratorWrapper = @ptrCast(@alignCast(ptr));
            if (try self.iter.next()) |entry| {
                return Iterator.Entry{
                    .key = entry.key,
                    .value = entry.value,
                    .version = entry.version,
                };
            }
            return null;
        }

        pub fn deinit(ptr: *anyopaque) void {
            const self: *SSTableIteratorWrapper = @ptrCast(@alignCast(ptr));
            self.iter.deinit();
        }

        pub fn iterator(self: *SSTableIteratorWrapper) Iterator {
            return Iterator{
                .ptr = self,
                .nextFn = next,
                .deinitFn = deinit,
            };
        }
    };

    const HeapMergeIterator = @import("heap_merge.zig").HeapMergeIterator;
    
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

    /// MergeIterator: Merges multiple sorted iterators using a Min-Heap.
    pub const MergeIterator = HeapMergeIterator(Iterator.Entry, Iterator, NoOpCloner);

    pub const CompactResult = struct {
        id: u64,
        min_key: []u8,
        max_key: []u8,
        file_size: u64,
        max_version: u64,
    };

    pub fn compact(
        allocator: Allocator, 
        inputs: []const []const u8, 
        dir_path: []const u8, 
        gc_threshold: u64,
        target_file_size: u64,
        id_gen_ctx: *anyopaque,
        id_gen_fn: *const fn(ctx: *anyopaque) u64
    ) !std.ArrayListUnmanaged(CompactResult) {
        const readers = try allocator.alloc(*SSTable.Reader, inputs.len);
        var readers_init_count: usize = 0;
        
        defer {
            var i: usize = 0;
            while (i < readers_init_count) : (i += 1) {
                readers[i].unref();
            }
            allocator.free(readers);
        }

        const wrappers = try allocator.alloc(SSTableIteratorWrapper, inputs.len);
        defer {
            for (wrappers) |*w| {
                w.iter.deinit();
            }
            allocator.free(wrappers);
        } 

        const iterators = try allocator.alloc(Iterator, inputs.len);
        defer allocator.free(iterators);

        for (inputs, 0..) |path, i| {
            readers[i] = try SSTable.Reader.open(allocator, path, null);
            readers_init_count += 1;
            
            wrappers[i] = SSTableIteratorWrapper.init(readers[i].iterator());
            iterators[i] = wrappers[i].iterator();
        }

        var merge_iter = try MergeIterator.init(allocator, iterators);
        defer merge_iter.deinit();

        var results = std.ArrayListUnmanaged(CompactResult){};
        errdefer {
            for (results.items) |res| {
                allocator.free(res.min_key);
                allocator.free(res.max_key);
            }
            results.deinit(allocator);
        }

        var current_builder: ?SSTable.Builder = null;
        var current_id: u64 = 0;
        var current_min_key: ?[]u8 = null;
        errdefer if (current_min_key) |k| allocator.free(k);
        
        var current_key_buf = std.ArrayListUnmanaged(u8){};
        defer current_key_buf.deinit(allocator);
        var max_key_buf = std.ArrayListUnmanaged(u8){};
        defer max_key_buf.deinit(allocator);
        
        var current_max_version: u64 = 0;

        var found_snapshot_version = false;

        while (try merge_iter.next()) |entry| {
             const is_new_key = !std.mem.eql(u8, current_key_buf.items, entry.key);
             
             if (is_new_key) {
                 current_key_buf.clearRetainingCapacity();
                 try current_key_buf.appendSlice(allocator, entry.key);
                 found_snapshot_version = false;
             }
             
             var keep = false;
             if (entry.version > gc_threshold) {
                 keep = true;
             } else {
                 if (!found_snapshot_version) {
                     if (entry.value.len > 0) {
                         keep = true;
                     }
                     found_snapshot_version = true;
                 }
             }

             if (keep) {
                 if (current_builder == null) {
                     current_id = id_gen_fn(id_gen_ctx);
                     var buf: [64]u8 = undefined;
                     const filename = try std.fmt.bufPrint(&buf, "table_{}.sst", .{current_id});
                     const path = try std.fs.path.join(allocator, &.{ dir_path, filename });
                     defer allocator.free(path);
                     
                     const estimated_count = target_file_size / 100;
                     current_builder = try SSTable.Builder.init(allocator, path, true, estimated_count, 64 * 1024); 
                     current_min_key = try allocator.dupe(u8, entry.key);
                     current_max_version = 0;
                 }

                 try current_builder.?.add(entry.key, entry.value, entry.version);
                 if (entry.version > current_max_version) current_max_version = entry.version;
                 
                 max_key_buf.clearRetainingCapacity();
                 try max_key_buf.appendSlice(allocator, entry.key);

                 if (current_builder.?.block_start_offset >= target_file_size) {
                     const size = try current_builder.?.finish();
                     current_builder.?.deinit();
                     current_builder = null;

                     {
                         const max_k = try allocator.dupe(u8, max_key_buf.items);
                         errdefer allocator.free(max_k);
                         try results.append(allocator, CompactResult{
                             .id = current_id,
                             .min_key = current_min_key.?,
                             .max_key = max_k,
                             .file_size = size,
                             .max_version = current_max_version,
                         });
                     }
                     current_min_key = null;
                 }
             }
        }

        if (current_builder) |*b| {
             const size = try b.finish();
             b.deinit();
             
             if (current_min_key != null) {
                 {
                     const max_k = try allocator.dupe(u8, max_key_buf.items);
                     errdefer allocator.free(max_k);
                     try results.append(allocator, CompactResult{
                         .id = current_id,
                         .min_key = current_min_key.?,
                         .max_key = max_k,
                         .file_size = size,
                         .max_version = current_max_version,
                     });
                 }
                 current_min_key = null;
             }
        } else {
             if (current_min_key) |k| allocator.free(k);
        }

        return results;
    }
};

pub const CompactionPolicy = struct {
    pub const Options = struct {
        l0_file_limit: usize = 4,
        l1_size_limit: u64 = 250 * 1024 * 1024,
    };

    pub const Task = struct {
        level: usize,
        source_tables: std.ArrayListUnmanaged(*TableInfo),
        next_level_tables: std.ArrayListUnmanaged(*TableInfo),

        pub fn deinit(self: *Task, allocator: Allocator) void {
            for (self.source_tables.items) |t| t.unref();
            self.source_tables.deinit(allocator);
            
            for (self.next_level_tables.items) |t| t.unref();
            self.next_level_tables.deinit(allocator);
        }
    };

    pub fn pick(allocator: Allocator, levels: []const std.ArrayListUnmanaged(*TableInfo), cursors: []usize, options: Options) !?Task {
        const GROWTH_FACTOR = 10;

        var best_level: ?usize = null;
        var best_score: f64 = 0.0;

        // 1. Calculate Scores
        for (0..Manifest.MAX_LEVELS - 1) |i| {
            const level = levels[i];
            var score: f64 = 0.0;

            if (i == 0) {
                score = @as(f64, @floatFromInt(level.items.len)) / @as(f64, @floatFromInt(options.l0_file_limit));
            } else {
                var total_size: u64 = 0;
                for (level.items) |tbl| {
                    total_size += tbl.file_size;
                }
                
                var target_size: u64 = options.l1_size_limit;
                var p: usize = 1;
                while (p < i) : (p += 1) {
                    target_size *= GROWTH_FACTOR;
                }
                
                score = @as(f64, @floatFromInt(total_size)) / @as(f64, @floatFromInt(target_size));
            }

            if (score > best_score) {
                best_score = score;
                best_level = i;
            }
        }

        if (best_score < 1.0) return null;
        if (best_level == null) return null;

        const i = best_level.?;
        const level = levels[i];
        
        var task = Task{
            .level = i,
            .source_tables = .{},
            .next_level_tables = .{},
        };
        // If we fail to construct a valid task (e.g. due to locks), we must cleanup.
        // But wait, if we mark files as compacting, we must own them.
        // Strategy: Collect candidates first. If ALL candidates are free, lock them and return task.
        // If any are locked, abort this attempt (return null).
        // Note: This is optimistic.
        
        var candidates_src = std.ArrayListUnmanaged(*TableInfo){};
        defer candidates_src.deinit(allocator);
        
        var candidates_next = std.ArrayListUnmanaged(*TableInfo){};
        defer candidates_next.deinit(allocator);

        if (i == 0) {
            // L0 -> L1: Merge ALL L0 files + Overlapping L1 files
            var l0_min: ?[]const u8 = null;
            var l0_max: ?[]const u8 = null;

            for (level.items) |tbl| {
                if (tbl.is_compacting.load(.acquire)) return null; // L0 compaction requires ALL L0 files usually or at least contiguous range. Here we take ALL.
                
                try candidates_src.append(allocator, tbl);
                
                if (l0_min == null or Comparator.compare(tbl.min_key, l0_min.?) == .lt) l0_min = tbl.min_key;
                if (l0_max == null or Comparator.compare(tbl.max_key, l0_max.?) == .gt) l0_max = tbl.max_key;
            }
            
            // If L0 is empty, nothing to do (shouldn't happen given score calculation)
            if (candidates_src.items.len == 0) return null;

            if (l0_min != null) {
                const next_level = levels[i + 1];
                for (next_level.items) |tbl| {
                        if (!(Comparator.compare(tbl.max_key, l0_min.?) == .lt or Comparator.compare(tbl.min_key, l0_max.?) == .gt)) {
                            if (tbl.is_compacting.load(.acquire)) return null; // Conflict in L1
                            try candidates_next.append(allocator, tbl);
                        }
                }
            }
        } else {
            if (level.items.len == 0) return null; 

            // For L1+, we pick one file (round robin)
            // We need to find a file that is NOT compacting.
            var attempts: usize = 0;
            var pick_idx = cursors[i];
            var pick_tbl: *TableInfo = undefined;
            var found = false;

            while (attempts < level.items.len) : (attempts += 1) {
                if (pick_idx >= level.items.len) pick_idx = 0;
                const t = level.items[pick_idx];
                if (!t.is_compacting.load(.acquire)) {
                    pick_tbl = t;
                    found = true;
                    break;
                }
                pick_idx += 1;
            }
            
            if (!found) return null; // All files in this level are busy

            // Update cursor for NEXT time
            cursors[i] = (pick_idx + 1) % level.items.len;

            try candidates_src.append(allocator, pick_tbl);

            const next_level = levels[i + 1];
            for (next_level.items) |tbl| {
                    if (!(Comparator.compare(tbl.max_key, pick_tbl.min_key) == .lt or Comparator.compare(tbl.min_key, pick_tbl.max_key) == .gt)) {
                        if (tbl.is_compacting.load(.acquire)) return null; // Conflict in next level
                        try candidates_next.append(allocator, tbl);
                    }
            }
        }
        
        // If we reached here, we have a valid set of candidates that were free at check time.
        // Now we must atomic-check-and-set.
        // Since we are under a global version mutex (assumed caller holds it), 
        // checking and setting is safe from other threads modifying THE LIST, 
        // but `is_compacting` prevents other compaction threads from picking the same.
        // Caller (DB) handles `versions.mutex`. So we are safe to just set.
        
        for (candidates_src.items) |t| {
            t.is_compacting.store(true, .release);
            t.ref();
            try task.source_tables.append(allocator, t);
        }
        for (candidates_next.items) |t| {
             t.is_compacting.store(true, .release);
             t.ref();
             try task.next_level_tables.append(allocator, t);
        }

        return task;
    }
};

const MockIdGen = struct {
    next_id: u64 = 100,
    pub fn gen(ctx: *anyopaque) u64 {
        var self: *MockIdGen = @ptrCast(@alignCast(ctx));
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

test "Compaction basic flow" {
    // This test needs to be updated if we want to test CompactionPolicy, 
    // but Compaction.compact works on paths and is largely unchanged.
    // We can keep this test as is.
    const allocator = std.testing.allocator;
    const path1 = "t1.sst";
    const path2 = "t2.sst";
    const dir = ".";
    
    defer {
        std.fs.cwd().deleteFile(path1) catch {};
        std.fs.cwd().deleteFile(path2) catch {};
        std.fs.cwd().deleteFile("table_100.sst") catch {};
    }

    {
        var b = try SSTable.Builder.init(allocator, path1, true, 1, 4096);
        try b.add("key1", "val1_v10", 10);
        _ = try b.finish();
        b.deinit();
    }

    {
        var b = try SSTable.Builder.init(allocator, path2, true, 2, 4096);
        try b.add("key1", "val1_v20", 20); 
        try b.add("key2", "val2_v20", 20);
        _ = try b.finish();
        b.deinit();
    }

    const inputs = [_][]const u8{ path1, path2 };
    var id_gen = MockIdGen{};
    var results = try Compaction.compact(allocator, &inputs, dir, 15, 1024 * 1024, &id_gen, MockIdGen.gen);
    defer {
        for (results.items) |r| {
            allocator.free(r.min_key);
            allocator.free(r.max_key);
        }
        results.deinit(allocator);
    }
    
    try std.testing.expectEqual(results.items.len, 1);
    try std.testing.expectEqual(results.items[0].id, 100);
}