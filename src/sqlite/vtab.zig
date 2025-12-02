const std = @import("std");
const c = @import("c.zig").c;
const types = @import("types.zig");
const cursor = @import("cursor.zig");
const DB = @import("../db.zig").DB;
const Transaction = @import("../mvcc/transaction.zig").Transaction;
const WAL = @import("../lsm/wal.zig").WAL;
const Schema = @import("schema.zig");
const Row = @import("row.zig");
const SqlParser = @import("sql_parser.zig");
const MemTable = @import("../lsm/memtable.zig").MemTable;
const SSTable = @import("../lsm/sstable.zig").SSTable;
const CompositeKey = @import("../lsm/composite_key.zig");

const allocator = types.allocator;
const SCHEMA_KEY = "_meta_schema";

fn xConnect(
    db: ?*c.sqlite3,
    aux: ?*anyopaque,
    argc: c_int,
    argv: [*c]const [*c]const u8,
    ppVtab: [*c][*c]c.sqlite3_vtab,
    pzErr: [*c][*c]u8,
) callconv(.c) c_int {
    _ = aux;

    if (argc < 4) {
        pzErr.* = c.sqlite3_mprintf("Argument missing: path to Axion DB");
        return c.SQLITE_ERROR;
    }

    const path_c = argv[3];
    const path_len = std.mem.len(path_c);
    var path = path_c[0..path_len];
    path = std.mem.trim(u8, path, "'\"");

    var sync_mode: WAL.SyncMode = .Full;
    if (argc >= 5) {
        const mode_c = argv[4];
        const mode_len = std.mem.len(mode_c);
        var mode_str = mode_c[0..mode_len];
        mode_str = std.mem.trim(u8, mode_str, "'\"");

        if (std.ascii.eqlIgnoreCase(mode_str, "OFF")) {
            sync_mode = .Off;
        } else if (std.ascii.eqlIgnoreCase(mode_str, "NORMAL")) {
            sync_mode = .Normal;
        }
    }

    var schema_sql_in: ?[]const u8 = null;
    if (argc >= 6) {
        const s_c = argv[5];
        const s_len = std.mem.len(s_c);
        const s_str = s_c[0..s_len];
        schema_sql_in = std.mem.trim(u8, s_str, "'\"");
    }

    var db_opts = DB.DBOptions{ .wal_sync_mode = sync_mode };
    if (argc >= 7) {
        const opts_c = argv[6];
        const opts_len = std.mem.len(opts_c);
        var opts_str = opts_c[0..opts_len];
        opts_str = std.mem.trim(u8, opts_str, "'\"");

        var it = std.mem.tokenizeAny(u8, opts_str, ";");
        while (it.next()) |pair| {
            var part_it = std.mem.tokenizeAny(u8, pair, "=");
            const key = part_it.next() orelse continue;
            const val = part_it.next() orelse continue;

            const k = std.mem.trim(u8, key, " ");
            const v = std.mem.trim(u8, val, " ");

            if (std.ascii.eqlIgnoreCase(k, "config_file")) {
                parseConfigFile(allocator, v, &db_opts) catch |err| {
                    pzErr.* = c.sqlite3_mprintf("Failed to load config file %.*s: %s", @as(c_int, @intCast(v.len)), v.ptr, @errorName(err).ptr);
                    return c.SQLITE_ERROR;
                };
            } else if (std.ascii.eqlIgnoreCase(k, "memtable_mb")) {
                if (std.fmt.parseInt(usize, v, 10)) |i| {
                    db_opts.memtable_size_bytes = i * 1024 * 1024;
                } else |_| {}
            } else if (std.ascii.eqlIgnoreCase(k, "l0_limit")) {
                if (std.fmt.parseInt(usize, v, 10)) |i| {
                    db_opts.l0_file_limit = i;
                } else |_| {}
            } else if (std.ascii.eqlIgnoreCase(k, "l1_mb")) {
                if (std.fmt.parseInt(u64, v, 10)) |i| {
                    db_opts.l1_size_bytes = i * 1024 * 1024;
                } else |_| {}
            } else if (std.ascii.eqlIgnoreCase(k, "cache_mb")) {
                if (std.fmt.parseInt(usize, v, 10)) |i| {
                    db_opts.block_cache_size_bytes = i * 1024 * 1024;
                } else |_| {}
            } else if (std.ascii.eqlIgnoreCase(k, "compaction_threads")) {
                if (std.fmt.parseInt(usize, v, 10)) |i| {
                    db_opts.compaction_threads = i;
                } else |_| {}
            }
        }
    }

    types.db_registry_mutex.lock();
    defer types.db_registry_mutex.unlock();

    if (types.db_registry == null) {
        types.db_registry = std.StringHashMap(*types.SharedDB).init(allocator);
    }

    var axion_db: *DB = undefined;
    var shared: *types.SharedDB = undefined;

    if (types.db_registry.?.get(path)) |existing_shared| {
        shared = existing_shared;
        shared.ref_count += 1;
        axion_db = shared.db;
    } else {
        axion_db = DB.open(allocator, path, db_opts) catch |err| {
            pzErr.* = c.sqlite3_mprintf("DB.open failed: %s", @errorName(err).ptr);
            return c.SQLITE_ERROR;
        };

        shared = allocator.create(types.SharedDB) catch return c.SQLITE_NOMEM;
        shared.db = axion_db;
        shared.ref_count = 1;

        const path_dup = allocator.dupe(u8, path) catch return c.SQLITE_NOMEM;
        types.db_registry.?.put(path_dup, shared) catch return c.SQLITE_NOMEM;
    }

    const vtab = allocator.create(types.AxionVTab) catch return c.SQLITE_NOMEM;
    vtab.* = std.mem.zeroes(types.AxionVTab);
    vtab.db = axion_db;
    vtab.sqlite_conn = db.?;
    const p_copy = allocator.dupeZ(u8, path) catch return c.SQLITE_NOMEM;
    vtab.path_copy = p_copy.ptr;

    // Load or Create Schema
    var schema: *Schema.TableSchema = undefined;
    var schema_updated = false;

    var declared_schema: ?*Schema.TableSchema = null;
    if (schema_sql_in) |sql| {
        const tbl_name_c = argv[2];
        const tbl_len = std.mem.len(tbl_name_c);
        declared_schema = SqlParser.parseSqliteSchema(allocator, sql, tbl_name_c[0..tbl_len]) catch return c.SQLITE_NOMEM;
    }

    if (axion_db.get(SCHEMA_KEY) catch null) |val_ref| {
        defer val_ref.deinit();
        const loaded_schema = Schema.TableSchema.fromJson(allocator, val_ref.data) catch {
            pzErr.* = c.sqlite3_mprintf("Failed to parse stored schema");
            if (declared_schema) |ds| {
                ds.deinit();
                allocator.destroy(ds);
            }
            return c.SQLITE_ERROR;
        };
        schema = allocator.create(Schema.TableSchema) catch return c.SQLITE_NOMEM;
        schema.* = loaded_schema;

        if (declared_schema) |ds| {
            for (ds.columns.items) |d_col| {
                var found = false;
                for (schema.columns.items) |s_col| {
                    if (std.mem.eql(u8, s_col.name, d_col.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    schema.addColumn(d_col.name, d_col.type, false) catch return c.SQLITE_NOMEM;
                    schema_updated = true;
                }
            }
            ds.deinit();
            allocator.destroy(ds);
        }
    } else {
        if (declared_schema) |ds| {
            schema = ds;
            schema_updated = true;
        } else {
            schema = allocator.create(Schema.TableSchema) catch return c.SQLITE_NOMEM;
            schema.* = Schema.TableSchema.init(allocator, "main") catch return c.SQLITE_NOMEM;
            schema.addColumn("key", .Blob, true) catch return c.SQLITE_NOMEM;
            schema.addColumn("value", .Blob, false) catch return c.SQLITE_NOMEM;
            schema_updated = true;
        }
    }

    if (schema_updated) {
        const json = schema.toJson() catch return c.SQLITE_NOMEM;
        defer allocator.free(json);
        axion_db.put(SCHEMA_KEY, json) catch return c.SQLITE_IOERR;
    }
    vtab.schema = schema;

    var sql_buf = std.ArrayListUnmanaged(u8){};
    defer sql_buf.deinit(allocator);

    const s1 = std.fmt.allocPrint(allocator, "CREATE TABLE x(", .{}) catch return c.SQLITE_NOMEM;
    defer allocator.free(s1);
    sql_buf.appendSlice(allocator, s1) catch return c.SQLITE_NOMEM;

    for (schema.columns.items, 0..) |col, idx| {
        if (idx > 0) {
            sql_buf.appendSlice(allocator, ", ") catch return c.SQLITE_NOMEM;
        }

        var type_str: []const u8 = "BLOB";
        switch (col.type) {
            .Integer => type_str = "INT",
            .Float => type_str = "REAL",
            .Text => type_str = "TEXT",
            .Blob => type_str = "BLOB",
            .Null => type_str = "NULL",
        }

        const s2 = std.fmt.allocPrint(allocator, "{s} {s}", .{ col.name, type_str }) catch return c.SQLITE_NOMEM;
        defer allocator.free(s2);
        sql_buf.appendSlice(allocator, s2) catch return c.SQLITE_NOMEM;

        if (col.is_primary_key) {
            sql_buf.appendSlice(allocator, " PRIMARY KEY") catch return c.SQLITE_NOMEM;
        }
    }
    sql_buf.appendSlice(allocator, ") WITHOUT ROWID") catch return c.SQLITE_NOMEM;
    sql_buf.append(allocator, 0) catch return c.SQLITE_NOMEM;

    const rc = c.sqlite3_declare_vtab(db, @as([*:0]const u8, @ptrCast(sql_buf.items.ptr)));
    if (rc != c.SQLITE_OK) {
        schema.deinit();
        allocator.destroy(schema);
        allocator.destroy(vtab);
        return rc;
    }

    // Register in vtab_registry
    const t_name_c = argv[2];
    const t_name = std.mem.span(t_name_c);

    types.vtab_registry_mutex.lock();
    if (types.vtab_registry == null) {
        types.vtab_registry = std.StringHashMap(*types.AxionVTab).init(allocator);
    }
    const reg_key = types.getVTabRegistryKey(allocator, db.?, t_name) catch {
        types.vtab_registry_mutex.unlock();
        return c.SQLITE_NOMEM;
    };
    types.vtab_registry.?.put(reg_key, vtab) catch {
        types.vtab_registry_mutex.unlock();
        allocator.free(reg_key);
        return c.SQLITE_NOMEM;
    };
    types.vtab_registry_mutex.unlock();

    _ = c.sqlite3_overload_function(db, "axion_backup", -1);

    // Register global function explicitly as fallback
    _ = c.sqlite3_create_function(db, "axion_alter_add_column", 3, c.SQLITE_UTF8, null, axion_alter_add_column_func, null, null);

    ppVtab.* = &vtab.base;
    return c.SQLITE_OK;
}

fn xDisconnect(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));

    // Unregister from vtab_registry
    types.vtab_registry_mutex.lock();
    if (types.vtab_registry) |*map| {
        const key = types.getVTabRegistryKey(allocator, self.sqlite_conn, self.schema.name) catch {
            types.vtab_registry_mutex.unlock();
            return c.SQLITE_ERROR;
        };
        defer allocator.free(key);
        if (map.fetchRemove(key)) |kv| {
            allocator.free(kv.key);
        }
    }
    types.vtab_registry_mutex.unlock();

    self.schema.deinit();
    allocator.destroy(self.schema);

    types.db_registry_mutex.lock();
    defer types.db_registry_mutex.unlock();

    const path_slice = std.mem.span(self.path_copy);

    if (types.db_registry) |*map| {
        if (map.get(path_slice)) |shared| {
            shared.ref_count -= 1;
            if (shared.ref_count == 0) {
                shared.db.close();
                const kv = map.fetchRemove(path_slice).?;
                allocator.free(kv.key);
                allocator.destroy(kv.value);
            }
        }
    }

    allocator.free(path_slice);
    allocator.destroy(self);
    return c.SQLITE_OK;
}

