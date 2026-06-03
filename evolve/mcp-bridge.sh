#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ evolve/mcp-bridge.sh — Safe, Audited Agent Self-Improvement             │
# │                                                                          │
# │ Ports the valuable core of an agent self-improvement loop (skills as     │
# │ procedural memory, improved over time from outcomes) into the HEROS      │
# │ safety model. The differentiator: every behaviour-changing               │
# │ self-modification (promote / retire) is risk-gated with a single-use     │
# │ human-approval nonce (guardian protocol) and recorded in a               │
# │ tamper-evident chain-hashed change log (audit protocol).                 │
# │                                                                          │
# │ Architecture: pure bash — no separate binary. The one pure-compute       │
# │ kernel (skill scoring, Wilson lower bound) is specified for Zero in      │
# │ spec/skill_score.0; this bridge holds the reference implementation.      │
# │ Security: jq --arg for all user data, no eval, flock on all writes.      │
# │ Requires: jq >= 1.6, sha256sum (coreutils), flock (util-linux), awk      │
# └──────────────────────────────────────────────────────────────────────────┘

set -euo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

trap 'exit 0' TERM INT PIPE

readonly MCP_PROTOCOL="2025-11-25"
readonly EVOLVE_VERSION="0.1.0"
readonly MAX_MSG=1048576  # 1 MiB

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Storage paths ─────────────────────────────────────────────────────────
DATA_DIR="${HEROS_DATA_DIR:-${SCRIPT_DIR}}"
SKILLS_FILE="${DATA_DIR}/.evolve-skills.json"
EVOLVE_AUDIT="${DATA_DIR}/.evolve-audit"
EVOLVE_AUDIT_STATE="${DATA_DIR}/.evolve-audit-state"
EVOLVE_LOCK="${DATA_DIR}/.evolve-lock"
APPROVALS_FILE="${DATA_DIR}/.evolve-approvals"

# ── Dependency check ──────────────────────────────────────────────────────
for _dep in jq sha256sum flock awk; do
    if ! command -v "$_dep" >/dev/null 2>&1; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"%s required but not found in PATH"}}\n' "$_dep"
        exit 1
    fi
done
unset _dep

# ── Rate limit state (token bucket, in-memory per session) ────────────────
declare -A _RL_BUCKETS
declare -A _RL_LAST
readonly RL_WINDOW=3600

_rl_check() {
    local key="$1" limit="$2" burst="$3"
    local now; now=$(date +%s 2>/dev/null || printf '0')
    local tokens="${_RL_BUCKETS[$key]:-$burst}"
    local last="${_RL_LAST[$key]:-$now}"
    local elapsed=$(( now - last ))
    local refill=$(( elapsed * limit / RL_WINDOW ))
    tokens=$(( tokens + refill ))
    [[ $tokens -gt $burst ]] && tokens=$burst
    _RL_LAST[$key]="$now"
    if [[ $tokens -le 0 ]]; then
        local reset_at=$(( now + RL_WINDOW - elapsed ))
        _RL_BUCKETS[$key]=0
        printf 'RATE_LIMITED %s' "$reset_at"
        return
    fi
    tokens=$(( tokens - 1 ))
    _RL_BUCKETS[$key]="$tokens"
    local reset_at=$(( now + RL_WINDOW ))
    printf 'OK %s %s %s' "$tokens" "$reset_at" "$limit"
}

