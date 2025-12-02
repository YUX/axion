const std = @import("std");
const DB = @import("db.zig").DB;
const MergedIterator = @import("lsm/merged_iterator.zig").MergedIterator;
const SnapshotIterator = @import("lsm/snapshot_iterator.zig").SnapshotIterator;
const SSTable = @import("lsm/sstable.zig").SSTable;
const Iterator = @import("lsm/iterator.zig");

const allocator = std.heap.c_allocator;

// Opaque types for C
pub const axion_db_t = opaque {};
pub const axion_iter_t = opaque {};
pub const axion_options_t = opaque {};

export fn axion_options_create(out_opts: *?*axion_options_t) c_int {
    const opts_ptr = allocator.create(DB.DBOptions) catch return -1;
    opts_ptr.* = .{}; // Defaults
    out_opts.* = @ptrCast(opts_ptr);
    return 0;
}

export fn axion_options_destroy(opts: *axion_options_t) void {
    const self: *DB.DBOptions = @ptrCast(@alignCast(opts));
    allocator.destroy(self);
}

export fn axion_options_set_memtable_size(opts: *axion_options_t, size: usize) void {
    const self: *DB.DBOptions = @ptrCast(@alignCast(opts));
    self.memtable_size_bytes = size;
}

export fn axion_options_set_l0_limit(opts: *axion_options_t, limit: usize) void {
    const self: *DB.DBOptions = @ptrCast(@alignCast(opts));
    self.l0_file_limit = limit;
}

export fn axion_db_open(path: [*c]const u8, out_db: *?*axion_db_t) c_int {
    // Default options
    const options = DB.DBOptions{
        .memtable_size_bytes = 64 * 1024 * 1024,
        .l0_file_limit = 4,
        .l1_size_bytes = 256 * 1024 * 1024,
        .wal_sync_mode = .Full,
        .block_cache_size_bytes = 16 * 1024 * 1024,
        .compaction_threads = 1,
    };
    return axion_db_open_internal(path, options, out_db);
}

export fn axion_db_open_with_options(path: [*c]const u8, opts: *axion_options_t, out_db: *?*axion_db_t) c_int {
    const options: *DB.DBOptions = @ptrCast(@alignCast(opts));
    return axion_db_open_internal(path, options.*, out_db);
}

fn axion_db_open_internal(path: [*c]const u8, options: DB.DBOptions, out_db: *?*axion_db_t) c_int {
    const path_slice = std.mem.span(path);
    const db = DB.open(allocator, path_slice, options) catch return -1;
    out_db.* = @ptrCast(db);
    return 0;
}

export fn axion_db_close(db: *axion_db_t) void {
    const self: *DB = @ptrCast(@alignCast(db));
    self.close();
}

export fn axion_db_put(db: *axion_db_t, key: [*c]const u8, key_len: usize, val: [*c]const u8, val_len: usize) c_int {
    const self: *DB = @ptrCast(@alignCast(db));
    const k = key[0..key_len];
    const v = val[0..val_len];

    self.put(k, v) catch return -1;
    return 0;
}

export fn axion_db_get(db: *axion_db_t, key: [*c]const u8, key_len: usize, out_val: *[*c]u8, out_val_len: *usize) c_int {
    const self: *DB = @ptrCast(@alignCast(db));
    const k = key[0..key_len];

    const result = self.get(k) catch return -1;
    if (result) |val_ref| {
        // We must copy data to C-owned memory because val_ref owns its memory via internal allocators/cache handles
        // and we need a simple free mechanism for C.
        const buf = allocator.alloc(u8, val_ref.data.len) catch return -1;
        @memcpy(buf, val_ref.data);

        out_val.* = buf.ptr;
        out_val_len.* = buf.len;

        val_ref.deinit();
        return 0;
    } else {
        out_val.* = null;
        out_val_len.* = 0;
        return 0; // Not found is not an error, just empty result
    }
}

export fn axion_db_free_val(val: [*c]u8, len: usize) void {
    if (val != null and len > 0) {
        allocator.free(val[0..len]);
    }
}

export fn axion_db_delete(db: *axion_db_t, key: [*c]const u8, key_len: usize) c_int {
    const self: *DB = @ptrCast(@alignCast(db));
    const k = key[0..key_len];
    self.delete(k) catch return -1;
    return 0;
}

// Iterator API
// Wrapper for C-style Iterator (Seek, Valid, Key, Value, Next)
const CIterator = struct {
    inner: SnapshotIterator,
    current_entry: ?Iterator.Entry,

    pub fn init(inner: SnapshotIterator) CIterator {
        return .{
            .inner = inner,
            .current_entry = null,
        };
    }

    pub fn seek(self: *CIterator, key: []const u8) !void {
        try self.inner.seek(key);
        self.current_entry = try self.inner.next();
    }

    pub fn next(self: *CIterator) !void {
        self.current_entry = try self.inner.next();
    }
};

export fn axion_c_iter_create(db: *axion_db_t, out_iter: *?*axion_iter_t) c_int {
    const self: *DB = @ptrCast(@alignCast(db));
    const current_ver = self.tm.global_version.load(.acquire);

    const inner = self.createIterator(current_ver) catch return -1;
    const wrapper = allocator.create(CIterator) catch return -1;
    wrapper.* = CIterator.init(inner);

    out_iter.* = @ptrCast(wrapper);
    return 0;
}

export fn axion_c_iter_destroy(iter: *axion_iter_t) void {
    const self: *CIterator = @ptrCast(@alignCast(iter));
    self.inner.deinit();
    allocator.destroy(self);
}

export fn axion_c_iter_seek(iter: *axion_iter_t, key: [*c]const u8, key_len: usize) c_int {
    const self: *CIterator = @ptrCast(@alignCast(iter));
    const k = key[0..key_len];
    self.seek(k) catch return -1;
    return 0;
}

export fn axion_c_iter_valid(iter: *axion_iter_t) bool {
    const self: *CIterator = @ptrCast(@alignCast(iter));
    return self.current_entry != null;
}

export fn axion_c_iter_next(iter: *axion_iter_t) c_int {
    const self: *CIterator = @ptrCast(@alignCast(iter));
    self.next() catch return -1;
    return 0;
}

export fn axion_c_iter_key(iter: *axion_iter_t, out_len: *usize) [*c]const u8 {
    const self: *CIterator = @ptrCast(@alignCast(iter));
    if (self.current_entry) |e| {
        out_len.* = e.key.len;
        return e.key.ptr;
    }
    out_len.* = 0;
    return null;
}

export fn axion_c_iter_value(iter: *axion_iter_t, out_len: *usize) [*c]const u8 {
    const self: *CIterator = @ptrCast(@alignCast(iter));
    if (self.current_entry) |e| {
        out_len.* = e.value.len;
        return e.value.ptr;
    }
    out_len.* = 0;
    return null;
}
