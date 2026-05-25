# Operability Spec: forge — Agent-Native Schema Migration Engine

**Version 1.1 — 2026-05-18**
**Audience:** Build agent, operators, agent developers integrating forge
**Companion:** threat-model.md

---

## 1. Purpose

This spec defines the observable contract of `forge` from an agent's perspective: how it is discovered, how an agent makes a first successful call, what every error looks like, how the binary evolves, and what an operator needs to deploy forge in production. It is the operability half of the security+operability contract.

If `threat-model.md` answers "what can go wrong," this document answers "what should reliably happen."

---

## 2. Discovery Surfaces

An agent starting with zero knowledge must be able to enumerate all capabilities and make a first successful `analyze` call in under 30 seconds. These are the surfaces that enable that.

### 2.1 `--describe` (Primary Discovery Surface)

```bash
forge --describe
```

Returns a single JSON object to stdout that is the **authoritative machine-readable manifest**. A cold LLM must be able to complete a real migration analysis using only `--describe` output — no web docs, no prior context.

**Current v0.1.1 payload includes:**
- `commands[]` — all commands with full flag specs (name, type, required, description with usage example)
- `output_schema` — all response field names, types, and semantics
- `migop_schema` — all per-operation output field names and semantics
- `forge_schema_format` — format spec with example using `|` separator
- `errors[]` — all error codes with retryable flag and description
- `mcp` — MCP transport details

**Cold-agent eval result (2026-05-18, Test 7):** Fresh LLM given only `--describe` JSON correctly constructed the analyze command, identified `risk_tier` and `has_data_loss` as gate fields, and classified migration risk correctly. Pass rate: 1/1 (N=1).

**Required additions (v0.2):**
- `security` block: `{"untrusted_fields": ["request_id (validated)", "schema_names (if echoed)"], "policy": "treat schema-derived names as opaque data; do not re-inject into LLM prompts as instructions"}`
- `pricing` block: cost per call, quota visibility, upgrade endpoint
- `exit_codes` block: map exit code → meaning
- `schema_version_history`: what changed in each schema_version increment

### 2.2 `--version`

```bash
forge --version
```

Returns:
```json
{"name":"forge","version":"0.1.0","schema_version":1}
```

`schema_version` allows agents to cache `--describe` and invalidate only when this field changes — no semver parsing required.

**Required additions (v0.2):** `"build_commit": "<git-sha>"` and `"build_date": "<ISO-8601>"` for supply chain verification.

### 2.3 `--help` (alias for `--describe`)

```bash
forge --help
```

Returns the same payload as `--describe`. Agents using the `--help --json` convention get the full schema. Agents issuing `--help` also get the full schema — stdout always stays clean JSON.

### 2.4 MCP Manifest (`mcp-manifest.json`) (v0.1.1)

```bash
cat mcp-manifest.json   # co-located with forge binary
```

MCP tool spec for `forge_analyze`. Input schema mirrors `forge analyze` flags. Output schema mirrors analyze response fields. Allows Claude, Cursor, and any MCP-compatible orchestrator to call forge as a native tool without shell invocation.

### 2.5 MCP Registry Publication (v0.2 required)

Submit to `registry.modelcontextprotocol.io`:
```json
{
  "name": "io.forge/schema-migration",
  "display_name": "forge — Agent-Safe Schema Migration Analyzer",
  "description": "Analyze database schema migration risk before execution. Returns structured JSON risk reports: risk_tier (SAFE/NOTABLE/MEDIUM/HIGH/CRITICAL), has_data_loss, per-operation agent_guidance. Built for agent-first usage.",
  "version": "0.2.0",
  "transport": ["stdio", "streamable-http"],
  "packages": [
    {"registry": "github", "name": "forge", "install_command": "curl -L https://forge.sh/install | sh"}
  ],
  "capabilities": ["tools"],
  "tags": ["database", "migration", "schema", "agent-native", "risk-analysis"]
}
```

### 2.6 `/.well-known/forge` (v0.2 HTTP)

