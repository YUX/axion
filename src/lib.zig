pub const c_api = @import("c_api.zig");
pub const sqlite_init = @import("sqlite/vtab.zig");

// Force exports
comptime {
    _ = c_api;
    _ = sqlite_init;
}
