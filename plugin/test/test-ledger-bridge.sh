#!/usr/bin/env bash
# plugin/test/test-ledger-bridge.sh — ledger bridge feature tests
#
# Phase 1: Wraps ledger/eval-auth.sh (BA-01..BA-11) + ledger/eval-bridge-auth.sh (AE-01..AE-08).
#          Both use their own stub binary; require: bash 4+, jq, openssl, xxd, python3.
# Phase 2: Plugin-layer tests (LP-01..LP-13) using a functional ledger stub.
#
# Usage: bash plugin/test/test-ledger-bridge.sh
# Requires: bash 4+, jq 1.6+
set -euo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LEDGER_BRIDGE="${REPO_ROOT}/ledger/mcp-bridge.sh"

PASS=0
FAIL=0
SKIP=0

for _req in jq bash; do
    command -v "$_req" >/dev/null 2>&1 || {
        printf 'test-ledger-bridge: %s not found in PATH (required)\n' "$_req" >&2
        exit 1
    }
done
[[ -f "$LEDGER_BRIDGE" ]] || {
    printf 'test-ledger-bridge: bridge not found: %s\n' "$LEDGER_BRIDGE" >&2
    exit 1
}

# shellcheck source=plugin/test/test-stub-binary.sh
source "${SCRIPT_DIR}/test-stub-binary.sh"

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
make_ledger_stub "$STUB_DIR"

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

# Run bridge with stub binary in PATH; optional env overrides via first args
_batch() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s\n' "$@" > "$tmpfile"
    env "PATH=${STUB_DIR}:${PATH}" \
        "HEROS_DATA_DIR=${LP_DATA_DIR:-}" \
        bash "$LEDGER_BRIDGE" < "$tmpfile" 2>/dev/null || true
    rm -f "$tmpfile"
}

# Run bridge with rate-limit env set
_batch_rl() {
    local rl_var="$1" rl_val="$2"; shift 2
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s\n' "$@" > "$tmpfile"
    env "PATH=${STUB_DIR}:${PATH}" \
        "HEROS_DATA_DIR=${LP_DATA_DIR:-}" \
        "${rl_var}=${rl_val}" \
        bash "$LEDGER_BRIDGE" < "$tmpfile" 2>/dev/null || true
    rm -f "$tmpfile"
}

_content() {
    local responses="$1" cid="$2"
    printf '%s\n' "$responses" \
        | jq -rs --argjson id "$cid" \
            'map(select(type=="object" and .id==$id)) | .[0] // {} | .result.content[0].text // "{}"' \
            2>/dev/null || echo "{}"
}

_call_msg() {
    local name="$1" args_json="$2" id="${3:-2}"
    jq -cn --argjson id "$id" --arg name "$name" --argjson args "$args_json" \
        '{"jsonrpc":"2.0","id":$id,"method":"tools/call","params":{"name":$name,"arguments":$args}}'
}

INIT_MSG='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"lp-eval","version":"1.0"}}}'
NOTIF_MSG='{"jsonrpc":"2.0","method":"notifications/initialized"}'

echo "ledger bridge plugin eval (auth wrap + LP-01..LP-13)"
echo "bridge: ${LEDGER_BRIDGE}"
echo "----------------------------------------------------------------------"

# ── Phase 1a: ledger/eval-auth.sh (BA-01..BA-11) ─────────────────────────────
echo "[Phase 1a] Running ledger/eval-auth.sh (BA-01..BA-11)"
AUTH_DEPS_OK=true
for _dep in openssl xxd python3; do
    command -v "$_dep" >/dev/null 2>&1 || { AUTH_DEPS_OK=false; break; }
done

if [[ "$AUTH_DEPS_OK" == "true" ]] && [[ -f "${REPO_ROOT}/ledger/eval-auth.sh" ]]; then
    BA_OUTPUT=""
    BA_RC=0
    BA_OUTPUT=$(bash "${REPO_ROOT}/ledger/eval-auth.sh" 2>/dev/null) || BA_RC=$?
    ba_pass=$(printf '%s\n' "$BA_OUTPUT" | grep -c '^PASS' 2>/dev/null || true)
    ba_fail=$(printf '%s\n' "$BA_OUTPUT" | grep -c '^FAIL' 2>/dev/null || true)
    ba_skip=$(printf '%s\n' "$BA_OUTPUT" | grep -c '^SKIP' 2>/dev/null || true)
    PASS=$(( PASS + ba_pass ))
    FAIL=$(( FAIL + ba_fail ))
    SKIP=$(( SKIP + ba_skip ))
    printf '%s\n' "$BA_OUTPUT"
    if (( BA_RC != 0 && ba_fail == 0 )); then
        printf 'FAIL  BA-??   eval-auth.sh exited non-zero (rc=%d)\n' "$BA_RC"
        FAIL=$(( FAIL + 1 ))
    fi
