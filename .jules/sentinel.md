## 2025-06-30 - Fix write-redirect & FIFO block vulnerabilities in forge
**Vulnerability:** `forge/mcp-bridge.sh` did not check if `.heros-keys` or audit files were symlinks, allowing write-redirects. It also passed `.heros-keys` directly to `awk` without checking if it was a regular file, allowing a FIFO blocking DoS.
**Learning:** Utilities like `awk` can block on FIFOs, and writing to unverified files can be redirected via symlinks. The `ledger` bridge correctly mitigated this, but the fixes were not fully ported to the `forge` bridge.
**Prevention:** Systematically port security fixes across bridges. Enforce fail-closed symlink checks `[[ -L <file> ]]` and regular file checks `[[ ! -f <file> ]]` before reading/writing data files.
