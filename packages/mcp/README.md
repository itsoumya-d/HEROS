# @heros/mcp

Cross-platform MCP 2025-11-25 bridge for **forge** and **ledger**. One Node
process exposes both tool families over:

- **stdio** — for Claude Desktop, Claude Code, Cursor, Cline, and any MCP client
  that launches a subprocess.
- **Streamable HTTP** — a single `/mcp` endpoint with sessions, JSON responses,
  and `text/event-stream` streaming for remote agents and LangGraph services.

No bash, jq, awk, flock, or GNU coreutils. The bridge runs on macOS, Linux, and
Windows wherever Node 22+ runs. The Zero binaries remain the pure-compute layer.

## Quick start

```bash
# stdio (default)
node packages/mcp/bin/heros-mcp.mjs --stdio

# Streamable HTTP
node packages/mcp/bin/heros-mcp.mjs --http --port 8787 --data-dir ~/.heros
# endpoint: http://127.0.0.1:8787/mcp
# health:   http://127.0.0.1:8787/healthz
```

Point the bridge at the binaries with `HEROS_FORGE_BIN` and `HEROS_LEDGER_BIN`
(or `--forge-bin` / `--ledger-bin`). If they are on `PATH` as `forge` and
`ledger`, no configuration is needed.

### Claude / Cursor / Cline

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

### Streamable HTTP

```bash
curl -s http://127.0.0.1:8787/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"curl","version":"1"}}}'
# response carries Mcp-Session-Id
```

Send that header on every subsequent request. `Accept: text/event-stream`
returns SSE frames. `GET /mcp` opens a keepalive SSE stream and `DELETE /mcp`
terminates the session.

### Python / LangGraph

`python/heros_mcp_client.py` is a stdlib-only client:

```python
from heros_mcp_client import HerosMcpClient

client = HerosMcpClient(env={"HEROS_DATA_DIR": "/tmp/heros"})
client.initialize()
print(client.list_tools()["result"]["tools"])
result = client.call_tool("forge_analyze", {
    "from_schema": "TABLE users",
    "to_schema": "TABLE users\nDROP COLUMN email",
})
print(result["result"]["content"][0]["text"])
client.close()
```

## Tools

| Tool | Scope | Notes |
|---|---|---|
| `forge_analyze` | none | Schema risk analysis; destructive migrations return an approval nonce |
| `ledger_register` | rw | Idempotent org registration; returns `ORG_EXISTS` on replay |
| `ledger_invoice_create` | rw | Idempotent by `idempotency_key`; scoped to the authenticated org |
| `ledger_invoice_list` | ro | Paginated JSONL store; 1–1000 records per page |
| `ledger_invoice_count` | ro | Count for the authenticated org |

Every successful response includes `_rate_limit` with `remaining`, `reset_at`,
`limit`, and `window`.

## Security

- **API keys (optional).** Set `HEROS_API_KEY` for single-tenant stdio mode, or
  send `Authorization: Bearer <key>` / `X-Heros-Api-Key` over HTTP. Keys use the
  existing `heros_<ro|rw>_<key_id>_<secret>` format and are validated with
  HMAC-SHA256 against `.heros-keys` in `HEROS_DATA_DIR` (`HEROS_HMAC_SEED` is
  required). Invalid, revoked, or under-scoped keys fail closed.
- **Human approval gates.** `forge_analyze` returns `decision_required: true`
  and a 16-hex `approval_nonce` for destructive migrations. The nonce is
  single-use, expires after 5 minutes, and is bound to the exact schema pair.
  Redeeming it returns `proceed_ok: true`.
- **Rate limits.** Token buckets per session: forge 200/h, register 10/h, create
  1000/h, list 3000/h, count 6000/h. Limit `0` disables a tool.
- **Audit receipts.** Authenticated calls append to `.heros-audit`; failed auth
  attempts append to `.heros-audit-failed`.
- **State safety.** Atomic writes, `O_EXCL` advisory locks with stale-lock
  recovery, and symlink rejection for `.ledger-data`, `.ledger-invoices`,
  `.heros-keys`, and lock files.
- **No shell.** Binaries are invoked with `execFile` argument arrays; schema
  text is never interpolated into a shell command.

## State model

`HEROS_DATA_DIR` (or `--data-dir`) holds:

- `.ledger-data` — registered org JSON
- `.ledger-invoices` — JSONL invoices
- `.heros-keys` — API keys (when auth is enabled)
- `.heros-audit`, `.heros-audit-failed`
- `.ledger-data.lock`, `.ledger-invoices.lock`

The bridge owns these files; the ledger binary remains a pure function.

## Tests

```bash
cd packages/mcp
npm test
```

The suite covers the MCP handshake, both transports, forge approval nonces,
ledger idempotency and pagination, API-key HMAC validation, rate limiting,
audit writes, and SSE.

## Compatibility

The legacy `forge/mcp-bridge.sh` and `ledger/mcp-bridge.sh` remain available for
deployments that require bash/jq. `@heros/mcp` exposes the same tool names and
response shapes, so clients can switch by changing the launch command.
