#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install/fetch-binaries.sh — fetch + verify the forge/ledger Zero binaries.
#
# The five pure-bash HEROS tools need no binary. forge and ledger are compiled
# Zero binaries (linux-musl-x64, sub-100 KiB). This script downloads the signed
# release assets, verifies their published SHA-256 checksum (hard gate), attempts
# a cosign signature check when possible, and installs them where the plugin's
# .mcp.json expects them (FORGE_BIN / LEDGER_BIN).
#
# Usage:
#   bash install/fetch-binaries.sh [--dest DIR] [--tag latest|vX.Y.Z]
#     --dest DIR   install dir for `forge` and `ledger` (default: ./bin, or
#                  ${CLAUDE_PLUGIN_DATA}/bin when invoked by /heros-setup)
#     --tag        release tag to pull (default: latest)
#
# Linux x86-64 only: on any other platform the binaries cannot run. The script
# says so plainly and exits 0 (the five bash tools still work) unless --strict.

set -euo pipefail
export LC_ALL=C.UTF-8

REPO="itsoumya-d/HEROS"
DEST="${CLAUDE_PLUGIN_DATA:+${CLAUDE_PLUGIN_DATA}/bin}"
DEST="${DEST:-./bin}"
TAG="latest"
STRICT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)   DEST="$2"; shift 2 ;;
        --tag)    TAG="$2";  shift 2 ;;
        --strict) STRICT=1;  shift ;;
        -h|--help) sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'fetch-binaries: unknown arg %q\n' "$1" >&2; exit 2 ;;
    esac
done

# ── Platform gate: these are linux-x86-64 binaries ───────────────────────────
os="$(uname -s 2>/dev/null || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"
if [[ "$os" != "Linux" || ! "$arch" =~ ^(x86_64|amd64)$ ]]; then
    cat >&2 <<EOF
fetch-binaries: forge/ledger are linux-x86-64 binaries; this host is ${os}/${arch}.
  Run them under Linux, WSL2, or a container. The other five HEROS tools
  (guardian, vault, audit, evolve, remix) work natively on this host already.
EOF
    [[ "$STRICT" -eq 1 ]] && exit 1 || exit 0
fi

for req in curl sha256sum; do
    command -v "$req" >/dev/null 2>&1 || { printf 'fetch-binaries: %s required\n' "$req" >&2; exit 2; }
done

mkdir -p "$DEST"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [[ "$TAG" == "latest" ]]; then
    base="https://github.com/${REPO}/releases/latest/download"
else
    base="https://github.com/${REPO}/releases/download/${TAG}"
fi

_have_cosign=0; command -v cosign >/dev/null 2>&1 && _have_cosign=1

_fetch_one() {  # $1 = tool name (forge|ledger)
    local tool="$1" asset="$1-linux-x64.bin"
    printf '→ %s: downloading %s\n' "$tool" "$asset"
    curl -fsSL "${base}/${asset}"        -o "${TMP}/${asset}"
    curl -fsSL "${base}/${asset}.sha256" -o "${TMP}/${asset}.sha256"

    # Hard gate: published SHA-256 must match.
    ( cd "$TMP" && sha256sum -c "${asset}.sha256" >/dev/null ) \
        || { printf 'fetch-binaries: %s CHECKSUM MISMATCH — refusing to install\n' "$asset" >&2; exit 1; }
    printf '  ✓ sha256 verified\n'

    # Best-effort signature check. Keyless cosign needs the signing cert; the
    # release publishes <asset>.sig but no separate cert, so a strict verify may
    # require --certificate. Attempt it; never silently claim success.
    if [[ "$_have_cosign" -eq 1 ]] && curl -fsSL "${base}/${asset}.sig" -o "${TMP}/${asset}.sig" 2>/dev/null; then
        if cosign verify-blob \
              --certificate-identity-regexp "https://github.com/${REPO}" \
              --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
              --signature "${TMP}/${asset}.sig" "${TMP}/${asset}" >/dev/null 2>&1; then
            printf '  ✓ cosign signature verified\n'
        else
            printf '  ! cosign present but could not verify signature (needs signing cert); relying on sha256\n'
        fi
    else
        printf '  • cosign not run (install cosign for signature verification); sha256 gate enforced\n'
    fi

    install -m 0755 "${TMP}/${asset}" "${DEST}/${tool}"
    printf '  ✓ installed %s\n' "${DEST}/${tool}"
}

_fetch_one forge
_fetch_one ledger

printf '\nDone. forge + ledger installed in %s\n' "$DEST"
printf 'The plugin .mcp.json points FORGE_BIN/LEDGER_BIN here; restart the MCP\n'
printf 'servers (or your client) to pick them up.\n'
