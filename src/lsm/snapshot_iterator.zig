const std = @import("std");
const Iterator = @import("iterator.zig").Iterator;
const Entry = @import("iterator.zig").Entry;
const MergedIterator = @import("merged_iterator.zig").MergedIterator;
const Version = @import("version_set.zig").Version;

pub const SnapshotIterator = struct {
    allocator: std.mem.Allocator,
    inner: MergedIterator,
    version: *Version,

    pub fn init(allocator: std.mem.Allocator, inner: MergedIterator, version: *Version) SnapshotIterator {
        // We assume version is already ref'd by the caller (DB.createIterator)
        // and we take ownership of that ref.
        return .{
            .allocator = allocator,
            .inner = inner,
            .version = version,
        };
    }

    pub fn deinit(self: *SnapshotIterator) void {
        self.inner.deinit();
        self.version.unref();
    }

    pub fn seek(self: *SnapshotIterator, key: []const u8) !void {
        try self.inner.seek(key);
    }

    pub fn next(self: *SnapshotIterator) !?Entry {
        return self.inner.next();
    }

    pub fn iterator(self: *SnapshotIterator) Iterator {
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

    fn wrapNext(ptr: *anyopaque) anyerror!?Entry {
        const self: *SnapshotIterator = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn wrapSeek(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *SnapshotIterator = @ptrCast(@alignCast(ptr));
        return self.seek(key);
    }

    fn wrapDeinit(ptr: *anyopaque) void {
        const self: *SnapshotIterator = @ptrCast(@alignCast(ptr));
        self.deinit();
        self.allocator.destroy(self);
    }
};
