![](img/cover.jpg)
# Axion ⚡

**The High-Performance, Embeddable Storage Engine for Zig & SQLite.**

Axion is a next-generation LSM-tree storage engine written in **Zig**. It is designed to exploit the full potential of modern NVMe SSDs and multi-core CPUs, offering distinct advantages: **blazing fast writes**, **ACID compliance**, **MVCC**, and seamless integration as a **SQLite Virtual Table**.

Whether you need a raw key-value store for your Zig application or a turbo-charged backend for your SQLite queries, Axion delivers.

---

## 🚧 Development Notice

> **Warning:** Axion is currently in **heavy development** and relies on features anticipated in the upcoming **Zig 0.16** release. It is **not yet suitable for production environments**.
>
> APIs, file formats, and internal structures may change without notice. We welcome intrepid contributors and feedback, but please use with caution!

---

## 🚀 Key Features

*   **LSM-Tree Architecture:** Optimized for heavy write workloads with Leveled Compaction.
*   **ACID Transactions:** Strict serializability and snapshot isolation using MVCC (Multi-Version Concurrency Control).
*   **Modern I/O:** Utilizes `io_uring` on Linux for asynchronous, high-throughput WAL writes.
*   **SQLite Integration:** Drop-in replacement for SQLite tables via the Virtual Table mechanism. Run SQL on top of an LSM tree!
*   **Efficiency:**
    *   **Prefix Compression:** Reduces storage footprint for keys with common prefixes.
    *   **Block Cache:** Sharded, concurrent block cache to minimize disk reads.
    *   **Bloom Filters:** fast negative lookups to avoid unnecessary disk seeks.
    *   **Zero-Copy:** Optimized read paths to reduce memory churn.
*   **Observability:** Built-in structured logging and atomic metrics for deep runtime insights.

---

## ⚡ Quick Start

### As a Zig Library

Add Axion to your `build.zig.zon` and import it:

```zig
const std = @import("std");
const Axion = @import("axion").DB;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Open the database
    var db = try Axion.open(allocator, "./my_data", .{
        .memtable_size_bytes = 64 * 1024 * 1024,
        .block_cache_size_bytes = 1 * 1024 * 1024 * 1024, // 1GB Cache
    });
    defer db.close();

    // Write
    try db.put("user:101", "Alice");

    // Read
    if (try db.get("user:101")) |value| {
        defer value.deinit();
        std.debug.print("Found: {s}\n", .{value.data});
    }

    // Atomic Transaction
    var txn = try db.beginTransaction();
    defer txn.deinit();
    
    try txn.put("balance:A", "500");
    try txn.put("balance:B", "300");
    try txn.commit();
}
```

### As a SQLite Storage Backend

Axion exposes itself as a SQLite Virtual Table module. This allows you to keep the SQL language you love but swap the B-Tree engine for Axion's LSM tree.

```bash
# Start the Axion Shell (bundled with SQLite)
./zig-out/bin/axion_shell
```

```sql
-- Mount an Axion database as a virtual table
-- Syntax: CREATE VIRTUAL TABLE <name> USING axion('<path>', '<wal_mode>', '', '<options>');
CREATE VIRTUAL TABLE users USING axion('./users_db', 'NORMAL', '', 'memtable_mb=64;cache_mb=256');

-- Use standard SQL
INSERT INTO users (key, value) VALUES ('u1', '{"name": "John", "age": 30}');
INSERT INTO users (key, value) VALUES ('u2', '{"name": "Jane", "age": 25}');

SELECT * FROM users WHERE key >= 'u1';
```

### Foreign Language Support (C, Python, Rust, Go)

Axion provides a native C ABI (`libaxion`), making it easy to integrate with any language that supports FFI (Foreign Function Interface) or CGO.

**1. Build the Shared Library:**
```bash
zig build
# Output: zig-out/lib/libaxion.so (or .dll/.dylib)
# Header: include/axion.h
```

**2. Usage in C:**
```c
#include "axion.h"
#include <stdio.h>

int main() {
    axion_db_t* db;
    if (axion_db_open("./c_data", &db) != 0) return 1;

    axion_db_put(db, "key", 3, "val", 3);

    char* val;
    size_t len;
    if (axion_db_get(db, "key", 3, &val, &len) == 0 && val) {
        printf("Got: %.*s\n", (int)len, val);
        axion_db_free_val(val, len);
    }

    axion_db_close(db);
    return 0;
}
```

