## 2025-05-24 - Optimize JSON Parsing with jq @sh filter
**Learning:** In bash scripts, spawning multiple `jq` subprocesses inside a tight loop or for every incoming message causes significant performance degradation (approx 5x slower) due to process spawning overhead.
**Action:** Combine multiple operations into a single `jq` call using the `@sh` filter and deserialize with `eval "arr=($parsed)"` to securely and efficiently handle newlines/special characters without spawning multiple subshells. Ensure strict type checking within `jq` before extraction.
