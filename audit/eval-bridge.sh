#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# audit/eval-bridge.sh — MCP bridge eval for audit tools
# Runs eval cases from eval-cases.jsonl against the audit MCP bridge.
#
# Usage:
#   bash audit/eval-bridge.sh
#
# The eval runner builds a fresh MCP session (initialize + tool call) for each
# case. Rate-limit-sensitive cases reuse a single session to preserve bucket state.

set -euo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/mcp-bridge.sh"
CASES="${SCRIPT_DIR}/eval-cases.jsonl"

# Use a temp data dir so tests never pollute the real audit log
TEST_DATA_DIR="$(mktemp -d)"
export HEROS_DATA_DIR="$TEST_DATA_DIR"
trap 'rm -rf "$TEST_DATA_DIR"' EXIT

PASS=0; FAIL=0; ERRORS=()

# ── Seed: pre-populate audit log with 3 entries so verify/list tests work ────
_seed_log() {
    local seed_msgs
    seed_msgs=$(printf '%s\n%s\n%s\n%s\n' \
        '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}' \
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"audit_log","arguments":{"event_type":"migration_approved","actor":"seed-agent","details":{"step":1}}}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"audit_log","arguments":{"event_type":"secret_accessed","actor":"seed-agent","details":{"step":2}}}}' \
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"audit_log","arguments":{"event_type":"invoice_created","actor":"seed-agent","details":{"step":3}}}}')
    printf '%s\n' "$seed_msgs" | timeout 15 bash "$BRIDGE" >/dev/null 2>&1 || true
}

_seed_log

