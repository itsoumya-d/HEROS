## 2025-06-25 - Prevent Symlink write-redirect and FIFO DoS attacks
**Vulnerability:** Security-critical data files (e.g., `.heros-keys`) passed directly to `awk` without checking for symlinks or ensuring they are regular files, which can lead to write-redirect attacks or FIFO blocking DoS.
**Learning:** `awk` execution can block indefinitely when encountering a FIFO file. Symlinks can redirect operations to arbitrary locations.
**Prevention:** Always enforce fail-closed symlink checks (`if [[ -L <file> ]]`) and regular file checks (`if [[ ! -f <file> ]]`) before passing critical files to utilities like `awk` in bash scripts.
