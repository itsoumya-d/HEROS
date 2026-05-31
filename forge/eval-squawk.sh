#!/usr/bin/env bash
#
# eval-squawk.sh — tests for squawk-bridge.sh.
#
# Uses a STUB `squawk` placed on PATH so these tests run without installing the
# real squawk binary. The stub echoes a canned JSON array for `--reporter json`.
#
set -euo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$SCRIPT_DIR/squawk-bridge.sh"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Create a stub squawk on a fresh dir and echo that dir.
#   $1 = canned JSON the stub emits for `--reporter json`
# ---------------------------------------------------------------------------
make_stub_dir() {
  local canned="$1"
  local dir
  dir="$(mktemp -d)"
  # Store the canned JSON in a sibling file so we never embed external data
  # into the stub's shell logic.
  printf '%s\n' "$canned" > "$dir/canned.json"
  cat > "$dir/squawk" <<'STUB'
#!/usr/bin/env bash
# stub squawk: ignore args, print canned JSON from sibling file. Exit non-zero
# when findings exist (mirrors real squawk), zero for the empty array.
here="$(cd "$(dirname "$0")" && pwd)"
cat "$here/canned.json"
if [ "$(tr -d '[:space:]' < "$here/canned.json")" = "[]" ]; then
  exit 0
fi
exit 1
STUB
  chmod +x "$dir/squawk"
  printf '%s' "$dir"
}

# Assert that JSON ($1) has field ($2) equal to ($3). $4 = case name.
assert_field() {
  local json="$1" field="$2" expected="$3" name="$4"
  local actual
  actual="$(printf '%s' "$json" | jq -r "$field" 2>/dev/null || printf '<jq-error>')"
  if [ "$actual" = "$expected" ]; then
    printf 'PASS: %s (%s == %s)\n' "$name" "$field" "$expected"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s (%s: expected %s, got %s)\n' "$name" "$field" "$expected" "$actual"
    printf '      json: %s\n' "$json"
    FAIL=$((FAIL + 1))
  fi
}

# Assert process exit code. $1 = actual, $2 = expected, $3 = name.
assert_exit() {
  if [ "$1" = "$2" ]; then
    printf 'PASS: %s (exit %s)\n' "$3" "$2"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s (exit: expected %s, got %s)\n' "$3" "$2" "$1"
    FAIL=$((FAIL + 1))
  fi
}

# Run the bridge with a stub squawk on PATH. Echoes JSON to stdout.
#   $1 = canned squawk JSON   $2 = sql file path
run_with_stub() {
  local canned="$1" sqlfile="$2" dir
  dir="$(make_stub_dir "$canned")"
  PATH="$dir:$PATH" bash "$BRIDGE" --sql-file "$sqlfile"
  rm -rf "$dir"
}

# A real SQL file to point --sql-file at.
SQLFILE="$(mktemp --suffix=.sql)"
printf 'ALTER TABLE foo DROP COLUMN bar;\n' > "$SQLFILE"

echo "=== squawk-bridge.sh eval ==="

# --- Case 1: ban-drop-column -> CRITICAL ---
J="$(run_with_stub '[{"file":"x.sql","line":1,"column":1,"level":"Warning","messages":[{"Note":"dropping column"}],"rule_name":"ban-drop-column"}]' "$SQLFILE")"
assert_field "$J" '.risk_tier' 'CRITICAL' 'case1 ban-drop-column -> CRITICAL'
assert_field "$J" '.status' 'ok' 'case1 status ok'
assert_field "$J" '.squawk_available' 'true' 'case1 squawk_available'

# --- Case 2: require-concurrent-index-creation -> HIGH ---
J="$(run_with_stub '[{"file":"x.sql","line":2,"column":1,"level":"Warning","messages":[{"Note":"use CONCURRENTLY"}],"rule_name":"require-concurrent-index-creation"}]' "$SQLFILE")"
assert_field "$J" '.risk_tier' 'HIGH' 'case2 require-concurrent-index-creation -> HIGH'

# --- Case 3: prefer-text-field -> MEDIUM ---
J="$(run_with_stub '[{"file":"x.sql","line":3,"column":1,"level":"Warning","messages":[{"Note":"prefer text"}],"rule_name":"prefer-text-field"}]' "$SQLFILE")"
assert_field "$J" '.risk_tier' 'MEDIUM' 'case3 prefer-text-field -> MEDIUM'

# --- Case 4: empty array -> SAFE ---
J="$(run_with_stub '[]' "$SQLFILE")"
assert_field "$J" '.risk_tier' 'SAFE' 'case4 empty -> SAFE'
assert_field "$J" '.finding_count' '0' 'case4 finding_count 0'
assert_field "$J" '.findings | length' '0' 'case4 empty findings array'
assert_field "$J" '.status' 'ok' 'case4 status ok'

