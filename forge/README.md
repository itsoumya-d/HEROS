# forge — Agent-Safe Database Schema Migration Engine

Built in Zero lang. JSON-only output. No interactive prompts. Designed for the era of autonomous agents.

---

## Quick Start for Agents

```bash
# 1. Discover everything forge can do (cold-start for agents)
forge --describe

# 2. Analyze migration risk — pass schema content inline, using | as line separator
forge analyze \
  --from "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL" \
  --to   "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL|COLUMN bio text NULLABLE"

# 3. Check the risk tier before proceeding
# SAFE, NOTABLE → proceed | MEDIUM, HIGH → review | CRITICAL → stop, alert human

# For file-based workflows, use the forge-analyze wrapper:
forge-analyze --from current.forge --to desired.forge
```

The `--describe` payload is self-contained. A cold LLM can extract every command, flag, input format, output shape, and error code from a single invocation — no documentation fetch required.

---

## What is forge?

Forge is a database schema migration engine built from the ground up for autonomous agents. Unlike traditional migration tools (Flyway, Liquibase, sqitch) that produce human-readable output and assume a human is watching, forge:

- Emits JSON on every code path (including errors)
- Returns structured risk assessments before migrations execute
- Flags data-loss operations with explicit boolean fields
- Provides per-operation guidance text agents can reason over
- Exits 0 even on errors (errors are in the JSON payload)
- Writes all output — including errors — to stdout only (no stdout/stderr split to merge)

The design principle: an orchestrating agent should be able to call forge, read one JSON object from stdout, and make a fully-informed decision — with no human in the loop.

---

## Why Zero Lang?

Zero is a systems programming language designed for agent-native software. Key properties for forge:

- **No GC**: deterministic latency — no pauses during migration analysis
- **Capability model**: I/O only flows through an explicit `World` parameter, making forge's I/O surface completely inspectable and auditable
- **Type-safe**: shapes, enums, and spans prevent silent data corruption that plagues Python migration scripts
- **Static binary**: ships as a single ELF64 musl-linked binary with no runtime dependencies — drop it in a container and run it
- **Small**: forge binary is ~35.1 KiB (under 19 KB) — security hardened: input validation, size limits, injection prevention

Zero is to agent-native software what Rust was to systems software: a language that makes the right thing the default.

---

## Forge Schema Format

Forge uses a pipe-separated text format. The `|` separator allows multi-line schemas to be passed as a single shell argument without quoting complexity or heredoc syntax.

**Tokens:**
- `TABLE <name>` — declare a table
- `COLUMN <name> <type> <NOT_NULL|NULLABLE>` — declare a column
- Optional modifiers: `PRIMARY_KEY`, `DEFAULT`

**Example:**
```
TABLE users|COLUMN id serial NOT_NULL PRIMARY_KEY|COLUMN email text NOT_NULL|COLUMN bio text NULLABLE
TABLE orders|COLUMN id serial NOT_NULL PRIMARY_KEY|COLUMN user_id integer NOT_NULL|COLUMN created_at timestamp NOT_NULL DEFAULT
```

Pass the schema string directly as a `--from` or `--to` argument. For file-based workflows, store the schema in a `.forge` file and use the `forge-analyze` wrapper, which reads the file and converts it to inline format automatically.

---

## Output Format

All forge commands return a single JSON object to stdout.

**`forge --version`:**
```json
{"name":"forge","version":"0.1.0","schema_version":1}
```

**`forge analyze` (safe migration):**
```json
{
  "schema_version": 1,
  "risk_tier": "NOTABLE",
  "risk_score": 0.25,
  "retryable": true,
  "has_data_loss": false,
  "decision_required": false,
  "operations": [
    {
      "type": "add_table",
      "table": "orders",
      "risk": "safe",
      "data_loss": false,
      "reversible": true
    },
    {
      "type": "add_column",
      "table": "users",
      "column": "bio",
      "nullable": true,
      "risk": "notable",
      "data_loss": false,
      "reversible": true,
      "estimated_lock_ms": 0,
      "agent_guidance": "Nullable column addition. Safe on most engines. No data loss. Reversible via DROP COLUMN."
    }
  ]
}
```

