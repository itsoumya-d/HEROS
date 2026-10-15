## 2024-05-24 - DoS Vulnerability in File Parsing via awk
**Vulnerability:** A missing regular file check before invoking `awk` on a file (e.g. `.heros-keys`). If the file is replaced with a symlink to a FIFO or a directory, `awk` will block indefinitely.
**Learning:** Utilities that read files, like `awk`, do not automatically check if the target is a regular file. A symlink to a FIFO can cause the utility to block forever, resulting in a Denial of Service.
**Prevention:** Always verify file integrity and type (`[[ ! -f ... ]]` and `[[ -L ... ]]`) before reading critical files with command-line utilities.