# --- Case 5: squawk absent from PATH -> SQUAWK_NOT_AVAILABLE, exit 0 ---
EMPTY_DIR="$(mktemp -d)"
set +e
# Build a PATH that contains ONLY dirs needed for bash/jq but no squawk.
# Easiest: keep current PATH but ensure no squawk; since the real squawk is
# almost certainly absent in CI, current PATH suffices. To be robust, strip
# any dir that contains a squawk by using a minimal PATH with required tools.
JQ_DIR="$(dirname "$(command -v jq)")"
BASH_DIR="$(dirname "$(command -v bash)")"
MKTEMP_DIR="$(dirname "$(command -v mktemp)")"
SAFE_PATH="$JQ_DIR:$BASH_DIR:$MKTEMP_DIR:$EMPTY_DIR"
J="$(PATH="$SAFE_PATH" bash "$BRIDGE" --sql-file "$SQLFILE")"
EC=$?
set -e
rm -rf "$EMPTY_DIR"
assert_exit "$EC" '0' 'case5 exit 0 when squawk absent'
assert_field "$J" '.error_code' 'SQUAWK_NOT_AVAILABLE' 'case5 SQUAWK_NOT_AVAILABLE'
assert_field "$J" '.available' 'false' 'case5 available false'
assert_field "$J" '.retryable' 'false' 'case5 retryable false'

# --- Case 6: --sql-file missing -> MISSING_FLAG ---
set +e
J="$(bash "$BRIDGE")"
EC=$?
set -e
assert_exit "$EC" '0' 'case6 exit 0'
assert_field "$J" '.error_code' 'MISSING_FLAG' 'case6 no args -> MISSING_FLAG'

# --- Case 7: nonexistent file -> FILE_NOT_FOUND ---
DIR7="$(make_stub_dir '[]')"
set +e
J="$(PATH="$DIR7:$PATH" bash "$BRIDGE" --sql-file /tmp/does-not-exist-$$.sql)"
EC=$?
set -e
rm -rf "$DIR7"
assert_exit "$EC" '0' 'case7 exit 0'
assert_field "$J" '.error_code' 'FILE_NOT_FOUND' 'case7 nonexistent -> FILE_NOT_FOUND'

# --- Case 8: multiple findings -> highest tier ---
# MEDIUM + HIGH + CRITICAL present -> CRITICAL
J="$(run_with_stub '[{"file":"x.sql","line":1,"column":1,"level":"Warning","messages":[{"Note":"a"}],"rule_name":"prefer-text-field"},{"file":"x.sql","line":2,"column":1,"level":"Warning","messages":[{"Note":"b"}],"rule_name":"require-concurrent-index-creation"},{"file":"x.sql","line":3,"column":1,"level":"Warning","messages":[{"Note":"c"}],"rule_name":"ban-drop-table"}]' "$SQLFILE")"
assert_field "$J" '.risk_tier' 'CRITICAL' 'case8 multi -> highest (CRITICAL)'
assert_field "$J" '.finding_count' '3' 'case8 finding_count 3'

# MEDIUM + HIGH (no critical) -> HIGH
J="$(run_with_stub '[{"file":"x.sql","line":1,"column":1,"level":"Warning","messages":[{"Note":"a"}],"rule_name":"prefer-text-field"},{"file":"x.sql","line":2,"column":1,"level":"Warning","messages":[{"Note":"b"}],"rule_name":"require-concurrent-index-creation"}]' "$SQLFILE")"
assert_field "$J" '.risk_tier' 'HIGH' 'case8b multi MEDIUM+HIGH -> HIGH'

# --- Bonus: path traversal rejected ---
DIRT="$(make_stub_dir '[]')"
set +e
J="$(PATH="$DIRT:$PATH" bash "$BRIDGE" --sql-file ../../etc/passwd)"
EC=$?
set -e
rm -rf "$DIRT"
assert_field "$J" '.error_code' 'INVALID_INPUT' 'bonus traversal -> INVALID_INPUT'

# --- Bonus: --describe is valid JSON with error_codes documented ---
J="$(bash "$BRIDGE" --describe)"
assert_field "$J" '.name' 'squawk-bridge' 'bonus describe name'
assert_field "$J" '([.error_codes[].code] | sort == ["FILE_NOT_FOUND","INVALID_INPUT","MISSING_FLAG","SQUAWK_FAILED","SQUAWK_NOT_AVAILABLE"])' 'true' 'bonus describe documents all error codes'

# --- Bonus: unknown rule -> MEDIUM (conservative) ---
J="$(run_with_stub '[{"file":"x.sql","line":1,"column":1,"level":"Warning","messages":[{"Note":"x"}],"rule_name":"some-future-rule"}]' "$SQLFILE")"
assert_field "$J" '.risk_tier' 'MEDIUM' 'bonus unknown rule -> MEDIUM'

# --- Bonus: warning level, no rule name -> NOTABLE ---
J="$(run_with_stub '[{"file":"x.sql","line":1,"column":1,"level":"Warning","messages":[{"Note":"x"}]}]' "$SQLFILE")"
assert_field "$J" '.risk_tier' 'NOTABLE' 'bonus no rule + warning -> NOTABLE'

# --- Bonus: squawk emits non-JSON -> SQUAWK_FAILED ---
DIRF="$(mktemp -d)"
cat > "$DIRF/squawk" <<'STUB'
#!/usr/bin/env bash
echo "panic: not json"
exit 2
STUB
chmod +x "$DIRF/squawk"
set +e
J="$(PATH="$DIRF:$PATH" bash "$BRIDGE" --sql-file "$SQLFILE")"
EC=$?
set -e
rm -rf "$DIRF"
assert_exit "$EC" '0' 'bonus non-json exit 0'
assert_field "$J" '.error_code' 'SQUAWK_FAILED' 'bonus non-json -> SQUAWK_FAILED'

rm -f "$SQLFILE"

echo "=== summary: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
