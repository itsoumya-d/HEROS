#!/usr/bin/env bash
# zeval — Binary evaluation runner for Zero tools
# Reads JSONL test cases, runs each against a binary, checks expected fields.
# Emits a single JSON result object to stdout.
#
# Usage: zeval --binary <path> --cases <file.jsonl> [--verbose]
# RT-33 style: all command construction via bash arrays, no eval, no string concat.

set -euo pipefail

# ── arg parsing ──────────────────────────────────────────────────────────────
BINARY=""
CASES_FILE=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)   BINARY="$2"; shift 2 ;;
        --cases)    CASES_FILE="$2"; shift 2 ;;
        --verbose)  VERBOSE=true; shift ;;
        --describe) _zeval_describe; exit 0 ;;
        *) jq -cn --arg f "$1" '{"error_code":"UNKNOWN_FLAG","flag":$f,"error":"Unknown flag. Run zeval --describe."}'; exit 0 ;;
    esac
done

_zeval_describe() {
    jq -cn '{
        "tool": "zeval",
        "version": "0.1.0",
        "description": "Binary evaluation runner for Zero tools. Reads JSONL test cases, runs each against a binary, checks expected fields. Emits structured JSON result.",
        "flags": {
            "--binary": {"type": "string", "required": true, "description": "Path to the binary to test."},
            "--cases": {"type": "string", "required": true, "description": "Path to JSONL file of test cases. One case per line."},
            "--verbose": {"type": "boolean", "required": false, "description": "Show per-case actual vs expected diff on failure."}
        },
        "case_format": {
            "id": "string — test case identifier",
            "args": "array of strings — CLI arguments to pass to binary",
            "expect_fields": "object — subset of fields expected in output. All listed fields must match.",
            "expect_exit": "integer — expected exit code (default 0)",
            "output_format": "string — json (default) or jsonl",
            "isolated": "boolean — if true, run in a fresh temp directory (default false)",
            "setup": "array of arrays — arg arrays to run before the test case"
        },
        "returns": {
            "total": "integer",
            "passed": "integer",
            "failed": "integer",
            "status": "ok or fail",
            "failures": "array of failure objects (empty on all-pass)"
        },
        "error_codes": {
            "BINARY_NOT_FOUND": {"retryable": false},
            "CASES_NOT_FOUND": {"retryable": false},
            "INVALID_CASES": {"retryable": false},
            "MISSING_FLAG": {"retryable": false}
        }
    }'
}

# ── validation ────────────────────────────────────────────────────────────────
if [[ -z "$BINARY" ]]; then
    echo '{"error_code":"MISSING_FLAG","flag":"--binary","error":"Required. Path to binary to test."}'; exit 0
fi
if [[ -z "$CASES_FILE" ]]; then
    echo '{"error_code":"MISSING_FLAG","flag":"--cases","error":"Required. Path to JSONL test cases file."}'; exit 0
fi
if [[ ! -x "$BINARY" ]]; then
    jq -cn --arg b "$BINARY" '{"error_code":"BINARY_NOT_FOUND","binary":$b,"error":"Binary not found or not executable."}'; exit 0
fi
if [[ ! -f "$CASES_FILE" ]]; then
    jq -cn --arg c "$CASES_FILE" '{"error_code":"CASES_NOT_FOUND","cases":$c,"error":"Cases file not found."}'; exit 0
fi
if ! command -v jq &>/dev/null; then
    echo '{"error_code":"DEPENDENCY_MISSING","dep":"jq","error":"jq >= 1.6 required."}'; exit 0
fi

# ── state ─────────────────────────────────────────────────────────────────────
TOTAL=0
PASSED=0
FAILED=0
FAILURES_JSON="[]"

SHARED_WORKDIR=$(mktemp -d)
trap 'rm -rf "$SHARED_WORKDIR"' EXIT

