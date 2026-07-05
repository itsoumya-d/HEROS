## 2024-07-06 - FIFO Blocking DoS Vulnerability in File Lookups
**Vulnerability:** A missing file check (`[[ ! -f ]]`) before calling `awk` on a security-critical file in a bash script.
**Learning:** If the file is replaced with a FIFO or directory, `awk` can block indefinitely (DoS) or produce unexpected errors.
**Prevention:** Always verify a file is a regular file (`[[ ! -f <file> ]]`) and/or check for symlinks (`[[ -L <file> ]]`) before reading from it in bash scripts.
