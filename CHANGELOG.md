# HEROS Changelog

All notable changes to the HEROS agent operations stack (forge, ledger, guardian, vault, audit, and ecosystem integrations). Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added (2026-06-04 — `remix`: agent-generated, user-tweakable companion UIs)
- **`remix` v0.1.0** — Seventh HEROS tool. Turns data from a *connected* app into a **separate, themeable, user-editable companion UI** (e.g. a Netflix watchlist → a to-do list) via a declarative `heros.ui/v1` spec: tweakable **design tokens** (W3C-DTCG `{$type,$value}` colors/spacing the *user* edits) + a **closed widget tree** + a **whitelisted action table**. `remix_render` is the trust boundary between an LLM-authored (and user-edited) document and the native renderer: pure-jq validation (no eval), closed component catalog, every rendered string sanitized (no control/non-ASCII/oversized), color/dimension token validation, https + optional `REMIX_ALLOWED_HOSTS` allowlist for links/images, forbids raw OS `intent`/`package`/`component` fields (the host builds intents, the spec never does), `onTap`→action referential integrity, and a 500-node DoS budget. Returns `{status:ok,valid:true,node_count,spec}` or `{error_code:INVALID_SPEC,violations:[…]}`. Pure compute, no I/O — actions are gated through `guardian` at dispatch time. 17 CI-gated eval cases incl. every rejection path (`remix/eval-cases.jsonl`, `remix/eval-bridge.sh`). MCP 2025-11-25 compliant; manifest ≤512 chars.
- **`docs/remix-spec.md`** — Research + design + honest limits: what's possible (Server-Driven UI from supported connectors) vs. not (you cannot repaint a third-party app in place on stock OSes, and there's no general "read any app's private data" — the sandbox working as intended). Maps the user's intent (tweak connected software, separate UI/UX from existing data, JSON output the user can hand-edit) to the achievable core, with `remix_resolve` (token-alias resolution) and reference host renderers on the roadmap.
- **CI**: added `remix-eval` pure-bash job (17 cases); shellcheck now covers `remix/` scripts; MCP manifest lint now checks all 7 manifests (was 6).

### Added (2026-06-03 — mobile app tracks: Android APK + Apple macOS/iOS)
- **`android-app/`** — minimal dependency-free Java + WebView Android app (AGP 8.6.0, Gradle 8.14.3 wrapper, compileSdk 34, JDK 17); the app shell for the Zero-as-WASM-in-app design. New `android-apk` CI job builds `:app:assembleDebug` on a runner with the Android SDK. Honest note: not buildable in the dev container (Google Maven 403, no SDK); YAML + Android XML validated locally. Distinct from the `android/arm64` console binary in `app/` (runs under Termux today) — a stock APK can't run the bash bridges, so the production path embeds the Zero kernels as a `wasm32-wasi` module.
- **`apple/`** — Swift Package for macOS + iOS: `HEROSClient` (shared URLSession client, both platforms), `HEROSConsoleUI` (SwiftUI, both platforms), `heros-console-cli` (macOS). New `apple-build` CI job on a macOS runner compile-verifies macOS (`swift build`) and iOS (`xcodebuild -destination 'generic/platform=iOS'`). iOS genuinely cannot be built in the Linux container (Apple toolchain is macOS-only); a signed App Store `.ipa` additionally needs account-bound Apple signing certs.

### Added (2026-06-03 — HEROS Console desktop app)
- **`app/` — HEROS Console** — a dependency-free **Go** (stdlib-only) cross-platform desktop app that drives the MCP bridges (guardian, evolve, audit, vault) from a local web UI. Owns no risk logic: it spawns the bash bridges as subprocesses and renders their JSON, so every safety gate stays in the bridges. Binds to loopback only; UI embedded via `go:embed`. Cross-compiles to **Linux (amd64/arm64), macOS (amd64/arm64), and Windows (amd64)** from a Linux host — no Mac required for the macOS build. Linux build run-tested end-to-end against guardian (CRITICAL + nonce) and evolve (propose → gated promote → list). New `desktop-app` CI job (vet + 5-target cross-compile). Honest caveat: bridges are bash+jq, so Windows needs Git Bash/WSL; iOS requires a Mac toolchain (not produced here); Android tracked via `docs/aosp-zero-integration.md`.

