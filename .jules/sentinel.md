## 2025-11-25 - Add missing input validation in tools/call for forge
**Vulnerability:** Missing JSON type validation in `forge/mcp-bridge.sh` for `tools/call` JSON-RPC parameters caused `jq` to fail and return non-zero exit codes when array/primitive types were provided instead of objects or strings. Due to `set -e`, this resulted in an internal server crash (status 500 / `-32603`) instead of returning a proper `-32602` Invalid Params error.
**Learning:** Security fixes applied to one component (e.g., `ledger/mcp-bridge.sh`) must be systematically ported to other components (e.g., `forge/mcp-bridge.sh`) that share similar resource handling or vulnerabilities.
**Prevention:** In bash scripts, explicitly type-check JSON properties using `jq -e` before extraction or processing.
