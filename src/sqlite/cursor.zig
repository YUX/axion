const std = @import("std");
const c = @import("c.zig").c;
const types = @import("types.zig");
const DB = @import("../db.zig").DB;
const Schema = @import("schema.zig");
const Row = @import("row.zig");
const MergedIterator = @import("../lsm/merged_iterator.zig").MergedIterator;
const SnapshotIterator = @import("../lsm/snapshot_iterator.zig").SnapshotIterator;
const Iterator = @import("../lsm/iterator.zig").Iterator;
const SSTable = @import("../lsm/sstable.zig").SSTable;
const CompositeKey = @import("../lsm/composite_key.zig");
const Comparator = @import("../lsm/comparator.zig");

const allocator = types.allocator;

pub fn xOpen(vtab: [*c]c.sqlite3_vtab, ppCursor: [*c][*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    _ = vtab;
    const cursor = allocator.create(types.AxionCursor) catch return c.SQLITE_NOMEM;
    const arena_ptr = allocator.create(std.heap.ArenaAllocator) catch {
        allocator.destroy(cursor);
        return c.SQLITE_NOMEM;
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);

    cursor.base = .{};
    cursor.iter = null;
    cursor.val_ref_ptr = null;
    cursor.read_txn_id = 0;
    cursor.read_txn_ver = 0;
    cursor.current_key_ptr = null;
    cursor.current_key_len = 0;
    cursor.current_value_ptr = null;
    cursor.current_value_len = 0;
    cursor.is_eof = true;
    cursor.is_point_lookup = false;

    cursor.lower_bound_ptr = null;
    cursor.lower_bound_len = 0;
    cursor.lower_bound_inclusive = false;
    cursor.upper_bound_ptr = null;
    cursor.upper_bound_len = 0;
    cursor.upper_bound_inclusive = false;

    cursor.scan_idx_id = 0;
    cursor.scan_idx_cols = 0;
    cursor.scan_idx_eq_mode = false;
    
    cursor.decoded_row_ptr = null;
    cursor.decoded_row_len = 0;
    
    cursor.arena = arena_ptr;

    ppCursor.* = &cursor.base;
    return c.SQLITE_OK;
}

pub fn xClose(cursor: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const self = @as(*types.AxionCursor, @ptrCast(cursor));
    const vtab = @as(*types.AxionVTab, @ptrCast(self.base.pVtab));

    if (self.val_ref_ptr) |ptr| {
        const v = @as(*SSTable.ValueRef, @ptrCast(@alignCast(ptr)));
        v.deinit();
    }
    if (self.iter) |iter| {
        iter.deinit();
        allocator.destroy(iter);
    }
    if (self.read_txn_id != 0) {
        vtab.db.tm.endReadOnly(.{ .id = self.read_txn_id, .read_version = self.read_txn_ver });
    }
    
    self.arena.deinit();
    allocator.destroy(self.arena);
    allocator.destroy(self);
    return c.SQLITE_OK;
}

pub fn xFilter(
    cursor: [*c]c.sqlite3_vtab_cursor, 
    idxNum: c_int, 
    idxStr: [*c]const u8, 
    argc: c_int, 
    argv: [*c]?*c.sqlite3_value
) callconv(.c) c_int {
    _ = idxStr;
    const self = @as(*types.AxionCursor, @ptrCast(cursor));
    const vtab = @as(*types.AxionVTab, @ptrCast(cursor.*.pVtab));
    
    // Cleanup previous state
    if (self.val_ref_ptr) |ptr| {
        const v = @as(*SSTable.ValueRef, @ptrCast(@alignCast(ptr)));
        v.deinit();
        self.val_ref_ptr = null;
    }
    if (self.iter) |iter| {
        iter.deinit();
        allocator.destroy(iter);
        self.iter = null;
    }
    if (self.read_txn_id != 0) {
        vtab.db.tm.endReadOnly(.{ .id = self.read_txn_id, .read_version = self.read_txn_ver });
        self.read_txn_id = 0;
    }

    // Reset Arena for new query
    _ = self.arena.reset(.retain_capacity);
    const arena_alloc = self.arena.allocator();

    self.current_key_ptr = null;
    self.current_value_ptr = null;
    self.lower_bound_ptr = null;
    self.upper_bound_ptr = null;

    self.decoded_row_ptr = null;
    self.decoded_row_len = 0;
    self.is_point_lookup = false;
    self.is_eof = true;

    const idx_id = @as(u32, @intCast((idxNum >> 16) & 0xFFFF));
    const num_cols = @as(u32, @intCast((idxNum >> 8) & 0xFF));
    const flags = @as(u8, @intCast(idxNum & 0xFF));

    // PK Type
    var pk_type: Schema.ColumnType = .Blob;
    for (vtab.schema.columns.items) |col| {
        if (col.is_primary_key) {
            pk_type = col.type;
            break;
        }
    }

    if (idx_id == 0) {
        self.scan_idx_id = 0;
        if (flags == 1) {
            // Point Lookup
            if (argc < 1) return c.SQLITE_INTERNAL;
            const val = argv[0];
            
            const key = encodePrimaryKey(arena_alloc, val, pk_type) catch return c.SQLITE_NOMEM;
            const result = vtab.db.get(key) catch |err| return types.mapZigError(err);
            if (result) |val_ref| {
                const v_ptr = arena_alloc.create(SSTable.ValueRef) catch return c.SQLITE_NOMEM;
                v_ptr.* = val_ref;
                self.val_ref_ptr = v_ptr;
                
                self.current_key_ptr = key.ptr;
                self.current_key_len = key.len;
                self.current_value_ptr = v_ptr.data.ptr;
                self.current_value_len = v_ptr.data.len;
                self.is_eof = false;
                self.is_point_lookup = true;
            }
        } else {
            // Range
            var arg_iter: usize = 0;
            if ((flags & (2 | 4)) != 0) {
                const val = argv[arg_iter]; arg_iter += 1;
                const k = encodePrimaryKey(arena_alloc, val, pk_type) catch return c.SQLITE_NOMEM;
                self.lower_bound_ptr = k.ptr;
                self.lower_bound_len = k.len;
                self.lower_bound_inclusive = (flags & 4) != 0;
            }
            if ((flags & (8 | 16)) != 0) {
                const val = argv[arg_iter]; arg_iter += 1;
                const k = encodePrimaryKey(arena_alloc, val, pk_type) catch return c.SQLITE_NOMEM;
                self.upper_bound_ptr = k.ptr;
                self.upper_bound_len = k.len;
                self.upper_bound_inclusive = (flags & 16) != 0;
            }
            const iter_ptr = createIterator(self, allocator) catch return c.SQLITE_ERROR;
            self.iter = iter_ptr;
            const prefix_byte = [_]u8{ @intFromEnum(CompositeKey.KeyType.Primary) };
            var seek_key: []const u8 = &prefix_byte;
            if (self.lower_bound_ptr) |ptr| seek_key = ptr[0..self.lower_bound_len];
            iter_ptr.seek(seek_key) catch return c.SQLITE_ERROR;
            advancePkIterator(self) catch return c.SQLITE_ERROR;
        }
    } else {
        // Index Scan
        self.scan_idx_id = idx_id;
        self.scan_idx_cols = num_cols;
        self.scan_idx_eq_mode = (flags == 1);

        var index_def: ?Schema.Index = null;
        for (vtab.schema.indexes.items) |idx| {
            if (idx.id == idx_id) {
                index_def = idx;
                break;
            }
        }
        if (index_def == null) return c.SQLITE_ERROR;

        var seek_values = std.ArrayListUnmanaged([]const u8){};
        defer seek_values.deinit(arena_alloc);

        var arg_iter: usize = 0;
        for (0..num_cols) |k| {
            if (arg_iter >= argc) break;
            const cid = index_def.?.column_ids.items[k];
            
            var col_type: Schema.ColumnType = .Blob;
            for (vtab.schema.columns.items) |c_def| {
                if (c_def.id == cid) {
                    col_type = c_def.type;
                    break;
                }
            }
            
            const val_bytes = encodeValue(arena_alloc, argv[arg_iter], col_type) catch return c.SQLITE_NOMEM;
            seek_values.append(arena_alloc, val_bytes) catch return c.SQLITE_NOMEM;
            arg_iter += 1;
        }

        const lb = CompositeKey.encodeIndexSeekKey(arena_alloc, idx_id, seek_values.items) catch return c.SQLITE_NOMEM;
        self.lower_bound_ptr = lb.ptr;
        self.lower_bound_len = lb.len;
        self.lower_bound_inclusive = true; 

        const iter_ptr = createIterator(self, allocator) catch return c.SQLITE_ERROR;
        self.iter = iter_ptr;
        iter_ptr.seek(lb) catch return c.SQLITE_ERROR;
        
        advanceIndexIterator(self, idx_id) catch return c.SQLITE_ERROR;
    }

    return c.SQLITE_OK;
}

pub fn xNext(cursor: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const self = @as(*types.AxionCursor, @ptrCast(cursor));

    _ = self.arena.reset(.retain_capacity);
    self.decoded_row_ptr = null;
    self.decoded_row_len = 0;
    
    if (self.val_ref_ptr) |ptr| {
        const v = @as(*SSTable.ValueRef, @ptrCast(@alignCast(ptr)));
        v.deinit();
        self.val_ref_ptr = null;
    }
    
    self.current_key_ptr = null;
    self.current_value_ptr = null;

    if (self.is_point_lookup) {
        self.is_eof = true;
        return c.SQLITE_OK;
    }

    if (self.iter) |iter| {
        _ = iter;
        if (self.scan_idx_id == 0) {
            advancePkIterator(self) catch |err| return types.mapZigError(err);
        } else {
            advanceIndexIterator(self, self.scan_idx_id) catch |err| return types.mapZigError(err);
        }
    } else {
        self.is_eof = true;
    }
    return c.SQLITE_OK;
}

pub fn xEof(cursor: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const self = @as(*types.AxionCursor, @ptrCast(cursor));
    return if (self.is_eof) 1 else 0;
}

pub fn xColumn(cursor: [*c]c.sqlite3_vtab_cursor, ctx: ?*c.sqlite3_context, n: c_int) callconv(.c) c_int {
    const self = @as(*types.AxionCursor, @ptrCast(cursor));
    if (self.is_eof) return c.SQLITE_OK;

    const col_idx = @as(usize, @intCast(n));
    const arena_alloc = self.arena.allocator();

    if (self.current_value_ptr) |ptr| {
        if (self.decoded_row_ptr == null) {
             const val_slice = ptr[0..self.current_value_len];
             const decoded = Row.Row.deserializeBorrowed(arena_alloc, val_slice) catch return c.SQLITE_NOMEM;
             self.decoded_row_ptr = decoded.ptr;
             self.decoded_row_len = decoded.len;
        }
        
        if (col_idx >= self.decoded_row_len) {
            c.sqlite3_result_null(ctx);
            return c.SQLITE_OK;
        }

        const val = self.decoded_row_ptr.?[col_idx];
        
        switch (val) {
            .Integer => |i| c.sqlite3_result_int64(ctx, i),
            .Float => |f| c.sqlite3_result_double(ctx, f),
            .Text => |s| c.sqlite3_result_text(ctx, s.ptr, @intCast(s.len), c.SQLITE_STATIC),
            .Blob => |b| c.sqlite3_result_blob(ctx, b.ptr, @intCast(b.len), c.SQLITE_STATIC),
            .Null => c.sqlite3_result_null(ctx),
        }
    }
    return c.SQLITE_OK;
}

pub fn xRowid(cursor: [*c]c.sqlite3_vtab_cursor, pRowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
    _ = cursor;
    pRowid.* = 0;
    return c.SQLITE_OK;
}

// --- Helpers ---

fn createIterator(self: *types.AxionCursor, alloc: std.mem.Allocator) !*Iterator {
    const vtab = @as(*types.AxionVTab, @ptrCast(self.base.pVtab));
    types.registry_init_once.call();
    
    const key = types.RegistryKey{ .conn = vtab.sqlite_conn, .db = vtab.db };
    const shard = types.registry.getShard(key);
    shard.mutex.lock();
    defer shard.mutex.unlock();
    
    if (shard.map.getPtr(key)) |entry| {
        if (entry.rolled_back) return error.TransactionRolledBack;
        
        const concrete = try alloc.create(MergedIterator);
        concrete.* = try entry.txn.scan("");
        
        const wrapper = try alloc.create(Iterator);
        wrapper.* = concrete.iterator();
        return wrapper;
    } else {
        const rot = vtab.db.tm.beginReadOnly();
        self.read_txn_id = rot.id;
        self.read_txn_ver = rot.read_version;
        
        const concrete = try alloc.create(SnapshotIterator);
        concrete.* = try vtab.db.createIterator(rot.read_version);
        
        const wrapper = try alloc.create(Iterator);
        wrapper.* = concrete.iterator();
        return wrapper;
    }
}

fn advancePkIterator(self: *types.AxionCursor) !void {
    var entry = try self.iter.?.next();

    while (entry) |e| {
        if (e.key.len == 0 or e.key[0] != @intFromEnum(CompositeKey.KeyType.Primary) or e.value.len == 0) {
             if (e.key.len > 0 and e.key[0] > @intFromEnum(CompositeKey.KeyType.Primary)) {
                 entry = null;
                 break;
             }
             entry = try self.iter.?.next();
        } else {
            break;
        }
    }

    if (entry) |e| {
        if (self.lower_bound_ptr) |ptr| {
            if (!self.lower_bound_inclusive) {
                 const lb = ptr[0..self.lower_bound_len];
                 if (Comparator.compare(e.key, lb) == .eq) {
                     return advancePkIterator(self);
                 }
            }
        }
        if (self.upper_bound_ptr) |ptr| {
            const ub = ptr[0..self.upper_bound_len];
            const cmp = Comparator.compare(e.key, ub);
            var over = false;
            if (self.upper_bound_inclusive) { 
                if (cmp == .gt) over = true;
            } else { 
                if (cmp != .lt) over = true;
            }
            if (over) {
                self.is_eof = true;
                return;
            }
        }
        self.current_key_ptr = e.key.ptr;
        self.current_key_len = e.key.len;
        self.current_value_ptr = e.value.ptr;
        self.current_value_len = e.value.len;
        self.is_eof = false;
    } else {
        self.is_eof = true;
    }
}

fn advanceIndexIterator(self: *types.AxionCursor, idx_id: u32) !void {
    const vtab = @as(*types.AxionVTab, @ptrCast(self.base.pVtab));
    const arena_alloc = self.arena.allocator();
    
    // We need index def to get total columns for extractPrimaryKey
    var total_cols: usize = 0;
    for (vtab.schema.indexes.items) |idx| {
        if (idx.id == idx_id) {
            total_cols = idx.column_ids.items.len;
            break;
        }
    }

    while (true) {
        const entry_opt = try self.iter.?.next();
        if (entry_opt == null) {
            self.is_eof = true;
            return;
        }
        const e = entry_opt.?;

        if (e.key.len < 5 or e.key[0] != @intFromEnum(CompositeKey.KeyType.Index)) {
             self.is_eof = true; 
             return;
        }
        
        const curr_id = std.mem.readInt(u32, e.key[1..5], .big);
        if (curr_id != idx_id) {
            self.is_eof = true; 
            return;
        }
        
        // Check Bounds (Prefix Match)
        if (self.lower_bound_ptr) |ptr| {
             const lb = ptr[0..self.lower_bound_len];
             if (!std.mem.startsWith(u8, e.key, lb)) {
                 // Moved past the prefix
                 self.is_eof = true;
                 return;
             }
        }
        
        // PK Extraction
        const pk = CompositeKey.extractPrimaryKey(arena_alloc, e.key, total_cols) catch continue;
        
        const row_ref = vtab.db.get(pk) catch return error.DBGetFailed;
        if (row_ref) |ref| {
            const v_ptr = arena_alloc.create(SSTable.ValueRef) catch return error.OutOfMemory;
            v_ptr.* = ref;
            
            if (self.val_ref_ptr) |p| {
                 const v = @as(*SSTable.ValueRef, @ptrCast(@alignCast(p)));
                 v.deinit();
            }
            self.val_ref_ptr = v_ptr;
            
            self.current_key_ptr = pk.ptr;
            self.current_key_len = pk.len;
            
            self.current_value_ptr = v_ptr.data.ptr;
            self.current_value_len = v_ptr.data.len;
            
            self.is_eof = false;
            return;
        } else {
            continue;
        }
    }
}

fn encodeValue(alloc: std.mem.Allocator, val: ?*c.sqlite3_value, col_type: Schema.ColumnType) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    try encodeValueAppend(alloc, &buf, val, col_type);
    return buf.toOwnedSlice(alloc);
}

