# Agent UX Principles: A Technical Specification for Designing Agent-Native Software

**Version 1.0 — May 2026**
**Audience:** Product engineers, API designers, CLI developers, founders building agent-callable infrastructure.

---

## Preface

This document defines the principles governing how software should behave when its primary users are AI agents — LLMs operating autonomously, without a human in the loop. The term "Agent UX" deliberately inverts the conventional meaning: UX here is not about human comfort but about machine reliability. A 5-star developer experience for humans can be a complete failure for agents.

The principles that follow are derived from four primary sources: the Model Context Protocol specification (MCP, protocol version 2025-06-18), the Anthropic Claude tool-use architecture, the OpenAI function-calling system, and close analysis of real agent-callable software — the GitHub CLI (`gh`), `uvx`, `jq`, and their antitheses (browser-based OAuth flows, interactive prompts, ANSI-colored output parsers).

These are not guidelines. They are design constraints. Software that violates them will fail under autonomous agent use, often silently and at scale.

---

## Part I: Numbered Principles

### Principle 1: Every Operation Must Have a Machine-Readable Schema

**Name:** Schema-First Contract

**Explanation:** An agent cannot read documentation. It reads structured schema. Every callable tool, endpoint, or CLI command must expose a machine-readable description of itself — what parameters it accepts, what types they are, which are required, and what the output structure looks like. In MCP, this is the `inputSchema` and optional `outputSchema` on every tool definition. In Anthropic's tool-use format, it is the `input_schema` JSON Schema object. In OpenAI function calling, it is `parameters`. The schema is not supplementary — it is the primary interface.

**Failure mode without it:** The agent either hallucinates parameters, fails validation silently, or produces a well-formed call that is semantically wrong. Error rate on tool selection approaches 30-60% without schemas.

**Bad:**
```
GET /api/send-email
# Documented only in a Confluence page
```

**Good:**
```json
{
  "name": "send_email",
  "description": "Send a plain-text or HTML email. Rate limited to 100/hour per API key.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "to": {"type": "array", "items": {"type": "string", "format": "email"}, "description": "Recipients. Max 50."},
      "subject": {"type": "string", "maxLength": 998},
      "body": {"type": "string"},
      "content_type": {"type": "string", "enum": ["text/plain", "text/html"], "default": "text/plain"}
    },
    "required": ["to", "subject", "body"]
  }
}
```

---

### Principle 2: Descriptions Are Routing Instructions, Not Prose

**Name:** Description as Semantic Router

**Explanation:** An LLM selects which tool to call by comparing intent against tool descriptions. The description must contain: (a) what the tool does in concrete action-verb terms; (b) what kinds of inputs it expects; (c) critical constraints; (d) what it does NOT do. Ambiguous or overlapping descriptions cause mis-routing.

**Failure mode:** Two tools with vague descriptions ("process data", "handle request") will be called interchangeably, producing wrong results 40-60% of the time.

**Bad:**
```json
{"name": "process", "description": "Processes a request."}
```

**Good:**
```json
{
  "name": "archive_invoice",
  "description": "Moves an invoice to archived state (soft delete — remains queryable with status='archived'). Do NOT use for permanent deletion (use delete_invoice) or cancellation (use cancel_invoice).",
  "inputSchema": {
    "type": "object",
    "properties": {
      "invoice_id": {
        "type": "string",
        "pattern": "^inv_[a-zA-Z0-9]{24}$",
        "description": "Invoice ID. Format: 'inv_' + 24 alphanumeric chars. Example: 'inv_A3kF9mN2pQrT8vW1xZ5bC7dE'"
      }
    },
    "required": ["invoice_id"]
  }
}
```

---

### Principle 3: All Operations Must Be Idempotent or Clearly Labeled

**Name:** Retry-Safe Idempotency

**Explanation:** Agents operate under uncertainty. When a tool call returns no response, the agent cannot know if it succeeded. Every mutation must either be idempotent by design or accept an idempotency key. This is one of the leading causes of agent-induced data corruption in production.