fn xBestIndex(vtab: [*c]c.sqlite3_vtab, info: [*c]c.sqlite3_index_info) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));

    // 1. Check Primary Key Point Lookup (EQ)
    var pk_idx: i32 = -1;
    for (self.schema.columns.items, 0..) |col, i| {
        if (col.is_primary_key) {
            pk_idx = @intCast(i);
            break;
        }
    }

    if (pk_idx != -1) {
        var i: usize = 0;
        while (i < info.*.nConstraint) : (i += 1) {
            const constraint = info.*.aConstraint[i];
            if (constraint.usable != 0 and constraint.iColumn == pk_idx and constraint.op == c.SQLITE_INDEX_CONSTRAINT_EQ) {
                info.*.aConstraintUsage[i].argvIndex = 1;
                info.*.aConstraintUsage[i].omit = 1;
                info.*.estimatedCost = 1.0;
                info.*.estimatedRows = 1;
                info.*.idxNum = 1;
                return c.SQLITE_OK;
            }
        }
    }

    // 2. Secondary Indexes (Prefix Matching)
    for (self.schema.indexes.items) |idx| {
        var match_count: u8 = 0;
        var argv_idx: c_int = 1;
        const cost: f64 = 5.0;
        const rows: i64 = 10;
        var flags: u8 = 0; // 1 = All EQ (Point/Prefix), 2 = Range on last

        // Check columns in order
        for (idx.column_ids.items) |cid| {
            var col_idx: i32 = -1;
            for (self.schema.columns.items, 0..) |col, k| {
                if (col.id == cid) {
                    col_idx = @intCast(k);
                    break;
                }
            }
            if (col_idx == -1) break;

            var found_eq = false;
            // Check for EQ constraint on this column
            var i: usize = 0;
            while (i < info.*.nConstraint) : (i += 1) {
                const constraint = info.*.aConstraint[i];
                if (constraint.usable != 0 and constraint.iColumn == col_idx and constraint.op == c.SQLITE_INDEX_CONSTRAINT_EQ) {
                    info.*.aConstraintUsage[i].argvIndex = argv_idx;
                    argv_idx += 1;
                    info.*.aConstraintUsage[i].omit = 0; // Let SQLite verify too just in case
                    found_eq = true;
                    match_count += 1;
                    break;
                }
            }

            if (found_eq) {
                flags = 1; // So far, equality
                continue;
            }
            break;
        }

        if (match_count > 0) {
            // We matched a prefix of the index
            info.*.estimatedCost = cost;
            info.*.estimatedRows = rows;
            const id_part = @as(c_int, @intCast(idx.id)) << 16;
            const cols_part = @as(c_int, match_count) << 8;
            const flags_part = @as(c_int, flags);
            info.*.idxNum = id_part | cols_part | flags_part;
            return c.SQLITE_OK;
        }
    }

    // 3. PK Range (Fallback)
    if (pk_idx != -1) {
        var idx_num: c_int = 0;
        var argv_idx: c_int = 1;
        var has_range = false;

        var i: usize = 0;
        while (i < info.*.nConstraint) : (i += 1) {
            const constraint = info.*.aConstraint[i];
            if (constraint.usable == 0 or constraint.iColumn != pk_idx) continue;

            if (constraint.op == c.SQLITE_INDEX_CONSTRAINT_GT) {
                idx_num |= 2;
                info.*.aConstraintUsage[i].argvIndex = argv_idx;
                argv_idx += 1;
                has_range = true;
                break;
            } else if (constraint.op == c.SQLITE_INDEX_CONSTRAINT_GE) {
                idx_num |= 4;
                info.*.aConstraintUsage[i].argvIndex = argv_idx;
                argv_idx += 1;
                has_range = true;
                break;
            }
        }
        i = 0;
        while (i < info.*.nConstraint) : (i += 1) {
            const constraint = info.*.aConstraint[i];
            if (constraint.usable == 0 or constraint.iColumn != pk_idx) continue;
            if (constraint.op == c.SQLITE_INDEX_CONSTRAINT_LT) {
                idx_num |= 8;
                info.*.aConstraintUsage[i].argvIndex = argv_idx;
                argv_idx += 1;
                has_range = true;
                break;
            } else if (constraint.op == c.SQLITE_INDEX_CONSTRAINT_LE) {
                idx_num |= 16;
                info.*.aConstraintUsage[i].argvIndex = argv_idx;
                argv_idx += 1;
                has_range = true;
                break;
            }
        }

        if (has_range or (info.*.nOrderBy == 1 and info.*.aOrderBy[0].iColumn == pk_idx and info.*.aOrderBy[0].desc == 0)) {
            info.*.estimatedCost = 100.0;
            info.*.estimatedRows = 100;
            info.*.idxNum = idx_num;
            if (info.*.nOrderBy == 1 and info.*.aOrderBy[0].iColumn == pk_idx and info.*.aOrderBy[0].desc == 0) info.*.orderByConsumed = 1;
            return c.SQLITE_OK;
        }
    }

    info.*.estimatedCost = 1000000.0;
    info.*.estimatedRows = 1000000;
    info.*.idxNum = 0; // Full Scan
    return c.SQLITE_OK;
}

