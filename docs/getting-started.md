# Getting Started with HEROS

Get HEROS running locally. The web SDK works with Node.js. The `forge` and `ledger` binaries require Linux x86-64 release artifacts or a Linux build environment.

---

## Prerequisites

- Node.js 20+ for `@heros/agentic`
- Any MCP-compatible client for `forge` and `ledger`
- Linux x86-64 or Docker for binaries
- `jq >= 1.6` in PATH for bridges
- `bash >= 4.0` for bridge evals

---

## Web SDK: Make A Website Agent-Ready

```bash
npm install @heros/agentic
npx @heros/agentic doctor
npx @heros/agentic init my-agentic-site
```

```js
import { createAgenticApp, createFileReceiptStore } from "@heros/agentic";

const heros = createAgenticApp({
  name: "shop",
  receiptStore: createFileReceiptStore({ path: ".heros/receipts.json" }),
  authorize: ({ context }) => context.apiKey === process.env.AGENT_API_KEY
    ? { principal: "agent:shop" }
    : false
});
```

For repository development, use the local workspace package and demo checks:

```bash
npm install file:packages/agentic
npm run test:agentic
npm run test:agentic-site
npm run demo:agentic
```

---

## Step 1: Download binaries

```bash
# Create a directory for HEROS
mkdir -p ~/heros && cd ~/heros

# Download forge (schema migration engine)
curl -L https://github.com/itsoumya-d/HEROS/releases/latest/download/forge-linux-x64.bin \
  -o forge && chmod +x forge

# Download ledger (agent accounting)
curl -L https://github.com/itsoumya-d/HEROS/releases/latest/download/ledger-linux-x64.bin \
  -o ledger && chmod +x ledger

# Download MCP bridges and manifests
curl -L https://raw.githubusercontent.com/itsoumya-d/HEROS/main/forge/mcp-bridge.sh \
  -o forge-bridge.sh && chmod +x forge-bridge.sh
curl -L https://raw.githubusercontent.com/itsoumya-d/HEROS/main/forge/mcp-manifest.json \
  -o forge-manifest.json

curl -L https://raw.githubusercontent.com/itsoumya-d/HEROS/main/ledger/mcp-bridge.sh \
  -o ledger-bridge.sh && chmod +x ledger-bridge.sh
curl -L https://raw.githubusercontent.com/itsoumya-d/HEROS/main/ledger/mcp-manifest.json \
  -o ledger-manifest.json
```

---

## Step 2: Verify installation

```bash
# forge: self-describing API (cold-agent discovery)
./forge --describe

# ledger: self-describing API
./ledger --describe

# Expected: JSON object with "tool" field and complete command/flag definitions
```

---

## Step 3: Add To An MCP Client

