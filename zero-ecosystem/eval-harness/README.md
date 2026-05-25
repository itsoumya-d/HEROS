# eval-harness — Binary Evaluation Runner for Zero Tools

**Status:** Design phase  
**Blocker:** None — bash wrapper, no Zero dependency  
**Priority:** P1  
**Sub-agent loop owner:** eval-harness

---

## Why

Every Zero tool needs an automated eval loop: write test cases, run against the binary, compare output. Currently ledger and forge each have handwritten eval scripts. `zeval` standardizes this into a reusable harness so every new Zero tool can plug in its eval cases without writing a new test runner.

---

## Agent-facing interface

```bash
# Run all eval cases
zeval --binary ./ledger --cases eval-cases.jsonl

# Run a single case
zeval --binary ./ledger --case '{"args":["register","--org-name","Acme"],"expect":{"status":"ok"}}'

# Run with verbose output (show full actual vs expected diff)
zeval --binary ./ledger --cases eval-cases.jsonl --verbose

# Describe the tool
zeval --describe
```

**Success output:**
```json
{"total":10,"passed":10,"failed":0,"status":"ok"}
```

**Failure output:**
```json
{
  "total": 10,
  "passed": 9,
  "failed": 1,
  "status": "fail",
  "failures": [
    {
      "case_id": "EC-03",
      "args": ["invoice", "create", "--to", "Vendor", "--amount", "bad"],
      "expected": {"error_code": "INVALID_INPUT"},
      "actual": {"error_code": "MISSING_FLAG"},
      "diff": "error_code: expected INVALID_INPUT, got MISSING_FLAG"
    }
  ]
}
```

---

## Eval case format (JSONL)

Each line is one test case:

```json
{"id":"EC-01","args":["register","--org-name","Acme"],"expect_fields":{"status":"ok"},"expect_exit":0}
{"id":"EC-02","args":["register"],"expect_fields":{"error_code":"MISSING_FLAG"},"expect_exit":0}
{"id":"EC-03","args":["invoice","create","--to","V","--amount","bad","--currency","USD","--idempotency-key","k1"],"expect_fields":{"error_code":"INVALID_INPUT"},"expect_exit":0}
```

**Fields:**
- `id` — test case identifier (string)
- `args` — array of CLI arguments passed to the binary
- `env` — optional: object of environment variables to set
- `stdin` — optional: string piped to binary stdin
- `setup` — optional: array of args to run as a setup step before the case
- `expect_fields` — object: each key must exist in actual output with matching value
- `expect_exit` — optional: expected exit code (default 0)
- `expect_output_format` — optional: "json" (default) or "jsonl"

**Match semantics:** `expect_fields` is a subset match — actual output may have extra fields. Only the specified fields are checked. This makes cases forward-compatible with new output fields.

---

## Implementation

`zeval` is a bash script (not a Zero binary — it wraps Zero binaries and compares JSON output).

**Core loop:**
```bash
while IFS= read -r case_line; do
    id=$(jq -r '.id' <<< "$case_line")
    args=$(jq -r '.args[]' <<< "$case_line")   # → array via mapfile
    expect=$(jq -c '.expect_fields' <<< "$case_line")
    
    # Run binary, capture output
    actual=$("$BINARY" "${ARGS_ARRAY[@]}" 2>/dev/null)
    
    # Check each expected field
    # For each key in expect: actual[key] == expect[key]?
    pass=true
    for key in $(jq -r 'keys[]' <<< "$expect"); do
        exp_val=$(jq -r --arg k "$key" '.[$k]' <<< "$expect")
        act_val=$(jq -r --arg k "$key" '.[$k]' <<< "$actual")
        if [[ "$exp_val" != "$act_val" ]]; then pass=false; ... fi
    done
done < "$CASES_FILE"
```

**Security:** no eval, no dynamic code execution. All comparisons via jq field extraction.

---

## Integration with existing eval logs

Existing eval cases in `ledger/` and `forge/` can be migrated to zeval JSONL format:
- `eval_log.md` → extract test cases → write `eval-cases.jsonl`
- CI job: `zeval --binary ./ledger-linux-x64.bin --cases ledger/eval-cases.jsonl`

This closes the gap between "eval log is a markdown file" and "eval is a CI gate."

---

## Eval of zeval itself (meta-eval)

| Case | Expected |
|---|---|
| EZ-01 | all-passing case set → `{"passed":N,"failed":0,"status":"ok"}` |
| EZ-02 | one failing case → `{"failed":1,"failures":[...]}` |
| EZ-03 | missing binary → `{"error_code":"BINARY_NOT_FOUND"}` |
| EZ-04 | malformed cases file → `{"error_code":"INVALID_CASES"}` |
| EZ-05 | `--describe` → full schema parseable |

---

## Version history

- v0.1.0 (planned): bash implementation, subset field matching, JSONL case format, JSON result output
- v0.2.0 (planned): parallel case execution, setup/teardown hooks, JSONL streaming output per case
