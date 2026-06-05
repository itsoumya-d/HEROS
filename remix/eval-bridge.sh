#!/usr/bin/env bash
# remix/eval-bridge.sh — stateless harness for remix_render (heros.ui/v1).
# Spawns a fresh MCP session per case, asserts expected fields. No disk state.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/mcp-bridge.sh"
CASES="${SCRIPT_DIR}/eval-cases.jsonl"

# Host allowlist exercised by RX-16/RX-17 (and used by the valid full spec).
export REMIX_ALLOWED_HOSTS="cdn.example.com,maps.example.com"

PASS=0; FAIL=0; FAILED_IDS=()

_session() {
    # $1 = tool name, $2 = arguments JSON ; emits the tool result JSON (text payload)
    local tool="$1" args="$2"
    {
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"eval","version":"1"}}}'
        jq -cn --arg t "$tool" --argjson a "$args" \
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":$t,"arguments":$a}}'
    } | bash "$BRIDGE" 2>/dev/null \
      | jq -rc 'select(.id==2) | .result.content[0].text' 2>/dev/null | head -n1
}

while IFS= read -r case_line; do
    [[ -z "$case_line" ]] && continue
    cid=$(jq -r '.id' <<< "$case_line")
    desc=$(jq -r '.description' <<< "$case_line")
    tool=$(jq -r '.tool' <<< "$case_line")
    args=$(jq -c '.arguments' <<< "$case_line")
    expect=$(jq -c '.expect' <<< "$case_line")

    result=$(_session "$tool" "$args")
    if [[ -z "$result" ]]; then
        FAIL=$((FAIL+1)); FAILED_IDS+=("$cid"); printf '  ✗ %s  %s\n      (no result)\n' "$cid" "$desc"; continue
    fi

    # Every expected key must match the actual result.
    mismatch=""
    while IFS= read -r k; do
        want=$(jq -c --arg k "$k" '.[$k]' <<< "$expect")
        got=$(jq -c --arg k "$k" '.[$k] // null' <<< "$result")
        if [[ "$want" != "$got" ]]; then mismatch="${mismatch} ${k}(want=${want} got=${got})"; fi
    done < <(jq -r 'keys[]' <<< "$expect")

    if [[ -z "$mismatch" ]]; then
        PASS=$((PASS+1)); printf '  ✓ %s  %s\n' "$cid" "$desc"
    else
        FAIL=$((FAIL+1)); FAILED_IDS+=("$cid")
        printf '  ✗ %s  %s\n      mismatch:%s\n      result: %s\n' "$cid" "$desc" "$mismatch" "$result"
    fi
done < "$CASES"

echo "------------------------------------------------------------"
printf 'remix eval: %d passed, %d failed (of %d)\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED_IDS[*]}"; exit 1; fi
echo "ALL REMIX EVALS PASSED"