**Bad:** `POST /payments/charge` — every call creates a new charge.

**Good:**
```json
{
  "name": "charge_payment_method",
  "description": "IDEMPOTENT when idempotency_key is provided: same key within 24h returns original result.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "payment_method_id": {"type": "string"},
      "amount_cents": {"type": "integer", "minimum": 50},
      "idempotency_key": {
        "type": "string",
        "description": "UUID v4. Makes this safe to retry. Required."
      }
    },
    "required": ["payment_method_id", "amount_cents", "idempotency_key"]
  }
}
```

---

### Principle 4: Errors Must Be Structured, Stable, and Actionable

**Name:** Machine-Parseable Error Codes

**Explanation:** Agents act on errors by pattern-matching against error codes, not reading messages. Every error must contain: a stable string error code (not an integer, never changes meaning); a human-readable message (can change); structured data fields for diagnosis. MCP: protocol errors use JSON-RPC codes; tool errors use `isError: true` + `structuredContent`.

**Bad:** `{"error": "Something went wrong. Please try again."}`

**Good:**
```json
{
  "isError": true,
  "structuredContent": {
    "error_code": "RATE_LIMIT_EXCEEDED",
    "category": "transient",
    "retry_after_seconds": 1847,
    "limit": 100,
    "window_seconds": 3600,
    "reset_at": "2026-05-17T15:00:00Z"
  }
}
```

---

### Principle 5: Output Must Be Structurally Pure

**Name:** Output Purity

**Explanation:** Any non-data content mixed into output corrupts parsing. `--json` must produce ONLY valid JSON on stdout; all diagnostics go to stderr. MCP stdio transport: "The server MUST NOT write anything to its stdout that is not a valid MCP message." Reference: `gh pr list --json number,title,state` returns a JSON array with zero decoration.

**Bad:**
```
$ mytool list --json
Authenticating...
[{"id": 1}]
WARNING: Deprecated version.
```

**Good:**
```
$ mytool list --json
[{"id": 1}]
# All other output → stderr
```

---

### Principle 6: No Interactive Prompts Under Any Circumstances

**Name:** Non-Interactive Execution Contract

**Explanation:** An agent running a subprocess cannot respond to stdin reads. Interactive prompts hang indefinitely. Every interactive behavior must have a flag equivalent. Tools should detect non-TTY stdin and automatically apply non-interactive mode.

**Bad:** `deploy --env production` → "Deploy? Enter 'yes' to confirm:" (hangs forever)

**Good:**
```bash
deploy --env production --yes
# Or: detect non-TTY stdin, apply --yes behavior automatically
```

---

### Principle 7: Operations Must Be Deterministic Given Identical Inputs

**Name:** Determinism Under Identical State

**Explanation:** Output structure must be stable (consistent ordering, stable IDs). List operations must return stable, documented ordering. Non-deterministic output forces agents to add reconciliation logic across every tool call.

**Bad:** `SELECT * FROM users` (random order)

**Good:** `SELECT * FROM users ORDER BY created_at ASC, id ASC` with declared sort contract.

---

### Principle 8: Latency and Side Effects Must Be Declared Before Execution

**Name:** Pre-Flight Semantics Declaration

**Explanation:** An agent building a multi-step plan needs to know, before committing, whether an operation has side effects, is expensive, or requires unavailable dependencies. MCP tool annotations serve this purpose: `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`.

**Bad:** `{"name": "run_query", "description": "Runs a query."}`

**Good:**
```json
{
  "name": "run_query",
  "description": "Read-only SELECT query. No side effects. 1-120 seconds. Results limited to 10,000 rows.",
  "annotations": {"readOnlyHint": true, "openWorldHint": true, "idempotentHint": true}
}
```

---

### Principle 9: Partial Success Must Be a First-Class Result Type

**Name:** Partial Success Reporting

**Explanation:** Batch operations frequently succeed for some inputs and fail for others. The result must enumerate success and failure per item with per-item error codes. Binary success/failure for batch calls is an anti-pattern.

