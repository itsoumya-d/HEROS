#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ remix/mcp-bridge.sh — Agent-generated, user-tweakable companion UIs       │
# │                                                                          │
# │ "Remix": an agent reads data from a connected app (via supported         │
# │ channels) and emits a DECLARATIVE UI SPEC (heros.ui/v1) describing a      │
# │ SEPARATE companion experience — e.g. a Netflix watchlist turned into a   │
# │ to-do list. Because the output is JSON (tokens + tree + actions), the    │
# │ USER can tweak it (colors/spacing/type) without touching logic.          │
# │                                                                          │
# │ This bridge is the pure-compute validator/normalizer for that spec       │
# │ (args/JSON in -> JSON out, no I/O), mirroring forge/ledger: it enforces   │
# │ a closed widget catalog, sanitizes every rendered string, validates the  │
# │ design tokens, and whitelists the action table (host-only intent         │
# │ dispatch). The Android/desktop host (app/, android-app/, apple/) renders  │
# │ the validated spec; guardian gates each action before it runs.           │
# │                                                                          │
# │ Honest scope (see docs/remix-spec.md): you CANNOT restyle a third-party  │
# │ app in place on stock non-rooted Android, and screen-scraping is a Play   │
# │ dead-end. remix builds a themed COMPANION surface from data read via     │
# │ SUPPORTED channels only.                                                  │
# │                                                                          │
# │ Security: jq for all parsing, no eval, no string-concatenated JSON.      │
# │ Requires: jq >= 1.6                                                       │
# └──────────────────────────────────────────────────────────────────────────┘

set -uo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
trap 'exit 0' TERM INT PIPE

readonly MCP_PROTOCOL="2025-11-25"
readonly REMIX_VERSION="0.1.0"
readonly MAX_MSG=1048576
# Rendered-string cap (512) and tree node budget (500) are enforced as
# literals inside REMIX_VALIDATOR (the pure-jq validator) below.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v jq >/dev/null 2>&1; then
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"jq >= 1.6 required but not found in PATH"}}\n'
    exit 1
fi

# Operator-configurable https host allowlist for links/images (comma-separated).
# Empty => any host allowed but https still required.
REMIX_ALLOWED_HOSTS="${REMIX_ALLOWED_HOSTS:-}"

# ── Rate limit (token bucket, in-memory) ───────────────────────────────────
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
    tokens=$(( tokens + refill )); [[ $tokens -gt $burst ]] && tokens=$burst
    _RL_LAST[$key]="$now"
    if [[ $tokens -le 0 ]]; then
        _RL_BUCKETS[$key]=0; printf 'RATE_LIMITED %s' "$(( now + RL_WINDOW - elapsed ))"; return
    fi
    tokens=$(( tokens - 1 )); _RL_BUCKETS[$key]="$tokens"
    printf 'OK %s %s %s' "$tokens" "$(( now + RL_WINDOW ))" "$limit"
}

_send_error() {
    jq -cn --argjson id "$1" --argjson code "$2" --arg msg "$3" \
        '{"jsonrpc":"2.0","id":$id,"error":{"code":$code,"message":$msg}}'
}

# ── The heros.ui/v1 validator (pure jq) ────────────────────────────────────
# Returns {valid, violations, warnings, spec}. Closed catalog, string
# sanitization (control + non-ASCII + length), token validation, action
# whitelist, https+host-allowlist for links/images, onTap must reference a
# declared action id.
read -r -d '' REMIX_VALIDATOR <<'JQ' || true
# --- helpers ---
def bad_string($max):
  (type != "string") or test("[^ -~]") or (length > $max);

