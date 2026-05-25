#!/usr/bin/env bash
# ledger/eval-bridge-auth.sh — V44 API key authentication regression suite
# Tests mcp-bridge.sh _validate_api_key + _audit against cases AE-01..AE-08.
#
# A minimal ledger stub is created in the temp dir so the bridge can start
# (bridge exits at startup if binary is missing). The stub returns ORG_NOT_FOUND
# for all commands; auth rejection cases are caught before the binary is invoked.
#
# Usage: bash ledger/eval-bridge-auth.sh
# Requires: bash 4+, jq 1.6+, openssl, xxd, python3
set -euo pipefail
LANG=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/mcp-bridge.sh"
PASS=0
FAIL=0
SKIP=0

# ── Pre-flight ────────────────────────────────────────────────────────────────
for _req in jq bash openssl xxd python3; do
    command -v "$_req" >/dev/null 2>&1 || {
        printf 'eval-bridge-auth: %s not found in PATH (required)\n' "$_req" >&2
        exit 1
    }
done
[[ -f "$BRIDGE" ]] || {
    printf 'eval-bridge-auth: bridge not found: %s\n' "$BRIDGE" >&2
    exit 1
}

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

# ── Test fixture setup ────────────────────────────────────────────────────────
SEED="eval-only-hmac-seed-not-for-production"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Minimal ledger stub: bridge checks binary exists at startup; stub lets it proceed.
# Stub returns a non-auth error so auth pass-through tests see a non-auth response.
cat > "${TEST_DIR}/ledger" << 'STUB'
#!/bin/sh
printf '{"error_code":"ORG_NOT_FOUND","error":"eval stub","retryable":false}\n'
STUB
chmod +x "${TEST_DIR}/ledger"

# Key material: 32 lowercase hex chars each (128-bit key_id + 128-bit secret)
RW_KEY_ID="aabbccddeeff00112233445566778899"
RW_SECRET="9988776655443322110000ffeeddccbb"
RO_KEY_ID="00112233445566778899aabbccddeeff"
RO_SECRET="ffeeddccbbaa99887766554433221100"
REV_KEY_ID="deadbeefdeadbeefdeadbeefdeadbeef"
REV_SECRET="cafebabecafebabecafebabecafebabe"

# HMAC-SHA256(key=SEED, msg=key_id:secret) — must match _validate_api_key algorithm
_hmac() {
    printf '%s' "${1}:${2}" | openssl dgst -sha256 -hmac "$SEED" -binary | xxd -p -c 32
}
RW_HASH=$(_hmac "$RW_KEY_ID" "$RW_SECRET")
RO_HASH=$(_hmac "$RO_KEY_ID" "$RO_SECRET")
REV_HASH=$(_hmac "$REV_KEY_ID" "$REV_SECRET")

# .heros-keys: key_id scope org_id hmac_hash created_epoch revoked
{
    printf '%s rw org_eval %s 1716000000 0\n' "$RW_KEY_ID" "$RW_HASH"
    printf '%s ro org_eval %s 1716000001 0\n' "$RO_KEY_ID" "$RO_HASH"
    printf '%s rw org_eval %s 1716000002 1\n' "$REV_KEY_ID" "$REV_HASH"
} > "${TEST_DIR}/.heros-keys"

# Full API key strings
RW_KEY="heros_rw_${RW_KEY_ID}_${RW_SECRET}"
RO_KEY="heros_ro_${RO_KEY_ID}_${RO_SECRET}"
REV_KEY="heros_rw_${REV_KEY_ID}_${REV_SECRET}"

# Tampered key: correct format + known key_id but wrong secret → HMAC mismatch
BAD_KEY="heros_rw_${RW_KEY_ID}_0000000000000000000000000000dead"

# Key with unknown key_id (not in .heros-keys); key_id must be 32 hex chars
MISSING_KEY="heros_rw_9999999999999999999999999999ffff_${RW_SECRET}"

export HEROS_DATA_DIR="$TEST_DIR"
export HEROS_HMAC_SEED="$SEED"

# ── Helpers ───────────────────────────────────────────────────────────────────
INIT_MSG='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"ae-eval","version":"1.0"}}}'
NOTIF_MSG='{"jsonrpc":"2.0","method":"notifications/initialized"}'

# Build a tools/call JSON-RPC message
_call() {
    local name="$1" args_json="$2" id="${3:-2}"
    jq -cn --argjson id "$id" --arg name "$name" --argjson args "$args_json" \
        '{"jsonrpc":"2.0","id":$id,"method":"tools/call","params":{"name":$name,"arguments":$args}}'
}

# Run bridge with HEROS_API_KEY=$1 and stub binary in PATH; return bridge stdout
_batch() {
    local key="$1"; shift
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s\n' "$@" > "$tmpfile"
    # Prepend TEST_DIR to PATH so bridge finds the ledger stub
    env "PATH=${TEST_DIR}:${PATH}" "HEROS_API_KEY=${key}" \
        bash "$BRIDGE" < "$tmpfile" 2>/dev/null || true
    rm -f "$tmpfile"
}