**Bad:** `{"status": "partial_failure", "message": "3 emails failed"}`

**Good:**
```json
{
  "results": [
    {"to": "alice@example.com", "status": "sent", "message_id": "msg_abc"},
    {"to": "bad-email", "status": "failed", "error_code": "INVALID_EMAIL_FORMAT"},
    {"to": "bob@example.com", "status": "sent", "message_id": "msg_def"}
  ],
  "summary": {"total": 3, "sent": 2, "failed": 1}
}
```

---

### Principle 10: Discovery Must Require Zero Out-of-Band Knowledge

**Name:** Self-Describing Discovery

**Explanation:** A cold agent must be able to discover and enumerate all capabilities through in-protocol mechanisms alone. MCP: `tools/list`, `resources/list`, `prompts/list`. CLI: `--help --json`, `--describe`, `--schema`. HTTP: `GET /.well-known/api-capabilities` or `/openapi.json`. MCP Registry: `server.json` at `registry.modelcontextprotocol.io`.

**Bad:** API with no OpenAPI spec; documentation only at a browser URL.

**Good:**
```
GET /.well-known/mcp-server
→ {"name": "io.example/api", "mcp_endpoint": "/mcp", "transport": "streamable-http"}

GET /mcp → tools/list → complete catalog with full JSON Schema
```

---

### Principle 11: Authentication Must Be Completable Without a Browser

**Name:** Headless-First Authentication

**Explanation:** Agent processes run without display servers. OAuth authorization code flows cannot be completed. Use: API keys via `Authorization: Bearer`, OAuth 2.1 client credentials flow, or Dynamic Client Registration (RFC 7591). Never: browser OAuth, SAML SSO, CAPTCHA, email verification gates.

**Bad:** Authorization Code Flow (requires browser + human click).

**Good (client credentials):**
```python
response = await http.post("/token", data={
    "grant_type": "client_credentials",
    "client_id": env.CLIENT_ID,
    "client_secret": env.CLIENT_SECRET
})
access_token = response.json()["access_token"]
```

---

### Principle 12: Tool Names Must Be Unique, Stable, and Namespaced

**Name:** Namespace Stability

**Explanation:** In multi-server MCP deployments, tools from all servers are merged into one registry. Name collisions corrupt tool selection. Names must be stable across versions (a rename is a breaking change). Convention: `{action}_{resource}` within server, `{server_domain}_{action}_{resource}` across servers.

**Bad:** Server A tools: `list, create, delete`. Server B tools: `list, create, delete`.

**Good:** `crm_list_contacts`, `crm_create_contact` | `billing_list_customers`, `billing_create_customer`

---

### Principle 13: Long-Running Operations Must Be Non-Blocking with Status Polling

**Name:** Async-First Execution Model

**Explanation:** Operations taking more than 5 seconds must return immediately with a job ID and expose a poll endpoint. The agent should be able to disconnect and reconnect. MCP Tasks extension handles this. At minimum: return `{"job_id": "...", "status": "queued", "poll_url": "..."}`.

**Bad:** `generate_report(year)` — synchronous 3-minute block.

**Good:**
```python
def generate_report(year):
    job_id = enqueue(year)
    return {"job_id": job_id, "status": "queued", "estimated_seconds": 180, "poll_interval_recommendation_seconds": 15}

def get_report_status(job_id):
    job = get_job(job_id)
    if job.complete:
        return {"status": "complete", "result_url": job.url}
    return {"status": job.status, "progress_pct": job.progress}
```

---

### Principle 14: Resource Consumption Must Be Observable and Bounded

**Name:** Observable Resource Contracts

**Explanation:** Rate limit state must be returned proactively in every response — not only when limits are exceeded. Include `retry_after_seconds` as a numeric field in rate limit errors (not embedded in a message string). Batch workflows have no opportunity to throttle without proactive signal.

**Good:**
```json
{
  "result": {"records_created": 47},
  "meta": {
    "rate_limit": {
      "limit_per_hour": 1000,
      "remaining_this_hour": 623,
      "reset_at": "2026-05-17T16:00:00Z"
    },
    "cost_usd": 0.0023,
    "latency_ms": 234
  }
}
```