fn xBegin(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));
    types.registry_init_once.call();

    const key = types.RegistryKey{ .conn = self.sqlite_conn, .db = self.db };
    const shard = types.registry.getShard(key);
    shard.mutex.lock();
    defer shard.mutex.unlock();

    if (shard.map.getPtr(key)) |entry| {
        // Join existing transaction
        if (entry.rolled_back) return c.SQLITE_ERROR;
        entry.ref_count += 1;
    } else {
        // Start new transaction on HEAP
        const txn = self.db.beginTransaction() catch return c.SQLITE_ERROR;
        const txn_ptr = allocator.create(Transaction) catch return c.SQLITE_NOMEM;
        txn_ptr.* = txn;

        shard.map.put(key, .{
            .txn = txn_ptr,
            .ref_count = 1,
            .rolled_back = false,
        }) catch {
            allocator.destroy(txn_ptr);
            return c.SQLITE_NOMEM;
        };
    }
    return c.SQLITE_OK;
}

fn xCommit(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));
    types.registry_init_once.call();

    const key = types.RegistryKey{ .conn = self.sqlite_conn, .db = self.db };
    const shard = types.registry.getShard(key);
    shard.mutex.lock();
    defer shard.mutex.unlock();

    if (shard.map.getPtr(key)) |entry| {
        if (entry.rolled_back) {
            entry.ref_count -= 1;
            if (entry.ref_count == 0) {
                allocator.destroy(entry.txn);
                _ = shard.map.remove(key);
            }
            return c.SQLITE_ERROR;
        }

        entry.ref_count -= 1;
        if (entry.ref_count == 0) {
            entry.txn.commit() catch {
                allocator.destroy(entry.txn);
                _ = shard.map.remove(key);
                return c.SQLITE_ERROR;
            };
            allocator.destroy(entry.txn);
            _ = shard.map.remove(key);
        }
    }
    return c.SQLITE_OK;
}

