# Storage Redesign: ledger v0.2

**Status:** Design — required for v0.2
**Closes:** RT-19 (STORAGE_LIMIT_EXCEEDED permanent degradation), V20 partial (WriteError atomicity)
**Date:** 2026-05-18

---

## Problem Statement

`ledger` v0.1 uses a fixed 256-byte write buffer for invoice storage. This limits the invoice store to 1-2 invoices before `STORAGE_LIMIT_EXCEEDED` is returned permanently with no recovery path. The design was intentional for v0.1 (simple, auditable), but is unsuitable for production use.

**Root causes:**

1. **Fixed write buffer**: `invoice.0` reads the entire `.ledger-invoices` file into a `[256]u8` stack buffer before appending. File size > 256 bytes → `STORAGE_LIMIT_EXCEEDED`. This is an architectural limit, not a tuning parameter.

2. **Non-atomic writes**: The write pattern is: open file → read existing content → append new content → write entire file. If the write fails mid-way (disk full, process killed), the file is truncated. There is no recovery.

3. **No delete/eviction**: There is no `ledger invoice delete` or `ledger store reset`. Once `STORAGE_LIMIT_EXCEEDED` is hit, the store is permanently degraded.

---

## Design Goals

1. **Unbounded storage**: no hard limit on number of invoices in v0.2
2. **Atomic writes**: a failed write must not corrupt existing data
3. **Streaming reads**: `invoice list` must not load the entire file into memory
4. **Agent-safe errors**: all failure modes return machine-readable JSON (no silent exits)
5. **Zero v0.2 compatibility**: design must be implementable in Zero once `std.fs.host()` is available

---

## Design: Append-Only JSONL with Temp-File Atomicity

### Write path (invoice create)

```
1. Validate all inputs (existing validation in v0.1 unchanged)
2. Check idempotency: scan .ledger-invoices for idem_key (existing chunked scan unchanged)
3. If idem_key found → return idempotent response (unchanged)
4. Construct new invoice JSON line (in memory, bounded by field limits)
5. Open .ledger-invoices-tmp for write (create/truncate)
6. Write entire existing .ledger-invoices content to tmp (streaming, 4096-byte chunks)
7. Write new invoice JSON line to tmp
8. fsync .ledger-invoices-tmp
9. Rename .ledger-invoices-tmp → .ledger-invoices (atomic on POSIX)
10. Return success JSON
```

**Why temp + rename:** `rename(2)` is atomic on POSIX (Linux). Either the old file or the new file exists at any point. Power failure or process kill after step 8 but before step 9 leaves the `.ledger-invoices` file unchanged. No corruption.

**Failure handling:**
- Steps 5-8 fail: clean up `.ledger-invoices-tmp`, return `STORE_WRITE_FAILED` (recoverable — original file untouched)
- Step 9 fails: same as above — original file untouched
- `.ledger-invoices-tmp` left behind (crash between 5-9): detect on startup, delete and log warning

### Read path (invoice list)

```
1. Open .ledger-invoices for read
2. Loop: read 4096-byte chunks until EOF
3. For each chunk: write bytes to stdout as-is (file is already valid JSONL)
4. Close file
5. Return (no trailing JSON object — invoice list output is pure JSONL)
```

This is already implemented in v0.1.5 (`runList` loops until EOF). No change needed for the read path.

### Storage limit (v0.2 removes it)

v0.2 removes `STORAGE_LIMIT_EXCEEDED`. The only limit is disk space. When disk is full, the write path fails at step 6-7 and returns `STORE_WRITE_FAILED` with `"disk_full": true` in the error body (detected via ENOSPC errno if available in Zero v0.2, or via write failure).

---

## Zero v0.2 Implementation Requirements

This design requires:

1. **`std.fs.openAppend` or `std.fs.openWrite`** with file create semantics for `.ledger-invoices-tmp`
2. **`std.fs.rename(from, to)`** — atomic file rename
3. **`std.fs.delete(path)`** — for cleanup of leftover `.ledger-invoices-tmp`
4. **Streaming reads**: `std.fs.readOrRaise` already supports chunked reads (4096-byte chunks)
5. **Startup check**: `main.0` must detect and delete `.ledger-invoices-tmp` if present

Items 1-3 are blocked on Zero v0.2 `std.fs.host()`. Item 4 is already available. Item 5 can be implemented with current Zero.

---

## Idempotency Scan Compatibility

The v0.1 chunked idempotency scan (`hasIdempotencyKeyAcross`) is compatible with the v0.2 design:
- Still scans `.ledger-invoices` (not the temp file)
- Still uses 128-byte boundary detection for keys spanning chunk boundaries
- No change needed

---

## Org Store (register.0) — Same Pattern

The `.ledger-data` file (org config) should use the same temp + rename pattern:
1. Write new org JSON to `.ledger-data-tmp`
2. fsync
3. Rename to `.ledger-data`

Currently `.ledger-data` is written in a single pass with a fixed buffer — acceptable because org data is small and fixed-size (one JSON line < 256 bytes). Still, atomic write is safer and should be applied for consistency.

---

## Backward Compatibility

`.ledger-invoices` JSONL format is unchanged. v0.2 binary reads v0.1 data files without migration.

---

## Estimated Binary Size Impact

Current forge binary: ~35 KiB. The streaming write path adds approximately:
- `openForWrite` syscall wrapper: ~50 bytes
- rename syscall wrapper: ~30 bytes
- delete syscall wrapper: ~20 bytes
- startup check for leftover tmp: ~100 bytes

Total estimated increase: < 1 KiB. v0.2 ledger binary should stay under 50 KiB.

---

## v0.2 Checklist

- [ ] Implement temp-file + rename write path in `invoice.0`
- [ ] Implement temp-file + rename write path in `register.0`
- [ ] Add startup check for `.ledger-invoices-tmp` / `.ledger-data-tmp`
- [ ] Remove `STORAGE_LIMIT_EXCEEDED` error code (or demote to STORE_WRITE_FAILED with disk_full field)
- [ ] Remove 256-byte write buffer limit
- [ ] Add `"disk_full": true` field to `STORE_WRITE_FAILED` when ENOSPC detected
- [ ] Update schema.0: remove `STORAGE_LIMIT_EXCEEDED` from error_codes, add `disk_full` to STORE_WRITE_FAILED
- [ ] Update --describe: remove recovery/upgrade_path fields from STORAGE_LIMIT_EXCEEDED (error code removed)
- [ ] Eval test: create 100 invoices without hitting any limit
- [ ] Eval test: simulate disk full → STORE_WRITE_FAILED with disk_full, original file intact
