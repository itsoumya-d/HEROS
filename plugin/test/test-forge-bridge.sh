#!/usr/bin/env bash
# plugin/test/test-forge-bridge.sh — forge bridge feature tests
#
# Phase 1: Runs existing forge/eval-bridge.sh (BE-01..BE-13, nonce protocol).
#          Requires the real forge binary. Skips if binary absent.
# Phase 2: Plugin-layer tests (FP-01..FP-08) using a stub binary.
#          Tests bridge-level validation and rate-limit injection.
#
# Usage: bash plugin/test/test-forge-bridge.sh
# Requires: bash 4+, jq 1.6+
set -euo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FORGE_BRIDGE="${REPO_ROOT}/forge/mcp-bridge.sh"

PASS=0
FAIL=0
SKIP=0

for _req in jq bash; do
    command -v "$_req" >/dev/null 2>&1 || {
        printf 'test-forge-bridge: %s not found in PATH (required)\n' "$_req" >&2
        exit 1
    }
done

# shellcheck source=plugin/test/test-stub-binary.sh
source "${SCRIPT_DIR}/test-stub-binary.sh"

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
make_forge_stub "$STUB_DIR"

FORGE_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$FORGE_DATA_DIR"' EXIT

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

_batch() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s\n' "$@" > "$tmpfile"
    env "PATH=${STUB_DIR}:${PATH}" bash "$FORGE_BRIDGE" < "$tmpfile" 2>/dev/null || true
    rm -f "$tmpfile"
}

_content() {
    local responses="$1" cid="$2"
    printf '%s\n' "$responses" \
        | jq -rs --argjson id "$cid" \
            'map(select(type=="object" and .id==$id)) | .[0] // {} | .result.content[0].text // "{}"' \
            2>/dev/null || echo "{}"
}

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

INIT_MSG='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fp-eval","version":"1.0"}}}'
NOTIF_MSG='{"jsonrpc":"2.0","method":"notifications/initialized"}'
FROM_SAFE=$'TABLE users\nCOLUMN id serial NOT_NULL'
TO_SAFE=$'TABLE users\nCOLUMN id serial NOT_NULL'

echo "forge bridge plugin eval (BE wrap + FP-01..FP-08)"
echo "bridge: ${FORGE_BRIDGE}"
echo "----------------------------------------------------------------------"

# ── Phase 1: existing eval-bridge.sh (requires real forge binary) ─────────────
FORGE_BIN=""
if [[ -x "${REPO_ROOT}/forge/forge" ]]; then
    FORGE_BIN="${REPO_ROOT}/forge/forge"
elif command -v forge >/dev/null 2>&1; then
    FORGE_BIN="$(command -v forge)"
fi

if [[ -n "$FORGE_BIN" ]]; then
    echo "[Phase 1] Running forge/eval-bridge.sh (13 cases) with binary: ${FORGE_BIN}"
    BE_OUTPUT=""
    BE_RC=0
    BE_OUTPUT=$(bash "${REPO_ROOT}/forge/eval-bridge.sh" 2>/dev/null) || BE_RC=$?
    # Count from output lines
    be_pass=$(printf '%s\n' "$BE_OUTPUT" | grep -c '^PASS' 2>/dev/null || true)
    be_fail=$(printf '%s\n' "$BE_OUTPUT" | grep -c '^FAIL' 2>/dev/null || true)
    be_skip=$(printf '%s\n' "$BE_OUTPUT" | grep -c '^SKIP' 2>/dev/null || true)
    PASS=$(( PASS + be_pass ))
    FAIL=$(( FAIL + be_fail ))
    SKIP=$(( SKIP + be_skip ))
    printf '%s\n' "$BE_OUTPUT"
    if (( BE_RC != 0 && be_fail == 0 )); then
        printf 'FAIL  BE-??   eval-bridge.sh exited non-zero (rc=%d)\n' "$BE_RC"
        FAIL=$(( FAIL + 1 ))
    fi
