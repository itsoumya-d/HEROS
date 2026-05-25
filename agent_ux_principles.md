# Agent UX Principles
## A Design Specification for Software Built for LLM Agents

*Compiled: May 2026 — based on MCP spec 2025-11-25, Anthropic tool-use API, OpenAI function calling, x402, A2A, and empirical study of agent-friendly CLIs*

---

## Preamble

This document defines actionable design principles for software intended to be called, provisioned, and operated by LLM-based agents — not humans. The principles are organized into nine domains. Each principle is stated as a concrete design requirement, followed by its rationale, technical implementation notes, and anti-patterns.

The core insight: **agents are not slow humans.** They cannot read a CAPTCHA, they cannot click an OAuth button, they cannot interpret ANSI escape codes, and they cannot retry a non-idempotent call safely. Every design choice that assumes a human is in the loop is a failure mode for agents.

---

## Domain 1: MCP (Model Context Protocol) — Structural Design

### Principle 1.1: Expose capabilities through the MCP initialize handshake, not documentation

**Requirement:** Every server MUST declare its supported primitives in the `initialize` response. A cold agent with no prior knowledge of your server MUST be able to discover all available tools, resources, and prompts through protocol messages alone, requiring zero external documentation.

**Technical implementation:**

The MCP initialization handshake (JSON-RPC 2.0, protocol version `2025-11-25`) follows this exact pattern:

```json
// Client → Server
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": { "elicitation": {} },
    "clientInfo": { "name": "my-agent", "version": "1.0.0" }
  }
}

// Server → Client
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "tools": { "listChanged": true },
      "resources": {},
      "prompts": {}
    },
    "serverInfo": { "name": "my-server", "version": "2.1.0" }
  }
}
```

The `capabilities` object is the contract. If `tools` is not declared here, agents MUST NOT attempt `tools/list`. If `listChanged: true` is declared, clients MUST listen for `notifications/tools/list_changed` and refresh their tool registry when it fires.

**After initialization**, send `notifications/initialized` (no ID, no response expected) to signal readiness.

**Anti-pattern:** Advertising capabilities in a README that agents cannot read programmatically. Listing tools in `capabilities` but not in `tools/list` response. Omitting `listChanged` when tools are dynamic.

---

### Principle 1.2: Every tool MUST carry an outputSchema alongside its inputSchema

**Requirement:** MCP tool definitions MUST include both `inputSchema` (what the agent sends) and `outputSchema` (what the agent receives). Agents cannot reason about outputs they cannot predict.

**Technical implementation:**

```json
{
  "name": "query_database",
  "title": "Database Query Executor",
  "description": "Executes a read-only SQL SELECT query against the analytics database. Returns rows as JSON objects. Use this when the user asks for data that requires aggregation, filtering, or joining across tables. Does NOT support mutations (INSERT/UPDATE/DELETE) — use write_record for those.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "sql": {
        "type": "string",
        "description": "A valid SQL SELECT statement. Must not contain semicolons (they are added automatically). Example: 'SELECT user_id, sum(revenue) FROM orders WHERE date > 2026-01-01 GROUP BY user_id'"
      },
      "limit": {
        "type": "integer",
        "description": "Maximum rows to return. Defaults to 100. Maximum 10000.",
        "default": 100
      }
    },
    "required": ["sql"]
  },
  "outputSchema": {
    "type": "object",
    "properties": {
      "rows": {
        "type": "array",
        "items": { "type": "object" },
        "description": "Array of result rows as JSON objects"
      },
      "rowCount": { "type": "integer" },
      "truncated": { "type": "boolean", "description": "True if results were cut at the limit" },
      "executionMs": { "type": "integer" }
    },
    "required": ["rows", "rowCount", "truncated"]
  }
}
```

For backwards compatibility, also serialize the structured output as JSON in a `TextContent` block alongside the `structuredContent` field.

**Anti-pattern:** Returning free-form text like `"Found 47 rows: ..."` that agents must parse with string manipulation. Changing output shape silently between versions.

---

### Principle 1.3: Use two distinct error channels correctly

**Requirement:** MCP defines two error channels. Use them correctly — conflating them breaks agent retry logic.

**Protocol errors** (JSON-RPC `error` field, code -32602): For malformed requests, unknown tool names, protocol violations. Agents cannot self-correct these; they indicate a programming bug.

**Tool execution errors** (`isError: true` in the result): For business logic failures, validation errors, upstream API failures. Agents CAN self-correct these — they read the error message and retry with different parameters.