### Added (2026-06-03 — `evolve`: safe, audited agent self-improvement)
- **`evolve` v0.1.0** — Sixth HEROS tool. Adapts the valuable core of an agent self-improvement loop (skills as procedural memory, improved from recorded outcomes) into the HEROS safety model: agents `evolve_skill_propose` skills (stored pending — no behaviour change), and every behaviour-changing self-modification (`evolve_skill_promote` / `evolve_skill_retire`) is risk-classified HIGH, gated by a single-use, action+skill-bound human-approval nonce (guardian protocol), and recorded in a tamper-evident chain-hashed change log (audit protocol). `evolve_skill_record_outcome` drives a confidence score (Wilson lower bound); `evolve_memory_note` stores inert, audited learning notes; `evolve_history` reads and cryptographically verifies the trail. Pure-bash bridge, 8 tools. 38 CI-gated eval cases incl. the full gated lifecycle, single-use-nonce enforcement, and tamper detection (`evolve/eval-cases.jsonl`, `evolve/eval-bridge.sh`). MCP 2025-11-25 compliant; all descriptions ≤512 chars.
- **`evolve_skill_recommend`** (9th tool) — pure-compute skill selection: ranks active skills by confidence score → successes → name. Read-only/SAFE. Mirrors `evolve/spec/skill_rank.0`. (Brings the suite to 40 eval cases.)
- **`evolve/spec/skill_score.0`** + **`evolve/spec/skill_rank.0`** — The two pure-compute kernels (confidence scoring; skill ranking) specified for Zero (fixed-point Wilson lower bound; integer rank key). Spec-only until a Zero compiler is in CI; the awk reference in the bridge is the tested source of truth, with a documented parity contract (`evolve/spec/README.md`).
- **`docs/hermes-mapping.md`** — Honest component-by-component map of NousResearch/hermes-agent → HEROS: what was ported (skills/self-improvement → `evolve`), what's already covered (40+ tools → `guardian`), what's out of scope and why (model providers, messaging gateways, execution backends — all network/async I/O, not Zero-expressible), and why a literal full-Zero-rewrite + five native apps are reframed as a roadmap (Tauri desktop first) rather than over-claimed.
- **CI**: added `evolve-eval` pure-bash job (38 cases); shellcheck now covers `evolve/` scripts; MCP manifest lint now checks all 6 manifests (was 5).

### Added (2026-05-31 — Platform expansion + YC research)
- **`guardian` v0.1.0** — Universal operation safety oracle. Pre-execution risk gate (SAFE/NOTABLE/MEDIUM/HIGH/CRITICAL) for 6 operation categories: file system, shell commands, network requests, infrastructure changes, code execution, and data access. Same `decision_required` + `approval_nonce` protocol as forge. Pure bash bridge (no compiled binary required). 35 CI-gated eval cases (`guardian/eval-cases.jsonl`, `guardian/eval-bridge.sh`). MCP 2025-11-25 compliant; manifest ≤512 chars.
- **`vault` v0.1.0** — Agent-native credential storage. `vault_secret_set/get/delete/list` with named secrets, base64-encoded on disk, flock-protected atomic writes, `.vault-audit` JSONL access log. `vault_secret_delete` requires human approval nonce (same V39 protocol as forge). 25 CI-gated eval cases (`vault/eval-cases.jsonl`, `vault/eval-bridge.sh`).
- **`audit` v0.1.0** — Tamper-evident append-only compliance log. Chain-hashed JSONL: each entry hashes the previous entry using SHA-256 (genesis seed → latest entry). `audit_verify` re-derives the entire hash chain and returns `{valid: false, broken_at_entry: N}` on any deletion or modification — directly fixes V3 in `docs/threat-model.md`. 29 CI-gated eval cases (`audit/eval-cases.jsonl`, `audit/eval-bridge.sh`).
- **`herd` coordination tool** — GNAP-style git-native multi-agent coordination. `herd init`, `register-agent`, `heartbeat`, `claim-task`, `complete-task`, `abandon-task`. File-locked JSON state, deadline-aware task claiming, idempotent registration. 30 CI-gated eval cases (`herd/eval-herd.sh`).
- **forge Squawk integration** (`forge/squawk-bridge.sh`) — Second-pass Postgres lock-hazard detection via Squawk (Rust binary). Graceful `SQUAWK_NOT_AVAILABLE` when Squawk is absent; 27 stub-based eval cases (`forge/eval-squawk.sh`).
- **ledger Litestream replication** (`ledger/litestream-replicate.sh`) — Wrapper for Litestream SQLite replication with S3/GCS/ABS replica URI validation, path traversal rejection, and `LITESTREAM_NOT_AVAILABLE` graceful degradation. 22 CI-gated stub-based eval cases (`ledger/eval-litestream.sh`); deployment guide in `docs/deployment-replication.md`.
- **OpenTelemetry tracing** (`zero-ecosystem/observability/otel-trace.sh`) — Sourceable OTEL helper for bash bridges. `emit_span`, `trace_enabled`, `timer_start/timer_ms`. Strict stdout isolation (no bytes ever emitted on the MCP stdio channel). 7 CI-gated eval cases (`zero-ecosystem/observability/eval-otel.sh`).
- **`docs/deep-research-report.md`** — 7-section adversarially-verified synthesis from 5 parallel research agents: YC RFS sourcing, verified real-world incidents (Replit July 2025, Moltbook Jan 2026), regulatory landscape (EU AI Act Aug 2, 2026), competitive landscape + absorption risk, market sizing (MarketsandMarkets $7.84B→$52.62B), OSS tool compatibility matrix, agent payments/identity standards.
- **CI expanded**: 7 new pure-bash eval jobs (guardian, vault, audit, herd, squawk, otel, litestream); shellcheck now covers all 22 shell scripts (was 7); MCP manifest lint now checks all 5 manifests (was 2).

