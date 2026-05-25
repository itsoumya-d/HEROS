#!/usr/bin/env bash
# eval-runner.sh — Run jsonschema eval-cases.jsonl against a compiled binary.
# Usage: JSONSCHEMA_BIN=./jsonschema bash eval-runner.sh [--describe]
# Requires: jq

set -euo pipefail
export LANG=C.UTF-8

_describe() {
    printf '{"tool":"eval-runner","version":"0.2.0","description":"Run jsonschema eval-cases.jsonl against a compiled jsonschema binary. Pass JSONSCHEMA_BIN env var or place binary at eval-runner.sh dir/jsonschema.","case_fields":{"id":"string — case identifier","args":"array of strings — CLI args to binary","expect_fields":"object — key=value pairs all of which must match actual output","expect_error_codes":"array of strings — each code must appear in actual.errors[].code","expect_error_count":"integer — actual.errors length must equal this","expect_error_paths":"array of strings — each path must appear in actual.errors[].path","description":"string — human description"},"output":"PASS/FAIL per case, summary line, exit 1 on any failure"}\n'
}

if [[ "${1:-}" == "--describe" ]]; then _describe; exit 0; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASES="${SCRIPT_DIR}/eval-cases.jsonl"
BIN="${JSONSCHEMA_BIN:-${SCRIPT_DIR}/jsonschema}"

PASS=0
FAIL=0

pass() { echo "PASS [$1] $2"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL [$1] $2 | actual: $3"; FAIL=$(( FAIL + 1 )); }

if [[ ! -x "$BIN" ]]; then
    echo "ERROR: binary not found or not executable: $BIN" >&2
    exit 1
fi

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # RT-168: guard non-JSON JSONL lines (e.g., comment lines) before id=$(jq...) which
    # would abort the script under set -e on jq failure rather than failing the case.
    if ! jq -e . >/dev/null 2>&1 <<< "$line"; then
        fail "?" "(invalid JSONL line — not valid JSON)" "n/a"
        continue
    fi

    id=$(jq -r '.id' <<< "$line")
    description=$(jq -r '.description' <<< "$line")

    # RT-155: guard non-array args — jq .args[] on null/string/object emits nothing;
    # mapfile produces empty array; binary runs with no args → outputs error JSON;
    # vacuous expects both return true → false-positive PASS. Detect and FAIL instead.
    if ! jq -e '.args | type == "array"' <<< "$line" >/dev/null 2>&1; then
        fail "$id" "$description" "malformed eval case: args is not a JSON array"
        continue
    fi

    # Build args array from JSON array
    mapfile -t args < <(jq -r '.args[]' <<< "$line")

    # Run the binary (capture output; allow non-zero exit)
    actual=$("$BIN" "${args[@]}" 2>/dev/null) || true

    # Verify output is valid JSON
    if ! jq -e . >/dev/null 2>&1 <<< "$actual"; then
        fail "$id" "$description" "non-JSON output: $actual"
        continue
    fi

    # Check expect_fields: each key in expect_fields must equal actual[key]
    fields_ok=$(jq -n \
        --argjson actual "$actual" \
        --argjson expect "$(jq -c '.expect_fields // {}' <<< "$line")" \
        '[$expect | to_entries[] | (.value == $actual[.key])] | all' 2>/dev/null || echo "false")

    # Check expect_error_codes: each code must appear in actual.errors[].code
    codes_ok=$(jq -n \
        --argjson actual "$actual" \
        --argjson codes "$(jq -c '.expect_error_codes // []' <<< "$line")" \
        '$codes | map(. as $c | [($actual.errors // [])[] | select(.code == $c)] | length > 0) | all' \
        2>/dev/null || echo "false")

    # Check expect_error_count: actual errors array length must equal declared count (V52)
    count_ok="true"
    if jq -e '.expect_error_count' >/dev/null 2>&1 <<< "$line"; then
        count_ok=$(jq -n \
            --argjson actual "$actual" \
            --argjson expected "$(jq -c '.expect_error_count' <<< "$line")" \
            '(($actual.errors // []) | length) == $expected' \
            2>/dev/null || echo "false")
    fi

    # Check expect_error_paths: each declared path must appear in actual.errors[].path (Cycle 75)
    paths_ok="true"
    if jq -e '.expect_error_paths' >/dev/null 2>&1 <<< "$line"; then
        paths_ok=$(jq -n \
            --argjson actual "$actual" \
            --argjson paths "$(jq -c '.expect_error_paths // []' <<< "$line")" \
            '$paths | map(. as $p | [($actual.errors // [])[] | select(.path == $p)] | length > 0) | all' \
            2>/dev/null || echo "false")
    fi

    if [[ "$fields_ok" == "true" && "$codes_ok" == "true" && "$count_ok" == "true" && "$paths_ok" == "true" ]]; then
        pass "$id" "$description"
    else
        # Build failure reason list (V53: show which checks failed)
        reasons=()
        [[ "$fields_ok" != "true" ]] && reasons+=("fields")
        [[ "$codes_ok"  != "true" ]] && reasons+=("codes")
        [[ "$count_ok"  != "true" ]] && reasons+=("count")
        [[ "$paths_ok"  != "true" ]] && reasons+=("paths")
        reason_str=$(IFS=','; echo "${reasons[*]}")
        fail "$id" "$description" "[$reason_str] $actual"
    fi
done < "$CASES"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
echo "All jsonschema eval cases passed."
