#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# evolve/eval-bridge.sh — MCP bridge eval for the evolve self-improvement tools.
# Runs eval-cases.jsonl (stateless unit cases) plus an interactive integration
# test that exercises the in-memory approval-nonce lifecycle and a tamper check.
#
# Usage: bash evolve/eval-bridge.sh

set -uo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/mcp-bridge.sh"
CASES="${SCRIPT_DIR}/eval-cases.jsonl"

TEST_DATA_DIR="$(mktemp -d)"
export HEROS_DATA_DIR="$TEST_DATA_DIR"
SKILLS_FILE="${TEST_DATA_DIR}/.evolve-skills.json"
AUDIT_FILE="${TEST_DATA_DIR}/.evolve-audit"
trap 'rm -rf "$TEST_DATA_DIR"' EXIT

PASS=0; FAIL=0; ERRORS=()

INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}'

# ── Seed deterministic registry fixtures (direct write — no bridge needed) ──
# seed_skill: pending (unit cases operate on it). seed_active: active (collision/retire paths).
_seed_registry() {
    local now; now=$(date +%s)
    jq -cn --argjson now "$now" '{
        "skills": {
            "seed_skill":  {"name":"seed_skill","trigger":"seeded pending skill","steps":["step one","step two"],"rationale":"seed","state":"pending","successes":0,"failures":0,"score":0.0,"created_ts":$now,"updated_ts":$now},
            "seed_active": {"name":"seed_active","trigger":"seeded active skill","steps":["do a thing"],"rationale":"seed","state":"active","successes":0,"failures":0,"score":0.0,"created_ts":$now,"updated_ts":$now}
        }
    }' > "$SKILLS_FILE"
}

# ── Read from the interactive bridge (fd 9) until a response with given id ───
# Called inside $(...) — fd 9 is inherited by the subshell (unlike coproc fds).
_recv_for_id() {
    local want="$1" liner id
    while IFS= read -r -t 20 liner <&9; do
        [[ -z "$liner" ]] && continue
        id=$(jq -r '.id // empty' <<< "$liner" 2>/dev/null) || continue
        [[ -z "$id" ]] && continue
        if [[ "$id" == "$want" ]]; then
            jq -r '.result.content[0].text' <<< "$liner" 2>/dev/null || printf '{}'
            return 0
        fi
    done
    printf '{}'; return 1
}

