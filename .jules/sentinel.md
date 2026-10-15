## 2025-02-28 - Ported Security Checks from ledger to forge
**Vulnerability:** The `forge/mcp-bridge.sh` script did not check for symlinks when accessing security-critical files like `.heros-keys`, which could lead to write-redirect attacks. Furthermore, it did not verify that `.heros-keys` is a regular file before reading it with `awk`, exposing it to a FIFO blocking DoS attack.
**Learning:** Security fixes applied to one component (e.g. `ledger/mcp-bridge.sh`) must be systematically ported to other bridges (`forge/mcp-bridge.sh`) that use the same components (like shared key/audit paths).
**Prevention:** Ported `V318` symlink checks and `RT-364` regular file checks from `ledger` to `forge`.