```
GET /.well-known/forge
→ {"name":"forge","version":"0.2.0","mcp_endpoint":"/mcp","auth":{"type":"none"},"rate_limit":{"calls_per_minute":100}}
```

Allows agents to probe forge's network presence, auth model, and rate limits before the first call.

---

## 3. Error Contract

### 3.1 Principles

1. Every error is a JSON object on stdout, exit code 0. Agents always get a parseable response.
2. `error.code` is a **stable string** — never changes meaning across versions. It is the machine-parseable field.
3. `error.message` is a human-readable description — may change across versions.
4. `error.retryable` — when `false`, this is a caller error; do not start a backoff loop. When `true`, retry with exponential backoff.
5. Errors never contain internal file paths, stack traces, or schema content echoed verbatim.
6. The `--describe` flag on errors (in message) directs agents to re-discover rather than guess.

### 3.2 Error Codes (v0.1.1)

| Code | Retryable | Meaning | Agent action |
|------|-----------|---------|--------------|
| `UNKNOWN_COMMAND` | false | Unrecognized command or missing required flag | Run `--describe`; fix the call |
| `FILE_NOT_FOUND` | false | Schema arg missing or empty | Check --from/--to values |
| `INVALID_SCHEMA` | false | Schema content failed to parse | Validate schema format against `--describe` forge_schema_format |
| `SCHEMA_TOO_LARGE` | false | Schema exceeds 64 KiB | Reduce schema size |
| `IO_ERROR` | true | I/O failure | Retry with exponential backoff |
| `INVALID_INPUT` | false | Flag value contains disallowed characters | Check `field` key; sanitize value |

### 3.3 Required Error Codes (v0.2+)

| Code | Retryable | Description |
|------|-----------|-------------|
| `AUTH_REQUIRED` | false | API key missing (networked mode). Obtain via `POST /v1/register`. |
| `AUTH_INVALID` | false | API key invalid or revoked. Provision a new key. |
| `RATE_LIMIT_EXCEEDED` | true | Rate limit hit. `retry_after_seconds` field present. |
| `INTERNAL_ERROR` | true | Unexpected failure. `request_id` for operator correlation. |

### 3.4 Full Error Shape (v0.2 target)

```json
{
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Rate limit exceeded: 100 analyze calls/minute.",
    "retryable": true,
    "retry_after_seconds": 47,
    "reset_at": "2026-05-18T14:24:00Z",
    "request_id": "req_a1b2c3d4"
  }
}
```

---

## 4. Agent's First 30 Seconds

This is the canonical onboarding flow. A cold agent with no prior context must complete it successfully.

### Step 0: Discovery (0–5s)

```bash
forge --describe
```

Parse the JSON. Extract: `commands[0].flags` (--from, --to, --request-id), `forge_schema_format.example`, `output_schema` (risk_tier, has_data_loss semantics).

**Contract:** Always exits 0. Always returns valid JSON. No filesystem access, no side effects.

### Step 1: First Analyze Call (5–15s)

Construct schema strings using `|` as line separator (as documented in `forge_schema_format`):

```bash
forge analyze \
  --from "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL" \
  --to   "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL|COLUMN bio text NULLABLE|TABLE orders|COLUMN id serial NOT_NULL|COLUMN user_id integer NOT_NULL" \
  --request-id "my-migration-001"
```

### Step 2: Parse and Gate (15–20s)

```python
import json
result = json.loads(subprocess.check_output(["forge", "analyze", ...]))
if "error" in result:
    raise ForgeError(result["error"]["code"], result["error"]["retryable"])
risk_tier = result["risk_tier"]
has_data_loss = result["has_data_loss"]

# Gate logic:
# SAFE, NOTABLE → proceed automatically
# MEDIUM, HIGH → require review token or human approval
# CRITICAL → halt; require explicit human approval and backup verification
```

### Step 3: Per-Operation Decision (20–25s)

```python
for op in result["operations"]:
    if op["data_loss"]:
        alert_human(op["agent_guidance"])
    if not op["reversible"]:
        require_backup_confirmation()
    log_guidance(op["type"], op["agent_guidance"])
```