---

### Principle 15: An Agent Must Be Able to Provision Its Own Access Without Human Intervention

**Name:** Programmatic Self-Provisioning

**Explanation:** This is the highest-order principle. A cold agent, given only a base URL, must be able to: discover what the API offers, create an account or register as a client, obtain credentials, and begin making authenticated calls — entirely without human intervention. Mechanisms: `/.well-known/` endpoints, Dynamic Client Registration (RFC 7591), programmatic API key generation, no CAPTCHA or email verification on the registration path.

**Minimum viable self-provisioning flow:**
```
1. GET /.well-known/mcp-server
   → Discover: requires API key, obtainable at /v1/auth/register

2. POST /v1/auth/register
   {"client_name": "my-agent-v1"}
   → {"api_key": "sk_live_...", "rate_limit_per_hour": 1000}

3. GET /mcp (Authorization: Bearer sk_live_...)
   → MCP session established
```

---

## Part II: Programmatic Discovery and Signup

### Cold Agent Reference Flow (Zero Human Intervention)

**Step 1: Registry Query**
Query `https://registry.modelcontextprotocol.io/v0/servers` with semantic search. Each `server.json` contains: `name`, `description`, `packages` (installation commands), `capabilities`, `env` (required vars + how to obtain them).

**Step 2: Capability Inspection**
If any required `env` var lacks a programmatic acquisition path → flag as requiring human setup → deprioritize.

**Step 3: Server Startup (stdio)**
```bash
uvx database-query-mcp    # Python — zero pre-installation
npx -y @org/mcp-server    # Node.js — zero pre-installation
```

**Step 4: MCP Initialization**
Send `initialize` → receive capabilities → send `notifications/initialized` → call `tools/list` + `resources/list` + `prompts/list`.

**Step 5: Credential Acquisition**
1. Check `/.well-known/oauth-authorization-server` for DCR endpoint (RFC 7591)
2. Check `server.json` env docs for `/register` endpoint
3. If neither → mark as requiring human setup

**Step 6: Ongoing Operation**
Monitor rate limit fields. When `remaining < 0.2 * limit` → implement exponential backoff. When `isError: true` → inspect `error_code` → classify transient (retry after `retry_after_seconds`) vs permanent.

---

## Part III: Anti-Patterns

### The 10 Most Common Ways Software Fails Agents

1. **Interactive Prompt Ambush** — stdin reads hang indefinitely; agent timeout fires; operation state unknown. Fix: `--yes` flag, detect non-TTY stdin.

2. **ANSI Contamination** — Color codes corrupt stdout JSON parsing. Fix: detect non-TTY stdout, strip ANSI; `--no-color` flag; never write non-data to stdout when `--json` active.

3. **Ambiguous Naming** — Tool names like `process`, `handle`, `run` with vague descriptions cause 40-60% mis-routing. Fix: `{action}_{object}` naming; include exclusions in description.

4. **Browser-Required Authentication** — OAuth authorization code, SAML SSO, CAPTCHA. Agents cannot complete. Fix: API keys via programmatic endpoint; OAuth client credentials flow.

5. **Opaque Batch Failure** — `{"status": "error", "count": 3}` — agent cannot retry selectively or determine which items succeeded. Fix: per-item results with per-item status and error codes.

6. **Non-Idempotent Mutations** — Retried POSTs create duplicates. Double-charges, duplicate emails. Fix: require idempotency keys; document idempotency window.

7. **Stateful Setup Requirements** — `must call authenticate() before list_users()`. Agent cannot track implicit session state reliably. Fix: each tool call self-contained.

8. **Unstable Error Messages** — `"User not found"` becomes `"No such user exists"` in v2. Agent error classification breaks. Fix: stable string error codes alongside every message; codes never change.

9. **Synchronous Long Operations** — 10+ second tool calls time out the HTTP connection. Agent cannot distinguish timeout from failure. Fix: return job ID immediately; expose poll endpoint.

