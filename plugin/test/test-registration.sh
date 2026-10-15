#!/usr/bin/env bash
# plugin/test/test-registration.sh — MCP protocol compliance tests (REG-01..REG-15)
#
# Tests the MCP handshake for both forge and ledger bridges without needing
# the Zero-compiled binary. Uses stub binaries placed in PATH.
#
# Usage: bash plugin/test/test-registration.sh
# Requires: bash 4+, jq 1.6+
set -euo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FORGE_BRIDGE="${REPO_ROOT}/forge/mcp-bridge.sh"
LEDGER_BRIDGE="${REPO_ROOT}/ledger/mcp-bridge.sh"

PASS=0
FAIL=0
SKIP=0

# ── Pre-flight ────────────────────────────────────────────────────────────────
for _req in jq bash; do
    command -v "$_req" >/dev/null 2>&1 || {
        printf 'test-registration: %s not found in PATH (required)\n' "$_req" >&2
        exit 1
    }
done
[[ -f "$FORGE_BRIDGE" ]] || { printf 'test-registration: forge bridge not found: %s\n' "$FORGE_BRIDGE" >&2; exit 1; }
[[ -f "$LEDGER_BRIDGE" ]] || { printf 'test-registration: ledger bridge not found: %s\n' "$LEDGER_BRIDGE" >&2; exit 1; }

# ── Stub setup ────────────────────────────────────────────────────────────────
# shellcheck source=plugin/test/test-stub-binary.sh
source "${SCRIPT_DIR}/test-stub-binary.sh"

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

make_forge_stub "$STUB_DIR"
make_ledger_stub "$STUB_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────
_assert() {
    local id="$1" desc="$2" got="$3" want="$4"
    if [[ "$got" == "$want" ]]; then
        printf 'PASS  %-8s %s\n' "$id" "$desc"
        PASS=$(( PASS + 1 ))
    else
        printf 'FAIL  %-8s %s\n' "$id" "$desc"
        printf '      want: %s\n' "$want"
        printf '      got:  %s\n' "$got"
        FAIL=$(( FAIL + 1 ))
    fi
}

_skip() {
    local id="$1" desc="$2" reason="$3"
    printf 'SKIP  %-8s %s (%s)\n' "$id" "$desc" "$reason"
    SKIP=$(( SKIP + 1 ))
}

# Send messages to a bridge via temp file; captures stdout.
_batch_forge() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s\n' "$@" > "$tmpfile"
    env "PATH=${STUB_DIR}:${PATH}" bash "$FORGE_BRIDGE" < "$tmpfile" 2>/dev/null || true
    rm -f "$tmpfile"
}

_batch_ledger() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s\n' "$@" > "$tmpfile"
    env "PATH=${STUB_DIR}:${PATH}" bash "$LEDGER_BRIDGE" < "$tmpfile" 2>/dev/null || true
    rm -f "$tmpfile"
}

# Extract .result or .error from the first matching response by id.
_field() {
    local responses="$1" cid="$2" field="$3"
    printf '%s\n' "$responses" \
        | jq -rs --argjson id "$cid" --arg f "$field" \
            'map(select(type=="object" and .id==$id)) | .[0] // {} | .[$f] // null' \
            2>/dev/null || echo "null"
}

# Extract content[0].text from a tools/call response.
_content() {
    local responses="$1" cid="$2"
    printf '%s\n' "$responses" \
        | jq -rs --argjson id "$cid" \
            'map(select(type=="object" and .id==$id)) | .[0] // {} | .result.content[0].text // "{}"' \
            2>/dev/null || echo "{}"
}

INIT_MSG='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"reg-eval","version":"1.0"}}}'
NOTIF_MSG='{"jsonrpc":"2.0","method":"notifications/initialized"}'

echo "plugin registration eval (MCP protocol compliance — REG-01..REG-15)"
echo "forge bridge:  ${FORGE_BRIDGE}"
echo "ledger bridge: ${LEDGER_BRIDGE}"
echo "stub dir:      ${STUB_DIR}"
echo "----------------------------------------------------------------------"

