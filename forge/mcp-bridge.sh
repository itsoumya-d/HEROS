#!/usr/bin/env bash
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ forge/mcp-bridge.sh — MCP stdio server for forge                        │
# │                                                                          │
# │ Architecture: this script owns the JSON-RPC 2.0 session loop.           │
# │ The forge binary handles all schema analysis logic.                      │
# │                                                                          │
# │ Why a bridge? Zero v0.1.x lacks world.in (stdin reading). V34 gap.     │
# │                                                                          │
# │ Requires: jq ≥ 1.6, forge binary in PATH or alongside this script      │
# │ Security: docs/threat-model.md V34, V35, RT-33, RT-34, RT-35           │
# └──────────────────────────────────────────────────────────────────────────┘

set -euo pipefail

# Predictable UTF-8 for jq — prevents locale-dependent parsing edge cases
# RT-382 port: LC_ALL overrides LANG in the glibc locale hierarchy — set LC_ALL directly
# so an operator's pre-existing LC_ALL cannot affect tr/awk locale-sensitive paths.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Clean shutdown on signal: avoid mid-write corruption of JSON-RPC output stream
# V170 port: PIPE added — client closing its stdin sends SIGPIPE to the bridge's stdout writes;
# without a trap, bridge exits with status 141 (unhandled signal) instead of 0.
# Internal pipeline SIGPIPEs go to subshells (bash forks pipeline builtins), not here.
trap 'exit 0' TERM INT PIPE

readonly MCP_PROTOCOL="2025-11-25"
readonly MAX_MSG=1048576  # 1 MiB — mcp-security-spec.md §5.1

# ── Locate forge binary ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_BIN=""
if command -v forge >/dev/null 2>&1; then
    FORGE_BIN="$(command -v forge)"
elif [[ -x "${SCRIPT_DIR}/forge" ]]; then
    FORGE_BIN="${SCRIPT_DIR}/forge"
fi

if [[ -z "$FORGE_BIN" ]]; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"forge binary not found in PATH or script directory"}}\n'
    exit 1
fi

# ── Dependency check ──────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"jq >= 1.6 required but not found in PATH"}}\n'
    exit 1
fi
# RT-311: python3 required for HMAC computation and constant-time comparison (removes openssl/xxd dependency)
# Only required when HEROS_API_KEY is set — anonymous mode runs without python3.
if [[ -n "${HEROS_API_KEY:-}" ]] && ! command -v python3 >/dev/null 2>&1; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"python3 required for API key authentication but not found in PATH. Install python3 or unset HEROS_API_KEY for anonymous mode."}}\n'
    exit 1
fi

