#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install/codex/install.sh — register HEROS MCP servers with OpenAI Codex.
#
# Idempotent: backs up ~/.codex/config.toml, removes any prior HEROS blocks, then
# appends the seven [mcp_servers.heros-*] tables with absolute paths substituted.
# Re-running it is safe and simply refreshes the block.
#
# Usage:
#   bash install/codex/install.sh [--config PATH] [--data DIR]
#     --config PATH  Codex config (default: ${CODEX_HOME:-~/.codex}/config.toml)
#     --data   DIR   writable state dir (default: ~/.heros)

set -euo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEROS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE="${SCRIPT_DIR}/heros.config.toml"

CONFIG="${CODEX_HOME:-${HOME}/.codex}/config.toml"
DATA="${HOME}/.heros"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG="$2"; shift 2 ;;
        --data)   DATA="$2";   shift 2 ;;
        -h|--help) sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'install: unknown arg %q\n' "$1" >&2; exit 2 ;;
    esac
done

[[ -f "$TEMPLATE" ]] || { printf 'install: template not found: %s\n' "$TEMPLATE" >&2; exit 2; }

mkdir -p "$(dirname "$CONFIG")" "$DATA" "${DATA}/bin"

# Marker comments delimit our block so re-runs replace rather than duplicate.
BEGIN='# >>> HEROS MCP servers (managed by install/codex/install.sh) >>>'
END='# <<< HEROS MCP servers <<<'

# Render the template with absolute paths.
rendered="$(sed -e "s|__HEROS_ROOT__|${HEROS_ROOT}|g" -e "s|__HEROS_DATA__|${DATA}|g" "$TEMPLATE")"

if [[ -f "$CONFIG" ]]; then
    backup="${CONFIG}.heros-backup.$(date +%Y%m%d%H%M%S)"
    cp "$CONFIG" "$backup"
    printf 'Backed up existing config to %s\n' "$backup"
    # Strip any previous HEROS block (between markers) using awk (no eval).
    awk -v b="$BEGIN" -v e="$END" '
        $0==b {skip=1; next}
        $0==e {skip=0; next}
        skip!=1 {print}
    ' "$CONFIG" > "${CONFIG}.tmp"
    mv "${CONFIG}.tmp" "$CONFIG"
else
    : > "$CONFIG"
fi

{
    printf '\n%s\n' "$BEGIN"
    printf '%s\n' "$rendered"
    printf '%s\n' "$END"
} >> "$CONFIG"

printf 'Registered 7 HEROS MCP servers in %s\n' "$CONFIG"
printf '  repo:  %s\n  state: %s\n' "$HEROS_ROOT" "$DATA"
printf 'Verify with:  codex mcp list\n'
printf 'forge/ledger need their binary — run: bash %s/install/fetch-binaries.sh --dest %s/bin\n' \
    "$HEROS_ROOT" "$DATA"
