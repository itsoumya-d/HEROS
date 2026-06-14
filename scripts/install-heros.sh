#!/usr/bin/env bash
set -euo pipefail

repo="${HEROS_REPO:-itsoumya-d/HEROS}"
version="${HEROS_VERSION:-latest}"
install_dir="${HEROS_INSTALL_DIR:-$HOME/.local/bin}"
data_dir="${HEROS_DATA_DIR:-$HOME/.local/share/heros}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'ERROR: %s is required\n' "$1" >&2
    exit 1
  fi
}

need curl
need chmod
need mkdir
need uname

os="$(uname -s)"
arch="$(uname -m)"

if [[ "$os" != "Linux" ]]; then
  printf 'ERROR: forge and ledger release binaries currently target Linux x86-64. Detected %s.\n' "$os" >&2
  printf 'Use @heros/agentic through npm on macOS/Windows, or use Linux/WSL for forge and ledger.\n' >&2
  exit 1
fi

case "$arch" in
  x86_64|amd64)
    target="linux-x64"
    ;;
  *)
    printf 'ERROR: unsupported architecture %s. Current release binaries target x86_64.\n' "$arch" >&2
    exit 1
    ;;
esac

mkdir -p "$install_dir" "$data_dir"

if [[ "$version" == "latest" ]]; then
  release_base="https://github.com/$repo/releases/latest/download"
  raw_ref="main"
else
  release_base="https://github.com/$repo/releases/download/$version"
  raw_ref="$version"
fi
raw_base="https://raw.githubusercontent.com/$repo/$raw_ref"

download() {
  local url="$1"
  local output="$2"
  printf 'Downloading %s\n' "$url"
  curl -fsSL "$url" -o "$output"
}

download "$release_base/forge-$target.bin" "$install_dir/heros-forge"
download "$release_base/ledger-$target.bin" "$install_dir/heros-ledger"
download "$raw_base/forge/mcp-bridge.sh" "$install_dir/heros-forge-bridge"
download "$raw_base/ledger/mcp-bridge.sh" "$install_dir/heros-ledger-bridge"
download "$raw_base/forge/mcp-manifest.json" "$data_dir/forge-mcp-manifest.json"
download "$raw_base/ledger/mcp-manifest.json" "$data_dir/ledger-mcp-manifest.json"

chmod +x \
  "$install_dir/heros-forge" \
  "$install_dir/heros-ledger" \
  "$install_dir/heros-forge-bridge" \
  "$install_dir/heros-ledger-bridge"

cat <<EOF
HEROS installed.

Binaries:
  $install_dir/heros-forge
  $install_dir/heros-ledger

MCP bridges:
  $install_dir/heros-forge-bridge
  $install_dir/heros-ledger-bridge

Data directory:
  $data_dir

Add this to your shell profile if needed:
  export PATH="$install_dir:\$PATH"

Bridge environment:
  export FORGE_BIN="$install_dir/heros-forge"
  export LEDGER_BIN="$install_dir/heros-ledger"
  export HEROS_DATA_DIR="$data_dir"
EOF
