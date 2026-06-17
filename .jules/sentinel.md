## 2025-05-15 - Prevent Write-Redirect and FIFO DoS in Bash Scripts
**Vulnerability:** Symlinks and FIFOs could be used to manipulate bash scripts reading security-critical data files like `.heros-keys`.
**Learning:** Using `awk` or redirection directly on user-controlled paths without checking if they are a regular file allows an attacker to either redirect file writes (via symlinks) or block execution indefinitely (via FIFOs).
**Prevention:** Enforce fail-closed symlink checks (`if [[ -L <file> ]]`) and regular file checks (`if [[ ! -f <file> ]]`) before passing security-critical files to utilities like `awk` or performing I/O.
