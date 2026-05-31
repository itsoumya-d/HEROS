#!/usr/bin/env bash
#
# eval-litestream.sh — tests for ledger/litestream-replicate.sh
#
# Runs without requiring litestream to be installed. For the "litestream
# present" case we put a STUB litestream on PATH that only answers
# `version` (it never starts replication).
#
set -euo pipefail
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WRAP="$HERE/litestream-replicate.sh"

PASS=0
FAIL=0
LAST_RC=0
LAST_OUT=""

# A clean PATH that does NOT contain a real litestream, but keeps the
# coreutils / jq we depend on. We point at the standard system dirs.
NO_LS_PATH="/usr/local/bin:/usr/bin:/bin"

# Sanity: jq must be reachable on the stripped PATH; if not, fall back to
# the inherited PATH (some environments install jq elsewhere).
if ! PATH="$NO_LS_PATH" command -v jq >/dev/null 2>&1; then
  NO_LS_PATH="$PATH"
fi
# If a real litestream sits in those dirs, fail loud — the absence tests
# would be meaningless.
if PATH="$NO_LS_PATH" command -v litestream >/dev/null 2>&1; then
  echo "ERROR: a real litestream is on the test PATH; absence tests cannot run" >&2
  exit 1
fi

# Temp workspace.
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Build a stub litestream that only handles `version`.
STUB_DIR="$TMP/stubbin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/litestream" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "version" ]; then
  echo "v0.3.13"
  exit 0
fi
# The stub must never actually replicate/restore during tests.
echo "stub-litestream: refusing to run '$*'" >&2
exit 99
STUB
chmod +x "$STUB_DIR/litestream"
STUB_PATH="$STUB_DIR:$NO_LS_PATH"

# Helpers --------------------------------------------------------------------

# jqget JSON FILTER -> value
jqget() { jq -r "$2" <<<"$1"; }

# check_eq NAME EXPECTED ACTUAL
check_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

# run_nols ARGS... : runs wrapper with litestream ABSENT.
# Sets globals LAST_OUT (stdout) and LAST_RC (exit code) in THIS shell.
# (Not invoked via $(...) so the globals survive — command substitution would
# run in a subshell and lose LAST_RC.)
run_nols() {
  set +e
  PATH="$NO_LS_PATH" bash "$WRAP" "$@" >"$TMP/out" 2>/dev/null
  LAST_RC=$?
  set -e
  LAST_OUT="$(cat "$TMP/out")"
}

# run_stub ARGS... : runs wrapper with the STUB litestream PRESENT.
run_stub() {
  set +e
  PATH="$STUB_PATH" bash "$WRAP" "$@" >"$TMP/out" 2>/dev/null
  LAST_RC=$?
  set -e
  LAST_OUT="$(cat "$TMP/out")"
}

# ---------------------------------------------------------------------------
# Test 1: check with litestream absent -> available:false, exit 0
# ---------------------------------------------------------------------------
run_nols check
check_eq "1 check(absent) exit 0" "0" "$LAST_RC"
check_eq "1 check(absent) error_code" "LITESTREAM_NOT_AVAILABLE" "$(jqget "$LAST_OUT" '.error_code')"
check_eq "1 check(absent) available" "false" "$(jqget "$LAST_OUT" '.available')"

# ---------------------------------------------------------------------------
# Test 2: check with stub litestream on PATH -> available:true, version parsed
# ---------------------------------------------------------------------------
run_stub check
check_eq "2 check(stub) exit 0" "0" "$LAST_RC"
check_eq "2 check(stub) available" "true" "$(jqget "$LAST_OUT" '.available')"
check_eq "2 check(stub) version" "v0.3.13" "$(jqget "$LAST_OUT" '.version')"

# ---------------------------------------------------------------------------
# Test 3: validate good db + s3:// replica -> valid:true (no litestream)
# ---------------------------------------------------------------------------
GOOD_DB="$TMP/data/app.db"
mkdir -p "$TMP/data"
run_nols validate --db "$GOOD_DB" --replica "s3://my-bucket/ledger"
check_eq "3 validate(good) exit 0" "0" "$LAST_RC"
check_eq "3 validate(good) valid" "true" "$(jqget "$LAST_OUT" '.valid')"
check_eq "3 validate(good) scheme" "s3" "$(jqget "$LAST_OUT" '.replica_scheme')"

# ---------------------------------------------------------------------------
# Test 4: validate unsupported scheme (http://) -> UNSUPPORTED_SCHEME
# ---------------------------------------------------------------------------
run_nols validate --db "$GOOD_DB" --replica "http://example.com/x"
check_eq "4 validate(http) exit 0" "0" "$LAST_RC"
check_eq "4 validate(http) error_code" "UNSUPPORTED_SCHEME" "$(jqget "$LAST_OUT" '.error_code')"

# ---------------------------------------------------------------------------
# Test 5: validate parent dir missing -> PARENT_DIR_MISSING
# ---------------------------------------------------------------------------
run_nols validate --db "$TMP/nope/here/app.db" --replica "s3://b/k"
check_eq "5 validate(no-parent) exit 0" "0" "$LAST_RC"
check_eq "5 validate(no-parent) error_code" "PARENT_DIR_MISSING" "$(jqget "$LAST_OUT" '.error_code')"

# ---------------------------------------------------------------------------
# Test 6: validate missing --db -> MISSING_FLAG
# ---------------------------------------------------------------------------
run_nols validate --replica "s3://b/k"
check_eq "6 validate(no-db) exit 0" "0" "$LAST_RC"
check_eq "6 validate(no-db) error_code" "MISSING_FLAG" "$(jqget "$LAST_OUT" '.error_code')"

# ---------------------------------------------------------------------------
# Test 7: replicate with litestream absent -> LITESTREAM_NOT_AVAILABLE
# ---------------------------------------------------------------------------
run_nols replicate --db "$GOOD_DB" --replica "s3://b/k"
check_eq "7 replicate(absent) exit 0" "0" "$LAST_RC"
check_eq "7 replicate(absent) error_code" "LITESTREAM_NOT_AVAILABLE" "$(jqget "$LAST_OUT" '.error_code')"

# ---------------------------------------------------------------------------
# Test 8: path traversal / bad input -> INVALID_INPUT
# ---------------------------------------------------------------------------
run_nols validate --db "$TMP/data/../../etc/app.db" --replica "s3://b/k"
check_eq "8 validate(traversal) exit 0" "0" "$LAST_RC"
check_eq "8 validate(traversal) error_code" "INVALID_INPUT" "$(jqget "$LAST_OUT" '.error_code')"

# Extra: control-character injection in replica -> INVALID_INPUT
run_nols validate --db "$GOOD_DB" --replica "$(printf 's3://b/\x07k')"
check_eq "8b validate(ctrl-char) error_code" "INVALID_INPUT" "$(jqget "$LAST_OUT" '.error_code')"

# Extra: --describe is well-formed JSON listing schemes.
run_nols --describe
check_eq "9 describe version" "0.1.0" "$(jqget "$LAST_OUT" '.version')"
check_eq "9 describe has s3" "s3" "$(jqget "$LAST_OUT" '.supported_replica_schemes[0]')"

# ---------------------------------------------------------------------------
echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo "ALL TESTS PASSED"
