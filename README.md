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
| [@heros/agentic](packages/agentic/README.md) | Installable web SDK surface for explicit, authenticated, auditable agent actions | v0.1.0 |
| [forge](forge/README.md) | Agent-safe database migration risk gate - risk-scores schema changes before they run | v0.1.4 |
| [ledger](ledger/README.md) | Agent accounting receipt primitive - register an org and create/list invoices with idempotency keys | v0.1.11 |

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

Both tools ship as MCP servers (stdio transport). Add to any MCP-compatible orchestrator:

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

For the web SDK demo path, see [docs/agentic-web-sdk-demo.md](docs/agentic-web-sdk-demo.md).
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
7. **No human prompts** — no "press Y to continue", no interactive flows, no TTY assumptions.

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
| @heros/agentic v0.1.0 | 11 Node unit tests, 5 demo route tests, plus `examples/agentic-site/agent-demo.mjs` integration proof | Current proof covers schema validation, auth denial, approval token flow, durable file stores, idempotency replay/conflict, receipts, HTTP route errors, and demo action flow | N/A |
| forge v0.1.4 | 38 eval_log tests; 33 binary-testable cases covered by release CI when Zero compiler variables are configured | 239+ cycles (all P2+ resolved) | v0.1.3 |
| ledger v0.1.11 | 25 binary-testable cases plus MCP bridge/auth evals covered by release CI when Zero compiler variables are configured | 239+ cycles (all P2+ resolved) | v0.1.3 |

Binary compilation requires Linux x86-64 (Zero ELF64 backend). Source compiles with the Zero compiler at [zero.vercel.app](https://zero.vercel.app).

---

## Author

Soumya Debnath — [soumyadebnath1619@gmail.com](mailto:soumyadebnath1619@gmail.com)

Built for agent-operated software. The wedge: make websites and high-stakes infrastructure expose safe, explicit action surfaces before autonomous agents reach production systems.