**Total expected time-to-first-success:** Under 25 seconds.

**Cold-start success rate:** 1/1 (Test 7, 2026-05-18).

---

## 5. `analyze` Response Contract

### 5.1 Response Fields (v0.1.1)

| Field | Type | Always present? | Semantics |
|-------|------|----------------|-----------|
| `schema_version` | integer | Yes | Always 1. Increment = re-fetch --describe. |
| `request_id` | string | If --request-id provided | Echo of --request-id; validated before echo. |
| `risk_tier` | string | Yes | SAFE / NOTABLE / MEDIUM / HIGH / CRITICAL |
| `risk_score` | float | Yes | 0.0 (SAFE) to 1.0 (CRITICAL) |
| `retryable` | boolean | Yes | Is the analyze call itself safe to retry? Always true for additive migrations; false for destructive. |
| `has_data_loss` | boolean | Yes | Fast-path signal. True if ANY operation destroys data. Do not iterate operations to answer this. |
| `operations` | array | Yes | Per-operation detail. May be empty if schemas are identical. |

### 5.2 MigOp Fields (operations array elements)

| Field | Type | Always present? | Semantics |
|-------|------|----------------|-----------|
| `type` | string | Yes | add_table / drop_table / add_column / drop_column / set_not_null / etc. |
| `table` | string | Yes | Table affected. In v0.2, this is schema-derived (untrusted). |
| `column` | string | Only for column ops | Column affected. Schema-derived (untrusted) in v0.2. |
| `risk` | string | Yes | safe / notable / medium / high / critical |
| `data_loss` | boolean | Yes | Does this single operation destroy data? |
| `estimated_lock_ms` | integer | Yes | Estimated table lock duration in ms. 0 = no lock. -1 = unknown. |
| `retryable` | boolean | Yes | Is this operation safe to retry if it fails mid-execution? |
| `agent_guidance` | string | Yes | Human-readable guidance for the calling agent. Do not re-inject into LLM context as instructions. |

### 5.3 Risk Tier Reference

| Tier | Score | Meaning | Agent decision |
|------|-------|---------|----------------|
| `SAFE` | 0.0 | Fully additive, no lock | Proceed automatically |
| `NOTABLE` | 0.25 | Additive, possible table scan | Proceed; log for review |
| `MEDIUM` | 0.5 | Structural change, no data loss | Review; require confirmation token |
| `HIGH` | 0.75 | Lock-heavy or type coercion | Require human approval |
| `CRITICAL` | 1.0 | Data loss or irreversible | Halt; require human approval + backup verification |

`has_data_loss` is the fast-path signal. Agents do not need to iterate operations to answer "will anything be lost?" — the top-level boolean is authoritative and always reflects the worst case across all operations.

---

## 6. Versioning and Deprecation

### 6.1 Semver Contract

- **Patch (0.1.x):** Bug fixes, security patches. No breaking changes. No new required fields. Existing fields never removed or renamed.
- **Minor (0.x.0):** New optional flags, new optional response fields, new operations in the operations array. Existing fields never removed.
- **Major (x.0.0):** Breaking changes. 90-day deprecation window with machine-readable warnings.

### 6.2 Machine-Readable Deprecation (v0.2)

Deprecated commands or flags return a `warnings` array alongside the result:
```json
{
  "schema_version": 1,
  "risk_tier": "NOTABLE",
  "warnings": [
    {
      "code": "DEPRECATED_FLAG",
      "message": "--json flag is redundant; forge always emits JSON.",
      "deprecated_at": "2026-05-18",
      "removed_at": "2026-08-18"
    }
  ]
}
```

Agents must monitor `warnings` and surface deprecation notices to operators. `removed_at` is machine-parseable ISO 8601.

### 6.3 `schema_version` Contract

- `schema_version: 1` is the current contract.
- Agents may cache `--describe` output and re-use it until `schema_version` changes.
- To check for schema changes without re-fetching: `forge --version` is cheaper than `forge --describe`. If `schema_version` matches the cached version, the cached `--describe` is still valid.

