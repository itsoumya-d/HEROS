# HEROS Plugin

Registers the HEROS forge and ledger MCP servers for Claude Code and GitHub Copilot (Codex).

## Claude Code (project-local)

The `.claude/settings.json` file at the repo root registers both bridges automatically when you open this folder in Claude Code.

**Tools exposed:**
- `forge_analyze` — schema migration risk analysis (SAFE/NOTABLE/MEDIUM/HIGH/CRITICAL)
- `ledger_register` — provision an accounting org
- `ledger_invoice_create` — create an invoice with idempotency key
- `ledger_invoice_list` — paginated invoice list
- `ledger_invoice_count` — invoice count

**One-time setup:**

```bash
# Create the data directory the bridges write to
mkdir -p /home/user/HEROS/.heros-data
```

Then open the HEROS folder in Claude Code. The two MCP servers (`heros-forge`, `heros-ledger`) will appear in the tools panel.

**Adding auth (optional):** Secrets must never be committed. Add them to your personal `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "heros-ledger": {
      "command": "/home/user/HEROS/ledger/mcp-bridge.sh",
      "env": {
        "HEROS_DATA_DIR": "/home/user/HEROS/.heros-data",
        "HEROS_API_KEY": "heros_rw_<key_id>_<secret>",
        "HEROS_HMAC_SEED": "<your-seed>"
      }
    }
  }
}
```

Generate API keys with `bash ledger/key-gen.sh --scope rw --org-id org_XXXXXXXX`.

**Global install:** Copy `plugin/claude/settings.json.template`, replace `__HEROS_ROOT__` with your absolute repo path, and merge into `~/.claude/settings.json`.

## GitHub Copilot / Codex (VS Code)

Install the [`copilot-mcp`](https://marketplace.visualstudio.com/items?itemName=AutomationSystems.copilot-mcp) VS Code extension, then copy the plugin configuration:

```bash
mkdir -p .vscode
cp plugin/codex/vscode-mcp-settings.json .vscode/mcp.json
mkdir -p .heros-data
```

Reload VS Code. The HEROS tools will appear as Copilot chat participants.

**Alternative (OpenAPI wrapper):** If you use a Copilot plugin that speaks OpenAPI rather than MCP stdio, start the HTTP wrapper:

```bash
bash plugin/codex/openapi-wrapper.sh --port 8743
```

Then register `http://localhost:8743` using `plugin/codex/openapi-spec.json` as the spec.

## Running the Test Suite

```bash
# Bridge-only (no Zero binary required)
chmod +x forge/mcp-bridge.sh ledger/mcp-bridge.sh plugin/test/*.sh
bash plugin/test/plugin-test.sh --mode bridge-only

# Full (requires compiled forge + ledger binaries)
bash plugin/test/plugin-test.sh --mode full
```

Expected output in bridge-only mode: `STATUS: partial` (binary eval cases are skipped; all bridge-layer tests pass).

## Test Coverage

| Suite | Cases | Description |
|-------|-------|-------------|
| REG-01..REG-15 | 15 | MCP handshake, protocol guards, tools/list |
| BE-01..BE-13   | 13 | Forge approval nonce protocol (requires binary) |
| FP-01..FP-08   |  8 | Forge bridge: rate limit, request_id, input guards, auth |
| BA-01..BA-11   | 11 | Ledger key-gen + HMAC auth validation |
| AE-01..AE-08   |  9 | Ledger bridge auth integration |
| LP-01..LP-13   | 13 | Ledger bridge: register, invoice CRUD, rate limit, isolation |
| FE-01..FE-33   | 33 | Forge binary eval (full mode only) |
| LE-01..LE-25   | 25 | Ledger binary eval (full mode only) |

## Security

- `HEROS_API_KEY` and `HEROS_HMAC_SEED` are secrets — never commit them.
- The `.heros-data/` directory contains auth keys, audit logs, and invoice data — add it to `.gitignore`.
- In production, run each bridge with the narrowest scope needed (`ro` for forge, `rw` for ledger writes).