else
    echo "[Phase 1] forge binary not found — skipping BE-01..BE-13"
    for _n in 01 02 03 04 05 06 07 08 09 10 11 12 13; do
        _skip "BE-${_n}" "nonce protocol" "forge binary not present (need Zero compiler build)"
    done
fi

echo "----------------------------------------------------------------------"
echo "[Phase 2] Plugin-layer tests (FP-01..FP-08) with stub binary"

# ── FP-01: SAFE analysis → _rate_limit field present ──────────────────────────
{
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$FROM_SAFE" "$TO_SAFE")")
    c=$(_content "$out" 2)
    v=$(jq -r 'if has("_rate_limit") then "yes" else "no" end' <<< "$c" 2>/dev/null || echo "no")
    _assert FP-01 "SAFE analysis → _rate_limit field present" "$v" "yes"
}

# ── FP-02: request_id echoed in response ──────────────────────────────────────
{
    extra='{"request_id":"test-req-001"}'
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_analyze_msg 2 "$FROM_SAFE" "$TO_SAFE" "$extra")")
    c=$(_content "$out" 2)
    rid=$(jq -r '.request_id // ""' <<< "$c" 2>/dev/null || echo "")
    _assert FP-02 "request_id echoed in response" "$rid" "test-req-001"
}

# ── FP-03: pipe char in from_schema → INVALID_INPUT ──────────────────────────
{
    pipe_schema="TABLE users|INJECTED_LINE"
    extra_msg=$(jq -cn --arg f "$pipe_schema" --arg t "$TO_SAFE" \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"forge_analyze","arguments":{"from_schema":$f,"to_schema":$t}}}')
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$extra_msg")
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
    _assert FP-03 "pipe char in from_schema → INVALID_INPUT" "$ec" "INVALID_INPUT"
}

# ── FP-04: from_schema > 64 KiB → INVALID_INPUT ──────────────────────────────
{
    big_schema=$(python3 -c "print('COLUMN col' + ' serial NOT_NULL\n' * 7000)" 2>/dev/null) || big_schema=""
    if [[ -n "$big_schema" ]]; then
        extra_msg=$(jq -cn --arg f "$big_schema" --arg t "$TO_SAFE" \
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"forge_analyze","arguments":{"from_schema":$f,"to_schema":$t}}}')
        out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$extra_msg")
        c=$(_content "$out" 2)
        ec=$(jq -r '.error_code // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
        _assert FP-04 "from_schema > 64 KiB → INVALID_INPUT" "$ec" "INVALID_INPUT"
    else
        _skip FP-04 "schema size limit" "python3 not available to generate large schema"
    fi
}

# ── FP-05: rate limit deny-all → RATE_LIMITED ────────────────────────────────
{
    # FORGE_RATE_ANALYZE_IP=0 enables deny-all mode (bridge rejects all calls immediately).
    # This is deterministic without needing burst exhaustion (which requires 11+ calls).
    tmpfile=$(mktemp)
    printf '%s\n' \
        "$INIT_MSG" \
        "$NOTIF_MSG" \
        "$(_analyze_msg 2 "$FROM_SAFE" "$TO_SAFE")" \
        > "$tmpfile"
    out=$(env "PATH=${STUB_DIR}:${PATH}" "FORGE_RATE_ANALYZE_IP=0" bash "$FORGE_BRIDGE" < "$tmpfile" 2>/dev/null || true)
    rm -f "$tmpfile"
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
    _assert FP-05 "rate limit deny-all (FORGE_RATE_ANALYZE_IP=0) → RATE_LIMITED" "$ec" "RATE_LIMITED"
}