# ── case runner ───────────────────────────────────────────────────────────────
_run_case() {
    local case_json="$1"

    local id output_format expect_fields expect_exit isolated
    id=$(jq -r '.id // "unnamed"' <<< "$case_json")
    output_format=$(jq -r '.output_format // "json"' <<< "$case_json")
    expect_exit=$(jq -r '(.expect_exit // 0) | tonumber' <<< "$case_json")
    isolated=$(jq -r '.isolated // false' <<< "$case_json")
    expect_fields=$(jq -c '.expect_fields // {}' <<< "$case_json")

    # Choose working directory
    local workdir="$SHARED_WORKDIR"
    if [[ "$isolated" == "true" ]]; then
        workdir=$(mktemp -d "$SHARED_WORKDIR/case_XXXXXX")
    fi

    # Build setup commands (array of arrays)
    local setup_count
    setup_count=$(jq -r '.setup | length // 0' <<< "$case_json" 2>/dev/null || echo 0)
    if [[ "$setup_count" -gt 0 ]]; then
        local si=0
        while [[ $si -lt $setup_count ]]; do
            # Build setup command as bash array via jq
            local setup_args_json
            setup_args_json=$(jq -c --argjson i "$si" '.setup[$i]' <<< "$case_json")
            local setup_args=()
            while IFS= read -r arg; do
                setup_args+=("$arg")
            done < <(jq -r '.[]' <<< "$setup_args_json")
            # Run setup command (ignore output, run in workdir)
            (cd "$workdir" && "$BINARY" "${setup_args[@]}" >/dev/null 2>&1) || true
            si=$((si + 1))
        done
    fi

    # Build main args array
    local args_json
    args_json=$(jq -c '.args // []' <<< "$case_json")
    local args=()
    while IFS= read -r arg; do
        args+=("$arg")
    done < <(jq -r '.[]' <<< "$args_json")

    # Run binary, capture output and exit code
    local actual_output actual_exit=0
    actual_output=$(cd "$workdir" && "$BINARY" "${args[@]}" 2>/dev/null) || actual_exit=$?

    # Check exit code
    local exit_ok=true
    if [[ "$actual_exit" -ne "$expect_exit" ]]; then
        exit_ok=false
    fi

    # Check expected fields (subset match).
    # Keys support dot-notation paths: "error.code" → .error.code
    local field_errors=()
    local field_ok=true
    local check_output="$actual_output"
    if [[ "$output_format" == "jsonl" ]]; then
        local expect_line
        expect_line=$(jq -r '(.expect_line // 1) | tonumber' <<< "$case_json")
        check_output=$(sed -n "${expect_line}p" <<< "$actual_output")
    fi
    while IFS= read -r key; do
        local exp_val act_val
        # Use -c (not -rc) to preserve JSON type distinctions (null vs "null", etc.)
        # Support dotted paths: "error.code" → getpath(["error","code"])
        if [[ "$key" == *.* ]]; then
            exp_val=$(jq -c --arg k "$key" '.[$k]' <<< "$expect_fields")
            act_val=$(jq -c --arg k "$key" 'getpath($k | split("."))' <<< "$check_output" 2>/dev/null || echo "null")
        else
            exp_val=$(jq -c --arg k "$key" '.[$k]' <<< "$expect_fields")
            act_val=$(jq -c --arg k "$key" '.[$k]' <<< "$check_output" 2>/dev/null || echo "null")
        fi
        if [[ "$exp_val" != "$act_val" ]]; then
            field_ok=false
            field_errors+=("{\"field\":\"$key\",\"expected\":$(jq -nc --arg v "$exp_val" '$v'),\"actual\":$(jq -nc --arg v "$act_val" '$v')}")
        fi
    done < <(jq -r 'keys[]' <<< "$expect_fields" 2>/dev/null || true)

    TOTAL=$((TOTAL + 1))
    if [[ "$field_ok" == "true" && "$exit_ok" == "true" ]]; then
        PASSED=$((PASSED + 1))
        if [[ "$VERBOSE" == "true" ]]; then
            echo "  PASS [$id]" >&2
        fi
    else
        FAILED=$((FAILED + 1))
        local diff_json="{}"
        if [[ "$field_ok" == "false" ]]; then
            local errors_array
            errors_array=$(printf '%s\n' "${field_errors[@]}" | jq -sc '.')
            diff_json=$(jq -nc \
                --argjson errs "$errors_array" \
                --arg actual "$actual_output" \
                '{"field_errors":$errs,"actual_output":$actual}')
        fi
        if [[ "$exit_ok" == "false" ]]; then
            diff_json=$(jq -nc \
                --argjson d "$diff_json" \
                --arg exp "$expect_exit" \
                --arg act "$actual_exit" \
                '$d + {"exit_expected":($exp|tonumber),"exit_actual":($act|tonumber)}')
        fi
        local failure
        failure=$(jq -nc \
            --arg id "$id" \
            --argjson args "$args_json" \
            --argjson exp "$expect_fields" \
            --argjson diff "$diff_json" \
            '{"case_id":$id,"args":$args,"expected":$exp,"diff":$diff}')
        FAILURES_JSON=$(jq -c --argjson f "$failure" '. + [$f]' <<< "$FAILURES_JSON")
        if [[ "$VERBOSE" == "true" ]]; then
            echo "  FAIL [$id]: $diff_json" >&2
        fi
    fi
}

# ── main loop ─────────────────────────────────────────────────────────────────
while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Validate JSON
    if ! jq -e . >/dev/null 2>&1 <<< "$line"; then
        jq -cn --arg l "$line" '{"error_code":"INVALID_CASES","error":("Non-JSON line in cases file: " + $l)}'; exit 0
    fi
    _run_case "$line"
done < "$CASES_FILE"

# ── emit result ────────────────────────────────────────────────────────────────
STATUS="ok"
if [[ $FAILED -gt 0 ]]; then STATUS="fail"; fi

jq -cn \
    --argjson total "$TOTAL" \
    --argjson passed "$PASSED" \
    --argjson failed "$FAILED" \
    --arg status "$STATUS" \
    --argjson failures "$FAILURES_JSON" \
    '{total:$total,passed:$passed,failed:$failed,status:$status,failures:$failures}'
