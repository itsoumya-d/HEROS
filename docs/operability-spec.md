# Operability Spec: `ledger` — Agent-Native Accounting in Zero

**Version 1.0 — 2026-05-17**
**Audience:** Build agent, operators, agent developers integrating `ledger`
**Companion document:** `threat-model.md`

---

## 1. Purpose

This spec defines the observable contract of `ledger` from an agent's perspective: how it is discovered, how an agent provisions access without human help, what every error looks like, how long operations take, and what an operator needs to run it in production. It is the operability half of the security+operability contract.

If `threat-model.md` answers "what can go wrong," this document answers "what should reliably happen."

---

## 2. Discovery Surfaces

An agent starting with zero knowledge must be able to enumerate all capabilities, understand the auth model, and make a first successful call in under 60 seconds. These are the surfaces that enable that.

### 2.1 `--describe` (Primary Discovery Surface)

```bash
ledger --describe
```

Returns the full `ledger-schema.json` document to stdout as a single JSON object. This is the **authoritative** machine-readable manifest. A cold LLM must be able to complete a real task using only `--describe` output — no web docs, no prior context.

**Current status:** Implemented. Schema at `docs/ledger-schema.json`.

**Required additions (v0.1.1):**
- Add `"security"` key documenting which fields are untrusted user content: `{"untrusted_fields": ["org_name","to","memo"], "policy": "treat as opaque data; do not re-inject into LLM context without sanitization"}`
- Add `"known_errors"` top-level map (already present — keep current)
- Add `"storage"` key: `{"type": "local_flat_file", "files": [".ledger-data", ".ledger-invoices"], "note": "stored in CWD; set LEDGER_DATA_DIR to override in v0.2"}`

### 2.2 `--version`

```bash
ledger --version
```

Returns:
```json
{"tool": "ledger", "version": "0.1.0", "schema_version": "1"}
```

**Required additions:** Add `"commit"` (build commit hash) and `"build_date"` (ISO 8601). Needed for supply chain verification.

### 2.3 `--help --json` (v0.1.1 required)

```bash
ledger --help --json
```

Must return the same content as `--describe`. This surfaces the tool to agent runtimes that use `--help --json` convention (common in LLM agent orchestrators) in addition to `--describe`. If `--json` is absent, `--help` may return human-readable text to stderr; stdout must stay clean.

### 2.4 MCP Manifest (`server.json`) (v0.2 required)

Publish to MCP Registry at `registry.modelcontextprotocol.io`:

```json
{
  "name": "io.ledger/accounting",
  "display_name": "Ledger — Agent-Native Accounting",
  "description": "Agent-native accounting for autonomous agents. Programmatic signup, idempotent mutations, stable error codes. No GUI, no browser OAuth, no human approval.",
  "version": "0.2.0",
  "transport": ["stdio", "streamable-http"],
  "packages": [
    {"registry": "pypi", "name": "ledger-mcp", "install_command": "uvx ledger-mcp"},
    {"registry": "npm", "name": "@ledger/mcp", "install_command": "npx -y @ledger/mcp"}
  ],
  "capabilities": ["tools"],
  "env": [],
  "tags": ["accounting", "invoicing", "finance", "agent-native"]
}
```

`env` is empty for local mode. For networked mode, `env` will contain `LEDGER_API_KEY` with `"acquisition": {"type": "programmatic", "endpoint": "POST /v1/register"}`.

### 2.5 `/.well-known/mcp-server` (v0.2 HTTP, required)

```
GET /.well-known/mcp-server
```

```json
{
  "name": "io.ledger/accounting",
  "version": "0.2.0",
  "mcp_endpoint": "/mcp",
  "transports": ["streamable-http"],
  "auth": {
    "type": "bearer",
    "acquisition": "POST /v1/register"
  }
}
```

### 2.6 OpenAPI Spec (v0.2 HTTP, required)

```
GET /openapi.json
```

Full OpenAPI 3.1 spec with all endpoints, request schemas, response schemas, and error shapes. Must be machine-parseable without any HTML rendering.

