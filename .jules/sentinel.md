## 2025-02-28 - TOCTOU FIFO Blocking DoS
**Vulnerability:** A missing fail-closed symlink check in `.heros-keys` reading logic allowed for a TOCTOU (Time-Of-Check to Time-Of-Use) and FIFO blocking DoS vulnerability by redirecting the awk read call.
**Learning:** Checking for file existence `[[ ! -f ]]` is insufficient if the target is a symlink to a FIFO or similar mechanism, which would cause `awk` to block indefinitely, disrupting auth logic across bridges.
**Prevention:** Always implement a strict fail-closed symlink check `if [[ -L <file> ]] || [[ ! -f <file> ]]` immediately before utilities like `awk` open security-critical data files.
