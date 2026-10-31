# HEROS — Agent-Native Infrastructure Toolkit

[![CI](https://github.com/itsoumya-d/HEROS/actions/workflows/ci.yml/badge.svg)](https://github.com/itsoumya-d/HEROS/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![MCP Native](https://img.shields.io/badge/MCP-native-8A2BE2.svg)](https://modelcontextprotocol.io)
[![Zero Runtime](https://img.shields.io/badge/Zero--lang-deterministic-black.svg)](https://github.com/vercel-labs/zero)

Infrastructure and web-action safety primitives rebuilt for autonomous agents. JSON-only output. Machine-readable errors. Idempotent operations. MCP-native contracts. Explicit website actions with auth, approvals, and receipts.

Core CLI primitives are built in [Zero lang](https://github.com/vercel-labs/zero) — deterministic latency, static binaries, no runtime dependencies. The web SDK is dependency-free Node/ESM.

---

## Tools

| Tool | What it does | Status |
|---|---|---|
| [@heros/agentic](packages/agentic/README.md) | Installable web SDK surface for explicit, authenticated, auditable agent actions, Merkle receipts, and score-triggered reflection | v0.2.0 |
| [@heros/mcp](packages/mcp/README.md) | MCP 2025-11-25 bridge, shadow migration gate, and Receipt Inspector | v0.3.0 |
| [forge](forge/README.md) | Agent-safe database migration risk gate - risk-scores schema changes before they run | v0.1.4 |
| [ledger](ledger/README.md) | Agent accounting receipt primitive - register an org and create/list invoices with idempotency keys | v0.1.11 |
| [rlvr](rlvr/README.md) | Verifiable-reasoning post-training primitives: GRPO, Dr.GRPO, DAPO, verifier audit | v0.1.0 core |

---

## Verifiable Reasoning (`rlvr/`)

`HEROS-RLVR` is the post-training layer for verifier-driven reasoning. It
implements group-relative advantages (vanilla GRPO and Dr.GRPO), DAPO
dynamic sampling and token-level loss, a JSON verifier adapter intended for
`forge`, and audit helpers for verifier errors and "miracle steps".

The core is pure Python with no runtime dependencies and 34 CPU tests:

```bash
PYTHONPATH=rlvr/src python -m unittest discover -s rlvr/tests -v
```

Status: algorithmic core implemented and tested. Model training and the
MATH-500/AIME evaluations require GPU access and are not part of this
repository's CI. No accuracy or length-improvement numbers are claimed. See
[rlvr/README.md](rlvr/README.md) for the objective, the three reductions, and
the documented failure boundaries.

---

## Quick Start

### @heros/agentic - Make a Website Safely Agentic

The first web SDK surface is an explicit action registry. Developers choose what agents may do, attach schemas and safety policy, then expose a manifest plus an execute endpoint.

```bash
npm install @heros/agentic
npx @heros/agentic doctor
npx @heros/agentic init my-agentic-site
```

```js
import { createAgenticApp } from "@heros/agentic";

const heros = createAgenticApp({
  name: "shop",
  authorize: ({ context }) => context.apiKey === process.env.AGENT_API_KEY
    ? { principal: "agent:shop" }
    : false
});

heros.action({
  name: "cart.add_item",
  inputSchema: {
    type: "object",
    required: ["sku", "quantity"],
    additionalProperties: false,
    properties: {
      sku: { type: "string", minLength: 3, maxLength: 32, pattern: "^[A-Z0-9-]+$", safeText: true },
      quantity: { type: "integer", minimum: 1, maximum: 10 }
    }
  },
  authRequired: true,
  annotations: { idempotent: true },
  handler: async ({ input }) => ({ added: true, sku: input.sku, quantity: input.quantity })
});

console.log(heros.manifest());
```

Run the local proof:

```bash
npm install file:packages/agentic
node --test packages/agentic/test/*.test.mjs
node --test examples/agentic-site/test/*.test.mjs
node examples/agentic-site/agent-demo.mjs
```

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
  "risk_tier": "SAFE",
  "has_data_loss": false,
  "decision_required": false,
  "schema_version": 1,
  "operations": [{"type":"add_column","table":"users","column":"bio","risk":"safe","data_loss":false,"retryable":true}]
}
```

### ledger - Agent Accounting Receipts

For stateful accounting operations, use the MCP bridge. The Zero binary stays pure-compute while the bridge owns disk state, timestamps, entropy, idempotency lookup, auth, and rate limits.

```json
{"tool":"ledger_register","arguments":{"org_name":"MyOrg"}}
{"tool":"ledger_invoice_create","arguments":{"to":"Vendor Inc","amount":1000.00,"currency":"USD","idempotency_key":"uuid-v4"}}
{"tool":"ledger_invoice_list","arguments":{"limit":100,"offset":0}}
```

---

## MCP Integration

HEROS ships a cross-platform MCP bridge in [`packages/mcp`](packages/mcp/README.md)
that exposes both `forge` and `ledger` from one process over **stdio** and
**Streamable HTTP** (MCP 2025-11-25). It has no bash, jq, awk, or flock
dependency and runs on macOS, Linux, and Windows with Node 22+.

**stdio (Claude Desktop, Cursor, Cline, and other MCP clients):**

```json
{
  "mcpServers": {
    "heros": {
      "command": "node",
      "args": ["/path/to/HEROS/packages/mcp/bin/heros-mcp.mjs", "--stdio"],
      "env": {
        "HEROS_FORGE_BIN": "/path/to/forge",
        "HEROS_LEDGER_BIN": "/path/to/ledger",
        "HEROS_DATA_DIR": "/path/to/heros-data"
      }
    }
  }
}
```

**Streamable HTTP (remote agents, LangGraph services):**

```bash
node packages/mcp/bin/heros-mcp.mjs --http --port 8787 --data-dir ~/.heros
# POST http://127.0.0.1:8787/mcp   (Mcp-Session-Id is returned by initialize)
# GET  http://127.0.0.1:8787/mcp   (text/event-stream)
# GET  http://127.0.0.1:8787/healthz
```

**Python / LangGraph:**

```python
from heros_mcp_client import HerosMcpClient

client = HerosMcpClient(env={"HEROS_DATA_DIR": "/tmp/heros"})
client.initialize()
print(client.list_tools()["result"]["tools"])
client.close()
```

Tool names are unchanged: `forge_analyze`, `ledger_register`,
`ledger_invoice_create`, `ledger_invoice_list`, `ledger_invoice_count`.
Human approval nonces, idempotency, rate limits, HMAC API-key auth, and audit
receipts are enforced by the bridge.

The original bash bridges (`forge/mcp-bridge.sh`, `ledger/mcp-bridge.sh`) remain
available for deployments that still require bash/jq.

For install paths across npm, pnpm, yarn, Linux, and MCP clients, see [docs/distribution.md](docs/distribution.md).
For the full launch checklist, see [docs/launch-checklist.md](docs/launch-checklist.md).

---

## Design Principles

Every tool and SDK surface in HEROS follows the same contract:

1. **JSON on every code path** — including errors. Agents read one output stream, no stdout/stderr merge.
2. **Stable error codes** — `MISSING_FLAG`, `INVALID_INPUT`, `ORG_EXISTS`, etc. Agents branch on codes, not text.
3. **Idempotent writes** — call `register` or `invoice create` on every cold start. Duplicate calls return the existing result.
4. **Self-describing** — `--describe` or `manifest()` emits a complete API contract. Cold LLMs discover the full interface from one invocation.
5. **Human approval gates** — dangerous actions return explicit approval challenges before side effects.
6. **Receipts** — successful actions emit audit records with input hashes, result hashes, principal, approval state, and idempotency metadata.
7. **Merkle audit log** — receipts chain through `prev_hash`/`entry_hash` and verify against a SHA-256 Merkle root with inclusion proofs.
8. **Executed migration evidence** — the MCP boundary runs destructive migrations in an ephemeral SQLite shadow before issuing an approval challenge.
9. **No human prompts** — no "press Y to continue", no interactive flows, no TTY assumptions.

---

## Architecture

HEROS tools share a two-layer architecture:

```
┌─────────────────────────────────────────────┐
│  MCP bridge (Node 22+, packages/mcp)        │
│  • stdio + Streamable HTTP transports       │
│  • JSON-RPC 2.0 session management          │
│  • File I/O, approvals, idempotency         │
│  • SQLite shadow gate + list-wise decision  │
│  • Merkle receipt log + inclusion proofs    │
│  • Rate limiting, API key auth, audit       │
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
- **No-shell-`eval` CI gate** - release checks fail if executable shell scripts introduce `eval`
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
| @heros/agentic v0.2.0 | 33 Node tests (unit, CLI, Merkle, reflection) + 5 demo route tests | Schema validation, auth denial, approval flow, durable stores, idempotency, Merkle inclusion/tamper detection, score-triggered reflection | N/A |
| @heros/mcp v0.3.0 | 46 Node tests including a 289-case adversarial corpus and browser smoke audit | stdio/HTTP, auth, approvals, rate limits, shadow gate, list-wise scoring, receipt inspector | N/A |
| forge v0.1.4 | 33 binary-testable eval cases; 970-line eval log | 239+ cycles (all P2+ resolved) | v0.1.3 |
| ledger v0.1.11 | 25 binary-testable cases plus MCP bridge/auth evals | 239+ cycles (all P2+ resolved) | v0.1.3 |

Binary compilation requires Linux x86-64 (Zero ELF64 backend). Source compiles with the Zero compiler at [zero.vercel.app](https://zero.vercel.app).

---

## Author

Soumya Debnath — [soumyadebnath1619@gmail.com](mailto:soumyadebnath1619@gmail.com)

Built for agent-operated software. The wedge: make websites and high-stakes infrastructure expose safe, explicit action surfaces before autonomous agents reach production systems.
