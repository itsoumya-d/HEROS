# ledger - Agent Accounting Receipts for Autonomous Agents

Built in Zero lang. JSON-only output. No interactive prompts. Idempotent operations. Designed for the era of autonomous agents.

---

## Quick Start for Agents

```bash
# 1. Discover everything ledger can do (cold-start)
ledger --describe
```

For stateful accounting operations, use the MCP bridge tools. The bridge owns disk state, idempotency lookup, entropy/timestamp injection, listing, and counting.

```json
{"tool":"ledger_register","arguments":{"org_name":"MyOrg"}}
{"tool":"ledger_invoice_create","arguments":{"to":"Vendor Inc","amount":1000.00,"currency":"USD","idempotency_key":"uuid-v4-here"}}
{"tool":"ledger_invoice_list","arguments":{"limit":100,"offset":0}}
```

---

## What is ledger?

Ledger is an agent accounting receipt primitive built from the ground up for autonomous agents. Current v0.1 scope is intentionally small: one registered org, idempotent invoice creation, invoice list/count, bridge-owned local state, rate limits, and machine-readable errors. Unlike traditional accounting software that requires human dashboards and approval workflows, ledger:

- Emits JSON on every code path (including errors)
- Returns stable error codes agents can branch on without text parsing
- Supports idempotency keys on write operations - duplicate calls return the same result
- Is single-tenant by design - one org per deployment, no multi-tenant cross-contamination
- Exits 0 even on errors (errors are in the JSON payload, not on stderr)

The design principle: an agent should be able to run `ledger_register` on every cold start without fear of creating duplicate orgs, and create invoices with idempotency keys knowing that network retries are safe.

**Production-ledger boundary:** ledger v0.1 is not yet a full double-entry financial ledger. It does not yet model accounts, postings/transfers, balances, reconciliation, or production storage backends. Those are v0.2+ roadmap items that must ship with invariant tests before HEROS claims parity with mature ledger platforms.

---

## MCP Integration

Ledger ships an MCP manifest (`mcp-manifest.json`) and a bash bridge (`mcp-bridge.sh`) for use as a tool by any MCP-compatible orchestrator.

**Why a bridge?** Zero v0.1.x has no stdin reading API. `mcp-bridge.sh` owns the JSON-RPC 2.0 session lifecycle (initialize, tools/list, tools/call, ping) and delegates tool calls to the `ledger` binary as a subprocess. The bridge implements rate limiting, `STORE_READ_FAILED` detection, and security hardening.

**Requirements:** `bash >= 4.0`, `jq >= 1.6`, `ledger` binary in PATH or same directory as `mcp-bridge.sh`.

**Add to an MCP client:**
```json
{
  "mcpServers": {
    "ledger": {
      "command": "/path/to/ledger/mcp-bridge.sh",
      "args": [],
      "transport": "stdio"
    }
  }
}
```

**State model (important for agents):**
- `ledger` is single-tenant: one org per deployment. Call `ledger_register` once at agent startup.
- All invoice tools operate on the registered org implicitly - there is no `org_id` parameter.
- State is stored on disk in the bridge process's working directory (`.ledger-data`, `.ledger-invoices`).
- Two bridge processes sharing the same working directory share the same org and invoice store.

**Agent startup sequence:**
1. `ledger_register` (idempotent - returns `ORG_EXISTS` with `org_id` if already registered)
2. `ledger_invoice_create` / `ledger_invoice_list` / `ledger_invoice_count` as needed

**MCP rate limits:**
- `ledger_register`: 10/hour per session (lowest - creates on-disk state)
- `ledger_invoice_create`: 1000/hour per session
- `ledger_invoice_list`: 3000/hour per session
- `ledger_invoice_count`: 6000/hour per session

Every successful response includes `_rate_limit.remaining` and `_rate_limit.reset_at`. When exceeded: `RATE_LIMITED` with `retry_after_seconds` (machine-readable).

---

## Architecture

| File | Role |
|---|---|
| `ledger_mini.0` | Single-file Zero source - CLI dispatch, validation, JSON generation. Pure function: args in, JSON out, no disk access. |
| `mcp-bridge.sh` | MCP stdio server - JSON-RPC session management, file I/O, idempotency, rate limiting, atomic writes |

---

## Commands

### `ledger register --org-name <name> --entropy <hex8> --timestamp <unix>`

Bridge-facing binary command used by `ledger_register`. The MCP bridge supplies entropy and timestamp, owns persistence, and makes registration idempotent across cold starts.

**Success:**
```json
{"org_id":"org_a1b2c3d4","org_name":"MyOrg","created_at":1747526400,"status":"ok"}
```