Edit `~/.claude/settings.json` (create if it doesn't exist):

```json
{
  "mcpServers": {
    "forge": {
      "command": "/home/YOUR_USER/heros/forge-bridge.sh",
      "args": [],
      "transport": "stdio",
      "env": {
        "FORGE_BIN": "/home/YOUR_USER/heros/forge",
        "HEROS_DATA_DIR": "/home/YOUR_USER/heros/data"
      }
    },
    "ledger": {
      "command": "/home/YOUR_USER/heros/ledger-bridge.sh",
      "args": [],
      "transport": "stdio",
      "env": {
        "LEDGER_BIN": "/home/YOUR_USER/heros/ledger",
        "HEROS_DATA_DIR": "/home/YOUR_USER/heros/data"
      }
    }
  }
}
```

```bash
# Create the data directory
mkdir -p ~/heros/data
```

Restart your MCP client. Both tools should appear in the MCP tools list.

---

## Step 4: Test forge

In your MCP client, ask:

> Analyze this schema migration for risk: adding a NOT NULL column `status` to the `users` table.

Or directly via CLI:

```bash
./forge analyze \
  --from "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL" \
  --to   "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL|COLUMN status text NOT_NULL"
```

Expected output:
```json
{
  "risk_tier": "MEDIUM",
  "has_data_loss": false,
  "decision_required": false,
  "operations": [
    {
      "type": "add_column",
      "risk": "medium",
      "agent_guidance": "Column added with NOT_NULL constraint. Requires backfill migration..."
    }
  ]
}
```

---

## Step 5: Test ledger

The Zero ledger binary is pure compute and does not own disk state. For agent-facing stateful operations, use the MCP bridge tools; the bridge supplies entropy/timestamps, persists org and invoice state, and implements list/count.

```json
{"tool":"ledger_register","arguments":{"org_name":"MyOrg"}}
{"tool":"ledger_invoice_create","arguments":{"to":"Vendor Inc","amount":1000.00,"currency":"USD","idempotency_key":"uuid-v4-here"}}
{"tool":"ledger_invoice_list","arguments":{"limit":100,"offset":0}}
```

---

## Risk tier reference

| Tier | Meaning | Agent action |
|---|---|---|
| `SAFE` | No risk | Proceed automatically |
| `NOTABLE` | Minor impact (brief lock, no data loss) | Log and proceed |
| `MEDIUM` | Requires care (NOT NULL backfill) | Plan backfill migration |
| `HIGH` | Significant lock or constraint (FK, PRIMARY KEY, set NOT NULL) | Require human review |
| `CRITICAL` | Irreversible data loss | Hard stop — require `human_acknowledgment_token` |

When `decision_required: true`, the agent MUST obtain a `human_acknowledgment_token` before proceeding. forge will issue a nonce on first call; present it on the second call after human sign-off.

---

## Docker (alternative)

```dockerfile
FROM alpine:3.19
RUN apk add --no-cache bash jq

COPY forge ledger forge-bridge.sh ledger-bridge.sh /usr/local/bin/
COPY forge-manifest.json /etc/heros/forge-manifest.json
COPY ledger-manifest.json /etc/heros/ledger-manifest.json

ENV HEROS_DATA_DIR=/data
VOLUME ["/data"]
```

---

## Environment variables

| Variable | Tool | Description | Default |
|---|---|---|---|
| `HEROS_DATA_DIR` | Both | Directory for state files (`.ledger-data`, `.ledger-invoices`) | Current working directory |
| `HEROS_API_KEY` | Both | Enable API key authentication (`heros_<scope>_<key_id>_<secret>`) | Unset (anonymous) |
| `HEROS_HMAC_SEED` | Both | HMAC seed for key verification (min 32 chars). Generate: `openssl rand -hex 32` | Required when `HEROS_API_KEY` set |
| `FORGE_BIN` | forge | Path to forge binary | `forge` (must be in PATH) |
| `LEDGER_BIN` | ledger | Path to ledger binary | `ledger` (must be in PATH) |
| `FORGE_RATE_ANALYZE_IP` | forge | Per-session IP bucket for forge_analyze (calls/hour) | 200 |
| `FORGE_RATE_ANALYZE_ORG` | forge | Per-session org bucket for forge_analyze when auth is enabled (calls/hour) | 500 |

---

## Troubleshooting

**`EXEC_FAILED: ledger binary produced no output`**  
→ Binary not found. Check `LEDGER_BIN` or ensure `ledger` is in PATH.

**`STORE_READ_FAILED`**  
→ Disk I/O error. Check `HEROS_DATA_DIR` is writable.

**`NO_ORG_REGISTERED`**  
→ Run `ledger_register` first.

**`python3 not found`**  
→ Only needed when `HEROS_API_KEY` is set. Unset `HEROS_API_KEY` for anonymous mode, or install python3.

**forge: `INVALID_INPUT: from_schema exceeds 64 KiB`**  
→ Schema is too large. Split into multiple calls by table group.

---

## Verify binary integrity (optional)

```bash
# Verify cosign signature (requires cosign CLI)
cosign verify-blob \
  --certificate-identity-regexp https://github.com/itsoumya-d/HEROS \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --signature forge-linux-x64.bin.sig \
  forge-linux-x64.bin

# Check SHA-256 against published checksum
sha256sum forge-linux-x64.bin
# Compare against: https://github.com/itsoumya-d/HEROS/releases/latest/download/forge-linux-x64.bin.sha256
```