# ── Stateless unit-case runner (fresh session per case) ─────────────────────
_run_case() {
    local id="$1" desc="$2" tool="$3" input_json="$4" expect_json="$5"
    local result
    result=$(printf '%s\n%s\n' "$INIT" \
        "$(jq -cn --arg tool "$tool" --argjson args "$input_json" \
            '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":$tool,"arguments":$args}}')" \
        | timeout 10 bash "$BRIDGE" 2>/dev/null \
        | grep -v '"method"' | tail -1 \
        | jq -r '.result.content[0].text' 2>/dev/null || printf '{}')

    local fail_fields=()
    while IFS= read -r key; do
        local exp_val act_val
        exp_val=$(jq -c --arg k "$key" '.[$k]' <<< "$expect_json" 2>/dev/null || printf 'null')
        act_val=$(jq -c --arg k "$key" '.[$k]' <<< "$result" 2>/dev/null || printf 'null')
        [[ "$exp_val" != "$act_val" ]] && fail_fields+=("${key}: expected=${exp_val} actual=${act_val}")
    done < <(jq -r 'keys[]' <<< "$expect_json" 2>/dev/null || true)

    if [[ ${#fail_fields[@]} -eq 0 ]]; then
        PASS=$(( PASS + 1 )); printf '  PASS [%s] %s\n' "$id" "$desc"
    else
        FAIL=$(( FAIL + 1 )); printf '  FAIL [%s] %s\n' "$id" "$desc"
        for f in "${fail_fields[@]}"; do printf '       %s\n' "$f"; done
        ERRORS+=("[${id}] ${desc}: ${fail_fields[*]}")
    fi
}

_chk() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$(( PASS + 1 )); printf '  PASS [INT] %s\n' "$label"
    else
        FAIL=$(( FAIL + 1 )); printf '  FAIL [INT] %s: expected=%s actual=%s\n' "$label" "$expected" "$actual"
        ERRORS+=("[INT] ${label}: expected=${expected} actual=${actual}")
    fi
}

# ── Integration: full gated self-improvement lifecycle in one live session ──
_run_integration() {
    printf '\n-- Integration: gated self-improvement lifecycle --\n'
    local IN="${TEST_DATA_DIR}/in.fifo" OUT="${TEST_DATA_DIR}/out.fifo"
    rm -f "$IN" "$OUT"; mkfifo "$IN" "$OUT"
    timeout 40 bash "$BRIDGE" <"$IN" >"$OUT" 2>/dev/null &
    local bg=$!
    exec 8>"$IN"
    exec 9<"$OUT"

    printf '%s\n' "$INIT" >&8

    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"evolve_skill_propose","arguments":{"name":"rollback_on_error","trigger":"deploy fails","steps":["detect failure","run rollback","alert human"],"actor":"agent-int"}}}' >&8
    local r1; r1=$(_recv_for_id 1)
    _chk "propose -> pending" "pending" "$(jq -r '.state // ""' <<< "$r1")"

    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"evolve_skill_promote","arguments":{"name":"rollback_on_error"}}}' >&8
    local r2 nonce; r2=$(_recv_for_id 2)
    _chk "promote(no nonce) -> decision_required" "true" "$(jq -r '.decision_required // ""' <<< "$r2")"
    nonce=$(jq -r '.approval_nonce // ""' <<< "$r2")
    if [[ "$nonce" =~ ^[0-9a-f]{16}$ ]]; then
        PASS=$(( PASS + 1 )); printf '  PASS [INT] approval_nonce is 16 hex chars\n'
    else
        FAIL=$(( FAIL + 1 )); printf '  FAIL [INT] approval_nonce malformed: %s\n' "$nonce"
        ERRORS+=("[INT] approval_nonce malformed: ${nonce}")
    fi

    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"evolve_skill_get","arguments":{"name":"rollback_on_error"}}}' >&8
    local r3; r3=$(_recv_for_id 3)
    _chk "still pending before approval" "pending" "$(jq -r '.skill.state // ""' <<< "$r3")"

    printf '%s\n' "$(jq -cn --arg n "$nonce" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"evolve_skill_promote","arguments":{"name":"rollback_on_error","human_acknowledgment_token":$n}}}')" >&8
    local r4; r4=$(_recv_for_id 4)
    _chk "promote(nonce) -> active" "active" "$(jq -r '.state // ""' <<< "$r4")"
    _chk "promote(nonce) -> proceed_ok" "true" "$(jq -r '.proceed_ok // ""' <<< "$r4")"

    printf '%s\n' "$(jq -cn --arg n "$nonce" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"evolve_skill_promote","arguments":{"name":"rollback_on_error","human_acknowledgment_token":$n}}}')" >&8
    local r5; r5=$(_recv_for_id 5)
    _chk "replayed nonce / re-promote is an error" "true" "$(jq -r 'has("error_code")' <<< "$r5")"

    printf '%s\n' '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"evolve_skill_record_outcome","arguments":{"name":"rollback_on_error","outcome":"success"}}}' >&8
    _recv_for_id 6 >/dev/null
    printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"evolve_skill_record_outcome","arguments":{"name":"rollback_on_error","outcome":"success"}}}' >&8
    _recv_for_id 7 >/dev/null
    printf '%s\n' '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"evolve_skill_record_outcome","arguments":{"name":"rollback_on_error","outcome":"failure"}}}' >&8
    local r8; r8=$(_recv_for_id 8)
    _chk "outcomes counted (2 succ)" "2" "$(jq -r '.successes // ""' <<< "$r8")"
    _chk "outcomes counted (1 fail)" "1" "$(jq -r '.failures // ""' <<< "$r8")"
    local score; score=$(jq -r '.score // 0' <<< "$r8")
    if awk -v s="$score" 'BEGIN{exit !(s>0 && s<1)}'; then
        PASS=$(( PASS + 1 )); printf '  PASS [INT] score in (0,1): %s\n' "$score"
    else
        FAIL=$(( FAIL + 1 )); printf '  FAIL [INT] score not in (0,1): %s\n' "$score"
        ERRORS+=("[INT] score not in (0,1): ${score}")
    fi

    printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"evolve_history","arguments":{"limit":50}}}' >&8
    local r9; r9=$(_recv_for_id 9)
    _chk "history valid" "true" "$(jq -r '.valid // ""' <<< "$r9")"

    printf '%s\n' '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"evolve_skill_retire","arguments":{"name":"rollback_on_error"}}}' >&8
    local r10 rnonce; r10=$(_recv_for_id 10)
    _chk "retire(no nonce) -> decision_required" "true" "$(jq -r '.decision_required // ""' <<< "$r10")"
    rnonce=$(jq -r '.approval_nonce // ""' <<< "$r10")
    printf '%s\n' "$(jq -cn --arg n "$rnonce" '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"evolve_skill_retire","arguments":{"name":"rollback_on_error","human_acknowledgment_token":$n}}}')" >&8
    local r11; r11=$(_recv_for_id 11)
    _chk "retire(nonce) -> retired" "retired" "$(jq -r '.state // ""' <<< "$r11")"

    exec 8>&-
    exec 9<&-
    wait "$bg" 2>/dev/null || true
    rm -f "$IN" "$OUT"
}