**`forge analyze` (critical migration):**
```json
{
  "schema_version": 1,
  "risk_tier": "CRITICAL",
  "risk_score": 1.0,
  "retryable": false,
  "has_data_loss": true,
  "decision_required": true,
  "operations": [
    {
      "type": "drop_table",
      "table": "posts",
      "risk": "critical",
      "data_loss": true,
      "reversible": false,
      "estimated_lock_ms": -1,
      "agent_guidance": "DROP TABLE is irreversible and destroys all row data. Do not proceed without explicit human approval and a verified backup."
    }
  ]
}
```

**`forge --describe` (agent discovery, excerpt):**
```json
{
  "name": "forge",
  "version": "0.1.0",
  "schema_version": 1,
  "description": "Agent-native database schema migration analyzer. Emits structured JSON on every code path.",
  "commands": [
    {
      "name": "analyze",
      "description": "Compare two schema snapshots and return a risk-scored migration plan.",
      "flags": [
        {
          "name": "--from",
          "type": "string",
          "required": true,
          "description": "Source schema. Use | as newline separator for multi-line schemas in shell."
        },
        {
          "name": "--to",
          "type": "string",
          "required": true,
          "description": "Target schema."
        }
      ]
    }
  ],
  "forge_schema_format": {
    "tokens": ["TABLE <name>", "COLUMN <name> <type> <NOT_NULL|NULLABLE>"],
    "separator": "|",
    "example": "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL"
  },
  "errors": [
    {"code": "FILE_NOT_FOUND", "retryable": false},
    {"code": "INVALID_SCHEMA", "retryable": false},
    {"code": "SCHEMA_TOO_LARGE", "retryable": false},
    {"code": "IO_ERROR", "retryable": true},
    {"code": "UNKNOWN_COMMAND", "retryable": false}
  ],
  "mcp": {
    "supported": true,
    "transport": "stdio",
    "manifest": "mcp-manifest.json"
  }
}
```

---

## Architecture

The full implementation is structured across six Zero source files:

| File | Role |
|---|---|
| `src/types.0` | Shared types: `Schema`, `MigOp`, `Report`, `RiskLevel` enum |
| `src/schema.0` | Schema parser with pool-based string storage |
| `src/diff.0` | Diff engine: 3-pass (drop tables, add tables, compare columns) |
| `src/output.0` | JSON serialization helpers for all output paths |
| `src/describe.0` | Agent discovery schema emitter |
| `src/main.0` | CLI dispatch — routes flags to commands, handles all error paths |

**Note on v0.1.0 binary:** The shipped forge binary (`forge_mini.0`) is optimized for Zero v0.1.1's direct ELF64 backend, which currently supports programs with inline main-level logic. The full modular implementation (`schema.0`, `diff.0`, etc.) type-checks cleanly with `zero check .` and will be the production binary when Zero v0.2+ ships full backend support.

---

## MCP Integration

Forge ships an MCP manifest (`mcp-manifest.json`) and a bash bridge (`mcp-bridge.sh`) for use as a tool by Claude, Cursor, and any MCP-compatible orchestrator.

**Why a bridge?** Zero v0.1.x has no stdin reading API (`world.in` not yet available). `mcp-bridge.sh` owns the JSON-RPC 2.0 session lifecycle (initialize, tools/list, tools/call, ping) and delegates tool calls to the `forge` binary as a subprocess. The bridge also implements rate limiting and security hardening. When Zero adds stdin support, the bridge will be replaced by a native Zero MCP server.

**Requirements:** `jq >= 1.6`, `forge` binary in PATH or same directory as `mcp-bridge.sh`.