# ── REG-01: forge bridge startup with stub binary → starts cleanly ─────────
{
    out=$(_batch_forge "$INIT_MSG")
    v=$(printf '%s\n' "$out" | jq -rs '.[0] // {} | has("result")' 2>/dev/null || echo "false")
    _assert REG-01 "forge: initialize with stub binary succeeds" "$v" "true"
}

# ── REG-02: ledger bridge startup with stub binary → starts cleanly ─────────
{
    out=$(_batch_ledger "$INIT_MSG")
    v=$(printf '%s\n' "$out" | jq -rs '.[0] // {} | has("result")' 2>/dev/null || echo "false")
    _assert REG-02 "ledger: initialize with stub binary succeeds" "$v" "true"
}

# ── REG-03: forge initialize → serverInfo.name == "forge" ───────────────────
{
    out=$(_batch_forge "$INIT_MSG")
    v=$(printf '%s\n' "$out" \
        | jq -rs '.[0] // {} | .result.serverInfo.name // ""' 2>/dev/null || echo "")
    _assert REG-03 "forge: serverInfo.name == forge" "$v" "forge"
}

# ── REG-04: ledger initialize → serverInfo.name == "ledger" ─────────────────
{
    out=$(_batch_ledger "$INIT_MSG")
    v=$(printf '%s\n' "$out" \
        | jq -rs '.[0] // {} | .result.serverInfo.name // ""' 2>/dev/null || echo "")
    _assert REG-04 "ledger: serverInfo.name == ledger" "$v" "ledger"
}