```json
// Correct: tool execution error (agent can retry with different date)
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "content": [{
      "type": "text",
      "text": "Invalid departure date '2025-01-01': must be in the future. Today is 2026-05-17. Retry with a date after today."
    }],
    "isError": true
  }
}

// Wrong: using protocol error for a business logic failure
{
  "jsonrpc": "2.0",
  "id": 4,
  "error": {
    "code": -32602,
    "message": "Invalid date"
  }
}
```

The actionable error message in tool execution errors is load-bearing. It must tell the agent exactly what was wrong and how to fix it.

---

### Principle 1.4: Use stdio for local tools, Streamable HTTP for remote services

**Requirement:** Local MCP servers (running on the same machine as the agent) MUST use stdio transport. Remote servers MUST use Streamable HTTP (HTTP POST + optional SSE). Never mix them.

**stdio transport:** The server reads JSON-RPC messages from stdin, writes responses to stdout. One newline per message. Credentials come from the process environment, NOT from the protocol. No auth framework in stdio — use environment variables (`MYSERVICE_API_KEY`).

**Streamable HTTP transport:** HTTP POST to a single endpoint for client→server messages. Optional SSE stream for server→client notifications. Auth via standard HTTP headers: `Authorization: Bearer <token>`, API keys in headers, OAuth tokens. The MCP spec recommends OAuth for obtaining tokens but does not mandate it.

**Anti-pattern:** Building an MCP server that spawns a browser window for auth. Building a remote server on stdio (cannot serve multiple clients). Reading credentials from stdin in stdio mode (breaks the message framing protocol).

---

### Principle 1.5: Implement pagination on all list operations

**Requirement:** `tools/list`, `resources/list`, and `prompts/list` MUST support cursor-based pagination. An agent discovering 500 tools in one response cannot fit them all in its context window.

```json
// Request
{ "jsonrpc": "2.0", "id": 5, "method": "tools/list", "params": { "cursor": "eyJwYWdlIjozfQ" } }

// Response
{
  "result": {
    "tools": [ /* up to N tools */ ],
    "nextCursor": "eyJwYWdlIjo0fQ"  // absent when no more pages
  }
}
```

Agents iterate until `nextCursor` is absent. Provide sensible page sizes (20–50 tools). Include a `title` field (human display name) separate from `name` (machine identifier) on every tool.

---

## Domain 2: Frontier Model Tool Calling — Schema Design

### Principle 2.1: Every tool description must answer five questions

**Requirement:** Tool descriptions are compiled into the model's system prompt. They are the primary signal the model uses for tool selection and parameter population. A description that cannot answer these five questions will produce incorrect calls:

1. **What does this tool do?** (action, not noun)
2. **When should it be used?** (trigger conditions)
3. **When should it NOT be used?** (negative constraints)
4. **What does each parameter mean?** (with format examples)
5. **What does it return?** (output semantics)

**Good (Anthropic tool schema):**
```json
{
  "name": "search_tickets",
  "description": "Searches the support ticket database for tickets matching a query. Use this when the user asks about existing issues, bug reports, or customer complaints. Do NOT use this to create new tickets — use create_ticket for that. Returns up to 20 matching tickets sorted by recency. Does not search comments within tickets, only ticket titles and descriptions.",
  "input_schema": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "Search terms. Supports boolean operators: AND, OR, NOT. Example: 'login AND (timeout OR error)'"
      },
      "status": {
        "type": "string",
        "enum": ["open", "closed", "all"],
        "description": "Filter by ticket status. Use 'all' if unsure."
      },
      "assignee_id": {
        "type": "string",
        "description": "Optional. User UUID to filter by assignee. Example: 'usr_abc123'. Omit to search all assignees."
      }
    },
    "required": ["query", "status"]
  }
}
```

**Bad:**
```json
{
  "name": "search_tickets",
  "description": "Search tickets.",
  "input_schema": {
    "type": "object",
    "properties": {
      "query": { "type": "string" },
      "status": { "type": "string" },
      "assignee_id": { "type": "string" }
    },
    "required": ["query"]
  }
}
```

The bad version will cause the model to guess at every parameter, select the wrong tool when alternatives exist, and fail to know when NOT to call it.

---

### Principle 2.2: Use strict mode and mark every property required

**Requirement:** Always enable `strict: true` (OpenAI) or use structured output mode. In strict mode, `additionalProperties` must be `false` on every object. Mark all properties as `required`; use `"type": ["string", "null"]` for optional fields.

**Anthropic:** Use `strict: true` on tool definitions to guarantee schema compliance.
**OpenAI:** 
```json
{
  "type": "function",
  "function": {
    "name": "get_weather",
    "strict": true,
    "parameters": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "location": { "type": "string" },
        "unit": { "type": ["string", "null"], "enum": ["celsius", "fahrenheit", null] }
      },
      "required": ["location", "unit"]
    }
  }
}
```

