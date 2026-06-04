## 2024-06-11 - [Optimize jq subprocess spawning in bash bridge loops]
**Learning:** In the MCP bridge bash scripts, spawning a `jq` subprocess is extremely slow and acts as a significant bottleneck in tight message-processing loops. Using multiple `jq` calls to extract fields from the same JSON payload adds unnecessary overhead.
**Action:** Consolidate multiple `jq` extractions into a single call using the `@sh` filter to output shell-quoted strings, and use `eval "array=(...)"` to safely read them into bash variables.
