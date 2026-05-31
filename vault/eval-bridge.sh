#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# vault/eval-bridge.sh — MCP bridge eval for vault tools
# Runs eval cases from eval-cases.jsonl against the vault MCP bridge.
#
# Special tool markers in eval-cases.jsonl:
#   vault_secret_set_then_get  — set then get in one session; expects get output
#   vault_secret_delete_pending — set then call delete (no token); expects pending response
#   vault_secret_set_overwrite  — set name twice; expects second response (version=2)

set -euo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/mcp-bridge.sh"
CASES="${SCRIPT_DIR}/eval-cases.jsonl"

# Use a temp data dir so each test run starts clean
EVAL_DATA_DIR=""
_cleanup() {
    if [[ -n "$EVAL_DATA_DIR" && -d "$EVAL_DATA_DIR" ]]; then
        rm -rf "$EVAL_DATA_DIR" 2>/dev/null || true
    fi
}
trap _cleanup EXIT

PASS=0; FAIL=0
ERRORS=()

# _mcp_session lines_array → stdout (all JSON-RPC responses, one per line)
# Sends an initialize message plus any additional lines to the bridge.
_mcp_session() {
    local -n _lines_ref="$1"
    local session_input
    session_input=$(printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}')
    local l
    for l in "${_lines_ref[@]}"; do
        session_input+=$'\n'"$l"
    done
    printf '%s\n' "$session_input" | HEROS_DATA_DIR="$EVAL_DATA_DIR" timeout 10 bash "$BRIDGE" 2>/dev/null
}

# _call tool arguments_json → extract last tool result text
_call() {
    local tool="$1" args="$2"
    # shellcheck disable=SC2034  # msgs passed by name to _mcp_session as a nameref
    local msgs=("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":${args}}}")
    local resp
    resp=$(_mcp_session msgs)
    # Filter out notifications, grab the last tools/call response, extract result text
    printf '%s\n' "$resp" \
        | grep -v '"method"' \
        | grep '"id":1' \
        | tail -1 \
        | jq -r '.result.content[0].text' 2>/dev/null || echo '{}'
}