---

## 3. Error Contract

### 3.1 Principles

1. Every error is a JSON object on stdout, exit code non-zero.
2. `error_code` is a **stable string** — never changes meaning across versions. It is the machine-parseable field.
3. `error` is a human-readable message — may change across versions.
4. Transient errors include `"retry": true` and, when applicable, `"retry_after_seconds": N`.
5. Errors never contain internal file paths, stack traces, or data from other orgs.
6. Unknown/unexpected errors return `INTERNAL_ERROR` with a `"request_id"` for operator correlation; no internal details.

### 3.2 Current Error Codes (v0.1.0)

| Code | Retry | Description |
|------|-------|-------------|
| `UNKNOWN_COMMAND` | false | Command not recognized. Run `ledger --describe` |
| `MISSING_FLAG` | false | Required flag absent. `flag` field names it. |
| `NO_ORG_REGISTERED` | false | Run `ledger register --org-name <name>` first |
| `ORG_EXISTS` | false | Org already registered. `org_id` field present. |
| `STORE_WRITE_FAILED` | true | Disk write failed. Check space and permissions. |
| `STORE_READ_FAILED` | true | Disk read failed. |

### 3.3 Required Error Codes (v0.1.1)

| Code | Retry | Description |
|------|-------|-------------|
| `INVALID_INPUT` | false | Input contains disallowed characters (null bytes, control chars). `field` and `reason` fields present. |
| `INTERNAL_ERROR` | true | Unexpected failure. `request_id` for operator correlation. |

### 3.4 Required Error Codes (v0.2+, networked)

| Code | Retry | Description |
|------|-------|-------------|
| `AUTH_REQUIRED` | false | No API key provided. Obtain via `POST /v1/register`. |
| `AUTH_INVALID` | false | API key invalid or revoked. Provision a new key. |
| `RATE_LIMIT_EXCEEDED` | true | Rate limit hit. `retry_after_seconds` and `reset_at` present. |
| `QUOTA_EXCEEDED` | false | Org storage quota exhausted. `limit` and `usage` fields. |
| `IDEMPOTENCY_KEY_CONFLICT` | false | Same key used for different command. `original_command` field. |
| `STORE_INTEGRITY_FAILED` | false | Data store HMAC verification failed. Do not trust stored data. |

### 3.5 Full Error Shape (v0.2 target)

```json
{
  "error_code": "RATE_LIMIT_EXCEEDED",
  "error": "Rate limit exceeded: 1000 calls/hour for this API key.",
  "category": "transient",
  "retry": true,
  "retry_after_seconds": 847,
  "reset_at": "2026-05-17T17:00:00Z",
  "limit": 1000,
  "window_seconds": 3600,
  "remaining": 0,
  "request_id": "req_a1b2c3d4"
}
```

### 3.6 Partial Success Shape (v0.2 batch operations)

```json
{
  "results": [
    {"item_ref": "inv_001", "status": "ok", "invoice_id": "inv_a1b2"},
    {"item_ref": "inv_002", "status": "error", "error_code": "MISSING_FLAG", "flag": "--amount"}
  ],
  "summary": {"total": 2, "ok": 1, "failed": 1},
  "meta": {"request_id": "req_xyz", "latency_ms": 42}
}
```

---

## 4. Agent's First 60 Seconds

This is the canonical onboarding flow. A cold agent with no prior context must complete it successfully.

### Step 0: Discovery (0–5s)

```bash
ledger --describe
```

Parse the JSON schema. Extract: available commands, required flags for each, error codes, idempotency behavior, data file locations.

**Contract:** Always exits 0, always returns valid JSON, always works even with no org registered.

### Step 1: Register (5–10s)

```bash
ledger register --org-name "agent-$(uuidgen | head -c 8)"
```

Returns `{"org_id": "org_XXXXXXXX", "org_name": "...", "created_at": ..., "status": "ok"}`.

Save `org_id`. All subsequent commands will need it (v0.2: pass as `--org-id` or `LEDGER_ORG_ID`).

