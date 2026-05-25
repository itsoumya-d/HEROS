#!/usr/bin/env bash
# forge/eval-bridge.sh — V39 bridge eval: approval_nonce / decision_required protocol
#
# Tests the MCP bridge layer (mcp-bridge.sh), not the forge binary directly.
# Specifically verifies V39: when decision_required:true, the bridge injects
# approval_nonce + approval_prompt, and a valid nonce redeems to proceed_ok:true.
#
# Usage: bash forge/eval-bridge.sh
# Requires: bash 4+, jq 1.6+, forge binary present (forge/forge or forge in PATH)
set -euo pipefail
LANG=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/mcp-bridge.sh"
PASS=0
FAIL=0
SKIP=0

# Pre-flight: same requirements as mcp-bridge.sh itself
for _req in jq bash; do
    command -v "$_req" >/dev/null 2>&1 || { printf 'eval-bridge: %s not found in PATH (required)\n' "$_req" >&2; exit 1; }
done
if [[ ! -x "$BRIDGE" && ! -f "$BRIDGE" ]]; then
    printf 'eval-bridge: bridge not found at %s\n' "$BRIDGE" >&2; exit 1
fi

_assert() {
    local id="$1" desc="$2" got="$3" want="$4"
    if [[ "$got" == "$want" ]]; then
        printf 'PASS  %-6s %s\n' "$id" "$desc"
        PASS=$(( PASS + 1 ))
    else
        printf 'FAIL  %-6s %s\n' "$id" "$desc"
        printf '      want: %s\n' "$want"
        printf '      got:  %s\n' "$got"
        FAIL=$(( FAIL + 1 ))
    fi
}

_skip() {
    local id="$1" desc="$2" reason="$3"
    printf 'SKIP  %-6s %s (%s)\n' "$id" "$desc" "$reason"
    SKIP=$(( SKIP + 1 ))
}

# Send multiple JSON-RPC messages (one per arg) to bridge via temp file; return stdout.
_batch() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s\n' "$@" > "$tmpfile"
    bash "$BRIDGE" < "$tmpfile" 2>/dev/null || true
    rm -f "$tmpfile"
}

# Given bridge output (multiple JSON lines) and an integer id, return content[0].text.
_content() {
    local responses="$1" cid="$2"
    printf '%s\n' "$responses" \
        | jq -rs --argjson id "$cid" \
            'map(select(type=="object" and .id==$id)) | .[0] // {} | .result.content[0].text // "{}"' \
            2>/dev/null \
        || echo "{}"
}

# Build a tools/call message for forge_analyze.
# Args: id from_schema to_schema [extra_args_json_object]
_analyze_msg() {
    local id="$1" from_s="$2" to_s="$3" extra="${4:-}"
    local args
    args=$(jq -cn --arg f "$from_s" --arg t "$to_s" '{"from_schema":$f,"to_schema":$t}')
    if [[ -n "$extra" ]]; then
        args=$(jq -c --argjson x "$extra" '. + $x' <<< "$args")
    fi
    jq -cn --argjson id "$id" --argjson a "$args" \
        '{"jsonrpc":"2.0","id":$id,"method":"tools/call","params":{"name":"forge_analyze","arguments":$a}}'
}

# Standard MCP session-start messages (no response for NOTIF).
INIT_MSG='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"be-eval","version":"1.0"}}}'
NOTIF_MSG='{"jsonrpc":"2.0","method":"notifications/initialized"}'

# Schema fixtures
FROM_CRIT=$'TABLE users\nCOLUMN id serial NOT_NULL'
TO_CRIT=$'TABLE posts\nCOLUMN id serial NOT_NULL'     # drop users + add posts = CRITICAL
FROM_SAFE=$'TABLE users\nCOLUMN id serial NOT_NULL'
TO_SAFE=$'TABLE users\nCOLUMN id serial NOT_NULL'     # identical = SAFE

