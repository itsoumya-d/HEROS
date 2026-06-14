#!/usr/bin/env bash
# ledger/eval-bridge.sh - MCP bridge behavior regression suite
#
# Tests the primary end-user ledger MCP workflow:
# register -> invoice create -> duplicate idempotency -> list/count pagination.
#
# Usage: bash ledger/eval-bridge.sh
# Requires: bash 4+, jq 1.6+, flock, timeout, ledger binary in PATH or ledger/
set -euo pipefail
LANG=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/mcp-bridge.sh"
PASS=0
FAIL=0
SKIP=0

_assert() {
    local id="$1" desc="$2" got="$3" want="$4"
    if [[ "$got" == "$want" ]]; then
        printf 'PASS  %-7s %s\n' "$id" "$desc"
        PASS=$(( PASS + 1 ))
    else
        printf 'FAIL  %-7s %s\n' "$id" "$desc"
        printf '       want: %s\n' "$want"
        printf '       got:  %s\n' "$got"
        FAIL=$(( FAIL + 1 ))
    fi
}

_skip() {
    local id="$1" desc="$2" reason="$3"
    printf 'SKIP  %-7s %s (%s)\n' "$id" "$desc" "$reason"
    SKIP=$(( SKIP + 1 ))
}

for _req in jq bash; do
    command -v "$_req" >/dev/null 2>&1 || {
        printf 'eval-bridge: %s not found in PATH (required)\n' "$_req" >&2
        exit 1
    }
done
[[ -f "$BRIDGE" ]] || {
    printf 'eval-bridge: bridge not found: %s\n' "$BRIDGE" >&2
    exit 1
}

echo "ledger bridge workflow suite (register/create/list/count)"
echo "bridge: ${BRIDGE}"
echo "----------------------------------------"

if (( BASH_VERSINFO[0] < 4 )); then
    _skip LBE-ALL "ledger bridge workflow eval" "requires bash 4+ for bridge associative arrays (got bash ${BASH_VERSION})"
    echo "----------------------------------------"
    printf 'ledger-bridge-suite: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
    exit 0
fi

for _req in flock timeout; do
    command -v "$_req" >/dev/null 2>&1 || {
        printf 'eval-bridge: %s not found in PATH (required by mcp-bridge.sh)\n' "$_req" >&2
        exit 1
    }
done

LEDGER_TARGET="${LEDGER_EVAL_BIN:-}"
if [[ -n "$LEDGER_TARGET" && -x "$LEDGER_TARGET" ]]; then
    :
elif [[ -x "${SCRIPT_DIR}/ledger" ]]; then
    LEDGER_TARGET="${SCRIPT_DIR}/ledger"
elif command -v ledger >/dev/null 2>&1; then
    LEDGER_TARGET="$(command -v ledger)"
else
    printf 'eval-bridge: ledger binary not found in PATH, %s/ledger, or LEDGER_EVAL_BIN\n' "$SCRIPT_DIR" >&2
    exit 1
fi

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
DATA_DIR="${TEST_DIR}/data"
BIN_DIR="${TEST_DIR}/bin"
mkdir -p "$DATA_DIR" "$BIN_DIR"
cp "$LEDGER_TARGET" "${BIN_DIR}/ledger"
chmod +x "${BIN_DIR}/ledger"

INIT_MSG='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"ledger-be-eval","version":"1.0"}}}'
NOTIF_MSG='{"jsonrpc":"2.0","method":"notifications/initialized"}'

_call() {
    local id="$1" name="$2" args_json="$3"
    jq -cn --argjson id "$id" --arg name "$name" --argjson args "$args_json" \
        '{"jsonrpc":"2.0","id":$id,"method":"tools/call","params":{"name":$name,"arguments":$args}}'
}

_batch() {
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s\n' "$@" > "$tmpfile"
    env "PATH=${BIN_DIR}:${PATH}" \
        "HEROS_DATA_DIR=${DATA_DIR}" \
        "HEROS_API_KEY=" \
        "HEROS_HMAC_SEED=" \
        bash "$BRIDGE" < "$tmpfile" 2>/dev/null || true
    rm -f "$tmpfile"
}

