## 2024-06-20 - Write-redirect attacks via symlinks
**Vulnerability:** Attackers could replace security-critical data files (like .heros-keys) with a symlink pointing to an attacker-controlled file, hijacking data reads/writes.
**Learning:** Checking for symlinks at startup prevents these attacks. Additionally, awk blocks or errors on FIFOs/directories.
**Prevention:** Add explicit fail-closed checks for `-L` (symlinks) on critical files at startup, and `-f` (regular file) checks before tools like awk read them.
