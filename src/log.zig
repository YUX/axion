const std = @import("std");

pub const Level = std.log.Level;

pub const Scope = enum {
    default,
    db,
    lsm,
    wal,
    compaction,
    memtable,
    mvcc,
    sqlite,
};

pub fn info(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
    switch (scope) {
        .db => std.log.scoped(.db).info(format, args),
        .lsm => std.log.scoped(.lsm).info(format, args),
        .wal => std.log.scoped(.wal).info(format, args),
        .compaction => std.log.scoped(.compaction).info(format, args),
        .memtable => std.log.scoped(.memtable).info(format, args),
        .mvcc => std.log.scoped(.mvcc).info(format, args),
        .sqlite => std.log.scoped(.sqlite).info(format, args),
        else => std.log.info(format, args),
    }
}

pub fn err(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
    switch (scope) {
        .db => std.log.scoped(.db).err(format, args),
        .lsm => std.log.scoped(.lsm).err(format, args),
        .wal => std.log.scoped(.wal).err(format, args),
        .compaction => std.log.scoped(.compaction).err(format, args),
        .memtable => std.log.scoped(.memtable).err(format, args),
        .mvcc => std.log.scoped(.mvcc).err(format, args),
        .sqlite => std.log.scoped(.sqlite).err(format, args),
        else => std.log.err(format, args),
    }
}

pub fn warn(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
    switch (scope) {
        .db => std.log.scoped(.db).warn(format, args),
        .lsm => std.log.scoped(.lsm).warn(format, args),
        .wal => std.log.scoped(.wal).warn(format, args),
        .compaction => std.log.scoped(.compaction).warn(format, args),
        .memtable => std.log.scoped(.memtable).warn(format, args),
        .mvcc => std.log.scoped(.mvcc).warn(format, args),
        .sqlite => std.log.scoped(.sqlite).warn(format, args),
        else => std.log.warn(format, args),
    }
}

pub fn debug(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
    switch (scope) {
        .db => std.log.scoped(.db).debug(format, args),
        .lsm => std.log.scoped(.lsm).debug(format, args),
        .wal => std.log.scoped(.wal).debug(format, args),
        .compaction => std.log.scoped(.compaction).debug(format, args),
        .memtable => std.log.scoped(.memtable).debug(format, args),
        .mvcc => std.log.scoped(.mvcc).debug(format, args),
        .sqlite => std.log.scoped(.sqlite).debug(format, args),
        else => std.log.debug(format, args),
    }
}
