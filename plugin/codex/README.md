# HEROS Codex / GitHub Copilot Plugin

Integrates HEROS forge and ledger tools into GitHub Copilot (Codex) in VS Code.

## Option A: copilot-mcp Extension (recommended)

1. Install [copilot-mcp](https://marketplace.visualstudio.com/items?itemName=AutomationSystems.copilot-mcp) in VS Code.
2. Copy the MCP settings into your workspace:
   ```bash
   mkdir -p .vscode .heros-data
   cp plugin/codex/vscode-mcp-settings.json .vscode/mcp.json
   ```
3. Reload VS Code (`Ctrl+Shift+P` → "Developer: Reload Window").
4. In Copilot Chat, type `@heros-forge` or `@heros-ledger` to use the tools.

The `vscode-mcp-settings.json` uses `${workspaceFolder}` which VS Code resolves to your repo root at extension load time.

**Adding auth:** Add secrets to `.vscode/mcp.json` (never commit this file with secrets):
```json
{
  "servers": {
    "heros-ledger": {
      "type": "stdio",
      "command": "${workspaceFolder}/ledger/mcp-bridge.sh",
      "env": {
        "HEROS_DATA_DIR": "${workspaceFolder}/.heros-data",
        "HEROS_API_KEY": "heros_rw_<key_id>_<secret>",
        "HEROS_HMAC_SEED": "<your-seed>"
      }
    }
  }
}
```

## Option B: OpenAPI HTTP Wrapper

For Copilot plugins or other tools that consume OpenAPI specs rather than MCP stdio:

1. Start the wrapper:
   ```bash
   bash plugin/codex/openapi-wrapper.sh --port 8743
   ```

2. Register `http://localhost:8743` as an OpenAPI plugin using `plugin/codex/openapi-spec.json` as the specification.

**Endpoints:**

| Method | Path | Tool |
|--------|------|------|
| POST | `/forge/analyze` | forge_analyze |
| POST | `/ledger/register` | ledger_register |
| POST | `/ledger/invoice/create` | ledger_invoice_create |
| GET  | `/ledger/invoice/list?limit=N&offset=N` | ledger_invoice_list |
| GET  | `/ledger/invoice/count` | ledger_invoice_count |

**Requirements:** `bash 4+`, `jq 1.6+`, `nc` (netcat) or `socat`.

## Security

- `.vscode/mcp.json` with secrets must be in `.gitignore`.
- The wrapper starts on localhost only — do not expose to untrusted networks.
- `openapi-wrapper.sh` does not eval user input; all argument construction uses jq and bash arrays.
