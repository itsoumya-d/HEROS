## 2024-05-18 - Optimize JSON parsing overhead using jq @sh filter
**Learning:** Sequential multiple `jq` invocations on the same JSON input within a busy loop or event handler introduce significant subprocess spawning overhead in Bash scripts.
**Action:** Combine multiple fields extraction into a single `jq` call using array construction, the `@sh` filter, and `join(" ")`. Then `eval "local arr=($parsed)"` to deserialize them into bash variables safely without multiple subprocesses.