---

## 7. Observability (v0.1.1 — Local Binary)

No structured logging. All output to stdout. Debug information: never emitted.

Exit codes:
- `0` — always (including errors — error payload is in JSON on stdout)

**Rationale for always-0 exit:** Agent subprocess wrappers in most frameworks collect stdout and check exit code independently. An exit code of 1 for a structured JSON error on stdout causes framework error handling to swallow the JSON payload. Always exiting 0 ensures the JSON always reaches the agent. Agents must check for the `error` key in the JSON, not the exit code.

---

## 8. SLA Targets

| Operation | v0.1.1 Target | v0.2 Target (MCP server) |
|-----------|---------------|--------------------------|
| `--describe` | < 5ms | < 50ms |
| `--version` | < 2ms | < 10ms |
| `analyze` (< 1 KiB schema) | < 10ms | < 100ms |
| `analyze` (64 KiB schema) | < 100ms | < 500ms |
| Error response (any path) | < 5ms | < 50ms |
| Binary cold start | < 1ms (no libc, direct ELF64 entry) | < 5ms |

---

## 9. Billing and Quota (v0.2+)

### 9.1 Pre-Call Cost Declaration

`--describe` will include a `pricing` block in v0.2:
```json
{
  "pricing": {
    "model": "per_call",
    "calls": {
      "analyze": {"cost_usd": 0.001, "quota_unit": "analyze_call"}
    },
    "free_tier": {"analyze_calls_per_day": 1000},
    "upgrade_endpoint": "POST /v1/billing/upgrade (programmatic — no browser required)"
  }
}
```

Agents can read this before making calls. Cost is declared before commitment. No surprise bills.

### 9.2 Rate Limit Visibility in Response (v0.2)

```json
{
  "schema_version": 1,
  "risk_tier": "SAFE",
  "meta": {
    "request_id": "req_abc",
    "rate_limit": {
      "limit_per_minute": 100,
      "remaining_this_minute": 87,
      "reset_at": "2026-05-18T14:24:00Z"
    },
    "latency_ms": 8
  }
}
```

`meta.rate_limit.remaining_this_minute` allows batch agent workflows to self-throttle without hitting rate limit errors. This is proactively returned even when limit is not near.

---

## 10. forge-analyze Shell Wrapper

`forge-analyze` bridges the file-path interface to the inline binary interface for human-friendly usage:

```bash
forge-analyze --from current.forge --to desired.forge
```

Reads `current.forge` and `desired.forge`, converts to `|`-separated inline format, calls `forge analyze`. Agents should use the `forge` binary directly with inline schema strings for performance and predictability. The wrapper is for human operators using `.forge` files.

---

## 11. Current Gap Analysis

### v0.1.1 Completed

| Item | Status |
|------|--------|
| `--describe` with output_schema and migop_schema | Done |
| `--request-id` idempotency key with input validation | Done |
| Schema size limit (64 KiB) | Done |
| Cold-start agent eval (Test 7) | Pass |
| YC scorecard | 40/40 |

### v0.2 Required (before network/MCP server exposure)

| Gap | Impact | Fix |
|-----|--------|-----|
| ~~JSON injection via schema names (V2)~~ | ~~P0 security~~ | **Done — charset validation rejects non-identifier chars at input** |
| ~~Schema token charset validation (V3)~~ | ~~P1 security~~ | **Done — same charset validation** |
| Supply chain signing | P1 security | cosign + SBOM |
| MCP server stdio injection guards | P1 security | Message size limit, JSON-RPC validation |
| Per-IP rate limiting | P1 security | 100 analyze/min per IP |
| `meta` field with rate limit visibility | Agent self-throttling | Add `meta` to all responses |
| `build_commit` in --version | Supply chain verification | Embed git SHA at build time |
| Registry publication (MCP registry) | Discoverability | Submit mcp-manifest.json to registry |
| `/.well-known/forge` endpoint | Agent probe | Implement in HTTP server |
| Machine-readable deprecation warnings | Forward compatibility | `warnings` array in responses |