fn xRollback(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));
    types.registry_init_once.call();

    const key = types.RegistryKey{ .conn = self.sqlite_conn, .db = self.db };
    const shard = types.registry.getShard(key);
    shard.mutex.lock();
    defer shard.mutex.unlock();

    if (shard.map.getPtr(key)) |entry| {
        if (!entry.rolled_back) {
            entry.txn.deinit();
            entry.rolled_back = true;
        }

        entry.ref_count -= 1;
        if (entry.ref_count == 0) {
            allocator.destroy(entry.txn);
            _ = shard.map.remove(key);
        }
    }
    return c.SQLITE_OK;
}

fn xUpdate(vtab: [*c]c.sqlite3_vtab, argc: c_int, argv: [*c]?*c.sqlite3_value, pRowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));
    _ = pRowid;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    self.db.checkBgError() catch return c.SQLITE_IOERR;
    self.db.checkMemTableCapacity() catch return c.SQLITE_IOERR;

    var txn_ptr: *Transaction = undefined;
    var local_txn = false;

    types.registry_init_once.call();
    const key = types.RegistryKey{ .conn = self.sqlite_conn, .db = self.db };
    const shard = types.registry.getShard(key);

    {
        shard.mutex.lock();
        if (shard.map.getPtr(key)) |entry| {
            if (entry.rolled_back) {
                shard.mutex.unlock();
                return c.SQLITE_ABORT;
            }
            txn_ptr = entry.txn;
            shard.mutex.unlock();
        } else {
            shard.mutex.unlock();
            const t = self.db.beginTransaction() catch return c.SQLITE_ERROR;
            txn_ptr = allocator.create(Transaction) catch return c.SQLITE_NOMEM;
            txn_ptr.* = t;
            local_txn = true;
        }
    }
    defer if (local_txn) {
        allocator.destroy(txn_ptr);
    };

    var pk_col_type: Schema.ColumnType = .Blob;
    for (self.schema.columns.items) |col| {
        if (col.is_primary_key) {
            pk_col_type = col.type;
            break;
        }
    }

    const old_pk_val = argv[0];
    var old_pk_bytes: ?[]u8 = null;

    if (c.sqlite3_value_type(old_pk_val) != c.SQLITE_NULL) {
        old_pk_bytes = encodePrimaryKey(arena_alloc, old_pk_val, pk_col_type) catch return c.SQLITE_NOMEM;

        const old_row_ref = self.db.get(old_pk_bytes.?) catch null;
        if (old_row_ref) |ref| {
            defer ref.deinit();
            const old_values = Row.Row.deserializeBorrowed(arena_alloc, ref.data) catch return c.SQLITE_NOMEM;

            for (self.schema.indexes.items) |idx| {
                var idx_values = std.ArrayListUnmanaged([]const u8){};
                defer idx_values.deinit(arena_alloc);

                var valid_idx = true;
                for (idx.column_ids.items) |cid| {
                    var col_idx: usize = 0;
                    var found = false;
                    for (self.schema.columns.items, 0..) |col, i| {
                        if (col.id == cid) {
                            col_idx = i;
                            found = true;
                            break;
                        }
                    }

                    if (!found or col_idx >= old_values.len) {
                        valid_idx = false;
                        break;
                    }

                    const val_bytes = rowValueToBytes(arena_alloc, old_values[col_idx]) catch return c.SQLITE_NOMEM;
                    idx_values.append(arena_alloc, val_bytes) catch return c.SQLITE_NOMEM;
                }

                if (valid_idx) {
                    const idx_key = CompositeKey.encodeIndexKey(arena_alloc, idx.id, idx_values.items, old_pk_bytes.?) catch return c.SQLITE_NOMEM;
                    txn_ptr.delete(idx_key) catch |err| return types.mapZigError(err);
                }
            }
        }
    }

    if (argc == 1) {
        if (old_pk_bytes) |pk| {
            txn_ptr.delete(pk) catch |err| return types.mapZigError(err);
        }
    } else {
        var values = std.ArrayListUnmanaged(Row.Row.Value){};
        defer values.deinit(arena_alloc);

        var new_pk_bytes: []u8 = undefined;
        var found_pk = false;

        for (self.schema.columns.items, 0..) |col, i| {
            const val_idx = 2 + i;
            const sqlite_val = argv[val_idx];

            var row_val: Row.Row.Value = .Null;
            switch (col.type) {
                .Integer => row_val = .{ .Integer = c.sqlite3_value_int64(sqlite_val) },
                .Float => row_val = .{ .Float = c.sqlite3_value_double(sqlite_val) },
                .Text => {
                    const txt = c.sqlite3_value_text(sqlite_val);
                    const len = c.sqlite3_value_bytes(sqlite_val);
                    const copy = arena_alloc.alloc(u8, @intCast(len)) catch return c.SQLITE_NOMEM;
                    @memcpy(copy, txt[0..@intCast(len)]);
                    row_val = .{ .Text = copy };
                },
                .Blob => {
                    const blob = c.sqlite3_value_blob(sqlite_val);
                    const len = c.sqlite3_value_bytes(sqlite_val);
                    const copy = arena_alloc.alloc(u8, @intCast(len)) catch return c.SQLITE_NOMEM;
                    @memcpy(copy, @as([*]const u8, @ptrCast(blob))[0..@intCast(len)]);
                    row_val = .{ .Blob = copy };
                },
                .Null => {},
            }
            values.append(arena_alloc, row_val) catch return c.SQLITE_NOMEM;

            if (col.is_primary_key) {
                new_pk_bytes = encodePrimaryKey(arena_alloc, sqlite_val, col.type) catch return c.SQLITE_NOMEM;
                found_pk = true;
            }
        }

        if (!found_pk) return c.SQLITE_ERROR;

        if (old_pk_bytes) |old| {
            if (!std.mem.eql(u8, old, new_pk_bytes)) {
                txn_ptr.delete(old) catch |err| return types.mapZigError(err);
            }
        }

        // Add new index entries
        for (self.schema.indexes.items) |idx| {
            var idx_values = std.ArrayListUnmanaged([]const u8){};
            defer idx_values.deinit(arena_alloc);

            for (idx.column_ids.items) |cid| {
                var col_idx: usize = 0;
                for (self.schema.columns.items, 0..) |col, i| {
                    if (col.id == cid) {
                        col_idx = i;
                        break;
                    }
                }

                const val_idx = 2 + col_idx;
                const col_type = self.schema.columns.items[col_idx].type;

                const real_val_bytes = encodeValue(arena_alloc, argv[val_idx], col_type) catch return c.SQLITE_NOMEM;
                idx_values.append(arena_alloc, real_val_bytes) catch return c.SQLITE_NOMEM;
            }

            const idx_key = CompositeKey.encodeIndexKey(arena_alloc, idx.id, idx_values.items, new_pk_bytes) catch return c.SQLITE_NOMEM;

            if (idx.unique) {
                const seek_key = CompositeKey.encodeIndexSeekKey(arena_alloc, idx.id, idx_values.items) catch return c.SQLITE_NOMEM;

                var iter = txn_ptr.scan(seek_key) catch |err| return types.mapZigError(err);
                defer iter.deinit();

                const next_entry = iter.next() catch |err| return types.mapZigError(err);
                if (next_entry) |entry| {
                    if (std.mem.startsWith(u8, entry.key, seek_key)) {
                        const existing_pk = CompositeKey.extractPrimaryKey(arena_alloc, entry.key, idx.column_ids.items.len) catch return c.SQLITE_CORRUPT;

                        if (!std.mem.eql(u8, existing_pk, new_pk_bytes)) {
                            const vtab_ptr = @as(*c.sqlite3_vtab, @ptrCast(vtab));
                            if (vtab_ptr.zErrMsg != null) c.sqlite3_free(vtab_ptr.zErrMsg);
                            vtab_ptr.zErrMsg = c.sqlite3_mprintf("UNIQUE constraint failed: %s.%s", self.schema.name.ptr, idx.name.ptr);
                            return c.SQLITE_CONSTRAINT;
                        }
                    }
                }
            }

            txn_ptr.put(idx_key, "\x01") catch |err| return types.mapZigError(err);
        }

        const row_data = Row.Row.serialize(arena_alloc, values.items) catch return c.SQLITE_NOMEM;

        txn_ptr.put(new_pk_bytes, row_data) catch |err| return types.mapZigError(err);
    }

    if (local_txn) {
        txn_ptr.commit() catch |err| return types.mapZigError(err);
    }
    return c.SQLITE_OK;
}

