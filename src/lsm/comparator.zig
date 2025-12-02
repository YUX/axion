const std = @import("std");
const Order = std.math.Order;

/// Compare two keys lexicographically.
/// This is the central point for key comparison optimization and future Collation support.
pub inline fn compare(a: []const u8, b: []const u8) Order {
    const min_len = @min(a.len, b.len);

    // Optimization: Fast path for keys >= 8 bytes (common for IDs, timestamps)
    // Comparing 8 bytes as a single integer instruction is much faster than byte-loop
    // or function call to memcmp for short prefixes.
    if (min_len >= 8) {
        const a_head = std.mem.readInt(u64, a[0..8], .big);
        const b_head = std.mem.readInt(u64, b[0..8], .big);

        if (a_head < b_head) return .lt;
        if (a_head > b_head) return .gt;

        // If heads are equal, compare the rest
        return std.mem.order(u8, a[8..], b[8..]);
    }

    return std.mem.order(u8, a, b);
}

/// Compare keys, returning true if a < b
pub inline fn less(a: []const u8, b: []const u8) bool {
    return compare(a, b) == .lt;
}

/// Compare keys, returning true if a <= b
pub inline fn lessOrEqual(a: []const u8, b: []const u8) bool {
    return compare(a, b) != .gt;
}

/// Compare keys, returning true if a == b
pub inline fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}