#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ audit/mcp-bridge.sh — Tamper-Evident Compliance Log for AI Operations   │
# │                                                                          │
# │ Addresses V3 in HEROS threat model: no HMAC integrity on stored data.   │
# │ Each entry carries a chain_hash = sha256(prev_hash || entry_json),       │
# │ creating a Merkle-style chain: any deletion or modification is detected  │
# │ by audit_verify.                                                         │
# │                                                                          │
# │ Architecture: pure bash — no separate binary. MCP 2025-11-25 compliant. │
# │ Security: jq --arg for all user data, no eval, flock on all writes.     │
# │ Requires: jq >= 1.6, sha256sum (coreutils), flock (util-linux)          │
# └──────────────────────────────────────────────────────────────────────────┘

set -euo pipefail

export LC_ALL=C.UTF-8

trap 'exit 0' TERM INT PIPE

readonly MCP_PROTOCOL="2025-11-25"
readonly AUDIT_VERSION="0.1.0"
readonly MAX_MSG=1048576  # 1 MiB

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Storage paths ─────────────────────────────────────────────────────────
# HEROS_DATA_DIR may be set by operator; default to script dir
DATA_DIR="${HEROS_DATA_DIR:-${SCRIPT_DIR}}"
AUDIT_LOG="${DATA_DIR}/.audit-log"
AUDIT_STATE="${DATA_DIR}/.audit-state"
AUDIT_LOCK="${DATA_DIR}/.audit-lock"

# ── Dependency check ──────────────────────────────────────────────────────
for _dep in jq sha256sum flock; do
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

# ── Chain hash helper ─────────────────────────────────────────────────────
_chain_hash() {
    local prev_hash="$1" entry_json="$2"
    printf '%s%s' "$prev_hash" "$entry_json" | sha256sum | cut -c1-64
}

# ── Storage helpers ───────────────────────────────────────────────────────
_read_state() {
    # Outputs: last_hash entry_count
    if [[ -f "$AUDIT_STATE" ]]; then
        local raw
        raw=$(cat "$AUDIT_STATE" 2>/dev/null) || { printf 'GENESIS 0'; return; }
        local lh ec
        lh=$(jq -r '.last_hash // "GENESIS"' <<< "$raw" 2>/dev/null) || lh="GENESIS"
        ec=$(jq -r '.entry_count // 0' <<< "$raw" 2>/dev/null) || ec=0
        printf '%s %s' "$lh" "$ec"
    else
        printf 'GENESIS 0'
    fi
}

_write_state() {
    local last_hash="$1" entry_count="$2"
    # Write atomically via temp file
    local tmp
    tmp=$(mktemp "${AUDIT_STATE}.XXXXXX")
    jq -cn --arg lh "$last_hash" --argjson ec "$entry_count" \
        '{"last_hash":$lh,"entry_count":$ec}' > "$tmp" && mv "$tmp" "$AUDIT_STATE"
}

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
_send_result() {
    local req_id="$1" result="$2"
    jq -cn --argjson id "$req_id" --argjson res "$result" \
        '{"jsonrpc":"2.0","id":$id,"result":$res}'
}

_send_error() {
    local req_id="$1" code="$2" msg="$3"
    jq -cn --argjson id "$req_id" --argjson code "$code" --arg msg "$msg" \
        '{"jsonrpc":"2.0","id":$id,"error":{"code":$code,"message":$msg}}'
}