**3. Usage in Python, Rust, Go:**
*   **Python:** Use `ctypes` or `cffi` to load `libaxion.so`.
*   **Rust:** Use `bindgen` to generate bindings from `axion.h`.
*   **Go:** Use `cgo` to link against `libaxion`.

---

## 🛠️ Build & Test

Axion requires **Zig 0.16 (master)**.

```bash
# Build release optimized binaries
zig build -Doptimize=ReleaseFast

# Run the full test suite (Unit + Integration)
zig build test

# Run the benchmark suite
zig build -Doptimize=ReleaseFast bench_native_axion bench_native_sqlite bench_vtab_axion     
```

---

## 📐 Architecture

Axion is built on first principles, avoiding over-engineering while ensuring robustness.

```ascii
+-----------------------------------------------------------------------+
|                      Axion - Architecture Overview                    |
+-----------------------------------------------------------------------+

   User Application (Zig / C / Go / Python)    OR    SQLite Query Engine
          |                                              |
          | (Native API)                                 | (Virtual Table)
          v                                              v
+-----------------------------------------------------------------------+
|  INTERFACE LAYER:  c_api.zig  /  sqlite/vtab.zig                      |
+-----------------------------------------------------------------------+
          |
          v
+-----------------------------------------------------------------------+
|  TRANSACTION LAYER (MVCC)                                             |
|                                                                       |
|  [ CommitBatcher ] <---(Group Commit)---> [ Transaction Manager ]     |
|         |                                          |                  |
|         +--- Serializes WAL Entries                +-- Global Version |
|         +--- Detects Conflicts                     +-- Snapshots      |
+-----------------------------------------------------------------------+
          | (Writes)                                 | (Reads)
          v                                          v
+--------------------------+           +--------------------------------+
|  STORAGE LAYER (LSM)     |           |  READ PATH                     |
|                          |           |                                |
|  +--------------------+  |           |  1. Check MemTable (Skiplist)  |
|  | MemTable (Memory)  |  |           |     (Latest updates)           |
|  | [Sharded Skiplist] |  |           |                                |
|  +--------------------+  |           |             v                  |
|            | (Flush)     |           |                                |
|            v             |           |  2. Check Block Cache (LRU)    |
|  +--------------------+  |           |     (Hot data in memory)       |
|  | WAL (Disk)         |  |           |                                |
|  | [Append-Only Log]  |  |           |             v                  |
|  +--------------------+  |           |                                |
|            | (Compact)   |           |  3. Check Bloom Filters        |
|            v             |           |     (Skip missing keys)        |
|  +--------------------+  |           |                                |
|  | SSTables (Disk)    |  |           |             v                  |
|  | Level 0 (Unsorted) |  |           |                                |
|  | Level 1 (Sorted)   | <------------+  4. Scan SSTables (Disk)       |
|  | Level 2 (Sorted)   |  |              (Binary search blocks)        |
|  +--------------------+  |                                            |
+--------------------------+           +--------------------------------+

+-----------------------------------------------------------------------+
|                      WORKFLOW: WRITE (PUT)                            |
+-----------------------------------------------------------------------+

1. User calls db.put(key, val)
2. Transaction created, assigned Sequence Number.
3. Written to WAL (Write-Ahead Log) for durability.
   (Optimized: Pre-serialized, patched with checksum later)
4. Written to MemTable (In-Memory SkipList).
5. Commit confirmed to user.

... LATER (Background) ...

6. MemTable Full? -> FLUSH to Disk (Level 0 SSTable).
7. Level 0 Full?  -> COMPACTION (Merge L0 -> L1).

+-----------------------------------------------------------------------+
|                      WORKFLOW: READ (GET)                             |
+-----------------------------------------------------------------------+

1. User calls db.get(key)
2. Acquire Snapshot (Current Max Sequence Number).
3. Search MemTable. Found? -> Return (if visible to snapshot).
4. Search Block Cache. Found? -> Return.
5. For each Level (L0 -> L1...):
   a. Check Bloom Filter. (Negative? -> Skip File).
   b. Read Index Block.
   c. Read Data Block from Disk.
   d. Check CRC32 Checksum.
   e. Search Key in Block. Found? -> Return.
```

---

## 📊 Configuration

Axion can be configured via the Options string in `CREATE VIRTUAL TABLE` or via the C API.

