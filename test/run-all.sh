#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# test/run-all.sh — one-command, whole-repo eval aggregator.
#
# Runs every component's eval suite and prints a per-component PASS/FAIL/SKIP
# matrix. This is the "prove every feature works" deliverable: a single command
# you (or CI, or a packager validating the plugin) can run to see the health of
# the entire HEROS stack at a glance.
#
# Usage:
#   bash test/run-all.sh            # run everything runnable, skip what needs a binary
#   bash test/run-all.sh --help
#
# Exit status:
#   0  every non-skipped suite passed
#   1  at least one non-skipped suite failed
#   2  usage / environment error (e.g. bash too old, jq missing)
#
# Suite classification (verified empirically — see CONTRIBUTING.md):
#   - "core" pure-bash suites run anywhere with bash+jq and always execute.
#   - "binary" suites need a compiled Zero binary (forge/ledger/jsonschema/zlog).
#     The Zero compiler is not in every environment, so these SKIP with an
#     explicit reason when the binary is absent — they are NOT silently passed.
#     CI builds the binaries first, so they run there.
#   - one suite (ledger bridge-auth) additionally needs `xxd`; it SKIPs cleanly
#     if `xxd` is not installed rather than reporting a spurious failure.
#
# A SKIP never fails the run; a FAIL always does. That keeps local runs honest
# (you see exactly what was not exercised) without blocking on toolchain gaps.

set -uo pipefail
export LC_ALL=C.UTF-8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PER_SUITE_TIMEOUT="${HEROS_TEST_TIMEOUT:-180}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '3,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

# ── Pre-flight: the harness itself needs bash 4+ and jq ──────────────────────
if (( BASH_VERSINFO[0] < 4 )); then
    printf 'run-all: bash 4+ required (got %s)\n' "${BASH_VERSION}" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    printf 'run-all: jq not found in PATH (required by every suite)\n' >&2
    exit 2
fi

# ── Result accumulators ──────────────────────────────────────────────────────
declare -a NAMES=() STATES=() NOTES=()
N_PASS=0 N_FAIL=0 N_SKIP=0

_record() { NAMES+=("$1"); STATES+=("$2"); NOTES+=("${3:-}"); }

# locate a forge/ledger binary the same way the bridges do: explicit env var,
# then a binary checked into the tool dir, then PATH.
_find_bin() {
    local envvar="$1" toolrel="$2" name="$3" v
    v="$(eval "printf '%s' \"\${$envvar:-}\"")"
    if [[ -n "$v" && -x "$v" ]]; then printf '%s' "$v"; return 0; fi
    if [[ -x "${REPO_ROOT}/${toolrel}" ]]; then printf '%s' "${REPO_ROOT}/${toolrel}"; return 0; fi
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    return 1
}

# _run <display-name> <script-relpath> — run a suite that is always runnable.
_run() {
    local name="$1" rel="$2" path="${REPO_ROOT}/$2" out rc
    if [[ ! -f "$path" ]]; then
        _record "$name" SKIP "script missing: $rel"; N_SKIP=$((N_SKIP+1))
        printf 'SKIP  %-22s (script missing: %s)\n' "$name" "$rel"; return
    fi
    out="$(cd "${REPO_ROOT}" && timeout "$PER_SUITE_TIMEOUT" bash "$path" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        _record "$name" PASS ""; N_PASS=$((N_PASS+1))
        printf 'PASS  %-22s\n' "$name"
    elif [[ $rc -eq 124 ]]; then
        _record "$name" FAIL "timed out after ${PER_SUITE_TIMEOUT}s"; N_FAIL=$((N_FAIL+1))
        printf 'FAIL  %-22s (timed out after %ss)\n' "$name" "$PER_SUITE_TIMEOUT"
    else
        local tail; tail="$(printf '%s' "$out" | tail -1)"
        _record "$name" FAIL "rc=$rc: $tail"; N_FAIL=$((N_FAIL+1))
        printf 'FAIL  %-22s (rc=%s) %s\n' "$name" "$rc" "$tail"
    fi
}

# _skip <display-name> <reason> — record a deliberate skip (dependency absent).
_skip() {
    _record "$1" SKIP "$2"; N_SKIP=$((N_SKIP+1))
    printf 'SKIP  %-22s (%s)\n' "$1" "$2"
}

printf '── HEROS full eval matrix ───────────────────────────────────────────\n'
printf 'repo: %s\n\n' "$REPO_ROOT"

# ── Core pure-bash suites (always run) ───────────────────────────────────────
_run guardian          guardian/eval-bridge.sh
_run vault             vault/eval-bridge.sh
_run audit             audit/eval-bridge.sh
_run evolve            evolve/eval-bridge.sh
_run remix             remix/eval-bridge.sh
_run forge-squawk      forge/eval-squawk.sh
_run forge-auth        forge/eval-auth.sh
_run ledger-auth       ledger/eval-auth.sh
_run ledger-litestream ledger/eval-litestream.sh
_run herd              herd/eval-herd.sh
_run observability     zero-ecosystem/observability/eval-otel.sh

# ── Suite needing xxd (stub-based, no real binary) ───────────────────────────
if command -v xxd >/dev/null 2>&1; then
    _run ledger-bridge-auth ledger/eval-bridge-auth.sh
else
    _skip ledger-bridge-auth "xxd not installed (apt-get install xxd / vim-common)"
fi

# ── Binary-backed suites (need a compiled Zero binary) ───────────────────────
if forge_bin="$(_find_bin FORGE_BIN forge/forge forge)"; then
    FORGE_BIN="$forge_bin" _run forge-bridge forge/eval-bridge.sh
else
    _skip forge-bridge "forge binary absent (build with the Zero compiler; runs in CI)"
fi

if jsonschema_bin="$(_find_bin JSONSCHEMA_BIN zero-ecosystem/json-schema/jsonschema jsonschema)"; then
    JSONSCHEMA_BIN="$jsonschema_bin" _run json-schema zero-ecosystem/json-schema/eval-runner.sh
else
    _skip json-schema "jsonschema binary absent (build with the Zero compiler; runs in CI)"
fi

# logger/zlog ships eval-cases.jsonl + zlog_mini.0 but no compiled binary and no
# runner wired up locally; the CI job (added in release.yml) builds + runs it.
_skip logger-zlog "zlog binary absent (build with the Zero compiler; runs in CI)"

# ── Summary matrix ───────────────────────────────────────────────────────────
printf '\n── Summary ──────────────────────────────────────────────────────────\n'
for i in "${!NAMES[@]}"; do
    printf '  %-5s %-22s %s\n' "${STATES[$i]}" "${NAMES[$i]}" "${NOTES[$i]}"
done
printf '─────────────────────────────────────────────────────────────────────\n'
printf 'TOTAL: %d passed, %d failed, %d skipped (of %d suites)\n' \
    "$N_PASS" "$N_FAIL" "$N_SKIP" "${#NAMES[@]}"

if [[ $N_FAIL -gt 0 ]]; then
    printf 'RESULT: FAIL — %d suite(s) failed\n' "$N_FAIL"
    exit 1
fi
printf 'RESULT: PASS — all runnable suites green (%d skipped for missing binaries/tools)\n' "$N_SKIP"
exit 0