**Idempotency:** Running register again with same org_name returns `{"error_code": "ORG_EXISTS", "status": "ok"}`. This is not a failure — the org_id is in `.ledger-data`. Agents should handle this by reading `.ledger-data` to recover the org_id.

**Gap in v0.1.0 (to fix):** The `ORG_EXISTS` response should echo back the existing `org_id` so the agent does not need to parse the data file. Fix: read and return existing org record on `ORG_EXISTS`.

### Step 2: Create Invoice (10–20s)

```bash
ledger invoice create \
  --to "Vendor Inc" \
  --amount 50000 \
  --currency USD \
  --memo "Services Q1 2026" \
  --idempotency-key "$(uuidgen)"
```

Returns structured invoice with `invoice_id`. Save idempotency key — if network/process fails and agent retries with same key, it gets the same invoice back.

### Step 3: Verify (20–25s)

```bash
ledger invoice list
```

Returns JSONL (one invoice per line). Parse each line as independent JSON. Verify the created invoice appears with correct fields.

### Step 4: Schema Re-Verification (optional, 25–30s)

```bash
ledger --version
```

Confirm binary version matches expected. In v0.2, compare against registry manifest.

**Total expected time-to-first-success:** Under 30 seconds for all steps.

---

## 5. Response Metadata (v0.2 required)

Every successful response must include a `meta` field:

```json
{
  "result": { ... },
  "meta": {
    "request_id": "req_a1b2c3d4",
    "latency_ms": 12,
    "rate_limit": {
      "limit_per_hour": 1000,
      "remaining_this_hour": 847,
      "reset_at": "2026-05-17T17:00:00Z"
    },
    "version": "0.2.0"
  }
}
```

`meta` is present on all non-error responses. Rate limit fields are proactive — returned even when limit is not exceeded. This is the signal batch workflows use to self-throttle without hitting rate limit errors.

**v0.1 gap:** No `meta` field, no rate limit visibility (0/2 on Agent UX scorecard). This is the most impactful missing feature for agent workflows.

---

## 6. Versioning and Deprecation

### 6.1 Semver Contract

- **Patch (0.1.x):** Bug fixes, security patches. Zero breaking changes.
- **Minor (0.x.0):** New commands, new optional flags, new optional response fields. Existing fields never removed or renamed.
- **Major (x.0.0):** Breaking changes. 90-day deprecation window with machine-readable deprecation headers.

### 6.2 Machine-Readable Deprecation (v0.2)

Deprecated commands return a `warnings` array in the response:

```json
{
  "result": { ... },
  "warnings": [
    {
      "code": "DEPRECATED_COMMAND",
      "message": "invoice list is deprecated. Use invoice list-v2 after 2026-08-17.",
      "deprecated_at": "2026-05-17",
      "removed_at": "2026-08-17",
      "migration": "ledger invoice list-v2 --cursor <cursor>"
    }
  ]
}
```

Agents must monitor `warnings` and surface deprecation notices to operators. The `removed_at` date is machine-parseable ISO 8601.

### 6.3 `--version` Schema Version

`schema_version` in `--version` output increments on any change to `--describe` output structure. Agents can cache the schema and invalidate the cache when `schema_version` changes.

---

## 7. Observability

### 7.1 v0.1 (Current — local)

No structured logging. Debug information goes to stderr only, never stdout. Exit codes:
- `0` — success
- `1` — user error (MISSING_FLAG, NO_ORG_REGISTERED, UNKNOWN_COMMAND)
- `2` — system error (STORE_WRITE_FAILED, STORE_READ_FAILED)
- `3` — internal error

**Gap:** Exit codes are not yet documented in schema or --describe. Add to v0.1.1.

### 7.2 v0.2 (Required)

**Structured audit log** (append-only JSONL, `~/.local/share/ledger/audit.jsonl` or configured path):