# _run_case id desc tool input_json expect_json
_run_case() {
    local id="$1" desc="$2" tool="$3" input_json="$4" expect_json="$5"

    # Fresh data dir per test case to avoid state bleed
    EVAL_DATA_DIR=$(mktemp -d)

    local result
    result="{}"

    case "$tool" in
        vault_secret_set|vault_secret_get|vault_secret_delete|vault_secret_list)
            result=$(_call "$tool" "$input_json")
            ;;

        vault_secret_set_then_get)
            # Use same session: set then get
            local name
            name=$(jq -r '.name' <<< "$input_json")
            local value
            value=$(jq -r '.value' <<< "$input_json")
            # shellcheck disable=SC2034  # msgs passed by name to _mcp_session as a nameref
            local msgs=(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"vault_secret_set\",\"arguments\":{\"name\":$(jq -cn --arg n "$name" '$n'),\"value\":$(jq -cn --arg v "$value" '$v')}}}"
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"vault_secret_get\",\"arguments\":{\"name\":$(jq -cn --arg n "$name" '$n')}}}"
            )
            local resp
            resp=$(_mcp_session msgs)
            result=$(printf '%s\n' "$resp" \
                | grep -v '"method"' \
                | grep '"id":2' \
                | tail -1 \
                | jq -r '.result.content[0].text' 2>/dev/null || echo '{}')
            ;;

        vault_secret_delete_pending)
            # Set a secret first, then call delete without token to get the nonce prompt
            local name
            name=$(jq -r '.name' <<< "$input_json")
            # shellcheck disable=SC2034  # msgs passed by name to _mcp_session as a nameref
            local msgs=(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"vault_secret_set\",\"arguments\":{\"name\":$(jq -cn --arg n "$name" '$n'),\"value\":\"placeholder\"}}}"
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"vault_secret_delete\",\"arguments\":{\"name\":$(jq -cn --arg n "$name" '$n')}}}"
            )
            local resp
            resp=$(_mcp_session msgs)
            result=$(printf '%s\n' "$resp" \
                | grep -v '"method"' \
                | grep '"id":2' \
                | tail -1 \
                | jq -r '.result.content[0].text' 2>/dev/null || echo '{}')
            ;;

        vault_secret_delete_bad_token)
            # Set a secret first, then call delete with an invalid/bad token
            local name
            name=$(jq -r '.name' <<< "$input_json")
            local token
            token=$(jq -r '.human_acknowledgment_token' <<< "$input_json")
            # shellcheck disable=SC2034  # msgs passed by name to _mcp_session as a nameref
            local msgs=(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"vault_secret_set\",\"arguments\":{\"name\":$(jq -cn --arg n "$name" '$n'),\"value\":\"placeholder\"}}}"
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"vault_secret_delete\",\"arguments\":{\"name\":$(jq -cn --arg n "$name" '$n'),\"human_acknowledgment_token\":$(jq -cn --arg t "$token" '$t')}}}"
            )
            local resp
            resp=$(_mcp_session msgs)
            result=$(printf '%s\n' "$resp" \
                | grep -v '"method"' \
                | grep '"id":2' \
                | tail -1 \
                | jq -r '.result.content[0].text' 2>/dev/null || echo '{}')
            ;;

        vault_secret_set_overwrite)
            # Set the same name twice, check version=2 in second response
            local name
            name=$(jq -r '.name' <<< "$input_json")
            local value
            value=$(jq -r '.value' <<< "$input_json")
            # shellcheck disable=SC2034  # msgs passed by name to _mcp_session as a nameref
            local msgs=(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"vault_secret_set\",\"arguments\":{\"name\":$(jq -cn --arg n "$name" '$n'),\"value\":\"v1\"}}}"
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"vault_secret_set\",\"arguments\":{\"name\":$(jq -cn --arg n "$name" '$n'),\"value\":$(jq -cn --arg v "$value" '$v')}}}"
            )
            local resp
            resp=$(_mcp_session msgs)
            result=$(printf '%s\n' "$resp" \
                | grep -v '"method"' \
                | grep '"id":2' \
                | tail -1 \
                | jq -r '.result.content[0].text' 2>/dev/null || echo '{}')
            ;;

        *)
            result='{"error_code":"UNKNOWN_TEST_TOOL"}'
            ;;
    esac

    # Check each expected field
    local fail_fields=()
    while IFS= read -r key; do
        local exp_val act_val
        exp_val=$(jq -c --arg k "$key" '.[$k]' <<< "$expect_json" 2>/dev/null || echo "null")
        act_val=$(jq -c --arg k "$key" '.[$k]' <<< "$result"      2>/dev/null || echo "null")
        if [[ "$exp_val" != "$act_val" ]]; then
            fail_fields+=("${key}: expected=${exp_val} actual=${act_val}")
        fi
    done < <(jq -r 'keys[]' <<< "$expect_json" 2>/dev/null || true)

    rm -rf "$EVAL_DATA_DIR" 2>/dev/null || true
    EVAL_DATA_DIR=""

    if [[ ${#fail_fields[@]} -eq 0 ]]; then
        PASS=$(( PASS + 1 ))
        printf '  PASS [%s] %s\n' "$id" "$desc"
    else
        FAIL=$(( FAIL + 1 ))
        printf '  FAIL [%s] %s\n' "$id" "$desc"
        for f in "${fail_fields[@]}"; do printf '       %s\n' "$f"; done
        ERRORS+=("[${id}] ${desc}: ${fail_fields[*]}")
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────
echo "vault eval-bridge — running $(grep -c . "$CASES") cases"
echo ""

while IFS= read -r case_line; do
    [[ -z "$case_line" || "$case_line" == \#* ]] && continue
    c_id=$(jq -r '.id'     <<< "$case_line")
    c_desc=$(jq -r '.desc' <<< "$case_line")
    c_tool=$(jq -r '.tool' <<< "$case_line")
    c_input=$(jq -c '.input'   <<< "$case_line")
    c_expect=$(jq -c '.expect' <<< "$case_line")
    _run_case "$c_id" "$c_desc" "$c_tool" "$c_input" "$c_expect"
done < "$CASES"

echo ""
printf 'Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$(( PASS + FAIL ))"

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "FAILURES:"
    for e in "${ERRORS[@]}"; do printf '  %s\n' "$e"; done
    exit 1
fi
echo "OK — all cases passed"
