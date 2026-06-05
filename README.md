# HEROS — Agent Operations Stack

Infrastructure rebuilt for autonomous agents. Pre-execution risk gates. Idempotent writes. Tamper-evident audit trails. MCP-native.

> *"Rebuild every major software category for a world where the next trillion users are not people but AI agents."*
> — YC Requests for Startups, Summer 2026

---

## Tools

| Tool | What it does | Status |
|---|---|---|
| [forge](forge/README.md) | Database migration safety — risk-scores any schema change before it runs; blocks data-loss ops without human approval | v0.1.4 |
| [ledger](ledger/README.md) | Agent accounting — idempotent invoices and org registration, HMAC auth, stable JSON error codes | v0.1.11 |
| [guardian](guardian/) | Universal safety oracle — pre-execution risk gate for file system, shell, network, infra, code execution, and data access | v0.1.0 |
| [vault](vault/) | Agent-native credential storage — named secrets with scoped access and access audit log | v0.1.0 |
| [audit](audit/) | Tamper-evident compliance log — append-only chain-hashed JSONL; `audit_verify` detects any alteration | v0.1.0 |

---

## Quick Start

### forge — Schema Migration Risk Analysis

```bash
# Install: download the binary (Linux x86-64)
curl -L https://github.com/itsoumya-d/HEROS/releases/latest/download/forge-linux-x64.bin -o forge && chmod +x forge

# Analyze migration risk
forge analyze \
  --from "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL" \
  --to   "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL|COLUMN bio text NULLABLE"
```

Output:
```json
{
  "schema_version": 1,
  "_forge_version": "0.1.4",
  "risk_tier": "NOTABLE",
  "risk_score": 0.25,
  "retryable": true,
  "has_data_loss": false,
  "decision_required": false,
  "operations": [{"type":"add_column","risk":"notable","data_loss":false,"estimated_lock_ms":0,"retryable":true,"agent_guidance":"New nullable column(s) added. Safe for most cases — no impact on existing rows or queries."}]
}
```

### ledger — Agent Accounting

```bash
# Install: download the binary (Linux x86-64)
curl -L https://github.com/itsoumya-d/HEROS/releases/latest/download/ledger-linux-x64.bin -o ledger && chmod +x ledger

# Use via the MCP bridge (recommended) — bridge supplies required --entropy / --timestamp
# Direct binary: ledger register --org-name "MyOrg" --entropy $(openssl rand -hex 4) --timestamp $(date +%s)
# See docs/getting-started.md for the MCP bridge setup
```

> See [`docs/demo-transcript.md`](docs/demo-transcript.md) for a full 60-second walkthrough with
> real outputs (SAFE/CRITICAL forge analyses + idempotent ledger writes), every line reproduced
> from the CI-gated eval suite.

---

## MCP Integration

All tools ship as MCP servers (stdio transport). Add to Claude Code or any MCP-compatible orchestrator:

**`~/.claude/settings.json`:**
```json
{
  "mcpServers": {
    "forge":    { "command": "/path/to/forge/mcp-bridge.sh",    "args": [], "transport": "stdio" },
    "ledger":   { "command": "/path/to/ledger/mcp-bridge.sh",   "args": [], "transport": "stdio" },
    "guardian": { "command": "/path/to/guardian/mcp-bridge.sh", "args": [], "transport": "stdio" },
    "vault":    { "command": "/path/to/vault/mcp-bridge.sh",    "args": [], "transport": "stdio" },
    "audit":    { "command": "/path/to/audit/mcp-bridge.sh",    "args": [], "transport": "stdio" }
  }
}
```

All bridges implement MCP 2025-11-25. Run `--describe` on forge or ledger for the full self-describing API schema — no documentation fetch needed.

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

| Component | Tests | Security | Zero Version |
|---|---|---|---|
| forge v0.1.4 | 33 binary JSONL + 13 bridge (BE) + 10 auth (FA) = 56 cases | OWASP Agentic Top-10 audited; P0–P2 findings resolved | v0.1.3 |
| ledger v0.1.11 | 25 binary JSONL + 11 auth (BA) + 9 bridge-auth (AE) = 45 cases | HMAC auth + OWASP audit; P0–P2 findings resolved | v0.1.3 |
| guardian v0.1.0 | 35 CI-gated eval cases | Same approval-nonce protocol as forge | pure bash |
| vault v0.1.0 | 25 CI-gated eval cases | V39 approval nonce for delete; scoped access log | pure bash |
| audit v0.1.0 | 29 CI-gated eval cases | Chain-hashed tamper detection; flock-protected appends | pure bash |

Security process is documented in [`docs/threat-model.md`](docs/threat-model.md) and [`docs/redteam-cycle1.md`](docs/redteam-cycle1.md). No `eval` in any shell path.

Binary compilation requires Linux x86-64 (Zero ELF64 backend). Source compiles with the Zero compiler at [zero.vercel.app](https://zero.vercel.app).

---

## Author

Soumya Debnath — [soumyadebnath1619@gmail.com](mailto:soumyadebnath1619@gmail.com)

Built for the YC RFS "Software for Agents" category. The premise: every software category needs to be rebuilt for agents as the primary user.