```jsonl
{"ts":"2026-05-17T14:23:11Z","request_id":"req_abc","command":"invoice.create","org_id":"org_1234","outcome":"ok","latency_ms":8,"idempotent_hit":false}
{"ts":"2026-05-17T14:23:12Z","request_id":"req_def","command":"invoice.list","org_id":"org_1234","outcome":"ok","latency_ms":3,"record_count":47}
```

Fields: `ts`, `request_id`, `command`, `org_id` (masked if anonymous), `outcome` (`ok`/`error`), `error_code` (if error), `latency_ms`. No financial amounts or PII in audit log.

**Health endpoint** (v0.2 HTTP):
```
GET /healthz
→ {"status": "ok", "version": "0.2.0", "uptime_seconds": 3847}

GET /readyz
→ {"status": "ok", "storage": "ok", "auth": "ok"}
```

**Metrics** (v0.2, Prometheus-compatible):
```
GET /metrics
→ ledger_requests_total{command="invoice.create",outcome="ok"} 4821
→ ledger_requests_total{command="invoice.create",outcome="error",error_code="RATE_LIMIT_EXCEEDED"} 3
→ ledger_latency_p99_ms{command="invoice.list"} 12
→ ledger_storage_records_total{org_id="..."} 847
```

---

## 8. SLA Targets

| Operation | v0.1 Target | v0.2 Target (networked) |
|-----------|-------------|------------------------|
| `--describe` | < 10ms | < 50ms (cached) |
| `register` | < 50ms | < 200ms |
| `invoice create` | < 50ms | < 300ms |
| `invoice list` (< 1000 records) | < 100ms | < 500ms |
| `invoice list` (< 10,000 records) | < 500ms | < 2000ms |
| `invoice count` | < 20ms | < 50ms |
| Idempotent re-call (same key) | < 20ms | < 100ms |
| Error response | < 10ms | < 50ms |

Operations exceeding 5 seconds must return a job ID and expose a poll endpoint (Principle 13 from agent-ux-principles.md).

**Uptime target (v0.2):** 99.9% monthly (< 44 minutes downtime/month), measured per org, not globally.

---

## 9. Billing and Quota (v0.2)

### 9.1 Tiers

| Tier | Price | Quota |
|------|-------|-------|
| Free | $0 | 1,000 invoices/month, 100 API calls/hour |
| Pro | $19/month | 100,000 invoices/month, 1,000 API calls/hour |
| Enterprise | Custom | Unlimited, SLA, dedicated support |

### 9.2 Cost Per Call (pre-call declaration)

`ledger --describe` includes a `pricing` field:

```json
{
  "pricing": {
    "model": "per_call",
    "calls": {
      "invoice.create": {"cost_usd": 0.0, "quota_unit": "invoice"},
      "invoice.list": {"cost_usd": 0.0, "quota_unit": "api_call"},
      "register": {"cost_usd": 0.0, "quota_unit": "none"}
    },
    "free_tier": {"invoices_per_month": 1000, "api_calls_per_hour": 100},
    "upgrade_url": "POST /v1/billing/upgrade (programmatic — no browser required)"
  }
}
```

### 9.3 Quota Exceeded Flow

```json
{
  "error_code": "QUOTA_EXCEEDED",
  "error": "Monthly invoice limit reached (1000/1000).",
  "retry": false,
  "quota_type": "invoices_per_month",
  "limit": 1000,
  "used": 1000,
  "reset_at": "2026-06-01T00:00:00Z",
  "upgrade_instructions": {
    "endpoint": "POST /v1/billing/upgrade",
    "payload": {"tier": "pro"},
    "auth": "Bearer <api_key>",
    "no_browser_required": true
  }
}
```

Agents can complete a tier upgrade without human intervention.

### 9.4 Refund/Dispute (v0.2)

```
POST /v1/billing/dispute
{"request_id": "req_abc", "reason": "DUPLICATE_CHARGE"}
→ {"dispute_id": "dis_xyz", "status": "under_review", "expected_resolution_hours": 48}

GET /v1/billing/dispute/{dispute_id}
→ {"status": "resolved", "resolution": "refunded", "amount_usd": 19.00}
```