else
    reason="openssl/xxd/python3 not found in PATH"
    [[ ! -f "${REPO_ROOT}/ledger/eval-auth.sh" ]] && reason="eval-auth.sh not found"
    for _n in 01 02 03 04 05 06 07 08 09 10 11; do
        _skip "BA-${_n}" "key-gen + auth validation" "$reason"
    done
fi

echo "----------------------------------------------------------------------"

# ── Phase 1b: ledger/eval-bridge-auth.sh (AE-01..AE-08) ──────────────────────
echo "[Phase 1b] Running ledger/eval-bridge-auth.sh (AE-01..AE-08)"
if [[ "$AUTH_DEPS_OK" == "true" ]] && [[ -f "${REPO_ROOT}/ledger/eval-bridge-auth.sh" ]]; then
    AE_OUTPUT=""
    AE_RC=0
    AE_OUTPUT=$(bash "${REPO_ROOT}/ledger/eval-bridge-auth.sh" 2>/dev/null) || AE_RC=$?
    ae_pass=$(printf '%s\n' "$AE_OUTPUT" | grep -c '^PASS' 2>/dev/null || true)
    ae_fail=$(printf '%s\n' "$AE_OUTPUT" | grep -c '^FAIL' 2>/dev/null || true)
    ae_skip=$(printf '%s\n' "$AE_OUTPUT" | grep -c '^SKIP' 2>/dev/null || true)
    PASS=$(( PASS + ae_pass ))
    FAIL=$(( FAIL + ae_fail ))
    SKIP=$(( SKIP + ae_skip ))
    printf '%s\n' "$AE_OUTPUT"
    if (( AE_RC != 0 && ae_fail == 0 )); then
        printf 'FAIL  AE-??   eval-bridge-auth.sh exited non-zero (rc=%d)\n' "$AE_RC"
        FAIL=$(( FAIL + 1 ))
    fi
else
    reason="openssl/xxd/python3 not found in PATH"
    [[ ! -f "${REPO_ROOT}/ledger/eval-bridge-auth.sh" ]] && reason="eval-bridge-auth.sh not found"
    for _n in 01 02 03 04 05 06 07 08 09; do
        _skip "AE-${_n}" "bridge auth integration" "$reason"
    done
fi

echo "----------------------------------------------------------------------"
echo "[Phase 2] Plugin-layer tests (LP-01..LP-13) with functional stub"

# Fresh data dir for LP tests (isolated from auth tests above)
LP_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$LP_DATA_DIR"' EXIT

REG_ARGS='{"org_name":"Test Org LP"}'
CREATE_ARGS='{"to":"Vendor Inc","amount":100,"currency":"USD","idempotency_key":"lp-key-001"}'

# ── LP-01: register → org_id starts with "org_" ──────────────────────────────
{
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_call_msg ledger_register "$REG_ARGS")")
    c=$(_content "$out" 2)
    oid=$(jq -r '.org_id // ""' <<< "$c" 2>/dev/null || echo "")
    v="no"
    [[ "$oid" == org_* ]] && v="yes"
    _assert LP-01 "register → org_id starts with org_" "$v" "yes"
}

# ── LP-02: invoice_create → status:draft, _idempotent:false ──────────────────
{
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_call_msg ledger_invoice_create "$CREATE_ARGS")")
    c=$(_content "$out" 2)
    st=$(jq -r '.status // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
    idem=$(jq -r '._idempotent | tostring' <<< "$c" 2>/dev/null || echo "null")
    ok="no"
    [[ "$st" == "draft" && "$idem" == "false" ]] && ok="yes"
    _assert LP-02 "invoice_create → status:draft, _idempotent:false" "$ok" "yes"
}

