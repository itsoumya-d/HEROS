# HEROS Console — cross-platform desktop app

A small, **dependency-free** desktop app that drives the HEROS MCP bridges
(`guardian`, `evolve`, `audit`, `vault`) from a local web UI.

Written in pure Go (standard library only), so it **cross-compiles to Linux,
macOS, and Windows from any host** — no Mac needed to produce the macOS build.

## What it is (and what it deliberately is not)

It mirrors the HEROS architecture: this binary owns **no** risk logic. It is a
thin client that spawns the bash MCP bridges as subprocesses, speaks JSON-RPC
2.0 over their stdio, and renders the JSON they return. Every safety decision
still happens in the bridges — guardian's approval nonce, evolve's gated
self-modification, audit's chain hash. The desktop app cannot bypass any gate;
it just makes them visible and clickable.

The UI has three tabs:
- **Guardian** — assess any operation and see its risk tier / `decision_required`.
- **Evolve** — propose skills, drive the gated promote flow (the app captures the
  approval nonce and you click again to confirm, simulating human sign-off), and
  list skills with their confidence scores.
- **Audit** — load and cryptographically verify the self-improvement change log.

## Run (from a checkout)

```bash
cd app
go run .            # builds, opens http://127.0.0.1:8765 in your browser
```

It autodetects the repo root (looks for `guardian/mcp-bridge.sh`). Override with
`-root /path/to/HEROS` or `HEROS_ROOT`. Override the address with `-addr` or
`HEROS_CONSOLE_ADDR`. Set `HEROS_CONSOLE_NO_OPEN=1` to not auto-open a browser.

The server binds to **loopback only** and rejects non-localhost clients.

## Build native binaries

```bash
# Host build
go build -o heros-console .

# Cross-compile (all from one Linux/macOS/Windows host; no Mac required for darwin)
GOOS=linux   GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o dist/heros-console-linux-amd64        .
GOOS=linux   GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o dist/heros-console-linux-arm64        .
GOOS=darwin  GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o dist/heros-console-macos-amd64        .
GOOS=darwin  GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o dist/heros-console-macos-arm64        .
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o dist/heros-console-windows-amd64.exe  .
```

Each binary is a single static file (~6 MiB) with the UI embedded via `go:embed`.

## Runtime requirement (honest caveat)

The MCP bridges are **bash + jq**, so the host needs `bash` and `jq` on `PATH`.
On Linux/macOS that's standard; on **Windows** use **Git Bash or WSL** until the
bridges have native ports. The Go binary is fully native everywhere; only the
bridges it spawns need a POSIX shell.

## Platform coverage

| Target | Status |
|---|---|
| Linux (amd64, arm64) | ✅ built + run-tested |
| macOS (amd64, arm64) | ✅ cross-compiled (Mach-O); run on a Mac |
| Windows (amd64) | ✅ cross-compiled (PE32+); needs Git Bash/WSL for the bridges |
| Android (arm64) | ✅ cross-compiled (`GOOS=android`); runs under **Termux** (which provides bash+jq). Not a packaged Play Store APK — that path is the Zero-as-WASM-in-app design in `docs/aosp-zero-integration.md`. |
| iOS | Requires a Mac + Xcode toolchain; genuinely not producible in a Linux container |

Desktop (Linux/macOS/Windows) **and** an Android arm64 binary are delivered as
real cross-compiled artifacts from a single Linux host. The Android binary runs
as a console/server under Termux; a sandboxed Play Store APK is a separate track
(`docs/aosp-zero-integration.md`). iOS is the one target that genuinely requires
Apple's toolchain on a Mac.
