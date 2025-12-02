const std = @import("std");
const Allocator = std.mem.Allocator;
const Manifest = @import("manifest.zig").Manifest;
const SSTable = @import("sstable.zig").SSTable;
const Iterator = @import("iterator.zig").Iterator;
const Entry = @import("iterator.zig").Entry;
const Comparator = @import("comparator.zig");
const TableInfo = @import("table_info.zig").TableInfo;

pub const LevelIterator = struct {
    allocator: Allocator,
    tables: []const *TableInfo,
    current_table_idx: usize,
    current_iter: ?SSTable.Reader.Iterator,
    
    pub fn init(allocator: Allocator, tables: []const *TableInfo) LevelIterator {
        return .{
            .allocator = allocator,
            .tables = tables,
            .current_table_idx = 0,
            .current_iter = null,
        };
    }

    pub fn deinit(self: *LevelIterator) void {
        if (self.current_iter) |*iter| {
            iter.deinit();
        }
    }

    pub fn seek(self: *LevelIterator, key: []const u8) !void {
        // 1. Binary Search to find the first table where max_key >= key
        var left: usize = 0;
        var right: usize = self.tables.len;
        
        while (left < right) {
            const mid = left + (right - left) / 2;
            const cmp = Comparator.compare(self.tables[mid].max_key, key);
            if (cmp == .lt) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        
        self.current_table_idx = left;
        
        if (self.current_iter) |*iter| {
            iter.deinit();
            self.current_iter = null;
        }

        if (self.current_table_idx < self.tables.len) {
             try self.openCurrentIter();
             if (self.current_iter) |*iter| {
                 try iter.seek(key);
             }
        }
    }

    pub fn next(self: *LevelIterator) !?Entry {
        while (self.current_table_idx < self.tables.len) {
            if (self.current_iter == null) {
                try self.openCurrentIter();
            }

            if (self.current_iter) |*iter| {
                if (try iter.next()) |entry| {
                    return Entry{
                        .key = entry.key,
                        .value = entry.value,
                        .version = entry.version,
                    };
                } else {
                    iter.deinit();
                    self.current_iter = null;
                    self.current_table_idx += 1;
                    continue; 
                }
            } else {
                self.current_table_idx += 1;
            }
        }
        return null;
    }

    fn openCurrentIter(self: *LevelIterator) !void {
        if (self.current_table_idx >= self.tables.len) return;
        
        const table = self.tables[self.current_table_idx];
        if (table.reader) |reader| {
            self.current_iter = reader.iterator();
        } else {
            return error.TableReaderNotOpen;
        }
    }
    
    pub fn iterator(self: *LevelIterator) Iterator {
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
        const self: *LevelIterator = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn wrapSeek(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *LevelIterator = @ptrCast(@alignCast(ptr));
        return self.seek(key);
    }

    fn wrapDeinit(ptr: *anyopaque) void {
        const self: *LevelIterator = @ptrCast(@alignCast(ptr));
        self.deinit();
        self.allocator.destroy(self);
    }
};