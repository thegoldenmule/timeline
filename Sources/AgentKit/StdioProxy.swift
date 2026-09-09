import Foundation
import TimelineCore

/// Where the running app's MCP server is. Resolved from `TIMELINE_MCP_URL` / `TIMELINE_MCP_TOKEN`, else
/// from `~/Library/Application Support/Timeline/mcp.json` (`{ "url", "token" }`) that the app writes.
public struct ProxyEndpoint: Hashable, Sendable {
    public var url: URL
    public var token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    public enum ResolutionError: Error, CustomStringConvertible {
        case notConfigured(URL)
        case malformed(URL)

        public var description: String {
            switch self {
            case .notConfigured(let file):
                "Timeline is not running or not configured: set TIMELINE_MCP_URL and TIMELINE_MCP_TOKEN, or start the app so it writes \(file.path)"
            case .malformed(let file): "\(file.path) is not { \"url\": ..., \"token\": ... }"
            }
        }
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configurationFile: URL = MCPConnectionInfo.defaultProxyConfigurationURL
    ) throws -> ProxyEndpoint {
        if let raw = environment["TIMELINE_MCP_URL"], let url = URL(string: raw),
            let token = environment["TIMELINE_MCP_TOKEN"]
        {
            return ProxyEndpoint(url: url, token: token)
        }
        guard let data = try? Data(contentsOf: configurationFile) else {
            throw ResolutionError.notConfigured(configurationFile)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = object["url"] as? String, let url = URL(string: raw), let token = object["token"] as? String
        else { throw ResolutionError.malformed(configurationFile) }
        return ProxyEndpoint(url: url, token: token)
    }
}

/// The stdio MCP proxy: newline-delimited JSON-RPC in, forwarded as Streamable HTTP POSTs to the
/// running app, responses (JSON or the `data:` events of an SSE body) written back one per line. It
/// tracks `Mcp-Session-Id` from the initialize response, sends DELETE when the input ends, and never
/// opens the database. `timeline-mcp`'s `main.swift` is a thin caller of `run`.
public enum StdioProxy {
    public struct Summary: Sendable, Hashable {
        public var forwarded: Int
        public var sessionId: String?
        public var errors: Int
    }

    /// - Parameters:
    ///   - input: one JSON-RPC message per element (a line of stdin).
    ///   - output: receives each JSON-RPC message from the server, without a trailing newline.
    public static func run(
        input: AsyncStream<String>, output: @Sendable (String) async -> Void, endpoint: ProxyEndpoint,
        session: URLSession = URLSession(configuration: .ephemeral), log: (@Sendable (String) -> Void)? = nil
    ) async -> Summary {
        var summary = Summary(forwarded: 0, sessionId: nil, errors: 0)
        for await line in input {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            summary.forwarded += 1
            let id = requestId(in: trimmed)
            do {
                let reply = try await post(
                    Data(trimmed.utf8), endpoint: endpoint, sessionId: summary.sessionId, session: session)
                if let sid = reply.sessionId { summary.sessionId = sid }
                if reply.status >= 400 {
                    summary.errors += 1
                    log?("HTTP \(reply.status) for \(trimmed.prefix(80))")
                    if let id {
                        await output(
                            errorResponse(
                                id: id,
                                message:
                                    "HTTP \(reply.status) from \(endpoint.url.absoluteString): \(reply.errorMessage ?? "")"
                            ))
                    }
                    continue
                }
                for message in reply.messages { await output(message) }
            } catch {
                summary.errors += 1
                log?("forward failed: \(error)")
                if let id {
                    await output(
                        errorResponse(
                            id: id,
                            message:
                                "Timeline is not reachable at \(endpoint.url.absoluteString): \(error.localizedDescription)"
                        ))
                }
            }
        }
        if let sid = summary.sessionId {
            _ = try? await post(nil, endpoint: endpoint, sessionId: sid, session: session, method: "DELETE")
        }
        return summary
    }

    struct Reply {
        var status: Int
        var sessionId: String?
        var messages: [String]
        var errorMessage: String?
    }

    static func post(
        _ body: Data?, endpoint: ProxyEndpoint, sessionId: String?, session: URLSession, method: String = "POST"
    )
        async throws -> Reply
    {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let sid = http?.value(forHTTPHeaderField: "Mcp-Session-Id")
        var messages: [String] = []
        var errorMessage: String?
        if status >= 400 {
            errorMessage =
                ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                ?? String(decoding: data, as: UTF8.self)
        } else if contentType.hasPrefix("text/event-stream") {
            messages = sseMessages(in: String(decoding: data, as: UTF8.self))
        } else if !data.isEmpty {
            messages = [String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return Reply(status: status, sessionId: sid, messages: messages, errorMessage: errorMessage)
    }

    /// The `data:` payloads of an SSE body, one string per event (multi-line data joined), empty ones skipped.
    public static func sseMessages(in text: String) -> [String] {
        var messages: [String] = []
        var current: [String] = []
        func flush() {
            let joined = current.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { messages.append(joined) }
            current = []
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("data:") {
                var payload = line.dropFirst(5)
                if payload.hasPrefix(" ") { payload = payload.dropFirst() }
                current.append(String(payload))
            }
        }
        flush()
        return messages
    }

    static func requestId(in line: String) -> JSONValue? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return nil }
        guard json["method"] != nil else { return nil }
        return json["id"]
    }

    static func errorResponse(id: JSONValue, message: String) -> String {
        let response: JSONValue = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": .string(message)]]
        return (try? ProjectCodec.encode(response)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