echo "forge bridge eval (V39 approval-nonce protocol)"
echo "bridge: ${BRIDGE}"
echo "----------------------------------------"

# ── BE-01: decision_required migration → approval_nonce injected ──────────
{
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$FROM_CRIT" "$TO_CRIT")")
    c=$(_content "$out" 2)
    v=$(jq -r 'if ((.approval_nonce//"") | length) > 0 then "yes" else "no" end' <<< "$c" 2>/dev/null || echo "no")
    _assert BE-01 "CRITICAL migration → approval_nonce present" "$v" "yes"
}

# ── BE-02: SAFE migration → no approval_nonce ─────────────────────────────
{
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$FROM_SAFE" "$TO_SAFE")")
    c=$(_content "$out" 2)
    v=$(jq -r 'if ((.approval_nonce//"") | length) > 0 then "yes" else "no" end' <<< "$c" 2>/dev/null || echo "no")
    _assert BE-02 "SAFE migration → no approval_nonce" "$v" "no"
}

# ── BE-03: unrecognized nonce → INVALID_ACKNOWLEDGMENT_TOKEN ─────────────
{
    extra='{"human_acknowledgment_token":"deadbeef0000000001"}'
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$FROM_CRIT" "$TO_CRIT" "$extra")")
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "MISSING"' <<< "$c" 2>/dev/null || echo "MISSING")
    _assert BE-03 "unrecognized nonce → INVALID_ACKNOWLEDGMENT_TOKEN" "$ec" "INVALID_ACKNOWLEDGMENT_TOKEN"
}

# ── BE-04: nonce roundtrip → proceed_ok:true (requires bash 4+ coproc) ────
if (( BASH_VERSINFO[0] >= 4 )); then
    # Use coprocess to keep bridge alive across two sequential calls within same session.
    # First call obtains approval_nonce; second call redeems it with human_acknowledgment_token.
    be04_result="fail:unknown"

    coproc FORGE { bash "$BRIDGE" 2>/dev/null; }

    # Initialize session
    printf '%s\n' "$INIT_MSG" >&"${FORGE[1]}"
    IFS= read -r -t 5 _ir <&"${FORGE[0]}" 2>/dev/null || true
    printf '%s\n' "$NOTIF_MSG" >&"${FORGE[1]}"

    # First call: get nonce
    printf '%s\n' "$(_analyze_msg 2 "$FROM_CRIT" "$TO_CRIT")" >&"${FORGE[1]}"
    IFS= read -r -t 10 _r1 <&"${FORGE[0]}" 2>/dev/null || true

    _nonce=$(jq -r '.result.content[0].text | fromjson | .approval_nonce // ""' \
        <<< "${_r1:-{}}" 2>/dev/null) || _nonce=""

    if [[ -n "$_nonce" ]]; then
        # Second call: redeem nonce
        _extra2=$(jq -cn --arg h "$_nonce" '{"human_acknowledgment_token":$h}')
        printf '%s\n' "$(_analyze_msg 3 "$FROM_CRIT" "$TO_CRIT" "$_extra2")" >&"${FORGE[1]}"
        IFS= read -r -t 10 _r2 <&"${FORGE[0]}" 2>/dev/null || true
        _pok=$(jq -r '.result.content[0].text | fromjson | .proceed_ok // false' \
            <<< "${_r2:-{}}" 2>/dev/null) || _pok="false"
        [[ "$_pok" == "true" ]] && be04_result="pass" || be04_result="fail:proceed_ok=${_pok}"
    else
        be04_result="fail:no nonce in first response"
    fi

    # Close bridge: send SIGTERM, then wait for exit
    kill "$FORGE_PID" 2>/dev/null || true
    wait "$FORGE_PID" 2>/dev/null || true

    if [[ "$be04_result" == "pass" ]]; then
        _assert BE-04 "valid nonce roundtrip → proceed_ok:true" "yes" "yes"
    else
        _assert BE-04 "valid nonce roundtrip → proceed_ok:true" "$be04_result" "pass"
    fi