_response() {
    local responses="$1" cid="$2"
    printf '%s\n' "$responses" \
        | jq -rs --argjson id "$cid" \
            'map(select(type=="object" and .id==$id)) | .[0] // {}' \
        2>/dev/null || echo "{}"
}

_content() {
    local responses="$1" cid="$2"
    printf '%s\n' "$responses" \
        | jq -rs --argjson id "$cid" \
            'map(select(type=="object" and .id==$id)) | .[0] // {} | .result.content[0].text // "{}"' \
        2>/dev/null || echo "{}"
}

_is_error() {
    local responses="$1" cid="$2"
    _response "$responses" "$cid" | jq -r '.result.isError // false' 2>/dev/null || echo "false"
}

_field() {
    local json="$1" filter="$2"
    jq -r "$filter" <<< "$json" 2>/dev/null || echo "__jq_error__"
}

REG_ARGS=$(jq -cn --arg org "Acme Corp" '{"org_name":$org}')
CREATE1_ARGS=$(jq -cn \
    --arg to "Vendor Inc" \
    --arg cur "USD" \
    --arg idem "idem-lbe-001" \
    --arg memo "June services" \
    '{"to":$to,"amount":100.25,"currency":$cur,"idempotency_key":$idem,"memo":$memo}')
CREATE1_DUP_ARGS=$(jq -cn \
    --arg to "Changed Vendor" \
    --arg cur "USD" \
    --arg idem "idem-lbe-001" \
    '{"to":$to,"amount":999.99,"currency":$cur,"idempotency_key":$idem}')
CREATE2_ARGS=$(jq -cn \
    --arg to "Second Vendor" \
    --arg cur "EUR" \
    --arg idem "idem-lbe-002" \
    '{"to":$to,"amount":42,"currency":$cur,"idempotency_key":$idem}')
LIST_BEFORE_ARGS='{}'
LIST_PAGE1_ARGS='{"limit":1,"offset":0}'
LIST_PAGE2_ARGS='{"limit":1,"offset":1}'
COUNT_ARGS='{}'
BAD_AMOUNT_ARGS='{"to":"Bad Vendor","amount":"100.00","currency":"USD","idempotency_key":"idem-bad-amount"}'
BAD_LIMIT_ARGS='{"limit":0}'

OUT=$(_batch \
    "$INIT_MSG" \
    "$NOTIF_MSG" \
    "$(_call 2 ledger_invoice_list "$LIST_BEFORE_ARGS")" \
    "$(_call 3 ledger_register "$REG_ARGS")" \
    "$(_call 4 ledger_register "$REG_ARGS")" \
    "$(_call 5 ledger_invoice_create "$CREATE1_ARGS")" \
    "$(_call 6 ledger_invoice_create "$CREATE1_DUP_ARGS")" \
    "$(_call 7 ledger_invoice_create "$CREATE2_ARGS")" \
    "$(_call 8 ledger_invoice_list "$LIST_PAGE1_ARGS")" \
    "$(_call 9 ledger_invoice_list "$LIST_PAGE2_ARGS")" \
    "$(_call 10 ledger_invoice_count "$COUNT_ARGS")" \
    "$(_call 11 ledger_invoice_create "$BAD_AMOUNT_ARGS")" \
    "$(_call 12 ledger_invoice_list "$BAD_LIMIT_ARGS")")

INIT_PROTO=$(_response "$OUT" 1 | jq -r '.result.protocolVersion // "MISSING"' 2>/dev/null || echo "MISSING")
_assert LBE-01 "initialize returns MCP protocol version" "$INIT_PROTO" "2025-11-25"

LIST_BEFORE=$(_content "$OUT" 2)
_assert LBE-02a "list before register returns NO_ORG_REGISTERED" \
    "$(_field "$LIST_BEFORE" '.error_code // "MISSING"')" "NO_ORG_REGISTERED"
_assert LBE-02b "list before register is marked isError" \
    "$(_is_error "$OUT" 2)" "true"

REGISTER=$(_content "$OUT" 3)
ORG_ID=$(_field "$REGISTER" '.org_id // ""')
_assert LBE-03a "register returns status ok" \
    "$(_field "$REGISTER" '.status // "MISSING"')" "ok"
_assert LBE-03b "register returns org_ identifier" \
    "$(_field "$REGISTER" 'if (.org_id // "" | test("^org_[0-9a-f]{8}$")) then "yes" else "no" end')" "yes"
