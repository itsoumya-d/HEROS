# Getting Started with HEROS

Get forge and ledger running in Claude Code in under 5 minutes.

---

## Prerequisites

- Claude Code (or any MCP-compatible client)
- Linux x86-64 (for binaries) OR Docker
- `jq >= 1.6` in PATH
- `bash >= 4.0`

---

## Step 1: Download binaries

```bash
# Create a directory for HEROS
mkdir -p ~/heros && cd ~/heros

# Download forge (schema migration engine)
curl -L https://github.com/soumyadebnath/heros/releases/latest/download/forge-linux-x64.bin \
  -o forge && chmod +x forge

# Download ledger (agent accounting)
curl -L https://github.com/soumyadebnath/heros/releases/latest/download/ledger-linux-x64.bin \
  -o ledger && chmod +x ledger

# Download MCP bridges and manifests
curl -L https://raw.githubusercontent.com/soumyadebnath/heros/main/forge/mcp-bridge.sh \
  -o forge-bridge.sh && chmod +x forge-bridge.sh
curl -L https://raw.githubusercontent.com/soumyadebnath/heros/main/forge/mcp-manifest.json \
  -o forge-manifest.json

curl -L https://raw.githubusercontent.com/soumyadebnath/heros/main/ledger/mcp-bridge.sh \
  -o ledger-bridge.sh && chmod +x ledger-bridge.sh
curl -L https://raw.githubusercontent.com/soumyadebnath/heros/main/ledger/mcp-manifest.json \
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

## Step 3: Add to Claude Code

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

Restart Claude Code. Both tools should appear in the MCP tools list.

---

## Step 4: Test forge

In Claude Code, ask:

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

```bash
# Register your org (idempotent — safe to run every startup)
./ledger register --org-name "MyOrg"

# Create an invoice
./ledger invoice create \
  --to "Vendor Inc" \
  --amount "1000.00" \
  --currency USD \
  --idempotency-key "$(uuidgen)"

# List all invoices
./ledger invoice list
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
| `HEROS_FORGE_ANALYZE_RATE` | forge | Rate limit for forge_analyze (calls/hour) | 3600 |
| `HEROS_FORGE_ANALYZE_BURST` | forge | Burst capacity for forge_analyze | 20 |

---

## Troubleshooting

**`EXEC_FAILED: ledger binary produced no output`**  
→ Binary not found. Check `LEDGER_BIN` or ensure `ledger` is in PATH.

**`STORE_READ_FAILED`**  
→ Disk I/O error. Check `HEROS_DATA_DIR` is writable.

**`NO_ORG_REGISTERED`**  
→ Call `ledger register --org-name "YourOrg"` first.

**`python3 not found`**  
→ Only needed when `HEROS_API_KEY` is set. Unset `HEROS_API_KEY` for anonymous mode, or install python3.

**forge: `INVALID_INPUT: from_schema exceeds 64 KiB`**  
→ Schema is too large. Split into multiple calls by table group.

---

## Verify binary integrity (optional)

```bash
# Verify cosign signature (requires cosign CLI)
cosign verify-blob \
  --certificate-identity-regexp https://github.com/soumyadebnath/heros \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --signature forge-linux-x64.bin.sig \
  forge-linux-x64.bin

# Check SHA-256 against published checksum
sha256sum forge-linux-x64.bin
# Compare against: https://github.com/soumyadebnath/heros/releases/latest/download/forge-linux-x64.bin.sha256
```