fn encodePrimaryKey(alloc: std.mem.Allocator, val: ?*c.sqlite3_value, col_type: Schema.ColumnType) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    try buf.append(alloc, @intFromEnum(CompositeKey.KeyType.Primary));
    try encodeValueAppend(alloc, &buf, val, col_type);
    return buf.toOwnedSlice(alloc);
}

fn encodeValueAppend(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), val: ?*c.sqlite3_value, col_type: Schema.ColumnType) !void {
    switch (col_type) {
        .Integer => {
            const i = c.sqlite3_value_int64(val);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &buf, i, .big); 
            try list.appendSlice(alloc, &buf);
        },
        .Float => {
             const f = c.sqlite3_value_double(val);
             var buf: [8]u8 = undefined;
             std.mem.writeInt(u64, &buf, @as(u64, @bitCast(f)), .big);
             try list.appendSlice(alloc, &buf);
        },
        .Text => {
            const txt = c.sqlite3_value_text(val);
            const len = c.sqlite3_value_bytes(val);
            try list.appendSlice(alloc, txt[0..@intCast(len)]);
        },
        .Blob => {
            const blob = c.sqlite3_value_blob(val);
            const len = c.sqlite3_value_bytes(val);
            try list.appendSlice(alloc, @as([*]const u8, @ptrCast(blob))[0..@intCast(len)]);
        },
        else => {},
    }
}