Without strict mode, models produce "best-effort" JSON that may omit required fields or add hallucinated ones. At production scale this creates unparseable payloads.

---

### Principle 2.3: Consolidate operations; never create one tool per HTTP method

**Requirement:** Avoid tool proliferation. Group related operations into a single tool with an `action` enum parameter. The model performs better with fewer, more capable tools.

**Do this:**
```json
{
  "name": "manage_issue",
  "description": "Creates, updates, or closes a GitHub issue. Use action='create' to open a new issue, action='update' to modify title/body/labels, action='close' to close with a comment.",
  "input_schema": {
    "properties": {
      "action": { "type": "string", "enum": ["create", "update", "close"] },
      "issue_number": { "type": ["integer", "null"], "description": "Required for update/close. Null for create." },
      "title": { "type": ["string", "null"] },
      "body": { "type": ["string", "null"] }
    },
    "required": ["action", "issue_number", "title", "body"]
  }
}
```

**Not this:** `create_issue`, `update_issue`, `close_issue`, `reopen_issue` as four separate tools.

Anthropic's empirical guidance: consolidation reduces selection ambiguity and is "especially important when using tool search." OpenAI guidance: keep the initially visible tool count below 20 for highest accuracy.

---

### Principle 2.4: Use namespace prefixes for multi-service tool sets

**Requirement:** When exposing tools from multiple services or domains, prefix names: `github_list_prs`, `slack_send_message`, `stripe_create_charge`. Both Anthropic and OpenAI explicitly recommend this.

Tool names must match `^[a-zA-Z0-9_-]{1,64}$` (Anthropic) or the equivalent pattern. MCP tool names may also include dots: `admin.tools.list` is valid.

Namespacing prevents the model from selecting `search` (for Slack) when it means `search` (for the database). The clarity cost is near-zero; the accuracy gain is significant.

---

### Principle 2.5: Return high-signal responses, not raw API dumps

**Requirement:** Tool responses are injected into the model's context window. Every byte costs tokens and attention. Return only what the model needs for its next reasoning step.

**Rules:**
- Return semantic identifiers (`user_id: "usr_abc123"`, `status: "open"`) not opaque internal references (`db_row_id: 48291`)
- Use natural language field names (`file_type`, not `mime_type`; `name`, not `uuid`)
- Truncate at sensible limits (20 results, not 2000) and include a `truncated: true` field so the model knows to refine its query
- Include a `nextCursor` or `hasMore` field if pagination exists
- Strip HTML, strip ANSI, strip rendering-layer artifacts

**Anti-pattern:** Returning a full database row including internal metadata, foreign keys, audit timestamps, and binary blobs because "the model might need it."

---

## Domain 3: What Works for Agents

### Principle 3.1: Be invocable with a single command and zero configuration state

**Requirement:** An agent must be able to use your tool with a single invocation that specifies all inputs inline. No setup wizard, no persistent session, no multi-step initialization.

**Why uvx works:** `uvx my-tool --arg value` — the binary is fetched, isolated, executed, and discarded. The agent never installs anything globally. The environment is clean and reproducible.

```bash
# Agent-friendly: everything inline, ephemeral, no state
uvx ruff check --output-format json myfile.py

# Agent-hostile: requires prior setup
ruff check myfile.py  # fails if ruff is not installed
```

**Why gh CLI works:** `gh pr list --json number,title,state --jq '.[].title'` — every output is selectable as structured JSON (`--json`), filterable with jq expressions (`--jq`), and formatted with Go templates (`--template`). The `--json` flag is the single most important agent-friendliness feature a CLI can have.

**Why jq works:** Reads stdin, writes stdout, takes its program as a positional argument, produces valid JSON on stdout, exits 0 on success. Completely stateless. No configuration file needed.

**Why curl works:** Single command, all options inline, `--silent` suppresses progress, `-o /dev/null -w '%{http_code}'` gives machine-readable status, `-H` adds headers, `-d` adds body. Everything accessible without reading docs at runtime.

**The common pattern:**
1. Single binary with no required installation state
2. All inputs as flags or arguments (not interactive prompts)
3. Output to stdout in structured format (JSON preferred)
4. Exit codes communicate success/failure (0 = success, nonzero = error)
5. `--help` (or `--help-json`) outputs usage to stdout in parseable form

---

### Principle 3.2: Provide a `--help-json` or equivalent machine-readable help format

