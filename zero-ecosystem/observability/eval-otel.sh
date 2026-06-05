#!/usr/bin/env bash
# eval-otel.sh — evaluation harness for otel-trace.sh.
#
# Verifies the no-op contract, enablement logic, the stub-driven emit path,
# and (most importantly) that otel_emit_span never leaks bytes to stdout.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${HERE}/otel-trace.sh"

FAILS=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

# Scratch dir for the stub binary + its marker file.
TMPDIR_OTEL="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_OTEL"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Case 1: OTEL unset -> disabled; emit produces NO stdout and returns 0.
# ---------------------------------------------------------------------------
(
	unset OTEL_EXPORTER_OTLP_ENDPOINT
	# shellcheck source=/dev/null
	source "$HELPER"

	if otel_trace_enabled; then
		exit 11  # should be disabled
	fi

	out="$(otel_emit_span ledger ledger.balance ok 5 foo=bar 2>/dev/null)"
	rc=$?
	if [ "$rc" -ne 0 ]; then exit 12; fi
	if [ -n "$out" ]; then exit 13; fi
	exit 0
)
rc=$?
case "$rc" in
	0) pass "case1: OTEL unset -> disabled, emit silent no-op (rc=0, no stdout)" ;;
	11) fail "case1: trace_enabled returned true while OTEL unset" ;;
	12) fail "case1: emit_span returned non-zero while disabled" ;;
	13) fail "case1: emit_span wrote to stdout while disabled" ;;
	*) fail "case1: unexpected rc=$rc" ;;
esac

# ---------------------------------------------------------------------------
# Case 2: endpoint set but otel-cli absent -> still disabled, no-op.
# Force an empty PATH (except a dir with no otel-cli) so command -v fails.
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR_OTEL/emptybin"
(
	export OTEL_EXPORTER_OTLP_ENDPOINT="https://example.invalid:443"
	# Empty bin dir as the only PATH entry: otel-cli (and everything else) is
	# absent, so command -v otel-cli must fail. The helper uses only bash
	# builtins, so it still works with no external commands on PATH.
	export PATH="$TMPDIR_OTEL/emptybin"
	# shellcheck source=/dev/null
	source "$HELPER"

	if otel_trace_enabled; then exit 21; fi
	out="$(otel_emit_span ledger ledger.balance ok 5 2>/dev/null)"
	rc=$?
	if [ "$rc" -ne 0 ]; then exit 22; fi
	if [ -n "$out" ]; then exit 23; fi
	exit 0
)
rc=$?
case "$rc" in
	0) pass "case2: endpoint set, otel-cli absent -> disabled, silent no-op" ;;
	21) fail "case2: trace_enabled true with otel-cli absent" ;;
	22) fail "case2: emit_span returned non-zero" ;;
	23) fail "case2: emit_span wrote to stdout" ;;
	*) fail "case2: unexpected rc=$rc" ;;
esac

# ---------------------------------------------------------------------------
# Case 3: stub otel-cli on PATH + endpoint set -> enabled; emit invokes stub,
# stub writes a marker file (NOT stdout) containing the span args; verify the
# marker has the span name + mcp.tool.name attr; verify NO stdout leaked.
# ---------------------------------------------------------------------------
STUB_DIR="$TMPDIR_OTEL/bin"
MARKER="$TMPDIR_OTEL/marker.txt"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/otel-cli" <<STUB
#!/usr/bin/env bash
# Stub otel-cli: record all args to the marker file, emit nothing to stdout.
{
  printf 'INVOKED'
  for a in "\$@"; do printf ' %s' "\$a"; done
  printf '\n'
} >>"$MARKER"
exit 0
STUB
chmod +x "$STUB_DIR/otel-cli"

