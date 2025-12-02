const std = @import("std");
const Allocator = std.mem.Allocator;
const SSTable = @import("sstable.zig").SSTable;

/// TableInfo represents the in-memory metadata and handle for an SSTable.
/// It is reference-counted to allow sharing between multiple Versions (Snapshot Isolation).
/// It owns its key strings and holds a reference to the underlying SSTable.Reader.
pub const TableInfo = struct {
    ref_count: std.atomic.Value(usize),
    allocator: Allocator,

    id: u64,
    level: usize,
    file_size: u64,
    min_key: []const u8, // Owned
    max_key: []const u8, // Owned
    reader: ?*SSTable.Reader,
    is_compacting: std.atomic.Value(bool),

    pub fn init(allocator: Allocator, id: u64, level: usize, min_key: []const u8, max_key: []const u8, file_size: u64, reader: ?*SSTable.Reader) !*TableInfo {
        const self = try allocator.create(TableInfo);
        self.ref_count = std.atomic.Value(usize).init(1);
        self.allocator = allocator;
        self.id = id;
        self.level = level;
        self.file_size = file_size;
        self.is_compacting = std.atomic.Value(bool).init(false);

        self.min_key = try allocator.dupe(u8, min_key);
        errdefer allocator.free(self.min_key);

        self.max_key = try allocator.dupe(u8, max_key);
        errdefer allocator.free(self.max_key);

        self.reader = reader;
        if (self.reader) |r| r.ref();

        return self;
    }

    pub fn initStealing(allocator: Allocator, id: u64, level: usize, min_key: []const u8, max_key: []const u8, file_size: u64, reader: ?*SSTable.Reader) !*TableInfo {
        const self = try allocator.create(TableInfo);
        self.ref_count = std.atomic.Value(usize).init(1);
        self.allocator = allocator;
        self.id = id;
        self.level = level;
        self.file_size = file_size;
        self.is_compacting = std.atomic.Value(bool).init(false);

        self.min_key = min_key;
        self.max_key = max_key;
        self.reader = reader;
        // Stolen ref, so no ref() call

        return self;
    }

    pub fn ref(self: *TableInfo) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn unref(self: *TableInfo) void {
        const prev = self.ref_count.fetchSub(1, .release);
        if (prev == 1) {
            _ = self.ref_count.load(.acquire);
            self.deinit();
        }
    }

    fn deinit(self: *TableInfo) void {
        self.allocator.free(self.min_key);
        self.allocator.free(self.max_key);
        if (self.reader) |r| r.unref();
        self.allocator.destroy(self);
    }
};
