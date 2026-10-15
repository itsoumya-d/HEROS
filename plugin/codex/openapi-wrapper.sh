#!/usr/bin/env bash
# plugin/codex/openapi-wrapper.sh — HTTP→MCP bridge for OpenAPI/Codex callers
#
# Starts a minimal HTTP server (port 8743 by default) that translates HTTP
# requests into MCP tools/call JSON-RPC messages and pipes them to the
# HEROS MCP bridges. Provides an OpenAPI-compatible interface for callers
# that do not speak the MCP stdio protocol natively (e.g. Copilot @openapi).
#
# Usage: bash plugin/codex/openapi-wrapper.sh [--port PORT]
#        PORT default: 8743
#
# Requires: bash 4+, jq 1.6+, nc (netcat, any variant) OR socat
# Security: no eval, jq for JSON construction, bash arrays for command args.
#
# Routes:
#   POST /forge/analyze         → forge_analyze
#   POST /ledger/register       → ledger_register
#   POST /ledger/invoice/create → ledger_invoice_create
#   GET  /ledger/invoice/list   → ledger_invoice_list
#   GET  /ledger/invoice/count  → ledger_invoice_count
set -euo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PORT=8743
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="${2:-8743}"; shift 2 ;;
        --help|-h)
            printf 'Usage: %s [--port PORT]\n' "$0"
            printf 'Default port: 8743\n'
            exit 0
            ;;
        *)
            printf '{"error":"unknown flag: %s"}\n' "$1" >&2
            exit 1
            ;;
    esac
done

# Validate port is a positive integer
if ! [[ "$PORT" =~ ^[1-9][0-9]*$ ]] || (( PORT > 65535 )); then
    printf '{"error":"invalid port: %s"}\n' "$PORT" >&2
    exit 1
fi

for _req in jq bash; do
    command -v "$_req" >/dev/null 2>&1 || {
        printf '{"error":"%s not found in PATH (required)"}\n' "$_req" >&2
        exit 1
    }
done

# Detect nc or socat
if command -v nc >/dev/null 2>&1; then
    HAVE_NC=true
else
    HAVE_NC=false
fi
if command -v socat >/dev/null 2>&1; then
    HAVE_SOCAT=true
else
    HAVE_SOCAT=false
fi

if [[ "$HAVE_NC" == "false" && "$HAVE_SOCAT" == "false" ]]; then
    printf '{"error":"neither nc nor socat found in PATH; one is required for the HTTP server"}\n' >&2
    exit 1
fi

FORGE_BRIDGE="${REPO_ROOT}/forge/mcp-bridge.sh"
LEDGER_BRIDGE="${REPO_ROOT}/ledger/mcp-bridge.sh"

if [[ ! -f "$FORGE_BRIDGE" || ! -f "$LEDGER_BRIDGE" ]]; then
    printf '{"error":"bridge scripts not found — run from HEROS repo root"}\n' >&2
    exit 1
fi

# ── MCP session helper ────────────────────────────────────────────────────────
# _mcp_call BRIDGE TOOL_NAME ARGS_JSON
# Runs a full MCP session (init → tools/call) and returns the content[0].text value.
_mcp_call() {
    local bridge="$1" tool_name="$2" args_json="$3"
    local tmpfile result
    tmpfile=$(mktemp)
    # Build three messages: initialize, notifications/initialized, tools/call
    jq -cn \
        --arg pv "2025-11-25" \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":$pv,"capabilities":{},"clientInfo":{"name":"openapi-wrapper","version":"0.1.0"}}}' \
        > "$tmpfile"
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >> "$tmpfile"
    jq -cn \
        --arg name "$tool_name" \
        --argjson args "$args_json" \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":$name,"arguments":$args}}' \
        >> "$tmpfile"
    result=$(bash "$bridge" < "$tmpfile" 2>/dev/null \
        | jq -rs 'map(select(type=="object" and .id==2)) | .[0] // {} | .result.content[0].text // "{}"' \
        2>/dev/null) || result="{}"
    rm -f "$tmpfile"
    printf '%s\n' "$result"
}