**Requirement:** Every flag must be discoverable without running the binary against a real target. `--help` in human-readable text is insufficient for agents — they cannot reliably parse ad-hoc prose. Add `--help-json` that emits a structured schema of all flags.

```json
// Output of: mytool --help-json
{
  "name": "mytool",
  "version": "2.1.0",
  "description": "Manages widget deployments",
  "commands": [
    {
      "name": "deploy",
      "description": "Deploy a widget to a target environment",
      "flags": [
        {
          "name": "--widget-id",
          "type": "string",
          "required": true,
          "description": "UUID of the widget to deploy. Example: wgt_abc123"
        },
        {
          "name": "--env",
          "type": "string",
          "enum": ["staging", "production"],
          "required": true
        },
        {
          "name": "--dry-run",
          "type": "boolean",
          "default": false,
          "description": "Print what would happen without executing"
        }
      ]
    }
  ]
}
```

This is the CLI equivalent of an MCP `tools/list` response. Without it, agents must either call `--help` and parse unstructured text (fragile) or hallucinate flag names (dangerous).

---

## Domain 4: What Fails for Agents

### Principle 4.1: Never emit ANSI escape codes to stdout when stdout is not a TTY

**Requirement:** ANSI escape sequences (`\033[32m`, `\x1b[0m`, etc.) are rendering instructions for terminal emulators. When an agent reads your stdout, it reads raw bytes — color codes appear as literal character sequences that corrupt the output.

**Implementation:**
```python
import sys
use_color = sys.stdout.isatty()
# OR: check the NO_COLOR environment variable (https://no-color.org)
use_color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
```

Respect the `NO_COLOR` environment variable (a widely adopted standard). Many tools already do this: `git`, `grep`, `ls` all check `isatty()` before coloring. Your tool must too.

**Anti-pattern:** Hardcoding ANSI codes without TTY detection. Outputting colored text to stdout that agents then try to parse as JSON and fail with a syntax error.

---

### Principle 4.2: Never use interactive prompts when stdin is not a TTY

