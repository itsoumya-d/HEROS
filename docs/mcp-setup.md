# MCP Setup Guide

Configure forge and ledger as MCP servers in your AI agent client. Setup takes under 5 minutes.

---

## Claude Code

Edit `~/.claude/settings.json` (or `%APPDATA%\Claude\settings.json` on Windows):

```json
{
  "mcpServers": {
    "forge": {
      "command": "/path/to/forge-bridge.sh",
      "args": [],
      "transport": "stdio",
      "env": {
        "FORGE_BIN": "/path/to/forge",
        "HEROS_DATA_DIR": "/path/to/heros/data"
      }
    },
    "ledger": {
      "command": "/path/to/ledger-bridge.sh",
      "args": [],
      "transport": "stdio",
      "env": {
        "LEDGER_BIN": "/path/to/ledger",
        "HEROS_DATA_DIR": "/path/to/heros/data"
      }
    }
  }
}
```

Restart Claude Code. Type `/tools` or ask "what tools do you have?" to verify forge and ledger appear.

---

## Cursor

Open Settings → MCP → Add Server. Or edit `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "forge": {
      "command": "bash",
      "args": ["/path/to/forge-bridge.sh"],
      "env": {
        "FORGE_BIN": "/path/to/forge",
        "HEROS_DATA_DIR": "/path/to/heros/data"
      }
    },
    "ledger": {
      "command": "bash",
      "args": ["/path/to/ledger-bridge.sh"],
      "env": {
        "LEDGER_BIN": "/path/to/ledger",
        "HEROS_DATA_DIR": "/path/to/heros/data"
      }
    }
  }
}
```

---

## Cline (VS Code Extension)

Open VS Code Settings → Cline → MCP Settings (or edit `cline_mcp_settings.json`):

```json
{
  "mcpServers": {
    "forge": {
      "command": "/path/to/forge-bridge.sh",
      "args": [],
      "disabled": false,
      "env": {
        "FORGE_BIN": "/path/to/forge",
        "HEROS_DATA_DIR": "/path/to/heros/data"
      }
    },
    "ledger": {
      "command": "/path/to/ledger-bridge.sh",
      "args": [],
      "disabled": false,
      "env": {
        "LEDGER_BIN": "/path/to/ledger",
        "HEROS_DATA_DIR": "/path/to/heros/data"
      }
    }
  }
}
```

---

## Any MCP-Compatible Client

The bridges use MCP stdio transport (JSON-RPC 2.0 over stdin/stdout). Any client that supports `stdio` transport works:

```
command: /path/to/forge-bridge.sh
transport: stdio
env:
  FORGE_BIN: /path/to/forge
  HEROS_DATA_DIR: /path/to/data
```

The bridge handshakes with the standard `initialize` → `notifications/initialized` → `tools/list` sequence. Tool names: `forge_analyze`, `ledger_register`, `ledger_invoice_create`, `ledger_invoice_list`, `ledger_invoice_count`.

---

## API Key Authentication (optional)

For teams sharing a HEROS deployment, enable API key authentication:

**1. Generate an HMAC seed** (store this as a secret, not in the config file):

```bash
export HEROS_HMAC_SEED=$(openssl rand -hex 32)
```

**2. Generate an API key** using the key generator:

```bash
bash ledger/key-gen.sh --scope rw --org-id my-org
# Output: {"status":"ok","key":"heros_rw_<key_id>_<secret>","key_id":"...","warning":"..."}
```

**3. Add to MCP config**:

```json
{
  "env": {
    "HEROS_API_KEY": "heros_rw_<key_id>_<secret>",
    "HEROS_HMAC_SEED": "<your-hmac-seed>",
    "HEROS_DATA_DIR": "/path/to/heros/data"
  }
}
```

Scopes: `ro` (read-only: list, count, describe), `rw` (read-write: all operations).

---

## Docker Compose

```yaml
services:
  forge-mcp:
    image: alpine:3.19
    command: ["/usr/local/bin/forge-bridge.sh"]
    stdin_open: true
    environment:
      FORGE_BIN: /usr/local/bin/forge
      HEROS_DATA_DIR: /data
    volumes:
      - heros-data:/data

  ledger-mcp:
    image: alpine:3.19
    command: ["/usr/local/bin/ledger-bridge.sh"]
    stdin_open: true
    environment:
      LEDGER_BIN: /usr/local/bin/ledger
      HEROS_DATA_DIR: /data
    volumes:
      - heros-data:/data

volumes:
  heros-data:
```

---

## Verifying the Connection

After setup, the bridge should respond to an `initialize` call. Test manually:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  | bash forge-bridge.sh
```

Expected response includes `"serverInfo":{"name":"forge","version":"0.1.4"}`.

---

## Troubleshooting

**Bridge doesn't appear in tools list**  
→ Check file paths are absolute. Relative paths fail when the MCP client changes working directory.

**`EXEC_FAILED` on first call**  
→ Binary not executable. Run `chmod +x forge ledger` and verify `FORGE_BIN`/`LEDGER_BIN` point to the correct paths.

**`NO_ORG_REGISTERED` on ledger operations**  
→ Call `ledger_register` via MCP first, or run `./ledger register --org-name "YourOrg"` directly.

**`python3 not found`**  
→ Only required when `HEROS_API_KEY` is set. Remove `HEROS_API_KEY` from env for anonymous mode.

**Rate limiting fires immediately**  
→ Default burst is 20 forge analyses. Increase: `HEROS_FORGE_ANALYZE_BURST=100` in env.