**Add to Claude Code (`~/.claude/settings.json`):**
```json
{
  "mcpServers": {
    "forge": {
      "command": "/path/to/forge/mcp-bridge.sh",
      "args": [],
      "transport": "stdio"
    }
  }
}
```

**Add to Cursor (`.cursor/mcp.json`):**
```json
{
  "mcpServers": {
    "forge": {
      "command": "/path/to/forge/mcp-bridge.sh",
      "args": []
    }
  }
}
```

Once registered, agents can call `forge_analyze` as a tool with `from_schema` and `to_schema` string parameters and receive a structured risk report directly in tool output — no shell invocation required.

**MCP rate limits:** `forge_analyze` is rate-limited at 200 calls/hour per IP and 500 calls/hour per org. Rate limit state is in the bridge process memory (resets on reconnect). Every successful response includes `_rate_limit.remaining` and `_rate_limit.reset_at` for proactive throttling. When exceeded, returns `RATE_LIMITED` with `retry_after_seconds` (machine-readable, no text parsing needed).

**Schema safety in MCP mode:** The bridge validates that `from_schema` and `to_schema` do not contain pipe characters (`|`). Pipe is forge's internal line separator — a `|` in the raw MCP argument would inject fake TABLE/COLUMN lines into the analysis. The bridge rejects such inputs with `INVALID_INPUT` before any parsing (RT-43).