### Changed (2026-05-31 — YC application update)
- **`docs/yc-application.md`**: Replaced hypothetical incident with verified real incidents (Replit July 2025, Moltbook Jan 2026). Fixed EU AI Act language (Art. 12/14/26, high-risk systems only, Aug 2, 2026 deadline). Fixed YC RFS blockquote — removed unconfirmed sub-bullets; added secondary-source caveat. Updated eval count to 269 total (140 JSONL + 43 auth/bridge + 86 ecosystem). Added Aembit + Claude Code sandbox to competition table with absorption-risk framing.
- **`docs/strategic-vision.md`**: Updated market comparables (Datadog $3.43B FY2025, Stripe $159B, HashiCorp $6.4B); detailed Claude Code sandbox + Aembit as verified absorption risk; added MarketsandMarkets CAGR data.

### Changed (2026-05-29 — YC application readiness pass)
- **Canonical YC application**: `docs/yc-application.md` rewritten as the single source of truth, structured around YC's actual application questions with every claim cited to a repo file, an explicit pre-revenue/pre-users traction statement, and a "RFS: Software for Agents" mapping. `forge/yc_application_draft.md` and `forge/yc_scorecard.md` re-labeled as forge-specific supporting material that link to it.
- **Honest claims**: `ledger` described as agent-native invoice/org accounting (true double-entry journals moved to the v0.2 roadmap) across README, landing page, manifest, and docs. Unverifiable "239+/250+ red-team cycles" counts replaced with the verifiable substance (documented red-team process, OWASP Agentic Top-10 audit, P0–P2 findings resolved, zero `eval`). Hosted pricing tiers explicitly marked planned/not-yet-deployed.
- **Demo**: added `docs/demo-transcript.md` — a 60-second walkthrough whose outputs are reproduced from the CI-gated eval suite + binary source (forge SAFE/NOTABLE/CRITICAL, ledger idempotent writes).

### Fixed (2026-05-29)
- Corrected the broken GitHub URL (`soumyadebnath/heros` → `itsoumya-d/HEROS`) in all 9 affected files — the README/landing `curl` install commands were 404ing.
- Resolved version drift: non-compiled `forge/src/*.0` + `forge/zero.json` aligned to the shipped `0.1.4`; `ledger/src/*.0` + `ledger/zero.json` aligned to `0.1.11` (matches the compiled `*_mini.0` binaries; no binary behavior change).
- Corrected the README quickstart output (adding a NULLABLE column is `NOTABLE`, not `SAFE`, and `add_column` emits no `table`/`column` field) to match eval case FE-03 and `forge_mini.0`. Fixed the landing-page hero op shape and its dead `docs/*.html` links.
- Added `SPDX-License-Identifier: MIT` headers to the bridge and key-gen scripts.

### Security (2026-05-25 — Launch Hardening Round)
- **CRIT-1**: `ledger/key-gen.sh` — HMAC seed was passed via `openssl dgst -hmac <seed>` CLI arg, exposing it in `/proc/<pid>/cmdline`. Replaced with `python3` env-based computation (same pattern as both bridges). Eliminated `xxd` dependency.
- **CRIT-2**: `zero-ecosystem/eval-harness/zeval.sh` — Four error messages used raw shell variable interpolation into JSON string contexts (`echo "{...\"$line\"...}"`). Replaced all four with `jq -cn --arg` calls. A crafted non-JSON line in eval-cases.jsonl could previously inject `"status":"ok"` into the CI pass/fail JSON.
- **HIGH-2**: `forge/mcp-bridge.sh` — `stored_revoked` whitespace strip used `//[[:space:]]/` (removes ALL whitespace) instead of `%%[[:space:]]*` (strips from first whitespace). Diverged from ledger bridge V421 fix. Fixed to match ledger bridge.
- **HIGH-3**: `ledger/key-gen.sh` — Missing `export LC_ALL=C.UTF-8` allowed operator locale to affect HMAC computation, potentially causing key-gen/validation mismatch. Added.
- **MED-1**: `forge/mcp-bridge.sh` — Added HMAC seed minimum-length check (≥32 chars) at startup, matching ledger bridge RT-463/RT-603. Forge bridge previously accepted weak seeds silently.
- **MED-2**: `ledger/mcp-bridge.sh` — ORG_EXISTS fast-path responses now strip `_new_data` via `del(._new_data)` before returning to agent. Defense-in-depth against internal field leakage on interrupted writes.

### Fixed
- Eval test case descriptions corrected: FE-04 ("drop table"), FE-06 ("analyze without --from → UNKNOWN_COMMAND"), FE-07 ("identical schemas → SAFE baseline"), LE-15 ("unknown top-level command → UNKNOWN_COMMAND").
- GitHub repo URL placeholder (`OWNER/REPO`) replaced with `itsoumya-d/HEROS` in README, docs, MCP manifests, and Show HN post.

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