fn xRename(vtab: [*c]c.sqlite3_vtab, zNewName: [*c]const u8) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));

    const name_len = std.mem.len(zNewName);
    const new_name = zNewName[0..name_len];

    allocator.free(self.schema.name);
    self.schema.name = allocator.dupe(u8, new_name) catch return c.SQLITE_NOMEM;

    const json = self.schema.toJson() catch return c.SQLITE_NOMEM;
    defer allocator.free(json);

    self.db.put(SCHEMA_KEY, json) catch return c.SQLITE_IOERR;

    return c.SQLITE_OK;
}

fn xSavepoint(vtab: [*c]c.sqlite3_vtab, iSavepoint: c_int) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));
    types.registry_init_once.call();

    const key = types.RegistryKey{ .conn = self.sqlite_conn, .db = self.db };
    const shard = types.registry.getShard(key);
    shard.mutex.lock();
    defer shard.mutex.unlock();

    var txn_ptr: *Transaction = undefined;

    if (shard.map.getPtr(key)) |entry| {
        if (entry.rolled_back) return c.SQLITE_ABORT;
        txn_ptr = entry.txn;
    } else {
        // Implicit transaction
        const txn = self.db.beginTransaction() catch return c.SQLITE_ERROR;
        txn_ptr = allocator.create(Transaction) catch return c.SQLITE_NOMEM;
        txn_ptr.* = txn;

        shard.map.put(key, .{
            .txn = txn_ptr,
            .ref_count = 1,
            .rolled_back = false,
        }) catch {
            allocator.destroy(txn_ptr);
            return c.SQLITE_NOMEM;
        };
    }

    txn_ptr.savepoint(iSavepoint) catch return c.SQLITE_NOMEM;
    return c.SQLITE_OK;
}