10. **Missing Rate Limit Visibility** — Only returns rate limit errors when exceeded. Batch workflows have no opportunity to throttle. Fix: include rate limit headers or fields in every response; `retry_after_seconds` as numeric field.

---

## Part IV: Agent UX Scorecard

Score each criterion 0 (missing), 1 (partial), 2 (complete). Maximum: 60.

| # | Criterion | Max |
|---|-----------|-----|
| 1 | Schema-First Discovery — all tools have complete `inputSchema` | 2 |
| 2 | Output Schema Declared — `outputSchema` for structured outputs | 2 |
| 3 | Description Routing Quality — action, object, constraints, exclusions | 2 |
| 4 | Parameter Descriptions — every param has format, examples, constraints | 2 |
| 5 | Idempotency — mutations accept idempotency keys or are idempotent | 2 |
| 6 | Structured Error Codes — stable string codes on all errors | 2 |
| 7 | Output Purity (CLI) — `--json` produces only JSON on stdout | 2 |
| 8 | Non-Interactive Execution — no stdin reads under any path | 2 |
| 9 | Deterministic Output Order — stable, documented sort contract | 2 |
| 10 | Side Effect Declaration — MCP annotations or description declares mutability | 2 |
| 11 | Partial Success — batch ops return per-item results | 2 |
| 12 | In-Protocol Discovery — enumerate all capabilities without docs | 2 |
| 13 | Headless Authentication — no browser required | 2 |
| 14 | Programmatic Account Creation — no human required | 2 |
| 15 | Rate Limit Visibility — proactive in every response | 2 |
| 16 | Async Long Operations — job ID + poll for ops >5s | 2 |
| 17 | Namespace Stability — unique, stable names across servers | 2 |
| 18 | Cancellation Support — in-progress ops cancellable | 2 |
| 19 | Transport Compatibility — stdio + HTTP | 2 |
| 20 | Registry Publication — machine-readable metadata in MCP Registry | 2 |
| 21 | Version Stability Policy — semver + deprecation window | 2 |
| 22 | Cost/Quota Transparency — per-call cost documented and returned | 2 |
| 23 | MCP Protocol Compliance — passes MCP Inspector | 2 |
| 24 | Self-Describing Error Recovery — `retry_after`, `valid_values` in errors | 2 |
| 25 | Progress Reporting — SSE or MCP progress notifications for long ops | 2 |
| 26 | Tool Annotations Complete — all four MCP hint flags set | 2 |
| 27 | Cursor-Based Pagination — not offset-based | 2 |
| 28 | Dry-Run Mode — `--dry-run` flag on all mutations | 2 |
| 29 | Credential Rotation — zero-downtime key rotation | 2 |
| 30 | Per-Agent Key Scoping — fine-grained per-tool scopes | 2 |

**Scoring:**
- 0–15: Incompatible with autonomous agent use
- 16–30: Limited use, high failure rate in multi-step workflows
- 31–45: Functional in controlled conditions; production risk on edge cases
- 46–54: Agent-ready; minor gaps won't block common workflows
- 55–60: Agent-native; reference implementation quality

---

## Appendix A: The `uvx` Principle

`uvx some-tool --arg value` downloads, installs in isolation, executes, and discards — zero state on host. This is the execution model all agent-callable CLIs should aspire to. `npx -y` is the Node.js equivalent. The MCP `mcpb` package format extends this to binary MCP servers.

## Appendix B: The `gh` CLI Pattern

`gh pr list --json number,title,state` — pure JSON, zero decoration. `gh` is the canonical reference: `--json` for all commands, explicit field selection, pure stdout, headless auth via `GH_TOKEN`, errors to stderr. Emulate this entire pattern, not just the flag.

## Appendix C: MCP Wire Format

JSON-RPC 2.0, UTF-8, newline-delimited on stdio. Init sequence: `initialize` → response → `notifications/initialized`. The `MCP-Protocol-Version` header required on all HTTP requests post-init. Capability negotiation determines which primitives are available.