# ── Approval nonce state (guardian protocol) ──────────────────────────────
# Persisted to a lock-guarded file rather than an in-memory array: tool
# handlers are dispatched via command substitution (a subshell), so an
# in-memory array set when issuing a nonce would not survive to the redeeming
# call. The file is single-use per nonce, 5-min TTL, pruned on write.
_generate_nonce() {
    dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

_approvals_load() {
    if [[ -f "$APPROVALS_FILE" ]]; then
        local raw; raw=$(cat "$APPROVALS_FILE" 2>/dev/null) || { printf '{}'; return; }
        if jq -e 'type=="object"' >/dev/null 2>&1 <<< "$raw"; then printf '%s' "$raw"; else printf '{}'; fi
    else
        printf '{}'
    fi
}

# Caller must hold the lock (fd 9). Stores nonce → "action:skill:expires_at",
# pruning expired entries.
_approval_put_nolock() {
    local nonce="$1" action="$2" skill="$3" exp="$4"
    local a now; a=$(_approvals_load); now=$(date +%s)
    a=$(jq -c --argjson now "$now" 'to_entries | map(select((.value|split(":")[2]|tonumber) > $now)) | from_entries' <<< "$a" 2>/dev/null || printf '{}')
    a=$(jq -c --arg k "$nonce" --arg v "${action}:${skill}:${exp}" '.[$k]=$v' <<< "$a")
    local t; t=$(mktemp "${APPROVALS_FILE}.XXXXXX") || return 1
    printf '%s' "$a" > "$t" && mv "$t" "$APPROVALS_FILE"
}

# Caller must hold the lock. Echoes "action:skill:exp" and deletes it (single
# use); echoes empty string if the nonce is absent.
_approval_take_nolock() {
    local nonce="$1"
    local a v; a=$(_approvals_load)
    v=$(jq -r --arg k "$nonce" '.[$k] // ""' <<< "$a")
    if [[ -n "$v" ]]; then
        a=$(jq -c --arg k "$nonce" 'del(.[$k])' <<< "$a")
        local t; t=$(mktemp "${APPROVALS_FILE}.XXXXXX") || { printf '%s' "$v"; return; }
        printf '%s' "$a" > "$t" && mv "$t" "$APPROVALS_FILE"
    fi
    printf '%s' "$v"
}

# ── Chain hash helper (audit protocol) ─────────────────────────────────────
_chain_hash() {
    local prev_hash="$1" entry_json="$2"
    printf '%s%s' "$prev_hash" "$entry_json" | sha256sum | cut -c1-64
}

# ── Pure-compute kernel: skill confidence score ────────────────────────────
# Wilson score lower bound (95%) of the success proportion. Pure function of
# (successes, failures). Mirrors spec/skill_score.0. Deterministic — no time,
# no I/O — exactly the shape that is portable to a Zero binary.
_wilson_score() {
    local s="$1" f="$2"
    awk -v s="$s" -v f="$f" 'BEGIN{
        n=s+f;
        if(n<=0){printf "0.000"; exit}
        z=1.96; z2=z*z;
        phat=s/n;
        denom=1.0+z2/n;
        center=phat+z2/(2.0*n);
        margin=z*sqrt((phat*(1.0-phat)+z2/(4.0*n))/n);
        lb=(center-margin)/denom;
        if(lb<0)lb=0; if(lb>1)lb=1;
        printf "%.3f", lb;
    }'
}

# ── Registry helpers ───────────────────────────────────────────────────────
_load_registry() {
    if [[ -f "$SKILLS_FILE" ]]; then
        local raw; raw=$(cat "$SKILLS_FILE" 2>/dev/null) || { printf '{"skills":{}}'; return; }
        if jq -e 'type=="object" and has("skills")' >/dev/null 2>&1 <<< "$raw"; then
            printf '%s' "$raw"
        else
            printf '{"skills":{}}'
        fi
    else
        printf '{"skills":{}}'
    fi
}

_write_registry_nolock() {
    local registry="$1"
    local tmp
    tmp=$(mktemp "${SKILLS_FILE}.XXXXXX") || return 1
    printf '%s' "$registry" > "$tmp" && mv "$tmp" "$SKILLS_FILE"
}

# ── Audit append (non-locking; caller holds the lock) ──────────────────────
_audit_append_nolock() {
    local event_type="$1" actor="$2" details_json="$3"
    local prev_hash="GENESIS" entry_count=0
    if [[ -f "$EVOLVE_AUDIT_STATE" ]]; then
        local sraw; sraw=$(cat "$EVOLVE_AUDIT_STATE" 2>/dev/null) || sraw=""
        if [[ -n "$sraw" ]]; then
            prev_hash=$(jq -r '.last_hash // "GENESIS"' <<< "$sraw" 2>/dev/null) || prev_hash="GENESIS"
            entry_count=$(jq -r '.entry_count // 0' <<< "$sraw" 2>/dev/null) || entry_count=0
        fi
    fi
    local now; now=$(date +%s)
    local entry_id=$(( entry_count + 1 ))
    local entry_pre
    entry_pre=$(jq -cn \
        --argjson eid "$entry_id" --argjson ts "$now" \
        --arg et "$event_type" --arg ac "$actor" --argjson det "$details_json" \
        '{"entry_id":$eid,"ts":$ts,"event_type":$et,"actor":$ac,"details":$det}')
    local ch; ch=$(_chain_hash "$prev_hash" "$entry_pre")
    local entry_full
    entry_full=$(jq -cn \
        --argjson eid "$entry_id" --argjson ts "$now" \
        --arg et "$event_type" --arg ac "$actor" --argjson det "$details_json" \
        --arg ch "$ch" \
        '{"entry_id":$eid,"ts":$ts,"event_type":$et,"actor":$ac,"details":$det,"chain_hash":$ch}')
    printf '%s\n' "$entry_full" >> "$EVOLVE_AUDIT" || return 1
    local stmp
    stmp=$(mktemp "${EVOLVE_AUDIT_STATE}.XXXXXX") || return 1
    jq -cn --arg lh "$ch" --argjson ec "$entry_id" \
        '{"last_hash":$lh,"entry_count":$ec}' > "$stmp" && mv "$stmp" "$EVOLVE_AUDIT_STATE"
}

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
_send_error() {
    local req_id="$1" code="$2" msg="$3"
    jq -cn --argjson id "$req_id" --argjson code "$code" --arg msg "$msg" \
        '{"jsonrpc":"2.0","id":$id,"error":{"code":$code,"message":$msg}}'
}

