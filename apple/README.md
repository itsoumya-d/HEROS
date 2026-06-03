# HEROS Console — Apple platforms (macOS + iOS)

A Swift Package that brings the HEROS Console to Apple platforms. Like every
HEROS surface it owns no risk logic — it's a client to the local HEROS Console
HTTP API (the Go app in `app/`), which forwards to the MCP bridges. Every gate
(guardian approval nonce, evolve gated self-modification, audit chain) stays
server-side.

## Targets

| Product | Platforms | What it is |
|---|---|---|
| `HEROSClient` | macOS + iOS | Shared `URLSession` client + JSON helpers |
| `HEROSConsoleUI` | macOS + iOS | SwiftUI views (`ContentView`, `HEROSConsoleApp`) |
| `heros-console-cli` | macOS | Command-line client (`swift build`) |

## Build (requires a Mac — Apple's toolchain only runs on macOS)

```bash
cd apple
swift build                                   # macOS: compiles client + UI + CLI
swift run heros-console-cli                    # macOS: prints console health

# iOS compile (no signing needed to type-check/compile):
xcodebuild -scheme HEROSConsoleUI \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

CI runs exactly this on a macOS runner (the `apple-build` job): `swift build`
for macOS and `xcodebuild ... -destination 'generic/platform=iOS'` for iOS — so
both platforms are **compile-verified** on Apple's toolchain.

## Honest scope

- macOS and iOS **compilation** is CI-verified on a macOS runner.
- A shippable, **signed `.ipa`** for the App Store additionally needs an Apple
  Developer account + signing certificates + provisioning profiles, which are
  account-bound secrets and not part of this repo. Wrapping `HEROSConsoleApp`
  in an Xcode app target (`@main`) and signing is the remaining packaging step.
- This is why iOS could not be produced in the Linux dev container at all
  (Apple's toolchain requires macOS); it lives here as a Mac-runner CI target.
