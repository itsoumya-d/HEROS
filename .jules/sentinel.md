## 2024-06-01 - Audit Fail File Integrity
**Vulnerability:** Symlink redirection attack via .heros-audit-failed
**Learning:** Symlink checking was missing for .heros-audit-failed when checking .heros-audit. This would allow an attacker to bypass the fail-closed symlink check.
**Prevention:** Always check all files that a program opens for writing in sensitive directories.