else
    _skip BE-04 "valid nonce roundtrip" "requires bash 4+ for coproc (got bash ${BASH_VERSION})"
fi

# ── BE-05: decision_required migration → approval_prompt present ──────────
{
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$FROM_CRIT" "$TO_CRIT")")
    c=$(_content "$out" 2)
    v=$(jq -r 'if ((.approval_prompt//"") | length) > 0 then "yes" else "no" end' <<< "$c" 2>/dev/null || echo "no")
    _assert BE-05 "CRITICAL migration → approval_prompt present" "$v" "yes"
}

# ── BE-06: HIGH migration (set_not_null) → approval_nonce ─────────────────
{
    f=$'TABLE users\nCOLUMN id serial NOT_NULL\nCOLUMN bio text NULLABLE'
    t=$'TABLE users\nCOLUMN id serial NOT_NULL\nCOLUMN bio text NOT_NULL'
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$f" "$t")")
    c=$(_content "$out" 2)
    v=$(jq -r 'if ((.approval_nonce//"") | length) > 0 then "yes" else "no" end' <<< "$c" 2>/dev/null || echo "no")
    _assert BE-06 "HIGH migration (set_not_null) → approval_nonce present" "$v" "yes"
}

# ── BE-07: tools/call before initialize → JSON-RPC error ──────────────────
{
    out=$(_batch "$(_analyze_msg 2 "$FROM_SAFE" "$TO_SAFE")" 2>/dev/null) || out=""
    v=$(printf '%s\n' "$out" | jq -rs '.[0] // {} | .error != null' 2>/dev/null || echo "false")
    _assert BE-07 "tools/call before initialize → JSON-RPC error" "$v" "true"
}

# ── BE-08: NOTABLE migration (add nullable col) → no approval_nonce ───────
{
    f=$'TABLE users\nCOLUMN id serial NOT_NULL'
    t=$'TABLE users\nCOLUMN id serial NOT_NULL\nCOLUMN bio text NULLABLE'
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$f" "$t")")
    c=$(_content "$out" 2)
    v=$(jq -r 'if ((.approval_nonce//"") | length) > 0 then "yes" else "no" end' <<< "$c" 2>/dev/null || echo "no")
    _assert BE-08 "NOTABLE migration (add nullable col) → no approval_nonce" "$v" "no"
}

# ── BE-09: nonce single-use — second redemption rejected ──────────────────
if (( BASH_VERSINFO[0] >= 4 )); then
    be09_result="fail:unknown"

    coproc FORGE2 { bash "$BRIDGE" 2>/dev/null; }

    printf '%s\n' "$INIT_MSG" >&"${FORGE2[1]}"
    IFS= read -r -t 5 _ir9 <&"${FORGE2[0]}" 2>/dev/null || true
    printf '%s\n' "$NOTIF_MSG" >&"${FORGE2[1]}"

    # Get nonce
    printf '%s\n' "$(_analyze_msg 2 "$FROM_CRIT" "$TO_CRIT")" >&"${FORGE2[1]}"
    IFS= read -r -t 10 _r9a <&"${FORGE2[0]}" 2>/dev/null || true
    _n9=$(jq -r '.result.content[0].text | fromjson | .approval_nonce // ""' \
        <<< "${_r9a:-{}}" 2>/dev/null) || _n9=""

    if [[ -n "$_n9" ]]; then
        _e9=$(jq -cn --arg h "$_n9" '{"human_acknowledgment_token":$h}')
        # First redemption
        printf '%s\n' "$(_analyze_msg 3 "$FROM_CRIT" "$TO_CRIT" "$_e9")" >&"${FORGE2[1]}"
        IFS= read -r -t 10 _r9b <&"${FORGE2[0]}" 2>/dev/null || true
        # Second redemption (same nonce — must be rejected)
        printf '%s\n' "$(_analyze_msg 4 "$FROM_CRIT" "$TO_CRIT" "$_e9")" >&"${FORGE2[1]}"
        IFS= read -r -t 10 _r9c <&"${FORGE2[0]}" 2>/dev/null || true
        _ec9=$(jq -r '.result.content[0].text | fromjson | .error_code // "MISSING"' \
            <<< "${_r9c:-{}}" 2>/dev/null) || _ec9="MISSING"
        [[ "$_ec9" == "INVALID_ACKNOWLEDGMENT_TOKEN" ]] \
            && be09_result="pass" \
            || be09_result="fail:second redemption got error_code=${_ec9}"
    else
        be09_result="fail:no nonce"
    fi

    kill "$FORGE2_PID" 2>/dev/null || true
    wait "$FORGE2_PID" 2>/dev/null || true

    if [[ "$be09_result" == "pass" ]]; then
        _assert BE-09 "nonce is single-use: second redemption rejected" "yes" "yes"
    else
        _assert BE-09 "nonce is single-use: second redemption rejected" "$be09_result" "pass"
    fi
