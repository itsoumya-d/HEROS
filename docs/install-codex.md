# Install HEROS in OpenAI Codex

Codex has no "plugin" concept — it loads MCP servers from `~/.codex/config.toml`.
HEROS ships an idempotent installer that registers all seven servers there.

## One-command install

```bash
bash install/codex/install.sh
```

This backs up your existing `~/.codex/config.toml`, removes any prior HEROS
block, and appends the seven `[mcp_servers.heros-*]` tables with absolute paths
substituted in. Re-running it is safe — it refreshes the block rather than
duplicating it.

Options:

```bash
bash install/codex/install.sh --config /path/to/config.toml --data ~/.heros
```

- `--config` — Codex config file (default `${CODEX_HOME:-~/.codex}/config.toml`)
- `--data` — writable dir for persistent state (default `~/.heros`)

Verify:

```bash
codex mcp list   # should show heros-guardian, heros-vault, heros-audit, …
```

## Manual install

Prefer to paste it yourself? Copy [`heros.config.toml`](../install/codex/heros.config.toml)
into your `~/.codex/config.toml`, replacing `__HEROS_ROOT__` with the absolute
path to your HEROS checkout and `__HEROS_DATA__` with a writable state dir.

## What works immediately vs. what needs a binary

The five pure-bash servers (guardian, vault, audit, evolve, remix) work as soon
as `bash` + `jq` are on PATH. forge and ledger need their linux-x86-64 Zero
binary:

```bash
bash install/fetch-binaries.sh --dest ~/.heros/bin
```

This verifies the published SHA-256 checksum (and cosign signature when
available) before installing. The Codex config points `FORGE_BIN` / `LEDGER_BIN`
at `~/.heros/bin/` by default. On non-Linux hosts forge/ledger can't run; use
Linux, WSL2, or Docker (the other five tools work natively).

## Prerequisites

Same as the [Claude Code path](install-claude-code.md#prerequisites): `bash` ≥ 4,
`jq` ≥ 1.6, `flock`, `sha256sum`, `base64`/`python3`, optional `openssl` (auth)
and `cosign` (binary signature verification).
