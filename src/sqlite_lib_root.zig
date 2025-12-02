pub const axion = @import("root.zig");
pub const vtab = @import("sqlite/vtab.zig");

comptime {
    _ = vtab;
    // Force export?
    // The export keyword in vtab.zig should be enough if the file is analyzed.
}
