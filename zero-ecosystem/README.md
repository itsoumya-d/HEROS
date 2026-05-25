# zero-ecosystem — Zero Language Primitive Library Index

Each subdirectory is a perpetual build loop for one missing Zero primitive.
Sub-agents never declare done — one primitive shipped means picking the next gap.

**Last updated:** 2026-05-24  
**Zero version at last audit:** v0.1.3 (2026-05-24)

---

## Ecosystem Gap Index

| Gap | Dir | Status | Blocker | Priority |
|---|---|---|---|---|
| JSON Schema validator | `json-schema/` | **Implemented v0.1.0** | None | P1 |
| Structured logger (JSONL append) | `logger/` | **Implemented v0.1.0** | None | P1 |
| Eval / test harness | `eval-harness/` | Design | None — bash wrapper for Zero binary | P1 |
| Rate limiter (native Zero) | `rate-limiter/` | Blocked | world.in + file-lock needed for shared state | P2 |
| MCP stdio server (native) | `mcp-server/` | Blocked | world.in (stdin) not in Zero v0.1.x (V34) | P1 on Zero v0.2 |
| HTTP routing / server | `http-router/` | Blocked | std.net socket I/O not available | P2 on Zero v0.2 |
| Key-value store (file-backed) | `kv-store/` | Design | std.fs.rename needed for atomic writes | P2 |
| JWT decoder (verify only) | `jwt/` | Design | Need base64 + HMAC-SHA256; std.crypto has hash32 only | P3 |
| OpenAPI emitter | `openapi/` | Design | Build from --describe JSON shape | P2 |
| HMAC-SHA256 | `crypto/` | Blocked | std.crypto has hash32 only; need more primitives | P3 on Zero v0.2 |

---

## Sub-agent Assignment

Each gap below is assigned to a perpetual research → implement → eval sub-agent loop.
The loop structure mirrors the main project loop: research delta → design → build → eval → checkpoint → repeat.

### P1 Gaps (unblocked, start now)

1. **json-schema/** — JSON Schema draft-07 subset validator. Input: schema object + data object. Output: `{"valid":true}` or `{"valid":false,"errors":[...]}`. Agent-facing: `jsonschema validate --schema <file> --data <json>`. Why in Zero: sub-10 KiB validator that agents can embed in any pipeline without a Python/Node runtime.

2. **logger/** — Structured JSONL append logger. Input: log level + key-value pairs. Output: appends `{"ts":N,"level":"info","msg":"...","k":"v"}` to a file. Agent-facing: `zlog info --key value`. Why: agents need tamper-evident append-only logs they can query with `invoice list`-style streaming reads.

3. **eval-harness/** — Binary evaluation runner. Wraps a Zero binary, runs a JSONL test case file, compares actual vs expected JSON output, reports pass/fail. Agent-facing: `zeval --binary ./ledger --cases eval-cases.jsonl`. Why: enables automated regression testing of all Zero tools without a Zero test runner.

### P2 Gaps (blocked on Zero v0.2 or design work needed)

4. **kv-store/** — File-backed key-value store. Get/set/delete with atomic writes (temp+rename). Agent-facing: `zkv set --key session_id --value abc`. Foundation for auth tokens, session state, agent memory.

5. **openapi/** — OpenAPI 3.1 emitter. Reads a tool's `--describe` JSON and emits an OpenAPI 3.1 YAML spec. Enables integration with API gateways and documentation generators without code changes.

6. **rate-limiter/** — Token bucket rate limiter as a standalone binary (not bash). Shared state via file lock. Agent-facing: `zlimit check --key session_1 --bucket api_calls --rate 100 --window 3600`. Currently implemented in bash; needs native Zero port when file-lock syscalls available.

### Tracking (blocked on Zero language)

7. **mcp-server/** — Native Zero MCP stdio server. Blocked on `world.in`. Design spec in `docs/mcp-security-spec.md`. Replaces bash bridge entirely when Zero v0.2 ships stdin support.

8. **http-router/** — HTTP server + router. Blocked on `std.net` socket I/O. Design TBD.

9. **jwt/** — JWT verification (HS256/RS256). Blocked on HMAC-SHA256 (std.crypto currently only has hash32).

10. **crypto/** — HMAC, AES-GCM, base64. Blocked on Zero stdlib expansion.

---

## How to work in a sub-agent loop

```
1. Read the gap README in zero-ecosystem/<gap>/README.md
2. Research: check Zero v<current> for any new stdlib that unblocks the gap
3. Design: write the agent-facing CLI interface (--describe schema first)
4. Build: implement in Zero; use std.crypto.hash32, std.fs, std.args, std.mem
5. Eval: write 5-10 JSONL test cases; run with zeval (or bash eval for now)
6. Checkpoint: update this README, bump version in sub-dir README
7. Goto 1 — never declare done; pick the next sub-gap
```

---

## Zero v0.1.3 capability baseline (2026-05-24)

Available for building NOW (no blockers):
- `std.args` — CLI argument parsing
- `std.fs` — file open/read/write/close (no rename, no delete yet)
- `std.crypto.hash32` — djb2+SDBM 32-bit hash
- `std.rand.entropyU32` — entropy source
- `std.time.wallSeconds` — Unix timestamp
- `std.mem.eql`, `std.mem.span`, `std.mem.len` — memory operations
- `world.out`, `world.err` — stdout/stderr write

Blocked (track at https://github.com/vercel-labs/zero):
- `world.in` — stdin reading (V34)
- `std.fs.rename` — atomic file rename (RT-19)
- `std.fs.delete` — file deletion
- `std.net` — socket I/O
- `std.crypto.hmac`, `std.crypto.aes` — cryptography beyond hash32
