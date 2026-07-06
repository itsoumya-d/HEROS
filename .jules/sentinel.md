## 2024-05-24 - Fix missing FIFO and symlink protections
**Vulnerability:** `forge/mcp-bridge.sh` and `ledger/key-gen.sh` were vulnerable to symlink write-redirects and FIFO-blocking DoS attacks because they did not check file types before reading or writing `.heros-keys`.
**Learning:** Security fixes applied to one script (`ledger/mcp-bridge.sh`) are often missed in other scripts that share the architecture (`forge/mcp-bridge.sh`, `ledger/key-gen.sh`).
**Prevention:** Always verify file attributes (`-L` and `-f`) before processing security-critical files with utilities like `awk` or redirecting outputs.
