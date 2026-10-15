## 2024-05-24 - Optimize JSON Parsing with jq @sh and eval

**Learning:** Repeated JSON parsing in Bash scripts can be a performance bottleneck due to the overhead of spawning multiple `jq` subprocesses. By using `jq`'s `@sh` filter to combine multiple field extractions into a single shell-escaped string, the script can safely deserialize the results using a single `eval` call without spawning multiple processes.

**Action:** Combine operations into a single `jq` call using `@sh` and deserialize with `eval "arr=($parsed)"` to optimize repeated JSON parsing.
