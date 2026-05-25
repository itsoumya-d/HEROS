# HEROS Changelog

All notable changes to forge and ledger. Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Security (2026-05-25 — Launch Hardening Round)
- **CRIT-1**: `ledger/key-gen.sh` — HMAC seed was passed via `openssl dgst -hmac <seed>` CLI arg, exposing it in `/proc/<pid>/cmdline`. Replaced with `python3` env-based computation (same pattern as both bridges). Eliminated `xxd` dependency.
- **CRIT-2**: `zero-ecosystem/eval-harness/zeval.sh` — Four error messages used raw shell variable interpolation into JSON string contexts (`echo "{...\"$line\"...}"`). Replaced all four with `jq -cn --arg` calls. A crafted non-JSON line in eval-cases.jsonl could previously inject `"status":"ok"` into the CI pass/fail JSON.
- **HIGH-2**: `forge/mcp-bridge.sh` — `stored_revoked` whitespace strip used `//[[:space:]]/` (removes ALL whitespace) instead of `%%[[:space:]]*` (strips from first whitespace). Diverged from ledger bridge V421 fix. Fixed to match ledger bridge.
- **HIGH-3**: `ledger/key-gen.sh` — Missing `export LC_ALL=C.UTF-8` allowed operator locale to affect HMAC computation, potentially causing key-gen/validation mismatch. Added.
- **MED-1**: `forge/mcp-bridge.sh` — Added HMAC seed minimum-length check (≥32 chars) at startup, matching ledger bridge RT-463/RT-603. Forge bridge previously accepted weak seeds silently.
- **MED-2**: `ledger/mcp-bridge.sh` — ORG_EXISTS fast-path responses now strip `_new_data` via `del(._new_data)` before returning to agent. Defense-in-depth against internal field leakage on interrupted writes.

### Fixed
- Eval test case descriptions corrected: FE-04 ("drop table"), FE-06 ("analyze without --from → UNKNOWN_COMMAND"), FE-07 ("identical schemas → SAFE baseline"), LE-15 ("unknown top-level command → UNKNOWN_COMMAND").
- GitHub repo URL placeholder (`OWNER/REPO`) replaced with `soumyadebnath/heros` in README, docs, MCP manifests, and Show HN post.

### Added
- `CONTRIBUTING.md` — gstack-style team workflow, autoresearch eval loop pattern, security standards.

### Security (2026-05-24 — Pre-launch)
- **CRIT-01 ledger**: Fixed TOCTOU race condition in `ledger_invoice_create` — `flock -x` now wraps idempotency check + binary call + append atomically. Without this fix, two concurrent bridge processes sharing `HEROS_DATA_DIR` could both pass the idempotency check and both write duplicate invoice records.
- **CRIT-02 ledger**: Fixed non-atomic `.ledger-data` write — replaced `>` truncate-and-write with `mktemp` + `mv` (atomic rename, same filesystem). Prevents partial-write corruption on process kill or disk-full mid-write.
- **P2-001 forge**: Added `isIdChar` guard to `forge_mini.0` table name byte-write loops (`drop_table`, `add_table`). Defense-in-depth: if upstream schema validation ever fails, the write-path guard emits `__INVALID_NAME__` sentinel instead of raw bytes.
- **Both bridges**: Merged two-process HMAC computation into a single `python3` invocation — computed HMAC hash no longer briefly appears in `/proc/cmdline`.
- **Both bridges**: `python3` startup check now gated on `HEROS_API_KEY` — unauthenticated deployments (most dev environments) no longer require `python3` in PATH.
- **ledger bridge**: Invoice count changed from `wc -l` to `jq -sc 'length'` — count now matches `invoice_list` semantics; divergence on externally-written or corrupt JSONL is eliminated.
- **ledger bridge**: Binary output validated as JSON object before `_new_data`/`_new_invoice_json` extraction — malformed binary output returns `EXEC_FAILED` rather than raw panic output to the agent.
- **ledger bridge**: Invoice count JSON construction changed from `echo` string interpolation to `jq -cn --argjson` — consistent with rest of bridge.
- **forge bridge**: Schema size error message corrected from "64KB" to "64 KiB (65536 bytes)" — accurate representation of the actual byte limit.
- **P2-01 ledger**: Added `isNonAscii` checks to `--to`, `--idempotency-key`, and `--memo` validation loops in `ledger_mini.0`. Non-ASCII bytes (0x80-0xFF) are now rejected with `INVALID_INPUT` — previously they passed `isControlChar` but were not sanitized in `writeDoubleJsonEscaped`, risking malformed UTF-8 in stored JSONL.