fn xRelease(vtab: [*c]c.sqlite3_vtab, iSavepoint: c_int) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));
    types.registry_init_once.call();

    const key = types.RegistryKey{ .conn = self.sqlite_conn, .db = self.db };
    const shard = types.registry.getShard(key);
    shard.mutex.lock();
    defer shard.mutex.unlock();

    if (shard.map.getPtr(key)) |entry| {
        if (!entry.rolled_back) {
            entry.txn.releaseSavepoint(iSavepoint);
        }
    }
    return c.SQLITE_OK;
}

fn xRollbackTo(vtab: [*c]c.sqlite3_vtab, iSavepoint: c_int) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));
    types.registry_init_once.call();

    const key = types.RegistryKey{ .conn = self.sqlite_conn, .db = self.db };
    const shard = types.registry.getShard(key);
    shard.mutex.lock();
    defer shard.mutex.unlock();

    if (shard.map.getPtr(key)) |entry| {
        if (!entry.rolled_back) {
            entry.txn.rollbackTo(iSavepoint) catch return c.SQLITE_ERROR;
        }
    }
    return c.SQLITE_OK;
}

fn xIntegrity(vtab: [*c]c.sqlite3_vtab, zSchema: [*c]const u8, zTabName: [*c]const u8, mFlags: c_int, pzErr: [*c][*c]u8) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));
    _ = zSchema;
    _ = zTabName;
    _ = mFlags;

    const current_version = self.db.versions.getCurrent();
    defer current_version.unref();

    for (current_version.levels) |level| {
        for (level.items) |table_info| {
            const sst_path = self.db.getTablePath(table_info.id) catch |err| {
                pzErr.* = c.sqlite3_mprintf("SSTable %d path error: %s", table_info.id, @errorName(err).ptr);
                return c.SQLITE_ERROR;
            };
            defer allocator.free(sst_path);

            var reader: *SSTable.Reader = undefined;
            if (SSTable.Reader.open(allocator, sst_path, self.db.versions.block_cache)) |r| {
                reader = r;
            } else |err| {
                pzErr.* = c.sqlite3_mprintf("SSTable %d open error: %s", table_info.id, @errorName(err).ptr);
                return c.SQLITE_ERROR;
            }
            defer reader.unref();

            var iter = reader.iterator();
            defer iter.deinit();

            while (iter.next() catch |err| {
                pzErr.* = c.sqlite3_mprintf("SSTable %d iteration error: %s", table_info.id, @errorName(err).ptr);
                return c.SQLITE_ERROR;
            }) |entry| {
                _ = entry;
            }
        }
    }

    const wal_path = std.fs.path.join(allocator, &.{ self.db.db_path, "WAL" }) catch return c.SQLITE_ERROR;
    defer allocator.free(wal_path);

    var dummy_memtable = MemTable.init(allocator) catch return c.SQLITE_ERROR;
    defer dummy_memtable.deinit();

    var temp_wal = WAL.init(allocator, wal_path, .Off) catch return c.SQLITE_ERROR;
    defer temp_wal.deinit();

    _ = temp_wal.replay(dummy_memtable, 0) catch |err| {
        pzErr.* = c.sqlite3_mprintf("WAL replay error: %s", @errorName(err).ptr);
        return c.SQLITE_ERROR;
    };

    return c.SQLITE_OK;
}

