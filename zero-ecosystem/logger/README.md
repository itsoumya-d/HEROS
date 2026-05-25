# logger — Structured JSONL Append Logger

**Status:** Design phase  
**Blocker:** None — implementable in Zero v0.1.2  
**Priority:** P1  
**Sub-agent loop owner:** logger

---

## Why

Agents running autonomously need an audit trail. When a fleet of agents calls ledger or forge in parallel, the operator needs to know: what was called, when, by which agent, what the result was. stdout is ephemeral; a JSONL append log is durable.

`zlog` is a single-binary structured logger that:
- Appends one JSON line per call to a log file
- Returns machine-readable JSON on every code path (including errors)
- Never blocks the caller (append-only I/O)
- Produces log files that `invoice list`-style streaming readers can consume

---

## Agent-facing interface

```bash
# Append a log entry
zlog info --msg "invoice created" --agent_id agent_007 --invoice_id inv_a1b2c3d4

# Append an error entry
zlog error --msg "STORE_WRITE_FAILED" --tool ledger --error_code STORE_WRITE_FAILED

# Read recent entries (last N lines)
zlog tail --n 100

# Describe the tool
zlog --describe
```

**Log entry format (written to .zlog-default):**
```json
{"ts":1747526401,"level":"info","msg":"invoice created","agent_id":"agent_007","invoice_id":"inv_a1b2c3d4"}
```

**Write response:**
```json
{"status":"ok","ts":1747526401,"level":"info","log_file":".zlog-default"}
```

---

## Design

### Log levels
`debug`, `info`, `warn`, `error` — validated enum, `INVALID_INPUT` on unknown level.

### Key-value pairs
Arbitrary `--key value` pairs after required flags. Collected via `std.args` scan. Max 16 pairs per entry (v0.1 stack limit). Max 64 bytes per key, 256 bytes per value.

### Write path
1. Parse level + msg flags
2. Collect extra key-value pairs
3. Open log file for append (`std.fs.openAppend` — needs Zero v0.1.x append mode; fallback: read + rewrite with temp-file)
4. Write JSON line: `{"ts":N,"level":"L","msg":"M","k1":"v1",...}\n`
5. Close
6. Return status JSON to stdout

### Read path (`tail`)
`zlog tail --n N` reads the log file from the end, emitting the last N lines as JSONL to stdout. Implementation: read in 4096-byte chunks from end of file (like Unix `tail`).

### Security
- All string values validated: `fmt.hasControlChar`, `fmt.hasNonAscii`
- No eval, no shelling out
- Log file path: always relative to CWD; no absolute paths accepted (path traversal prevention)
- Log entry fields marked `UNTRUSTED` in `--describe`: `msg`, all extra key-value pair values

---

## v0.1 constraints

`std.fs` in Zero v0.1.2 supports `open`, `create`, `readOrRaise`, `writeAll`, `close`. No native append mode. Workaround: `openAppend` is not available — v0.1 implementation must read existing file, then rewrite with new entry appended using temp-file pattern (same as storage-redesign-v2.md). This makes zlog O(N) on log file size for v0.1. Fixed in v0.2 when `std.fs.openAppend` lands.

---

## Eval cases (target: 8/8 pass)

| Case | Input | Expected |
|---|---|---|
| EL-01 | `zlog info --msg "test"` | `{"status":"ok",...}` and entry appended to file |
| EL-02 | `zlog error --msg "failed" --code E01` | error entry with level=error |
| EL-03 | invalid level `--level trace` | `{"error_code":"INVALID_INPUT"}` |
| EL-04 | msg with control char | `{"error_code":"INVALID_INPUT"}` |
| EL-05 | `zlog tail --n 5` on 10-entry file | last 5 lines as JSONL |
| EL-06 | `zlog tail --n 5` on empty file | empty output, status ok |
| EL-07 | missing --msg flag | `{"error_code":"MISSING_FLAG"}` |
| EL-08 | `--describe` cold-start | full schema parseable by fresh LLM |

---

## Version history

- v0.1.0 (planned): info/warn/error levels, append via rewrite, tail command
- v0.2.0 (planned): native append mode, O(1) write, log rotation
