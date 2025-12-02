//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const DB = @import("db.zig").DB;
pub const MemTable = @import("lsm/memtable.zig").MemTable;
pub const SSTable = @import("lsm/sstable.zig").SSTable;
pub const WAL = @import("lsm/wal.zig").WAL;
pub const Manifest = @import("lsm/manifest.zig").Manifest;
pub const TransactionManager = @import("mvcc/transaction.zig").TransactionManager;
pub const metrics = @import("metrics.zig");

pub const sqlite = struct {
    pub const c = @import("sqlite/c.zig").c;
    pub const vtab = @import("sqlite/vtab.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("db.zig");
    _ = @import("lsm/memtable.zig");
    _ = @import("lsm/sstable.zig");
    _ = @import("lsm/wal.zig");
    _ = @import("lsm/manifest.zig");
    _ = @import("mvcc/transaction.zig");
    _ = @import("lsm/block_cache.zig");
    _ = @import("lsm/table_info.zig");
    _ = @import("lsm/compaction.zig");
}

pub fn bufferedPrint() !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}