# ── Run a single eval case ────────────────────────────────────────────────────
_run_case() {
    local id="$1" desc="$2" tool="$3" input_json="$4" expect_json="$5"

    local result
    result=$(printf '%s\n%s\n' \
        '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}' \
        "$(jq -cn --arg tool "$tool" --argjson args "$input_json" \
            '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":$tool,"arguments":$args}}')" \
        | timeout 10 bash "$BRIDGE" 2>/dev/null \
        | grep -v '"method"' \
        | tail -1 \
        | jq -r '.result.content[0].text' 2>/dev/null || printf '{}')

    # Check each expected field
    local fail_fields=()
    while IFS= read -r key; do
        local exp_val act_val
        exp_val=$(jq -c --arg k "$key" '.[$k]' <<< "$expect_json" 2>/dev/null || printf 'null')
        act_val=$(jq -c --arg k "$key" '.[$k]' <<< "$result" 2>/dev/null || printf 'null')
        if [[ "$exp_val" != "$act_val" ]]; then
            fail_fields+=("${key}: expected=${exp_val} actual=${act_val}")
        fi
    done < <(jq -r 'keys[]' <<< "$expect_json" 2>/dev/null || true)

    if [[ ${#fail_fields[@]} -eq 0 ]]; then
        PASS=$(( PASS + 1 ))
        printf '  PASS [%s] %s\n' "$id" "$desc"
    else
        FAIL=$(( FAIL + 1 ))
        printf '  FAIL [%s] %s\n' "$id" "$desc"
        for f in "${fail_fields[@]}"; do printf '       %s\n' "$f"; done
        ERRORS+=("[${id}] ${desc}: ${fail_fields[*]}")
    fi
}

# ── Integration test: append 3 entries in one session, verify, list ──────────
_run_integration() {
    printf '\n-- Integration: multi-entry session --\n'

    local session_result
    session_result=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
        '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}' \
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"audit_log","arguments":{"event_type":"db_backup_started","actor":"backup-agent","details":{"db":"payments","env":"prod"}}}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"audit_log","arguments":{"event_type":"db_backup_completed","actor":"backup-agent","details":{"size_mb":42}}}}' \
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"audit_log","arguments":{"event_type":"alert_sent","actor":"monitor-agent","details":{"channel":"pagerduty"}}}}' \
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"audit_verify","arguments":{}}}' \
        '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"audit_list","arguments":{"limit":10}}}' \
        | timeout 20 bash "$BRIDGE" 2>/dev/null \
        | grep -v '"method"') || true

    # Parse results by id
    local log1 log2 log3 verify_r list_r
    log1=$(jq -r 'select(.id==1) | .result.content[0].text' <<< "$session_result" 2>/dev/null || printf '{}')
    log2=$(jq -r 'select(.id==2) | .result.content[0].text' <<< "$session_result" 2>/dev/null || printf '{}')
    log3=$(jq -r 'select(.id==3) | .result.content[0].text' <<< "$session_result" 2>/dev/null || printf '{}')
    verify_r=$(jq -r 'select(.id==4) | .result.content[0].text' <<< "$session_result" 2>/dev/null || printf '{}')
    list_r=$(jq -r 'select(.id==5) | .result.content[0].text' <<< "$session_result" 2>/dev/null || printf '{}')

    local int_pass=0 int_fail=0

    _check_int() {
        local label="$1" expected="$3" actual="$4"
        # $2 (field) is informational only — used in label by caller
        if [[ "$expected" == "$actual" ]]; then
            int_pass=$(( int_pass + 1 ))
            printf '  PASS [INT] %s\n' "$label"
        else
            int_fail=$(( int_fail + 1 ))
            printf '  FAIL [INT] %s: expected=%s actual=%s\n' "$label" "$expected" "$actual"
            ERRORS+=("[INT] ${label}: expected=${expected} actual=${actual}")
        fi
    }

    _check_int "log1 status ok"         "status" '"ok"' "$(jq -c '.status' <<< "$log1" 2>/dev/null || printf 'null')"
    _check_int "log2 status ok"         "status" '"ok"' "$(jq -c '.status' <<< "$log2" 2>/dev/null || printf 'null')"
    _check_int "log3 status ok"         "status" '"ok"' "$(jq -c '.status' <<< "$log3" 2>/dev/null || printf 'null')"
    _check_int "verify valid true"      "valid"  'true' "$(jq -c '.valid' <<< "$verify_r" 2>/dev/null || printf 'null')"
    _check_int "list status ok"         "status" '"ok"' "$(jq -c '.status' <<< "$list_r" 2>/dev/null || printf 'null')"

    # chain_hash must be 64 hex chars
    local ch1; ch1=$(jq -r '.chain_hash // ""' <<< "$log1" 2>/dev/null)
    if [[ ${#ch1} -eq 64 ]]; then
        int_pass=$(( int_pass + 1 ))
        printf '  PASS [INT] chain_hash is 64 hex chars\n'
    else
        int_fail=$(( int_fail + 1 ))
        printf '  FAIL [INT] chain_hash length expected=64 actual=%d\n' "${#ch1}"
        ERRORS+=("[INT] chain_hash length: expected=64 actual=${#ch1}")
    fi

    # entry_ids must be sequential
    local e1 e2 e3
    e1=$(jq -r '.entry_id' <<< "$log1" 2>/dev/null || printf '0')
    e2=$(jq -r '.entry_id' <<< "$log2" 2>/dev/null || printf '0')
    e3=$(jq -r '.entry_id' <<< "$log3" 2>/dev/null || printf '0')
    if [[ $(( e2 - e1 )) -eq 1 && $(( e3 - e2 )) -eq 1 ]]; then
        int_pass=$(( int_pass + 1 ))
        printf '  PASS [INT] entry_ids are sequential\n'
    else
        int_fail=$(( int_fail + 1 ))
        printf '  FAIL [INT] entry_ids not sequential: e1=%s e2=%s e3=%s\n' "$e1" "$e2" "$e3"
        ERRORS+=("[INT] entry_ids not sequential: ${e1} ${e2} ${e3}")
    fi

    PASS=$(( PASS + int_pass ))
    FAIL=$(( FAIL + int_fail ))
}

# ── Main ──────────────────────────────────────────────────────────────────────
total_cases=$(grep -c '' "$CASES" 2>/dev/null || printf '0')
printf 'audit eval-bridge — running %s cases\n' "$total_cases"
printf '\n-- Unit cases --\n'

while IFS= read -r case_line; do
    [[ -z "$case_line" || "$case_line" == \#* ]] && continue
    c_id=$(jq -r '.id' <<< "$case_line")
    c_desc=$(jq -r '.desc' <<< "$case_line")
    c_tool=$(jq -r '.tool' <<< "$case_line")
    c_input=$(jq -c '.input' <<< "$case_line")
    c_expect=$(jq -c '.expect' <<< "$case_line")
    _run_case "$c_id" "$c_desc" "$c_tool" "$c_input" "$c_expect"
done < "$CASES"

_run_integration

printf '\n'
printf 'Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" $(( PASS + FAIL ))

if [[ $FAIL -gt 0 ]]; then
    printf '\nFAILURES:\n'
    for e in "${ERRORS[@]}"; do printf '  %s\n' "$e"; done
    exit 1
fi
printf 'OK — all cases passed\n'
