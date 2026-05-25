# HEROS — Agent-Native Infrastructure Toolkit

Infrastructure primitives rebuilt for autonomous agents. JSON-only output. Machine-readable errors. Idempotent operations. MCP-native.

Built in [Zero lang](https://github.com/vercel-labs/zero) — deterministic latency, static binaries, no runtime dependencies.

---

## Tools

| Tool | What it does | Status |
|---|---|---|
| [forge](forge/README.md) | Database schema migration engine — risk-scores schema changes before they run | v0.1.4 |
| [ledger](ledger/README.md) | Double-entry accounting — create invoices and register orgs with idempotency keys | v0.1.11 |

---

## Quick Start

### forge — Schema Migration Risk Analysis

```bash
# Install: download the binary (Linux x86-64)
curl -L https://github.com/soumyadebnath/heros/releases/latest/download/forge -o forge && chmod +x forge

# Analyze migration risk
forge analyze \
  --from "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL" \
  --to   "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL|COLUMN bio text NULLABLE"
```

Output:
```json
{
  "risk_tier": "SAFE",
  "has_data_loss": false,
  "decision_required": false,
  "schema_version": 1,
  "operations": [{"type":"add_column","table":"users","column":"bio","risk":"safe","data_loss":false,"retryable":true}]
}
```

### ledger — Agent Accounting

```bash
# Install: download the binary (Linux x86-64)
curl -L https://github.com/soumyadebnath/heros/releases/latest/download/ledger -o ledger && chmod +x ledger

# Register your org (idempotent)
ledger register --org-name "MyOrg"

# Create an invoice
ledger invoice create --to "Vendor Inc" --amount "1000.00" --currency USD --idempotency-key "uuid-v4"
```

---

## MCP Integration

Both tools ship as MCP servers (stdio transport). Add to Claude Code or any MCP-compatible orchestrator:

**`~/.claude/settings.json`:**
```json
{
  "mcpServers": {
    "forge": {
      "command": "/path/to/forge/mcp-bridge.sh",
      "args": [],
      "transport": "stdio"
    },
    "ledger": {
      "command": "/path/to/ledger/mcp-bridge.sh",
      "args": [],
      "transport": "stdio"
    }
  }
}
```

Both bridges implement the MCP 2025-11-25 protocol. Run `--describe` on either binary for the full self-describing API schema — no documentation fetch needed.

---

## Design Principles

Every tool in HEROS follows the same contract:

1. **JSON on every code path** — including errors. Agents read one output stream, no stdout/stderr merge.
2. **Stable error codes** — `MISSING_FLAG`, `INVALID_INPUT`, `ORG_EXISTS`, etc. Agents branch on codes, not text.
3. **Idempotent writes** — call `register` or `invoice create` on every cold start. Duplicate calls return the existing result.
4. **Self-describing** — `--describe` emits a complete API contract. Cold LLMs discover the full interface from one invocation.
5. **Exit 0 always** — errors live in the JSON payload. Agents never need to inspect exit codes.
6. **No human prompts** — no "press Y to continue", no interactive flows, no TTY assumptions.

---

## Architecture

HEROS tools share a two-layer architecture:

```
┌─────────────────────────────────────────────┐
│  MCP Bridge (bash)                          │
│  • JSON-RPC 2.0 session management          │
│  • File I/O (read/write state files)        │
│  • Rate limiting, idempotency               │
│  • API key auth (optional)                  │
└─────────────────┬───────────────────────────┘
                  │ CLI args (validated, array-constructed)
┌─────────────────▼───────────────────────────┐
│  Zero Binary (pure function)                │
│  • Args in → JSON out → exit                │
│  • No file I/O (Zero v0.1.x constraint)     │
│  • Input validation + output generation     │
│  • Deterministic, no GC, ~7-35 KiB         │
└─────────────────────────────────────────────┘
```

The bridge owns I/O and session state. The binary owns business logic. This separation makes the security surface fully auditable: the binary has no network access, no file access, and no environment variable access beyond what Zero's capability model allows.

---

## Security

- **No eval** — all shell argument construction uses bash arrays
- **jq extraction only** — user input never concatenated into shell commands (RT-33)
- **Argument injection hardened** — binary receives each flag as a separate array element
- **Idempotency keys** — validated for control chars to prevent idempotency bypass
- **Concurrent access** — exclusive file locks on write paths (flock) prevent duplicate records under parallel bridge processes
- **Atomic writes** — org data written via temp file + mv to prevent partial-write corruption
- OWASP Agentic Top 10 (ASI01–ASI10) audited; see `docs/threat-model.md`

---

## Status

| Component | Tests | Security Cycles | Zero Version |
|---|---|---|---|
| forge v0.1.4 | 38 eval_log tests; 33 binary cases in CI | 239+ cycles (all P2+ resolved) | v0.1.3 |
| ledger v0.1.11 | 25 binary cases in CI | 239+ cycles (all P2+ resolved) | v0.1.3 |

Binary compilation requires Linux x86-64 (Zero ELF64 backend). Source compiles with the Zero compiler at [zero.vercel.app](https://zero.vercel.app).

---

## Author

Soumya Debnath — [soumyadebnath1619@gmail.com](mailto:soumyadebnath1619@gmail.com)

Built for the YC RFS "Software for Agents" category. The premise: every software category needs to be rebuilt for agents as the primary user.