# ── HTTP response helpers ─────────────────────────────────────────────────────
_http_ok() {
    local body="$1"
    local length=${#body}
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "$length" "$body"
}

_http_bad_request() {
    local msg="$1"
    local body
    body=$(jq -cn --arg m "$msg" '{"error":$m}')
    local length=${#body}
    printf 'HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "$length" "$body"
}

_http_not_found() {
    local path="$1"
    local body
    body=$(jq -cn --arg p "$path" '{"error":"not found","path":$p}')
    local length=${#body}
    printf 'HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "$length" "$body"
}

# ── Request handler ───────────────────────────────────────────────────────────
_handle_request() {
    local method="" path="" body=""
    local content_length=0
    local in_headers=true

    # Read HTTP request line and headers
    while IFS= read -r raw_line; do
        # Strip carriage return
        local line="${raw_line%$'\r'}"
        if [[ "$in_headers" == "true" ]]; then
            if [[ -z "$line" ]]; then
                in_headers=false
                break
            fi
            if [[ -z "$method" ]]; then
                # First line: METHOD PATH HTTP/1.1
                read -r method path _ <<< "$line"
            else
                case "${line,,}" in
                    content-length:*)
                        content_length="${line#*: }"
                        content_length="${content_length// /}"
                        ;;
                esac
            fi
        fi
    done

    # Read body if present
    if (( content_length > 0 )); then
        body=$(dd bs=1 count="$content_length" 2>/dev/null) || body=""
    fi

    # Route
    case "${method} ${path}" in
        "POST /forge/analyze")
            if ! jq -e . >/dev/null 2>&1 <<< "$body"; then
                _http_bad_request "request body must be valid JSON"
                return
            fi
            result=$(_mcp_call "$FORGE_BRIDGE" "forge_analyze" "$body")
            _http_ok "$result"
            ;;
        "POST /ledger/register")
            if ! jq -e . >/dev/null 2>&1 <<< "$body"; then
                _http_bad_request "request body must be valid JSON"
                return
            fi
            result=$(_mcp_call "$LEDGER_BRIDGE" "ledger_register" "$body")
            _http_ok "$result"
            ;;
        "POST /ledger/invoice/create")
            if ! jq -e . >/dev/null 2>&1 <<< "$body"; then
                _http_bad_request "request body must be valid JSON"
                return
            fi
            result=$(_mcp_call "$LEDGER_BRIDGE" "ledger_invoice_create" "$body")
            _http_ok "$result"
            ;;
        "GET /ledger/invoice/list"|"GET /ledger/invoice/list?"*)
            # Parse query params (limit, offset)
            qs="${path#*\?}"
            [[ "$path" == "${path#*\?}" ]] && qs=""
            lim=100
            off=0
            if [[ -n "$qs" ]]; then
                while IFS='=' read -r k v; do
                    case "$k" in
                        limit)  lim="$v" ;;
                        offset) off="$v" ;;
                    esac
                done < <(printf '%s\n' "$qs" | tr '&' '\n')
            fi
            # Build args JSON safely
            args=$(jq -cn --argjson lim "$lim" --argjson off "$off" \
                '{"limit":$lim,"offset":$off}' 2>/dev/null) || args='{"limit":100,"offset":0}'
            result=$(_mcp_call "$LEDGER_BRIDGE" "ledger_invoice_list" "$args")
            _http_ok "$result"
            ;;
        "GET /ledger/invoice/count")
            result=$(_mcp_call "$LEDGER_BRIDGE" "ledger_invoice_count" "{}")
            _http_ok "$result"
            ;;
        *)
            _http_not_found "$path"
            ;;
    esac
}

# ── Server loop ───────────────────────────────────────────────────────────────
printf '[openapi-wrapper] Listening on port %d\n' "$PORT" >&2
printf '[openapi-wrapper] Routes: POST /forge/analyze, POST /ledger/register,\n' >&2
printf '[openapi-wrapper]         POST /ledger/invoice/create, GET /ledger/invoice/list,\n' >&2
printf '[openapi-wrapper]         GET /ledger/invoice/count\n' >&2

trap 'exit 0' TERM INT

if [[ "$HAVE_NC" == "true" ]]; then
    # nc-based loop: each connection is handled in a subshell
    while true; do
        nc -l -p "$PORT" -q 1 2>/dev/null < <(_handle_request) || true
    done
elif [[ "$HAVE_SOCAT" == "true" ]]; then
    socat "TCP-LISTEN:${PORT},reuseaddr,fork" \
        "EXEC:bash ${SCRIPT_DIR}/openapi-wrapper.sh --_handle,pipes" 2>/dev/null || true
fi
