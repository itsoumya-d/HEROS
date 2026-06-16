## 2024-06-01 - Port V318 Symlink Check to Forge Bridge
**Vulnerability:** Symlink write-redirect attack via `.heros-keys`, `.heros-audit`, and `.heros-audit-failed`. An attacker could replace these files with symlinks to overwrite arbitrary files when the bridge process runs.
**Learning:** Security mechanisms implemented in one bridge (`ledger/mcp-bridge.sh`) must be systematically ported to all other bridges (`forge/mcp-bridge.sh`) that interact with the same shared resources (like the `HEROS_DATA_DIR` authentication registry and audit logs).
**Prevention:** When introducing a path-based vulnerability fix (like a symlink check) to a service, always search the codebase for other services that interact with the same paths.