# ── LP-03: duplicate idempotency key → _idempotent:true ──────────────────────
{
    # Second call with same idempotency key (register + create already done in LP-01/02)
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_call_msg ledger_invoice_create "$CREATE_ARGS")")
    c=$(_content "$out" 2)
    idem=$(jq -r '._idempotent | tostring' <<< "$c" 2>/dev/null || echo "false")
    _assert LP-03 "duplicate idempotency key → _idempotent:true" "$idem" "true"
}

# ── LP-04: 3 invoices → invoice_list count == 3 ──────────────────────────────
{
    # Create 2 more invoices (1 already exists from LP-02)
    create2=$(jq -cn '{"to":"Vendor2","amount":200,"currency":"USD","idempotency_key":"lp-key-002"}')
    create3=$(jq -cn '{"to":"Vendor3","amount":300,"currency":"USD","idempotency_key":"lp-key-003"}')
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call_msg ledger_invoice_create "$create2" 2)" \
        "$(_call_msg ledger_invoice_create "$create3" 3)")
    # Now list
    out2=$(_batch "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call_msg ledger_invoice_list '{}' 2)")
    c2=$(_content "$out2" 2)
    cnt=$(jq -r '.total_count // .count // 0' <<< "$c2" 2>/dev/null || echo "0")
    _assert LP-04 "3 invoices created → invoice_list total_count == 3" "$cnt" "3"
}

# ── LP-05: invoice_count matches invoice_list count ───────────────────────────
{
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call_msg ledger_invoice_count '{}' 2)")
    c=$(_content "$out" 2)
    cnt=$(jq -r '.count // 0' <<< "$c" 2>/dev/null || echo "0")
    _assert LP-05 "invoice_count == 3 (matches invoice_list)" "$cnt" "3"
}

# ── LP-06: invoice_create before register → NO_ORG_REGISTERED ─────────────────
{
    FRESH_DIR=$(mktemp -d)
    tmpfile=$(mktemp)
    printf '%s\n' \
        "$INIT_MSG" \
        "$NOTIF_MSG" \
        "$(_call_msg ledger_invoice_create "$CREATE_ARGS")" \
        > "$tmpfile"
    out=$(env "PATH=${STUB_DIR}:${PATH}" "HEROS_DATA_DIR=${FRESH_DIR}" \
        bash "$LEDGER_BRIDGE" < "$tmpfile" 2>/dev/null || true)
    rm -f "$tmpfile" && rm -rf "$FRESH_DIR"
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
    _assert LP-06 "invoice_create before register → NO_ORG_REGISTERED" "$ec" "NO_ORG_REGISTERED"
}

# ── LP-07: invoice_list before register → NO_ORG_REGISTERED ──────────────────
{
    FRESH_DIR=$(mktemp -d)
    tmpfile=$(mktemp)
    printf '%s\n' \
        "$INIT_MSG" \
        "$NOTIF_MSG" \
        "$(_call_msg ledger_invoice_list '{}' 2)" \
        > "$tmpfile"
    out=$(env "PATH=${STUB_DIR}:${PATH}" "HEROS_DATA_DIR=${FRESH_DIR}" \
        bash "$LEDGER_BRIDGE" < "$tmpfile" 2>/dev/null || true)
    rm -f "$tmpfile" && rm -rf "$FRESH_DIR"
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
    _assert LP-07 "invoice_list before register → NO_ORG_REGISTERED" "$ec" "NO_ORG_REGISTERED"
}

# ── LP-08: invoice_create missing `to` → MISSING_FLAG ────────────────────────
{
    no_to_args=$(jq -cn '{"amount":100,"currency":"USD","idempotency_key":"lp-key-008"}')
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_call_msg ledger_invoice_create "$no_to_args")")
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
    _assert LP-08 "invoice_create missing to → MISSING_FLAG" "$ec" "MISSING_FLAG"
}

# ── LP-09: invoice_create non-number amount → MISSING_FLAG (bridge guard) ────
{
    bad_amount_args=$(jq -cn '{"to":"Vendor","amount":"not-a-number","currency":"USD","idempotency_key":"lp-key-009"}')
    out=$(_batch "$INIT_MSG" "$NOTIF_MSG" "$(_call_msg ledger_invoice_create "$bad_amount_args")")
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
    _assert LP-09 "non-number amount → MISSING_FLAG (bridge type guard)" "$ec" "MISSING_FLAG"
}

