#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ vault/mcp-bridge.sh — Agent-native secret/credential manager            │
# │                                                                          │
# │ Architecture: pure bash — no separate binary. Secrets are purely I/O;  │
# │ all persistence is owned by this bridge via flock-protected writes.     │
# │ Follows the same security model as forge/ledger/guardian bridges:       │
# │ jq --arg for all user data, no eval, no string concatenation.          │
# │                                                                          │
# │ Storage: ${HEROS_DATA_DIR:-.}/.vault-secrets/ (one file per secret)    │
# │          .vault-index  (JSONL name/created_at index, no values)        │
# │          .vault-lock   (flock target for all writes)                   │
# │          .vault-audit  (JSONL access log — ts/op/name, no values)     │
# │                                                                          │
# │ Requires: jq >= 1.6, base64 (coreutils or openssl), flock (util-linux) │
# │ Security: docs/threat-model.md                                         │
# └──────────────────────────────────────────────────────────────────────────┘

set -euo pipefail

# RT-382: LC_ALL overrides LANG in the glibc locale hierarchy — set directly
# so an operator's pre-existing LC_ALL cannot affect tr/jq locale-sensitive paths.
export LC_ALL=C.UTF-8

# Clean shutdown on signal: avoid mid-write corruption of the JSON-RPC output stream.
# PIPE: client closing stdin sends SIGPIPE to the bridge's stdout writes; without a trap,
# bridge exits with status 141 (unhandled signal) instead of 0.
trap 'exit 0' TERM INT PIPE

readonly MCP_PROTOCOL="2025-11-25"
readonly MAX_MSG=1048576  # 1 MiB — per mcp-security-spec.md §5.1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Dependency check ──────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"jq >= 1.6 required but not found in PATH"}}\n'
    exit 1
fi
if ! command -v flock >/dev/null 2>&1; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"flock (util-linux) required but not found in PATH"}}\n'
    exit 1
fi
# python3 required for HMAC auth when HEROS_API_KEY is set.
if [[ -n "${HEROS_API_KEY:-}" ]] && ! command -v python3 >/dev/null 2>&1; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"python3 required for API key authentication but not found in PATH. Install python3 or unset HEROS_API_KEY for anonymous mode."}}\n'
    exit 1
fi

# ── Load manifest ─────────────────────────────────────────────────────────
MANIFEST="${SCRIPT_DIR}/mcp-manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"mcp-manifest.json not found alongside mcp-bridge.sh"}}\n'
    exit 1
fi
if ! jq -e . >/dev/null 2>&1 < "$MANIFEST"; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"mcp-manifest.json is not valid JSON — check file integrity"}}\n'
    exit 1
fi
if ! jq -e '.tools | type == "array"' >/dev/null 2>&1 < "$MANIFEST"; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"mcp-manifest.json: tools field must be an array"}}\n'
    exit 1
fi

SERVER_VERSION=$(jq -r '.version // "0.0.0"' "$MANIFEST")
# V199: cap SERVER_VERSION to prevent E2BIG when passed as --arg sv to jq.
SERVER_VERSION="${SERVER_VERSION:0:64}"

# ── Data directory setup ──────────────────────────────────────────────────
HEROS_DATA_DIR="${HEROS_DATA_DIR:-.}"

