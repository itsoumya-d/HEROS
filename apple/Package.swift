// swift-tools-version:5.9
// HEROS Console for Apple platforms.
//
// - HEROSClient        : shared, platform-agnostic client for the HEROS Console
//                        HTTP API (compiles for macOS AND iOS).
// - HEROSConsoleUI     : SwiftUI views (compiles for macOS AND iOS).
// - heros-console-cli  : a macOS command-line client (built via `swift build`).
//
// CI builds this on a macОS runner: `swift build` (macOS) +
// `xcodebuild -destination 'generic/platform=iOS'` (iOS compile). Producing a
// signed .ipa for the App Store additionally requires Apple Developer signing
// certificates, which are account-bound and not part of this repo.
import PackageDescription

let package = Package(
    name: "HEROSConsole",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .library(name: "HEROSClient", targets: ["HEROSClient"]),
        .library(name: "HEROSConsoleUI", targets: ["HEROSConsoleUI"]),
        .executable(name: "heros-console-cli", targets: ["heros-console-cli"])
    ],
    targets: [
        .target(name: "HEROSClient"),
        .target(name: "HEROSConsoleUI", dependencies: ["HEROSClient"]),
        .executableTarget(name: "heros-console-cli", dependencies: ["HEROSClient"])
    ]
)