# ── Tamper test: corrupt the change log, expect history valid:false ─────────
_run_tamper() {
    printf '\n-- Integration: tamper detection --\n'
    if [[ ! -s "$AUDIT_FILE" ]]; then
        FAIL=$(( FAIL + 1 )); printf '  FAIL [INT] audit log missing for tamper test\n'
        ERRORS+=("[INT] audit log missing for tamper test"); return
    fi
    local first rest tampered
    first=$(head -n 1 "$AUDIT_FILE")
    rest=$(tail -n +2 "$AUDIT_FILE")
    tampered=$(jq -c '.details = {"tampered":true}' <<< "$first")
    { printf '%s\n' "$tampered"; [[ -n "$rest" ]] && printf '%s\n' "$rest"; } > "${AUDIT_FILE}.new"
    mv "${AUDIT_FILE}.new" "$AUDIT_FILE"

    local res
    res=$(printf '%s\n%s\n' "$INIT" \
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"evolve_history","arguments":{"limit":50}}}' \
        | timeout 10 bash "$BRIDGE" 2>/dev/null | grep -v '"method"' | tail -1 \
        | jq -r '.result.content[0].text' 2>/dev/null || printf '{}')
    _chk "tampered log -> valid:false" "false" "$(jq -r '.valid' <<< "$res" 2>/dev/null || printf 'ERR')"
    local ba; ba=$(jq -r '.broken_at_entry // 0' <<< "$res")
    if [[ "$ba" == "1" ]]; then
        PASS=$(( PASS + 1 )); printf '  PASS [INT] broken_at_entry=1\n'
    else
        FAIL=$(( FAIL + 1 )); printf '  FAIL [INT] broken_at_entry expected=1 actual=%s\n' "$ba"
        ERRORS+=("[INT] broken_at_entry expected=1 actual=${ba}")
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────
_seed_registry

total_cases=$(grep -c '' "$CASES" 2>/dev/null || printf '0')
printf 'evolve eval-bridge — running %s unit cases + integration\n' "$total_cases"
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
_run_tamper

printf '\n'
printf 'Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" $(( PASS + FAIL ))
if [[ $FAIL -gt 0 ]]; then
    printf '\nFAILURES:\n'
    for e in "${ERRORS[@]}"; do printf '  %s\n' "$e"; done
    exit 1
fi
printf 'OK — all cases passed\n'
