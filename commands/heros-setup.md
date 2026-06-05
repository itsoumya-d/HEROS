---
description: Bootstrap HEROS forge/ledger binaries into the plugin data dir
---

The five pure-bash HEROS tools (guardian, vault, audit, evolve, remix) work
immediately on any host with `bash` + `jq`. The two binary-backed tools
(`forge`, `ledger`) need their compiled Zero binary, which this command fetches
and verifies.

Steps:
1. Run the bootstrap script, passing the plugin's persistent data dir:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/install/fetch-binaries.sh" --dest "${CLAUDE_PLUGIN_DATA}/bin"
   ```

2. The script downloads the signed `forge` and `ledger` linux-x64 release assets,
   `cosign verify-blob`s them against the HEROS release identity, and installs
   them to `${CLAUDE_PLUGIN_DATA}/bin/` (where `.mcp.json` points `FORGE_BIN` /
   `LEDGER_BIN`).
3. On a non-Linux host the binaries cannot run; report that forge/ledger need
   Linux, WSL, or Docker, and that the other five tools work natively meanwhile.
4. After setup, confirm by listing the `heros-forge` and `heros-ledger` tools and
   making one read-only call (e.g. a forge analyze on a trivial schema diff).