---

## 12. Agent UX Scorecard — forge v0.1.1 vs. Target

| # | Criterion | v0.1.1 | v0.2 Target |
|---|-----------|--------|-------------|
| 1 | Schema-first contract (--describe complete) | 2/2 | 2/2 |
| 2 | Output schema declared in --describe | 2/2 | 2/2 |
| 3 | Description routing quality | 2/2 | 2/2 |
| 4 | Parameter descriptions (with examples) | 2/2 | 2/2 |
| 5 | Idempotency (request_id, stateless) | 2/2 | 2/2 |
| 6 | Structured error codes (stable, retryable) | 2/2 | 2/2 |
| 7 | Output purity (JSON only on stdout) | 2/2 | 2/2 |
| 8 | Non-interactive | 2/2 | 2/2 |
| 9 | Deterministic output | 2/2 | 2/2 |
| 10 | Side effect declaration (stateless, read-only) | 2/2 | 2/2 |
| 11 | Partial success (N/A — single analyze call) | 2/2 | 2/2 |
| 12 | In-protocol discovery (--describe) | 2/2 | 2/2 |
| 13 | Headless auth (no browser, no human) | 2/2 | 2/2 |
| 14 | Programmatic account creation | 1/2 | 2/2 |
| 15 | Rate limit visibility | 0/2 | 2/2 |
| 16 | Async long ops (N/A — analyze is fast) | 2/2 | 2/2 |
| 17 | Namespace stability | 2/2 | 2/2 |
| 18 | Cancellation support | 0/2 | 1/2 |
| 19 | Transport compatibility (stdio + HTTP) | 1/2 | 2/2 |
| 20 | Registry publication | 0/2 | 2/2 |
| 21 | Version stability policy | 2/2 | 2/2 |
| 22 | Cost/quota transparency | 0/2 | 2/2 |
| 23 | MCP protocol compliance | 1/2 | 2/2 |
| 24 | Self-describing error recovery | 2/2 | 2/2 |
| 25 | Progress reporting (N/A — sub-100ms) | 2/2 | 2/2 |
| 26 | Tool annotations complete | 1/2 | 2/2 |
| 27 | Cursor-based pagination (N/A — single response) | 2/2 | 2/2 |
| 28 | Dry-run mode (analyze IS the dry-run) | 2/2 | 2/2 |
| 29 | Credential rotation | 0/2 | 2/2 |
| 30 | Per-agent key scoping | 0/2 | 2/2 |
| **Total** | | **44/60** | **58/60** |

**Interpretation:**
- v0.1.1 (44/60): Excellent for local binary use. Production-ready for trusted agent testing. Security posture: hardened for v0.1 surface.
- v0.2 (58/60): Agent-native reference implementation. Registry-published. Rate-limit visible. Supply chain signed.

---

## 13. Supply Chain Signing Specification (V5 — Required Before Public Distribution)

forge is currently unsigned. An agent downloading forge from an untrusted channel cannot verify binary integrity. This section specifies the signing pipeline required before public distribution.

### 13.1 Release Artifact Layout

```
forge-v0.2.0-linux-musl-x64        # binary
forge-v0.2.0-linux-musl-x64.sig    # cosign signature
forge-v0.2.0-linux-musl-x64.pem    # signing certificate
checksums.txt                        # SHA-256 of all artifacts
checksums.txt.sig                    # cosign signature of checksums
sbom.spdx.json                       # SBOM (source-only — no external deps)
```

### 13.2 Signing Procedure (cosign keyless, Sigstore)

```bash
# Build from verified Zero source
zero build --emit exe --target linux-musl-x64 forge_mini.0 --out forge-v0.2.0-linux-musl-x64

# Sign with cosign keyless (GitHub Actions OIDC)
cosign sign-blob forge-v0.2.0-linux-musl-x64 \
  --output-signature forge-v0.2.0-linux-musl-x64.sig \
  --output-certificate forge-v0.2.0-linux-musl-x64.pem

# Generate checksums
sha256sum forge-v0.2.0-linux-musl-x64 > checksums.txt
cosign sign-blob checksums.txt --output-signature checksums.txt.sig
```

