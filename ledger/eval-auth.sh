#!/usr/bin/env bash
# ledger/eval-auth.sh — Integration tests for V44 API key auth.
# Tests key-gen.sh output + mcp-bridge.sh _validate_api_key round-trips.
#
# Run: bash ledger/eval-auth.sh
# Requires: openssl, xxd, jq, python3 (for constant-time compare in bridge)

set -euo pipefail
export LANG=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────────────────────────
pass() { echo "PASS [$1] $2"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL [$1] $2"; FAIL=$(( FAIL + 1 )); }

# Source _validate_api_key from bridge (without running the server loop)
# Extracts the function definition to a temp file and dot-sources it.
_source_bridge() {
    local tmp_dir="$1"
    HEROS_DATA_DIR="$tmp_dir"
    local fn_file
    fn_file=$(mktemp)
    sed -n '/^_validate_api_key()/,/^}/p' "${SCRIPT_DIR}/mcp-bridge.sh" > "$fn_file"
    # shellcheck source=/dev/null
    . "$fn_file"
    rm -f "$fn_file"
}

# ── Test setup ───────────────────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export HEROS_HMAC_SEED
HEROS_HMAC_SEED=$(openssl rand -hex 32)
export HEROS_DATA_DIR="$TMP"

# Source _validate_api_key from bridge
_source_bridge "$TMP"

# ── BA-01: key-gen produces valid JSON with expected fields ──────────────────
BA01_ORG="org_00000001"
BA01_OUT=$(bash "${SCRIPT_DIR}/key-gen.sh" --scope rw --org-id "$BA01_ORG" 2>&1)
if jq -e '.status == "ok" and (.key | startswith("heros_rw_")) and .key_id and .warning' \
    <<< "$BA01_OUT" >/dev/null 2>&1; then
    pass "BA-01" "key-gen produces valid JSON with status:ok and heros_rw_ prefix"
else
    fail "BA-01" "key-gen output unexpected: $BA01_OUT"
fi

# Extract key from BA-01 output for subsequent tests
BA01_KEY=$(jq -r '.key' <<< "$BA01_OUT")
BA01_KEY_ID=$(jq -r '.key_id' <<< "$BA01_OUT")

# ── BA-02: _validate_api_key succeeds with generated key (rw) ────────────────
BA02_ORG=$(_validate_api_key "$BA01_KEY" "rw") || BA02_RC=$?
if [[ "${BA02_RC:-0}" -eq 0 && "$BA02_ORG" == "$BA01_ORG" ]]; then
    pass "BA-02" "_validate_api_key returns correct org_id for valid rw key"
else
    fail "BA-02" "_validate_api_key failed (rc=${BA02_RC:-?}) or wrong org: '$BA02_ORG'"
fi
unset BA02_RC

# ── BA-03: rw key satisfies ro scope check ───────────────────────────────────
_validate_api_key "$BA01_KEY" "ro" >/dev/null || BA03_RC=$?
if [[ "${BA03_RC:-0}" -eq 0 ]]; then
    pass "BA-03" "rw key satisfies ro scope requirement"
else
    fail "BA-03" "rw key rejected for ro scope (rc=${BA03_RC:-?})"
fi
unset BA03_RC

# ── BA-04: wrong secret → return 1 (INVALID_API_KEY) ────────────────────────
IFS='_' read -r _p _s _kid _sec <<< "$BA01_KEY"
BAD_KEY="heros_rw_${_kid}_$(openssl rand -hex 16)"
BA04_ORG="" BA04_RC=0
BA04_ORG=$(_validate_api_key "$BAD_KEY" "rw") || BA04_RC=$?
if [[ $BA04_RC -eq 1 ]]; then
    pass "BA-04" "wrong secret → return 1 (INVALID_API_KEY)"
else
    fail "BA-04" "wrong secret: expected rc=1, got rc=$BA04_RC org='$BA04_ORG'"
fi

# ── BA-05: unknown key_id → return 1 ────────────────────────────────────────
UNKNOWN_KEY="heros_rw_$(openssl rand -hex 16)_$(openssl rand -hex 16)"
BA05_RC=0
_validate_api_key "$UNKNOWN_KEY" "rw" >/dev/null 2>&1 || BA05_RC=$?
if [[ $BA05_RC -eq 1 ]]; then
    pass "BA-05" "unknown key_id → return 1 (INVALID_API_KEY)"
else
    fail "BA-05" "unknown key_id: expected rc=1, got rc=$BA05_RC"
fi

# ── BA-06: malformed key format → return 1 ──────────────────────────────────
BA06_RC=0
_validate_api_key "not_a_heros_key" "rw" >/dev/null 2>&1 || BA06_RC=$?
if [[ $BA06_RC -eq 1 ]]; then
    pass "BA-06" "malformed key format → return 1"
else
    fail "BA-06" "malformed key: expected rc=1, got rc=$BA06_RC"
fi

# ── BA-07: generate ro key, verify rw requirement rejected → return 3 ────────
BA07_OUT=$(bash "${SCRIPT_DIR}/key-gen.sh" --scope ro --org-id "$BA01_ORG")
BA07_KEY=$(jq -r '.key' <<< "$BA07_OUT")
BA07_RC=0
_validate_api_key "$BA07_KEY" "rw" >/dev/null 2>&1 || BA07_RC=$?
if [[ $BA07_RC -eq 3 ]]; then
    pass "BA-07" "ro key rejected for rw scope → return 3 (INSUFFICIENT_SCOPE)"
else
    fail "BA-07" "ro key + rw scope: expected rc=3, got rc=$BA07_RC"
fi

# ── BA-08: revoked key → return 2 ───────────────────────────────────────────
# Manually revoke BA-01's key by rewriting .heros-keys with revoked=1
sed -i "s/^${BA01_KEY_ID} .*/$(grep "^${BA01_KEY_ID} " "${TMP}/.heros-keys" | awk '{$6=1; print}')/" \
    "${TMP}/.heros-keys" 2>/dev/null || true
BA08_RC=0
_validate_api_key "$BA01_KEY" "rw" >/dev/null 2>&1 || BA08_RC=$?
if [[ $BA08_RC -eq 2 ]]; then
    pass "BA-08" "revoked key → return 2 (API_KEY_REVOKED)"
else
    fail "BA-08" "revoked key: expected rc=2, got rc=$BA08_RC"
fi

# ── BA-09: empty HEROS_HMAC_SEED → return 1 (RT-132) ────────────────────────
ORIG_SEED="$HEROS_HMAC_SEED"
HEROS_HMAC_SEED=""
BA09_RC=0
_validate_api_key "$BA07_KEY" "ro" >/dev/null 2>&1 || BA09_RC=$?
HEROS_HMAC_SEED="$ORIG_SEED"
if [[ $BA09_RC -eq 1 ]]; then
    pass "BA-09" "empty HEROS_HMAC_SEED → return 1 (RT-132 guard fires)"
else
    fail "BA-09" "empty seed: expected rc=1, got rc=$BA09_RC"
fi

# ── BA-10: key-gen rejects empty HEROS_HMAC_SEED ────────────────────────────
HEROS_HMAC_SEED=""
BA10_OUT=$(bash "${SCRIPT_DIR}/key-gen.sh" --scope rw --org-id "org_00000004" 2>&1) || true
HEROS_HMAC_SEED="$ORIG_SEED"
if jq -e '.error_code == "INVALID_INPUT"' <<< "$BA10_OUT" >/dev/null 2>&1; then
    pass "BA-10" "key-gen rejects empty HEROS_HMAC_SEED with INVALID_INPUT"
else
    fail "BA-10" "key-gen with empty seed: $BA10_OUT"
fi

# ── BA-11: key-gen rejects org_id values the bridges would reject ───────────
BA11_OUT=$(bash "${SCRIPT_DIR}/key-gen.sh" --scope rw --org-id "org_x" 2>&1) || true
if jq -e '.error_code == "INVALID_INPUT"' <<< "$BA11_OUT" >/dev/null 2>&1; then
    pass "BA-11" "key-gen rejects invalid org_id before writing .heros-keys"
else
    fail "BA-11" "key-gen with invalid org_id: $BA11_OUT"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
echo "All auth eval cases passed."
