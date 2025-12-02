const std = @import("std");

pub const BLOCK_SIZE = 64 * 1024;
pub const RESTART_INTERVAL = 16;
pub const MAGIC = 0xA710557; // AXION_SST
pub const VERSION = 5; // Version 5: Prefix Compression
pub const FOOTER_SIZE = 28;

pub const IndexEntry = struct {
    key: []const u8,
    offset: u64,
    length: u32,
};
