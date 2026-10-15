## 2024-05-18 - Batch jq extraction to reduce subprocess overhead
**Learning:** Parsing multiple fields with separate `jq` calls in a bash loop incurs high overhead.
**Action:** Combine extractions into a single `jq` call by placing results in an array, mapping through `@sh`, and parsing the output back into bash arrays using `eval`. Crucially, safely type-check properties like strings with `(if (.field | type) == "string" then .field else "" end)` and use `.field | tojson` for objects or when nulls shouldn't evaluate to empty strings, to prevent `jq` crashes or code execution via `eval`.