# ── LP-10: lowercase currency → INVALID_INPUT ────────────────────────────────
{
    FRESH_DIR=$(mktemp -d)
    # Register first so we don't get NO_ORG_REGISTERED
    tmpfile=$(mktemp)
    printf '%s\n' \
        "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call_msg ledger_register "$REG_ARGS" 2)" \
        > "$tmpfile"
    env "PATH=${STUB_DIR}:${PATH}" "HEROS_DATA_DIR=${FRESH_DIR}" \
        bash "$LEDGER_BRIDGE" < "$tmpfile" >/dev/null 2>/dev/null || true
    rm -f "$tmpfile"

    lower_args=$(jq -cn '{"to":"Vendor","amount":100,"currency":"usd","idempotency_key":"lp-key-010"}')
    tmpfile=$(mktemp)
    printf '%s\n' \
        "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call_msg ledger_invoice_create "$lower_args")" \
        > "$tmpfile"
    out=$(env "PATH=${STUB_DIR}:${PATH}" "HEROS_DATA_DIR=${FRESH_DIR}" \
        bash "$LEDGER_BRIDGE" < "$tmpfile" 2>/dev/null || true)
    rm -f "$tmpfile" && rm -rf "$FRESH_DIR"
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
    _assert LP-10 "lowercase currency → INVALID_INPUT from stub" "$ec" "INVALID_INPUT"
}