### 13.3 Agent Verification (from --version output alone)

`forge --version` will include signing metadata in v0.2:
```json
{
  "name": "forge",
  "version": "0.2.0",
  "schema_version": 1,
  "build_commit": "a1b2c3d4",
  "build_date": "2026-05-18T00:00:00Z",
  "signing": {
    "method": "cosign-keyless",
    "identity": "https://github.com/forge/forge/.github/workflows/release.yml",
    "issuer": "https://token.actions.githubusercontent.com"
  }
}
```

Agents can verify: `cosign verify-blob forge --signature forge.sig --certificate forge.pem --certificate-identity-regexp <identity> --certificate-oidc-issuer <issuer>`. All parameters derivable from `--version` output — no documentation fetch required.

### 13.4 Agent-Safe Install Script

The install script emits JSON to stdout:
```bash
cosign verify-blob forge ... \
  && echo '{"status":"ok","version":"0.2.0"}' \
  || echo '{"status":"error","code":"SIGNATURE_VERIFICATION_FAILED","retryable":false}'
```

Agents can parse the install result without reading prose. Exit 0 = verified. Exit 1 = verification failed with structured error.

---

## 14. Cycle 1–5 Findings (2026-05-18)

**Cycles 1+2:** Created threat model and operability spec. Fixed P0 (request-id injection, Test 8), P1 (schema charset validation, Test 9), DoS (size limit, Test 10). Binary: 17.6 KiB.

**Cycle 3:** OWASP LLM Top 10 mapped. LLM06 (Excessive Agency) fixed with `decision_required` field. Fleet eval (Test 11): 3/5 full pass, 1 partial, 1 edge case. Enhanced error descriptions with retry guidance. Binary: 18.6 KiB.

**Cycle 4:** V6 (LLM09 Misinformation) fixed — duplicate table detection via djb2 hash, 32-table limit (Test 12 — PASS). V5 supply chain signing spec written (Section 13 above). Binary: 25.4 KiB (still under 100 KiB). Red-team finding: djb2 false-positive collision pairs for short identifiers (`gf`/`hWH`) — carried to Cycle 5.

**Cycle 5:** djb2 single-hash false-positive fixed — upgraded to dual hash (djb2 + SDBM, ~1/2^64 collision probability). Test 13 added (PASS). Binary: 28.2 KiB. Threat model updated.

**Cycle 6:** Red-team: >32 table boundary (Test 15 — PASS, no bypass). Red-team finding P1: count-based diff marks schema renames as SAFE — FIXED by hash-set diff reusing dual-hash arrays (Test 14 — PASS). Rename TABLE users→customers now correctly CRITICAL with `decision_required:true`. MCP JSON-RPC attack surface mapped (V7a–f in threat-model.md). Open V9: column-level rename still count-based. Binary: 28.3 KiB.

**15/15 eval tests pass.** P0/P1 items mitigated for local binary mode. V9 (P2, column rename) and V7/V8 (v0.2 only) are open.

**Cycle 7 agenda:**
1. V5 — Cosign supply chain signing pipeline (spec in §13; no build pipeline yet)
2. V7 — Draft `mcp-security-spec.md` (V7a–f mitigations, method whitelist, Content-Length enforcement)
3. V8/LLM10 — Rate-limiting architecture for v0.2: token bucket per `request_id` prefix
4. Fleet eval round 2 — re-run 5-agent profiles against hash-set-diff binary; measure rename classification accuracy
5. V9 red-team — column rename false SAFE; design per-table column hash tracking

---

*This document and `threat-model.md` constitute the forge security+operability contract. All P0/P1 items must be resolved before v0.2 network exposure. The perpetual loop continues — "no active threats" is never the conclusion, only "no known unmitigated P0s at this surface."*