# MED-1 FIX: HMAC auth startup validation — matches ledger bridge RT-463/RT-603 checks.
# Runs only when auth is enabled (HEROS_API_KEY set).
if [[ -n "${HEROS_API_KEY:-}" ]]; then
    if [[ -z "${HEROS_DATA_DIR:-}" ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_DATA_DIR must be set when HEROS_API_KEY is configured"}}\n'
        exit 1
    fi
    if [[ ! -d "${HEROS_DATA_DIR}" ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_DATA_DIR does not exist or is not a directory — check operator configuration"}}\n'
        exit 1
    fi
    if [[ ${#HEROS_HMAC_SEED} -lt 32 ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_HMAC_SEED is too short (minimum 32 characters required). Generate with: openssl rand -hex 32"}}\n'
        exit 1
    fi
    if [[ ! -f "${HEROS_DATA_DIR}/.heros-keys" ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_DATA_DIR/.heros-keys not found — create API keys first with: ledger/key-gen.sh"}}\n'
        exit 1
    fi
fi

# ── Load manifest ─────────────────────────────────────────────────────────
MANIFEST="${SCRIPT_DIR}/mcp-manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"mcp-manifest.json not found alongside mcp-bridge.sh"}}\n'
    exit 1
fi
# V132 port: validate manifest JSON at startup — malformed manifest causes set -e death on SERVER_VERSION extraction
if ! jq -e . >/dev/null 2>&1 < "$MANIFEST"; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"mcp-manifest.json is not valid JSON — check file integrity"}}\n'
    exit 1
fi
# V134 port: validate manifest tools array — null or missing tools key causes set -e on first tools/list
if ! jq -e '.tools | type == "array"' >/dev/null 2>&1 < "$MANIFEST"; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"mcp-manifest.json: tools field must be an array"}}\n'
    exit 1
fi

SERVER_VERSION=$(jq -r '.version // "0.0.0"' "$MANIFEST")
# V199 port: cap SERVER_VERSION to prevent E2BIG when passed as --arg sv to jq in the
# initialize response. No legitimate version string needs more than 64 chars.
SERVER_VERSION="${SERVER_VERSION:0:64}"

# ── Rate limiting (token bucket, v0.2 spec — docs/rate-limit-spec.md) ─────
declare -A _RL_BUCKETS

# V135 port: non-integer env var causes arithmetic error under set -e → silent startup death
_rl_clamp() {
    local v="$1" max="$2"
    # RT-387 port: leading zeros (e.g. "010") pass ^[0-9]+$ but bash evaluates as octal;
    # "019" is invalid octal and causes arithmetic error that kills the bridge at startup.
    # ^(0|[1-9][0-9]*)$ rejects all leading-zero values before they reach arithmetic.
    [[ "$v" =~ ^(0|[1-9][0-9]*)$ ]] || { printf '[forge-config] rate limit "%s" is not a valid non-negative integer (no leading zeros); using default 1\n' "$v" >&2; v=1; }
    # RT-391 port: values with >10 digits risk silent int64 overflow in multiplication.
    (( ${#v} > 10 )) && { printf '[forge-config] rate limit "%s" exceeds maximum digit length (10); using default 1\n' "$v" >&2; v=1; }
    if (( v > max )); then echo "$max"; else echo "$v"; fi
}

RL_ANALYZE_IP_LIMIT=$(_rl_clamp "${FORGE_RATE_ANALYZE_IP:-200}" 2000)
readonly RL_ANALYZE_IP_LIMIT
RL_ANALYZE_ORG_LIMIT=$(_rl_clamp "${FORGE_RATE_ANALYZE_ORG:-500}" 5000)
readonly RL_ANALYZE_ORG_LIMIT

# RT-298 port: SECONDS is bash uptime (not Unix epoch). One-time offset for real timestamps.
_RL_EPOCH_OFFSET=$(( $(date +%s) - SECONDS ))
readonly _RL_EPOCH_OFFSET

RL_REMAINING=0
RL_RESET_AT=0
_rl_check() {
    local tool="$1" dim="$2" val="$3" limit="$4" burst="$5"
    # RT-287 port: limit=0 is deny-all (operator-disabled)
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

    # RT-284 port: compute added directly to avoid refill_per_sec truncation cascade
    local elapsed=$(( now - last ))
    local added=$(( elapsed * limit * 100 / 3600 ))
    tokens=$(( tokens + added ))
    [[ $tokens -gt $cap ]] && tokens=$cap

    local tokens_needed=$(( 100 - (tokens % 100) ))
    # RT-298 port: real Unix epoch timestamp via _RL_EPOCH_OFFSET
    RL_RESET_AT=$(( _RL_EPOCH_OFFSET + now + tokens_needed * 3600 / (limit * 100) ))

    if (( tokens >= 100 )); then
        tokens=$(( tokens - 100 ))
        _RL_BUCKETS[$key]="${tokens}:${now}"
        # RT-295 port: remaining AFTER consuming (not before)
        RL_REMAINING=$(( tokens / 100 ))
        return 0
    else
        _RL_BUCKETS[$key]="${tokens}:${now}"
        RL_REMAINING=0
        return 1
    fi
}

_rl_rate_limited_json() {
    local tool="$1" dim="$2" limit="$3"
    # RT-301 port: use RL_RESET_AT for accurate retry_after_seconds
    local now_epoch=$(( _RL_EPOCH_OFFSET + SECONDS ))
    local retry=$(( RL_RESET_AT - now_epoch ))
    (( retry < 1 )) && retry=1
    jq -cn --arg tool "$tool" --arg dim "$dim" --argjson rs "$retry" \
        '{"error_code":"RATE_LIMITED","error":"Too many requests. Retry after the specified delay.","retry_after_seconds":$rs,"limit_type":$dim,"limit_tool":$tool,"retryable":true}'
}

_rl_inject_field() {
    local json="$1" remaining="$2" reset_at="$3" limit="$4"
    # RT-314 port: printf avoids echo interpreting "-n"/"-e" in $json as flags (same class as V142)
    jq -c --argjson rem "$remaining" --argjson rat "$reset_at" --argjson lim "$limit" \
        '. + {"_rate_limit":{"remaining":$rem,"reset_at":$rat,"limit":$lim,"window":"per_hour"}}' \
        <<< "$json" 2>/dev/null || printf '%s\n' "$json"
}

# ── Auth v0.2 (V44) — shared key namespace with ledger bridge ────────────────
# Keys generated via ledger/key-gen.sh. forge_analyze is always scope=ro.
# HEROS_API_KEY: if set, all tool calls require a valid key from .heros-keys.
# HEROS_DATA_DIR: directory containing .heros-keys and .heros-audit.
HEROS_DATA_DIR="${HEROS_DATA_DIR:-.}"

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

    # RT-135: awk field-exact lookup; RT-134: first match exits (duplicate key_id safe)
    local record
    record=$(awk -v kid="${key_id}" '$1 == kid { print; exit }' \
        "${HEROS_DATA_DIR}/.heros-keys" 2>/dev/null) || true
    [[ -z "$record" ]] && return 1

    local _kid stored_scope stored_org stored_hash _created stored_revoked
    read -r _kid stored_scope stored_org stored_hash _created stored_revoked <<< "$record"
    # RT-283 port: strip trailing whitespace (bash read puts remainder in last var including \r from CRLF)
    # HIGH-2 FIX: %%[[:space:]]* strips from first whitespace onward (ledger bridge V421 pattern);
    # //[[:space:]]/ removed ALL whitespace globally and could produce false non-revoked on "1 x" → "1x".
    stored_revoked="${stored_revoked%%[[:space:]]*}"

    [[ "$stored_revoked" == "1" ]] && return 2

    # RT-132: empty HMAC seed rejects all validation
    [[ -z "${HEROS_HMAC_SEED:-}" ]] && return 1

    # RT-311/RT-128: compute + compare in one python3 call — seed via env (never CLI arg).
    # Single spawn avoids computed_hash appearing in /proc/cmdline; compare_digest prevents timing oracle.
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

    # Fail closed: any stored_scope value other than ro or rw is rejected (RT-256 port).
    # V140 note: malformed stored_scope → rc=1 (INVALID_API_KEY), not rc=3 (INSUFFICIENT_SCOPE),
    # to give operators accurate diagnostics (integrity error vs legitimate scope mismatch).
    case "$stored_scope" in
        ro) [[ "$required_scope" == "rw" ]] && return 3 ;;
        rw) ;;
        *) return 1 ;;
    esac

    # RT-257 port: validate stored_org format before returning — defense-in-depth
    [[ ! "$stored_org" =~ ^org_[0-9a-f]{8}$ ]] && return 1

    echo "$stored_org"
    return 0
}

_audit() {
    local key_id="$1" scope="$2" tool="$3" org_id="${4:-}"
    local epoch
    epoch=$(date +%s 2>/dev/null || echo "0")
    printf '%s %s %s %s %s\n' "$epoch" "$key_id" "$scope" "$tool" "$org_id" \
        >> "${HEROS_DATA_DIR}/.heros-audit" 2>/dev/null || true
}

# _audit_fail rc — append one failed-auth record to .heros-audit-failed (V50)
# rc: 1=INVALID_API_KEY 2=API_KEY_REVOKED 3=INSUFFICIENT_SCOPE
_audit_fail() {
    local rc="$1"
    local epoch
    epoch=$(date +%s 2>/dev/null || echo "0")
    printf '%s FAIL rc=%s\n' "$epoch" "$rc" \
        >> "${HEROS_DATA_DIR}/.heros-audit-failed" 2>/dev/null || true
}

# ── Session state (global) ────────────────────────────────────────────────
INITIALIZED=false
# V119 port: separate flag gates notifications/initialized so it cannot bypass initialize
INIT_REQUESTED=false

# ── V39: decision_required approval nonces ───────────────────────────────
# Stores pending approvals: nonce → expires_at (SECONDS + 300 TTL).
# Single-use: cleared on first valid redemption. Prevents replay.
declare -A _PENDING_APPROVALS

# Generate a 16-hex-char nonce (64 bits) from /dev/urandom.
# RT-106: fallback chain handles minimal containers where od is absent.
# Returns non-zero and emits nothing if no hex tool is available.
_generate_nonce() {
    if command -v od >/dev/null 2>&1; then
        dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
    elif command -v xxd >/dev/null 2>&1; then
        dd if=/dev/urandom bs=8 count=1 2>/dev/null | xxd -l 8 -p | tr -d ' \n'
    elif command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 8
    else
        return 1
    fi
}

# ── JSON-RPC response builders ────────────────────────────────────────────
# All responses built via jq — no printf format-string injection risk (V35)

rpc_ok() {
    # RT-302 port: pipe $2 via stdin to avoid argv size limit (MAX_ARG_STRLEN = 131072)
    # for large results (e.g. tools/list with many tools, large forge_analyze responses).
    printf '%s' "$2" | jq -cn --argjson _id "$1" \
        '{"jsonrpc":"2.0","id":$_id,"result":input}'
}

rpc_err() {
    jq -cn --argjson _id "$1" --argjson _c "$2" --arg _m "$3" \
        '{"jsonrpc":"2.0","id":$_id,"error":{"code":$_c,"message":$_m}}'
}

# ── tools/list — reshape mcp-manifest.json into MCP wire format ───────────
tools_list_response() {
    # RT-63: include outputSchema per Principle 1.2; RT-64: include title per Principle 1.5
    jq -c '{tools:[.tools[]|{
        name,
        title,
        description,
        inputSchema:.input_schema,
        outputSchema:.output_schema,
        annotations
    }]}' "$MANIFEST"
}

# ── invoke_forge — map tools/call to forge CLI ────────────────────────────
# RT-33: arguments extracted via jq; command built as bash array (no injection).
# Schema content is converted from JSON multiline strings to forge's | format.
invoke_forge() {
    local name="$1"
    local args_json="$2"
    local result

    case "$name" in
        forge_analyze)
            local from_schema to_schema
            if ! from_schema=$(jq -re '.from_schema' <<< "$args_json" 2>/dev/null); then
                echo '{"error_code":"MISSING_FLAG","flag":"from_schema","retryable":true,"error":"from_schema is required"}'
                return
            fi
            if ! to_schema=$(jq -re '.to_schema' <<< "$args_json" 2>/dev/null); then
                echo '{"error_code":"MISSING_FLAG","flag":"to_schema","retryable":true,"error":"to_schema is required"}'
                return
            fi

            # RT-419: cap schema size before binary invocation. RT-435: use byte count
            # (wc -c), not codepoint count (${#}), because MAX_ARG_STRLEN is a BYTE limit.
            # Multi-byte UTF-8 chars (e.g. 4-byte emoji) pass a codepoint cap of 65536 while
            # occupying up to 262144 bytes, causing E2BIG with a misleading EXEC_FAILED
            # (retryable:true). Byte count is accurate regardless of encoding.
            local from_bytes to_bytes
            from_bytes=$(printf '%s' "$from_schema" | wc -c 2>/dev/null) || from_bytes=0
            to_bytes=$(printf '%s' "$to_schema" | wc -c 2>/dev/null) || to_bytes=0
            if (( from_bytes > 65536 )); then
                echo '{"error_code":"INVALID_INPUT","field":"from_schema","retryable":false,"error":"from_schema exceeds 64 KiB limit (65536 bytes); split into smaller schemas"}'
                return
            fi
            if (( to_bytes > 65536 )); then
                echo '{"error_code":"INVALID_INPUT","field":"to_schema","retryable":false,"error":"to_schema exceeds 64 KiB limit (65536 bytes); split into smaller schemas"}'
                return
            fi

            # RT-43: reject literal pipe characters in schema content.
            # forge_mini treats | as a line separator (same as \n, byte 124 in scanLine).
            # A | in the raw schema would inject extra TABLE/COLUMN lines into the analysis,
            # allowing an attacker to add fake tables or columns to the risk report.
            # Legitimate Forge Schema Format has no valid use for | within a line.
            case "$from_schema" in
                *\|*) echo '{"error_code":"INVALID_INPUT","field":"from_schema","retryable":true,"error":"from_schema must not contain pipe characters (|); use newlines to separate TABLE/COLUMN lines"}'; return ;;
            esac
            case "$to_schema" in
                *\|*) echo '{"error_code":"INVALID_INPUT","field":"to_schema","retryable":true,"error":"to_schema must not contain pipe characters (|); use newlines to separate TABLE/COLUMN lines"}'; return ;;
            esac

            # Convert multiline schema strings to forge's pipe-delimited inline format.
            # tr '\n' '|' replaces newlines with |; tr -d '\r' strips Windows CR.
            local from_inline to_inline
            from_inline=$(printf '%s' "$from_schema" | tr '\n' '|' | tr -d '\r')
            to_inline=$(printf '%s' "$to_schema" | tr '\n' '|' | tr -d '\r')

            local cmd=("$FORGE_BIN" analyze --from "$from_inline" --to "$to_inline")

            # Optional request_id for idempotency key echoing
            # RT-432: cap request_id before passing as argv — no length check would let a
            # 1 MiB agent-supplied value exceed MAX_ARG_STRLEN (131072), causing E2BIG in the
            # forge binary execve. A legitimate idempotency key is a UUID (36 chars) or similar;
            # 512 bytes is generous. Oversized values are permanent failures → INVALID_INPUT.
            local request_id
            if request_id=$(jq -re '.request_id' <<< "$args_json" 2>/dev/null) && [[ -n "$request_id" ]]; then
                if (( ${#request_id} > 512 )); then
                    echo '{"error_code":"INVALID_INPUT","field":"request_id","retryable":false,"error":"request_id exceeds 512-byte limit; use a UUID or shorter idempotency key"}'
                    return
                fi
                cmd+=(--request-id "$request_id")
            fi

            # V158: capture binary stderr via mktemp so forge crashes are visible in operator logs.
            local _forge_etmp _forge_stderr
            if _forge_etmp=$(mktemp 2>/dev/null); then
                result=$("${cmd[@]}" 2>"$_forge_etmp") || true
                _forge_stderr=$(tr -cd '[:print:][:space:]' < "$_forge_etmp" 2>/dev/null)
                # RT-325 port: || true prevents rare rm failure (immutable file, disk error) from killing
                # invoke_forge via set -e, which would return -32603 instead of the actual forge response.
                rm -f "$_forge_etmp" || true
                [[ -n "$_forge_stderr" ]] && printf '[forge-bin] %s\n' "$_forge_stderr" >&2
            else
                result=$("${cmd[@]}" 2>/dev/null) || true
                printf '[forge-warn] mktemp failed; binary stderr not captured for this call\n' >&2
            fi
            # RT-111 P3: reject whitespace-only or non-object output (e.g. binary crash prints to stderr).
            # [[ -n "$result" ]] accepted whitespace strings and arrays; jq type check is strict.
            if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$result"; then
                result='{"error_code":"EXEC_FAILED","retryable":true,"error":"forge produced invalid or empty output"}'
            fi
            # RT-314 class: printf avoids echo interpreting leading "-n"/"-e" in result as flags
            printf '%s\n' "$result"
            ;;

        *)
            echo '{"error_code":"UNKNOWN_TOOL","retryable":false,"error":"No such tool"}'
            # RT-297 port: return to prevent fall-through to audit call with unvalidated tool name
            return
            ;;
    esac
}

# ── handle_message — dispatch one JSON-RPC 2.0 message ────────────────────
handle_message() {
    local line="$1"

    # Validate JSON
    if ! jq -e . >/dev/null 2>&1 <<< "$line"; then
        rpc_err "null" -32700 "Parse error: message is not valid JSON"
        return
    fi

    # RT-38: reject non-object JSON-RPC (arrays and primitives are invalid)
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$line"; then
        rpc_err "null" -32600 "Invalid Request: message must be a JSON object, not an array or primitive"
        return
    fi

    local id method
    id=$(jq -c '.id // null' <<< "$line")
    method=$(jq -r '.method // ""' <<< "$line")

    # RT-431: guard oversized id values — jq's --argjson passes id as an execve argv string;
    # Linux MAX_ARG_STRLEN = 131072 bytes; a >4KB id cannot be a legitimate MCP id (UUIDs are
    # 38 chars, integers at most ~20 chars). Reject early with id:null (safe — "null" is 4 bytes).
    if (( ${#id} > 4096 )); then
        rpc_err "null" -32600 "Invalid Request: id field must not exceed 4096 bytes"
        return
    fi

    # Notifications: absent "id" key means no response expected
    if ! jq -e 'has("id")' >/dev/null 2>&1 <<< "$line"; then
        # V119 port: only accept notifications/initialized after initialize was processed
        [[ "$method" == "notifications/initialized" && "$INIT_REQUESTED" == "true" ]] && INITIALIZED=true
        return
    fi

    # RT-292 port: reject requests with missing or wrong jsonrpc version field
    if ! jq -e '.jsonrpc == "2.0"' >/dev/null 2>&1 <<< "$line"; then
        rpc_err "$id" -32600 "Invalid Request: jsonrpc field must be \"2.0\""
        return
    fi

    # V154 port: non-string method must return -32600 (Invalid Request), not -32601 (Method not found)
    if ! jq -e '.method | type == "string"' >/dev/null 2>&1 <<< "$line"; then
        rpc_err "$id" -32600 "Invalid Request: method must be a string"
        return
    fi

    case "$method" in

        initialize)
            # V7e: reject re-initialization (use INIT_REQUESTED not INITIALIZED — V119 port)
            if [[ "$INIT_REQUESTED" == "true" ]]; then
                rpc_err "$id" -32002 "Already initialized — re-initialization rejected"
                return
            fi
            INIT_REQUESTED=true
            INITIALIZED=true
            # RT-285 port: build via jq --arg to prevent SERVER_VERSION injection into JSON
            local _init_result
            _init_result=$(jq -cn --arg pv "$MCP_PROTOCOL" --arg sv "$SERVER_VERSION" \
                '{"protocolVersion":$pv,"capabilities":{"tools":{}},"serverInfo":{"name":"forge","version":$sv}}')
            rpc_ok "$id" "$_init_result"
            ;;

        tools/list)
            # RT-310: spec compliance — tools/list requires initialization
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
            local tool_name tool_args forge_out first_line is_error content_json
            tool_name=$(jq -r '.params.name // ""' <<< "$line")
            tool_args=$(jq -c '.params.arguments // {}' <<< "$line")

            if [[ -z "$tool_name" ]]; then
                rpc_err "$id" -32602 "Invalid params: missing tool name in params.name"
                return
            fi
            # RT-219 port: reject tool names with control chars or non-identifier bytes
            # Prevents audit log injection via embedded newline in tool_name.
            if [[ ! "$tool_name" =~ ^[a-z][a-z0-9_]*$ ]]; then
                rpc_err "$id" -32602 "Invalid params: tool name must match [a-z][a-z0-9_]+"
                return
            fi

            # ── Rate limiting (docs/rate-limit-spec.md) ───────────────────
            # forge_analyze has both per-IP and per-org limits.
            # In stdio mode, single client = "session" for both dimensions.
            local rl_ok=true rl_dim="" rl_limit=0
            local rl_remaining=0 rl_reset=0
            if [[ "$tool_name" == "forge_analyze" ]]; then
                # Check per-IP limit first (lower of the two)
                if ! _rl_check "$tool_name" "ip" "session" "$RL_ANALYZE_IP_LIMIT" 10; then
                    rl_ok=false; rl_dim="per_ip"; rl_limit=$RL_ANALYZE_IP_LIMIT
                else
                    # Capture IP remaining before org check overwrites RL_REMAINING
                    local ip_remaining=$RL_REMAINING ip_reset=$RL_RESET_AT
                    if ! _rl_check "${tool_name}_org" "org" "session" "$RL_ANALYZE_ORG_LIMIT" 10; then
                        rl_ok=false; rl_dim="per_org"; rl_limit=$RL_ANALYZE_ORG_LIMIT
                    else
                        # Both passed — use min remaining (the binding constraint for this agent)
                        if (( ip_remaining <= RL_REMAINING )); then
                            rl_remaining=$ip_remaining; rl_reset=$ip_reset; rl_limit=$RL_ANALYZE_IP_LIMIT
                        else
                            rl_remaining=$RL_REMAINING; rl_reset=$RL_RESET_AT; rl_limit=$RL_ANALYZE_ORG_LIMIT
                        fi
                    fi
                fi
            fi
            if [[ "$rl_ok" == "false" ]]; then
                local rl_json
                rl_json=$(_rl_rate_limited_json "$tool_name" "$rl_dim" "$rl_limit")
                content_json=$(jq -cn --arg text "$rl_json" \
                    '{"content":[{"type":"text","text":$text}],"isError":true}')
                rpc_ok "$id" "$content_json"
                return
            fi

            # ── V44 auth guard (RT-136: placed before invoke_forge so V39 nonce ──
            # ── logic never runs for unauthenticated callers)              ──
            local _forge_api_key="${HEROS_API_KEY:-}"
            local _forge_key_id="" _forge_key_scope="" _forge_org_id="" _forge_auth_ok=false
            if [[ -n "$_forge_api_key" ]]; then
                local _forge_auth_rc=0
                _forge_org_id=$(_validate_api_key "$_forge_api_key" "ro") || _forge_auth_rc=$?
                case $_forge_auth_rc in
                    2)
                        _audit_fail 2
                        content_json=$(jq -cn \
                            '{"content":[{"type":"text","text":"{\"error_code\":\"API_KEY_REVOKED\",\"retryable\":false,\"hint\":\"Rotate key via `ledger key rotate`\"}"}],"isError":true}')
                        rpc_ok "$id" "$content_json"; return ;;
                    3)
                        _audit_fail 3
                        content_json=$(jq -cn \
                            '{"content":[{"type":"text","text":"{\"error_code\":\"INSUFFICIENT_SCOPE\",\"retryable\":false,\"hint\":\"forge_analyze requires ro or rw scope\"}"}],"isError":true}')
                        rpc_ok "$id" "$content_json"; return ;;
                    0)
                        _forge_auth_ok=true
                        IFS='_' read -r _ _forge_key_scope _forge_key_id _ <<< "$_forge_api_key" ;;
                    *)
                        _audit_fail 1
                        content_json=$(jq -cn \
                            '{"content":[{"type":"text","text":"{\"error_code\":\"INVALID_API_KEY\",\"retryable\":false,\"hint\":\"Obtain a valid key via `ledger key create --scope ro`\"}"}],"isError":true}')
                        rpc_ok "$id" "$content_json"; return ;;
                esac
            fi

            forge_out=$(invoke_forge "$tool_name" "$tool_args")

            # RT-68: forge binary uses nested {"error":{"code","message","retryable"}} format.
            # Normalize to flat {"error_code","error","retryable"} so isError detection (which
            # checks has("error_code")) and agents reading output_schema both see one consistent format.
            # RT-342: printf avoids echo interpreting "-n"/"-e" in $forge_out as flags
            forge_out=$(jq -c \
                'if type == "object" and ((.error | type) == "object")
                 then {error_code:.error.code, error:.error.message, retryable:.error.retryable}
                 else . end' <<< "$forge_out" 2>/dev/null || printf '%s\n' "$forge_out")

            # V39: human_acknowledgment_token nonce protocol (docs/forge-v02-spec.md)
            # Guards decision_required: true responses — agents must present a bridge-issued nonce
            # (obtained from a prior analysis response) to prove a human reviewed the risk.
            if [[ "$tool_name" == "forge_analyze" ]]; then
                local hat=""
                hat=$(jq -re '.human_acknowledgment_token // empty' <<< "$tool_args" 2>/dev/null) || true

                if [[ -n "$hat" ]]; then
                    # Agent provided a token — verify it.
                    # RT-109: validate format before using as associative array key.
                    # hat="@" or hat="*" would expand to special bash array subscripts,
                    # allowing unset to wipe all _PENDING_APPROVALS entries. Nonces are
                    # exactly 16 lowercase hex chars — reject anything else immediately.
                    if ! [[ "$hat" =~ ^[0-9a-f]{16}$ ]]; then
                        forge_out='{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Token format invalid. Expected 16 hex chars."}'
                    elif [[ -z "${_PENDING_APPROVALS[$hat]+x}" ]]; then
                        # Token not found (never issued or already used)
                        forge_out='{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Token not recognized or already used. Re-run forge_analyze (no token) to obtain a fresh approval_nonce."}'
                    else
                        local hat_expires="${_PENDING_APPROVALS[$hat]}"
                        if (( SECONDS > hat_expires )); then
                            # Token expired — remove and reject
                            unset "_PENDING_APPROVALS[$hat]"
                            forge_out='{"error_code":"INVALID_ACKNOWLEDGMENT_TOKEN","retryable":true,"error":"Approval token expired (5-min TTL). Re-run forge_analyze (no token) to obtain a fresh approval_nonce."}'
                        else
                            # Valid token — single-use: consume it, inject proceed_ok
                            unset "_PENDING_APPROVALS[$hat]"
                            forge_out=$(jq -c '. + {"proceed_ok":true,"decision_required":false}' \
                                <<< "$forge_out" 2>/dev/null || printf '%s\n' "$forge_out")
                        fi
                    fi
                elif jq -e '.decision_required == true' >/dev/null 2>&1 <<< "$forge_out"; then
                    # No token but decision_required: true — issue nonce
                    # RT-106: guard against empty nonce if no hex tool is available.
                    local nonce expires_at
                    nonce=$(_generate_nonce 2>/dev/null) || nonce=""
                    # RT-399: validate exact 16-hex-char format — empty-check alone misses partial
                    # dd reads (< 8 bytes from /dev/urandom) which produce short nonces that pass
                    # the empty check but later fail the redemption format check, causing deadlock.
                    if [[ ! "$nonce" =~ ^[0-9a-f]{16}$ ]]; then
                        forge_out='{"error_code":"EXEC_FAILED","retryable":true,"error":"Bridge: nonce generation failed or produced invalid output. Cannot gate decision_required migration."}'
                    else
                        expires_at=$(( SECONDS + 300 ))
                        _PENDING_APPROVALS[$nonce]="$expires_at"
                        forge_out=$(jq -c \
                            --arg n "$nonce" \
                            --arg p "Migration has data loss or critical risk. Human sign-off required. Pass this nonce as human_acknowledgment_token after the human principal approves." \
                            '. + {"approval_nonce":$n,"approval_prompt":$p}' \
                            <<< "$forge_out" 2>/dev/null || printf '%s\n' "$forge_out")
                    fi
                fi
            fi

            # RT-40: set isError if forge returned an error response
            first_line="${forge_out%%$'\n'*}"
            is_error=false
            if jq -e 'type == "object" and has("error_code")' >/dev/null 2>&1 <<< "$first_line"; then
                is_error=true
            fi

            # Inject _rate_limit into successful forge responses
            # RT-307: use $rl_limit (binding constraint's limit) not hardcoded IP limit
            local display_out="$forge_out"
            if [[ "$is_error" == "false" ]]; then
                display_out=$(_rl_inject_field "$forge_out" "$rl_remaining" "$rl_reset" "$rl_limit")
            fi

            content_json=$(jq -cn --arg text "$display_out" --argjson ie "$is_error" \
                '{"content":[{"type":"text","text":$text}],"isError":$ie}')
            rpc_ok "$id" "$content_json"

            # Audit authenticated dispatches
            if [[ "$_forge_auth_ok" == "true" ]]; then
                _audit "$_forge_key_id" "$_forge_key_scope" "$tool_name" "$_forge_org_id"
            fi
            ;;

        ping)
            rpc_ok "$id" "{}"
            ;;

        *)
            # V161 port: truncate method before embedding to prevent argv overflow for ~1MiB method strings
            local _method_trunc="${method:0:200}"
            rpc_err "$id" -32601 "Method not found: ${_method_trunc}"
            ;;

    esac
}

# ── Main read loop ─────────────────────────────────────────────────────────
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue

    # RT-35: 1 MiB message size limit before jq parsing
    if (( ${#line} > MAX_MSG )); then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Message too large (max 1 MiB)"}}\n'
        continue
    fi

    # RT-37: prevent bridge termination if handler exits non-zero
    handle_message "$line" || \
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal bridge error — handler failed unexpectedly"}}\n'
done
