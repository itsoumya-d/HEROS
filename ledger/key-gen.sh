#!/usr/bin/env bash
# ledger/key-gen.sh — Generate a new API key and write to .heros-keys.
#
# Provides the key-creation side of V44 auth for v0.1.x (before `ledger key create`
# is implemented as a Zero binary command in v0.2).
#
# Usage:
#   HEROS_HMAC_SEED=<seed> HEROS_DATA_DIR=<dir> ./key-gen.sh --scope rw --org-id <org_id>
#
# Output: JSON with the full key (shown once — cannot be retrieved from stored hash).
#
# HEROS_HMAC_SEED must be a non-empty secret (recommended: 256-bit random hex).
# Generate: openssl rand -hex 32
#
# Requires: openssl ≥ 1.1, xxd, jq.

set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEROS_DATA_DIR="${HEROS_DATA_DIR:-${SCRIPT_DIR}}"
SCOPE="rw"
ORG_ID=""

# ── Arg parsing ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scope)  SCOPE="${2:-}";  shift 2 ;;
        --org-id) ORG_ID="${2:-}"; shift 2 ;;
        *)
            printf '{"error_code":"UNKNOWN_FLAG","retryable":false,"error":"Unknown flag: %s"}\n' "$1" >&2
            exit 1 ;;
    esac
done

# ── Validation ───────────────────────────────────────────────────────────────
if [[ ! "$SCOPE" =~ ^(ro|rw)$ ]]; then
    printf '{"error_code":"INVALID_INPUT","retryable":false,"error":"scope must be ro or rw"}\n' >&2
    exit 1
fi

if [[ -z "$ORG_ID" ]]; then
    printf '{"error_code":"MISSING_FLAG","retryable":false,"error":"--org-id is required"}\n' >&2
    exit 1
fi

if [[ ! "$ORG_ID" =~ ^org_[0-9a-f]{8}$ ]]; then
    printf '{"error_code":"INVALID_INPUT","retryable":false,"error":"--org-id must match org_[0-9a-f]{8}"}\n' >&2
    exit 1
fi

# RT-132: non-empty seed required — empty seed makes HMAC predictable
if [[ -z "${HEROS_HMAC_SEED:-}" ]]; then
    printf '{"error_code":"INVALID_INPUT","retryable":false,"error":"HEROS_HMAC_SEED must be set to a non-empty secret. Generate one: openssl rand -hex 32"}\n' >&2
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    printf '{"error_code":"EXEC_FAILED","retryable":false,"error":"openssl not found in PATH"}\n' >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    printf '{"error_code":"EXEC_FAILED","retryable":false,"error":"python3 not found in PATH"}\n' >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    printf '{"error_code":"EXEC_FAILED","retryable":false,"error":"jq not found in PATH"}\n' >&2
    exit 1
fi

# ── Generate key material (128 bits each = [0-9a-f]{32}) ────────────────────
KEY_ID=$(openssl rand -hex 16)
SECRET=$(openssl rand -hex 16)

# ── HMAC-SHA256(key=HEROS_HMAC_SEED, msg=key_id:secret) ─────────────────────
# Same formula as mcp-bridge.sh _validate_api_key — both must agree.
# Using HEROS_HMAC_SEED as the outer key: stolen .heros-keys alone is useless.
# CRIT-1 FIX: seed passed via env (not CLI arg) — prevents /proc/cmdline exposure.
# Same python3 pattern used in both bridges: single spawn, seed only in environment.
HMAC_HASH=$(printf '%s' "${KEY_ID}:${SECRET}" | \
    python3 -c "
import hmac,hashlib,sys,os
seed=os.environ['HEROS_HMAC_SEED'].encode()
data=sys.stdin.buffer.read()
print(hmac.new(seed,data,hashlib.sha256).hexdigest())
")

CREATED=$(date +%s 2>/dev/null || echo "0")
KEYS_FILE="${HEROS_DATA_DIR}/.heros-keys"

# ── Write to .heros-keys ─────────────────────────────────────────────────────
# Format: key_id scope org_id hmac_hash created_epoch revoked
# Check for key_id collision (RT-135: awk field-exact match — no substring or regex risk)
if awk -v kid="$KEY_ID" '$1 == kid { found=1; exit } END { exit !found }' \
        "$KEYS_FILE" 2>/dev/null; then
    printf '{"error_code":"KEY_ALREADY_EXISTS","retryable":true,"error":"key_id collision — try again"}\n' >&2
    exit 1
fi

printf '%s %s %s %s %s 0\n' "$KEY_ID" "$SCOPE" "$ORG_ID" "$HMAC_HASH" "$CREATED" >> "$KEYS_FILE"

# ── Output (full key shown once — secret not recoverable from stored hash) ───
FULL_KEY="heros_${SCOPE}_${KEY_ID}_${SECRET}"
jq -n \
    --arg key   "$FULL_KEY" \
    --arg key_id "$KEY_ID" \
    --arg scope  "$SCOPE" \
    --arg org_id "$ORG_ID" \
    '{
        "status": "ok",
        "key": $key,
        "key_id": $key_id,
        "scope": $scope,
        "org_id": $org_id,
        "warning": "Store this key securely. The secret portion cannot be retrieved after creation."
    }'