def hosts: ($ENV.REMIX_ALLOWED_HOSTS // "") | split(",") | map(select(length>0));

def url_host: ltrimstr("https://") | split("/")[0] | split("?")[0];

def check_url($u; $where):
  if ($u|type) != "string" then ["\($where): url must be a string"]
  elif ($u | test("^https://") | not) then ["\($where): url must be https (got \($u))"]
  else ( (hosts) as $h
         | if ($h|length)==0 then []
           elif ($h | index($u|url_host)) == null then ["\($where): host \($u|url_host) not in allowlist"]
           else [] end )
  end;

# Validate one design-token value.
def check_token($path; $tok):
  ($tok["$value"]) as $v
  | if ($tok["$type"]) == "color" then
      ( if ($v|type)=="string" and ($v|test("^(#[0-9a-fA-F]{3,8}|\\{[a-zA-Z0-9_.]+\\})$")) then []
        else ["token \($path): color must be hex or {alias}, got \($v|tojson)"] end )
    elif ($tok["$type"]) == "dimension" then
      ( if ($v|type)=="object" and (($v.value|type)=="number") and ($v.value>=0) and ($v.value<=4096) and (($v.unit|type)=="string") and (($v.unit|length)>0) then []
        elif ($v|type)=="string" and ($v|test("^\\{[a-zA-Z0-9_.]+\\}$")) then []
        else ["token \($path): dimension must be {value,unit} (0..4096) or {alias}"] end )
    else [] end;

def check_tokens:
  [ (.tokens // {}) | paths(objects) as $p | getpath($p) | select(has("$type")) as $tok
      | check_token(($p|join(".")); $tok) ] | add // [];

# Recursively validate the component tree. $catalog is an array of allowed types.
def walk($catalog; $actionids):
  . as $n
  | if ($n|type) != "object" then []
    else
      ( if ($n|has("type")) and (($catalog | index($n.type)) == null)
          then ["unknown component type: \($n.type|tojson)"] else [] end )
      + ( ["value","label","alt","title"]
          | map( . as $f
                 | if ($n|has($f)) and ($n[$f]|bad_string(512))
                   then "\($n.type//"node").\($f): non-ASCII/control/oversized string"
                   else empty end ) )
      + ( if ($n.type=="image") and ($n|has("source")) then check_url($n.source; "image.source") else [] end )
      + ( if ($n|has("onTap")) then
            ( if ($n.onTap|type)=="string" and (($actionids|index($n.onTap)) != null) then []
              else ["onTap references unknown action id: \($n.onTap|tojson)"] end )
          else [] end )
      + ( (($n.children // []) | if type=="array" then map(walk($catalog;$actionids)) | add else [] end) // [] )
      + ( (($n.itemTemplate // empty) | walk($catalog;$actionids)) // [] )
    end;

def count_nodes:
  if type=="object" then 1
    + (((.children // []) | if type=="array" then map(count_nodes)|add else 0 end) // 0)
    + (((.itemTemplate // empty) | count_nodes) // 0)
  else 0 end;

# --- main ---
. as $spec
| (["column","row","card","list","text","image","button","spacer","divider"]) as $catalog
| (["navigate","open_deeplink","mark_done","dismiss","submit"]) as $actiontypes
| (($spec.actions // {}) | keys) as $actionids
| ( # schema
    (if ($spec.schema // "") | test("^heros\\.ui/v1$") then [] else ["schema must be \"heros.ui/v1\""] end)
    # node budget
    + (if (($spec.tree // {}) | count_nodes) > 500 then ["tree exceeds 500 nodes"] else [] end)
    # tokens
    + check_tokens
    # actions table
    + ( ($spec.actions // {}) | to_entries | map(
          .key as $id | .value as $a
          | ( if ($a.type // "") | IN($actiontypes[]) then [] else ["action \($id): type must be one of navigate|open_deeplink|mark_done|dismiss|submit"] end )
          + ( if ($a.type=="open_deeplink") then check_url($a.url; "action \($id)") else [] end )
          + ( if ($a | has("intent")) or ($a | has("package")) or ($a | has("component"))
                then ["action \($id): raw intent/package/component fields are forbidden — host builds intents, not the spec"] else [] end )
        ) | add // [] )
    # tree
    + (($spec.tree // {}) | walk($catalog; $actionids))
  ) as $violations
| { "valid": ($violations|length==0), "violations": $violations, "node_count": (($spec.tree // {})|count_nodes), "spec": $spec }
JQ

_handle_render() {
    local params="$1"
    local rl; rl=$(_rl_check "render" 600 20)
    if [[ "${rl%% *}" == "RATE_LIMITED" ]]; then
        local resa="${rl#* }"; local ra=$(( resa - $(date +%s) )); [[ $ra -lt 1 ]] && ra=1
        jq -cn --argjson ra "$ra" '{"error_code":"RATE_LIMITED","retryable":true,"retry_after_seconds":$ra,"error":"Rate limit exceeded."}'; return
    fi

    # Extract the spec (required object).
    local spec
    spec=$(jq -ce '.spec' <<< "$params" 2>/dev/null) || {
        jq -cn '{"error_code":"MISSING_FLAG","flag":"spec","retryable":true,"error":"Required field: spec (a heros.ui/v1 object)"}'; return; }
    if ! jq -e 'type=="object"' >/dev/null 2>&1 <<< "$spec"; then
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"spec must be a JSON object"}'; return; fi

    # Run the validator.
    local result
    result=$(REMIX_ALLOWED_HOSTS="$REMIX_ALLOWED_HOSTS" jq -c "$REMIX_VALIDATOR" <<< "$spec" 2>/dev/null) || {
        jq -cn '{"error_code":"INVALID_INPUT","retryable":true,"error":"spec could not be parsed/validated"}'; return; }

    local valid; valid=$(jq -r '.valid' <<< "$result" 2>/dev/null)
    if [[ "$valid" == "true" ]]; then
        jq -cn --argjson r "$result" \
            '{"status":"ok","valid":true,"node_count":$r.node_count,"spec":$r.spec}'
    else
        jq -cn --argjson r "$result" \
            '{"error_code":"INVALID_SPEC","retryable":true,"valid":false,"violations":$r.violations,"error":"Spec failed heros.ui/v1 validation; see violations."}'
    fi
}

# ── MCP session loop ───────────────────────────────────────────────────────
INITIALIZED=false
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ ${#line} -gt $MAX_MSG ]]; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Message exceeds 1 MiB limit"}}\n'; continue
    fi
    if ! jq -e . >/dev/null 2>&1 <<< "$line"; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: invalid JSON"}}\n'; continue
    fi
    if ! jq -e 'type=="object"' >/dev/null 2>&1 <<< "$line"; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request: must be a JSON object"}}\n'; continue
    fi
    req_id=$(jq -c '.id // null' <<< "$line")
    method=$(jq -r '.method // ""' <<< "$line")
    case "$method" in
        initialize)
            if [[ "$INITIALIZED" == "true" ]]; then _send_error "$req_id" -32003 "Already initialized"; continue; fi
            INITIALIZED=true
            jq -cn '{"jsonrpc":"2.0","id":null,"method":"notifications/initialized","params":{}}'
            jq -cn --argjson id "$req_id" --arg proto "$MCP_PROTOCOL" --arg ver "$REMIX_VERSION" \
                '{"jsonrpc":"2.0","id":$id,"result":{"protocolVersion":$proto,"capabilities":{"tools":{}},"serverInfo":{"name":"remix","version":$ver}}}'
            ;;
        tools/list)
            MANIFEST="${SCRIPT_DIR}/mcp-manifest.json"
            if [[ -f "$MANIFEST" ]]; then tools_json=$(jq -c '.tools' "$MANIFEST" 2>/dev/null || printf '[]'); else tools_json="[]"; fi
            jq -cn --argjson id "$req_id" --argjson tools "$tools_json" '{"jsonrpc":"2.0","id":$id,"result":{"tools":$tools}}'
            ;;
        tools/call)
            tool_name=$(jq -r '.params.name // ""' <<< "$line")
            params=$(jq -c '.params.arguments // {}' <<< "$line")
            case "$tool_name" in
                remix_render) tool_result=$(_handle_render "$params") ;;
                *) tool_result=$(jq -cn '{"error_code":"UNKNOWN_TOOL","retryable":false,"error":"Unknown tool. Use remix_render."}') ;;
            esac
            is_error=false
            if jq -e 'has("error_code")' >/dev/null 2>&1 <<< "$tool_result"; then is_error=true; fi
            jq -cn --argjson id "$req_id" --argjson res "$tool_result" --argjson ie "$is_error" \
                '{"jsonrpc":"2.0","id":$id,"result":{"content":[{"type":"text","text":($res|tostring)}],"isError":$ie}}'
            ;;
        ping) jq -cn --argjson id "$req_id" '{"jsonrpc":"2.0","id":$id,"result":{}}' ;;
        notifications/*) ;;
        *) _send_error "$req_id" -32601 "Method not found: ${method}" ;;
    esac
done