fn axion_backup_func(context: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    var path_val: ?*c.sqlite3_value = null;
    if (argc == 1) {
        path_val = argv[0];
    } else if (argc == 2) {
        path_val = argv[1];
    } else {
        c.sqlite3_result_error(context, "axion_backup expects 1 or 2 arguments", -1);
        return;
    }

    if (c.sqlite3_value_type(path_val) != c.SQLITE_TEXT) {
        c.sqlite3_result_error(context, "backup_path must be TEXT", -1);
        return;
    }

    const path_c = c.sqlite3_value_text(path_val);
    const path_len = c.sqlite3_value_bytes(path_val);
    const backup_path = path_c[0..@intCast(path_len)];

    const vtab = @as(*types.AxionVTab, @ptrCast(@alignCast(c.sqlite3_user_data(context))));

    vtab.db.backup(backup_path) catch |err| {
        c.sqlite3_result_error(context, c.sqlite3_mprintf("Backup failed: %s", @errorName(err).ptr), -1);
        return;
    };

    c.sqlite3_result_text(context, "Backup successful", -1, c.SQLITE_STATIC);
    return;
}

fn axion_alter_add_column_func(context: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    if (argc != 3) {
        c.sqlite3_result_error(context, "axion_alter_add_column expects 3 args: table_name, col_name, col_type", -1);
        return;
    }

    // Look up vtab
    const db = c.sqlite3_context_db_handle(context);
    if (db == null) {
        c.sqlite3_result_error(context, "Failed to get DB handle", -1);
        return;
    }
    const t_c = c.sqlite3_value_text(argv[0]);
    const t_len = c.sqlite3_value_bytes(argv[0]);
    const table_name = t_c[0..@intCast(t_len)];

    var vtab: ?*types.AxionVTab = null;
    {
        types.vtab_registry_mutex.lock();
        defer types.vtab_registry_mutex.unlock();
        if (types.vtab_registry) |map| {
            if (types.getVTabRegistryKey(allocator, db.?, table_name)) |key| {
                defer allocator.free(key);
                vtab = map.get(key);
            } else |_| {}
        }
    }

    if (vtab == null) {
        c.sqlite3_result_error(context, "Table not found or not an Axion table", -1);
        return;
    }

    const self = vtab.?;

    const c_c = c.sqlite3_value_text(argv[1]);
    const c_len = c.sqlite3_value_bytes(argv[1]);
    const col_name = c_c[0..@intCast(c_len)];

    const type_c = c.sqlite3_value_text(argv[2]);
    const type_len = c.sqlite3_value_bytes(argv[2]);
    const type_str = type_c[0..@intCast(type_len)];

    var ctype: Schema.ColumnType = .Blob;
    if (std.ascii.eqlIgnoreCase(type_str, "INT") or std.ascii.eqlIgnoreCase(type_str, "INTEGER")) {
        ctype = .Integer;
    } else if (std.ascii.eqlIgnoreCase(type_str, "REAL") or std.ascii.eqlIgnoreCase(type_str, "FLOAT")) {
        ctype = .Float;
    } else if (std.ascii.eqlIgnoreCase(type_str, "TEXT")) {
        ctype = .Text;
    } else if (std.ascii.eqlIgnoreCase(type_str, "NULL")) {
        ctype = .Null;
    }

    self.schema.addColumn(col_name, ctype, false) catch |err| {
        c.sqlite3_result_error(context, c.sqlite3_mprintf("Add Column Failed: %s", @errorName(err).ptr), -1);
        return;
    };

    const json = self.schema.toJson() catch return;
    defer allocator.free(json);

    self.db.put(SCHEMA_KEY, json) catch |err| {
        c.sqlite3_result_error(context, c.sqlite3_mprintf("Persist Schema Failed: %s", @errorName(err).ptr), -1);
        return;
    };

    c.sqlite3_result_text(context, "Column Added. Please reconnect.", -1, c.SQLITE_TRANSIENT);
}

const AxionScalarFunc = fn (?*c.sqlite3_context, c_int, [*c]?*c.sqlite3_value) callconv(.c) void;

fn xFindFunction(vtab: [*c]c.sqlite3_vtab, nArg: c_int, zName: [*c]const u8, pxFunc: [*c]?*const AxionScalarFunc, ppsAux: [*c]?*anyopaque) callconv(.c) c_int {
    const self = @as(*types.AxionVTab, @ptrCast(vtab));
    _ = nArg;

    const name_len = std.mem.len(zName);
    const name = zName[0..name_len];

    if (std.ascii.eqlIgnoreCase(name, "axion_backup")) {
        pxFunc.* = &axion_backup_func;
        ppsAux.* = self;
        return 1;
    }

    if (std.ascii.eqlIgnoreCase(name, "axion_alter_add_column")) {
        return c.SQLITE_NOTFOUND;
    }

    return c.SQLITE_NOTFOUND;
}