### Changed
- **ledger manifest**: Rate limit labels changed from `per_ip`/`per_org` to `per_session` — accurately reflects that limits are per bridge process instance, not per IP or org.
- **ledger manifest**: `startup_sequence` updated — removed mandatory `ledger_invoice_count` step (no storage limit in v0.1.10).
- **ledger manifest**: `STORAGE_LIMIT_EXCEEDED` removed from `ledger_invoice_create.error_codes` — not applicable to `ledger_mini.0` + bridge design.
- **ledger manifest**: `request_id` field `maxLength` corrected from 128 → 512 to match bridge enforcement.
- **ledger README**: Removed stale "~1-2 invoice limit" and `STORAGE_LIMIT_EXCEEDED` references.
- **ledger README**: Architecture table updated to reflect `ledger_mini.0` single-file source (removed stale `src/` modular references).

### Added
- **`README.md`**: Root platform overview covering forge + ledger, MCP setup, architecture, and security summary.
- **`docs/pricing.md`**: Freemium pricing model — Free hosted tier, Developer ($0), Pro ($49/mo), Enterprise (custom).
- **`docs/launch-strategy.md`**: YC-aligned launch strategy — HN Show HN, MCP registry, X thread, YC application guidance, 90-day success metrics.
- **`docs/concept-gate.md`**: Three category-rebuild proposals for next Zero-ecosystem tool (auth.0, queue.0, schema.0).
- **`zero-ecosystem/README.md`**: Gap index for Zero primitive library — json-schema, logger, eval-harness, rate-limiter, MCP server, HTTP router, KV store, JWT, OpenAPI, HMAC.
- **forge eval tests 30-38**: Drop/set NOT_NULL (RT-82), Add NOT_NULL column (RT-79a), schema_truncated (RT-99), 64 KiB boundary, 1 MiB limit, request_id echo, isIdChar guard, rate limiting.
- **ledger eval tests 23-25**: Double-escape adversarial cases — `"` and `\` in same field (LE-23), adjacent `\"` sequence (LE-24), special chars in idempotency_key (LE-25).
- **`forge/eval-cases.jsonl`**: Added FE-30 (duplicate table → INVALID_SCHEMA), FE-31 (djb2 collision pair gf/hWH accepted as distinct → NOTABLE), FE-32 (33-table schema → INVALID_SCHEMA), FE-33 (257-column schema → schema_truncated:true). 29 → 33 binary-testable cases.
- **`ledger/eval-cases.jsonl`**: Rebuilt for binary-level testing — added `--entropy`/`--timestamp` to all register/invoice create calls; corrected invoice list/count to expect UNKNOWN_COMMAND (bridge-only); added LE-20 through LE-25 (double-escape regression tests). 20 → 25 cases.

---

## ledger v0.1.11 — 2026-05-24

### Security
- **P2-01**: Added `isNonAscii` checks (bytes 0x80-0xFF) to `--to`, `--idempotency-key`, and `--memo` validation loops. Non-ASCII bytes now rejected with `INVALID_INPUT` — previously they passed `isControlChar` but could produce malformed UTF-8 sequences in `_new_invoice_json` or `_new_data` stored JSON.

### Changed
- `eval-cases.jsonl`: Rebuilt as binary-level tests (25 cases) — added required `--entropy`/`--timestamp` args; updated invoice list/count expectations to UNKNOWN_COMMAND; added double-escape regression tests LE-20 through LE-25.

---

## forge v0.1.4 — 2026-05-18

### Added
- Column type change detection (RT-83) — type change now reported as CRITICAL (was silently SAFE)
- NOT_NULL column analysis: `add_not_null`, `drop_not_null`, `set_not_null` operations (RT-79a, RT-82)
- PRIMARY_KEY operations: `add_primary_key`, `drop_primary_key` (RT-88)
- UNIQUE constraint operations: `add_unique`, `drop_unique` (RT-92)
- FOREIGN KEY operations: `add_foreign_key`, `drop_foreign_key` (RT-93)
- DEFAULT operations: `add_default`, `drop_default` (RT-87)
- Schema truncation sentinel: `schema_truncated:true` when >256 columns (RT-99)
- `decision_required:true` extended to `set_not_null` and `add_primary_key` operations
- `_forge_version` field in all analyze responses (V34)