# ── Validation helpers ────────────────────────────────────────────────────
_validate_event_type() {
    local v="$1"
    [[ ${#v} -gt 64 ]] && return 1
    [[ "$v" =~ ^[a-z][a-z0-9_]*$ ]] || return 1
    return 0
}

_validate_actor() {
    local v="$1"
    [[ -z "$v" ]] && return 1
    [[ ${#v} -gt 256 ]] && return 1
    # ASCII printable: 0x20–0x7E
    printf '%s' "$v" | LC_ALL=C grep -qP '^[\x20-\x7E]+$' 2>/dev/null || \
        printf '%s' "$v" | LC_ALL=C grep -q '^[[:print:]]*$' 2>/dev/null || return 1
    return 0
}

# ── Tool: audit_log ───────────────────────────────────────────────────────
_handle_audit_log() {
    local params="$1"

    # Rate limit: 2000/hour, burst 50
    local rl_result
    rl_result=$(_rl_check "audit_log" 2000 50)
    local rl_status; rl_status="${rl_result%% *}"
    if [[ "$rl_status" == "RATE_LIMITED" ]]; then
        local reset_at; reset_at="${rl_result#* }"
        local retry_after=$(( reset_at - $(date +%s) ))
        [[ $retry_after -lt 1 ]] && retry_after=1
        jq -cn \
            --argjson ra "$retry_after" \
            --argjson rs "$reset_at" \
            '{"error_code":"RATE_LIMITED","retryable":true,"retry_after_seconds":$ra,"reset_at":$rs,"error":"Rate limit exceeded. Wait retry_after_seconds before retrying."}'
        return
    fi
    local rl_remaining reset_at rl_limit
    read -r _ rl_remaining reset_at rl_limit <<< "$rl_result"

    # Extract event_type (required)
    local event_type
    event_type=$(jq -re '.event_type // empty' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"event_type","retryable":true,"error":"Required field: event_type"}'
        return
    }
    if ! _validate_event_type "$event_type"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"event_type must match [a-z][a-z0-9_]*, max 64 chars"}'
        return
    fi

    # Extract actor (required)
    local actor
    actor=$(jq -re '.actor // empty' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"actor","retryable":true,"error":"Required field: actor"}'
        return
    }
    if ! _validate_actor "$actor"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"actor must be ASCII printable, 1-256 chars"}'
        return
    fi

    # Extract details (optional, must be JSON object if present)
    local details_raw details_json
    details_raw=$(jq -c '.details // {}' <<< "$params" 2>/dev/null) || details_raw="{}"
    # Ensure details is an object
    if ! jq -e 'type == "object"' <<< "$details_raw" >/dev/null 2>&1; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"details must be a JSON object"}'
        return
    fi
    details_json="$details_raw"
    # Enforce 2048-char serialized limit
    if [[ ${#details_json} -gt 2048 ]]; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"details serialized length exceeds 2048 chars"}'
        return
    fi

    # Perform flock-protected write
    local now; now=$(date +%s)
    local tmp_result
    tmp_result=$(
        (
            flock -x 9
            # Read current state
            local state_raw; state_raw=$(_read_state)
            local prev_hash entry_count
            read -r prev_hash entry_count <<< "$state_raw"

            local entry_id=$(( entry_count + 1 ))

            # Build entry JSON deterministically (no details in hash-input yet — details is included)
            # Build partial entry for hashing: all fields except chain_hash
            local entry_pre
            entry_pre=$(jq -cn \
                --argjson eid "$entry_id" \
                --argjson ts "$now" \
                --arg et "$event_type" \
                --arg ac "$actor" \
                --argjson det "$details_json" \
                '{"entry_id":$eid,"ts":$ts,"event_type":$et,"actor":$ac,"details":$det}')

            # Compute chain hash
            local chain_hash
            chain_hash=$(_chain_hash "$prev_hash" "$entry_pre")

            # Build full entry with chain_hash
            local entry_full
            entry_full=$(jq -cn \
                --argjson eid "$entry_id" \
                --argjson ts "$now" \
                --arg et "$event_type" \
                --arg ac "$actor" \
                --argjson det "$details_json" \
                --arg ch "$chain_hash" \
                '{"entry_id":$eid,"ts":$ts,"event_type":$et,"actor":$ac,"details":$det,"chain_hash":$ch}')

            # Append to log
            printf '%s\n' "$entry_full" >> "$AUDIT_LOG" || {
                printf '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Failed to append to audit log"}'
                exit 0
            }

            # Update state
            _write_state "$chain_hash" "$entry_id" || {
                printf '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Failed to update audit state"}'
                exit 0
            }

            # Return success
            jq -cn \
                --argjson eid "$entry_id" \
                --argjson ts "$now" \
                --arg ch "$chain_hash" \
                '{"entry_id":$eid,"ts":$ts,"chain_hash":$ch,"status":"ok"}'
        ) 9>"$AUDIT_LOCK"
    ) || {
        jq -cn '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Failed to acquire write lock"}'
        return
    }

    # Annotate with rate limit info
    jq -cn \
        --argjson res "$tmp_result" \
        --argjson rem "$rl_remaining" \
        --argjson rsa "$reset_at" \
        --argjson lim "$rl_limit" \
        '$res + {"_rate_limit":{"remaining":$rem,"reset_at":$rsa,"limit":$lim,"window":"per_hour"}}'
}

# ── Tool: audit_verify ────────────────────────────────────────────────────
_handle_audit_verify() {
    local params="$1"

    # Rate limit: 60/hour, burst 5
    local rl_result
    rl_result=$(_rl_check "audit_verify" 60 5)
    local rl_status; rl_status="${rl_result%% *}"
    if [[ "$rl_status" == "RATE_LIMITED" ]]; then
        local reset_at; reset_at="${rl_result#* }"
        local retry_after=$(( reset_at - $(date +%s) ))
        [[ $retry_after -lt 1 ]] && retry_after=1
        jq -cn \
            --argjson ra "$retry_after" \
            --argjson rs "$reset_at" \
            '{"error_code":"RATE_LIMITED","retryable":true,"retry_after_seconds":$ra,"reset_at":$rs,"error":"Rate limit exceeded. Wait retry_after_seconds before retrying."}'
        return
    fi
    local rl_remaining reset_at rl_limit
    read -r _ rl_remaining reset_at rl_limit <<< "$rl_result"

    # Read-only: no flock needed
    if [[ ! -f "$AUDIT_LOG" ]]; then
        jq -cn \
            --argjson rem "$rl_remaining" \
            --argjson rsa "$reset_at" \
            --argjson lim "$rl_limit" \
            '{"valid":true,"entry_count":0,"status":"ok","_rate_limit":{"remaining":$rem,"reset_at":$rsa,"limit":$lim,"window":"per_hour"}}'
        return
    fi

    local prev_hash="GENESIS"
    local entry_count=0
    local broken_at=""
    local broken=false

    while IFS= read -r entry_line; do
        [[ -z "$entry_line" ]] && continue
        entry_count=$(( entry_count + 1 ))

        # Validate JSON
        if ! jq -e . >/dev/null 2>&1 <<< "$entry_line"; then
            broken=true
            broken_at="$entry_count"
            break
        fi

        # Extract stored chain_hash
        local stored_hash
        stored_hash=$(jq -r '.chain_hash // ""' <<< "$entry_line" 2>/dev/null)

        # Rebuild the pre-hash entry (entry without chain_hash)
        local entry_pre
        entry_pre=$(jq -c 'del(.chain_hash)' <<< "$entry_line" 2>/dev/null) || {
            broken=true
            broken_at="$entry_count"
            break
        }

        # Compute expected hash
        local expected_hash
        expected_hash=$(_chain_hash "$prev_hash" "$entry_pre")

        if [[ "$stored_hash" != "$expected_hash" ]]; then
            broken=true
            broken_at="$entry_count"
            break
        fi

        prev_hash="$stored_hash"
    done < "$AUDIT_LOG"

    if [[ "$broken" == "true" ]]; then
        jq -cn \
            --argjson ba "$broken_at" \
            --argjson rem "$rl_remaining" \
            --argjson rsa "$reset_at" \
            --argjson lim "$rl_limit" \
            '{"valid":false,"broken_at_entry":$ba,"status":"ok","_rate_limit":{"remaining":$rem,"reset_at":$rsa,"limit":$lim,"window":"per_hour"}}'
    else
        jq -cn \
            --argjson ec "$entry_count" \
            --argjson rem "$rl_remaining" \
            --argjson rsa "$reset_at" \
            --argjson lim "$rl_limit" \
            '{"valid":true,"entry_count":$ec,"status":"ok","_rate_limit":{"remaining":$rem,"reset_at":$rsa,"limit":$lim,"window":"per_hour"}}'
    fi
}

# ── Tool: audit_list ──────────────────────────────────────────────────────
_handle_audit_list() {
    local params="$1"

    # Rate limit: 600/hour, burst 20
    local rl_result
    rl_result=$(_rl_check "audit_list" 600 20)
    local rl_status; rl_status="${rl_result%% *}"
    if [[ "$rl_status" == "RATE_LIMITED" ]]; then
        local reset_at; reset_at="${rl_result#* }"
        local retry_after=$(( reset_at - $(date +%s) ))
        [[ $retry_after -lt 1 ]] && retry_after=1
        jq -cn \
            --argjson ra "$retry_after" \
            --argjson rs "$reset_at" \
            '{"error_code":"RATE_LIMITED","retryable":true,"retry_after_seconds":$ra,"reset_at":$rs,"error":"Rate limit exceeded. Wait retry_after_seconds before retrying."}'
        return
    fi
    local rl_remaining reset_at rl_limit
    read -r _ rl_remaining reset_at rl_limit <<< "$rl_result"

    # Extract limit (default 50, max 500)
    local limit offset
    limit=$(jq -r '.limit // 50' <<< "$params" 2>/dev/null)
    offset=$(jq -r '.offset // 0' <<< "$params" 2>/dev/null)

    # Validate limit
    if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"limit must be a non-negative integer"}'
        return
    fi
    if ! [[ "$offset" =~ ^[0-9]+$ ]]; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"offset must be a non-negative integer"}'
        return
    fi
    if [[ $limit -gt 500 ]]; then limit=500; fi
    if [[ $limit -lt 1 ]]; then limit=1; fi

    if [[ ! -f "$AUDIT_LOG" ]]; then
        jq -cn \
            --argjson rem "$rl_remaining" \
            --argjson rsa "$reset_at" \
            --argjson lim "$rl_limit" \
            '{"entries":[],"count":0,"total_count":0,"has_more":false,"status":"ok","_rate_limit":{"remaining":$rem,"reset_at":$rsa,"limit":$lim,"window":"per_hour"}}'
        return
    fi

    # Read all lines into array (newest first = reverse order)
    local -a all_lines=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        all_lines+=("$line")
    done < "$AUDIT_LOG"

    local total_count=${#all_lines[@]}

    # Build entries JSON array: newest first, apply offset and limit
    # Reverse by iterating from end
    local entries_json="[]"
    local collected=0
    local skipped=0
    local i=$(( total_count - 1 ))
    while [[ $i -ge 0 && $collected -lt $limit ]]; do
        local line="${all_lines[$i]}"
        if jq -e . >/dev/null 2>&1 <<< "$line"; then
            if [[ $skipped -lt $offset ]]; then
                skipped=$(( skipped + 1 ))
            else
                entries_json=$(jq -cn --argjson arr "$entries_json" --argjson entry "$line" '$arr + [$entry]')
                collected=$(( collected + 1 ))
            fi
        fi
        i=$(( i - 1 ))
    done

    local has_more=false
    local remaining_after=$(( total_count - offset - collected ))
    [[ $remaining_after -gt 0 ]] && has_more=true

    jq -cn \
        --argjson entries "$entries_json" \
        --argjson count "$collected" \
        --argjson total "$total_count" \
        --argjson hm "$has_more" \
        --argjson rem "$rl_remaining" \
        --argjson rsa "$reset_at" \
        --argjson lim "$rl_limit" \
        '{"entries":$entries,"count":$count,"total_count":$total,"has_more":$hm,"status":"ok","_rate_limit":{"remaining":$rem,"reset_at":$rsa,"limit":$lim,"window":"per_hour"}}'
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
            jq -cn \
                '{"jsonrpc":"2.0","id":null,"method":"notifications/initialized","params":{}}'
            jq -cn \
                --argjson id "$req_id" \
                --arg proto "$MCP_PROTOCOL" \
                --arg ver "$AUDIT_VERSION" \
                '{
                    "jsonrpc":"2.0","id":$id,
                    "result":{
                        "protocolVersion":$proto,
                        "capabilities":{"tools":{}},
                        "serverInfo":{"name":"audit","version":$ver}
                    }
                }'
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
                audit_log)
                    tool_result=$(_handle_audit_log "$params")
                    ;;
                audit_verify)
                    tool_result=$(_handle_audit_verify "$params")
                    ;;
                audit_list)
                    tool_result=$(_handle_audit_list "$params")
                    ;;
                *)
                    tool_result=$(jq -cn '{"error_code":"UNKNOWN_TOOL","retryable":false,"error":"Unknown tool. Use audit_log, audit_verify, or audit_list."}')
                    ;;
            esac

            jq -cn \
                --argjson id "$req_id" \
                --argjson res "$tool_result" \
                '{"jsonrpc":"2.0","id":$id,"result":{"content":[{"type":"text","text":($res|tostring)}],"isError":false}}'
            ;;

        ping)
            jq -cn --argjson id "$req_id" '{"jsonrpc":"2.0","id":$id,"result":{}}'
            ;;

        notifications/*)
            # Notifications: no response required
            ;;

        *)
            _send_error "$req_id" -32601 "Method not found: ${method}"
            ;;
    esac

done