---

## 10. Auth and Key Management (v0.2)

### 10.1 Programmatic Key Provisioning

```bash
# Step 1: Register (already done → org_id known)
# Step 2: Create API key
curl -X POST /v1/keys \
  -H "X-Org-Id: org_1234" \
  -d '{"name":"agent-v1","scopes":["invoice:read","invoice:write"]}'
→ {"api_key":"sk_live_...","key_id":"key_abc","scopes":["invoice:read","invoice:write"],"created_at":"..."}
```

### 10.2 Key Scopes

| Scope | Operations |
|-------|-----------|
| `invoice:read` | invoice list |
| `invoice:write` | invoice create |
| `org:read` | register (read existing) |
| `billing:read` | quota status |
| `billing:write` | upgrade, dispute |
| `*` | All (not recommended for agent keys) |

### 10.3 Zero-Downtime Key Rotation

1. Create new key: `POST /v1/keys` → `key_new`
2. Update agent to use `key_new`
3. Verify `key_new` works: any read operation
4. Revoke old key: `DELETE /v1/keys/{key_old}`

Both keys are valid during the transition window. No downtime.

### 10.4 Key Compromise Response

```
DELETE /v1/keys/{key_id}?reason=COMPROMISED
→ {"status": "revoked", "effective_at": "<now>", "outstanding_requests_cancelled": true}
```

Revocation is immediate. All in-flight requests using the revoked key return `AUTH_INVALID` within one request cycle (< 100ms propagation).

---

## 11. Operator Runbook (v0.2)

### 11.1 Deployment

```bash
# Verify binary integrity before deployment
cosign verify-blob ledger-linux-musl-x64 \
  --signature ledger.sig \
  --certificate ledger.pem \
  --certificate-identity "https://github.com/ledger/ledger/.github/workflows/release.yml" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"

# Start MCP HTTP server
LEDGER_DATA_DIR=/var/lib/ledger \
LEDGER_AUDIT_LOG=/var/log/ledger/audit.jsonl \
LEDGER_PORT=8080 \
./ledger-linux-musl-x64 server
```

### 11.2 Health Checks

```bash
# Liveness (process alive)
curl -f http://localhost:8080/healthz

# Readiness (storage + auth reachable)
curl -f http://localhost:8080/readyz
```

Orchestrator should use `/readyz` for traffic routing decisions.

### 11.3 Graceful Shutdown

On `SIGTERM`, `ledger` server:
1. Stops accepting new connections (< 1s)
2. Drains in-flight requests (up to 30s)
3. Flushes audit log buffer
4. Exits 0

In-flight mutations that were committed before shutdown are persisted. In-flight mutations not yet committed return `INTERNAL_ERROR` with `retry: true`.

### 11.4 Backup and Recovery

```bash
# Backup data store (consistent snapshot)
ledger admin backup --output /backup/ledger-$(date +%Y%m%d).tar.gz

# Verify backup integrity
ledger admin verify-backup /backup/ledger-20260517.tar.gz
→ {"status": "ok", "records": 4821, "integrity": "verified"}

# Restore
ledger admin restore /backup/ledger-20260517.tar.gz --data-dir /var/lib/ledger
```

### 11.5 Storage Quota Monitoring

```bash
ledger admin quota-status --all-orgs
→ [{"org_id":"org_1234","invoices_used":847,"invoices_limit":1000,"pct":84.7}, ...]
```

Alert when any org exceeds 80% quota.

### 11.6 Anomaly Detection Alerts

| Condition | Alert |
|-----------|-------|
| Org creates > 100 invoices/minute | Hold + operator review |
| Single IP registers > 10 orgs/hour | IP rate limit + alert |
| `STORE_INTEGRITY_FAILED` on any read | P0 — possible tampering |
| Error rate for any org > 50% over 5m | Alert — possible attack or client bug |

---

## 12. Current Gap Analysis (v0.1.0 → v0.1.1 → v0.2)

### v0.1.1 Status

