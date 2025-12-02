const std = @import("std");
const Iterator = @import("iterator.zig").Iterator;
const Entry = @import("iterator.zig").Entry;
const MemTable = @import("memtable.zig").MemTable;
const SSTable = @import("sstable.zig").SSTable;
const Comparator = @import("comparator.zig");

pub const MemTableIteratorWrapper = struct {
    allocator: std.mem.Allocator,
    inner: MemTable.Iterator,

    pub fn create(allocator: std.mem.Allocator, inner: MemTable.Iterator) !Iterator {
        const self = try allocator.create(MemTableIteratorWrapper);
        self.* = .{ .allocator = allocator, .inner = inner };
        return Iterator{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = Iterator.VTable{
        .next = next,
        .seek = seek,
        .deinit = deinit,
    };

    fn next(ptr: *anyopaque) anyerror!?Entry {
        const self: *MemTableIteratorWrapper = @ptrCast(@alignCast(ptr));
        if (try self.inner.next()) |entry| {
            return Entry{
                .key = entry.key,
                .value = entry.value,
                .version = entry.version,
            };
        }
        return null;
    }

    fn seek(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *MemTableIteratorWrapper = @ptrCast(@alignCast(ptr));
        try self.inner.seek(key);
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *MemTableIteratorWrapper = @ptrCast(@alignCast(ptr));
        // inner.deinit() is no-op for MemTable currently, but good practice if it changes
        self.inner.deinit();
        self.allocator.destroy(self);
    }
};

pub const SSTableIteratorWrapper = struct {
    allocator: std.mem.Allocator,
    inner: SSTable.Reader.Iterator,

    pub fn create(allocator: std.mem.Allocator, inner: SSTable.Reader.Iterator) !Iterator {
        const self = try allocator.create(SSTableIteratorWrapper);
        self.* = .{ .allocator = allocator, .inner = inner };
        return Iterator{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = Iterator.VTable{
        .next = next,
        .seek = seek,
        .deinit = deinit,
    };

    fn next(ptr: *anyopaque) anyerror!?Entry {
        const self: *SSTableIteratorWrapper = @ptrCast(@alignCast(ptr));
        if (try self.inner.next()) |entry| {
            return Entry{
                .key = entry.key,
                .value = entry.value,
                .version = entry.version,
            };
        }
        return null;
    }

    fn seek(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *SSTableIteratorWrapper = @ptrCast(@alignCast(ptr));
        try self.inner.seek(key);
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *SSTableIteratorWrapper = @ptrCast(@alignCast(ptr));
        self.inner.deinit();
        self.allocator.destroy(self);
    }
};

pub const HashMapIteratorWrapper = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry),
    idx: usize,

    pub fn create(allocator: std.mem.Allocator, map: std.StringHashMap([]const u8), version: u64) !Iterator {
        const self = try allocator.create(HashMapIteratorWrapper);
        self.* = .{
            .allocator = allocator,
            .entries = .{},
            .idx = 0,
        };

        var it = map.iterator();
        while (it.next()) |entry| {
            try self.entries.append(allocator, .{
                .key = entry.key_ptr.*,
                .value = entry.value_ptr.*,
                .version = version,
            });
        }

        // Sort
        std.mem.sort(Entry, self.entries.items, {}, cmpEntry);

        return Iterator{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn cmpEntry(context: void, a: Entry, b: Entry) bool {
        _ = context;
        return Comparator.compare(a.key, b.key) == .lt;
    }

    const vtable = Iterator.VTable{
        .next = next,
        .seek = seek,
        .deinit = deinit,
    };

    fn next(ptr: *anyopaque) anyerror!?Entry {
        const self: *HashMapIteratorWrapper = @ptrCast(@alignCast(ptr));
        if (self.idx < self.entries.items.len) {
            const e = self.entries.items[self.idx];
            self.idx += 1;
            return e;
        }
        return null;
    }

    fn seek(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *HashMapIteratorWrapper = @ptrCast(@alignCast(ptr));
        // Binary search
        var left: usize = 0;
        var right: usize = self.entries.items.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (Comparator.compare(self.entries.items[mid].key, key) == .lt) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        self.idx = left;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *HashMapIteratorWrapper = @ptrCast(@alignCast(ptr));
        self.entries.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