# ── LP-11: rate limit exhaustion → RATE_LIMITED ───────────────────────────────
{
    FRESH_DIR=$(mktemp -d)
    # Register
    tmpfile=$(mktemp)
    printf '%s\n' "$INIT_MSG" "$NOTIF_MSG" "$(_call_msg ledger_register "$REG_ARGS" 2)" > "$tmpfile"
    env "PATH=${STUB_DIR}:${PATH}" "HEROS_DATA_DIR=${FRESH_DIR}" \
        bash "$LEDGER_BRIDGE" < "$tmpfile" >/dev/null 2>/dev/null || true
    rm -f "$tmpfile"

    # LEDGER_RATE_INVOICE_CREATE_ORG=0 enables deny-all mode (rejects every call immediately).
    c1=$(jq -cn '{"to":"V1","amount":1,"currency":"USD","idempotency_key":"rl-key-001"}')
    tmpfile=$(mktemp)
    printf '%s\n' \
        "$INIT_MSG" "$NOTIF_MSG" \
        "$(_call_msg ledger_invoice_create "$c1" 2)" \
        > "$tmpfile"
    out=$(env "PATH=${STUB_DIR}:${PATH}" "HEROS_DATA_DIR=${FRESH_DIR}" \
        "LEDGER_RATE_INVOICE_CREATE_ORG=0" \
        bash "$LEDGER_BRIDGE" < "$tmpfile" 2>/dev/null || true)
    rm -f "$tmpfile" && rm -rf "$FRESH_DIR"
    c=$(_content "$out" 2)
    ec=$(jq -r '.error_code // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
    _assert LP-11 "invoice_create operator-disabled (LEDGER_RATE_INVOICE_CREATE_ORG=0) → TOOL_DISABLED" "$ec" "TOOL_DISABLED"
}

# ── LP-12: _rate_limit field present on successful register ───────────────────
{
    FRESH_DIR=$(mktemp -d)
    tmpfile=$(mktemp)
    printf '%s\n' "$INIT_MSG" "$NOTIF_MSG" "$(_call_msg ledger_register "$REG_ARGS")" > "$tmpfile"
    out=$(env "PATH=${STUB_DIR}:${PATH}" "HEROS_DATA_DIR=${FRESH_DIR}" \
        bash "$LEDGER_BRIDGE" < "$tmpfile" 2>/dev/null || true)
    rm -f "$tmpfile" && rm -rf "$FRESH_DIR"
    c=$(_content "$out" 2)
    v=$(jq -r 'if has("_rate_limit") then "yes" else "no" end' <<< "$c" 2>/dev/null || echo "no")
    _assert LP-12 "register success → _rate_limit field present" "$v" "yes"
}

# ── LP-13: cross-org isolation ────────────────────────────────────────────────
# Two separate bridge sessions with different org registrations cannot see each other's invoices.
{
    if command -v python3 >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 \
        && command -v xxd >/dev/null 2>&1; then
        XORG_DIR=$(mktemp -d)
        AUTH_SEED="cross-org-isolation-test-seed-32c"
        KEY_ID_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaa0001"
        SECRET_A="bbbbbbbbbbbbbbbbbbbbbbbbbbbb0001"
        KEY_ID_B="aaaaaaaaaaaaaaaaaaaaaaaaaaaa0002"
        SECRET_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbb0002"
        HMAC_A=$(printf '%s' "${KEY_ID_A}:${SECRET_A}" \
            | openssl dgst -sha256 -hmac "$AUTH_SEED" -binary \
            | python3 -c "import sys; print(sys.stdin.buffer.read().hex())" 2>/dev/null) || HMAC_A=""
        HMAC_B=$(printf '%s' "${KEY_ID_B}:${SECRET_B}" \
            | openssl dgst -sha256 -hmac "$AUTH_SEED" -binary \
            | python3 -c "import sys; print(sys.stdin.buffer.read().hex())" 2>/dev/null) || HMAC_B=""

        if [[ -n "$HMAC_A" && -n "$HMAC_B" ]]; then
            # Register two orgs via separate bridge sessions
            printf '%s rw org_aaaa0001 %s 1716000001 0\n' "$KEY_ID_A" "$HMAC_A" \
                > "${XORG_DIR}/.heros-keys"
            printf '%s rw org_bbbb0002 %s 1716000002 0\n' "$KEY_ID_B" "$HMAC_B" \
                >> "${XORG_DIR}/.heros-keys"
            API_KEY_A="heros_rw_${KEY_ID_A}_${SECRET_A}"
            API_KEY_B="heros_rw_${KEY_ID_B}_${SECRET_B}"

            # Register org A and create an invoice
            REG_A='{"org_name":"Org A"}'
            INV_A='{"to":"A-Vendor","amount":100,"currency":"USD","idempotency_key":"xorg-inv-a-001"}'
            tmpfile=$(mktemp)
            printf '%s\n' "$INIT_MSG" "$NOTIF_MSG" \
                "$(_call_msg ledger_register "$REG_A" 2)" \
                "$(_call_msg ledger_invoice_create "$INV_A" 3)" \
                > "$tmpfile"
            env "PATH=${STUB_DIR}:${PATH}" "HEROS_DATA_DIR=${XORG_DIR}" \
                "HEROS_API_KEY=${API_KEY_A}" "HEROS_HMAC_SEED=${AUTH_SEED}" \
                bash "$LEDGER_BRIDGE" < "$tmpfile" >/dev/null 2>/dev/null || true
            rm -f "$tmpfile"

            # Org B lists invoices — should see 0 (not Org A's invoice)
            tmpfile=$(mktemp)
            printf '%s\n' "$INIT_MSG" "$NOTIF_MSG" \
                "$(_call_msg ledger_invoice_count '{}' 2)" \
                > "$tmpfile"
            out=$(env "PATH=${STUB_DIR}:${PATH}" "HEROS_DATA_DIR=${XORG_DIR}" \
                "HEROS_API_KEY=${API_KEY_B}" "HEROS_HMAC_SEED=${AUTH_SEED}" \
                bash "$LEDGER_BRIDGE" < "$tmpfile" 2>/dev/null || true)
            rm -f "$tmpfile"
            rm -rf "$XORG_DIR"
            c=$(_content "$out" 2)
            # Org B has not registered yet — should get NO_ORG_REGISTERED or count=0
            ec=$(jq -r '.error_code // "NONE"' <<< "$c" 2>/dev/null || echo "NONE")
            cnt=$(jq -r '.count // -1' <<< "$c" 2>/dev/null || echo "-1")
            ok="no"
            # Either NO_ORG_REGISTERED or count=0 means cross-org isolation works
            [[ "$ec" == "NO_ORG_REGISTERED" || "$cnt" == "0" ]] && ok="yes"
            _assert LP-13 "cross-org isolation: org B cannot see org A invoices" "$ok" "yes"
        else
            _skip LP-13 "cross-org isolation" "HMAC computation failed"
        fi
    else
        _skip LP-13 "cross-org isolation" "python3/openssl/xxd not available"
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
echo "----------------------------------------------------------------------"
printf 'ledger-bridge: PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"

if (( FAIL > 0 )); then
    exit 1
fi