| Option | Default | Description |
| :--- | :--- | :--- |
| `memtable_mb` | 64 | Size of in-memory buffer (MB) before flushing. |
| `cache_mb` | 10 | Size of the in-memory LRU block cache (MB). |
| `l0_limit` | 4 | Number of SSTables in Level 0 before compaction triggers. |
| `l1_mb` | 256 | Target size of Level 1 (MB). Subsequent levels are 10x larger. |
| `compaction_threads` | 1 | Number of background threads for merging tables. |
| `wal_sync_mode` | `Full` | `Full` (fsync), `Normal` (write), or `Off` (unsafe). |
| `config_file` | - | Path to an external configuration file (k=v format). |

Example with multiple options:
```sql
CREATE VIRTUAL TABLE logs USING axion('./logs_db', 'NORMAL', '', 'memtable_mb=128;l0_limit=8;compaction_threads=2');
```

---

## 📈 Benchmarks

Axion demonstrates significant performance advantages over standard SQLite (B-Tree) for write-heavy workloads, while maintaining competitive read speeds.

**Environment:** Linux, **Zig 0.16 (master)** (ReleaseFast), 100 Threads, 50k Keys.

### 1. Sync Mode: `FULL` (Strict Fsync Durability)
*Safety first: Every write is physically flushed to disk.*

| Metric | SQLite (Native) | Axion (Native) | Axion (VTab) |
| :--- | :--- | :--- | :--- |
| **Write (Random)** | 160 | **5,863** | 2,556 |
| **Write (Sequential)** | 157 | **6,087** | 2,595 |
| **Read (Point)** | 1,926,734 | **2,658,290** | 2,198,205 |
| **Range Scan** | **539,888** | 240,440 | 149,312 |
| **Mix (Read/Write)** | **2,379,954*** | 11,493 | 5,082 |

*\*Note: SQLite's high Mix score suggests the benchmark may benefit from implicit transaction batching or extremely high read ratios in this specific test case, whereas Axion appears to be paying the fsync penalty for writes more strictly.*

### 2. Sync Mode: `NORMAL` (Buffered/Async Writes)
*Performance balanced: Writes are buffered to OS cache; `io_uring` used where applicable.*

| Metric | SQLite (Native) | Axion (Native) | Axion (VTab) |
| :--- | :--- | :--- | :--- |
| **Write (Random)** | 153 | **369,037** | 282,246 |
| **Write (Sequential)** | 154 | **401,930** | 303,050 |
| **Read (Point)** | 1,097,877 | **2,574,712** | 2,204,108 |
| **Range Scan** | **599,852** | 241,794 | 148,225 |
| **Mix (Read/Write)** | **2,537,048** | 670,029 | 495,939 |

### 3. Sync Mode: `OFF` (Unsafe/Max Speed)
*Raw in-memory speed: No disk sync guarantees.*

| Metric | SQLite (Native) | Axion (Native) | Axion (VTab) |
| :--- | :--- | :--- | :--- |
| **Write (Random)** | 138 | **370,795** | 275,176 |
| **Write (Sequential)** | 163 | **404,950** | 284,876 |
| **Read (Point)** | 1,133,065 | **2,549,722** | 2,202,941 |
| **Range Scan** | **582,908** | 244,441 | 140,152 |
| **Mix (Read/Write)** | **2,483,035** | 669,776 | 474,662 |

---

## 🖥️ CLI Tools

Axion comes with a handy shell for management and inspection.

```bash
# Open a DB and check internal stats
./zig-out/bin/axion_shell ./my_data --sql ".stats"
```

Output:
```text
--- Axion Metrics ---
Puts: 1250430
Gets: 4021
Iterators: 50
Compactions: 12
Flushes: 8
BlockCache Hits: 8540
BlockCache Misses: 120
Txn Success: 1250000
Txn Conflict: 0
---------------------
```

---

## 📜 License

This project is open-source software.

---

## 🤖 AI Usage Disclosure

This project's codebase was initially written by human developers and has since evolved through AI-assisted audits and contributions.

*   **Code Origin:** The core logic and initial implementation are human-authored.
*   **AI Role:** AI tools are used for code auditing, documentation generation, website building, and intelligent auto-completion.
*   **Code Verification:** AI does **not** write code directly without human oversight. There is no "vibe coding" involved; all AI-suggested changes are reviewed.
*   **Documentation:** All documentation and website content are primarily generated and maintained by AI to ensure clarity and consistency.