var axion_module = c.sqlite3_module{ .iVersion = 2, .xCreate = xConnect, .xConnect = xConnect, .xBestIndex = xBestIndex, .xDisconnect = xDisconnect, .xDestroy = xDisconnect, .xOpen = cursor.xOpen, .xClose = cursor.xClose, .xFilter = cursor.xFilter, .xNext = cursor.xNext, .xEof = cursor.xEof, .xColumn = cursor.xColumn, .xRowid = cursor.xRowid, .xUpdate = xUpdate, .xBegin = xBegin, .xSync = null, .xCommit = xCommit, .xRollback = xRollback, .xRename = xRename, .xSavepoint = xSavepoint, .xRelease = xRelease, .xRollbackTo = xRollbackTo, .xShadowName = null, .xIntegrity = xIntegrity, .xFindFunction = xFindFunction };

pub fn register(db: ?*c.sqlite3) callconv(.c) c_int {
    return c.sqlite3_create_module(db, "axion", &axion_module, null);
}

pub export fn sqlite3_axion_init(db: ?*c.sqlite3, pzErrMsg: [*c][*c]u8, pApi: ?*const c.sqlite3_api_routines) callconv(.c) c_int {
    _ = pzErrMsg;
    _ = pApi;
    return register(db);
}

fn parseConfigFile(alloc: std.mem.Allocator, path: []const u8, opts: *DB.DBOptions) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const size = try file.getEndPos();
    const content = try alloc.alloc(u8, size);
    errdefer alloc.free(content);
    _ = try file.read(content);
    defer alloc.free(content);

    var line_it = std.mem.tokenizeAny(u8, content, "\n");
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var it = std.mem.tokenizeAny(u8, trimmed, "=");
        const key = it.next() orelse continue;
        const val = it.next() orelse continue;

        const k = std.mem.trim(u8, key, " ");
        const v = std.mem.trim(u8, val, " ");

        if (std.ascii.eqlIgnoreCase(k, "memtable_mb")) {
            if (std.fmt.parseInt(usize, v, 10)) |i| opts.memtable_size_bytes = i * 1024 * 1024 else |_| {}
        } else if (std.ascii.eqlIgnoreCase(k, "l0_limit")) {
            if (std.fmt.parseInt(usize, v, 10)) |i| opts.l0_file_limit = i else |_| {}
        } else if (std.ascii.eqlIgnoreCase(k, "l1_mb")) {
            if (std.fmt.parseInt(u64, v, 10)) |i| opts.l1_size_bytes = i * 1024 * 1024 else |_| {}
        } else if (std.ascii.eqlIgnoreCase(k, "cache_mb")) {
            if (std.fmt.parseInt(usize, v, 10)) |i| opts.block_cache_size_bytes = i * 1024 * 1024 else |_| {}
        } else if (std.ascii.eqlIgnoreCase(k, "compaction_threads")) {
            if (std.fmt.parseInt(usize, v, 10)) |i| opts.compaction_threads = i else |_| {}
        }
    }
}

fn rowValueToBytes(alloc: std.mem.Allocator, val: Row.Row.Value) ![]u8 {
    switch (val) {
        .Integer => |i| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &buf, i, .big);
            return alloc.dupe(u8, &buf);
        },
        .Float => |f| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @as(u64, @bitCast(f)), .big);
            return alloc.dupe(u8, &buf);
        },
        .Text => |s| return alloc.dupe(u8, s),
        .Blob => |b| return alloc.dupe(u8, b),
        .Null => return alloc.dupe(u8, ""),
    }
}

fn encodeValueAppend(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), val: ?*c.sqlite3_value, col_type: Schema.ColumnType) !void {
    switch (col_type) {
        .Integer => {
            const i = c.sqlite3_value_int64(val);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &buf, i, .big);
            try list.appendSlice(alloc, &buf);
        },
        .Float => {
            const f = c.sqlite3_value_double(val);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @as(u64, @bitCast(f)), .big);
            try list.appendSlice(alloc, &buf);
        },
        .Text => {
            const txt = c.sqlite3_value_text(val);
            const len = c.sqlite3_value_bytes(val);
            try list.appendSlice(alloc, txt[0..@intCast(len)]);
        },
        .Blob => {
            const blob = c.sqlite3_value_blob(val);
            const len = c.sqlite3_value_bytes(val);
            try list.appendSlice(alloc, @as([*]const u8, @ptrCast(blob))[0..@intCast(len)]);
        },
        else => {},
    }
}

fn encodeValue(alloc: std.mem.Allocator, val: ?*c.sqlite3_value, col_type: Schema.ColumnType) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    try encodeValueAppend(alloc, &buf, val, col_type);
    return buf.toOwnedSlice(alloc);
}

fn encodePrimaryKey(alloc: std.mem.Allocator, val: ?*c.sqlite3_value, col_type: Schema.ColumnType) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    try buf.append(alloc, @intFromEnum(CompositeKey.KeyType.Primary));
    try encodeValueAppend(alloc, &buf, val, col_type);
    return buf.toOwnedSlice(alloc);
}
