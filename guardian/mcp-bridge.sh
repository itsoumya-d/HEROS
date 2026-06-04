#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ guardian/mcp-bridge.sh — Universal Agent Operation Safety Oracle         │
# │                                                                          │
# │ guardian extends forge's pre-execution risk gate beyond databases to     │
# │ ALL agent operations: file system, shell commands, network requests,     │
# │ infrastructure changes, code execution, and data access.                 │
# │                                                                          │
# │ Architecture: pure bash — no separate binary required. Risk assessment   │
# │ logic lives in this bridge via embedded rulesets. Follows the same       │
# │ security model as forge/mcp-bridge.sh: jq --arg for all user data,      │
# │ no eval, no string concatenation, HMAC auth optional.                   │
# │                                                                          │
# │ Requires: jq >= 1.6                                                     │
# └──────────────────────────────────────────────────────────────────────────┘

set -euo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

trap 'exit 0' TERM INT PIPE

readonly MCP_PROTOCOL="2025-11-25"
readonly GUARDIAN_VERSION="0.1.0"
readonly MAX_MSG=1048576

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Dependency check ──────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"jq >= 1.6 required but not found in PATH"}}\n'
    exit 1
fi

# ── Rate limit state (token bucket, in-memory) ────────────────────────────
declare -A _RL_BUCKETS    # key → tokens
declare -A _RL_LAST       # key → last_epoch
readonly RL_LIMIT_ASSESS=300      # per hour
readonly RL_BURST_ASSESS=15
readonly RL_WINDOW=3600

_rl_check() {
    local key="$1" limit="$2" burst="$3"
    local now; now=$(date +%s 2>/dev/null || echo "0")
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
        echo "RATE_LIMITED $reset_at"
        return
    fi
    tokens=$(( tokens - 1 ))
    _RL_BUCKETS[$key]="$tokens"
    local reset_at=$(( now + RL_WINDOW ))
    echo "OK $tokens $reset_at $limit"
}

# ── Approval nonce state (decision_required flow) ─────────────────────────
declare -A _PENDING_APPROVALS  # nonce → "op_hash:expires_at"

