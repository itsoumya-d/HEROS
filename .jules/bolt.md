## 2025-02-18 - Batch jq extractions using bash array eval
**Learning:** Sequential `jq` invocations in Bash scripts spawn multiple subprocesses and are a major source of latency. In this codebase, five `jq` extractions were used to parse arguments for a single tool call, significantly increasing processing time.
**Action:** Always combine multi-property JSON extractions into a single `jq` call. To maintain Bash RCE safety and strict type checking, construct a flat array of status flags and values, pipe through `@sh` to sanitize for the shell, and `eval` into a Bash array.
