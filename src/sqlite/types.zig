const std = @import("std");
const c = @import("c.zig").c;
const DB = @import("../db.zig").DB;
const Transaction = @import("../mvcc/transaction.zig").Transaction;
const MergedIterator = @import("../lsm/merged_iterator.zig").MergedIterator;
const Iterator = @import("../lsm/iterator.zig").Iterator;
const Schema = @import("schema.zig");
const Row = @import("row.zig");

pub const allocator = std.heap.c_allocator;

// --- Registry ---
pub const RegistryKey = struct {
    conn: *c.sqlite3,
    db: *DB,
};

pub const TxnEntry = struct {
    txn: *Transaction,
    ref_count: usize,
    rolled_back: bool,
};

pub const REGISTRY_SHARDS = 64;
pub const RegistryShard = struct {
    mutex: std.Thread.Mutex,
    map: std.AutoHashMap(RegistryKey, TxnEntry),
};

pub const ShardedRegistry = struct {
    shards: []RegistryShard,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !ShardedRegistry {
        const s = try alloc.alloc(RegistryShard, REGISTRY_SHARDS);
        for (s) |*shard| {
            shard.mutex = .{};
            shard.map = std.AutoHashMap(RegistryKey, TxnEntry).init(alloc);
        }
        return .{ .shards = s, .allocator = alloc };
    }

    pub fn getShard(self: *ShardedRegistry, key: RegistryKey) *RegistryShard {
        const h = std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
        return &self.shards[h % REGISTRY_SHARDS];
    }
};

// Global Registry Instance
pub var registry: ShardedRegistry = undefined;
pub var registry_init_once = std.once(initRegistry);

fn initRegistry() void {
    registry = ShardedRegistry.init(allocator) catch @panic("OOM");
}

// --- Shared DB Registry ---
pub const SharedDB = struct {
    db: *DB,
    ref_count: usize,
};

pub var db_registry_mutex = std.Thread.Mutex{};
pub var db_registry: ?std.StringHashMap(*SharedDB) = null;

pub var vtab_registry_mutex = std.Thread.Mutex{};
pub var vtab_registry: ?std.StringHashMap(*AxionVTab) = null;

pub fn getVTabRegistryKey(alloc: std.mem.Allocator, conn: *c.sqlite3, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{*}:{s}", .{ conn, name });
}

// --- VTab & Cursor Structs ---
pub const AxionVTab = extern struct {
    base: c.sqlite3_vtab,
    db: *DB,
    sqlite_conn: *c.sqlite3,
    path_copy: [*c]const u8,
    schema: *Schema.TableSchema,
};

pub const AxionCursor = extern struct {
    base: c.sqlite3_vtab_cursor,
    iter: ?*Iterator,
    val_ref_ptr: ?*anyopaque, // *SSTable.ValueRef

    current_key_ptr: ?[*]const u8,
    current_key_len: usize,
    current_value_ptr: ?[*]const u8,
    current_value_len: usize,

    read_txn_id: u64,
    read_txn_ver: u64,

    is_eof: bool,
    is_point_lookup: bool,

    // Range Scan Support
    lower_bound_ptr: ?[*]const u8,
    lower_bound_len: usize,
    lower_bound_inclusive: bool,

    upper_bound_ptr: ?[*]const u8,
    upper_bound_len: usize,
    upper_bound_inclusive: bool,

    scan_idx_id: u32,
    scan_idx_cols: u32,
    scan_idx_eq_mode: bool,

    decoded_row_ptr: ?[*]Row.Row.Value,
    decoded_row_len: usize,

    arena: *std.heap.ArenaAllocator,
};

pub fn mapZigError(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => c.SQLITE_NOMEM,
        error.DiskQuota, error.InputOutput, error.SystemResources, error.AccessDenied, error.BrokenPipe, error.ConnectionResetByPeer => c.SQLITE_IOERR,
        error.DatabaseCompromised => c.SQLITE_CORRUPT,
        else => c.SQLITE_ERROR,
    };
}
