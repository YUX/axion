const std = @import("std");
const DB = @import("axion").DB;
const CompositeKey = @import("lsm/composite_key.zig");
const IndexUpdate = @import("../db.zig").IndexUpdate;

test "Secondary Index Integration" {
    const allocator = std.testing.allocator;
    const test_path = "test_db_idx";
    std.fs.cwd().deleteTree(test_path) catch {};
    defer std.fs.cwd().deleteTree(test_path) catch {};

    var db = try DB.open(allocator, test_path, .Full);
    defer db.close();

    const idx_id_name: u32 = 1;

    // Insert Users with Index on Name
    // User 1: Alice
    {
        const updates = [_]IndexUpdate{
            .{ .id = idx_id_name, .old_value = null, .new_value = "Alice" },
        };
        try db.putIndexed("user:1", "User Data Alice", &updates);
    }
    
    // User 2: Bob
    {
        const updates = [_]IndexUpdate{
            .{ .id = idx_id_name, .old_value = null, .new_value = "Bob" },
        };
        try db.putIndexed("user:2", "User Data Bob", &updates);
    }

    // User 3: Alice (Another Alice)
    {
        const updates = [_]IndexUpdate{
            .{ .id = idx_id_name, .old_value = null, .new_value = "Alice" },
        };
        try db.putIndexed("user:3", "User Data Alice 2", &updates);
    }

    // Verify Index Scan: "Alice"
    {
        var iter = try db.getIndexIterator(idx_id_name, "Alice");
        defer iter.deinit();

        // Expect user:1
        while (try iter.next()) |entry| {
            // Skip tombstones (empty values)
            if (entry.value.len == 0) continue;

            const pk = try CompositeKey.extractPrimaryKey(allocator, entry.key);
            defer allocator.free(pk);
            
            // We expect user:1 first (Alice)
            // But wait, we are in a loop now.
            // Let's collect results or check sequentially.
            // Since the logic is sequential:
            
            if (std.mem.eql(u8, pk, "user:1")) {
                // Found user:1.
                // Check next.
                break;
            } else {
                // If we found something else first, fail.
                // Unless we found user:3? No, user:1 < user:3.
                std.debug.print("Found unexpected PK: {s}\n", .{pk});
                try std.testing.expect(false);
            }
        }

        // Expect user:3
        while (try iter.next()) |entry| {
            if (entry.value.len == 0) continue;
            const pk = try CompositeKey.extractPrimaryKey(allocator, entry.key);
            defer allocator.free(pk);
            try std.testing.expectEqualStrings("user:3", pk);
            break;
        }

        // Expect user:2 (Bob)
        while (try iter.next()) |entry| {
            if (entry.value.len == 0) continue;
            const pk = try CompositeKey.extractPrimaryKey(allocator, entry.key);
            defer allocator.free(pk);
            try std.testing.expectEqualStrings("user:2", pk);
            break;
        }
    }

    // Update User 1: Alice -> Charlie
    {
        const updates = [_]IndexUpdate{
            .{ .id = idx_id_name, .old_value = "Alice", .new_value = "Charlie" },
        };
        try db.putIndexed("user:1", "User Data Charlie", &updates);
    }

    // Verify Index Scan: "Alice" (Should only have user:3)
    {
        var iter = try db.getIndexIterator(idx_id_name, "Alice");
        defer iter.deinit();

        // Should find user:3. user:1 should be skipped (tombstone).
        while (try iter.next()) |entry| {
            if (entry.value.len == 0) continue;
            
            const pk = try CompositeKey.extractPrimaryKey(allocator, entry.key);
            defer allocator.free(pk);
            try std.testing.expectEqualStrings("user:3", pk);
            break;
        }
        
        // Next should be Bob (user:2)
        while (try iter.next()) |entry| {
             if (entry.value.len == 0) continue;
             
             const pk = try CompositeKey.extractPrimaryKey(allocator, entry.key);
             defer allocator.free(pk);
             try std.testing.expectEqualStrings("user:2", pk);
             break;
        }
    }
}