stdout_capture="$TMPDIR_OTEL/stdout.txt"
(
	export OTEL_EXPORTER_OTLP_ENDPOINT="https://example.invalid:443"
	export PATH="$STUB_DIR:$PATH"
	# shellcheck source=/dev/null
	source "$HELPER"

	if ! otel_trace_enabled; then exit 31; fi

	# Capture ONLY stdout (let stderr through to the harness, /dev/null'd below).
	otel_emit_span ledger ledger.balance ok 42 user=alice >"$stdout_capture" 2>/dev/null
	exit $?
)
rc=$?

if [ "$rc" -eq 31 ]; then
	fail "case3: trace_enabled false with stub present + endpoint set"
elif [ "$rc" -ne 0 ]; then
	fail "case3: emit_span returned non-zero rc=$rc"
else
	# 3a: stdout must be empty.
	if [ -s "$stdout_capture" ]; then
		fail "case3a: emit_span leaked bytes to stdout: $(cat "$stdout_capture")"
	else
		pass "case3a: emit_span produced ZERO stdout bytes (stdout clean)"
	fi

	# 3b: stub must have been invoked and recorded the span.
	if [ ! -f "$MARKER" ]; then
		fail "case3b: stub otel-cli was not invoked (no marker file)"
	elif ! grep -q -- '--name ledger.balance' "$MARKER"; then
		fail "case3b: marker missing span name '--name ledger.balance'"
	else
		pass "case3b: stub invoked with --name ledger.balance"
	fi

	# 3c: mcp.tool.name attribute must be present in --attrs.
	if [ -f "$MARKER" ] && grep -q -- 'mcp.tool.name=ledger.balance' "$MARKER"; then
		pass "case3c: mcp.tool.name=ledger.balance attribute present"
	else
		fail "case3c: mcp.tool.name attribute missing from span attrs"
	fi
fi

# ---------------------------------------------------------------------------
# Case 3d: malformed/unsafe attr pairs must be dropped (no comma injection).
# ---------------------------------------------------------------------------
: >"$MARKER"
(
	export OTEL_EXPORTER_OTLP_ENDPOINT="https://example.invalid:443"
	export PATH="$STUB_DIR:$PATH"
	# shellcheck source=/dev/null
	source "$HELPER"
	otel_emit_span ledger ledger.write ok 1 "evil=a,b=injected" "ok=fine" >/dev/null 2>&1
)
if grep -q -- 'b=injected' "$MARKER"; then
	fail "case3d: comma-bearing attr value was NOT dropped (injection risk)"
elif grep -q -- 'ok=fine' "$MARKER"; then
	pass "case3d: unsafe comma attr dropped, safe attr kept"
else
	fail "case3d: safe attr 'ok=fine' was unexpectedly dropped"
fi

# ---------------------------------------------------------------------------
# Case 4: timer functions return numeric values.
# ---------------------------------------------------------------------------
(
	# shellcheck source=/dev/null
	source "$HELPER"
	t0="$(otel_timer_start)"
	case "$t0" in
		'' | *[!0-9]*) exit 41 ;;
	esac
	ms="$(otel_timer_ms "$t0")"
	case "$ms" in
		'' | *[!0-9]*) exit 42 ;;
	esac
	# Garbage input must yield numeric 0, not an error.
	ms_bad="$(otel_timer_ms "not-a-number")"
	if [ "$ms_bad" != "0" ]; then exit 43; fi
	exit 0
)
rc=$?
case "$rc" in
	0) pass "case4: timer_start/timer_ms return numeric values; bad input -> 0" ;;
	41) fail "case4: timer_start did not return a number" ;;
	42) fail "case4: timer_ms did not return a number" ;;
	43) fail "case4: timer_ms(bad) did not return 0" ;;
	*) fail "case4: unexpected rc=$rc" ;;
esac

# ---------------------------------------------------------------------------
echo "----"
if [ "$FAILS" -ne 0 ]; then
	printf '%d test(s) FAILED\n' "$FAILS"
	exit 1
fi
echo "ALL TESTS PASSED"
exit 0
