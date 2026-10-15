## 2025-02-12 - Combine jq Calls with @sh
**Learning:** Multiple individual jq calls for simple validations and extractions in a Bash script introduce significant subprocess spawning overhead, which creates a performance bottleneck during JSON-RPC message processing.
**Action:** Combine all top-level validations and extractions into a single jq call. Use the @sh filter in jq to safely format the output, and deserialize it in Bash using `eval "arr=($parsed)"` to extract the variables without risking command injection or syntax errors.
