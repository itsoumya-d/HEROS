// SPDX-License-Identifier: MIT
import Foundation
import HEROSClient

// Small macOS command-line client for the HEROS Console. Usage:
//   heros-console-cli [baseURL]
// Defaults to http://127.0.0.1:8765 and prints the console health.
let base = CommandLine.arguments.dropFirst().first ?? "http://127.0.0.1:8765"
let client = HEROSConsoleClient(baseURL: base)

do {
    let health = try await client.health()
    print("HEROS Console @ \(base)")
    print("  status: \(health["status"] as? String ?? "?")")
    print("  root:   \(health["root"] as? String ?? "?")")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
