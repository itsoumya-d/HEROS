// SPDX-License-Identifier: MIT
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin client for the HEROS Console local HTTP API (served by the Go app in
/// `app/`). Like every HEROS surface, it owns no risk logic — it forwards tool
/// calls to the MCP bridges (via the console) and returns their JSON. All gates
/// (guardian approval nonce, evolve gated self-modification, audit chain) stay
/// server-side.
public struct HEROSConsoleClient {
    public let baseURL: URL

    public init(baseURL: String = "http://127.0.0.1:8765") {
        self.baseURL = URL(string: baseURL) ?? URL(string: "http://127.0.0.1:8765")!
    }

    public enum ClientError: Error {
        case badResponse
        case http(Int)
    }

    /// GET /healthz — returns the decoded JSON object.
    public func health() async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent("healthz")
        let (data, resp) = try await URLSession.shared.data(from: url)
        try Self.check(resp)
        return try Self.json(data)
    }

    /// POST /api/call — invoke a bridge tool. `args` is arbitrary JSON.
    /// Returns the tool's result JSON object.
    public func call(server: String, tool: String, args: [String: Any] = [:]) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent("api/call")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["server": server, "tool": tool, "args": args]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp)
        return try Self.json(data)
    }

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.http(http.statusCode) }
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else { throw ClientError.badResponse }
        return dict
    }
}
