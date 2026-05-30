## 2024-05-27 - Batch jq processing in hot loops
**Learning:** Sequential `jq` invocations inside hot loops (like processing every incoming message in `handle_message`) create significant overhead in bash due to subprocess spawning.
**Action:** Always combine multiple `jq` reads/validations on the same JSON string into a single `jq` invocation. Use `jq ... | @sh` combined with `eval "arr=($parsed)"` to securely and correctly deserialize values (handling newlines and quotes safely) into a Bash array.
