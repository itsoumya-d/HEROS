## 2024-05-18 - Reduce jq Subprocess Overhead in Bash
**Learning:** In bash scripts, repeatedly spawning `jq` subprocesses within a read loop (e.g., to extract multiple fields or validate JSON) introduces significant processing overhead, becoming a major performance bottleneck for high-throughput bridge/RPC handlers.
**Action:** Combine multiple `jq` extraction and validation operations into a single `jq` invocation. Construct an array of the needed values and output them as a shell-safe string using the `@sh` filter, then deserialize them into a bash array using `eval "arr=($parsed)"`.