# ── FP-06: RATE_LIMITED response includes retry_after_seconds > 0 ─────────────
{
    tmpfile=$(mktemp)
    printf '%s\n' \
        "$INIT_MSG" \
        "$NOTIF_MSG" \
        "$(_analyze_msg 2 "$FROM_SAFE" "$TO_SAFE")" \
        > "$tmpfile"
    out=$(env "PATH=${STUB_DIR}:${PATH}" "FORGE_RATE_ANALYZE_IP=0" bash "$FORGE_BRIDGE" < "$tmpfile" 2>/dev/null || true)
    rm -f "$tmpfile"
    c=$(_content "$out" 2)
    retry=$(jq -r '.retry_after_seconds // 0' <<< "$c" 2>/dev/null || echo "0")
    v="no"
    (( retry > 0 )) && v="yes"
    _assert FP-06 "RATE_LIMITED has retry_after_seconds > 0" "$v" "yes"
}

# ── FP-07: HEROS_API_KEY set + HEROS_DATA_DIR missing → startup error ─────────
{
    tmpfile=$(mktemp)
    printf '%s\n' "$INIT_MSG" > "$tmpfile"
    out=$(env "PATH=${STUB_DIR}:${PATH}" \
        "HEROS_API_KEY=heros_ro_aabbccddeeff00112233445566778899_9988776655443322110000ffeeddccbb" \
        "HEROS_DATA_DIR=/tmp/nonexistent-dir-$$" \
        "HEROS_HMAC_SEED=this-is-a-32-char-seed-for-testing" \
        bash "$FORGE_BRIDGE" < "$tmpfile" 2>/dev/null || true)
    rm -f "$tmpfile"
    # Bridge should exit with a JSON error, not produce an initialize result
    is_error=$(printf '%s\n' "$out" \
        | jq -rs '.[0] // {} | if .error != null or .result == null then "yes" else "no" end' \
        2>/dev/null || echo "no")
    _assert FP-07 "API key + missing DATA_DIR → startup error JSON" "$is_error" "yes"
}

# ── FP-08: valid API key + correct setup → auth passes, analysis succeeds ─────
{
    if command -v python3 >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
        AUTH_SEED="plugin-test-hmac-seed-32chars-ok"
        KEY_ID="aabbccddeeff00112233445566778899"
        SECRET="9988776655443322110000ffeeddccbb"
        HMAC_HASH=$(printf '%s' "${KEY_ID}:${SECRET}" \
            | openssl dgst -sha256 -hmac "$AUTH_SEED" -binary \
            | python3 -c "import sys; print(sys.stdin.buffer.read().hex())" 2>/dev/null) || HMAC_HASH=""

        if [[ -n "$HMAC_HASH" ]]; then
            AUTH_DATA=$(mktemp -d)
            trap 'rm -rf "$AUTH_DATA"' EXIT
            printf '%s ro org_aabbccdd %s 1716000000 0\n' "$KEY_ID" "$HMAC_HASH" \
                > "${AUTH_DATA}/.heros-keys"
            API_KEY="heros_ro_${KEY_ID}_${SECRET}"

            tmpfile=$(mktemp)
            printf '%s\n' \
                "$INIT_MSG" \
                "$NOTIF_MSG" \
                "$(_analyze_msg 2 "$FROM_SAFE" "$TO_SAFE")" \
                > "$tmpfile"
            out=$(env "PATH=${STUB_DIR}:${PATH}" \
                "HEROS_API_KEY=${API_KEY}" \
                "HEROS_DATA_DIR=${AUTH_DATA}" \
                "HEROS_HMAC_SEED=${AUTH_SEED}" \
                bash "$FORGE_BRIDGE" < "$tmpfile" 2>/dev/null || true)
            rm -f "$tmpfile"
            c=$(_content "$out" 2)
            ec=$(jq -r '.error_code // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
            rt=$(jq -r '.risk_tier // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
            ok="no"
            [[ "$ec" == "NONE" && "$rt" == "SAFE" ]] && ok="yes"
            _assert FP-08 "valid API key + correct setup → auth passes" "$ok" "yes"
        else
            _skip FP-08 "auth setup" "HMAC computation failed (openssl/python3 issue)"
        fi
    else
        _skip FP-08 "auth setup" "python3 or openssl not available"
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
echo "----------------------------------------------------------------------"
printf 'forge-bridge: PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"

if (( FAIL > 0 )); then
    exit 1
fi