**Agent quickstart via MCP:**
1. Read `mcp-manifest.json` for tool input/output shapes (or call `forge --describe` for the full binary API)
2. Call `forge_analyze` with the current and desired schema before any migration (use newlines as line separators in the schema strings — the bridge converts to forge's `|` format)
3. Gate on `risk_tier` and `has_data_loss` before proceeding
4. If `decision_required: true`, do NOT auto-proceed — surface to a human principal
5. Check each operation's `agent_guidance` for per-step safe-to-execute advice

---

## Risk Tier Reference

| Tier | Score | Meaning | Agent Decision |
|---|---|---|---|
| `SAFE` | 0.0 | Fully additive, no lock, instant | Proceed automatically |
| `NOTABLE` | 0.25 | Additive but may scan large tables | Proceed; log for review |
| `MEDIUM` | 0.5 | Structural change, no data loss | Review before proceeding |
| `HIGH` | 0.75 | Significant lock time or type coercion | Require human approval |
| `CRITICAL` | 1.0 | Data loss, irreversible | Stop; alert human; verify backup |

**Examples by tier:**

- `SAFE`: Adding a new table with no foreign key constraints
- `NOTABLE`: Adding a nullable column (may require table scan on some engines)
- `MEDIUM`: Adding a NOT NULL column with a default (table rewrite on some engines)
- `HIGH`: Changing a column type (requires data coercion, possible lock)
- `CRITICAL`: Dropping a table or column (destroys data, irreversible)

`has_data_loss` is the fast-path signal. Agents do not need to iterate `operations` to answer "will anything be lost?" — the top-level boolean is authoritative.

`decision_required` is the explicit halt signal. When `true`, agents **must not auto-proceed** — human approval and backup verification are required before executing the migration. This field exists specifically to counter the agent-era risk of excessive autonomous agency (OWASP LLM06).

---

## Error Codes

All errors are returned as structured JSON to stdout:

```json
{
  "error": {
    "code": "UNKNOWN_COMMAND",
    "message": "Missing --from flag. Use forge --describe for usage.",
    "retryable": false
  }
}
```

| Code | Retryable | Meaning |
|---|---|---|
| `FILE_NOT_FOUND` | false | Schema file path does not exist |
| `INVALID_SCHEMA` | false | Schema string failed to parse |
| `SCHEMA_TOO_LARGE` | false | Schema exceeds the 64 KiB limit |
| `IO_ERROR` | true | Filesystem or pipe I/O failure |
| `UNKNOWN_COMMAND` | false | Unrecognized command or missing required flag |

`retryable: false` means the error is a caller error — the agent should surface it rather than start a backoff loop. `retryable: true` means a transient failure — safe to retry with exponential backoff.

---

## `schema_version` Field

Every forge response includes `"schema_version": 1`. When forge increments this field, agents that cached the `--describe` payload know to re-fetch it. This allows forge to evolve its output contract without agents silently misinterpreting new fields.

---

## Security

forge is designed with the assumption that every caller is untrusted and every output is a potential attack surface against the calling LLM.

**Input validation hardening (v0.1.1):**
- `--request-id` values are validated before echo — values containing `"`, `\`, or control characters return `INVALID_INPUT` instead of injecting into JSON output
- Schema content (`--from`, `--to`) is charset-validated — characters outside `[A-Za-z0-9_ |\t\n\r]` return `INVALID_SCHEMA`, preventing prompt injection via table/column names
- Schema size is hard-capped at 64 KiB per arg to prevent DoS via O(N) parse loops

**Column rename detection (v0.1.3 — V9 fix):**
- Column diff upgraded from count-based to hash-set comparison
- Column names are hashed with their containing table hash as seed — `users.id` and `orders.id` have different hashes, preventing cross-table column confusion
- Renames within preserved tables (`email → email_address`) now correctly report CRITICAL instead of false SAFE
- Only columns in preserved tables (present in both schemas) are indexed — dropped table columns don't inflate the diff count

**Upgrade note for v0.1.2 users:** Compound migrations analyzed by v0.1.2 or earlier may have had incomplete operations lists — a column rename hidden behind a table rename was silently absent from the output. Re-audit any compound migration approved under v0.1.2 or earlier before executing it in production.

**Bridge security hardening (mcp-bridge.sh):**
- RT-43 — Pipe injection guard: schemas containing `|` rejected before newline→pipe conversion
- RT-37 — Exit propagation: handler failures emit error response, bridge continues
- RT-38 — Non-object JSON rejected with `-32600 Invalid Request`
- RT-40 — `isError: true` set when forge returns an `error_code` field
- RT-41 — Signal handling: `trap 'exit 0' TERM INT` prevents mid-write corruption
- RT-42 — `LANG=C.UTF-8` prevents locale-dependent jq behavior
- V7e — Re-initialization rejected with `-32002`
- RT-47 — All 4 cosign signatures (binary + manifest for both tools) verified in CI before upload

**Rate limiting (mcp-bridge.sh):**
- Token bucket algorithm: 200/hour per-IP, 500/hour per-org for `forge_analyze`
- `RATE_LIMITED` error: `retry_after_seconds`, `limit_type`, `limit_tool`, `retryable:true`
- `_rate_limit` field in all success responses: `remaining`, `reset_at`, `limit`, `window`
- Operator overrides: `FORGE_RATE_ANALYZE_IP`, `FORGE_RATE_ANALYZE_ORG` (env vars, 10× ceiling)
- State in bridge process memory (resets on reconnect)

**Output discipline:**
- No user-supplied strings are echoed into output without validation
- No ANSI codes on any output path
- No internal paths, stack traces, or data from other callers in error messages
- Table/column names in operation output restricted to `[a-zA-Z0-9_]` (isIdChar), preventing prompt injection via schema identifiers

**Threat model:** `docs/threat-model.md` — full attack surface analysis (V1–V40) with per-vector status. OWASP Agentic Top 10 (ASI01–ASI10) fully mapped.

---

## Binary Properties

| Property | Value |
|---|---|
| Size | ~35.1 KiB (v0.1.2); v0.1.3 larger due to 4×256-element column hash arrays |
| Format | ELF64 x86-64 |
| ABI | musl (static, no dynamic deps) |
| Built with | Zero lang v0.1.1 direct ELF64 backend |
| Entry | Direct syscall layer — no libc startup |

---

## Author

Soumya Debnath — [soumyadebnath1619@gmail.com](mailto:soumyadebnath1619@gmail.com)

forge v0.1.0 — Built for the YC RFS "Software for Agents" category.
