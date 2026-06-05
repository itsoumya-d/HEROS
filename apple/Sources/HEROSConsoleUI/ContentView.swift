// SPDX-License-Identifier: MIT
import SwiftUI
import HEROSClient

/// SwiftUI view for the HEROS Console (compiles for macOS and iOS). Drives the
/// same bridges as the desktop app, through the local console HTTP API.
public struct ContentView: View {
    private let client = HEROSConsoleClient()

    @State private var status: String = "not checked"
    @State private var skills: String = "—"

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("⬡ HEROS Console")
                .font(.title2).bold()
            Text("agent operations stack — guardian · evolve · audit · vault")
                .font(.footnote).foregroundColor(.secondary)

            GroupBox("Console health") {
                Text(status).font(.system(.body, design: .monospaced))
                Button("Check health") { Task { await checkHealth() } }
            }

            GroupBox("Active skills (evolve)") {
                Text(skills).font(.system(.body, design: .monospaced))
                Button("Refresh recommendations") { Task { await refreshSkills() } }
            }

            Spacer()
        }
        .padding(20)
    }

    private func checkHealth() async {
        do {
            let h = try await client.health()
            status = (h["status"] as? String ?? "?") + " · root: " + (h["root"] as? String ?? "?")
        } catch {
            status = "error: \(error)"
        }
    }

    private func refreshSkills() async {
        do {
            let r = try await client.call(server: "evolve", tool: "evolve_skill_recommend")
            if let top = r["top"] as? String {
                skills = "top: \(top) · count: \(r["count"] as? Int ?? 0)"
            } else {
                skills = "no active skills (count: \(r["count"] as? Int ?? 0))"
            }
        } catch {
            skills = "error: \(error)"
        }
    }
}

/// App entry scene. The `@main` attribute is added by the Xcode app target that
/// wraps this package; kept attribute-free here so the package compiles as a
/// library on both macOS and iOS.
public struct HEROSConsoleApp: App {
    public init() {}
    public var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
