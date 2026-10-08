#!/usr/bin/env bash
# plugin/test/test-stub-binary.sh — shared stub binary factory for bridge-layer tests
#
# Source this file; do not execute directly.
# Provides:
#   make_forge_stub <dir>    — creates <dir>/forge (SAFE for identical schemas, CRITICAL otherwise)
#   make_ledger_stub <dir>   — creates <dir>/ledger (functional: register + invoice create)
#   make_ledger_auth_stub <dir> — creates <dir>/ledger (simple ORG_NOT_FOUND stub for auth tests)
#
# All stubs: no eval, no user-input interpolation into printf format strings.

make_forge_stub() {
    local dir="$1"
    cat > "${dir}/forge" << 'FORGE_STUB'
#!/usr/bin/env bash
# Minimal forge stub: CRITICAL when schemas differ, SAFE when identical.
set -euo pipefail
export LC_ALL=C.UTF-8

cmd="${1:-}"
from_arg="" to_arg="" req_id=""

shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)       from_arg="${2:-}"; shift 2 ;;
        --to)         to_arg="${2:-}";   shift 2 ;;
        --request-id) req_id="${2:-}";   shift 2 ;;
        *)            shift ;;
    esac
done

case "$cmd" in
    analyze)
        from_first="${from_arg%%|*}"
        to_first="${to_arg%%|*}"
        if [[ "$from_first" != "$to_first" ]]; then
            if [[ -n "$req_id" ]]; then
                jq -cn --arg rid "$req_id" \
                    '{"risk_tier":"CRITICAL","has_data_loss":true,"decision_required":true,"retryable":false,"schema_version":1,"request_id":$rid}'
            else
                printf '{"risk_tier":"CRITICAL","has_data_loss":true,"decision_required":true,"retryable":false,"schema_version":1}\n'
            fi
        else
            if [[ -n "$req_id" ]]; then
                jq -cn --arg rid "$req_id" \
                    '{"risk_tier":"SAFE","has_data_loss":false,"decision_required":false,"retryable":true,"schema_version":1,"request_id":$rid}'
            else
                printf '{"risk_tier":"SAFE","has_data_loss":false,"decision_required":false,"retryable":true,"schema_version":1}\n'
            fi
        fi
        ;;
    --version)
        printf '{"tool":"forge","version":"0.1.4-stub","schema_version":1}\n'
        ;;
    --describe)
        printf '{"tool":"forge","schema_version":1}\n'
        ;;
    *)
        printf '{"error_code":"UNKNOWN_COMMAND","retryable":false}\n'
        ;;
esac
FORGE_STUB
    chmod +x "${dir}/forge"
}

make_ledger_stub() {
    local dir="$1"
    cat > "${dir}/ledger" << 'LEDGER_STUB'
#!/usr/bin/env bash
# Functional ledger stub: handles register and invoice create.
set -euo pipefail
export LC_ALL=C.UTF-8

cmd="${1:-}"
sub="${2:-}"

ent=""
org_name=""
to=""
amount=""
currency=""
idem=""

shift || true
[[ "$cmd" == "invoice" ]] && { shift || true; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --entropy)        ent="${2:-}";       shift 2 ;;
        --org-name)       org_name="${2:-}";  shift 2 ;;
        --to)             to="${2:-}";         shift 2 ;;
        --amount)         amount="${2:-}";     shift 2 ;;
        --currency)       currency="${2:-}";   shift 2 ;;
        --idempotency-key) idem="${2:-}";      shift 2 ;;
        --timestamp)      shift 2 ;;
        --memo)           shift 2 ;;
        *)                shift ;;
    esac
done

case "$cmd" in
    register)
        ent="${ent:-deadbeef}"
        # Build _new_data as a JSON string so the bridge can write it to .ledger-data
        new_data=$(jq -cn --arg oid "org_${ent}" --arg name "${org_name}" \
            '{"org_id":$oid,"org_name":$name,"status":"ok"}')
        jq -cn --arg oid "org_${ent}" --arg name "${org_name}" --arg nd "$new_data" \
            '{"status":"ok","org_id":$oid,"org_name":$name,"_new_data":$nd}'
        ;;
    invoice)
        if [[ "$sub" == "create" ]]; then
            ent="${ent:-deadbeef}"
            # Validate currency: must be 3 uppercase ASCII letters
            if ! printf '%s' "$currency" | grep -qE '^[A-Z]{3}$'; then
                printf '{"error_code":"INVALID_INPUT","field":"--currency","retryable":false}\n'
                exit 0
            fi
            # Validate amount: must be a valid number
            if ! printf '%s' "$amount" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then
                printf '{"error_code":"INVALID_INPUT","field":"--amount","retryable":false}\n'
                exit 0
            fi
            # Build _new_invoice_json as a JSON string for the bridge to append to .ledger-invoices
            new_inv=$(jq -cn --arg iid "inv_${ent}" --arg to "$to" \
                --arg idem "$idem" --arg curr "$currency" --argjson amt "$amount" \
                '{"status":"draft","invoice_id":$iid,"to":$to,"amount":$amt,"currency":$curr,"idempotency_key":$idem,"_idempotent":false}')
            jq -cn --arg iid "inv_${ent}" --arg to "$to" \
                --arg idem "$idem" --arg curr "$currency" --argjson amt "$amount" \
                --arg nij "$new_inv" \
                '{"status":"draft","invoice_id":$iid,"to":$to,"amount":$amt,"currency":$curr,"idempotency_key":$idem,"_idempotent":false,"_new_invoice_json":$nij}'
        else
            printf '{"error_code":"UNKNOWN_COMMAND","retryable":false}\n'
        fi
        ;;
    --version)
        printf '{"tool":"ledger","version":"0.1.11-stub","schema_version":1}\n'
        ;;
    --describe)
        printf '{"tool":"ledger","schema_version":1}\n'
        ;;
    *)
        printf '{"error_code":"UNKNOWN_COMMAND","retryable":false}\n'
        ;;
esac
LEDGER_STUB
    chmod +x "${dir}/ledger"
}

make_ledger_auth_stub() {
    local dir="$1"
    cat > "${dir}/ledger" << 'AUTH_STUB'
#!/bin/sh
printf '{"error_code":"ORG_NOT_FOUND","error":"eval stub","retryable":false}\n'
AUTH_STUB
    chmod +x "${dir}/ledger"
}
