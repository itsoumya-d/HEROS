## 2025-01-20 - Port fail-closed symlink and FIFO DoS protections to Forge
**Vulnerability:** `forge/mcp-bridge.sh` lacked fail-closed symlink checks for `.heros-keys` and failed to verify `.heros-keys` is a regular file before calling `awk`, creating risks of write-redirect attacks and FIFO blocking DoS.
**Learning:** Security fixes applied to one component (e.g., `ledger`) must be systematically ported to all components that share the vulnerability (e.g., `forge`).
**Prevention:** Implement `[[ -L <file> ]]` symlink checks at startup and `[[ ! -f <file> ]]` regular file checks before file reads.