# Extract content[0].text from bridge output for the given message id
_content() {
    local responses="$1" cid="$2"
    printf '%s\n' "$responses" \
        | jq -rs --argjson id "$cid" \
            'map(select(type=="object" and .id==$id)) | .[0] // {} | .result.content[0].text // "{}"' \
            2>/dev/null || echo "{}"
}

# Extract error_code; returns "NONE" if absent
_ec() {
    jq -r '.error_code // "NONE"' <<< "$1" 2>/dev/null || echo "NONE"
}

# "yes" if error_code is one of the V44 auth error codes, "no" otherwise
_is_auth_err() {
    case "$1" in
        INVALID_API_KEY|API_KEY_REVOKED|INSUFFICIENT_SCOPE) echo "yes" ;;
        *) echo "no" ;;
    esac
}

CREATE_ARGS='{"to":"vendor","amount":100,"currency":"USD","idempotency_key":"idem-ae"}'
LIST_ARGS='{}'

echo "ledger bridge auth eval (V44 — AE-01..AE-08)"
echo "bridge:   ${BRIDGE}"
echo "data_dir: ${TEST_DIR}"
echo "----------------------------------------"

# ── AE-01: valid rw key + invoice create → auth passes, audit entry written ──
{
    rm -f "${TEST_DIR}/.heros-audit"
    out=$(_batch "$RW_KEY" "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call ledger_invoice_create "$CREATE_ARGS")")
    c=$(_content "$out" 2)
    ec=$(_ec "$c")
    # Auth passed = error is not one of the three auth error codes
    _assert AE-01a "valid rw key → invoice create → auth passes" \
        "$(_is_auth_err "$ec")" "no"
    audit_hit="no"
    grep -q "$RW_KEY_ID" "${TEST_DIR}/.heros-audit" 2>/dev/null && audit_hit="yes" || true
    _assert AE-01b "valid rw key → audit entry written with key_id" \
        "$audit_hit" "yes"
}

# ── AE-02: malformed HEROS_API_KEY → INVALID_API_KEY ─────────────────────────
{
    out=$(_batch "not-a-valid-key" "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call ledger_invoice_list "$LIST_ARGS")")
    c=$(_content "$out" 2)
    _assert AE-02 "malformed HEROS_API_KEY → INVALID_API_KEY" \
        "$(_ec "$c")" "INVALID_API_KEY"
}

# ── AE-03: revoked key → API_KEY_REVOKED ─────────────────────────────────────
{
    out=$(_batch "$REV_KEY" "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call ledger_invoice_list "$LIST_ARGS")")
    c=$(_content "$out" 2)
    _assert AE-03 "revoked key → API_KEY_REVOKED" \
        "$(_ec "$c")" "API_KEY_REVOKED"
}

# ── AE-04: ro key + write op (invoice create) → INSUFFICIENT_SCOPE ────────────
{
    out=$(_batch "$RO_KEY" "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call ledger_invoice_create "$CREATE_ARGS")")
    c=$(_content "$out" 2)
    _assert AE-04 "ro key + rw op → INSUFFICIENT_SCOPE" \
        "$(_ec "$c")" "INSUFFICIENT_SCOPE"
}

# ── AE-05: ro key + read op (invoice list) → auth passes ─────────────────────
{
    out=$(_batch "$RO_KEY" "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call ledger_invoice_list "$LIST_ARGS")")
    c=$(_content "$out" 2)
    ec=$(_ec "$c")
    _assert AE-05 "ro key + ro op → auth passes" \
        "$(_is_auth_err "$ec")" "no"
}

# ── AE-06: tampered secret (HMAC mismatch) → INVALID_API_KEY ─────────────────
{
    out=$(_batch "$BAD_KEY" "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call ledger_invoice_list "$LIST_ARGS")")
    c=$(_content "$out" 2)
    _assert AE-06 "tampered key (HMAC mismatch) → INVALID_API_KEY" \
        "$(_ec "$c")" "INVALID_API_KEY"
}

# ── AE-07: valid format but key_id not in .heros-keys → INVALID_API_KEY ──────
{
    out=$(_batch "$MISSING_KEY" "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call ledger_invoice_list "$LIST_ARGS")")
    c=$(_content "$out" 2)
    _assert AE-07 "key_id not in .heros-keys → INVALID_API_KEY" \
        "$(_ec "$c")" "INVALID_API_KEY"
}

# ── AE-08: HEROS_API_KEY="" (migration mode) → auth skipped, binary invoked ──
{
    out=$(_batch "" "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call ledger_invoice_list "$LIST_ARGS")")
    c=$(_content "$out" 2)
    ec=$(_ec "$c")
    _assert AE-08 "HEROS_API_KEY='' → migration mode, auth skipped" \
        "$(_is_auth_err "$ec")" "no"
}

# ── Summary ───────────────────────────────────────────────────────────────────
echo "----------------------------------------"
printf 'Results: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
