#!/usr/bin/env bash
# plugin/test/plugin-test.sh — master plugin test runner
#
# Runs all HEROS plugin test suites and reports results with improvement areas.
#
# Usage:
#   bash plugin/test/plugin-test.sh [--mode bridge-only|full]
#
# Modes:
#   bridge-only  (default) — runs registration + bridge tests using stub binaries.
#                            No Zero compiler required.
#   full         — additionally runs zeval.sh against compiled binaries if present.
#                  Falls back to bridge-only with a warning if binaries are absent.
#
# Exit codes:
#   0 — all non-skipped tests passed (or partial: some skipped but none failed)
#   1 — one or more tests failed
set -euo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MODE="bridge-only"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:-bridge-only}"; shift 2 ;;
        --help|-h)
            printf 'Usage: %s [--mode bridge-only|full]\n' "$0"
            exit 0
            ;;
        *)
            printf '{"error_code":"UNKNOWN_FLAG","flag":"%s"}\n' "$1" >&2
            exit 1
            ;;
    esac
done

for _req in jq bash; do
    command -v "$_req" >/dev/null 2>&1 || {
        printf 'plugin-test: %s not found in PATH (required)\n' "$_req" >&2
        exit 1
    }
done

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
declare -a IMPROVEMENT_AREAS=()

# ── Validate plugin configuration ─────────────────────────────────────────────
echo "=================================================================="
echo " HEROS Plugin Test Suite"
echo " Mode: ${MODE}"
echo " Repo: ${REPO_ROOT}"
echo "=================================================================="
echo ""

echo "[config] Validating .claude/settings.json ..."
SETTINGS="${REPO_ROOT}/.claude/settings.json"
if [[ -f "$SETTINGS" ]]; then
    if jq -e . >/dev/null 2>&1 < "$SETTINGS"; then
        FORGE_CMD=$(jq -r '.mcpServers["heros-forge"].command // ""' "$SETTINGS")
        LEDGER_CMD=$(jq -r '.mcpServers["heros-ledger"].command // ""' "$SETTINGS")
        if [[ -f "$FORGE_CMD" && -f "$LEDGER_CMD" ]]; then
            printf '[config] PASS  .claude/settings.json valid; forge=%s ledger=%s\n' \
                "$(basename "$FORGE_CMD")" "$(basename "$LEDGER_CMD")"
            TOTAL_PASS=$(( TOTAL_PASS + 1 ))
        else
            printf '[config] FAIL  .claude/settings.json: bridge paths not found\n'
            printf '               forge: %s\n' "$FORGE_CMD"
            printf '               ledger: %s\n' "$LEDGER_CMD"
            TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
            IMPROVEMENT_AREAS+=("CONFIG: .claude/settings.json references non-existent bridge files")
        fi
    else
        printf '[config] FAIL  .claude/settings.json is not valid JSON\n'
        TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
        IMPROVEMENT_AREAS+=("CONFIG: .claude/settings.json is not valid JSON")
    fi
else
    printf '[config] FAIL  .claude/settings.json not found at %s\n' "$SETTINGS"
    TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
    IMPROVEMENT_AREAS+=("CONFIG: .claude/settings.json missing — plugin not registered")
fi

# Check binary presence for full mode
FORGE_BIN_PRESENT=false
LEDGER_BIN_PRESENT=false
if [[ -x "${REPO_ROOT}/forge/forge" ]] || command -v forge >/dev/null 2>&1; then
    FORGE_BIN_PRESENT=true
fi
if [[ -x "${REPO_ROOT}/ledger/ledger" ]] || command -v ledger >/dev/null 2>&1; then
    LEDGER_BIN_PRESENT=true
fi

if [[ "$MODE" == "full" ]]; then
    if [[ "$FORGE_BIN_PRESENT" == "false" || "$LEDGER_BIN_PRESENT" == "false" ]]; then
        echo ""
        echo "[mode] WARNING: --mode full requested but compiled binaries not found."
        echo "       Falling back to bridge-only mode."
        echo "       To build: see .github/workflows/release.yml build-and-sign job."
        MODE="bridge-only"
    fi
fi

echo ""

# ── Helper: run a test script, collect counts ─────────────────────────────────
_run_suite() {
    local label="$1" script="$2"
    echo "=================================================================="
    echo " Suite: ${label}"
    echo "=================================================================="
    local out=""
    out=$(bash "$script" 2>/dev/null) || true
    printf '%s\n' "$out"
    local sp sf ss
    sp=$(printf '%s\n' "$out" | grep -c '^PASS' 2>/dev/null || true)
    sf=$(printf '%s\n' "$out" | grep -c '^FAIL' 2>/dev/null || true)
    ss=$(printf '%s\n' "$out" | grep -c '^SKIP' 2>/dev/null || true)
    TOTAL_PASS=$(( TOTAL_PASS + sp ))
    TOTAL_FAIL=$(( TOTAL_FAIL + sf ))
    TOTAL_SKIP=$(( TOTAL_SKIP + ss ))
    if (( sf > 0 )); then
        # Collect failing test IDs for improvement areas
        while IFS= read -r line; do
            case "$line" in
                FAIL*)
                    IMPROVEMENT_AREAS+=("${label}: ${line}")
                    ;;
            esac
        done <<< "$out"
    fi
    if (( ss > 0 )) && [[ "$FORGE_BIN_PRESENT" == "false" ]]; then
        IMPROVEMENT_AREAS+=("${label}: ${ss} test(s) skipped — build forge/ledger binary to enable full coverage")
    fi
    echo ""
}

