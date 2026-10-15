
## 2024-06-16 - Port Symlink Write-Redirect Protection
**Vulnerability:** The forge bridge lacked symlink checks on `.heros-keys`, `.heros-audit`, and `.heros-audit-failed` which were present in the ledger bridge. This allowed for write-redirect attacks or reading critical data from attacker-controlled symlinked locations.
**Learning:** Security fixes made to one component (ledger) were not systematically ported to other components (forge) that share similar configurations and resources.
**Prevention:** When applying security fixes or enhancements to one bridge, systematically check and port the same mechanisms to all other bridges that share similar resources or vulnerabilities.