_assert LBE-03c "register strips bridge-internal _new_data" \
    "$(_field "$REGISTER" 'has("_new_data")')" "false"
_assert LBE-03d "register success includes _rate_limit" \
    "$(_field "$REGISTER" 'has("_rate_limit")')" "true"

REGISTER_AGAIN=$(_content "$OUT" 4)
_assert LBE-04a "second register returns ORG_EXISTS" \
    "$(_field "$REGISTER_AGAIN" '.error_code // "MISSING"')" "ORG_EXISTS"
_assert LBE-04b "second register returns same org_id" \
    "$(_field "$REGISTER_AGAIN" '.org_id // ""')" "$ORG_ID"

CREATE1=$(_content "$OUT" 5)
INV1_ID=$(_field "$CREATE1" '.invoice_id // ""')
_assert LBE-05a "invoice create returns draft status" \
    "$(_field "$CREATE1" '.status // "MISSING"')" "draft"
_assert LBE-05b "invoice create stores numeric amount as ledger string" \
    "$(_field "$CREATE1" '.amount // "MISSING"')" "100.25"
_assert LBE-05c "invoice create returns _idempotent false" \
    "$(_field "$CREATE1" '._idempotent')" "false"
_assert LBE-05d "invoice create strips bridge-internal _new_invoice_json" \
    "$(_field "$CREATE1" 'has("_new_invoice_json")')" "false"

CREATE1_DUP=$(_content "$OUT" 6)
_assert LBE-06a "duplicate idempotency returns _idempotent true" \
    "$(_field "$CREATE1_DUP" '._idempotent')" "true"
_assert LBE-06b "duplicate idempotency returns original invoice_id" \
    "$(_field "$CREATE1_DUP" '.invoice_id // ""')" "$INV1_ID"
_assert LBE-06c "duplicate idempotency returns original stored recipient" \
    "$(_field "$CREATE1_DUP" '.to // "MISSING"')" "Vendor Inc"

CREATE2=$(_content "$OUT" 7)
INV2_ID=$(_field "$CREATE2" '.invoice_id // ""')
_assert LBE-07 "second invoice create returns a distinct invoice_id" \
    "$(_field "$CREATE2" 'if .invoice_id != "'"$INV1_ID"'" then "yes" else "no" end')" "yes"

LIST_PAGE1=$(_content "$OUT" 8)
_assert LBE-08a "list page 1 returns one invoice" \
    "$(_field "$LIST_PAGE1" '.count')" "1"
_assert LBE-08b "list page 1 reports total_count 2" \
    "$(_field "$LIST_PAGE1" '.total_count')" "2"
_assert LBE-08c "list page 1 has_more true" \
    "$(_field "$LIST_PAGE1" '.has_more')" "true"
_assert LBE-08d "list page 1 returns first invoice" \
    "$(_field "$LIST_PAGE1" '.invoices[0].invoice_id // ""')" "$INV1_ID"

LIST_PAGE2=$(_content "$OUT" 9)
_assert LBE-09a "list page 2 returns one invoice" \
    "$(_field "$LIST_PAGE2" '.count')" "1"
_assert LBE-09b "list page 2 has_more false" \
    "$(_field "$LIST_PAGE2" '.has_more')" "false"
_assert LBE-09c "list page 2 returns second invoice" \
    "$(_field "$LIST_PAGE2" '.invoices[0].invoice_id // ""')" "$INV2_ID"

COUNT=$(_content "$OUT" 10)
_assert LBE-10 "invoice count returns 2" \
    "$(_field "$COUNT" '.count')" "2"

BAD_AMOUNT=$(_content "$OUT" 11)
_assert LBE-11a "string amount rejected by bridge type guard" \
    "$(_field "$BAD_AMOUNT" '.error_code // "MISSING"')" "MISSING_FLAG"
_assert LBE-11b "string amount rejection marks isError" \
    "$(_is_error "$OUT" 11)" "true"

BAD_LIMIT=$(_content "$OUT" 12)
_assert LBE-12 "invalid list limit rejected" \
    "$(_field "$BAD_LIMIT" '.error_code // "MISSING"')" "INVALID_PARAM"

echo "----------------------------------------"
printf 'ledger-bridge-suite: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