else
    _skip BE-09 "nonce single-use" "requires bash 4+ for coproc"
fi

# ── BE-10: cross-session nonce isolation (process-local state) ────────────
{
    # Get a real nonce from one bridge session, then try to redeem it in a new session.
    # Since _PENDING_APPROVALS is process-local bash state, the new session won't recognize it.
    out1=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$FROM_CRIT" "$TO_CRIT")")
    c1=$(_content "$out1" 2)
    _ncs=$(jq -r '.approval_nonce // ""' <<< "$c1" 2>/dev/null) || _ncs=""

    if [[ -n "$_ncs" ]]; then
        _xtra=$(jq -cn --arg h "$_ncs" '{"human_acknowledgment_token":$h}')
        out2=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$FROM_CRIT" "$TO_CRIT" "$_xtra")")
        c2=$(_content "$out2" 2)
        ec_cs=$(jq -r '.error_code // "MISSING"' <<< "$c2" 2>/dev/null || echo "MISSING")
        _assert BE-10 "cross-session nonce rejected (process-local isolation)" \
            "$ec_cs" "INVALID_ACKNOWLEDGMENT_TOKEN"
    else
        _skip BE-10 "cross-session nonce isolation" "BE-01 produced no nonce; check bridge"
    fi
}

# ── BE-11: RT-109 — "@" nonce → format rejection, not array corruption ────
# If "@" were accepted as a key, ${_PENDING_APPROVALS[@]+x} would match the
# entire array and unset "[@]" would wipe all pending approvals.
{
    extra='{"human_acknowledgment_token":"@"}'
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$FROM_CRIT" "$TO_CRIT" "$extra")")
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "MISSING"' <<< "$c" 2>/dev/null || echo "MISSING")
    _assert BE-11 "RT-109: '@' nonce → format-rejected (not array wipe)" "$ec" "INVALID_ACKNOWLEDGMENT_TOKEN"
}

# ── BE-12: RT-109 — wrong-length nonce → format rejection ─────────────────
{
    extra='{"human_acknowledgment_token":"deadbeef0000000"}'   # 15 chars, not 16
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$FROM_CRIT" "$TO_CRIT" "$extra")")
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "MISSING"' <<< "$c" 2>/dev/null || echo "MISSING")
    _assert BE-12 "RT-109: 15-char nonce → format-rejected" "$ec" "INVALID_ACKNOWLEDGMENT_TOKEN"
}

# ── BE-13: RT-109 — nonce with non-hex chars → format rejection ───────────
{
    extra='{"human_acknowledgment_token":"DEADBEEF0000GGGG"}'   # uppercase + G
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$FROM_CRIT" "$TO_CRIT" "$extra")")
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "MISSING"' <<< "$c" 2>/dev/null || echo "MISSING")
    _assert BE-13 "RT-109: uppercase/non-hex nonce → format-rejected" "$ec" "INVALID_ACKNOWLEDGMENT_TOKEN"
}

echo ""
printf 'bridge-eval: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