# Validate HEROS_DATA_DIR when auth is enabled
if [[ -n "${HEROS_API_KEY:-}" ]]; then
    if [[ -z "${HEROS_DATA_DIR:-}" ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_DATA_DIR must be set when HEROS_API_KEY is configured"}}\n'
        exit 1
    fi
    if [[ ! -d "${HEROS_DATA_DIR}" ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_DATA_DIR does not exist or is not a directory — check operator configuration"}}\n'
        exit 1
    fi
    seed="${HEROS_HMAC_SEED:-}"
    if [[ ${#seed} -lt 32 ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_HMAC_SEED is too short (minimum 32 characters required). Generate with: openssl rand -hex 32"}}\n'
        exit 1
    fi
    if [[ ! -f "${HEROS_DATA_DIR}/.heros-keys" ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_DATA_DIR/.heros-keys not found — create API keys first with: ledger/key-gen.sh"}}\n'
        exit 1
    fi
fi

# Warn in anonymous mode
if [[ -z "${HEROS_API_KEY:-}" ]]; then
    echo "[vault-security] HEROS_API_KEY unset — anonymous mode active. No audit logging. Set HEROS_API_KEY to enforce authentication." >&2
fi

# Vault secrets directory
VAULT_SECRETS_DIR="${HEROS_DATA_DIR}/.vault-secrets"
VAULT_INDEX_FILE="${HEROS_DATA_DIR}/.vault-index"
VAULT_LOCK_FILE="${HEROS_DATA_DIR}/.vault-lock"
VAULT_AUDIT_FILE="${HEROS_DATA_DIR}/.vault-audit"

# Create secrets dir if needed
if [[ ! -d "$VAULT_SECRETS_DIR" ]]; then
    mkdir -p "$VAULT_SECRETS_DIR" 2>/dev/null || {
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Failed to create .vault-secrets directory — check directory permissions"}}\n'
        exit 1
    }
fi

# Symlink checks on critical vault files (V318 pattern)
for _vault_f in ".vault-lock" ".vault-index"; do
    if [[ -L "${HEROS_DATA_DIR}/${_vault_f}" ]]; then
        jq -cn --arg p "${HEROS_DATA_DIR}/${_vault_f}" \
            '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":("Security: "+$p+" is a symlink — data files must be regular files to prevent write-redirect attacks. Remove the symlink and restart.")}}'
        exit 1
    fi
done
unset _vault_f
# Warn-only for audit file (operators may legitimately symlink to centralized log)
if [[ -L "${VAULT_AUDIT_FILE}" ]]; then
    echo "[vault-security] WARNING: .vault-audit is a symlink; audit writes will follow the link. Ensure the target path is trusted." >&2
fi

# ── Rate limiting (token bucket, v0.2 spec) ───────────────────────────────
# Tokens stored ×100 (integer fixed-point) for sub-token precision.
declare -A _RL_BUCKETS

# RT-298: SECONDS is bash uptime. Compute epoch offset once for real Unix timestamps.
_RL_EPOCH_OFFSET=$(( $(date +%s 2>/dev/null || echo 0) - SECONDS ))
readonly _RL_EPOCH_OFFSET

_rl_clamp() {
    local v="$1" max="$2"
    # RT-387: reject leading zeros before arithmetic (octal parse hazard).
    [[ "$v" =~ ^(0|[1-9][0-9]*)$ ]] || { printf '[vault-config] rate limit "%s" is not a valid non-negative integer (no leading zeros); using default 1\n' "$v" >&2; v=1; }
    # RT-391: reject >10 digit values (int64 overflow in multiplication).
    (( ${#v} > 10 )) && { printf '[vault-config] rate limit "%s" exceeds maximum digit length (10); using default 1\n' "$v" >&2; v=1; }
    if (( v > max )); then echo "$max"; else echo "$v"; fi
}

RL_SET_LIMIT=$(_rl_clamp "${VAULT_RATE_SET:-100}" 1000)
readonly RL_SET_LIMIT
RL_GET_LIMIT=$(_rl_clamp "${VAULT_RATE_GET:-500}" 5000)
readonly RL_GET_LIMIT
RL_DELETE_LIMIT=$(_rl_clamp "${VAULT_RATE_DELETE:-50}" 500)
readonly RL_DELETE_LIMIT
RL_LIST_LIMIT=$(_rl_clamp "${VAULT_RATE_LIST:-1000}" 10000)
readonly RL_LIST_LIMIT

RL_REMAINING=0
RL_RESET_AT=0

# _rl_check tool dim value limit_per_hour burst_capacity
# Returns 0 (allow) or 1 (deny), sets RL_REMAINING and RL_RESET_AT globals.
_rl_check() {
    local tool="$1" dim="$2" val="$3" limit="$4" burst="$5"
    if (( limit == 0 )); then
        RL_REMAINING=0
        RL_RESET_AT=$(( _RL_EPOCH_OFFSET + SECONDS + 3600 ))
        return 1
    fi
    local key="${tool}:${dim}:${val}"
    local now="$SECONDS"
    local cap=$(( burst * 100 ))

    local tokens=$cap last=$now
    if [[ -n "${_RL_BUCKETS[$key]+x}" ]]; then
        IFS=: read -r tokens last <<< "${_RL_BUCKETS[$key]}"
    fi

    # RT-284: compute added directly to avoid refill_per_sec truncation cascade.
    local elapsed=$(( now - last ))
    local added=$(( elapsed * limit * 100 / 3600 ))
    tokens=$(( tokens + added ))
    [[ $tokens -gt $cap ]] && tokens=$cap

    local tokens_needed=$(( 100 - (tokens % 100) ))
    # RT-298: add epoch offset so reset_at is a real Unix timestamp.
    RL_RESET_AT=$(( _RL_EPOCH_OFFSET + now + tokens_needed * 3600 / (limit * 100) ))

    if (( tokens >= 100 )); then
        tokens=$(( tokens - 100 ))
        _RL_BUCKETS[$key]="${tokens}:${now}"
        # RT-295: remaining AFTER consuming so agents see calls left, not calls left+1.
        RL_REMAINING=$(( tokens / 100 ))
        return 0
    else
        _RL_BUCKETS[$key]="${tokens}:${now}"
        RL_REMAINING=0
        return 1
    fi
}

_rl_rate_limited_json() {
    local tool="$1" dim="$2"
    # RT-301: use RL_RESET_AT for accurate retry_after_seconds.
    local now_epoch=$(( _RL_EPOCH_OFFSET + SECONDS ))
    local retry=$(( RL_RESET_AT - now_epoch ))
    (( retry < 1 )) && retry=1
    jq -cn --arg tool "$tool" --arg dim "$dim" --argjson rs "$retry" \
        '{"error_code":"RATE_LIMITED","error":"Too many requests. Retry after the specified delay.","retry_after_seconds":$rs,"limit_type":$dim,"limit_tool":$tool,"retryable":true}'
}

_rl_inject_field() {
    local json="$1" remaining="$2" reset_at="$3" limit="$4"
    # RT-314: printf avoids echo interpreting "-n"/"-e" in $json as flags.
    jq -c --argjson rem "$remaining" --argjson rat "$reset_at" --argjson lim "$limit" \
        '. + {"_rate_limit":{"remaining":$rem,"reset_at":$rat,"limit":$lim,"window":"per_hour"}}' \
        <<< "$json" 2>/dev/null || printf '%s\n' "$json"
}

# ── Auth (shared key namespace with ledger/forge bridges) ─────────────────
_validate_api_key() {
    local key="$1" required_scope="${2:-ro}"
    local prefix scope key_id secret
    IFS='_' read -r prefix scope key_id secret <<< "$key"

    if [[ "$prefix" != "heros" ]] || \
       [[ ! "$scope" =~ ^(ro|rw)$ ]] || \
       [[ ! "$key_id" =~ ^[0-9a-f]{32}$ ]] || \
       [[ ! "$secret" =~ ^[0-9a-f]{32}$ ]]; then
        return 1
    fi

    [[ ! -f "${HEROS_DATA_DIR}/.heros-keys" ]] && return 1

    local record
    record=$(awk -v kid="${key_id}" '$1 == kid { print; exit }' \
        "${HEROS_DATA_DIR}/.heros-keys" 2>/dev/null) || true
    [[ -z "$record" ]] && return 1

    local _kid stored_scope stored_org stored_hash _created stored_revoked
    read -r _kid stored_scope stored_org stored_hash _created stored_revoked <<< "$record"
    # RT-283: strip trailing whitespace from last field.
    stored_revoked="${stored_revoked%%[[:space:]]*}"

    [[ "$stored_revoked" == "1" ]] && return 2

    [[ -z "${HEROS_HMAC_SEED:-}" ]] && return 1

    # RT-311/RT-128: compute + compare in one python3 call — seed via env (never CLI arg).
    if ! printf '%s' "${key_id}:${secret}" | \
        python3 -c "
import hmac,hashlib,sys,os
seed=os.environ['HEROS_HMAC_SEED'].encode()
data=sys.stdin.buffer.read()
expected=sys.argv[1]
computed=hmac.new(seed,data,hashlib.sha256).hexdigest()
sys.exit(0 if hmac.compare_digest(computed,expected) else 1)
" "$stored_hash" 2>/dev/null; then
        return 1
    fi

    # Fail closed: any stored_scope value other than ro or rw is rejected.
    case "$stored_scope" in
        ro) [[ "$required_scope" == "rw" ]] && return 3 ;;
        rw) ;;
        *) return 1 ;;
    esac

    [[ ! "$stored_org" =~ ^org_[0-9a-f]{8}$ ]] && return 1

    echo "$stored_org"
    return 0
}

_audit_access() {
    local op="$1" name="$2"
    local ts
    ts=$(date +%s 2>/dev/null || echo "0")
    # RT-33: jq --arg for all user-controlled data (name may contain JSON-special chars).
    jq -cn --argjson ts "$ts" --arg op "$op" --arg name "$name" \
        '{"ts":$ts,"op":$op,"name":$name}' \
        >> "${VAULT_AUDIT_FILE}" 2>/dev/null || true
}

_audit_fail() {
    local rc="$1"
    local epoch
    epoch=$(date +%s 2>/dev/null || echo "0")
    printf '%s FAIL rc=%s\n' "$epoch" "$rc" \
        >> "${HEROS_DATA_DIR}/.heros-audit-failed" 2>/dev/null || true
}

# ── Approval nonce state (decision_required flow for vault_secret_delete) ─
declare -A _PENDING_APPROVALS  # nonce → "secret_name:expires_at" (SECONDS + 300 TTL)

_generate_nonce() {
    local ent=""
    if ent=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | head -c16) && \
       [[ ${#ent} -eq 16 ]] && [[ $ent =~ ^[0-9a-f]{16}$ ]]; then
        printf '%s' "$ent"; return 0
    fi
    if ent=$(xxd -l8 -p /dev/urandom 2>/dev/null | tr -d ' \n' | head -c16) && \
       [[ ${#ent} -eq 16 ]] && [[ $ent =~ ^[0-9a-f]{16}$ ]]; then
        printf '%s' "$ent"; return 0
    fi
    if ent=$(openssl rand -hex 8 2>/dev/null | head -c16) && \
       [[ ${#ent} -eq 16 ]] && [[ $ent =~ ^[0-9a-f]{16}$ ]]; then
        printf '%s' "$ent"; return 0
    fi
    return 1
}

# ── Base64 encode/decode helpers ──────────────────────────────────────────
# _b64encode: reads from stdin, outputs base64 (no newlines) to stdout.
_b64encode() {
    # Prefer base64 -w0 (GNU coreutils). Fall back to python3 for macOS/minimal systems.
    if base64 --version >/dev/null 2>&1; then
        base64 -w0
    else
        python3 -c "import base64,sys; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())"
    fi
}

# _b64decode: reads base64 from stdin, outputs raw bytes to stdout.
_b64decode() {
    if base64 --version >/dev/null 2>&1; then
        base64 -d
    else
        python3 -c "import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))"
    fi
}

# ── Secret name validation ────────────────────────────────────────────────
# Returns 0 if valid, 1 if invalid. No path traversal: rejects '..' and '/'.
_validate_secret_name() {
    local name="$1"
    # Length check first
    if [[ ${#name} -eq 0 || ${#name} -gt 128 ]]; then
        return 1
    fi
    # Charset: [a-zA-Z0-9_.-] only — strict regex
    if [[ ! "$name" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        return 1
    fi
    # No path traversal: reject '..' component anywhere in name
    case "$name" in
        *..*) return 1 ;;
        */*) return 1 ;;
    esac
    return 0
}

# ── Secret file path helper ───────────────────────────────────────────────
# Returns the path to the secret file for a given (already-validated) name.
_secret_file() {
    printf '%s/%s.json' "$VAULT_SECRETS_DIR" "$1"
}

# ── Vault tool handlers ───────────────────────────────────────────────────

# vault_secret_set(name, value, [description])
_handle_vault_secret_set() {
    local args_json="$1"

    # Extract and validate name
    local name
    if ! name=$(jq -re '.name | if type == "string" then . else error end' <<< "$args_json" 2>/dev/null); then
        echo '{"error_code":"MISSING_FLAG","flag":"name","retryable":true,"error":"name is required and must be a string"}'
        return
    fi
    if ! _validate_secret_name "$name"; then
        echo '{"error_code":"INVALID_INPUT","field":"name","retryable":false,"error":"name must match [a-zA-Z0-9_.-], max 128 chars, no path traversal (no .. or /)"}'
        return
    fi

    # Extract and validate value (required)
    local value
    if ! value=$(jq -re '.value | if type == "string" then . else error end' <<< "$args_json" 2>/dev/null); then
        echo '{"error_code":"MISSING_FLAG","flag":"value","retryable":true,"error":"value is required and must be a string"}'
        return
    fi
    # Value length cap: 64 KiB (UTF-8 text encoded as base64 means real limit is ~48 KiB raw)
    if (( ${#value} > 65536 )); then
        echo '{"error_code":"INVALID_INPUT","field":"value","retryable":false,"error":"value exceeds 64 KiB limit"}'
        return
    fi

    # Extract optional description (ASCII printable only, max 512 chars)
    local description=""
    if description=$(jq -re '.description | if type == "string" then . else error end' <<< "$args_json" 2>/dev/null); then
        if (( ${#description} > 512 )); then
            echo '{"error_code":"INVALID_INPUT","field":"description","retryable":false,"error":"description exceeds 512 characters"}'
            return
        fi
        # ASCII printable only (0x20–0x7E)
        if ! printf '%s' "$description" | grep -qP '^[\x20-\x7E]*$' 2>/dev/null; then
            # Fallback without perl regex
            if printf '%s' "$description" | LC_ALL=C grep -q '[^[:print:][:space:]]' 2>/dev/null; then
                echo '{"error_code":"INVALID_INPUT","field":"description","retryable":false,"error":"description must be ASCII printable only"}'
                return
            fi
        fi
    else
        description=""
    fi

    # Base64 encode the value
    local value_b64
    value_b64=$(printf '%s' "$value" | _b64encode 2>/dev/null) || {
        echo '{"error_code":"STORE_WRITE_FAILED","error":"Failed to base64-encode secret value","retryable":false}'
        return
    }

    local ts
    ts=$(date +%s 2>/dev/null || echo "0")
    local secret_file
    secret_file=$(_secret_file "$name")

    # Hold exclusive lock across existence check + write + index update
    local result_json=""
    {
        flock -w 30 -x 200 || {
            echo '{"error_code":"STORE_WRITE_FAILED","error":"Store lock unavailable; retry in a few seconds.","retryable":true}'
            return
        }

        local version=1
        local created_at="$ts"
        if [[ -f "$secret_file" ]]; then
            # Read existing record to preserve created_at and increment version
            local existing
            existing=$(cat "$secret_file" 2>/dev/null) || {
                echo '{"error_code":"STORE_READ_FAILED","error":"Failed to read existing secret file","retryable":false}'
                return
            }
            if jq -e . >/dev/null 2>&1 <<< "$existing"; then
                created_at=$(jq -r '.created_at // "'"$ts"'"' <<< "$existing" 2>/dev/null || echo "$ts")
                local old_version
                old_version=$(jq -r '.version // 0' <<< "$existing" 2>/dev/null || echo "0")
                version=$(( old_version + 1 ))
            fi
        fi

        # Write secret file atomically via tmpfile + mv
        local secret_json
        secret_json=$(jq -cn \
            --arg name "$name" \
            --arg description "$description" \
            --arg value_b64 "$value_b64" \
            --argjson created_at "$created_at" \
            --argjson updated_at "$ts" \
            --argjson version "$version" \
            '{name:$name,description:$description,value_b64:$value_b64,created_at:$created_at,updated_at:$updated_at,version:$version}')

        local tmpfile
        if tmpfile=$(mktemp "${secret_file}.XXXXXX" 2>/dev/null); then
            if printf '%s\n' "$secret_json" > "$tmpfile" 2>/dev/null && \
               mv -f "$tmpfile" "$secret_file" 2>/dev/null; then
                :
            else
                rm -f "$tmpfile" 2>/dev/null || true
                echo '{"error_code":"STORE_WRITE_FAILED","error":"Failed to write secret file atomically","retryable":true}'
                return
            fi
        else
            if ! printf '%s\n' "$secret_json" > "$secret_file" 2>/dev/null; then
                echo '{"error_code":"STORE_WRITE_FAILED","error":"Failed to write secret file","retryable":true}'
                return
            fi
        fi

        # Update index — rewrite to add/replace entry for this name
        local index_entry
        index_entry=$(jq -cn \
            --arg name "$name" \
            --arg description "$description" \
            --argjson created_at "$created_at" \
            --argjson version "$version" \
            '{name:$name,description:$description,created_at:$created_at,version:$version}')

        local index_tmpfile
        if [[ -f "$VAULT_INDEX_FILE" ]]; then
            if index_tmpfile=$(mktemp "${VAULT_INDEX_FILE}.XXXXXX" 2>/dev/null); then
                # Filter out the old entry for this name by PARSED .name (not a raw
                # substring — a substring match could drop unrelated entries whose
                # description happens to contain the name), then append new entry.
                if jq -c --arg n "$name" 'select(.name != $n)' "$VAULT_INDEX_FILE" > "$index_tmpfile" 2>/dev/null; then
                    printf '%s\n' "$index_entry" >> "$index_tmpfile" 2>/dev/null || true
                    mv -f "$index_tmpfile" "$VAULT_INDEX_FILE" 2>/dev/null || true
                else
                    # Malformed index line — don't clobber existing data; append only.
                    rm -f "$index_tmpfile" 2>/dev/null || true
                    printf '%s\n' "$index_entry" >> "$VAULT_INDEX_FILE" 2>/dev/null || true
                fi
            else
                printf '%s\n' "$index_entry" >> "$VAULT_INDEX_FILE" 2>/dev/null || true
            fi
        else
            printf '%s\n' "$index_entry" > "$VAULT_INDEX_FILE" 2>/dev/null || true
        fi

        # Build secret_id (sha256 of name, first 16 hex chars — deterministic)
        local secret_id
        secret_id=$(printf '%s' "$name" | sha256sum 2>/dev/null | cut -c1-16 || echo "unknown")

        result_json=$(jq -cn \
            --arg secret_id "$secret_id" \
            --arg name "$name" \
            --argjson created_at "$created_at" \
            --argjson updated_at "$ts" \
            --argjson version "$version" \
            '{"secret_id":$secret_id,"name":$name,"created_at":$created_at,"updated_at":$updated_at,"version":$version,"status":"ok"}')

    } 200>"${VAULT_LOCK_FILE}" || {
        echo '{"error_code":"STORE_WRITE_FAILED","error":"Failed to create vault lock file; check directory permissions","retryable":true}'
        return
    }

    printf '%s\n' "$result_json"
}

# vault_secret_get(name)
_handle_vault_secret_get() {
    local args_json="$1"

    local name
    if ! name=$(jq -re '.name | if type == "string" then . else error end' <<< "$args_json" 2>/dev/null); then
        echo '{"error_code":"MISSING_FLAG","flag":"name","retryable":true,"error":"name is required and must be a string"}'
        return
    fi
    if ! _validate_secret_name "$name"; then
        echo '{"error_code":"INVALID_INPUT","field":"name","retryable":false,"error":"name must match [a-zA-Z0-9_.-], max 128 chars, no path traversal"}'
        return
    fi

    local secret_file
    secret_file=$(_secret_file "$name")

    if [[ ! -f "$secret_file" ]]; then
        echo '{"error_code":"SECRET_NOT_FOUND","retryable":false,"error":"No secret found with that name"}'
        return
    fi

    local secret_data
    secret_data=$(cat "$secret_file" 2>/dev/null) || {
        echo '{"error_code":"STORE_READ_FAILED","error":"Failed to read secret file","retryable":false}'
        return
    }

    if ! jq -e . >/dev/null 2>&1 <<< "$secret_data"; then
        echo '{"error_code":"STORE_READ_FAILED","error":"Secret file contains invalid JSON — possible corruption","retryable":false}'
        return
    fi

    # Decode base64 value — output is raw bytes decoded as UTF-8 string
    local value_b64 value
    value_b64=$(jq -r '.value_b64 // ""' <<< "$secret_data" 2>/dev/null)
    value=$(printf '%s' "$value_b64" | _b64decode 2>/dev/null) || {
        echo '{"error_code":"STORE_READ_FAILED","error":"Failed to base64-decode secret value — possible corruption","retryable":false}'
        return
    }

    # Audit the read access (ts, op, name — NOT the value)
    _audit_access "get" "$name"

    local secret_id
    secret_id=$(printf '%s' "$name" | sha256sum 2>/dev/null | cut -c1-16 || echo "unknown")

    jq -cn \
        --arg secret_id "$secret_id" \
        --arg name "$name" \
        --arg value "$value" \
        --arg description "$(jq -r '.description // ""' <<< "$secret_data" 2>/dev/null)" \
        --argjson created_at "$(jq -r '.created_at // 0' <<< "$secret_data" 2>/dev/null)" \
        --argjson version "$(jq -r '.version // 1' <<< "$secret_data" 2>/dev/null)" \
        '{"secret_id":$secret_id,"name":$name,"value":$value,"description":$description,"created_at":$created_at,"version":$version,"status":"ok"}'
}

# vault_secret_delete(name, [human_acknowledgment_token])
_handle_vault_secret_delete() {
    local args_json="$1"

    local name
    if ! name=$(jq -re '.name | if type == "string" then . else error end' <<< "$args_json" 2>/dev/null); then
        echo '{"error_code":"MISSING_FLAG","flag":"name","retryable":true,"error":"name is required and must be a string"}'
        return
    fi
    if ! _validate_secret_name "$name"; then
        echo '{"error_code":"INVALID_INPUT","field":"name","retryable":false,"error":"name must match [a-zA-Z0-9_.-], max 128 chars, no path traversal"}'
        return
    fi

    local secret_file
    secret_file=$(_secret_file "$name")

    if [[ ! -f "$secret_file" ]]; then
        echo '{"error_code":"SECRET_NOT_FOUND","retryable":false,"error":"No secret found with that name"}'
        return
    fi

    # Extract optional human_acknowledgment_token
    local hat=""
    hat=$(jq -r '.human_acknowledgment_token // ""' <<< "$args_json" 2>/dev/null) || hat=""

    if [[ -n "$hat" ]]; then
        # Validate token format: exactly 16 lowercase hex chars.
        # RT-109: validate before using as associative array key to prevent special key expansion.
        if ! [[ "$hat" =~ ^[0-9a-f]{16}$ ]]; then
            echo '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Token format invalid. Expected 16 hex chars. Re-run vault_secret_delete without token to obtain a fresh approval_nonce."}'
            return
        fi
        if [[ -z "${_PENDING_APPROVALS[$hat]+x}" ]]; then
            echo '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Token not recognized or already used. Re-run vault_secret_delete (no token) to obtain a fresh approval_nonce."}'
            return
        fi
        local pending="${_PENDING_APPROVALS[$hat]}"
        # Stored as "secret_name:expires_at"; name is validated [a-zA-Z0-9_.-]
        # (no colon), so split on the last colon to recover the expiry.
        local hat_name="${pending%:*}"
        local hat_expires="${pending##*:}"
        if (( SECONDS > hat_expires )); then
            unset "_PENDING_APPROVALS[$hat]"
            echo '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Approval token expired (5-min TTL). Re-run vault_secret_delete (no token) to obtain a fresh approval_nonce."}'
            return
        fi
        # Bind the token to the exact secret it was issued for. A nonce minted to
        # approve deleting one secret must not be replayable to delete another
        # within the TTL — otherwise the gate degrades to "approve any deletion".
        if [[ "$hat_name" != "$name" ]]; then
            echo '{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Approval token does not match this secret. Re-run vault_secret_delete (no token) for the exact secret you want deleted."}'
            return
        fi
        # Valid token bound to this secret — single-use: consume and proceed.
        unset "_PENDING_APPROVALS[$hat]"

        # Perform the deletion under lock
        {
            flock -w 30 -x 200 || {
                echo '{"error_code":"STORE_WRITE_FAILED","error":"Store lock unavailable; retry in a few seconds.","retryable":true}'
                return
            }
            rm -f "$secret_file" 2>/dev/null || {
                echo '{"error_code":"STORE_WRITE_FAILED","error":"Failed to delete secret file","retryable":true}'
                return
            }
            # Remove from index
            if [[ -f "$VAULT_INDEX_FILE" ]]; then
                local idx_tmp
                if idx_tmp=$(mktemp "${VAULT_INDEX_FILE}.XXXXXX" 2>/dev/null); then
                    # Filter by parsed .name (not raw substring) so we only drop the
                    # entry actually being deleted.
                    if jq -c --arg n "$name" 'select(.name != $n)' "$VAULT_INDEX_FILE" > "$idx_tmp" 2>/dev/null; then
                        mv -f "$idx_tmp" "$VAULT_INDEX_FILE" 2>/dev/null || rm -f "$idx_tmp" 2>/dev/null || true
                    else
                        rm -f "$idx_tmp" 2>/dev/null || true
                    fi
                fi
            fi
        } 200>"${VAULT_LOCK_FILE}" || {
            echo '{"error_code":"STORE_WRITE_FAILED","error":"Failed to create vault lock file; check directory permissions","retryable":true}'
            return
        }

        _audit_access "delete" "$name"
        echo '{"status":"ok","deleted":true}'
        return
    fi

    # No token — issue approval nonce (decision_required flow)
    local nonce expires_at
    nonce=$(_generate_nonce 2>/dev/null) || nonce=""
    if [[ ! "$nonce" =~ ^[0-9a-f]{16}$ ]]; then
        echo '{"error_code":"STORE_WRITE_FAILED","retryable":true,"error":"Bridge: nonce generation failed. Cannot gate decision_required delete."}'
        return
    fi
    expires_at=$(( SECONDS + 300 ))
    _PENDING_APPROVALS[$nonce]="${name}:${expires_at}"

    jq -cn \
        --arg name "$name" \
        --arg nonce "$nonce" \
        '{"decision_required":true,"name":$name,"approval_nonce":$nonce,"approval_prompt":"Secret deletion is irreversible. Human sign-off required. Pass approval_nonce as human_acknowledgment_token after obtaining approval. Token expires in 5 minutes.","status":"pending"}'
}

# vault_secret_list()
_handle_vault_secret_list() {
    if [[ ! -f "$VAULT_INDEX_FILE" ]]; then
        echo '{"secrets":[],"count":0,"status":"ok"}'
        return
    fi

    local list_json
    list_json=$(jq -sc '{"secrets":.,"count":(. | length),"status":"ok"}' \
        "$VAULT_INDEX_FILE" 2>/dev/null) || {
        echo '{"error_code":"STORE_READ_FAILED","error":"Failed to read vault index","retryable":false}'
        return
    }
    printf '%s\n' "$list_json"
}

# ── invoke_vault — dispatch a tools/call to vault logic ──────────────────
# V44: if HEROS_API_KEY is set, validates key before dispatch.
invoke_vault() {
    local name="$1"
    local args_json="$2"

    # ── Auth guard ────────────────────────────────────────────────────────
    local _api_key="${HEROS_API_KEY:-}"
    local _key_id="" _key_scope="" _org_id=""
    if [[ -n "$_api_key" ]]; then
        local _required_scope="ro"
        case "$name" in
            vault_secret_set|vault_secret_delete) _required_scope="rw" ;;
        esac
        local _auth_rc=0
        _org_id=$(_validate_api_key "$_api_key" "$_required_scope") || _auth_rc=$?
        case $_auth_rc in
            2)
                _audit_fail 2
                echo '{"error_code":"API_KEY_REVOKED","retryable":false,"hint":"Rotate key via `ledger key rotate`"}'
                return ;;
            3)
                _audit_fail 3
                echo '{"error_code":"INSUFFICIENT_SCOPE","retryable":false,"hint":"Use an rw-scoped key for write operations"}'
                return ;;
            0)
                IFS='_' read -r _ _key_scope _key_id _ <<< "$_api_key" ;;
            *)
                _audit_fail 1
                echo '{"error_code":"INVALID_API_KEY","retryable":false,"hint":"Obtain a valid key via `ledger key create --scope rw`"}'
                return ;;
        esac
    fi

    case "$name" in
        vault_secret_set)    _handle_vault_secret_set    "$args_json" ;;
        vault_secret_get)    _handle_vault_secret_get    "$args_json" ;;
        vault_secret_delete) _handle_vault_secret_delete "$args_json" ;;
        vault_secret_list)   _handle_vault_secret_list ;;
        *)
            echo '{"error_code":"UNKNOWN_TOOL","retryable":false,"error":"No such tool"}'
            return
            ;;
    esac
}

# ── JSON-RPC response builders ─────────────────────────────────────────────
rpc_ok() {
    # RT-302: pipe $2 via stdin to avoid argv size limit for large results.
    printf '%s' "$2" | jq -cn --argjson _id "$1" \
        '{"jsonrpc":"2.0","id":$_id,"result":input}'
}

rpc_err() {
    jq -cn --argjson _id "$1" --argjson _c "$2" --arg _m "$3" \
        '{"jsonrpc":"2.0","id":$_id,"error":{"code":$_c,"message":$_m}}'
}

# ── tools/list — reshape mcp-manifest.json into MCP wire format ───────────
tools_list_response() {
    # RT-63: include outputSchema; RT-64: include title.
    jq -c '{tools:[.tools[]|{
        name,
        title,
        description,
        inputSchema:.input_schema,
        outputSchema:.output_schema,
        annotations
    }]}' "$MANIFEST"
}

# ── handle_message — dispatch one JSON-RPC 2.0 message ────────────────────
handle_message() {
    local line="$1"

    # Validate JSON
    if ! jq -e . >/dev/null 2>&1 <<< "$line"; then
        rpc_err "null" -32700 "Parse error: message is not valid JSON"
        return
    fi

    # RT-38: reject non-object JSON-RPC
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$line"; then
        rpc_err "null" -32600 "Invalid Request: message must be a JSON object, not an array or primitive"
        return
    fi

    local id method
    id=$(jq -c '.id // null' <<< "$line")
    method=$(jq -r '.method // ""' <<< "$line")

    # RT-431: guard oversized id values
    if (( ${#id} > 4096 )); then
        rpc_err "null" -32600 "Invalid Request: id field must not exceed 4096 bytes"
        return
    fi

    # Notifications: absent "id" key means no response expected
    if ! jq -e 'has("id")' >/dev/null 2>&1 <<< "$line"; then
        [[ "$method" == "notifications/initialized" && "$INIT_REQUESTED" == "true" ]] && INITIALIZED=true
        return
    fi

    # RT-292: reject missing or wrong jsonrpc version
    if ! jq -e '.jsonrpc == "2.0"' >/dev/null 2>&1 <<< "$line"; then
        rpc_err "$id" -32600 "Invalid Request: jsonrpc field must be \"2.0\""
        return
    fi

    # V154: non-string method must return -32600 not -32601
    if ! jq -e '.method | type == "string"' >/dev/null 2>&1 <<< "$line"; then
        rpc_err "$id" -32600 "Invalid Request: method must be a string"
        return
    fi

    case "$method" in

        initialize)
            # V7e: reject re-initialization
            if [[ "$INIT_REQUESTED" == "true" ]]; then
                rpc_err "$id" -32003 "Already initialized — re-initialization rejected"
                return
            fi
            INIT_REQUESTED=true
            INITIALIZED=true
            local _init_result
            _init_result=$(jq -cn --arg pv "$MCP_PROTOCOL" --arg sv "$SERVER_VERSION" \
                '{"protocolVersion":$pv,"capabilities":{"tools":{}},"serverInfo":{"name":"vault","version":$sv}}')
            rpc_ok "$id" "$_init_result"
            ;;

        tools/list)
            if [[ "$INITIALIZED" != "true" ]]; then
                rpc_err "$id" -32002 "Server not initialized — send initialize first"
                return
            fi
            local tools_json
            tools_json=$(tools_list_response)
            rpc_ok "$id" "$tools_json"
            ;;

        tools/call)
            if [[ "$INITIALIZED" != "true" ]]; then
                rpc_err "$id" -32002 "Server not initialized — send initialize first"
                return
            fi
            # RT-345: validate params type
            if ! jq -e '.params | . == null or type == "object"' >/dev/null 2>&1 <<< "$line"; then
                rpc_err "$id" -32602 "Invalid params: params must be an object"
                return
            fi
            # RT-349: validate arguments type
            if ! jq -e '.params.arguments | . == null or type == "object"' >/dev/null 2>&1 <<< "$line"; then
                rpc_err "$id" -32602 "Invalid params: params.arguments must be an object"
                return
            fi
            # V339: reject non-string params.name
            if ! jq -e '.params.name | . == null or type == "string"' >/dev/null 2>&1 <<< "$line"; then
                rpc_err "$id" -32602 "Invalid params: params.name must be a string"
                return
            fi

            local tool_name tool_args vault_out content_json
            tool_name=$(jq -r '.params.name // ""' <<< "$line")
            tool_args=$(jq -c '.params.arguments // {}' <<< "$line")

            if [[ -z "$tool_name" ]]; then
                rpc_err "$id" -32602 "Invalid params: missing tool name in params.name"
                return
            fi
            # RT-219: reject tool names with control chars or non-identifier bytes
            if [[ ! "$tool_name" =~ ^[a-z][a-z0-9_]*$ ]]; then
                rpc_err "$id" -32602 "Invalid params: tool name must match [a-z][a-z0-9_]+"
                return
            fi

            # ── Rate limiting ─────────────────────────────────────────────
            local rl_ok=true rl_dim="per_session" rl_limit=0 rl_burst=0
            case "$tool_name" in
                vault_secret_set)
                    rl_limit=$RL_SET_LIMIT; rl_burst=10
                    _rl_check "$tool_name" "session" "session" "$rl_limit" "$rl_burst" || rl_ok=false
                    ;;
                vault_secret_get)
                    rl_limit=$RL_GET_LIMIT; rl_burst=20
                    _rl_check "$tool_name" "session" "session" "$rl_limit" "$rl_burst" || rl_ok=false
                    ;;
                vault_secret_delete)
                    rl_limit=$RL_DELETE_LIMIT; rl_burst=5
                    _rl_check "$tool_name" "session" "session" "$rl_limit" "$rl_burst" || rl_ok=false
                    ;;
                vault_secret_list)
                    rl_limit=$RL_LIST_LIMIT; rl_burst=30
                    _rl_check "$tool_name" "session" "session" "$rl_limit" "$rl_burst" || rl_ok=false
                    ;;
                *)
                    # Unknown tools: conservative default limit.
                    # RT-431: fixed "__unknown__" bucket prevents unbounded _RL_BUCKETS growth.
                    rl_limit=60; rl_burst=10
                    _rl_check "__unknown__" "session" "session" "$rl_limit" "$rl_burst" || rl_ok=false
                    ;;
            esac
            if [[ "$rl_ok" == "false" ]]; then
                local rl_json
                if (( rl_limit == 0 )); then
                    rl_json='{"error_code":"TOOL_DISABLED","error":"This tool has been disabled by operator configuration.","retryable":false}'
                else
                    rl_json=$(_rl_rate_limited_json "$tool_name" "$rl_dim")
                fi
                content_json=$(jq -cn --arg text "$rl_json" \
                    '{"content":[{"type":"text","text":$text}],"isError":true}')
                rpc_ok "$id" "$content_json"
                return
            fi
            local rl_remaining=$RL_REMAINING rl_reset=$RL_RESET_AT

            vault_out=$(invoke_vault "$tool_name" "$tool_args")

            # RT-40: isError detection
            local first_line="${vault_out%%$'\n'*}"
            local is_error=false
            if jq -e 'type == "object" and has("error_code")' >/dev/null 2>&1 <<< "$first_line"; then
                is_error=true
            fi

            # Inject _rate_limit into successful responses
            local display_out="$vault_out"
            if [[ "$is_error" == "false" ]]; then
                display_out=$(_rl_inject_field "$vault_out" "$rl_remaining" "$rl_reset" "$rl_limit")
            fi

            content_json=$(printf '%s' "$display_out" | \
                jq -Rsc --argjson ie "$is_error" \
                '{"content":[{"type":"text","text":.}],"isError":$ie}')
            rpc_ok "$id" "$content_json"
            ;;

        ping)
            rpc_ok "$id" "{}"
            ;;

        *)
            # V161: truncate method before embedding to prevent argv overflow
            local _method_trunc="${method:0:200}"
            rpc_err "$id" -32601 "Method not found: ${_method_trunc}"
            ;;

    esac
}

# ── Session state ──────────────────────────────────────────────────────────
INITIALIZED=false
INIT_REQUESTED=false

# ── Main read loop ─────────────────────────────────────────────────────────
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue

    # RT-35: 1 MiB message size limit before jq parsing
    if (( ${#line} > MAX_MSG )); then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Message too large (max 1 MiB)"}}\n'
        continue
    fi

    # RT-37: guard against unexpected handle_message failure with set -e
    handle_message "$line" || \
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal bridge error — handler failed unexpectedly"}}\n'
done