_generate_nonce() {
    dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

_nonce_hash() {
    # sha256 of operation content, first 16 hex chars
    printf '%s' "$1" | sha256sum | cut -c1-16
}

# ── Risk assessment engine ────────────────────────────────────────────────
# Returns: "RISK_TIER RISK_SCORE HAS_SIDE_EFFECTS REVERSIBLE DECISION_REQUIRED GUIDANCE"
# All space-separated. Guidance may contain spaces — use only first 5 fields positionally.

_assess_file_system() {
    local op="$1"
    local action; action=$(jq -r '.action // "unknown"' <<< "$op" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local path; path=$(jq -r '.path // ""' <<< "$op" 2>/dev/null)
    local recursive; recursive=$(jq -r '.recursive // false' <<< "$op" 2>/dev/null)

    case "$action" in
        read_file|read|cat|head|tail|list_dir|ls|stat|find)
            echo "SAFE 0.0 false true false Read-only file system operation. No data modified."
            ;;
        write_file|write|create_file|touch|mkdir)
            echo "NOTABLE 0.25 true true false Creates a new file or directory. Reversible by deleting the created path."
            ;;
        write_file_overwrite|overwrite|truncate)
            echo "MEDIUM 0.5 true false false Overwrites existing file content. Original data is lost unless backed up."
            ;;
        rename|move|mv)
            echo "NOTABLE 0.25 true true false Renames or moves a file. Reverse by moving back to original location."
            ;;
        chmod|chown|chgrp)
            echo "MEDIUM 0.5 true true false Changes file permissions or ownership. May affect other processes accessing this file."
            ;;
        delete_dir|rmdir)
            if [[ "$recursive" == "true" ]]; then
                echo "CRITICAL 1.0 true false true Recursive directory delete destroys all files in the target tree. Data loss is permanent and unrecoverable without backup."
            else
                echo "MEDIUM 0.5 true true false Deletes an empty directory. Verify the directory is truly empty before proceeding."
            fi
            ;;
        delete_file|delete|rm|unlink)
            if [[ "$recursive" == "true" || "$action" == "rmdir_recursive" ]]; then
                echo "CRITICAL 1.0 true false true Recursive delete destroys all files in the target tree. Data loss is permanent and unrecoverable without backup."
            else
                # Check for critical paths
                case "$path" in
                    /etc/*|/bin/*|/usr/*|/lib/*|/boot/*)
                        echo "CRITICAL 1.0 true false true Deleting a system file can break OS functionality. Irreversible without reinstall."
                        ;;
                    *.log|/tmp/*|/var/tmp/*)
                        echo "NOTABLE 0.25 true true false Deleting a temporary or log file. Generally safe."
                        ;;
                    *)
                        echo "HIGH 0.75 true false true Permanently deletes a file. Unrecoverable without backup."
                        ;;
                esac
            fi
            ;;
        symlink|ln)
            echo "NOTABLE 0.25 true true false Creates a symbolic link. Can be removed."
            ;;
        *)
            echo "MEDIUM 0.5 true false false Unknown file system operation. Assess manually before proceeding."
            ;;
    esac
}

_assess_shell_command() {
    local op="$1"
    local command; command=$(jq -r '.command // ""' <<< "$op" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local args_str; args_str=$(jq -r '(.args // []) | join(" ")' <<< "$op" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local full_cmd="${command} ${args_str}"

    # Destructive patterns — highest priority check
    if echo "$full_cmd" | grep -qE '(rm\s+-rf|rm\s+-fr|dd\s+if|mkfs|wipefs|shred|format|fdisk|parted)'; then
        echo "CRITICAL 1.0 true false true Command pattern matches known destructive operations (rm -rf / dd / mkfs). Permanent data loss likely."
        return
    fi

    # Service/process control
    if echo "$full_cmd" | grep -qE '(systemctl|service|init|reboot|halt|shutdown|kill\s+-9|pkill|killall)'; then
        echo "HIGH 0.75 true true true Affects running services or processes. May interrupt production workloads."
        return
    fi

    # Package management
    if echo "$full_cmd" | grep -qE '(apt\s+(install|remove|purge)|yum\s+(install|remove)|pip\s+install|npm\s+install|brew\s+install)'; then
        echo "MEDIUM 0.5 true true false Installs or modifies system packages. Review package names for security."
        return
    fi

    # Network configuration
    if echo "$full_cmd" | grep -qE '(iptables|ufw|firewall|ip\s+route|ip\s+link|ifconfig|netplan)'; then
        echo "HIGH 0.75 true false true Modifies network configuration. May disrupt connectivity."
        return
    fi

    # Permission changes
    if echo "$full_cmd" | grep -qE '(chmod|chown|chgrp|setuid|setgid|sudo|su\s)'; then
        echo "MEDIUM 0.5 true true false Changes permissions or executes with elevated privileges."
        return
    fi

    # Read-only commands
    if echo "$command" | grep -qE '^(cat|ls|find|grep|head|tail|less|more|wc|stat|file|diff|ps|top|df|du|env|printenv|echo|pwd|whoami|id|date|uptime)$'; then
        echo "SAFE 0.0 false true false Read-only command. Inspects state without modification."
        return
    fi

    # File creation commands
    if echo "$command" | grep -qE '^(touch|mkdir|cp|mv|ln)$'; then
        echo "NOTABLE 0.25 true true false Creates or moves files. Reversible."
        return
    fi

    # Default: unknown command
    echo "MEDIUM 0.5 true false false Unrecognized shell command. Review manually before executing in production."
}

_assess_network_request() {
    local op="$1"
    local method; method=$(jq -r '.method // "GET"' <<< "$op" 2>/dev/null | tr '[:lower:]' '[:upper:]')
    local url; url=$(jq -r '.url // ""' <<< "$op" 2>/dev/null); : "$url"
    local has_pii; has_pii=$(jq -r '.contains_pii // false' <<< "$op" 2>/dev/null)
    local financial; financial=$(jq -r '.financial // false' <<< "$op" 2>/dev/null)
    local batch_size; batch_size=$(jq -r '.batch_size // 1 | tonumber' <<< "$op" 2>/dev/null || echo "1")

    case "$method" in
        GET|HEAD|OPTIONS)
            echo "SAFE 0.0 false true false Read-only HTTP method. No server state modified."
            ;;
        POST)
            if [[ "$financial" == "true" ]]; then
                echo "HIGH 0.75 true false true POST with financial data. Triggers a financial transaction or record creation."
            elif [[ "$has_pii" == "true" ]]; then
                echo "MEDIUM 0.5 true false false POST with PII. Ensure data handling complies with privacy policy."
            elif [[ "$batch_size" -gt 100 ]]; then
                echo "HIGH 0.75 true false true Batch POST of more than 100 records. High volume mutation. Verify idempotency."
            else
                echo "NOTABLE 0.25 true false false POST creates a new resource. Generally reversible via DELETE."
            fi
            ;;
        PUT|PATCH)
            if [[ "$financial" == "true" ]]; then
                echo "HIGH 0.75 true false true PUT/PATCH with financial data. Modifies an existing financial record."
            elif [[ "$has_pii" == "true" ]]; then
                echo "MEDIUM 0.5 true false false PUT/PATCH with PII. Overwrites existing sensitive data."
            else
                echo "MEDIUM 0.5 true false false PUT/PATCH modifies an existing resource. Prior state may be lost."
            fi
            ;;
        DELETE)
            echo "HIGH 0.75 true false true HTTP DELETE removes a resource. Verify recovery procedure before proceeding."
            ;;
        *)
            echo "MEDIUM 0.5 true false false Unknown HTTP method. Assess side effects manually."
            ;;
    esac
}

_assess_infrastructure() {
    local op="$1"
    local action; action=$(jq -r '.action // "unknown"' <<< "$op" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local resource; resource=$(jq -r '.resource_type // ""' <<< "$op" 2>/dev/null | tr '[:upper:]' '[:lower:]')

    case "$action" in
        list|describe|get|read|show|status|plan_dry_run)
            echo "SAFE 0.0 false true false Read-only infrastructure inspection. No resources affected."
            ;;
        create|provision|launch|start|deploy)
            echo "NOTABLE 0.25 true true false Creates a new infrastructure resource. Reversible by destroying it."
            ;;
        update|modify|resize|reconfigure)
            case "$resource" in
                iam|policy|role|permission|security_group|firewall)
                    echo "HIGH 0.75 true false true Modifies access control or security policy. May grant or revoke permissions across the system."
                    ;;
                database|rds|aurora|postgres|mysql)
                    echo "HIGH 0.75 true false true Modifies database configuration. May affect running applications."
                    ;;
                *)
                    echo "MEDIUM 0.5 true false false Modifies infrastructure resource configuration."
                    ;;
            esac
            ;;
        scale_down|reduce|shrink)
            echo "HIGH 0.75 true true true Reduces capacity. May cause service degradation under load."
            ;;
        stop|terminate|destroy|delete|nuke|teardown)
            case "$resource" in
                production|prod|live)
                    echo "CRITICAL 1.0 true false true Destroying a production resource. Irreversible. All running workloads terminated."
                    ;;
                *)
                    echo "CRITICAL 1.0 true false true Destroying infrastructure is permanent. All data and configuration in the resource will be lost."
                    ;;
            esac
            ;;
        rotate_secret|rotate_key)
            echo "MEDIUM 0.5 true false false Rotates a secret or key. All clients using the old secret must be updated."
            ;;
        *)
            echo "MEDIUM 0.5 true false false Unknown infrastructure action. Review before executing."
            ;;
    esac
}

_assess_code_execution() {
    local op="$1"
    local env; env=$(jq -r '.environment // "unknown"' <<< "$op" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local isolated; isolated=$(jq -r '.isolated // false' <<< "$op" 2>/dev/null)
    local elevated; elevated=$(jq -r '.elevated_privileges // false' <<< "$op" 2>/dev/null)
    local dry_run; dry_run=$(jq -r '.dry_run // false' <<< "$op" 2>/dev/null)

    if [[ "$dry_run" == "true" ]]; then
        echo "SAFE 0.0 false true false Dry-run / analysis mode. No side effects."
        return
    fi
    if [[ "$elevated" == "true" ]]; then
        echo "CRITICAL 1.0 true false true Executing with elevated privileges in any environment is high risk. Requires explicit authorization."
        return
    fi
    case "$env" in
        sandbox|test|dev|local|ci)
            if [[ "$isolated" == "true" ]]; then
                echo "SAFE 0.0 true true false Isolated sandbox execution. Side effects are contained."
            else
                echo "NOTABLE 0.25 true true false Test/dev environment execution. Limited blast radius."
            fi
            ;;
        staging|qa)
            echo "MEDIUM 0.5 true false false Staging environment execution. May affect shared QA data."
            ;;
        production|prod|live)
            echo "HIGH 0.75 true false true Production code execution. Changes affect live users."
            ;;
        *)
            echo "MEDIUM 0.5 true false false Unknown execution environment. Treat as potentially production."
            ;;
    esac
}

_assess_data_access() {
    local op="$1"
    local action; action=$(jq -r '.action // "read"' <<< "$op" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local sensitivity; sensitivity=$(jq -r '.sensitivity // "internal"' <<< "$op" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local volume; volume=$(jq -r '.record_count // 1 | tonumber' <<< "$op" 2>/dev/null || echo "1")

    case "$action" in
        read|query|select|export|download)
            case "$sensitivity" in
                public|open)
                    echo "SAFE 0.0 false true false Accessing public data. No privacy concern."
                    ;;
                internal|confidential)
                    if [[ "$volume" -gt 10000 ]]; then
                        echo "HIGH 0.75 false true true Bulk export of internal data. Review data handling policy."
                    else
                        echo "NOTABLE 0.25 false true false Accessing internal data."
                    fi
                    ;;
                pii|personal|sensitive|phi|hipaa)
                    if [[ "$volume" -gt 1000 ]]; then
                        echo "CRITICAL 1.0 false true true Bulk access to PII/sensitive data. Requires explicit authorization and DPA compliance review."
                    else
                        echo "HIGH 0.75 false true true Accessing personal or sensitive data. Log access for compliance."
                    fi
                    ;;
                financial|payment|pci)
                    echo "HIGH 0.75 false true true Accessing financial/payment data. Ensure PCI DSS compliance."
                    ;;
                *)
                    echo "MEDIUM 0.5 false true false Unknown data sensitivity level. Treat as confidential."
                    ;;
            esac
            ;;
        delete|purge|anonymize|wipe)
            case "$sensitivity" in
                pii|personal|sensitive|phi)
                    echo "HIGH 0.75 true false true Deleting personal data is irreversible and has GDPR/compliance implications. Requires authorization."
                    ;;
                *)
                    echo "MEDIUM 0.5 true false false Deleting data records. Ensure backup exists."
                    ;;
            esac
            ;;
        share|send|publish|email)
            case "$sensitivity" in
                pii|personal|sensitive|financial)
                    echo "CRITICAL 1.0 true false true Sharing sensitive/PII data externally. Requires explicit authorization and data handling agreement."
                    ;;
                *)
                    echo "MEDIUM 0.5 true false false Sharing data externally. Verify recipient authorization."
                    ;;
            esac
            ;;
        *)
            echo "MEDIUM 0.5 true false false Unknown data action. Review before executing."
            ;;
    esac
}

_assess_operation() {
    local op_type="$1" op_json="$2"

    local result
    case "$op_type" in
        file_system)   result=$(_assess_file_system   "$op_json") ;;
        shell_command) result=$(_assess_shell_command "$op_json") ;;
        network_request) result=$(_assess_network_request "$op_json") ;;
        infrastructure)  result=$(_assess_infrastructure  "$op_json") ;;
        code_execution)  result=$(_assess_code_execution  "$op_json") ;;
        data_access)     result=$(_assess_data_access     "$op_json") ;;
        database)
            # Guardian knows about database ops — surface a recommendation to use forge
            echo "MEDIUM 0.5 true false false Database schema operation detected. Use forge_analyze for precise PostgreSQL migration risk assessment."
            return
            ;;
        *)
            echo "MEDIUM 0.5 true false false Unrecognized operation type '${op_type}'. Treat as potentially destructive. Review manually."
            return
            ;;
    esac
    echo "$result"
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

# ── Tool handler ──────────────────────────────────────────────────────────
_handle_guardian_assess() {
    local params="$1" req_id="$2"

    # Extract and validate operation_type
    local op_type
    op_type=$(jq -re '.operation_type // empty' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"operation_type","retryable":true,"error":"Required field: operation_type"}'
        return
    }

    # Validate operation_type is string, max 64 chars, ASCII printable
    if [[ ${#op_type} -gt 64 ]] || ! printf '%s' "$op_type" | grep -qP '^[\x20-\x7E]+$' 2>/dev/null; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"operation_type must be ASCII printable, max 64 chars"}'
        return
    fi

    # Extract operation object (required) — jq -e exits 1 on null/absent
    local op_json
    op_json=$(jq -ce '.operation' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"operation","retryable":true,"error":"Required field: operation (JSON object describing the operation)"}'
        return
    }

    # Extract optional request_id
    local request_id
    request_id=$(jq -r '.request_id // ""' <<< "$params" 2>/dev/null)
    if [[ ${#request_id} -gt 512 ]]; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"request_id max 512 chars"}'
        return
    fi

    # Extract optional human_acknowledgment_token
    local hat
    hat=$(jq -r '.human_acknowledgment_token // ""' <<< "$params" 2>/dev/null)

    # Rate limit check
    local rl_result
    rl_result=$(_rl_check "guardian_assess" "$RL_LIMIT_ASSESS" "$RL_BURST_ASSESS")
    local rl_status; rl_status="${rl_result%% *}"
    if [[ "$rl_status" == "RATE_LIMITED" ]]; then
        local reset_at; reset_at="${rl_result#* }"
        local retry_after=$(( reset_at - $(date +%s) ))
        [[ $retry_after -lt 1 ]] && retry_after=1
        jq -cn \
            --argjson ra "$retry_after" \
            --argjson rs "$reset_at" \
            --argjson lim "$RL_LIMIT_ASSESS" \
            '{"error_code":"RATE_LIMITED","retryable":true,"retry_after_seconds":$ra,"reset_at":$rs,"limit":$lim,"window":"per_hour","error":"Rate limit exceeded. Wait retry_after_seconds before retrying."}'
        return
    fi
    local rl_remaining reset_at rl_limit
    read -r _ rl_remaining reset_at rl_limit <<< "$rl_result"

    # Handle human_acknowledgment_token (approval flow)
    if [[ -n "$hat" ]]; then
        # Validate token format: 16 hex chars
        if ! [[ "$hat" =~ ^[0-9a-f]{16}$ ]]; then
            jq -cn '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Token format invalid. Re-run guardian_assess without token to get a fresh approval_nonce."}'
            return
        fi
        # Look up pending approval
        if [[ -z "${_PENDING_APPROVALS[$hat]+x}" ]]; then
            jq -cn '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Token not recognized or already used. Re-run guardian_assess (no token) to obtain a fresh approval_nonce."}'
            return
        fi
        local pending="${_PENDING_APPROVALS[$hat]}"
        local stored_hash; stored_hash="${pending%%:*}"
        local expires_at; expires_at="${pending##*:}"
        local now; now=$(date +%s 2>/dev/null || echo "0")
        if [[ $now -gt $expires_at ]]; then
            unset "_PENDING_APPROVALS[$hat]"
            jq -cn '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Approval token expired (5-min TTL). Re-run guardian_assess (no token) to obtain a fresh approval_nonce."}'
            return
        fi
        # Bind the token to the exact operation it was issued for. A nonce minted
        # for one HIGH/CRITICAL request must not be replayable against a different
        # operation within the TTL — otherwise the human-approval gate degrades
        # from "approve this action" to "approve any action".
        local current_hash; current_hash=$(_nonce_hash "${op_type}:${op_json}")
        if [[ "$stored_hash" != "$current_hash" ]]; then
            jq -cn '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Approval token does not match this operation. Re-run guardian_assess (no token) for the exact action you want approved."}'
            return
        fi
        # Token valid and bound to this operation — consume and return proceed_ok
        unset "_PENDING_APPROVALS[$hat]"

        local assessment_result
        assessment_result=$(_assess_operation "$op_type" "$op_json")
        local risk_tier risk_score has_side_effects reversible decision_required
        read -r risk_tier risk_score has_side_effects reversible decision_required _ <<< "$assessment_result"
        local guidance="${assessment_result#* * * * * }"

        jq -cn \
            --arg rt "$risk_tier" \
            --argjson rs "$risk_score" \
            --argjson hse "$has_side_effects" \
            --argjson rev "$reversible" \
            --arg ot "$op_type" \
            --arg rid "$request_id" \
            --argjson rem "$rl_remaining" \
            --argjson rsa "$reset_at" \
            --argjson lim "$rl_limit" \
            --arg guidance "$guidance" \
            '{
                "schema_version": 1,
                "operation_type": $ot,
                "risk_tier": $rt,
                "risk_score": $rs,
                "has_side_effects": $hse,
                "reversible": $rev,
                "decision_required": false,
                "proceed_ok": true,
                "guidance": $guidance,
                "request_id": (if $rid == "" then null else $rid end),
                "_rate_limit": {
                    "remaining": $rem,
                    "reset_at": $rsa,
                    "limit": $lim,
                    "window": "per_hour"
                }
            }'
        return
    fi

    # Normal assessment (no token)
    local assessment_result
    assessment_result=$(_assess_operation "$op_type" "$op_json")
    local risk_tier risk_score has_side_effects reversible decision_required
    read -r risk_tier risk_score has_side_effects reversible decision_required _ <<< "$assessment_result"
    local guidance="${assessment_result#* * * * * }"

    # Issue approval nonce for HIGH/CRITICAL operations
    local approval_nonce="" approval_prompt=""
    if [[ "$decision_required" == "true" ]]; then
        local nonce; nonce=$(_generate_nonce 2>/dev/null) || nonce=""
        if [[ -n "$nonce" ]]; then
            local now; now=$(date +%s 2>/dev/null || echo "0")
            local op_hash; op_hash=$(_nonce_hash "${op_type}:${op_json}")
            local expires_at=$(( now + 300 ))
            _PENDING_APPROVALS[$nonce]="${op_hash}:${expires_at}"
            approval_nonce="$nonce"
            approval_prompt="Operation classified as ${risk_tier}. Human sign-off required before execution. Pass approval_nonce as human_acknowledgment_token after obtaining approval. Token expires in 5 minutes."
        fi
    fi

    jq -cn \
        --arg rt "$risk_tier" \
        --argjson rs "$risk_score" \
        --argjson hse "$has_side_effects" \
        --argjson rev "$reversible" \
        --arg ot "$op_type" \
        --argjson dr "$decision_required" \
        --arg nonce "$approval_nonce" \
        --arg prompt "$approval_prompt" \
        --arg rid "$request_id" \
        --arg guidance "$guidance" \
        --argjson rem "$rl_remaining" \
        --argjson rsa "$reset_at" \
        --argjson lim "$rl_limit" \
        '{
            "schema_version": 1,
            "operation_type": $ot,
            "risk_tier": $rt,
            "risk_score": $rs,
            "has_side_effects": $hse,
            "reversible": $rev,
            "decision_required": $dr,
            "guidance": $guidance,
            "request_id": (if $rid == "" then null else $rid end),
            "approval_nonce": (if $nonce == "" then null else $nonce end),
            "approval_prompt": (if $prompt == "" then null else $prompt end),
            "_rate_limit": {
                "remaining": $rem,
                "reset_at": $rsa,
                "limit": $lim,
                "window": "per_hour"
            }
        }'
}

# ── Main MCP session loop ─────────────────────────────────────────────────
INITIALIZED=false

while IFS= read -r line || [[ -n "$line" ]]; do
    # RT-33: never use eval; process via jq
    [[ -z "$line" ]] && continue

    # Enforce message size
    if [[ ${#line} -gt $MAX_MSG ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Message exceeds 1 MiB limit"}}\n'
        continue
    fi

    # Validate JSON
    if ! jq -e . >/dev/null 2>&1 <<< "$line"; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: invalid JSON"}}\n'
        continue
    fi

    # Must be an object
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
                --arg proto "$MCP_PROTOCOL" \
                --arg ver "$GUARDIAN_VERSION" \
                '{"jsonrpc":"2.0","id":null,"method":"notifications/initialized","params":{}}'
            jq -cn \
                --argjson id "$req_id" \
                --arg proto "$MCP_PROTOCOL" \
                --arg ver "$GUARDIAN_VERSION" \
                '{
                    "jsonrpc":"2.0","id":$id,
                    "result":{
                        "protocolVersion":$proto,
                        "capabilities":{"tools":{}},
                        "serverInfo":{"name":"guardian","version":$ver}
                    }
                }'
            ;;

        tools/list)
            MANIFEST="${SCRIPT_DIR}/mcp-manifest.json"
            if [[ -f "$MANIFEST" ]]; then
                tools_json=$(jq -c '.tools' "$MANIFEST" 2>/dev/null || echo "[]")
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
                guardian_assess)
                    tool_result=$(_handle_guardian_assess "$params" "$req_id")
                    ;;
                *)
                    tool_result=$(jq -cn '{"error_code":"UNKNOWN_TOOL","retryable":false,"error":"Unknown tool. Use guardian_assess."}')
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
            # Notifications: no response
            ;;

        *)
            _send_error "$req_id" -32601 "Method not found: ${method}"
            ;;
    esac

done
