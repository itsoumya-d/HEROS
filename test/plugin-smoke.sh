#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# test/plugin-smoke.sh — prove the plugin packaging actually launches.
#
# For every server declared in /.mcp.json, this resolves the documented path
# variables (${CLAUDE_PLUGIN_ROOT} -> repo root, ${CLAUDE_PLUGIN_DATA} -> a temp
# dir) exactly the way Claude Code does, then pipes an `initialize` + `tools/list`
# JSON-RPC handshake over stdio to the bridge and asserts a valid tools/list with
# at least one tool. This is what makes "HEROS is a Claude Code plugin" verifiable
# rather than aspirational.
#
# Binary-backed servers (forge/ledger) whose binary is absent SKIP with the
# bridge's own clean "binary not found" error — packaging is still proven (the
# bridge launches and degrades gracefully); the binary is fetched by /heros-setup.
#
# Usage: bash test/plugin-smoke.sh
# Exit:  0 all non-skipped servers answered; 1 a server failed; 2 setup error.

set -uo pipefail
export LC_ALL=C.UTF-8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_JSON="${REPO_ROOT}/.mcp.json"

command -v jq >/dev/null 2>&1 || { echo "plugin-smoke: jq required" >&2; exit 2; }
[[ -f "$MCP_JSON" ]] || { echo "plugin-smoke: .mcp.json not found at $MCP_JSON" >&2; exit 2; }

# CLAUDE_PLUGIN_DATA is a writable per-user dir in real installs; a temp dir here.
PLUGIN_DATA="$(mktemp -d)"
trap 'rm -rf "$PLUGIN_DATA"' EXIT

PASS=0 FAIL=0 SKIP=0

_expand() { # substitute the documented plugin path variables
    local s="$1"
    s="${s//\$\{CLAUDE_PLUGIN_ROOT\}/$REPO_ROOT}"
    s="${s//\$\{CLAUDE_PLUGIN_DATA\}/$PLUGIN_DATA}"
    printf '%s' "$s"
}

INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}'
LIST='{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

printf '── HEROS plugin smoke test (.mcp.json) ──────────────────────────────\n'

# Iterate servers without a subshell so counters persist.
while IFS=$'\t' read -r name command args_json env_json; do
    # Build argv from the JSON array, expanding path variables.
    mapfile -t raw_args < <(printf '%s' "$args_json" | jq -r '.[]?')
    cmd_args=()
    for a in "${raw_args[@]}"; do cmd_args+=("$(_expand "$a")"); done
    bin="$(_expand "$command")"

    # Export the server's env block (HEROS_DATA_DIR, FORGE_BIN, ...) for the call.
    env_kv=()
    while IFS=$'\t' read -r k v; do
        [[ -z "$k" ]] && continue
        env_kv+=("$k=$(_expand "$v")")
    done < <(printf '%s' "$env_json" | jq -r 'to_entries[]? | [.key, (.value|tostring)] | @tsv')

    out="$(printf '%s\n%s\n' "$INIT" "$LIST" \
        | timeout 20 env "${env_kv[@]}" "$bin" "${cmd_args[@]}" 2>/dev/null)"

    # tools/list result for id==1?
    tools="$(printf '%s\n' "$out" \
        | jq -rc 'select(.id==1 and (.result.tools|type=="array")) | .result.tools[].name' 2>/dev/null \
        | paste -sd, -)"

    if [[ -n "$tools" ]]; then
        printf 'PASS  %-16s tools: %s\n' "$name" "$tools"
        PASS=$((PASS+1))
    elif printf '%s' "$out" | jq -e 'select(.error.message? // "" | test("binary not found"))' >/dev/null 2>&1; then
        printf 'SKIP  %-16s (binary absent — run /heros-setup; bridge launched cleanly)\n' "$name"
        SKIP=$((SKIP+1))
    else
        printf 'FAIL  %-16s (no tools/list result)\n' "$name"
        FAIL=$((FAIL+1))
    fi
done < <(jq -r '.mcpServers | to_entries[] | [.key, .value.command, (.value.args|tojson), (.value.env // {}|tojson)] | @tsv' "$MCP_JSON")

printf '─────────────────────────────────────────────────────────────────────\n'
printf 'TOTAL: %d launched+listed, %d failed, %d skipped (binary absent)\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]] || { echo "RESULT: FAIL"; exit 1; }
echo "RESULT: PASS — every packaged server launches and answers tools/list"
exit 0