**Requirement:** Any prompt that blocks waiting for user input (`Press [y/n] to continue:`, `Enter your API key:`, library readline prompts, Python's `input()`) will hang an agent's execution indefinitely — agents cannot type.

**Implementation:**
- Check `sys.stdin.isatty()` before prompting
- If stdin is not a TTY, require all inputs as flags or fail with a clear error: `Error: --confirm flag required in non-interactive mode`
- Provide `--yes` / `--non-interactive` / `--force` flags for all destructive operations
- When a required parameter is missing in non-interactive mode, exit nonzero with a message explaining which flag to add

**Anti-pattern:** `sudo`-style password prompts mid-execution. Package manager confirmations (`Proceed? [Y/n]`). Any `getpass()` call without a flag fallback.

---

### Principle 4.3: Never require a browser-based OAuth flow for agent access

**Requirement:** Standard OAuth 2.0 authorization code flow requires opening a browser, clicking through a consent screen, and receiving a redirect. Agents have no browser. This flow hard-blocks agent access.

**Agent-compatible authentication alternatives (in order of preference):**
1. **API key via HTTP POST:** `POST /v1/keys` with JSON body → returns `{"key": "sk-...", "created_at": "..."}`. No email, no browser, no CAPTCHA.
2. **Static bearer tokens:** Generated in a dashboard, valid indefinitely or until rotated. Passed as `Authorization: Bearer <token>` or `X-API-Key: <key>`.
3. **Machine-to-machine OAuth (client credentials grant):** `POST /oauth/token` with `grant_type=client_credentials`, `client_id`, `client_secret` → returns `access_token`. No browser redirect.
4. **PKCE flow with CLI helper:** `gh auth login` solves this by catching the redirect in a local HTTP server. Acceptable only if your CLI includes this helper and it works headlessly.
5. **Cryptographic identity (DID/wallet):** Agent presents a signed credential bound to its decentralized identifier (TDIP DID, ERC-8004). No central account required.

**Reject:** OAuth authorization code flow, SAML SSO, CAPTCHA on any auth endpoint, email verification gates.

---

### Principle 4.4: Never use stateful daemons that require a management lifecycle

**Requirement:** Tools that require `start` → `use` → `stop` lifecycle management are difficult for agents to use reliably. Agents may crash mid-task, leaving daemons running. They may call `use` before `start`. Cleanup is non-deterministic.

**Prefer:** Stateless request/response tools. If you must maintain state, use request-scoped sessions with explicit timeout and auto-cleanup:
```
POST /sessions → { "session_id": "sess_abc", "expires_at": "2026-05-17T15:00:00Z" }
POST /sessions/sess_abc/actions
DELETE /sessions/sess_abc  # or auto-expires
```

Always include `expires_at` and honor it server-side even if the agent crashes without cleanup.

---

### Principle 4.5: Provide unambiguous flags; never use single-letter flags as the only form

**Requirement:** Single-letter flags (`-f`, `-r`, `-v`) are ambiguous. Different tools reuse the same letters for different meanings. An agent that has learned `-r` means "recursive" in one tool will make errors when `-r` means "remote" in another.

**Requirement:** Every flag MUST have a long form (`--force`, `--recursive`, `--verbose`). Single-letter short forms are optional conveniences. Document the long form in `--help-json`. Agents use the long form exclusively.

**Ambiguous flag anti-patterns:**
- `-d` = debug in one tool, delete in another, directory in a third
- Flags that change meaning based on positional context
- Positional arguments with no named equivalent flag

---

## Domain 5: Idempotency, Partial Success, and Retryability

### Principle 5.1: Every mutating operation MUST accept an idempotency key

**Requirement:** Agents operate in unreliable networks. They will retry failed calls. Without idempotency keys, retries produce duplicate side effects (duplicate charges, duplicate emails, duplicate records).

**Implementation (HTTP header pattern, following Stripe):**
```http
POST /v1/charges
Idempotency-Key: agent-session-abc123-step-7-charge-user-456
Content-Type: application/json

{"amount": 2000, "currency": "usd", "customer": "cus_abc"}
```

Server behavior:
- First call with key: execute and store result
- Subsequent calls with same key: return stored result immediately, do NOT re-execute
- Key storage: minimum 24 hours, recommended 7 days
- Collision on in-flight key: return `409 Conflict` with `Retry-After` header

**Key construction rule:** Idempotency keys MUST be deterministic from the workflow context, not from the execution moment. `agent-session-{session_id}-step-{step_number}-{operation_name}` is correct. `{uuid_v4()}` is wrong (generates a new key on every retry, defeating the purpose).

**Implement for:** POST, PUT, PATCH, DELETE. GET is inherently idempotent; no key needed.

---

### Principle 5.2: Return partial success explicitly, not as an error

**Requirement:** Batch operations that partially succeed MUST return a structured partial success response, not a blanket error. An error response causes the agent to retry the entire batch, re-executing already-completed items.

```json
// Good: partial success
HTTP 207 Multi-Status
{
  "succeeded": [
    { "id": "item_1", "result": { "created": true } },
    { "id": "item_3", "result": { "created": true } }
  ],
  "failed": [
    {
      "id": "item_2",
      "error": {
        "code": "DUPLICATE_EMAIL",
        "message": "Email user@example.com already exists. Use update_user to modify existing records.",
        "retryable": false
      }
    }
  ],
  "partial": true
}

// Bad: treating partial success as total failure
HTTP 400
{ "error": "Some items failed" }
```

The `retryable` field on each failure is critical. Agents use it to distinguish:
- `retryable: false` — stop, the input is wrong, do not retry
- `retryable: true` — transient failure, retry this item with backoff
- No `retryable` field — agent must guess (do not do this)

---

### Principle 5.3: Distinguish retryable from non-retryable errors in every response

**Requirement:** Every error response MUST classify whether the error is transient (retry will likely succeed) or permanent (retry will always fail).

```json
// Transient — agent should retry with exponential backoff
HTTP 429
{
  "error": {
    "code": "RATE_LIMITED",
    "message": "Rate limit exceeded. Retry after 30 seconds.",
    "retryable": true,
    "retry_after_seconds": 30
  }
}

// Permanent — agent should NOT retry, should report failure
HTTP 422
{
  "error": {
    "code": "INVALID_CURRENCY",
    "message": "Currency 'XYZ' is not supported. Supported currencies: USD, EUR, GBP, JPY.",
    "retryable": false,
    "valid_values": ["USD", "EUR", "GBP", "JPY"]
  }
}
```

HTTP status codes alone are insufficient — 500 can be transient (server restart) or permanent (code bug). The `retryable` field removes ambiguity.

Standard retry-safe HTTP status codes: `429` (rate limit, always retry), `503` (service unavailable, retry). Non-retryable: `400` (bad input), `401` (auth failed), `403` (forbidden), `404` (not found), `422` (unprocessable entity).

---

### Principle 5.4: Support checkpointed long-running operations

**Requirement:** Operations taking more than 5 seconds MUST be asynchronous with status polling. Agents cannot block synchronously for minutes — their context window fills, their timeout fires.

**Pattern (aligned with MCP Tasks experimental spec):**
```http
POST /v1/exports → 202 Accepted
{ "job_id": "job_abc123", "status": "pending", "poll_url": "/v1/exports/job_abc123" }

GET /v1/exports/job_abc123 → 200
{ "job_id": "job_abc123", "status": "running", "progress": 0.42, "eta_seconds": 30 }

GET /v1/exports/job_abc123 → 200
{ "job_id": "job_abc123", "status": "complete", "result_url": "/v1/exports/job_abc123/result" }
```

Jobs MUST be idempotent: submitting the same job twice (same `Idempotency-Key`) returns the existing job, not a new one. Jobs MUST survive agent crashes: a new agent session can poll an existing job ID.

---

## Domain 6: Programmatic Discovery

### Principle 6.1: Publish a DNS TXT record at `_mcp.<your-domain>` for agent discovery

**Requirement:** A cold agent that knows only your domain name must be able to discover your MCP endpoint. The IETF draft `draft-morrison-mcp-dns-discovery` defines the standard mechanism.

**DNS TXT record format:**
```
_mcp.yourdomain.com  IN  TXT  "v=mcp1; url=https://mcp.yourdomain.com; proto=mcp; public=true"
```

Key fields:
- `v=mcp1` — version marker
- `url=` — the MCP server endpoint URL
- `proto=mcp` — protocol identifier
- `public=true` — any agent can discover this without authentication
- `pk=ed25519:<base64url>` — optional: server's public key for identity verification

**Additionally**, serve a manifest at `/.well-known/mcp-server` (JSON):
```json
{
  "name": "MyService MCP Server",
  "version": "2.1.0",
  "endpoint": "https://mcp.yourdomain.com",
  "capabilities": ["tools", "resources"],
  "auth": {
    "type": "bearer",
    "provision_url": "https://yourdomain.com/v1/api-keys"
  }
}
```

Google's A2A protocol uses `/.well-known/agent-card.json` for a similar purpose.

---

### Principle 6.2: Register in the MCP Registry with a machine-readable manifest

**Requirement:** Publish to the MCP Registry (`registry.mcp.io`) so agents can find you through centralized discovery. The registry manifest format:

```json
{
  "namespace": "com.yourdomain.myservice",
  "description": "Manages widget deployments and monitoring",
  "repository": {
    "url": "https://github.com/yourorg/myservice-mcp",
    "source": "github"
  },
  "packages": [
    {
      "registry": "npm",
      "name": "@yourorg/myservice-mcp",
      "version": "2.1.0"
    }
  ]
}
```

For npm packages, agents can install via `npx @yourorg/myservice-mcp`. For Python packages, via `uvx yourorg-myservice-mcp`. These are the two primary agent-native install paths.

**Namespace verification:** `io.github.username` namespaces verified via GitHub OAuth (CLI-based). `com.example` namespaces verified via DNS TXT record (fully programmatic).

---

### Principle 6.3: Publish package metadata that enables zero-configuration discovery

**Requirement:** npm and pip package metadata are programmatically queryable. Use them as a discovery layer.

**npm:**
```json
// package.json
{
  "name": "@yourorg/myservice-mcp",
  "keywords": ["mcp", "mcp-server", "ai-agent"],
  "mcp": {
    "server": true,
    "capabilities": ["tools", "resources"],
    "transport": "stdio"
  }
}
```

Agents can search: `npm search mcp-server --json` and filter by keyword.

**pip:**
```toml
# pyproject.toml
[project]
keywords = ["mcp", "mcp-server", "ai-agent"]

[project.scripts]
myservice-mcp = "myservice_mcp:main"

[project.entry-points."mcp.servers"]
myservice = "myservice_mcp:server"
```

The `mcp.servers` entry point group allows Python-aware agent frameworks to discover installed MCP servers without configuration.

---

## Domain 7: Programmatic Signup

### Principle 7.1: Provision API keys via HTTP POST with no human steps

**Requirement:** An agent must be able to create an account and obtain working credentials in a single HTTP roundtrip. No email verification, no CAPTCHA, no browser window, no human approval.

**Compliant signup endpoint:**
```http
POST /v1/api-keys
Content-Type: application/json
X-Agent-Identity: did:key:z6Mk...  (optional: agent's DID for identity)

{
  "plan": "pay-per-call",
  "spending_limit_usd": 10.00,
  "label": "my-agent-session-abc123"
}

→ 201 Created
{
  "api_key": "sk-live-abc123xyz...",
  "key_id": "key_abc123",
  "plan": "pay-per-call",
  "spending_limit_usd": 10.00,
  "rate_limit": { "requests_per_minute": 60, "requests_per_day": 10000 },
  "created_at": "2026-05-17T10:00:00Z",
  "docs_url": "https://docs.yourdomain.com/api"
}
```

Every field in the response is machine-readable. The `docs_url` points to machine-readable API documentation (OpenAPI spec preferred).

**Why no email?** Emails require a human to read them. An agent cannot click a verification link. Email-gated signup is a complete blocker.

**Abuse prevention without email:** IP rate limiting, spending caps (required in request body), anomaly detection, and post-hoc suspension work without human-in-the-loop signup. Anthropic, OpenAI, and most modern API providers gate by payment method, not email verification.

---

### Principle 7.2: Return machine-readable onboarding state in the signup response

**Requirement:** The signup response must give the agent everything it needs to make its first API call. Do not redirect to a documentation website. Do not require an additional configuration step.

**Minimum required fields in the response:**
- `api_key` or equivalent credential
- `base_url` — the API's root URL
- `rate_limit` — so the agent can self-throttle
- `spending_limit` — so the agent knows its budget
- `openapi_url` or `docs_url` — pointer to machine-readable API spec

**Anti-pattern:** Sending `"Check your email to complete registration"`. Returning just `{ "success": true }`. Redirecting to a human-readable onboarding wizard.

---

## Domain 8: Agent-Native Economics

### Principle 8.1: Bill per-call with a machine-readable pricing structure

**Requirement:** Subscription pricing fails for agents because agent usage is bursty and unpredictable. An agent making 50,000 calls in a single task and zero the next week is not well-served by a monthly plan. Per-call pricing must be available.

**Machine-readable pricing (expose at `/v1/pricing`):**
```json
{
  "plans": [
    {
      "id": "pay-per-call",
      "type": "usage",
      "currency": "USD",
      "line_items": [
        { "metric": "api_calls", "price_per_unit": 0.001, "unit": "call" },
        { "metric": "data_transfer_mb", "price_per_unit": 0.01, "unit": "MB" }
      ],
      "minimum_charge_usd": 0.00
    }
  ],
  "free_tier": {
    "api_calls_per_month": 1000,
    "expires_after_days": null
  }
}
```

Return usage and remaining budget in every API response header:
```
X-RateLimit-Remaining: 4982
X-Credits-Remaining: 8.42
X-Credits-Used-This-Call: 0.001
```

Agents use these headers to self-regulate spending without calling a separate usage endpoint.

---

### Principle 8.2: Support x402 for trustless per-call payment

**Requirement:** For services where agents should be able to pay without pre-provisioned accounts, implement the x402 protocol (HTTP 402 Payment Required).

**The x402 flow:**
1. Agent requests resource: `GET /v1/premium-data`
2. Server: `402 Payment Required` + payment challenge (amount in USDC, destination wallet, chain ID)
3. Agent wallet signs payment authorization (EIP-3009) — does not expose private key
4. Agent retries with `PAYMENT-SIGNATURE` header containing signed authorization
5. Server verifies on-chain settlement, returns `200 OK` + `PAYMENT-RESPONSE` confirmation

This mechanism is:
- **Stateless:** No account creation, no API key, no OAuth
- **Trustless:** Payment proof is cryptographically verified
- **Per-call:** No subscription required
- **Auditable:** Every payment is on-chain

For fiat-based services, support Machine Payments Protocol (MPP, co-authored by Stripe and Tempo): HTTP 402 challenge → signed credential → session token for repeated calls with per-token billing.

---

### Principle 8.3: Provide cryptographic agent identity as a first-class concept

**Requirement:** Agent identity must not require a human email address or browser OAuth. Support at least one of: API keys (simplest), DIDs (Decentralized Identifiers), or ERC-8004 on-chain agent identity.

**DID-based identity (interoperability layer):**
```
// Agent presents its DID in a header
X-Agent-Identity: did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK

// Service verifies the DID against the signed request
// No central registry required — the DID is self-authenticating
```

**Reputation without OAuth:**
- On-chain NFT-backed agent identity: agents build reputation through successful transactions
- Credit scoring based on payment history (not human identity)
- Programmable spending controls: `{ "max_usd_per_call": 0.10, "max_usd_per_day": 50.00 }`
- Automatic suspension for unusual behavior — no human review required for reinstatement below a threshold

**The key insight:** agents build reputation through economic behavior (timely payments, no fraud) not through identity verification (email, phone, face). Design your trust model accordingly.

---

## Domain 9: Real Examples of Agent-Native Software

### Principle 9.1: Study these systems — they got it right

**Exa (semantic search API):**
- Returns neural-embedding search results, not HTML pages with ads
- Every result includes pre-extracted text, metadata, and relevance score
- Supports `highlights` extraction — returns only the relevant excerpt, not the whole page
- Output is JSON with stable schema; no parsing of rendered HTML required
- MCP server available (`npx exa-mcp-server`)

**Tavily:**
- "Source-first discovery" — returns authoritative sources with structured summaries
- Security-validated results (filters content that would be harmful in agent context)
- Optional multi-step synthesis — agent asks once, gets researched answer
- Designed specifically for RAG pipelines: returns `content` field ready for vector embedding

**Firecrawl:**
- Combines search + full-page content extraction in a single API call
- Returns clean Markdown — no HTML, no scripts, no CSS
- MCP server for direct Claude Code / Cursor integration
- Handles JavaScript-rendered pages that other scrapers miss

**uvx (uv tool runner):**
- `uvx tool-name --arg value` — installs into a temporary isolated env, runs, discards
- Dependencies declared inline in script metadata, not in global state
- No global installation required — agent invocation is always idempotent
- Environment isolation prevents dependency conflicts between tool calls

**gh CLI (GitHub CLI):**
- Every subcommand supports `--json fields` for structured output
- `--jq expression` for inline filtering without a separate jq call
- `--template go-template` for custom formatting
- `notifications/tools/list_changed`-style: `gh extension list --json` returns structured extension metadata
- Auth via `gh auth login` (supports headless PKCE flow) or `GITHUB_TOKEN` env var

**Amazon Bedrock AgentCore Payments:**
- Native agent wallet management — agents have spending limits configured at deployment time
- `POST /payments/authorize { amount, recipient, purpose }` → `{ payment_id, status, receipt }`
- Spending governance enforced server-side — agent cannot exceed its authorized limits
- Full audit trail of agent financial actions without human review of each transaction

**Perplexity Sonar API:**
- OpenAI-compatible interface — zero migration cost from OpenAI to Sonar
- Returns pre-synthesized, cited answers — agent gets one clean answer, not 10 links to parse
- `citations` array in response — structured references the agent can include in its output
- Stream-friendly: tokens arrive as they're generated, agent can start processing immediately

---

## Summary: The Agent UX Checklist

A software system is agent-ready when it satisfies all of the following:

### Discovery
- [ ] DNS TXT record at `_mcp.<domain>` with server URL
- [ ] `/.well-known/mcp-server` manifest with capabilities and auth info
- [ ] Published in MCP Registry or npm/pip with `mcp-server` keyword
- [ ] `tools/list` response includes `name`, `title`, `description`, `inputSchema`, `outputSchema` for every tool

### Invocability
- [ ] All inputs specifiable as flags/arguments — no interactive prompts
- [ ] `--help-json` or equivalent outputs machine-readable flag schema
- [ ] Detects non-TTY stdout and suppresses ANSI color codes automatically
- [ ] Respects `NO_COLOR` environment variable
- [ ] Stateless or clearly scoped stateful operations with explicit TTL

### Authentication
- [ ] API keys provisionable via HTTP POST with no email step
- [ ] Machine-readable auth instructions in signup response
- [ ] No browser-based OAuth required for agent-to-service auth
- [ ] Supports `Authorization: Bearer` and/or `X-API-Key` header

### Reliability
- [ ] Every mutating endpoint accepts `Idempotency-Key` header
- [ ] Batch operations return HTTP 207 Multi-Status with per-item success/failure
- [ ] Every error has `retryable: true/false` field
- [ ] Long-running operations are async with status polling endpoint
- [ ] Jobs survive agent crashes and are resumable by job ID

### Output
- [ ] Structured JSON by default (or via `--json` flag)
- [ ] Stable schema with semantic field names
- [ ] Pagination with cursor, `truncated` flag, and `hasMore` field
- [ ] `outputSchema` declared in tool/MCP definition
- [ ] Response headers include `X-Credits-Remaining`, `X-RateLimit-Remaining`

### Economics
- [ ] Per-call pricing available (not subscription-only)
- [ ] `/v1/pricing` endpoint with machine-readable rate structure
- [ ] Spending limits enforceable at key-creation time
- [ ] Optional: x402 or MPP support for trustless per-call payment

---

*These principles are derived from: MCP Specification 2025-11-25 (modelcontextprotocol.io), Anthropic Tool Use documentation (platform.claude.com), OpenAI Function Calling guide (developers.openai.com), Anthropic Engineering blog "Writing Tools for Agents", x402 protocol (Coinbase/Allium), Nevermined agent payments documentation, DNS MCP discovery draft (IETF draft-morrison-mcp-dns-discovery), and empirical analysis of uvx, gh CLI, jq, curl, Exa, Tavily, Firecrawl, and Amazon Bedrock AgentCore.*
