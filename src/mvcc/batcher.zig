const std = @import("std");
const log = @import("../log.zig");
const metrics = @import("../metrics.zig");
const Transaction = @import("transaction.zig").Transaction;
const TransactionManager = @import("transaction.zig").TransactionManager;
const WAL = @import("../lsm/wal.zig").WAL;
const Wyhash = std.hash.Wyhash;

pub const CommitRequest = struct {
    txn: *Transaction,
    next: ?*CommitRequest = null,
    status: enum { Pending, Success, Conflict } = .Pending,

    // Futex for waiting
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

pub const CommitBatcher = struct {
    const HISTORY_SIZE = 64 * 1024;
    const HistoryEntry = struct {
        hash: u64,
        version: u64,
    };

    allocator: std.mem.Allocator,
    tm: *TransactionManager,

    // Lock-free Stack Head (MPSC)
    head: std.atomic.Value(?*CommitRequest),

    thread: std.Thread,
    running: std.atomic.Value(bool),
    execution_mutex: std.Thread.Mutex,

    // For waking up the batcher thread
    event_futex: std.atomic.Value(u32),

    // Conflict History Cache
    history: []HistoryEntry,
    history_idx: usize,
    history_min_ver: u64,

    pub fn init(allocator: std.mem.Allocator, tm: *TransactionManager) !*CommitBatcher {
        const self = try allocator.create(CommitBatcher);
        self.allocator = allocator;
        self.tm = tm;
        self.head = std.atomic.Value(?*CommitRequest).init(null);
        self.running = std.atomic.Value(bool).init(true);
        self.execution_mutex = std.Thread.Mutex{};
        self.event_futex = std.atomic.Value(u32).init(0);

        self.history = try allocator.alloc(HistoryEntry, HISTORY_SIZE);
        @memset(self.history, .{ .hash = 0, .version = 0 });
        self.history_idx = 0;
        self.history_min_ver = 0;

        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn deinit(self: *CommitBatcher) void {
        self.running.store(false, .release);
        std.Thread.Futex.wake(&self.event_futex, 1);
        self.thread.join();
        self.allocator.free(self.history);
        self.allocator.destroy(self);
    }

    pub fn lockExecution(self: *CommitBatcher) void {
        self.execution_mutex.lock();
    }

    pub fn unlockExecution(self: *CommitBatcher) void {
        self.execution_mutex.unlock();
    }

    pub fn submit(self: *CommitBatcher, req: *CommitRequest) void {
        req.status = .Pending;
        req.done.store(0, .monotonic);

        // Push to lock-free stack
        while (true) {
            const current = self.head.load(.monotonic);
            req.next = current;
            // CAS: If head is still current, set it to req.
            if (self.head.cmpxchgWeak(current, req, .release, .monotonic)) |_| {
                // Failed, retry (loop)
            } else {
                // Success
                break;
            }
        }

        // Wake up batcher
        self.event_futex.store(1, .release);
        std.Thread.Futex.wake(&self.event_futex, 1);
    }

    fn run(self: *CommitBatcher) void {
        var pending_flush_ver: ?u64 = null;
        var pending_clients: ?*CommitRequest = null;

        // FIFO Queue of pending requests
        var queue_head: ?*CommitRequest = null;
        var queue_tail: ?*CommitRequest = null;
        const BATCH_LIMIT = 1000;

        while (self.running.load(.acquire)) {
            // 1. Drain Stack (Atomic Swap)
            const stack_top = self.head.swap(null, .acquire);

            if (stack_top) |node| {
                // Reverse stack to get FIFO segment (Oldest -> Newest)
                var current: ?*CommitRequest = node;
                var prev: ?*CommitRequest = null;
                var first_in_segment: ?*CommitRequest = null; // This will be the tail of the new segment

                while (current) |curr| {
                    if (first_in_segment == null) first_in_segment = curr;
                    const next = curr.next;
                    curr.next = prev;
                    prev = curr;
                    current = next;
                }
                const segment_head = prev; // Oldest

                // Append segment to queue
                if (queue_tail) |qt| {
                    qt.next = segment_head;
                } else {
                    queue_head = segment_head;
                }
                queue_tail = first_in_segment;
            }

            // Check if we have work in the queue
            if (queue_head == null) {
                // No work.
                if (pending_flush_ver) |_| {
                    self.tm.wal.completeFlush() catch |err| {
                        log.err(.wal, "WAL Flush Error: {}", .{err});
                    };
                    self.wakeClients(pending_clients);
                    pending_flush_ver = null;
                    pending_clients = null;
                } else {
                    // Wait for work
                    const signal = self.event_futex.swap(0, .acquire);
                    if (signal == 1) {
                        continue;
                    }
                    std.Thread.Futex.wait(&self.event_futex, 0);
                }
                continue;
            }

            // 2. Cut a batch from queue_head
            var batch_count: usize = 0;
            var batch_end = queue_head;
            var batch_prev: ?*CommitRequest = null;

            while (batch_end) |node| : (batch_count += 1) {
                if (batch_count >= BATCH_LIMIT) break;
                batch_prev = node;
                batch_end = node.next;
            }

            // Detach batch
            if (batch_prev) |bp| {
                bp.next = null;
            }

            const current_batch = queue_head;

            // Advance queue
            queue_head = batch_end;
            if (queue_head == null) queue_tail = null;

            // 3. Process Batch (CPU Work)
            self.execution_mutex.lock();
            const result = self.prepareBatch(current_batch);
            self.execution_mutex.unlock();

            // 4. Complete Previous Flush (Wait IO)
            if (pending_flush_ver) |_| {
                self.tm.wal.completeFlush() catch |err| {
                    log.err(.wal, "WAL Flush Error: {}", .{err});
                };
                self.wakeClients(pending_clients);
                pending_flush_ver = null;
                pending_clients = null;
            }

            // 5. Submit New Flush (Async IO)
            if (result.max_ver > 0) {
                self.tm.wal.submitFlush(result.max_ver) catch |err| {
                    log.err(.wal, "WAL Submit Error: {}", .{err});
                    var iter = result.list;
                    while (iter) |req| {
                        req.status = .Conflict;
                        iter = req.next;
                    }
                    self.wakeClients(result.list);
                    continue;
                };
                pending_flush_ver = result.max_ver;
                pending_clients = result.list;
            } else {
                self.wakeClients(result.list);
            }
        }

        // Cleanup
        if (pending_flush_ver) |_| {
            self.tm.wal.completeFlush() catch {};
            self.wakeClients(pending_clients);
        }
    }

    const BatchResult = struct {
        list: ?*CommitRequest,
        max_ver: u64,
    };

    fn prepareBatch(self: *CommitBatcher, first_req_node: ?*CommitRequest) BatchResult {
        // Note: list is already ordered FIFO by run()

        var valid_count: usize = 0;

        // Iterate and validate
        var node_iter = first_req_node;
        while (node_iter) |req| {
            // Conflict Check
            if (self.checkConflict(req.txn)) {
                req.status = .Conflict;
                metrics.global.txnConflict();
            } else {
                req.status = .Success;
                metrics.global.txnSuccess();
                valid_count += 1;
            }
            node_iter = req.next;
        }

        if (valid_count == 0) {
            return BatchResult{ .list = first_req_node, .max_ver = 0 };
        }

        // Phase 2: Assign Versions & Serialize WAL

        node_iter = first_req_node;
        while (node_iter) |req| {
            if (req.status == .Success) {
                // Assign Version
                const commit_ver = self.tm.global_version.fetchAdd(1, .monotonic) + 1;

                // Patch & CRC
                self.tm.prepareTxnBuffer(req.txn, commit_ver);

                // Write to WAL
                self.tm.wal.appendRaw(req.txn.wal_buffer.items, commit_ver) catch |err| {
                    log.err(.wal, "WAL Append Error: {}", .{err});
                    req.status = .Conflict;
                };

                if (req.status == .Success) {
                    // Apply to MemTable
                    self.tm.applyToMemTable(req.txn, commit_ver) catch {
                        // MemTable error (OOM?)
                    };

                    // Add to History
                    var w_it = req.txn.buffer.keyIterator();
                    while (w_it.next()) |k| {
                        const h = Wyhash.hash(0, k.*);
                        self.history[self.history_idx] = .{ .hash = h, .version = commit_ver };

                        // Prepare for next slot
                        self.history_idx = (self.history_idx + 1) % self.history.len;

                        // Update min_ver. The slot we just filled (idx) was the oldest?
                        // No, the slot we are GOING to fill (history_idx) contains the entry we are about to overwrite in next loop.
                        // So the oldest valid entry is at history_idx.
                        self.history_min_ver = self.history[self.history_idx].version;
                    }
                }
            }
            node_iter = req.next;
        }

        const max_ver = self.tm.global_version.load(.acquire);

        return BatchResult{ .list = first_req_node, .max_ver = max_ver };
    }

    fn wakeClients(self: *CommitBatcher, list: ?*CommitRequest) void {
        _ = self;
        var notify = list;
        while (notify) |req| {
            const next = req.next;
            req.done.store(1, .release);
            std.Thread.Futex.wake(&req.done, 1);
            notify = next;
        }
    }

    fn checkConflict(self: *CommitBatcher, txn: *Transaction) bool {
        // Optimistic: Check if any key in WRITE set has been updated since txn.read_version
        // Optimization: Check Recent History first
        const use_history = txn.read_version >= self.history_min_ver;

        var it = txn.buffer.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            var must_check_db = true;

            if (use_history) {
                const h = Wyhash.hash(0, key);
                var found = false;

                // Iterate backwards from newest to oldest
                var idx = self.history_idx;
                var checked: usize = 0;

                while (checked < self.history.len) : (checked += 1) {
                    if (idx == 0) idx = self.history.len;
                    idx -= 1;

                    const item = self.history[idx];

                    if (item.version <= txn.read_version) {
                        // Reached entries older than our read snapshot.
                        // Since history is monotonic, we are done.
                        break;
                    }

                    if (item.hash == h) {
                        found = true;
                        break;
                    }
                }

                if (!found) must_check_db = false;
            }

            if (must_check_db) {
                if (self.tm.storage_latest_ver_fn(self.tm.storage_ptr, key)) |latest| {
                    if (latest > txn.read_version) {
                        return true;
                    }
                }
            }
        }
        return false;
    }
};
