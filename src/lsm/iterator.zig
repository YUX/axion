const std = @import("std");

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    version: u64,
};

pub const Iterator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque) anyerror!?Entry,
        seek: *const fn (ptr: *anyopaque, key: []const u8) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn next(self: Iterator) !?Entry {
        return self.vtable.next(self.ptr);
    }

    pub fn seek(self: Iterator, key: []const u8) !void {
        return self.vtable.seek(self.ptr, key);
    }

    pub fn deinit(self: Iterator) void {
        self.vtable.deinit(self.ptr);
    }
};
