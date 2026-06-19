## 2026-05-18 - Fix FIFO blocking DoS and symlink redirect in forge
**Vulnerability:** The forge bridge did not check if `.heros-keys` was a regular file or a symlink, allowing a FIFO to block `awk` execution (DoS) or a symlink to redirect reads/writes.
**Learning:** When applying security fixes to one bridge, they must be systematically ported to other bridges that share the same resources or patterns.
**Prevention:** Enforce fail-closed symlink checks (`[[ -L <file> ]]`) and regular file checks (`[[ ! -f <file> ]]`) before passing security-critical files to utilities like `awk`.
