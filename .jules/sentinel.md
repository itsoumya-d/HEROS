
## 2025-02-28 - [Prevent FIFO blocking DoS and symlink write-redirects]
**Vulnerability:** Security-critical data files passed to `awk` without checking if they were regular files, enabling a FIFO DoS attack that could block the bridge. Lack of symlink checks enabled write-redirect attacks.
**Learning:** Utilities like `awk` will block indefinitely if pointed to a FIFO, and file redirection will follow attacker-controlled symlinks.
**Prevention:** Always verify files are regular files (`[[ ! -f <file> ]]`) before passing to utilities, and verify files are not symlinks (`[[ -L <file> ]]`) during startup checks.