# ── REG-05: forge tools/list → forge_analyze present with inputSchema ────────
{
    out=$(_batch_forge "$INIT_MSG" "$NOTIF_MSG" \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    v=$(printf '%s\n' "$out" \
        | jq -rs --argjson id 2 \
            'map(select(type=="object" and .id==$id)) | .[0] // {} |
             .result.tools // [] | map(select(.name=="forge_analyze")) | length > 0' \
        2>/dev/null || echo "false")
    _assert REG-05 "forge: tools/list contains forge_analyze" "$v" "true"
}

# ── REG-06: ledger tools/list → all four tools present ───────────────────────
{
    out=$(_batch_ledger "$INIT_MSG" "$NOTIF_MSG" \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    v=$(printf '%s\n' "$out" \
        | jq -rs --argjson id 2 \
            'map(select(type=="object" and .id==$id)) | .[0] // {} |
             .result.tools // [] |
             [.[].name] | sort |
             . == ["ledger_invoice_count","ledger_invoice_create","ledger_invoice_list","ledger_register"]' \
        2>/dev/null || echo "false")
    _assert REG-06 "ledger: tools/list has all 4 tools" "$v" "true"
}

# ── REG-07: tools/list before initialize → -32002 ────────────────────────────
{
    out=$(_batch_forge '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
    code=$(printf '%s\n' "$out" | jq -rs '.[0] // {} | .error.code // 0' 2>/dev/null || echo "0")
    _assert REG-07 "forge: tools/list before initialize → -32002" "$code" "-32002"
}

# ── REG-08a: forge double-initialize → -32002 ────────────────────────────────
{
    out=$(_batch_forge "$INIT_MSG" "$NOTIF_MSG" "$INIT_MSG")
    code=$(printf '%s\n' "$out" \
        | jq -rs 'map(select(type=="object")) | last // {} | .error.code // 0' 2>/dev/null || echo "0")
    _assert REG-08a "forge: double-initialize → -32002" "$code" "-32002"
}

# ── REG-08b: ledger double-initialize → -32003 ───────────────────────────────
{
    out=$(_batch_ledger "$INIT_MSG" "$NOTIF_MSG" "$INIT_MSG")
    code=$(printf '%s\n' "$out" \
        | jq -rs 'map(select(type=="object")) | last // {} | .error.code // 0' 2>/dev/null || echo "0")
    _assert REG-08b "ledger: double-initialize → -32003" "$code" "-32003"
}

# ── REG-09: invalid JSON → -32700 ────────────────────────────────────────────
{
    out=$(_batch_forge 'not-valid-json')
    code=$(printf '%s\n' "$out" | jq -rs '.[0] // {} | .error.code // 0' 2>/dev/null || echo "0")
    _assert REG-09 "forge: invalid JSON → -32700 parse error" "$code" "-32700"
}

# ── REG-10: non-object JSON (array) → -32600 ─────────────────────────────────
{
    out=$(_batch_forge '[1,2,3]')
    code=$(printf '%s\n' "$out" | jq -rs '.[0] // {} | .error.code // 0' 2>/dev/null || echo "0")
    _assert REG-10 "forge: array message → -32600 invalid request" "$code" "-32600"
}

# ── REG-11: missing jsonrpc field → -32600 ───────────────────────────────────
{
    out=$(_batch_forge '{"id":1,"method":"initialize","params":{}}')
    code=$(printf '%s\n' "$out" | jq -rs '.[0] // {} | .error.code // 0' 2>/dev/null || echo "0")
    _assert REG-11 "forge: missing jsonrpc field → -32600" "$code" "-32600"
}

# ── REG-12: non-string method → -32600 ───────────────────────────────────────
{
    out=$(_batch_forge '{"jsonrpc":"2.0","id":1,"method":42,"params":{}}')
    code=$(printf '%s\n' "$out" | jq -rs '.[0] // {} | .error.code // 0' 2>/dev/null || echo "0")
    _assert REG-12 "forge: non-string method → -32600" "$code" "-32600"
}

# ── REG-13: message > 1 MiB → -32001 ─────────────────────────────────────────
{
    # Generate a message slightly over 1 MiB (1048576 bytes)
    big_msg=$(python3 -c "
import json
msg = {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"x\":\"A\"*1100000}}
print(json.dumps(msg))
" 2>/dev/null) || big_msg=""
    if [[ -n "$big_msg" ]]; then
        out=$(_batch_forge "$big_msg")
        code=$(printf '%s\n' "$out" | jq -rs '.[0] // {} | .error.code // 0' 2>/dev/null || echo "0")
        _assert REG-13 "forge: message >1 MiB → -32001" "$code" "-32001"
    else
        _skip REG-13 "message size limit" "python3 not available to generate oversized message"
    fi
}

# ── REG-14: oversized id (>4096 bytes) → -32600 with id:null ─────────────────
{
    long_id=$(python3 -c "print('x'*5000)" 2>/dev/null) || long_id=""
    if [[ -n "$long_id" ]]; then
        oversized_msg=$(jq -cn --arg lid "$long_id" \
            '{"jsonrpc":"2.0","id":$lid,"method":"initialize","params":{}}')
        out=$(_batch_forge "$oversized_msg")
        id_val=$(printf '%s\n' "$out" | jq -rs '.[0] // {} | .id' 2>/dev/null || echo "null")
        code=$(printf '%s\n' "$out" | jq -rs '.[0] // {} | .error.code // 0' 2>/dev/null || echo "0")
        id_ok="false"
        [[ "$id_val" == "null" ]] && id_ok="true"
        _assert REG-14 "forge: oversized id → id:null in error response" "$id_ok" "true"
    else
        _skip REG-14 "oversized id" "python3 not available to generate oversized id"
    fi
}

# ── REG-15: ping → empty result {} ───────────────────────────────────────────
{
    out=$(_batch_forge "$INIT_MSG" "$NOTIF_MSG" \
        '{"jsonrpc":"2.0","id":2,"method":"ping","params":{}}')
    result=$(printf '%s\n' "$out" \
        | jq -rs --argjson id 2 \
            'map(select(type=="object" and .id==$id)) | .[0] // {} | .result' \
        2>/dev/null || echo "null")
    _assert REG-15 "forge: ping → result {}" "$result" "{}"
}

# ── Summary ───────────────────────────────────────────────────────────────────
echo "----------------------------------------------------------------------"
printf 'registration: PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"

if (( FAIL > 0 )); then
    exit 1
fi