| Gap | Impact | Status |
|-----|--------|--------|
| JSON injection (V1 in threat model) | **P0 security** | **FIXED 2026-05-18** |
| Function naming bug (doRegister/doInvoice) | Compilation failure | **FIXED 2026-05-18** |
| `ORG_EXISTS` doesn't return existing org_id | Agent can't recover org_id after restart | Open |
| `--help --json` not implemented | Misses agent runtimes using this convention | Open |
| Exit codes undocumented in schema | Agents can't classify errors by exit code | Open |
| Input length limits on user strings | Context flooding, idempotency bypass | Open (RT-05) |

### v0.2 Required (before network exposure)

| Gap | Impact | Fix |
|-----|--------|-----|
| No `meta` / rate limit fields in responses | Agents can't self-throttle (0/2 scorecard) | Add `meta` to all responses |
| No structured audit log | No operator forensics | Append-only JSONL audit log |
| No supply chain signing | P1 security | cosign + SBOM |
| `LEDGER_DATA_DIR` env var not supported | CWD-dependent writes | Implement env var for data dir |
| `balance` command missing (in quickstart schema but unimplemented) | Agent follows quickstart, fails | Implement or remove from schema |
| No `--dry-run` flag on mutations | Agents can't preview effects | Add `--dry-run` to invoice create |

---

## 13. Agent UX Scorecard — Current vs. Target

| # | Criterion | v0.1.0 | v0.1.1 | v0.2 |
|---|-----------|--------|--------|------|
| 1 | Schema-first contract | 2 | 2 | 2 |
| 2 | Output schema declared | 1 | 1 | 2 |
| 3 | Description routing quality | 2 | 2 | 2 |
| 4 | Parameter descriptions | 2 | 2 | 2 |
| 5 | Idempotency | 2 | 2 | 2 |
| 6 | Structured error codes | 2 | 2 | 2 |
| 7 | Output purity (JSON only on stdout) | 2 | 2 | 2 |
| 8 | Non-interactive | 2 | 2 | 2 |
| 9 | Deterministic output | 2 | 2 | 2 |
| 10 | Side effect declaration | 2 | 2 | 2 |
| 11 | Partial success | 1 | 1 | 2 |
| 12 | In-protocol discovery | 2 | 2 | 2 |
| 13 | Headless auth | 2 | 2 | 2 |
| 14 | Programmatic account creation | 2 | 2 | 2 |
| 15 | Rate limit visibility | **0** | 0 | 2 |
| 16 | Async long ops | 1 | 1 | 2 |
| 17 | Namespace stability | 2 | 2 | 2 |
| 18 | Cancellation support | 0 | 0 | 1 |
| 19 | Transport compatibility (stdio+HTTP) | 1 | 1 | 2 |
| 20 | Registry publication | 0 | 0 | 2 |
| 21 | Version stability policy | 1 | 2 | 2 |
| 22 | Cost/quota transparency | 0 | 0 | 2 |
| 23 | MCP protocol compliance | 0 | 0 | 2 |
| 24 | Self-describing error recovery | 1 | 2 | 2 |
| 25 | Progress reporting | 0 | 0 | 1 |
| 26 | Tool annotations complete | 0 | 0 | 2 |
| 27 | Cursor-based pagination | 0 | 0 | 2 |
| 28 | Dry-run mode | 0 | 1 | 2 |
| 29 | Credential rotation | 0 | 0 | 2 |
| 30 | Per-agent key scoping | 0 | 0 | 2 |
| **Total** | | **34/60** | **37/60 (3 open gaps)** | **58/60** |

**Interpretation:**
- v0.1.0 (34/60): Functional for controlled agent use. Production risk on edge cases.
- v0.1.1 (37/60): Securely functional. Ready for trusted agent testing.
- v0.2 (58/60): Agent-native. Reference implementation quality.

---

*This document and `threat-model.md` together constitute the Phase 1 security + operability contract. The build agent must resolve all v0.1.1 gaps before adding new features. The v0.2 gaps must be resolved before any networked deployment.*