### Fixed
- Column rename false-SAFE (V9) — hash-set column diff replaces count-based diff; renames now correctly CRITICAL
- Table rename false-SAFE (Cycle 6) — hash-set table diff; renames correctly CRITICAL
- djb2 collision false-positive (Cycle 5) — dual hash (djb2 + SDBM) reduces collision probability to ~1/2^64
- `decision_required` trigger: was "HIGH/CRITICAL only"; now also triggers on data loss + set_not_null + add_primary_key
- `forge_mini.0` comment on `decision_required` corrected (RT-79b)
- Empty-table migration false-HIGH → now correctly SAFE (FE-12)

### Security
- RT-109: Array subscript injection in nonce lookup — format validation (`^[0-9a-f]{16}$`) before array access
- RT-106: `od` unavailability in minimal containers — fallback chain (od → xxd → openssl)
- V39: `human_acknowledgment_token` nonce protocol implemented — 64-bit nonce, 5-min TTL, single-use
- RT-99: Silent column truncation at >256 columns — schema_truncated flag prevents false-SAFE
- RT-43: Pipe character injection in schema content — rejected before binary invocation
- RT-68: `isError` detection fixed — normalizes nested `error.code` format to flat `error_code`
- V7e: Session re-initialization rejection (returns -32002)

---

## ledger v0.1.10 — 2026-05-18

### Added
- `ledger invoice count` subcommand — line count on `.ledger-invoices` (RT-34)
- `mcp-bridge.sh` — full MCP stdio server (JSON-RPC 2.0, rate limiting, idempotency, STORE_READ_FAILED detection)
- `mcp-manifest.json` — MCP manifest with all 4 tools, error codes, rate limits, agent quickstart
- API key authentication via HMAC-SHA256 (`heros_<scope>_<key_id>_<secret>` format, V44)
- `_rate_limit` field in all success responses — proactive throttling signal for agents
- `writeDoubleJsonEscaped` — two-level JSON escaping for user strings in `_new_data`/`_new_invoice_json`
- `retryable` field on all error responses (RT-62)

### Fixed
- RT-71a: `^` (caret, 0x5E) silently dropped in `to` field — `byteChar` now covers all printable ASCII 32-126
- RT-72: DEL (0x7F) passed control-char validation — `hasControlChar` now explicitly rejects 0x7F
- LE-21/LE-22: Double-escape bug — `"` and `\` in user strings now survive two JSON decode passes correctly
- Trailing comma syntax error in `--describe` block (line 209)

### Security
- RT-12: Control chars in idempotency key bypassed idempotency — `fmt.hasControlChar` added
- RT-16: Non-ASCII bytes silently passed to output — `fmt.hasNonAscii` added to all string fields
- RT-33: Argument injection — all bridge args constructed as bash arrays, no string concatenation
- RT-382: `export LC_ALL=C.UTF-8` — ensures consistent jq behavior regardless of operator LANG

---

## forge v0.1.3 — 2026-05-18

### Added
- Column rename detection (V9) — table-seeded hash-set column diff
- `--request-id` flag for log deduplication in distributed agent pipelines
- `forge-analyze` shell wrapper for file-based workflows
- `mcp-bridge.sh` — MCP stdio server for forge
- `mcp-manifest.json` — MCP manifest with V39 nonce protocol
- OWASP Agentic Top 10 (ASI01–ASI10) audit complete

### Fixed
- Column hash-set diff replaces count-based diff (V9)

---

## forge v0.1.1 — 2026-05-17

### Added
- Initial forge release — schema risk analysis in Zero lang
- Risk tiers: SAFE, NOTABLE, MEDIUM, HIGH, CRITICAL
- `has_data_loss`, `decision_required`, `estimated_lock_ms` fields on all operations
- `--describe` self-documenting API payload
- JSON-only output on all code paths

### Security
- V1: JSON injection via `--request-id` — input validation
- V2/V3: Schema charset validation — rejects non-identifier chars
- 64 KiB schema size limit

---

## ledger v0.1.0 — 2026-05-17

### Added
- Initial ledger release — agent-native accounting in Zero lang
- `ledger register` — idempotent org provisioning
- `ledger invoice create` — invoice creation with idempotency keys
- `ledger invoice list` — JSONL invoice retrieval
- JSON-only output on all code paths, stable error codes
- `--describe` self-documenting API payload
