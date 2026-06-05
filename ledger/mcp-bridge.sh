#!/usr/bin/env bash
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ ledger/mcp-bridge.sh — MCP stdio server for ledger                      │
# │                                                                          │
# │ Architecture: this script owns the JSON-RPC 2.0 session loop.           │
# │ The ledger binary handles all accounting logic.                          │
# │                                                                          │
# │ Why a bridge? Zero v0.1.x lacks world.in (stdin reading). The language  │
# │ only exposes world.out/world.err for I/O. Stdin reading requires a      │
# │ future Zero release (V34 gap). This bridge fills that gap today.        │
# │                                                                          │
# │ Requires: jq ≥ 1.6, ledger binary in PATH or alongside this script     │
# │ Security: docs/threat-model.md V34, V35, RT-33, RT-34, RT-35           │
# └──────────────────────────────────────────────────────────────────────────┘

set -euo pipefail

# RT-382: LC_ALL overrides LANG in the glibc locale hierarchy — set LC_ALL directly
# so an operator's pre-existing LC_ALL cannot affect tr/jq locale-sensitive paths.
export LC_ALL=C.UTF-8

# Clean shutdown on signal: avoid mid-write corruption of the JSON-RPC output stream
# V170: PIPE added — client closing its stdin sends SIGPIPE to the bridge's stdout writes;
# without a trap, bridge exits with status 141 (unhandled signal) instead of 0.
# Internal pipeline SIGPIPEs go to subshells (bash forks pipeline builtins), not here.
trap 'exit 0' TERM INT PIPE

readonly MCP_PROTOCOL="2025-11-25"
readonly MAX_MSG=1048576  # 1 MiB — per mcp-security-spec.md §5.1

# ── Locate ledger binary ───────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_BIN=""
if command -v ledger >/dev/null 2>&1; then
    LEDGER_BIN="$(command -v ledger)"
elif [[ -x "${SCRIPT_DIR}/ledger" ]]; then
    LEDGER_BIN="${SCRIPT_DIR}/ledger"
fi

if [[ -z "$LEDGER_BIN" ]]; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"ledger binary not found in PATH or script directory"}}\n'
    exit 1
fi

# ── Dependency check ──────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"jq >= 1.6 required but not found in PATH"}}\n'
    exit 1
fi
# RT-256: python3 is the HMAC dependency for API key auth. Only required when HEROS_API_KEY
# is configured — unauthenticated deployments (anonymous mode) have no dependency on python3.
# Checking here only when auth is active avoids blocking minimal containers without python3.
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
# V132: validate manifest JSON at startup — malformed manifest causes set -e death on first tools/list
if ! jq -e . >/dev/null 2>&1 < "$MANIFEST"; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"mcp-manifest.json is not valid JSON — check file integrity"}}\n'
    exit 1
fi
# V134: validate manifest tools array — null or missing tools key causes set -e on first tools/list
if ! jq -e '.tools | type == "array"' >/dev/null 2>&1 < "$MANIFEST"; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"mcp-manifest.json: tools field must be an array"}}\n'
    exit 1
fi

SERVER_VERSION=$(jq -r '.version // "0.0.0"' "$MANIFEST")
# V199: cap SERVER_VERSION to prevent E2BIG when passed as --arg sv to jq in the
# initialize response. No legitimate version string needs more than 64 chars.
SERVER_VERSION="${SERVER_VERSION:0:64}"