# ── Run suites ────────────────────────────────────────────────────────────────
chmod +x "${SCRIPT_DIR}/test-registration.sh" \
    "${SCRIPT_DIR}/test-forge-bridge.sh" \
    "${SCRIPT_DIR}/test-ledger-bridge.sh" 2>/dev/null || true

_run_suite "MCP Registration" "${SCRIPT_DIR}/test-registration.sh"
_run_suite "Forge Bridge"     "${SCRIPT_DIR}/test-forge-bridge.sh"
_run_suite "Ledger Bridge"    "${SCRIPT_DIR}/test-ledger-bridge.sh"

# ── Full mode: run zeval against compiled binaries ────────────────────────────
if [[ "$MODE" == "full" ]]; then
    ZEVAL="${REPO_ROOT}/zero-ecosystem/eval-harness/zeval.sh"
    if [[ -f "$ZEVAL" ]]; then
        echo "=================================================================="
        echo " Suite: Forge Binary (zeval)"
        echo "=================================================================="
        FORGE_BIN="${REPO_ROOT}/forge/forge"
        command -v forge >/dev/null 2>&1 && FORGE_BIN="$(command -v forge)"
        FORGE_EVAL_OUT=""
        FORGE_EVAL_OUT=$(bash "$ZEVAL" --binary "$FORGE_BIN" \
            --cases "${REPO_ROOT}/forge/eval-cases.jsonl" 2>/dev/null) || true
        printf '%s\n' "$FORGE_EVAL_OUT"
        fe_pass=$(printf '%s\n' "$FORGE_EVAL_OUT" | jq -r '.passed // 0' 2>/dev/null || echo "0")
        fe_fail=$(printf '%s\n' "$FORGE_EVAL_OUT" | jq -r '.failed // 0' 2>/dev/null || echo "0")
        TOTAL_PASS=$(( TOTAL_PASS + fe_pass ))
        TOTAL_FAIL=$(( TOTAL_FAIL + fe_fail ))
        (( fe_fail > 0 )) && IMPROVEMENT_AREAS+=("Forge Binary: ${fe_fail} eval case(s) failed")
        echo ""

        echo "=================================================================="
        echo " Suite: Ledger Binary (zeval)"
        echo "=================================================================="
        LEDGER_BIN="${REPO_ROOT}/ledger/ledger"
        command -v ledger >/dev/null 2>&1 && LEDGER_BIN="$(command -v ledger)"
        LEDGER_EVAL_OUT=""
        LEDGER_EVAL_OUT=$(bash "$ZEVAL" --binary "$LEDGER_BIN" \
            --cases "${REPO_ROOT}/ledger/eval-cases.jsonl" 2>/dev/null) || true
        printf '%s\n' "$LEDGER_EVAL_OUT"
        le_pass=$(printf '%s\n' "$LEDGER_EVAL_OUT" | jq -r '.passed // 0' 2>/dev/null || echo "0")
        le_fail=$(printf '%s\n' "$LEDGER_EVAL_OUT" | jq -r '.failed // 0' 2>/dev/null || echo "0")
        TOTAL_PASS=$(( TOTAL_PASS + le_pass ))
        TOTAL_FAIL=$(( TOTAL_FAIL + le_fail ))
        (( le_fail > 0 )) && IMPROVEMENT_AREAS+=("Ledger Binary: ${le_fail} eval case(s) failed")
        echo ""
    else
        printf '[full-mode] SKIP  zeval.sh not found at %s\n' "$ZEVAL"
        TOTAL_SKIP=$(( TOTAL_SKIP + 58 ))  # 33 forge + 25 ledger eval cases
        IMPROVEMENT_AREAS+=("Binary evals: 58 cases skipped (zeval.sh missing)")
    fi
fi

# ── Improvement areas ─────────────────────────────────────────────────────────
echo "=================================================================="
echo " Improvement Areas"
echo "=================================================================="
if [[ ${#IMPROVEMENT_AREAS[@]} -eq 0 ]]; then
    echo "  None — all non-skipped tests passed."
else
    for area in "${IMPROVEMENT_AREAS[@]}"; do
        printf '  [!] %s\n' "$area"
    done
fi
echo ""

# ── Final report ─────────────────────────────────────────────────────────────
echo "=================================================================="
echo " Final Report"
echo "=================================================================="
STATUS="ok"
(( TOTAL_FAIL > 0 )) && STATUS="fail"
(( TOTAL_SKIP > 0 && TOTAL_FAIL == 0 )) && STATUS="partial"

printf 'PASS: %d\n' "$TOTAL_PASS"
printf 'FAIL: %d\n' "$TOTAL_FAIL"
printf 'SKIP: %d\n' "$TOTAL_SKIP"
printf 'STATUS: %s\n' "$STATUS"
echo ""

# Emit machine-readable JSON summary to a file if PLUGIN_TEST_RESULT_FILE is set
if [[ -n "${PLUGIN_TEST_RESULT_FILE:-}" ]]; then
    jq -cn \
        --argjson pass "$TOTAL_PASS" \
        --argjson fail "$TOTAL_FAIL" \
        --argjson skip "$TOTAL_SKIP" \
        --arg status "$STATUS" \
        --arg mode "$MODE" \
        --argjson forge_bin "$FORGE_BIN_PRESENT" \
        --argjson ledger_bin "$LEDGER_BIN_PRESENT" \
        '{"pass":$pass,"fail":$fail,"skip":$skip,"status":$status,"mode":$mode,
          "binary_present":{"forge":$forge_bin,"ledger":$ledger_bin}}' \
        > "$PLUGIN_TEST_RESULT_FILE" 2>/dev/null || true
fi

if (( TOTAL_FAIL > 0 )); then
    exit 1
fi