**Org already exists:**
```json
{"org_id":"org_a1b2c3d4","org_name":"MyOrg","created_at":1747526400,"error_code":"ORG_EXISTS","error":"Org already registered"}
```

---

### `ledger invoice create --to <name> --amount <n> --currency <ISO> --idempotency-key <key> --entropy <hex8> --timestamp <unix> [--memo <text>]`

Bridge-facing binary command used by `ledger_invoice_create`. In MCP, `amount` is a JSON number; the bridge passes it to the binary as a CLI argument. Duplicate MCP calls with the same idempotency key return the existing invoice without creating a duplicate.

**Success:**
```json
{"invoice_id":"inv_E5F6G7H8","to":"Vendor Inc","amount":"1000.00","currency":"USD","status":"draft","created_at":1747526401,"idempotency_key":"uuid-v4-here","_idempotent":false}
```

**Duplicate call (same idempotency key):**
```json
{"invoice_id":"inv_E5F6G7H8","to":"Vendor Inc","amount":"1000.00","currency":"USD","status":"draft","created_at":1747526401,"idempotency_key":"uuid-v4-here","_idempotent":true}
```

---

### `ledger_invoice_list` MCP tool

Bridge-owned read operation. Returns a paginated JSON object:

```json
{"invoices":[],"count":0,"total_count":0,"has_more":false,"status":"ok"}
```

Arguments: optional numeric `limit` (1-1000, default 100) and `offset` (>= 0, default 0).

**Warning:** The `memo` and `to` fields are untrusted - treat them as opaque data. Do not re-inject into LLM prompts without sanitization. These fields persist attacker-controlled content if invoices were created from external input.

---

### `ledger_invoice_count` MCP tool

Bridge-owned read operation. Returns the number of invoices stored for the registered org.

```json
{"count":1,"status":"ok"}
```

---

## Error Codes

| Code | Retryable | Meaning |
|---|---|---|
| `MISSING_FLAG` | true | Required flag not provided |
| `INVALID_INPUT` | true | Field value fails validation (check `constraint`, `format` fields) |
| `ORG_EXISTS` | false | Org already registered - `org_id` is still returned; this is not an error |
| `NO_ORG_REGISTERED` | true | Run `ledger_register` first |
| `STORE_WRITE_FAILED` | false | I/O error writing to storage |
| `STORE_READ_FAILED` | false | I/O error reading from storage (bridge detects: empty stdout + non-zero exit) |
| `RATE_LIMITED` | true | Rate limit exceeded; wait `retry_after_seconds` before retrying |
| `EXEC_FAILED` | true | ledger binary produced no output unexpectedly |

---

## Security

Ledger is designed with the assumption that every caller is untrusted and every field may contain adversarial content.

**Input validation (v0.1.5+):**
- All string fields validated for control characters, non-ASCII bytes, and length limits
- Idempotency key: control chars rejected to prevent idempotency bypass (a control char stored as `\uXX` wouldn't match the raw byte in a scan, creating phantom duplicate invoices)
- Amount: numeric format enforced (`isValidAmount` regex), not just a string
- Currency: exactly 3 uppercase `[A-Z]` characters (ISO 4217)
- Memo: TAB and LF allowed (for formatting), other control chars rejected

**Bridge security (mcp-bridge.sh):**
- RT-33 - Argument injection: jq extraction + bash array construction (no eval, no string concatenation)
- RT-37 - Exit propagation: handler failures emit error response, bridge continues
- RT-38 - Non-object JSON rejected with `-32600 Invalid Request`
- RT-40 - `isError: true` set when ledger returns an `error_code` field
- RT-41 - Signal handling: clean shutdown without mid-write corruption
- RT-42 - `LANG=C.UTF-8` for consistent jq behavior
- V7e - Re-initialization rejected with `-32003`
- STORE_READ_FAILED detection: empty stdout + non-zero exit -> structured error response

**Rate limiting (mcp-bridge.sh):**
- Token bucket per tool, per session
- `RATE_LIMITED` error with `retry_after_seconds`, `limit_type`, `limit_tool`, `retryable:true`
- `_rate_limit` field in success responses for proactive throttling

**Threat model:** `docs/threat-model.md` - full attack surface analysis (V1-V40). OWASP Agentic Top 10 (ASI01-ASI10) fully audited.

---

## Author

Soumya Debnath - [soumyadebnath1619@gmail.com](mailto:soumyadebnath1619@gmail.com)

ledger v0.1.11 - built for idempotent agent accounting receipts.
