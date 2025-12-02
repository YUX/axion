const std = @import("std");
const Iterator = @import("iterator.zig").Iterator;
const Comparator = @import("comparator.zig");

pub const MergedIterator = struct {
    pub const Entry = @import("iterator.zig").Entry;

    allocator: std.mem.Allocator,
    children: std.ArrayListUnmanaged(Iterator),
    child_entries: std.ArrayListUnmanaged(?Entry),
    heap: std.ArrayListUnmanaged(usize),
    
    read_version: u64,
    last_key: ?[]u8,
    next_child_to_advance: ?usize,

    pub fn init(allocator: std.mem.Allocator, read_version: u64) MergedIterator {
        return .{
            .allocator = allocator,
            .children = .{},
            .child_entries = .{},
            .heap = .{},
            .read_version = read_version,
            .last_key = null,
            .next_child_to_advance = null,
        };
    }

    pub fn deinit(self: *MergedIterator) void {
        if (self.last_key) |k| self.allocator.free(k);
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit(self.allocator);
        self.child_entries.deinit(self.allocator);
        self.heap.deinit(self.allocator);
    }

    pub fn add(self: *MergedIterator, iter: Iterator) !void {
        try self.children.append(self.allocator, iter);
        try self.child_entries.append(self.allocator, null);
    }

    pub fn seek(self: *MergedIterator, key: []const u8) !void {
        self.heap.clearRetainingCapacity();
        if (self.last_key) |k| self.allocator.free(k);
        self.last_key = null;
        self.next_child_to_advance = null;

        for (self.children.items, 0..) |child, i| {
            try child.seek(key);
            const entry = try child.next();
            self.child_entries.items[i] = entry;
            if (entry != null) {
                try self.heapPush(i);
            }
        }
    }

    pub fn next(self: *MergedIterator) !?Entry {
        // Lazy advance: Advance the child that provided the PREVIOUS result
        if (self.next_child_to_advance) |idx| {
            try self.advanceChild(idx);
            self.next_child_to_advance = null;
        }

        while (self.heap.items.len > 0) {
            const idx = self.heap.items[0];
            const entry = self.child_entries.items[idx].?;

            // Check if this key is same as last emitted key (Deduplication / Shadowing)
            var is_shadowed = false;
            if (self.last_key) |last| {
                if (std.mem.eql(u8, last, entry.key)) {
                    is_shadowed = true;
                }
            }

            // Check visibility
            const is_visible = entry.version <= self.read_version;

            if (is_shadowed) {
                try self.advanceChild(idx);
                continue;
            }
            
            if (!is_visible) {
                try self.advanceChild(idx);
                continue;
            }

            // Now we have a visible, non-shadowed key.
            // Update last_key.
            if (self.last_key) |k| self.allocator.free(k);
            self.last_key = try self.allocator.dupe(u8, entry.key);

            // Prepare to advance this child NEXT time
            self.next_child_to_advance = idx;
            
            // Return entry pointing DIRECTLY to child's memory (Zero-Copy Value)
            return Entry{ .key = self.last_key.?, .value = entry.value, .version = entry.version };
        }
        return null;
    }

    fn advanceChild(self: *MergedIterator, idx: usize) !void {
        const entry = try self.children.items[idx].next();
        self.child_entries.items[idx] = entry;
        
        if (entry == null) {
            // Remove root (swap with last, pop, sift down)
            const last_idx = self.heap.items.len - 1;
            std.mem.swap(usize, &self.heap.items[0], &self.heap.items[last_idx]);
            _ = self.heap.pop();
            
            if (self.heap.items.len > 0) {
                 self.siftDown(0);
            }
        } else {
            // Value changed. Sift down.
            self.siftDown(0);
        }
    }
    
    fn heapPush(self: *MergedIterator, idx: usize) !void {
        try self.heap.append(self.allocator, idx);
        self.siftUp(self.heap.items.len - 1);
    }

    fn siftUp(self: *MergedIterator, start_idx: usize) void {
        var idx = start_idx;
        while (idx > 0) {
            const parent = (idx - 1) / 2;
            if (self.compare(idx, parent)) { // idx < parent
                std.mem.swap(usize, &self.heap.items[idx], &self.heap.items[parent]);
                idx = parent;
            } else {
                break;
            }
        }
    }

    fn siftDown(self: *MergedIterator, start_idx: usize) void {
        var idx = start_idx;
        const half = self.heap.items.len / 2;
        while (idx < half) {
            var left = 2 * idx + 1;
            const right = left + 1;
            
            if (right < self.heap.items.len and self.compare(right, left)) {
                left = right;
            }
            
            if (self.compare(left, idx)) {
                std.mem.swap(usize, &self.heap.items[idx], &self.heap.items[left]);
                idx = left;
            } else {
                break;
            }
        }
    }

    // Returns true if heap[a] < heap[b] (Higher priority)
    // Priority: Key ASC, Version DESC
    fn compare(self: *MergedIterator, a_idx: usize, b_idx: usize) bool {
        const a = self.heap.items[a_idx];
        const b = self.heap.items[b_idx];
        const entry_a = self.child_entries.items[a].?;
        const entry_b = self.child_entries.items[b].?;

        const cmp = Comparator.compare(entry_a.key, entry_b.key);
        if (cmp == .lt) return true;
        if (cmp == .gt) return false;
        
        // Key equal, compare version DESC
        return entry_a.version > entry_b.version;
    }

    pub fn iterator(self: *MergedIterator) @import("iterator.zig").Iterator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = @import("iterator.zig").Iterator.VTable{
        .next = wrapNext,
        .seek = wrapSeek,
        .deinit = wrapDeinit,
    };

    fn wrapNext(ptr: *anyopaque) anyerror!?Entry {
        const self: *MergedIterator = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn wrapSeek(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *MergedIterator = @ptrCast(@alignCast(ptr));
        return self.seek(key);
    }

    fn wrapDeinit(ptr: *anyopaque) void {
        const self: *MergedIterator = @ptrCast(@alignCast(ptr));
        self.deinit();
        self.allocator.destroy(self);
    }
};
