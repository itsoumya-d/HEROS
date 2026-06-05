# Install HEROS in Claude Code

HEROS ships as a Claude Code plugin: seven MCP servers plus slash commands,
installable in one command from the marketplace.

## One-command install

```bash
claude plugin marketplace add itsoumya-d/HEROS
claude plugin install heros@heros
```

That's it. Open `/mcp` and you'll see the seven HEROS servers:
`heros-guardian`, `heros-vault`, `heros-audit`, `heros-evolve`, `heros-remix`,
`heros-forge`, `heros-ledger`.

The marketplace copies the plugin into Claude Code's cache and wires up the
servers from [`/.mcp.json`](../.mcp.json) using `${CLAUDE_PLUGIN_ROOT}` (the
plugin tree) and `${CLAUDE_PLUGIN_DATA}` (a persistent per-user dir under
`~/.claude/plugins/data/`, where vault/audit/evolve/ledger keep their state
across reinstalls).

## What works immediately vs. what needs a binary

| Server | Needs | Works on |
|---|---|---|
| guardian, vault, audit, evolve, remix | `bash` + `jq` | any host (macOS, Linux, WSL, Git Bash) |
| forge, ledger | their Zero binary (linux-x86-64) | Linux / WSL2 / Docker |

The five pure-bash servers are the always-on core. To enable forge and ledger,
run the bootstrap:

```
/heros-setup
```

This calls [`install/fetch-binaries.sh`](../install/fetch-binaries.sh), which
downloads the signed `forge`/`ledger` release assets, verifies their published
SHA-256 checksum (and the cosign signature when `cosign` is installed), and
drops them in `${CLAUDE_PLUGIN_DATA}/bin/` — exactly where `.mcp.json` points
`FORGE_BIN` / `LEDGER_BIN`. On non-Linux hosts it tells you so and exits cleanly;
the other five tools keep working.

## Slash commands

| Command | What it does |
|---|---|
| `/heros-assess` | Risk-score an operation with guardian before running it |
| `/heros-audit-verify` | Verify the tamper-evident audit chain and explain the result |
| `/heros-skill` | Propose / promote / list evolve skills (gated self-improvement) |
| `/heros-setup` | Fetch + verify the forge/ledger binaries |

## Prerequisites

- `bash` ≥ 4, `jq` ≥ 1.6 (on Windows: Git Bash or WSL)
- `flock`, `sha256sum`, and `base64` or `python3` (vault/audit storage)
- `openssl` (only when API-key auth is enabled)
- `cosign` (optional — enables binary signature verification in `/heros-setup`)

## Verifying the packaging yourself

```bash
bash test/plugin-smoke.sh   # launches every .mcp.json server, asserts tools/list
bash test/run-all.sh        # full per-component eval matrix
```

See [install-codex.md](install-codex.md) for the OpenAI Codex path.