# ── Validation helpers ─────────────────────────────────────────────────────
# ASCII printable only (0x20–0x7E): rejects control chars (incl. newline/tab)
# AND non-ASCII bytes. The empty string is considered valid. Uses tr so that
# embedded newlines cannot slip past a line-oriented grep.
_is_ascii_printable() {
    [[ -z "$1" ]] && return 0
    local leftover
    leftover=$(printf '%s' "$1" | LC_ALL=C tr -d '\040-\176' | wc -c)
    [[ "${leftover//[[:space:]]/}" == "0" ]]
}

_validate_skill_name() {
    local v="$1"
    [[ -n "$v" ]] || return 1
    [[ ${#v} -le 64 ]] || return 1
    [[ "$v" =~ ^[a-z][a-z0-9_]*$ ]] || return 1
    return 0
}

# ── Tool: evolve_skill_propose ─────────────────────────────────────────────
_handle_propose() {
    local params="$1"

    local rl; rl=$(_rl_check "propose" 300 15)
    if [[ "${rl%% *}" == "RATE_LIMITED" ]]; then
        local resa="${rl#* }"; local ra=$(( resa - $(date +%s) )); [[ $ra -lt 1 ]] && ra=1
        jq -cn --argjson ra "$ra" '{"error_code":"RATE_LIMITED","retryable":true,"retry_after_seconds":$ra,"error":"Rate limit exceeded."}'; return
    fi
    local rl_rem reset_at rl_lim; read -r _ rl_rem reset_at rl_lim <<< "$rl"

    local name trigger rationale actor
    name=$(jq -re '.name // empty' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"name","retryable":true,"error":"Required field: name"}'; return; }
    if ! _validate_skill_name "$name"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"name must match [a-z][a-z0-9_]*, max 64 chars"}'; return; fi

    trigger=$(jq -re '.trigger // empty' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"trigger","retryable":true,"error":"Required field: trigger"}'; return; }
    if [[ ${#trigger} -gt 256 ]] || ! _is_ascii_printable "$trigger"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"trigger must be ASCII printable, max 256 chars (no control or non-ASCII bytes)"}'; return; fi

    rationale=$(jq -r '.rationale // ""' <<< "$params" 2>/dev/null)
    if [[ ${#rationale} -gt 512 ]] || ! _is_ascii_printable "$rationale"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"rationale must be ASCII printable, max 512 chars"}'; return; fi

    # steps: array of strings, each ASCII printable <=512 chars, max 32 steps
    local steps_json
    steps_json=$(jq -ce '.steps' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"steps","retryable":true,"error":"Required field: steps (array of strings)"}'; return; }
    if ! jq -e 'type=="array" and length>=1 and length<=32 and all(.[]; type=="string" and length<=512)' >/dev/null 2>&1 <<< "$steps_json"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"steps must be an array of 1-32 strings, each <=512 chars"}'; return; fi
    # Charset-validate each step (reject control / non-ASCII)
    local _step
    while IFS= read -r _step; do
        if ! _is_ascii_printable "$_step"; then
            jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"each step must be ASCII printable (no control or non-ASCII bytes)"}'; return
        fi
    done < <(jq -r '.[]' <<< "$steps_json" 2>/dev/null)

    actor=$(jq -r '.actor // "agent"' <<< "$params" 2>/dev/null)
    if [[ ${#actor} -gt 256 ]] || ! _is_ascii_printable "$actor"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"actor must be ASCII printable, max 256 chars"}'; return; fi

    local out
    out=$(
        (
            flock -x 9
            local reg; reg=$(_load_registry)
            local cur_state
            cur_state=$(jq -r --arg n "$name" '.skills[$n].state // ""' <<< "$reg" 2>/dev/null)
            if [[ "$cur_state" == "active" ]]; then
                jq -cn '{"error_code":"INVALID_INPUT","retryable":false,"error":"An active skill with this name exists. Retire it first (gated) before proposing a revision — active behaviour never changes without going through the approval gate."}'
                exit 0
            fi
            local now; now=$(date +%s)
            local newreg
            newreg=$(jq -c \
                --arg n "$name" --arg tr "$trigger" --arg ra "$rationale" \
                --argjson st "$steps_json" --argjson now "$now" \
                '.skills[$n] = {"name":$n,"trigger":$tr,"steps":$st,"rationale":$ra,"state":"pending","successes":0,"failures":0,"score":0.0,"created_ts":$now,"updated_ts":$now}' \
                <<< "$reg")
            _write_registry_nolock "$newreg" || { jq -cn '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Failed to write skills registry"}'; exit 0; }
            local det; det=$(jq -cn --arg n "$name" '{"skill":$n,"state":"pending"}')
            _audit_append_nolock "skill_proposed" "$actor" "$det" || true
            jq -cn --arg n "$name" '{"skill":$n,"state":"pending","status":"ok"}'
        ) 9>"$EVOLVE_LOCK"
    ) || { jq -cn '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Failed to acquire write lock"}'; return; }

    jq -cn --argjson res "$out" --argjson rem "$rl_rem" --argjson rsa "$reset_at" --argjson lim "$rl_lim" \
        '$res + {"_rate_limit":{"remaining":$rem,"reset_at":$rsa,"limit":$lim,"window":"per_hour"}}'
}

# ── Shared gate handler for promote / retire (self-modification) ───────────
# action = "promote" | "retire"
_handle_gated_transition() {
    local params="$1" action="$2"

    local rl; rl=$(_rl_check "$action" 120 10)
    if [[ "${rl%% *}" == "RATE_LIMITED" ]]; then
        local resa="${rl#* }"; local ra=$(( resa - $(date +%s) )); [[ $ra -lt 1 ]] && ra=1
        jq -cn --argjson ra "$ra" '{"error_code":"RATE_LIMITED","retryable":true,"retry_after_seconds":$ra,"error":"Rate limit exceeded."}'; return
    fi

    local name actor hat
    name=$(jq -re '.name // empty' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"name","retryable":true,"error":"Required field: name"}'; return; }
    if ! _validate_skill_name "$name"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"name must match [a-z][a-z0-9_]*, max 64 chars"}'; return; fi
    actor=$(jq -r '.actor // "agent"' <<< "$params" 2>/dev/null)
    if [[ ${#actor} -gt 256 ]] || ! _is_ascii_printable "$actor"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"actor must be ASCII printable, max 256 chars"}'; return; fi
    hat=$(jq -r '.human_acknowledgment_token // ""' <<< "$params" 2>/dev/null)

    # Verify the skill exists and is in a valid state for the requested action.
    local reg cur_state
    reg=$(_load_registry)
    cur_state=$(jq -r --arg n "$name" '.skills[$n].state // ""' <<< "$reg" 2>/dev/null)
    if [[ -z "$cur_state" ]]; then
        jq -cn --arg n "$name" '{"error_code":"SKILL_NOT_FOUND","retryable":false,"error":("No skill named "+$n)}'; return; fi
    local target_state
    case "$action" in
        promote)
            if [[ "$cur_state" != "pending" ]]; then
                jq -cn --arg s "$cur_state" '{"error_code":"INVALID_INPUT","retryable":false,"error":("Only pending skills can be promoted; current state is "+$s)}'; return; fi
            target_state="active" ;;
        retire)
            if [[ "$cur_state" != "active" ]]; then
                jq -cn --arg s "$cur_state" '{"error_code":"INVALID_INPUT","retryable":false,"error":("Only active skills can be retired; current state is "+$s)}'; return; fi
            target_state="retired" ;;
    esac

    # ── Approval flow (token present) ──
    if [[ -n "$hat" ]]; then
        if ! [[ "$hat" =~ ^[0-9a-f]{16}$ ]]; then
            jq -cn '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Token format invalid. Re-run without token to obtain a fresh approval_nonce."}'; return; fi
        local out
        out=$(
            (
                flock -x 9
                local pending; pending=$(_approval_take_nolock "$hat")
                if [[ -z "$pending" ]]; then
                    jq -cn '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Token not recognized or already used. Re-run without token to obtain a fresh approval_nonce."}'; exit 0; fi
                local p_action p_skill p_exp
                IFS=':' read -r p_action p_skill p_exp <<< "$pending"
                local now; now=$(date +%s)
                if [[ $now -gt ${p_exp:-0} ]]; then
                    jq -cn '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Approval token expired (5-min TTL). Re-run without token to obtain a fresh approval_nonce."}'; exit 0; fi
                if [[ "$p_action" != "$action" || "$p_skill" != "$name" ]]; then
                    jq -cn '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Token does not match this action/skill. Tokens are single-use and bound to one operation."}'; exit 0; fi
                local reg2; reg2=$(_load_registry)
                local st2; st2=$(jq -r --arg n "$name" '.skills[$n].state // ""' <<< "$reg2" 2>/dev/null)
                if [[ "$st2" != "$cur_state" ]]; then
                    jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"Skill state changed concurrently; re-assess before retrying."}'; exit 0; fi
                local now2; now2=$(date +%s)
                local newreg
                newreg=$(jq -c --arg n "$name" --arg ts "$target_state" --argjson now "$now2" \
                    '.skills[$n].state=$ts | .skills[$n].updated_ts=$now' <<< "$reg2")
                _write_registry_nolock "$newreg" || { jq -cn '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Failed to write skills registry"}'; exit 0; }
                local det; det=$(jq -cn --arg n "$name" --arg from "$cur_state" --arg to "$target_state" '{"skill":$n,"from":$from,"to":$to}')
                _audit_append_nolock "skill_${action}d" "$actor" "$det" || true
                jq -cn --arg n "$name" --arg ts "$target_state" '{"skill":$n,"state":$ts,"proceed_ok":true,"decision_required":false,"status":"ok"}'
            ) 9>"$EVOLVE_LOCK"
        ) || { jq -cn '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Failed to acquire write lock"}'; return; }
        printf '%s' "$out"
        return
    fi

    # ── No token: classify as a self-modification requiring human sign-off ──
    local nonce; nonce=$(_generate_nonce 2>/dev/null) || nonce=""
    local now; now=$(date +%s)
    local expires_at=$(( now + 300 ))
    if [[ -n "$nonce" ]]; then
        (
            flock -x 9
            _approval_put_nolock "$nonce" "$action" "$name" "$expires_at" || true
        ) 9>"$EVOLVE_LOCK"
    fi
    local prompt
    prompt="Self-modification '${action} ${name}' changes the agent's active behaviour. Classified HIGH (decision_required). Obtain human sign-off, then call ${action} again with approval_nonce as human_acknowledgment_token. Token expires in 5 minutes."
    jq -cn --arg n "$name" --arg act "$action" --arg nonce "$nonce" --arg prompt "$prompt" \
        '{"skill":$n,"action":$act,"risk_tier":"HIGH","decision_required":true,"approval_nonce":(if $nonce=="" then null else $nonce end),"approval_prompt":$prompt,"status":"ok"}'
}

# ── Tool: evolve_skill_record_outcome ──────────────────────────────────────
_handle_record_outcome() {
    local params="$1"

    local rl; rl=$(_rl_check "record_outcome" 2000 50)
    if [[ "${rl%% *}" == "RATE_LIMITED" ]]; then
        local resa="${rl#* }"; local ra=$(( resa - $(date +%s) )); [[ $ra -lt 1 ]] && ra=1
        jq -cn --argjson ra "$ra" '{"error_code":"RATE_LIMITED","retryable":true,"retry_after_seconds":$ra,"error":"Rate limit exceeded."}'; return
    fi

    local name outcome actor
    name=$(jq -re '.name // empty' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"name","retryable":true,"error":"Required field: name"}'; return; }
    if ! _validate_skill_name "$name"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"name must match [a-z][a-z0-9_]*, max 64 chars"}'; return; fi
    outcome=$(jq -re '.outcome // empty' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"outcome","retryable":true,"error":"Required field: outcome (success|failure)"}'; return; }
    if [[ "$outcome" != "success" && "$outcome" != "failure" ]]; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"outcome must be exactly success or failure"}'; return; fi
    actor=$(jq -r '.actor // "agent"' <<< "$params" 2>/dev/null)
    if [[ ${#actor} -gt 256 ]] || ! _is_ascii_printable "$actor"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"actor must be ASCII printable, max 256 chars"}'; return; fi

    local out
    out=$(
        (
            flock -x 9
            local reg; reg=$(_load_registry)
            local exists; exists=$(jq -r --arg n "$name" 'if (.skills[$n]) then "y" else "n" end' <<< "$reg" 2>/dev/null)
            if [[ "$exists" != "y" ]]; then
                jq -cn --arg n "$name" '{"error_code":"SKILL_NOT_FOUND","retryable":false,"error":("No skill named "+$n)}'; exit 0; fi
            local s f
            s=$(jq -r --arg n "$name" '.skills[$n].successes // 0' <<< "$reg")
            f=$(jq -r --arg n "$name" '.skills[$n].failures // 0' <<< "$reg")
            if [[ "$outcome" == "success" ]]; then s=$(( s + 1 )); else f=$(( f + 1 )); fi
            local score; score=$(_wilson_score "$s" "$f")
            local now; now=$(date +%s)
            local newreg
            newreg=$(jq -c --arg n "$name" --argjson s "$s" --argjson f "$f" --argjson sc "$score" --argjson now "$now" \
                '.skills[$n].successes=$s | .skills[$n].failures=$f | .skills[$n].score=$sc | .skills[$n].updated_ts=$now' <<< "$reg")
            _write_registry_nolock "$newreg" || { jq -cn '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Failed to write skills registry"}'; exit 0; }
            local det; det=$(jq -cn --arg n "$name" --arg o "$outcome" --argjson sc "$score" '{"skill":$n,"outcome":$o,"score":$sc}')
            _audit_append_nolock "skill_outcome_recorded" "$actor" "$det" || true
            jq -cn --arg n "$name" --argjson s "$s" --argjson f "$f" --argjson sc "$score" \
                '{"skill":$n,"successes":$s,"failures":$f,"score":$sc,"status":"ok"}'
        ) 9>"$EVOLVE_LOCK"
    ) || { jq -cn '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Failed to acquire write lock"}'; return; }
    printf '%s' "$out"
}

# ── Tool: evolve_skill_list ─────────────────────────────────────────────────
_handle_list() {
    local params="$1"
    local state_filter
    state_filter=$(jq -r '.state // ""' <<< "$params" 2>/dev/null)
    if [[ -n "$state_filter" && "$state_filter" != "pending" && "$state_filter" != "active" && "$state_filter" != "retired" ]]; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"state filter must be one of pending, active, retired"}'; return; fi
    local reg; reg=$(_load_registry)
    if [[ -n "$state_filter" ]]; then
        jq -c --arg st "$state_filter" '[.skills[] | select(.state==$st)] | {"skills":., "count":length, "status":"ok"}' <<< "$reg"
    else
        jq -c '[.skills[]] | {"skills":., "count":length, "status":"ok"}' <<< "$reg"
    fi
}

# ── Tool: evolve_skill_recommend ───────────────────────────────────────────
# Pure-compute selection: rank ACTIVE skills by confidence score (desc), then
# successes (desc), then name (asc). Mirrors spec/skill_rank.0. Read-only, SAFE.
_handle_recommend() {
    local params="$1"
    local trigger
    trigger=$(jq -r '.trigger // ""' <<< "$params" 2>/dev/null)
    if [[ ${#trigger} -gt 256 ]] || ! _is_ascii_printable "$trigger"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"trigger must be ASCII printable, max 256 chars"}'; return; fi
    local reg; reg=$(_load_registry)
    # Sort active skills by (score desc, successes desc, name asc).
    jq -c '
        [ .skills[] | select(.state=="active") ]
        | sort_by([ (-.score), (-(.successes)), .name ])
        | { "skills": ., "top": (if length>0 then .[0].name else null end), "count": length, "status": "ok" }
    ' <<< "$reg"
}

# ── Tool: evolve_skill_get ──────────────────────────────────────────────────
_handle_get() {
    local params="$1"
    local name
    name=$(jq -re '.name // empty' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"name","retryable":true,"error":"Required field: name"}'; return; }
    if ! _validate_skill_name "$name"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"name must match [a-z][a-z0-9_]*, max 64 chars"}'; return; fi
    local reg; reg=$(_load_registry)
    local found; found=$(jq -c --arg n "$name" '.skills[$n] // empty' <<< "$reg" 2>/dev/null)
    if [[ -z "$found" ]]; then
        jq -cn --arg n "$name" '{"error_code":"SKILL_NOT_FOUND","retryable":false,"error":("No skill named "+$n)}'; return; fi
    jq -cn --argjson sk "$found" '{"skill":$sk,"status":"ok"}'
}

# ── Tool: evolve_memory_note ────────────────────────────────────────────────
# Persistent learning notes ("a model of who you are"). Notes are DATA, never
# auto-acted-upon. Stored only in the tamper-evident change log.
_handle_memory_note() {
    local params="$1"

    local rl; rl=$(_rl_check "memory_note" 1000 30)
    if [[ "${rl%% *}" == "RATE_LIMITED" ]]; then
        local resa="${rl#* }"; local ra=$(( resa - $(date +%s) )); [[ $ra -lt 1 ]] && ra=1
        jq -cn --argjson ra "$ra" '{"error_code":"RATE_LIMITED","retryable":true,"retry_after_seconds":$ra,"error":"Rate limit exceeded."}'; return
    fi

    local note actor topic
    note=$(jq -re '.note // empty' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"note","retryable":true,"error":"Required field: note"}'; return; }
    if [[ ${#note} -gt 1024 ]] || ! _is_ascii_printable "$note"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"note must be ASCII printable, max 1024 chars"}'; return; fi
    topic=$(jq -r '.topic // "general"' <<< "$params" 2>/dev/null)
    if [[ ${#topic} -gt 64 ]] || ! [[ "$topic" =~ ^[a-z][a-z0-9_]*$ ]]; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"topic must match [a-z][a-z0-9_]*, max 64 chars"}'; return; fi
    actor=$(jq -r '.actor // "agent"' <<< "$params" 2>/dev/null)
    if [[ ${#actor} -gt 256 ]] || ! _is_ascii_printable "$actor"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"actor must be ASCII printable, max 256 chars"}'; return; fi

    local out
    out=$(
        (
            flock -x 9
            local det; det=$(jq -cn --arg t "$topic" --arg n "$note" '{"topic":$t,"note":$n}')
            _audit_append_nolock "memory_note" "$actor" "$det" || { jq -cn '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Failed to append note"}'; exit 0; }
            jq -cn --arg t "$topic" '{"topic":$t,"recorded":true,"status":"ok"}'
        ) 9>"$EVOLVE_LOCK"
    ) || { jq -cn '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Failed to acquire write lock"}'; return; }
    printf '%s' "$out"
}

# ── Tool: evolve_history (read-only; returns change log + chain validity) ───
_handle_history() {
    local params="$1"
    local limit
    limit=$(jq -r '.limit // 50' <<< "$params" 2>/dev/null)
    if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"limit must be a non-negative integer"}'; return; fi
    [[ $limit -gt 500 ]] && limit=500
    [[ $limit -lt 1 ]] && limit=1

    if [[ ! -f "$EVOLVE_AUDIT" ]]; then
        jq -cn '{"entries":[],"count":0,"valid":true,"status":"ok"}'; return; fi

    # Verify the chain and collect entries.
    local prev_hash="GENESIS" entry_count=0 broken=false broken_at=0
    local -a lines=()
    while IFS= read -r el; do
        [[ -z "$el" ]] && continue
        lines+=("$el")
        entry_count=$(( entry_count + 1 ))
        if [[ "$broken" == "false" ]]; then
            if ! jq -e . >/dev/null 2>&1 <<< "$el"; then broken=true; broken_at="$entry_count"; continue; fi
            local stored pre exp
            stored=$(jq -r '.chain_hash // ""' <<< "$el" 2>/dev/null)
            pre=$(jq -c 'del(.chain_hash)' <<< "$el" 2>/dev/null) || { broken=true; broken_at="$entry_count"; continue; }
            exp=$(_chain_hash "$prev_hash" "$pre")
            if [[ "$stored" != "$exp" ]]; then broken=true; broken_at="$entry_count"; continue; fi
            prev_hash="$stored"
        fi
    done < "$EVOLVE_AUDIT"

    # Newest-first, limited.
    local entries="[]" collected=0 i=$(( entry_count - 1 ))
    while [[ $i -ge 0 && $collected -lt $limit ]]; do
        local el="${lines[$i]}"
        if jq -e . >/dev/null 2>&1 <<< "$el"; then
            entries=$(jq -cn --argjson arr "$entries" --argjson e "$el" '$arr + [$e]')
            collected=$(( collected + 1 ))
        fi
        i=$(( i - 1 ))
    done

    if [[ "$broken" == "true" ]]; then
        jq -cn --argjson e "$entries" --argjson c "$collected" --argjson ba "$broken_at" \
            '{"entries":$e,"count":$c,"valid":false,"broken_at_entry":$ba,"status":"ok"}'
    else
        jq -cn --argjson e "$entries" --argjson c "$collected" --argjson tc "$entry_count" \
            '{"entries":$e,"count":$c,"total_count":$tc,"valid":true,"status":"ok"}'
    fi
}

# ── Main MCP session loop ─────────────────────────────────────────────────
INITIALIZED=false

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue

    if [[ ${#line} -gt $MAX_MSG ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Message exceeds 1 MiB limit"}}\n'
        continue
    fi
    if ! jq -e . >/dev/null 2>&1 <<< "$line"; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: invalid JSON"}}\n'
        continue
    fi
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$line"; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request: must be a JSON object"}}\n'
        continue
    fi

    req_id=$(jq -c '.id // null' <<< "$line")
    method=$(jq -r '.method // ""' <<< "$line")

    case "$method" in
        initialize)
            if [[ "$INITIALIZED" == "true" ]]; then
                _send_error "$req_id" -32003 "Already initialized"
                continue
            fi
            INITIALIZED=true
            jq -cn '{"jsonrpc":"2.0","id":null,"method":"notifications/initialized","params":{}}'
            jq -cn --argjson id "$req_id" --arg proto "$MCP_PROTOCOL" --arg ver "$EVOLVE_VERSION" \
                '{"jsonrpc":"2.0","id":$id,"result":{"protocolVersion":$proto,"capabilities":{"tools":{}},"serverInfo":{"name":"evolve","version":$ver}}}'
            ;;

        tools/list)
            MANIFEST="${SCRIPT_DIR}/mcp-manifest.json"
            if [[ -f "$MANIFEST" ]]; then
                tools_json=$(jq -c '.tools' "$MANIFEST" 2>/dev/null || printf '[]')
            else
                tools_json="[]"
            fi
            jq -cn --argjson id "$req_id" --argjson tools "$tools_json" \
                '{"jsonrpc":"2.0","id":$id,"result":{"tools":$tools}}'
            ;;

        tools/call)
            tool_name=$(jq -r '.params.name // ""' <<< "$line")
            params=$(jq -c '.params.arguments // {}' <<< "$line")

            case "$tool_name" in
                evolve_skill_propose)        tool_result=$(_handle_propose "$params") ;;
                evolve_skill_promote)        tool_result=$(_handle_gated_transition "$params" "promote") ;;
                evolve_skill_retire)         tool_result=$(_handle_gated_transition "$params" "retire") ;;
                evolve_skill_record_outcome) tool_result=$(_handle_record_outcome "$params") ;;
                evolve_skill_list)           tool_result=$(_handle_list "$params") ;;
                evolve_skill_recommend)      tool_result=$(_handle_recommend "$params") ;;
                evolve_skill_get)            tool_result=$(_handle_get "$params") ;;
                evolve_memory_note)          tool_result=$(_handle_memory_note "$params") ;;
                evolve_history)              tool_result=$(_handle_history "$params") ;;
                *)
                    tool_result=$(jq -cn '{"error_code":"UNKNOWN_TOOL","retryable":false,"error":"Unknown tool. Use evolve_skill_propose, evolve_skill_promote, evolve_skill_retire, evolve_skill_record_outcome, evolve_skill_list, evolve_skill_recommend, evolve_skill_get, evolve_memory_note, or evolve_history."}')
                    ;;
            esac

            is_error=false
            if jq -e 'has("error_code")' >/dev/null 2>&1 <<< "$tool_result"; then is_error=true; fi
            jq -cn --argjson id "$req_id" --argjson res "$tool_result" --argjson ie "$is_error" \
                '{"jsonrpc":"2.0","id":$id,"result":{"content":[{"type":"text","text":($res|tostring)}],"isError":$ie}}'
            ;;

        ping)
            jq -cn --argjson id "$req_id" '{"jsonrpc":"2.0","id":$id,"result":{}}'
            ;;

        notifications/*)
            ;;

        *)
            _send_error "$req_id" -32601 "Method not found: ${method}"
            ;;
    esac
done
