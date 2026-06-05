#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# guardian/eval-bridge.sh — MCP bridge eval for guardian_assess
# Runs eval cases from eval-cases.jsonl against the guardian MCP bridge.

set -euo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/mcp-bridge.sh"
CASES="${SCRIPT_DIR}/eval-cases.jsonl"

PASS=0; FAIL=0; ERRORS=()

# Build the MCP session: initialize + all tool calls
_run_case() {
    local id="$1" desc="$2" tool="$3" input_json="$4" expect_json="$5"

    local result
    result=$(printf '%s\n%s\n' \
        '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}' \
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":$(printf '%s' "$input_json")}}" \
        | timeout 10 bash "$BRIDGE" 2>/dev/null \
        | grep -v '"method"' \
        | tail -1 \
        | jq -r '.result.content[0].text' 2>/dev/null || echo '{}')

    # Check each expected field
    local fail_fields=()
    while IFS= read -r key; do
        local exp_val act_val
        exp_val=$(jq -c --arg k "$key" '.[$k]' <<< "$expect_json" 2>/dev/null || echo "null")
        act_val=$(jq -c --arg k "$key" '.[$k]' <<< "$result" 2>/dev/null || echo "null")
        if [[ "$exp_val" != "$act_val" ]]; then
            fail_fields+=("${key}: expected=${exp_val} actual=${act_val}")
        fi
    done < <(jq -r 'keys[]' <<< "$expect_json" 2>/dev/null || true)

    if [[ ${#fail_fields[@]} -eq 0 ]]; then
        PASS=$((PASS + 1))
        echo "  PASS [${id}] ${desc}"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL [${id}] ${desc}"
        for f in "${fail_fields[@]}"; do echo "       ${f}"; done
        ERRORS+=("[${id}] ${desc}: ${fail_fields[*]}")
    fi
}

echo "guardian eval-bridge — running $(wc -l < "$CASES") cases"
echo ""

while IFS= read -r case_line; do
    [[ -z "$case_line" || "$case_line" == \#* ]] && continue
    c_id=$(jq -r '.id' <<< "$case_line")
    c_desc=$(jq -r '.desc' <<< "$case_line")
    c_tool=$(jq -r '.tool' <<< "$case_line")
    c_input=$(jq -c '.input' <<< "$case_line")
    c_expect=$(jq -c '.expect' <<< "$case_line")
    _run_case "$c_id" "$c_desc" "$c_tool" "$c_input" "$c_expect"
done < "$CASES"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, $((PASS + FAIL)) total"

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "FAILURES:"
    for e in "${ERRORS[@]}"; do echo "  $e"; done
    exit 1
fi
echo "OK — all cases passed"