# RT-455: when HEROS_API_KEY is set, HEROS_DATA_DIR must be a readable directory.
# Without this check, a missing/empty HEROS_DATA_DIR causes every auth attempt to return
# INVALID_API_KEY (file not found on /.heros-keys), misleading the operator into
# thinking their key is wrong rather than their data dir configuration is wrong.
if [[ -n "${HEROS_API_KEY:-}" ]]; then
    if [[ -z "${HEROS_DATA_DIR:-}" ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_DATA_DIR must be set when HEROS_API_KEY is configured"}}\n'
        exit 1
    fi
    if [[ ! -d "${HEROS_DATA_DIR}" ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_DATA_DIR does not exist or is not a directory — check operator configuration"}}\n'
        exit 1
    fi
    # RT-463: weak HMAC seed allows key forgery via brute force of the HMAC keyspace.
    # Minimum 32 characters; use openssl rand -hex 32 (64 hex chars) for 256-bit security.
    # RT-603: "256 bits" applies when using hex encoding (each char = 4 bits); a 32-char
    # all-ASCII string is 256 bits only if chars are single bytes — hex is the safer choice.
    if [[ ${#HEROS_HMAC_SEED} -lt 32 ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_HMAC_SEED is too short (minimum 32 characters required). Generate with: openssl rand -hex 32"}}\n'
        exit 1
    fi
    # RT-466: if .heros-keys is absent, every auth attempt returns INVALID_API_KEY —
    # misleading the operator into thinking their key is wrong rather than the registry
    # file is missing. Fail fast with a clear "run ledger key create" instruction.
    if [[ ! -f "${HEROS_DATA_DIR}/.heros-keys" ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"HEROS_DATA_DIR/.heros-keys not found — create API keys first with: ledger key create"}}\n'
        exit 1
    fi
fi

# ── Rate limiting (token bucket, v0.2 spec — docs/rate-limit-spec.md) ─────
# Buckets: associative array keyed "tool:dim:value" → "tokens×100:last_epoch"
# Tokens stored ×100 (integer fixed-point) for one decimal of precision.
# Limits in tokens/hour; refill = limit/3600 tokens per second.
# Operator overrides via env vars (clamped to 10× default ceiling).
declare -A _RL_BUCKETS

# RT-298: SECONDS is bash uptime (not Unix epoch). Compute offset once so RL_RESET_AT
# values exported to agents are real Unix timestamps, not bridge-uptime seconds.
# RT-472: date +%s failure (command missing or non-numeric output) causes set -e to kill
# the bridge silently at startup; || echo 0 prevents this while still allowing the bridge
# to start (reset_at timestamps degrade to bridge-uptime-relative values, not real epochs).
_RL_EPOCH_OFFSET=$(( $(date +%s 2>/dev/null || echo 0) - SECONDS ))
readonly _RL_EPOCH_OFFSET

_rl_clamp() {
    local v="$1" max="$2"
    # V135: non-integer env var causes bash arithmetic error → set -e → silent startup death
    # RT-387: leading zeros (e.g. "010") pass ^[0-9]+$ but bash evaluates them as octal; "019"
    # is invalid octal and causes an arithmetic error that kills the bridge at startup.
    # ^(0|[1-9][0-9]*)$ rejects all leading-zero values before they reach arithmetic.
    [[ "$v" =~ ^(0|[1-9][0-9]*)$ ]] || { printf '[ledger-config] rate limit "%s" is not a valid non-negative integer (no leading zeros); using default 1\n' "$v" >&2; v=1; }
    # RT-391: bash uses int64 arithmetic (max ~9.2×10^18, 19 digits); values with >10 digits
    # risk silent overflow in _rl_check multiplication. All practical limits fit in 10 digits
    # (max ceiling 60000); reject anything longer before it reaches arithmetic.
    (( ${#v} > 10 )) && { printf '[ledger-config] rate limit "%s" exceeds maximum digit length (10); using default 1\n' "$v" >&2; v=1; }
    if (( v > max )); then echo "$max"; else echo "$v"; fi
}

RL_REG_IP_LIMIT=$(_rl_clamp "${LEDGER_RATE_REGISTER_IP:-10}" 100)
readonly RL_REG_IP_LIMIT
RL_CREATE_ORG_LIMIT=$(_rl_clamp "${LEDGER_RATE_INVOICE_CREATE_ORG:-1000}" 10000)
readonly RL_CREATE_ORG_LIMIT
RL_LIST_ORG_LIMIT=$(_rl_clamp "${LEDGER_RATE_INVOICE_LIST_ORG:-3000}" 30000)
readonly RL_LIST_ORG_LIMIT
RL_COUNT_ORG_LIMIT=$(_rl_clamp "${LEDGER_RATE_INVOICE_COUNT_ORG:-6000}" 60000)
readonly RL_COUNT_ORG_LIMIT
RL_TOOLS_LIST_IP_LIMIT=$(_rl_clamp "${LEDGER_RATE_TOOLS_LIST_IP:-60}" 600)
readonly RL_TOOLS_LIST_IP_LIMIT
# V128: initialize rate limit (30/hr per-IP per mcp-security-spec.md §4)
RL_INIT_IP_LIMIT=$(_rl_clamp "${LEDGER_RATE_INITIALIZE_IP:-30}" 300)
readonly RL_INIT_IP_LIMIT

# ── Auth v0.2 (V44) ──────────────────────────────────────────────────────────
# HEROS_DATA_DIR: directory containing .heros-keys, .heros-audit, .ledger-data
# HEROS_HMAC_SEED: HMAC key for API key verification (operator-set; must be random)
# HEROS_API_KEY: if set, all requests require a valid key from .heros-keys
HEROS_DATA_DIR="${HEROS_DATA_DIR:-.}"

# RT-246: warn to stderr when running without authentication — no audit trail in this mode
if [[ -z "${HEROS_API_KEY:-}" ]]; then
    echo "[ledger-security] HEROS_API_KEY unset — anonymous mode active. No audit logging. Set HEROS_API_KEY to enforce authentication and enable audit trail." >&2
fi

# V155: warn when data dir defaults to CWD in auth mode — key/audit files in a world-writable
# directory (e.g. /tmp) expose them to modification by other local users.
if [[ "$HEROS_DATA_DIR" == "." && -n "${HEROS_API_KEY:-}" ]]; then
    echo "[ledger-security] WARNING: HEROS_DATA_DIR not set — key and audit files will be written to the current working directory. Set HEROS_DATA_DIR to a private, non-world-writable path." >&2
fi

# V158: HEROS_API_KEY set but HEROS_HMAC_SEED unset — all authenticated calls silently fail
# with INVALID_API_KEY (HMAC check returns 1 before computation). Warn early so operators
# can diagnose immediately rather than debugging mysterious auth rejections.
if [[ -n "${HEROS_API_KEY:-}" && -z "${HEROS_HMAC_SEED:-}" ]]; then
    echo "[ledger-security] WARNING: HEROS_API_KEY is set but HEROS_HMAC_SEED is unset — all authenticated calls will be rejected. Set HEROS_HMAC_SEED to a random secret for HMAC key verification." >&2
fi

# V258: warn at startup if .heros-audit exceeds 100 MB. The audit log grows unboundedly
# (~2 GB/month at moderate load); this alert fires before disk exhaustion so operators
# can rotate manually. No automatic rotation: rotating audit data without consent is a
# compliance concern.
if [[ -n "${HEROS_API_KEY:-}" && -f "${HEROS_DATA_DIR}/.heros-audit" ]]; then
    _v258_audit_sz=$(stat -c %s "${HEROS_DATA_DIR}/.heros-audit" 2>/dev/null || echo 0)
    if (( _v258_audit_sz > 104857600 )); then
        echo "[ledger-audit-warn] .heros-audit exceeds 100 MB (${_v258_audit_sz} bytes); consider rotating to prevent disk exhaustion. Rename or truncate .heros-audit and restart the bridge." >&2
    fi
    unset _v258_audit_sz
fi

# V318: fail-closed symlink check — a symlink replacing a security-critical data file
# redirects writes to an attacker-chosen target. Check at startup before any tool calls.
# .heros-audit: warn (operators may legitimately symlink audit to a centralized log).
# .heros-keys/.ledger-data/.ledger-invoices/.ledger-data.lock/.ledger-invoices.lock: fatal (redirecting these is always malicious).
# V395/V397: lock files opened with 200> (O_TRUNC) — a symlink here truncates the target at lock-acquire time.
for _v318_f in ".heros-keys" ".ledger-data" ".ledger-invoices" ".ledger-data.lock" ".ledger-invoices.lock"; do
    if [[ -L "${HEROS_DATA_DIR}/${_v318_f}" ]]; then
        # V321: use jq --arg to safely embed path (may contain JSON-special chars: \, ", etc).
        jq -cn --arg p "${HEROS_DATA_DIR}/${_v318_f}" \
            '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":("Security: "+$p+" is a symlink — data files must be regular files to prevent write-redirect attacks. Remove the symlink and restart.")}}'
        exit 1
    fi
done
unset _v318_f
# RT-648: check audit files (warn-only — operators may legitimately symlink audit to centralized log).
for _v318_warn in ".heros-audit" ".heros-audit-failed"; do
    if [[ -L "${HEROS_DATA_DIR}/${_v318_warn}" ]]; then
        echo "[ledger-security] WARNING: ${HEROS_DATA_DIR}/${_v318_warn} is a symlink; audit writes will follow the link. Ensure the target path is trusted and operator-controlled." >&2
    fi
done
unset _v318_warn

# _rl_check tool dim value limit_per_hour burst_capacity
# Returns 0 (allow) or 1 (deny), sets RL_REMAINING and RL_RESET_AT globals.
RL_REMAINING=0
RL_RESET_AT=0
_rl_check() {
    local tool="$1" dim="$2" val="$3" limit="$4" burst="$5"
    # RT-257: limit=0 is deny-all — lets operators disable a tool entirely via env var
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

    # RT-284: compute added directly — avoids refill_per_sec=limit*100/3600 truncating
    # to 0 for low limits (e.g. 10/hr → 0 → clamped to 1 → 36/hr effective instead of 10/hr).
    local elapsed=$(( now - last ))
    local added=$(( elapsed * limit * 100 / 3600 ))
    tokens=$(( tokens + added ))
    [[ $tokens -gt $cap ]] && tokens=$cap

    local tokens_needed=$(( 100 - (tokens % 100) ))
    # RT-298: add epoch offset so reset_at is a real Unix timestamp (SECONDS is bridge uptime)
    RL_RESET_AT=$(( _RL_EPOCH_OFFSET + now + tokens_needed * 3600 / (limit * 100) ))

    if (( tokens >= 100 )); then
        tokens=$(( tokens - 100 ))
        _RL_BUCKETS[$key]="${tokens}:${now}"
        # RT-295: compute remaining AFTER consuming so agents see calls left, not calls left+1
        RL_REMAINING=$(( tokens / 100 ))
        return 0
    else
        _RL_BUCKETS[$key]="${tokens}:${now}"
        RL_REMAINING=0
        return 1
    fi
}

# _rl_rate_limited_json tool dim — emit RATE_LIMITED JSON with retry_after
_rl_rate_limited_json() {
    local tool="$1" dim="$2"
    # RT-301: use RL_RESET_AT (real epoch from _rl_check) for accurate retry_after_seconds.
    # 3600/limit over-estimates when bucket has partial tokens; RL_RESET_AT is exact.
    local now_epoch=$(( _RL_EPOCH_OFFSET + SECONDS ))
    local retry=$(( RL_RESET_AT - now_epoch ))
    (( retry < 1 )) && retry=1
    jq -cn --arg tool "$tool" --arg dim "$dim" --argjson rs "$retry" \
        '{"error_code":"RATE_LIMITED","error":"Too many requests. Retry after the specified delay.","retry_after_seconds":$rs,"limit_type":$dim,"limit_tool":$tool,"retryable":true}'
}

# _rl_inject_field success_json remaining reset_at limit — add _rate_limit to JSON
_rl_inject_field() {
    local json="$1" remaining="$2" reset_at="$3" limit="$4"
    # RT-314: printf avoids echo interpreting "-n"/"-e" in $json as flags (same class as V142)
    jq -c --argjson rem "$remaining" --argjson rat "$reset_at" --argjson lim "$limit" \
        '. + {"_rate_limit":{"remaining":$rem,"reset_at":$rat,"limit":$lim,"window":"per_hour"}}' \
        <<< "$json" 2>/dev/null || printf '%s\n' "$json"
}

# _validate_api_key key required_scope
# Parses heros_<scope>_<key_id>_<secret>, looks up key_id in .heros-keys,
# verifies HMAC-SHA256(HEROS_HMAC_SEED, key_id:secret), checks scope.
# On success: prints org_id to stdout, returns 0.
# Returns 1 (INVALID_API_KEY), 2 (API_KEY_REVOKED), 3 (INSUFFICIENT_SCOPE).
# Requires: python3. Depends on HEROS_DATA_DIR, HEROS_HMAC_SEED.
_validate_api_key() {
    local key="$1" required_scope="${2:-ro}"
    local prefix scope key_id secret
    IFS='_' read -r prefix scope key_id secret <<< "$key"

    # Format: heros_<ro|rw>_<32-hex-key-id>_<32-hex-secret>
    if [[ "$prefix" != "heros" ]] || \
       [[ ! "$scope" =~ ^(ro|rw)$ ]] || \
       [[ ! "$key_id" =~ ^[0-9a-f]{32}$ ]] || \
       [[ ! "$secret" =~ ^[0-9a-f]{32}$ ]]; then
        return 1
    fi

    # RT-364: require regular file before awk — FIFO/directory/missing file would block or error;
    # -f follows symlinks, so symlink→FIFO also fails. Absent file returns INVALID_API_KEY directly.
    [[ ! -f "${HEROS_DATA_DIR}/.heros-keys" ]] && return 1

    # RT-135: awk field-exact lookup prevents any substring match and handles duplicates (first wins)
    local record
    record=$(awk -v kid="${key_id}" '$1 == kid { print; exit }' \
        "${HEROS_DATA_DIR}/.heros-keys" 2>/dev/null) || true
    [[ -z "$record" ]] && return 1

    # Record: key_id scope org_id hmac_hash created_epoch revoked
    local _kid stored_scope stored_org stored_hash _created stored_revoked
    read -r _kid stored_scope stored_org stored_hash _created stored_revoked <<< "$record"
    # RT-283: bash `read` assigns all remaining text (including trailing whitespace) to the last
    # variable. Strip from first whitespace onward: "1   " → "1", "1 extra_field" → "1".
    # V421: //[[:space:]]/ removed ALL whitespace ("1 extra" → "1extra" ≠ "1" → bypass).
    # %%[[:space:]]* strips longest suffix starting at first whitespace character.
    stored_revoked="${stored_revoked%%[[:space:]]*}"

    [[ "$stored_revoked" == "1" ]] && return 2

    # RT-132: empty HMAC seed degrades security — reject before computing
    [[ -z "${HEROS_HMAC_SEED:-}" ]] && return 1

    # RT-256/RT-128: compute + compare in one python3 call — seed via env (never CLI arg).
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

    # Scope: stored scope must satisfy required scope for this operation.
    # Fail closed: any stored_scope value other than ro or rw is rejected (RT-256 fix).
    # V140: malformed stored_scope (not ro/rw) is a key record integrity error → rc=1 (INVALID_API_KEY),
    # not rc=3 (INSUFFICIENT_SCOPE), to give operators accurate diagnostics.
    case "$stored_scope" in
        ro) [[ "$required_scope" == "rw" ]] && return 3 ;;
        rw) ;;
        *)  return 1 ;;
    esac

    # RT-257: validate org_id format before returning — defense-in-depth against
    # malformed .heros-keys entries reaching the audit log or downstream callers.
    [[ ! "$stored_org" =~ ^org_[0-9a-f]{8}$ ]] && return 1

    echo "$stored_org"
    return 0
}

# _audit key_id scope tool org_id — append one authenticated-call record to .heros-audit
_audit() {
    local key_id="$1" scope="$2" tool="$3" org_id="${4:-}"
    local epoch
    epoch=$(date +%s 2>/dev/null || echo "0")
    printf '%s %s %s %s %s\n' "$epoch" "$key_id" "$scope" "$tool" "$org_id" \
        >> "${HEROS_DATA_DIR}/.heros-audit" || \
        echo "[ledger-audit-warn] audit write failed — check permissions/disk on ${HEROS_DATA_DIR}/.heros-audit" >&2
}

# _audit_fail rc — append one failed-auth record to .heros-audit-failed (V50)
# rc: 1=INVALID_API_KEY 2=API_KEY_REVOKED 3=INSUFFICIENT_SCOPE
_audit_fail() {
    local rc="$1"
    local epoch
    epoch=$(date +%s 2>/dev/null || echo "0")
    printf '%s FAIL rc=%s\n' "$epoch" "$rc" \
        >> "${HEROS_DATA_DIR}/.heros-audit-failed" || \
        echo "[ledger-audit-warn] audit-failed write failed — check permissions/disk on ${HEROS_DATA_DIR}/.heros-audit-failed" >&2
}

# ── Session state (global — mutated from handle_message) ──────────────────
INITIALIZED=false
# V119 fix: separate flag for initialize request processed — gates notifications/initialized
INIT_REQUESTED=false

# ── JSON-RPC response builders ─────────────────────────────────────────────
# All responses built via jq — no printf format-string injection risk (V35)

rpc_ok() {
    # $1 = JSON id value (null, number, or quoted string as raw JSON)
    # $2 = result (raw JSON value)
    # RT-287/RT-302: pipe $2 via stdin (not --argjson) to avoid argv size limit for large results
    # (tools_list with many tools, or large invoice_list responses wrapped in content_json)
    printf '%s' "$2" | jq -cn --argjson _id "$1" \
        '{"jsonrpc":"2.0","id":$_id,"result":input}'
}

rpc_err() {
    # $1 = JSON id value  $2 = error code (integer)  $3 = message string
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

# ── _exec_ledger — run ledger binary with structured error on empty output ──
# $1 = "allow_empty" to permit empty stdout (invoice list with no invoices).
# $2..N = command to run.
# Empty stdout + non-zero exit → STORE_READ_FAILED (storage I/O failure).
# Empty stdout + zero exit + allow_empty → pass through (valid empty response).
# Empty stdout + zero exit + !allow_empty → EXEC_FAILED (unexpected).
_exec_ledger() {
    local allow_empty="${1:-}" ; shift
    local _out _rc=0
    # RT-254: capture binary stderr to surface panics/errors; sanitize before logging to operator
    local _etmp _eout=""
    if _etmp=$(mktemp 2>/dev/null); then
        # RT-527: timeout 60 prevents a hung binary from holding the flock lock indefinitely
        # in multi-bridge deployments. Exit code 124 on timeout → _rc=124 → STORE_READ_FAILED.
        _out=$(timeout 60 "$@" 2>"$_etmp") || _rc=$?
        # V193: cap stderr capture at 64KB — a runaway binary writing 100MB stderr would
        # otherwise load 100MB into a bash variable and block on a 100MB stderr write.
        # head -c 65536 reads only the first 64KB from the temp file (O(64KB) disk I/O).
        # RT-617: exclude \r/\v/\f — [:space:] includes carriage return (0x0D) which enables
        # terminal cursor-to-col-0 overwrite in operator logs if binary emits adversarial stderr.
        _eout=$(head -c 65536 "$_etmp" | tr -cd '[:print:]\t\n' 2>/dev/null) || true
        # RT-325: || true prevents rare rm failure (e.g., immutable file) from killing _exec_ledger
        # via set -e, which would return -32603 instead of the actual ledger response.
        rm -f "$_etmp" || true
        [[ -n "$_eout" ]] && printf '[ledger-bin] %s\n' "$_eout" >&2
    else
        # RT-313: mktemp failed — run without stderr capture (diagnostic blind spot, not a security issue)
        printf '[ledger-warn] mktemp failed — binary stderr will not be logged for this call\n' >&2
        _out=$("$@" 2>/dev/null) || _rc=$?
    fi
    if [[ -z "$_out" ]]; then
        if [[ $_rc -ne 0 ]]; then
            echo '{"error_code":"STORE_READ_FAILED","error":"ledger exited with an error and produced no output — possible storage I/O failure","retryable":false}'
        elif [[ "$allow_empty" != "allow_empty" ]]; then
            echo '{"error_code":"EXEC_FAILED","retryable":true,"error":"ledger produced no output"}'
        fi
    else
        # V142: printf avoids echo interpreting leading "-n"/"-e" in binary output as flags
        printf '%s\n' "$_out"
    fi
}

# ── _ledger_entropy — 8 random hex chars for ID generation ───────────────
# Same fallback chain as _generate_nonce (od → xxd → openssl → fail-closed).
# Bridge provides entropy so the ELF64 binary (no std.rand) can generate unique IDs.
_ledger_entropy() {
    local ent=""
    # RT-619: add hex-char validation — length alone doesn't rule out aberrant tool output.
    if ent=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | head -c8) && [[ ${#ent} -eq 8 ]] && [[ $ent =~ ^[0-9a-f]{8}$ ]]; then
        printf '%s' "$ent"; return 0
    fi
    if ent=$(xxd -l4 -p /dev/urandom 2>/dev/null | head -c8) && [[ ${#ent} -eq 8 ]] && [[ $ent =~ ^[0-9a-f]{8}$ ]]; then
        printf '%s' "$ent"; return 0
    fi
    if ent=$(openssl rand -hex 4 2>/dev/null | head -c8) && [[ ${#ent} -eq 8 ]] && [[ $ent =~ ^[0-9a-f]{8}$ ]]; then
        printf '%s' "$ent"; return 0
    fi
    return 1
}

# ── _ledger_timestamp — current Unix epoch seconds ────────────────────────
_ledger_timestamp() {
    local ts
    ts=$(date +%s 2>/dev/null) || ts="0"
    printf '%s' "$ts"
}

# ── invoke_ledger — map a tools/call to ledger CLI ────────────────────────
# RT-33: arguments extracted via jq (never via string concatenation into eval).
# Command arrays built element-by-element — no shell word-splitting attack.
# V44: if HEROS_API_KEY is set, validates key before dispatch; audits on success.
# State-passing design: bridge reads .ledger-data/.ledger-invoices, passes to binary
# via args; binary outputs _new_data/_new_invoice_json; bridge writes back to files.
# ELF64 Zero binary has no file I/O — all persistence is owned by this bridge.
invoke_ledger() {
    local name="$1"
    local args_json="$2"

    # ── V44 auth guard ────────────────────────────────────────────────────────
    # When HEROS_API_KEY is set, every call is authenticated against .heros-keys.
    # Unauthenticated calls are allowed only when HEROS_API_KEY is unset (migration mode).
    local _api_key="${HEROS_API_KEY:-}"
    local _key_id="" _key_scope="" _org_id=""
    if [[ -n "$_api_key" ]]; then
        local _required_scope="ro"
        case "$name" in
            ledger_register|ledger_invoice_create) _required_scope="rw" ;;
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
                IFS='_' read -r _ _key_scope _key_id _ <<< "$_api_key"
                case "$name" in
                    ledger_register|ledger_invoice_create|ledger_invoice_list|ledger_invoice_count)
                        _audit "$_key_id" "$_key_scope" "$name" "$_org_id"
                        ;;
                esac
                ;;
            *)
                _audit_fail 1
                echo '{"error_code":"INVALID_API_KEY","retryable":false,"hint":"Obtain a valid key via `ledger key create --scope rw`"}'
                return ;;
        esac
    fi

    case "$name" in
        ledger_register)
            local org_name
            # RT-452: validate type == "string" before passing to binary.
            if ! org_name=$(jq -re '.org_name | if type == "string" then . else error end' <<< "$args_json" 2>/dev/null); then
                echo '{"error_code":"MISSING_FLAG","flag":"org_name","retryable":true,"error":"org_name is required and must be a string"}'
                return
            fi
            # V261: cap field length to prevent CLI E2BIG and unbounded file growth.
            if (( ${#org_name} > 256 )); then
                echo '{"error_code":"INVALID_PARAM","flag":"org_name","retryable":false,"error":"org_name exceeds 256 characters"}'
                return
            fi
            # ORG_EXISTS fast path: check without lock first (common case — org already registered).
            local _data_file="${HEROS_DATA_DIR}/.ledger-data"
            if [[ -f "$_data_file" ]]; then
                local _existing_org
                _existing_org=$(cat "$_data_file" 2>/dev/null) || {
                    echo '{"error_code":"STORE_READ_FAILED","error":"Failed to read org data","retryable":false}'
                    return
                }
                # MED-2 FIX: del(._new_data) strips internal fields before returning to agent;
                # mirrors the del at the normal write path — defense-in-depth for interrupted writes.
                jq -c 'del(._new_data) + {"error_code":"ORG_EXISTS","retryable":false,"status":"ok"}' \
                    <<< "$_existing_org" 2>/dev/null || \
                    echo '{"error_code":"ORG_EXISTS","retryable":false,"status":"ok","error":"Org already registered"}'
                return
            fi
            # New org: pre-generate entropy before acquiring lock (no file dependency).
            local _ent _ts _raw_reg
            if ! _ent=$(_ledger_entropy); then
                echo '{"error_code":"STORE_WRITE_FAILED","error":"Failed to generate entropy for org ID","retryable":false}'
                return
            fi
            _ts=$(_ledger_timestamp)
            # CRIT-01/CRIT-02: hold exclusive lock across existence re-check, binary call, and atomic write.
            # Double-checked locking: fast path above avoids lock overhead in the common case (org exists).
            {
                # RT-525: flock -w 30 prevents indefinite block when another bridge holds the lock.
                # Returns LOCK_TIMEOUT (retryable) instead of hanging forever.
                flock -w 30 -x 200 || {
                    echo '{"error_code":"LOCK_TIMEOUT","error":"Store lock unavailable; another bridge process may be busy. Retry in a few seconds.","retryable":true}'
                    return
                }
                if [[ -f "$_data_file" ]]; then
                    # Another process registered between our fast-path check and lock acquisition.
                    local _existing_org2
                    _existing_org2=$(cat "$_data_file" 2>/dev/null) || {
                        echo '{"error_code":"STORE_READ_FAILED","error":"Failed to read org data","retryable":false}'
                        return
                    }
                    # MED-2 FIX: del(._new_data) strips internal fields (double-checked lock path).
                    jq -c 'del(._new_data) + {"error_code":"ORG_EXISTS","retryable":false,"status":"ok"}' \
                        <<< "$_existing_org2" 2>/dev/null || \
                        echo '{"error_code":"ORG_EXISTS","retryable":false,"status":"ok","error":"Org already registered"}'
                    return
                fi
                _raw_reg=$(_exec_ledger "" "$LEDGER_BIN" register \
                    --org-name "$org_name" \
                    --entropy "$_ent" \
                    --timestamp "$_ts") || true
                # P3-03: validate binary output is JSON before extracting fields.
                if ! jq -e . >/dev/null 2>&1 <<< "$_raw_reg"; then
                    echo '{"error_code":"EXEC_FAILED","error":"Binary produced invalid JSON","retryable":false}'
                    return
                fi
                # CRIT-02: atomic write via temp file + mv to prevent partial-write corruption on kill/crash.
                local _new_org_data
                if _new_org_data=$(jq -re '._new_data' <<< "$_raw_reg" 2>/dev/null) && [[ -n "$_new_org_data" ]]; then
                    local _tmpfile
                    if _tmpfile=$(mktemp "${_data_file}.XXXXXX" 2>/dev/null); then
                        if printf '%s\n' "$_new_org_data" > "$_tmpfile" 2>/dev/null && \
                           mv -f "$_tmpfile" "$_data_file" 2>/dev/null; then
                            :
                        else
                            rm -f "$_tmpfile" 2>/dev/null
                            echo "[ledger-warn] failed to atomically write .ledger-data" >&2
                        fi
                    else
                        printf '%s\n' "$_new_org_data" > "$_data_file" 2>/dev/null || \
                            echo "[ledger-warn] failed to write .ledger-data (mktemp unavailable)" >&2
                    fi
                fi
            } 200>"${HEROS_DATA_DIR}/.ledger-data.lock" || {
                # RT-622: lock file redirect failure (permissions, disk full) was previously
                # an undifferentiated -32603. Now surfaces as STORE_LOCK_FAILED with context.
                echo '{"error_code":"STORE_LOCK_FAILED","error":"Failed to create data lock file; check directory permissions and disk space","retryable":true}'
                return
            }
            # Return response without internal _new_data field.
            jq -c 'del(._new_data)' <<< "$_raw_reg" 2>/dev/null || printf '%s\n' "$_raw_reg"
            ;;

        ledger_invoice_create)
            local to amount currency idem memo
            # RT-452: type guard on all string-only fields.
            if ! to=$(jq -re '.to | if type == "string" then . else error end' <<< "$args_json" 2>/dev/null); then
                echo '{"error_code":"MISSING_FLAG","flag":"to","retryable":true,"error":"to is required and must be a string"}'; return
            fi
            # V261: length caps prevent CLI E2BIG and invoice store bloat.
            if (( ${#to} > 256 )); then
                echo '{"error_code":"INVALID_PARAM","flag":"to","retryable":false,"error":"to exceeds 256 characters"}'; return
            fi
            # RT-547: require JSON number type — string "true"/arrays/objects must not reach the binary.
            if ! amount=$(jq -re '.amount | if type == "number" then . else error end' <<< "$args_json" 2>/dev/null); then
                echo '{"error_code":"MISSING_FLAG","flag":"amount","retryable":true,"error":"amount is required and must be a number"}'; return
            fi
            if ! currency=$(jq -re '.currency | if type == "string" then . else error end' <<< "$args_json" 2>/dev/null); then
                echo '{"error_code":"MISSING_FLAG","flag":"currency","retryable":true,"error":"currency is required and must be a string"}'; return
            fi
            if (( ${#currency} > 8 )); then
                echo '{"error_code":"INVALID_PARAM","flag":"currency","retryable":false,"error":"currency exceeds 8 characters"}'; return
            fi
            if ! idem=$(jq -re '.idempotency_key | if type == "string" then . else error end' <<< "$args_json" 2>/dev/null); then
                echo '{"error_code":"MISSING_FLAG","flag":"idempotency_key","retryable":true,"error":"idempotency_key is required and must be a string"}'; return
            fi
            if (( ${#idem} > 128 )); then
                echo '{"error_code":"INVALID_PARAM","flag":"idempotency_key","retryable":false,"error":"idempotency_key exceeds 128 characters"}'; return
            fi
            # NO_ORG_REGISTERED: bridge checks file existence (ELF64 binary has no file I/O).
            local _inv_data_file="${HEROS_DATA_DIR}/.ledger-data"
            local _inv_file="${HEROS_DATA_DIR}/.ledger-invoices"
            if [[ ! -f "$_inv_data_file" ]]; then
                echo '{"error_code":"NO_ORG_REGISTERED","retryable":true,"error":"Call ledger_register first to provision an org"}'
                return
            fi
            # Pre-generate entropy + build command array before lock (minimize lock hold time).
            local _ent2 _ts2
            if ! _ent2=$(_ledger_entropy); then
                echo '{"error_code":"STORE_WRITE_FAILED","error":"Failed to generate entropy for invoice ID","retryable":false}'
                return
            fi
            _ts2=$(_ledger_timestamp)
            # Build command array — each arg is a separate element (no injection risk).
            local cmd=("$LEDGER_BIN" invoice create
                --to "$to"
                --amount "$amount"
                --currency "$currency"
                --idempotency-key "$idem"
                --entropy "$_ent2"
                --timestamp "$_ts2")
            # RT-452: non-string memo treated as absent. V261: cap at 512 chars.
            if memo=$(jq -re '.memo | if type == "string" then . else error end' <<< "$args_json" 2>/dev/null) && [[ -n "$memo" ]]; then
                if (( ${#memo} > 512 )); then
                    echo '{"error_code":"INVALID_PARAM","flag":"memo","retryable":false,"error":"memo exceeds 512 characters"}'; return
                fi
                cmd+=(--memo "$memo")
            fi
            # CRIT-01: hold exclusive lock across idempotency check + binary call + append to prevent
            # duplicate invoices when two bridge processes share the same HEROS_DATA_DIR.
            local _raw_inv _new_inv_json
            {
                # RT-525: flock -w 30 prevents indefinite block on contested lock (multi-bridge).
                flock -w 30 -x 200 || {
                    echo '{"error_code":"LOCK_TIMEOUT","error":"Store lock unavailable; another bridge process may be busy. Retry in a few seconds.","retryable":true}'
                    return
                }
                # Idempotency check inside lock: look up key scoped to this org.
                # RT-636: add org_id guard — without it, two orgs using the same idempotency_key
                # on a shared bridge would collide: Org B receives Org A's invoice as the response.
                # (.org_id // "") matches legacy records (no org_id field) when _org_id is also "".
                if [[ -f "$_inv_file" ]]; then
                    local _existing_inv
                    _existing_inv=$(jq -ce --arg k "$idem" --arg oid "$_org_id" \
                        'select(.idempotency_key == $k and (.org_id // "") == $oid)' \
                        "$_inv_file" 2>/dev/null | head -1) || true
                    if [[ -n "$_existing_inv" ]]; then
                        jq -c '. + {"_idempotent":true}' <<< "$_existing_inv" 2>/dev/null || \
                            printf '%s\n' "$_existing_inv"
                        return
                    fi
                fi
                # Call binary for validation and ID generation (inside lock: result appended before lock release).
                _raw_inv=$(_exec_ledger "" "${cmd[@]}") || true
                # P3-03: validate binary output is JSON before extracting fields.
                if ! jq -e . >/dev/null 2>&1 <<< "$_raw_inv"; then
                    echo '{"error_code":"EXEC_FAILED","error":"Binary produced invalid JSON","retryable":false}'
                    return
                fi
                # Append _new_invoice_json to .ledger-invoices inside lock.
                if _new_inv_json=$(jq -re '._new_invoice_json' <<< "$_raw_inv" 2>/dev/null) && [[ -n "$_new_inv_json" ]]; then
                    # RT-548: inject org_id into the stored record so invoice_list can filter
                    # by org. _org_id is empty when no HEROS_API_KEY is set (unauthenticated).
                    _new_inv_json=$(jq -c --arg oid "$_org_id" '. + {"org_id":$oid}' \
                        <<< "$_new_inv_json" 2>/dev/null) || {
                        echo '{"error_code":"EXEC_FAILED","error":"Failed to inject org_id into invoice record","retryable":false}'
                        return
                    }
                    # RT-518: surface append failure as STORE_WRITE_FAILED (retryable) — previously
                    # logged-and-continued, enabling agent to receive a success response for an invoice
                    # that was never persisted, making retry look like a duplicate (duplicate payment risk).
                    # Retry is safe: idempotency_key is checked on re-entry; if this append failed,
                    # the key is not in the file, so the next attempt generates and persists a new invoice.
                    if ! printf '%s\n' "$_new_inv_json" >> "$_inv_file" 2>/dev/null; then
                        echo "[ledger-warn] failed to append to .ledger-invoices" >&2
                        echo '{"error_code":"STORE_WRITE_FAILED","error":"Failed to persist invoice to store; retry is safe — idempotency_key is rechecked on re-entry.","retryable":true}'
                        return
                    fi
                fi
            } 200>"${HEROS_DATA_DIR}/.ledger-invoices.lock" || {
                # RT-622: lock file redirect failure → actionable error (not undifferentiated -32603).
                echo '{"error_code":"STORE_LOCK_FAILED","error":"Failed to create invoice lock file; check directory permissions and disk space","retryable":true}'
                return
            }
            # Return response without internal _new_invoice_json field.
            # RT-641: inject org_id into response for consistency with idempotent responses
            # (which return the stored record that already includes org_id from RT-548 fix).
            jq -c --arg oid "$_org_id" 'del(._new_invoice_json) + {"org_id":$oid}' \
                <<< "$_raw_inv" 2>/dev/null || printf '%s\n' "$_raw_inv"
            ;;

        ledger_invoice_list)
            # Bridge-internal: ELF64 binary has no file I/O; list handled here directly.
            local _list_data_file="${HEROS_DATA_DIR}/.ledger-data"
            local _list_inv_file="${HEROS_DATA_DIR}/.ledger-invoices"
            if [[ ! -f "$_list_data_file" ]]; then
                echo '{"error_code":"NO_ORG_REGISTERED","retryable":true,"error":"Call ledger_register first to provision an org"}'
                return
            fi
            # V266: pagination — limit (1-1000, default 100) and offset (>=0, default 0).
            # Prevents unbounded responses: 100K invoices × 1.5KB/invoice = 150 MB without limit.
            local _lim _off
            _lim=$(jq -re '.limit // 100 | if type == "number" and . == floor and . >= 1 and . <= 1000 then . else error end' <<< "$args_json" 2>/dev/null) || {
                echo '{"error_code":"INVALID_PARAM","flag":"limit","retryable":false,"error":"limit must be an integer between 1 and 1000 (default: 100)"}'; return
            }
            _off=$(jq -re '.offset // 0 | if type == "number" and . == floor and . >= 0 then . else error end' <<< "$args_json" 2>/dev/null) || {
                echo '{"error_code":"INVALID_PARAM","flag":"offset","retryable":false,"error":"offset must be a non-negative integer (default: 0)"}'; return
            }
            if [[ ! -f "$_list_inv_file" ]]; then
                echo '{"invoices":[],"count":0,"total_count":0,"has_more":false,"status":"ok"}'
                return
            fi
            # V313: filter by org_id before pagination — prevents cross-org invoice visibility
            # in multi-tenant deployments. Legacy records without org_id field treated as org_id=""
            # via (.org_id // ""), so unauthenticated invoices visible only to unauthenticated callers.
            jq -sc --argjson lim "$_lim" --argjson off "$_off" --arg oid "$_org_id" \
                '[.[] | select((.org_id // "") == $oid)] |
                 (length) as $total |
                 .[$off:$off+$lim] as $page |
                 {"invoices":$page,"count":($page|length),"total_count":$total,"has_more":($off+$lim < $total),"status":"ok"}' \
                "$_list_inv_file" 2>/dev/null || \
                    echo '{"error_code":"STORE_READ_FAILED","error":"Failed to read invoice store","retryable":false}'
            ;;

        ledger_invoice_count)
            # Bridge-internal: count is a line count on .ledger-invoices.
            local _cnt_data_file="${HEROS_DATA_DIR}/.ledger-data"
            local _cnt_inv_file="${HEROS_DATA_DIR}/.ledger-invoices"
            if [[ ! -f "$_cnt_data_file" ]]; then
                echo '{"error_code":"NO_ORG_REGISTERED","retryable":true,"error":"Call ledger_register first to provision an org"}'
                return
            fi
            local _cnt=0
            if [[ -f "$_cnt_inv_file" ]]; then
                # P2-02: jq -sc parses JSONL (matching invoice_list semantics).
                # RT-542: surface jq failure (corrupt store) as STORE_READ_FAILED — not || echo 0
                # which previously masked data integrity failures by returning count=0 silently.
                # V327: filter by org_id to match invoice_list semantics (RT-635 added org_id scoping
                # to invoice_list; invoice_count must use the same filter for consistent total_count).
                if ! _cnt=$(jq -sc --arg oid "$_org_id" '[.[] | select((.org_id // "") == $oid)] | length' "$_cnt_inv_file" 2>/dev/null); then
                    echo '{"error_code":"STORE_READ_FAILED","error":"Failed to parse invoice store; file may be corrupt","retryable":false}'
                    return
                fi
                [[ "$_cnt" =~ ^[0-9]+$ ]] || _cnt=0
            fi
            # P3-05: use jq for JSON construction (consistent with rest of bridge; eliminates interpolation).
            jq -cn --argjson cnt "$_cnt" '{"count":$cnt,"status":"ok"}'
            ;;

        *)
            echo '{"error_code":"UNKNOWN_TOOL","retryable":false,"error":"No such tool"}'
            # RT-297: return here to prevent audit log injection via tool name with embedded newline.
            # Unknown tools are not dispatches; the audit records authorized calls only.
            return
            ;;
    esac

    # Audit every authenticated dispatch (including binary-level failures — RT-128 audit note)
    # Authenticated known-tool dispatches are audited immediately after auth succeeds.
    # That captures early validation/storage failures without auditing unknown tool names.
}

# ── handle_message — dispatch one JSON-RPC 2.0 message ────────────────────
handle_message() {
    local line="$1"

    # Validate JSON (also catches empty lines)
    if ! jq -e . >/dev/null 2>&1 <<< "$line"; then
        rpc_err "null" -32700 "Parse error: message is not valid JSON"
        return
    fi

    # RT-38: reject non-object JSON-RPC (arrays and primitives are not valid requests/notifications)
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$line"; then
        rpc_err "null" -32600 "Invalid Request: message must be a JSON object, not an array or primitive"
        return
    fi

    # Extract id as raw JSON (preserves type: null, number, string)
    local id method
    id=$(jq -c '.id // null' <<< "$line")
    method=$(jq -r '.method // ""' <<< "$line")

    # RT-389: guard oversized id values — jq's --argjson passes id as an execve argv string;
    # Linux MAX_ARG_STRLEN = 131072 bytes; a >4KB id cannot be a legitimate MCP id (UUIDs are
    # 38 chars, integers at most ~20 chars). Reject early with id:null (safe — "null" is 4 bytes).
    if (( ${#id} > 4096 )); then
        rpc_err "null" -32600 "Invalid Request: id field must not exceed 4096 bytes"
        return
    fi

    # Notifications: absent "id" key means no response expected
    if ! jq -e 'has("id")' >/dev/null 2>&1 <<< "$line"; then
        # V119 fix: only accept notifications/initialized after initialize was processed
        # to prevent bypassing the initialize handshake via notification spoofing
        [[ "$method" == "notifications/initialized" && "$INIT_REQUESTED" == "true" ]] && INITIALIZED=true
        return  # No response for notifications
    fi

    # RT-292: reject requests missing or mismatching jsonrpc version (mcp-security-spec.md §5.2)
    if ! jq -e '.jsonrpc == "2.0"' >/dev/null 2>&1 <<< "$line"; then
        rpc_err "$id" -32600 "Invalid Request: jsonrpc field must be \"2.0\""
        return
    fi

    # V154: method must be a non-null string — null/number/object method is an invalid request,
    # not "method not found". Correct code is -32600 (Invalid Request), not -32601 (Method not found).
    if ! jq -e '.method | type == "string"' >/dev/null 2>&1 <<< "$line"; then
        rpc_err "$id" -32600 "Invalid Request: method must be a string"
        return
    fi

    case "$method" in

        initialize)
            # V7e: reject re-initialization (mcp-security-spec.md §5.2)
            # RT-849: use -32003 (not -32002) for already-initialized; MCP spec defines
            # -32002 specifically as "not initialized" — using the same code for the
            # opposite condition causes spec-compliant clients to retry initialize endlessly.
            if [[ "$INIT_REQUESTED" == "true" ]]; then
                rpc_err "$id" -32003 "Already initialized — re-initialization rejected"
                return
            fi
            # V128: rate limit initialize per-IP (30/hr per mcp-security-spec.md §4)
            local _init_rl_ok=true
            _rl_check "initialize" "ip" "session" "$RL_INIT_IP_LIMIT" 3 || _init_rl_ok=false
            if [[ "$_init_rl_ok" == "false" ]]; then
                # RT-287: guard RL_INIT_IP_LIMIT==0 before division (operator disable case)
                if (( RL_INIT_IP_LIMIT == 0 )); then
                    rpc_err "$id" -32029 "initialize has been disabled by operator configuration. retryable=false"
                else
                    # RT-301: accurate retry from RL_RESET_AT (not 3600/limit overestimate)
                    local _init_retry=$(( RL_RESET_AT - _RL_EPOCH_OFFSET - SECONDS ))
                    (( _init_retry < 1 )) && _init_retry=1
                    rpc_err "$id" -32029 "Rate limit exceeded for initialize (${RL_INIT_IP_LIMIT}/hour). retry_after_seconds=${_init_retry}"
                fi
                return
            fi
            # RT-252: log clientInfo for forensics (sanitized — tr strips control chars / newlines)
            # RT-292: truncate after stripping to bound log line length (prevents disk-fill via long clientInfo)
            local _cname _cver _client_proto
            # V151: || true prevents SIGPIPE (from head closing pipe early on long names) from
            # triggering set -e and killing the initialize handler. These are forensic-only fields.
            _cname=$(jq -r '.params.clientInfo.name // "unknown"' <<< "$line" | tr -cd '[:print:]' | head -c 128) || true
            _cver=$(jq -r '.params.clientInfo.version // "unknown"' <<< "$line" | tr -cd '[:print:]' | head -c 64) || true
            _client_proto=$(jq -r '.params.protocolVersion // "unknown"' <<< "$line" | tr -cd '[:print:]' | head -c 32) || true
            echo "[ledger-client] connected: name=${_cname} version=${_cver} proto=${_client_proto}" >&2 || true
            # RT-253: warn on protocol version mismatch (skip when client omits protocolVersion)
            if [[ "$_client_proto" != "$MCP_PROTOCOL" && "$_client_proto" != "unknown" ]]; then
                echo "[ledger-client] WARNING: client requested protocolVersion=${_client_proto} but server supports ${MCP_PROTOCOL} — client must accept or abort" >&2
            fi
            INIT_REQUESTED=true
            INITIALIZED=true
            # RT-285: build via jq --arg to prevent SERVER_VERSION containing '"' from breaking JSON
            local _init_result
            _init_result=$(jq -cn --arg pv "$MCP_PROTOCOL" --arg sv "$SERVER_VERSION" \
                '{"protocolVersion":$pv,"capabilities":{"tools":{}},"serverInfo":{"name":"ledger","version":$sv}}')
            rpc_ok "$id" "$_init_result"
            ;;

        tools/list)
            # RT-259: spec compliance — tools/list requires initialization (capability negotiation complete)
            if [[ "$INITIALIZED" != "true" ]]; then
                rpc_err "$id" -32002 "Server not initialized — send initialize first"
                return
            fi
            # V129: rate limit tools/list per spec §4 (60/hour per-IP; fingerprinting defense)
            # RT-268 fix: use -32029 (rate limit) not -32002 (not-initialized) — distinct error codes
            local rl_tl_ok=true
            _rl_check "tools/list" "ip" "session" "$RL_TOOLS_LIST_IP_LIMIT" 5 || rl_tl_ok=false
            if [[ "$rl_tl_ok" == "false" ]]; then
                if (( RL_TOOLS_LIST_IP_LIMIT == 0 )); then
                    rpc_err "$id" -32029 "tools/list has been disabled by operator configuration. retryable=false"
                else
                    # RT-301: accurate retry from RL_RESET_AT (not 3600/limit overestimate)
                    local _tl_retry=$(( RL_RESET_AT - _RL_EPOCH_OFFSET - SECONDS ))
                    (( _tl_retry < 1 )) && _tl_retry=1
                    rpc_err "$id" -32029 "Rate limit exceeded for tools/list (${RL_TOOLS_LIST_IP_LIMIT}/hour). retry_after_seconds=${_tl_retry}"
                fi
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
            # RT-345: validate params type before field extraction — non-object params (e.g., array)
            # cause jq to exit non-zero on .params.name/.params.arguments access, triggering set -e
            # and producing -32603 (internal error) instead of -32602 (invalid params).
            if ! jq -e '.params | . == null or type == "object"' >/dev/null 2>&1 <<< "$line"; then
                rpc_err "$id" -32602 "Invalid params: params must be an object"
                return
            fi
            # RT-349: validate arguments type before extraction — non-object arguments (e.g., number,
            # array) pass jq's '// {}' coercion (truthy values skip the default) and reach
            # invoke_ledger where field extraction produces MISSING_FLAG instead of -32602.
            if ! jq -e '.params.arguments | . == null or type == "object"' >/dev/null 2>&1 <<< "$line"; then
                rpc_err "$id" -32602 "Invalid params: params.arguments must be an object"
                return
            fi
            # V339: reject non-string params.name (e.g. array) — consistent with RT-349 for params.arguments.
            if ! jq -e '.params.name | . == null or type == "string"' >/dev/null 2>&1 <<< "$line"; then
                rpc_err "$id" -32602 "Invalid params: params.name must be a string"
                return
            fi
            local tool_name tool_args ledger_out content_json
            tool_name=$(jq -r '.params.name // ""' <<< "$line")
            tool_args=$(jq -c '.params.arguments // {}' <<< "$line")

            if [[ -z "$tool_name" ]]; then
                rpc_err "$id" -32602 "Invalid params: missing tool name in params.name"
                return
            fi
            # RT-219: reject tool names with newlines, control chars, or non-identifier bytes
            # to prevent audit log injection via embedded LF in tool_name.
            if [[ ! "$tool_name" =~ ^[a-z][a-z0-9_]*$ ]]; then
                rpc_err "$id" -32602 "Invalid params: tool name must match [a-z][a-z0-9_]+"
                return
            fi

            # ── Rate limiting (docs/rate-limit-spec.md) ───────────────────
            # In stdio mode the single client is "session". Per-IP = per-session.
            local rl_ok=true rl_dim="" rl_limit=0 rl_burst=0
            case "$tool_name" in
                ledger_register)
                    rl_dim="per_ip"; rl_limit=$RL_REG_IP_LIMIT; rl_burst=2
                    _rl_check "$tool_name" "ip" "session" "$rl_limit" "$rl_burst" || rl_ok=false
                    ;;
                ledger_invoice_create)
                    rl_dim="per_org"; rl_limit=$RL_CREATE_ORG_LIMIT; rl_burst=20
                    _rl_check "$tool_name" "org" "session" "$rl_limit" "$rl_burst" || rl_ok=false
                    ;;
                ledger_invoice_list)
                    rl_dim="per_org"; rl_limit=$RL_LIST_ORG_LIMIT; rl_burst=60
                    _rl_check "$tool_name" "org" "session" "$rl_limit" "$rl_burst" || rl_ok=false
                    ;;
                ledger_invoice_count)
                    rl_dim="per_org"; rl_limit=$RL_COUNT_ORG_LIMIT; rl_burst=120
                    _rl_check "$tool_name" "org" "session" "$rl_limit" "$rl_burst" || rl_ok=false
                    ;;
                *)
                    # V76 fix: unknown tools get a conservative default rate limit (not bypassed)
                    # RT-431: use fixed "__unknown__" bucket key for all unknown tool names —
                    # per-name keys allow unbounded _RL_BUCKETS growth via unique fake tool names.
                    # "__unknown__" is rejected by the tool-name regex so it cannot collide.
                    rl_dim="per_org"; rl_limit=60; rl_burst=10
                    _rl_check "__unknown__" "org" "session" "$rl_limit" "$rl_burst" || rl_ok=false
                    ;;
            esac
            if [[ "$rl_ok" == "false" ]]; then
                local rl_json
                # RT-258: distinguish operator-disabled (limit=0) from transient rate-limit
                if (( rl_limit == 0 )); then
                    rl_json='{"error_code":"TOOL_DISABLED","error":"This tool has been disabled by the operator configuration.","retryable":false}'
                else
                    rl_json=$(_rl_rate_limited_json "$tool_name" "$rl_dim")
                fi
                content_json=$(jq -cn --arg text "$rl_json" \
                    '{"content":[{"type":"text","text":$text}],"isError":true}')
                rpc_ok "$id" "$content_json"
                return
            fi
            local rl_remaining=$RL_REMAINING rl_reset=$RL_RESET_AT

            # Dispatch to ledger binary
            ledger_out=$(invoke_ledger "$tool_name" "$tool_args")

            # RT-40: isError flag — detect ledger error responses so MCP clients
            # can check isError without parsing the text content. Check only the
            # first line of output; errors are always single-line JSON objects with error_code.
            local first_line="${ledger_out%%$'\n'*}"
            local is_error=false
            if jq -e 'type == "object" and has("error_code")' >/dev/null 2>&1 <<< "$first_line"; then
                is_error=true
            fi

            # Inject _rate_limit into successful responses. All tools now return single-JSON
            # objects (invoice_list was JSONL pre-V266; pagination fix made it single-JSON).
            local display_out="$ledger_out"
            if [[ "$is_error" == "false" ]]; then
                display_out=$(_rl_inject_field "$ledger_out" "$rl_remaining" "$rl_reset" "$rl_limit")
            fi

            # RT-287: use stdin pipe (not --arg) so large display_out doesn't exceed argv size limit.
            # -R (raw-input) + -s (slurp) reads all of stdin as a single JSON string value in `.`.
            # printf '%s' avoids adding an extra trailing newline to the content.
            content_json=$(printf '%s' "$display_out" | \
                jq -Rsc --argjson ie "$is_error" \
                '{"content":[{"type":"text","text":.}],"isError":$ie}')
            rpc_ok "$id" "$content_json"
            ;;

        ping)
            rpc_ok "$id" "{}"
            ;;

        *)
            # V161: truncate method name before embedding in --arg to prevent argv overflow
            # for agent-sent method strings approaching MAX_MSG (1MiB). 200 chars is ample for
            # any real method name while keeping the error message well within argv limits.
            local _method_trunc="${method:0:200}"
            rpc_err "$id" -32601 "Method not found: ${_method_trunc}"
            ;;

    esac
}

# ── Main read loop ─────────────────────────────────────────────────────────
# RT-35: check message size before any JSON parsing
# IFS= preserves leading/trailing whitespace in each line
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines silently
    [[ -z "$line" ]] && continue

    # 1 MiB message size limit (mcp-security-spec.md §5.1)
    # ${#line} is character count; close approximation for byte limit on ASCII-dominant JSON
    if (( ${#line} > MAX_MSG )); then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Message too large (max 1 MiB)"}}\n'
        continue
    fi

    # RT-37: guard against unexpected handle_message failure with set -e
    # If the handler exits non-zero (jq crash, etc.), emit an internal error
    # response instead of terminating the bridge process.
    handle_message "$line" || \
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal bridge error — handler failed unexpectedly"}}\n'
done
