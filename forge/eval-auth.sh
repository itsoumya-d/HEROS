#!/usr/bin/env bash
# forge/eval-auth.sh — Integration tests for V44 API key auth on the forge bridge.
# Tests the _validate_api_key + _audit functions sourced from forge/mcp-bridge.sh.
# Uses ledger/key-gen.sh to generate keys (shared .heros-keys namespace).
#
# Run: bash forge/eval-auth.sh
# Requires: openssl, xxd, jq, python3

set -euo pipefail
export LANG=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_DIR="$(cd "${SCRIPT_DIR}/../ledger" && pwd)"
PASS=0
FAIL=0

pass() { echo "PASS [$1] $2"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL [$1] $2"; FAIL=$(( FAIL + 1 )); }

# Source _validate_api_key and _audit from forge bridge
_source_forge_bridge() {
    local tmp_dir="$1"
    HEROS_DATA_DIR="$tmp_dir"
    local fn_file
    fn_file=$(mktemp)
    sed -n '/^_validate_api_key()/,/^}/p' "${SCRIPT_DIR}/mcp-bridge.sh" >> "$fn_file"
    sed -n '/^_audit()/,/^}/p' "${SCRIPT_DIR}/mcp-bridge.sh" >> "$fn_file"
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

_source_forge_bridge "$TMP"

# ── FA-01: key-gen (via ledger/key-gen.sh) creates key readable by forge bridge ─
FA01_ORG="org_forge_test"
FA01_OUT=$(bash "${LEDGER_DIR}/key-gen.sh" --scope ro --org-id "$FA01_ORG" 2>&1)
if jq -e '.status == "ok" and (.key | startswith("heros_ro_"))' <<< "$FA01_OUT" >/dev/null 2>&1; then
    pass "FA-01" "ledger/key-gen.sh creates ro key readable by forge bridge"
else
    fail "FA-01" "key-gen output unexpected: $FA01_OUT"
fi

FA01_KEY=$(jq -r '.key' <<< "$FA01_OUT")
FA01_KEY_ID=$(jq -r '.key_id' <<< "$FA01_OUT")

# ── FA-02: ro key satisfies forge ro scope requirement ───────────────────────
FA02_ORG="" FA02_RC=0
FA02_ORG=$(_validate_api_key "$FA01_KEY" "ro") || FA02_RC=$?
if [[ "${FA02_RC:-0}" -eq 0 && "$FA02_ORG" == "$FA01_ORG" ]]; then
    pass "FA-02" "ro key validates against forge (ro scope), correct org_id returned"
else
    fail "FA-02" "_validate_api_key failed (rc=${FA02_RC:-?}) org='$FA02_ORG'"
fi
unset FA02_RC

# ── FA-03: rw key also satisfies forge ro scope ──────────────────────────────
FA03_OUT=$(bash "${LEDGER_DIR}/key-gen.sh" --scope rw --org-id "$FA01_ORG" 2>&1)
FA03_KEY=$(jq -r '.key' <<< "$FA03_OUT")
FA03_RC=0
_validate_api_key "$FA03_KEY" "ro" >/dev/null 2>&1 || FA03_RC=$?
if [[ $FA03_RC -eq 0 ]]; then
    pass "FA-03" "rw key satisfies forge ro scope requirement"
else
    fail "FA-03" "rw key rejected for ro scope: rc=$FA03_RC"
fi

# ── FA-04: wrong secret → INVALID_API_KEY ────────────────────────────────────
IFS='_' read -r _p _s _kid _sec <<< "$FA01_KEY"
FA04_BAD="heros_ro_${_kid}_$(openssl rand -hex 16)"
FA04_RC=0
_validate_api_key "$FA04_BAD" "ro" >/dev/null 2>&1 || FA04_RC=$?
if [[ $FA04_RC -eq 1 ]]; then
    pass "FA-04" "wrong secret → return 1 (INVALID_API_KEY)"
else
    fail "FA-04" "expected rc=1, got $FA04_RC"
fi

# ── FA-05: unknown key_id → INVALID_API_KEY ──────────────────────────────────
FA05_UNKNOWN="heros_ro_$(openssl rand -hex 16)_$(openssl rand -hex 16)"
FA05_RC=0
_validate_api_key "$FA05_UNKNOWN" "ro" >/dev/null 2>&1 || FA05_RC=$?
if [[ $FA05_RC -eq 1 ]]; then
    pass "FA-05" "unknown key_id → return 1"
else
    fail "FA-05" "expected rc=1, got $FA05_RC"
fi

# ── FA-06: revoked key → API_KEY_REVOKED ────────────────────────────────────
sed -i "s/^${FA01_KEY_ID} .*/$(awk -v kid="$FA01_KEY_ID" '$1==kid{$6=1;print}' \
    "${TMP}/.heros-keys")/" "${TMP}/.heros-keys" 2>/dev/null || true
FA06_RC=0
_validate_api_key "$FA01_KEY" "ro" >/dev/null 2>&1 || FA06_RC=$?
if [[ $FA06_RC -eq 2 ]]; then
    pass "FA-06" "revoked key → return 2 (API_KEY_REVOKED)"
else
    fail "FA-06" "expected rc=2, got $FA06_RC"
fi

# ── FA-07: empty HEROS_HMAC_SEED → INVALID_API_KEY (RT-132) ─────────────────
ORIG_SEED="$HEROS_HMAC_SEED"
HEROS_HMAC_SEED=""
FA07_RC=0
_validate_api_key "$FA03_KEY" "ro" >/dev/null 2>&1 || FA07_RC=$?
HEROS_HMAC_SEED="$ORIG_SEED"
if [[ $FA07_RC -eq 1 ]]; then
    pass "FA-07" "empty HEROS_HMAC_SEED → return 1 (RT-132 guard)"
else
    fail "FA-07" "expected rc=1, got $FA07_RC"
fi

# ── FA-08: _audit writes to .heros-audit ─────────────────────────────────────
_audit "testkey_abc" "ro" "forge_analyze" "org_forge_test"
if grep -q "testkey_abc ro forge_analyze org_forge_test" "${TMP}/.heros-audit" 2>/dev/null; then
    pass "FA-08" "_audit appends record to .heros-audit"
else
    fail "FA-08" ".heros-audit missing expected audit record"
fi

# ── FA-09: duplicate key_id in .heros-keys — first entry wins (RT-134) ───────
FA09_SHADOW_LINE="${FA01_KEY_ID} ro org_shadow deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef 1000000 0"
echo "$FA09_SHADOW_LINE" >> "${TMP}/.heros-keys"
FA09_ORG="" FA09_RC=0
# FA01_KEY is revoked (from FA-06), so should return 2 (not 0 with shadow org)
FA09_ORG=$(_validate_api_key "$FA01_KEY" "ro") || FA09_RC=$?
if [[ $FA09_RC -eq 2 ]]; then
    pass "FA-09" "duplicate key_id: first entry (revoked=1) wins, shadow entry ignored (RT-134)"
else
    fail "FA-09" "expected rc=2 (revoked first entry wins), got rc=$FA09_RC org='$FA09_ORG'"
fi

# ── FA-10: malformed key format → INVALID_API_KEY ────────────────────────────
FA10_RC=0
_validate_api_key "bad_key_format" "ro" >/dev/null 2>&1 || FA10_RC=$?
if [[ $FA10_RC -eq 1 ]]; then
    pass "FA-10" "malformed key format → return 1"
else
    fail "FA-10" "expected rc=1, got $FA10_RC"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
echo "All forge auth eval cases passed."
