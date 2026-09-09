import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import AgentKit

/// A curl-style JSON-RPC client over `URLSession` against the live host on 127.0.0.1: the transcript of
/// spikes/mcp-server/curl-transcript.txt, replayed.
struct MCPTestClient: Sendable {
    var url: URL
    var token: String?
    var sessionId: String?
    var origin: String?
    var session = URLSession(configuration: .ephemeral)

    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
        /// JSON-RPC messages: the JSON body, or every `data:` event of an SSE body.
        var messages: [JSONValue]

        var result: JSONValue? { messages.last?["result"] }
        var error: JSONValue? { messages.last?["error"] }
    }

    func post(_ json: JSONValue, method: String = "POST", extraHeaders: [String: String] = [:]) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        if method != "DELETE" { request.httpBody = try ProjectCodec.encode(json) }
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
        return Reply(
            status: http.statusCode, headers: headers, body: data,
            messages: MCPTestClient.messages(in: data, contentType: headers["content-type"] ?? ""))
    }

    static func messages(in data: Data, contentType: String) -> [JSONValue] {
        if contentType.hasPrefix("text/event-stream") {
            let text = String(decoding: data, as: UTF8.self)
            return text.split(separator: "\n").filter { $0.hasPrefix("data:") }.compactMap { line in
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty else { return nil }
                return try? ProjectCodec.decode(JSONValue.self, from: Data(payload.utf8))
            }
        }
        return (try? ProjectCodec.decode(JSONValue.self, from: data)).map { [$0] } ?? []
    }

    static let initialize: JSONValue = [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "0"],
        ],
    ]

    static func call(_ id: Int, _ tool: String, _ arguments: JSONValue) -> JSONValue {
        [
            "jsonrpc": "2.0", "id": .number(Double(id)), "method": "tools/call",
            "params": ["name": .string(tool), "arguments": arguments],
        ]
    }

    /// initialize + notifications/initialized, returning a client bound to the new session.
    mutating func handshake() async throws -> Reply {
        let reply = try await post(MCPTestClient.initialize)
        sessionId = reply.headers["mcp-session-id"]
        if sessionId != nil { _ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"]) }
        return reply
    }
}

@Suite(.serialized) struct MCPServerHostTests {
    struct Harness {
        var services: TestServices
        var host: MCPServerHost
        var info: MCPConnectionInfo
        var log: LogSink

        static func make(configuration: MCPServerHost.Configuration = .init(), policy: ApprovalPolicy = .standard)
            async throws -> Harness
        {
            let services = try await TestServices.make(approvalPolicy: policy)
            let context = services.toolContext(actor: .human, sessionId: nil)
            let registry = await EditorTools.standard(context: context)
            let log = LogSink()
            var configuration = configuration
            configuration.log = { line in log.append(line) }
            let host = MCPServerHost(registry: registry, context: context, configuration: configuration)
            let info = try await host.start()
            return Harness(services: services, host: host, info: info, log: log)
        }

        func client() -> MCPTestClient { MCPTestClient(url: info.url, token: info.token) }
    }

    final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    @Test func startsOnAnEphemeralLocalhostPortWithConnectionInfo() async throws {
        let h = try await Harness.make()
        defer { Task { await h.host.stop() } }
        #expect(h.info.url.host == "127.0.0.1" && (h.info.url.port ?? 0) > 0 && h.info.url.path == "/mcp")
        #expect(h.info.approvalURL.path == "/approval" && h.info.approvalURL.port == h.info.url.port)
        #expect(h.info.token.count >= 32)
        #expect(h.info.toolAccess.bearerToken == h.info.token && h.info.toolAccess.serverName == "timeline")
        #expect(h.info.claudeMCPAddCommand.contains("--transport http timeline \(h.info.url.absoluteString)"))
        #expect(await h.host.connectionInfo == h.info)
        #expect(await h.host.isRunning)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentkit-\(UUID().uuidString)/mcp.json")
        try h.info.writeProxyConfiguration(to: file)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String]
        #expect(written?["url"] == h.info.url.absoluteString && written?["token"] == h.info.token)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        await h.host.stop()
        #expect(await !h.host.isRunning)
    }

    @Test func requestsWithoutTheBearerTokenAreRefused() async throws {
        let h = try await Harness.make()
        defer { Task { await h.host.stop() } }
        var anonymous = h.client()
        anonymous.token = nil
        let reply = try await anonymous.post(MCPTestClient.initialize)
        #expect(reply.status == 401)
        #expect(reply.headers["www-authenticate"]?.hasPrefix("Bearer") == true)
        #expect(reply.error?["message"]?.stringValue?.contains("bearer") == true)
        var wrong = h.client()
        wrong.token = "nope"
        #expect(try await wrong.post(MCPTestClient.initialize).status == 401)
        var approval = h.client()
        approval.url = h.info.approvalURL
        approval.token = nil
        #expect(try await approval.post(["tool_name": "x"]).status == 401)
        #expect(await h.host.sessionCount == 0)
    }

    @Test func originAndHostValidationStillApply() async throws {
        let h = try await Harness.make()
        defer { Task { await h.host.stop() } }
        var evil = h.client()
        evil.origin = "http://evil.example"
        #expect(try await evil.post(MCPTestClient.initialize).status == 403)
        var good = h.client()
        good.origin = "http://127.0.0.1:\(h.info.url.port!)"
        #expect(try await good.handshake().status == 200)
        let badHost = try await h.client().post(MCPTestClient.initialize, extraHeaders: ["Host": "evil.example"])
        #expect(badHost.status == 421)
        #expect(await h.host.sessionCount == 1)
    }

    @Test func curlStyleTranscriptSucceedsWithTheToken() async throws {
        let h = try await Harness.make()
        defer { Task { await h.host.stop() } }
        var client = h.client()
        let initialized = try await client.handshake()
        #expect(
            initialized.status == 200 && initialized.headers["content-type"]?.hasPrefix("text/event-stream") == true)
        #expect(client.sessionId != nil)
        #expect(initialized.result?["serverInfo"]?["name"] == "timeline")
        #expect(initialized.result?["capabilities"]?["tools"] != nil)
        #expect(initialized.result?["instructions"]?.stringValue?.contains("project_list") == true)

        let list = try await client.post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try #require(list.result?["tools"]?.arrayValue)
        #expect(tools.map { $0["name"]?.stringValue ?? "" } == EditorTools.names)
        let apply = try #require(tools.first { $0["name"] == "timeline_apply" })
        #expect(
            apply["annotations"]?["idempotentHint"] == .bool(true)
                && apply["annotations"]?["readOnlyHint"] == .bool(false))
        #expect(apply["outputSchema"]?["properties"]?["version"] != nil)
        #expect(apply["inputSchema"]?["$defs"]?["op_moveClip"] != nil)
        let describe = try #require(tools.first { $0["name"] == "project_describe" })
        #expect(
            describe["annotations"]?["readOnlyHint"] == .bool(true)
                && describe["annotations"]?["title"] == "Describe project")

        let listed = try await client.post(MCPTestClient.call(3, "project_list", [:]))
        #expect(listed.result?["isError"] == nil)
        #expect(listed.result?["structuredContent"]?["count"]?.intValue == 1)
        #expect(listed.result?["content"]?[0]?["type"] == "text")
        let projectId = try #require(listed.result?["structuredContent"]?["projects"]?[0]?["projectId"]?.stringValue)
        let version = try #require(listed.result?["structuredContent"]?["projects"]?[0]?["version"]?.intValue)

        let clip = try #require(Fixtures.firstVideoClip(in: await h.services.store.state()))
        let move: JSONValue = [
            "projectId": .string(projectId), "expectedVersion": .number(Double(version)), "commandId": "cmd-A",
            "ops": [
                [
                    "type": "moveClip", "clipId": .string(clip.id.rawValue),
                    "to": ["start": ["v": 48048, "ts": 24000]], "mode": "overwrite",
                ]
            ],
        ]
        let applied = try await client.post(MCPTestClient.call(4, "timeline_apply", move))
        #expect(applied.result?["isError"] == nil, "\(applied.messages)")
        let applied1 = try #require(applied.result?["structuredContent"]?["version"]?.intValue)
        #expect(applied1 > version)
        #expect(
            applied.result?["structuredContent"]?["changedIds"]?.arrayValue?.contains(.string(clip.id.rawValue)) == true
        )

        let retry = try await client.post(MCPTestClient.call(5, "timeline_apply", move))
        #expect(retry.result?["structuredContent"]?["status"] == "replayed")
        #expect(retry.result?["structuredContent"]?["version"]?.intValue == applied1)

        var stale = move
        stale["commandId"] = "cmd-B"
        let rejected = try await client.post(MCPTestClient.call(6, "timeline_apply", stale))
        #expect(rejected.result?["isError"] == .bool(true))
        #expect(rejected.result?["structuredContent"]?["error"] == "staleVersion")
        #expect(rejected.result?["structuredContent"]?["changedSince"]?["transactions"]?.arrayValue?.count == 1)

        let assetId = try #require(clip.assetId?.rawValue)
        let look = try await client.post(
            MCPTestClient.call(
                7, "look_at", ["assetId": .string(assetId), "timestamps": [["v": 0, "ts": 24000]], "height": 40]))
        let blocks = try #require(look.result?["content"]?.arrayValue)
        #expect(blocks.count == 2 && blocks[1]["type"] == "image" && blocks[1]["mimeType"] == "image/png")
        let png = Data(base64Encoded: blocks[1]["data"]?.stringValue ?? "")
        #expect(png?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        let unknown = try await client.post(MCPTestClient.call(8, "nope", [:]))
        #expect(unknown.error?["message"]?.stringValue?.contains("Unknown tool") == true)

        // The store saw the session's actor, receipts were recorded, and the host logged the calls.
        let sessionId = try #require(client.sessionId)
        #expect(await h.services.store.receivedCommands.last?.actor == .agent(sessionId: sessionId))
        #expect(
            await h.services.receipts.receipts.map(\.toolName) == [
                "project_list", "timeline_apply", "timeline_apply", "timeline_apply", "look_at",
            ])
        #expect(
            await h.host.calls.map(\.tool) == [
                "project_list", "timeline_apply", "timeline_apply", "timeline_apply", "look_at",
            ])
        #expect(await h.host.calls.map(\.isError) == [false, false, false, true, false])
        #expect(h.log.all.contains { $0.contains("tools/call timeline_apply") })

        let closed = try await client.post([:], method: "DELETE")
        #expect(closed.status == 200)
        #expect(await h.host.sessionCount == 0)
        let afterClose = try await client.post(["jsonrpc": "2.0", "id": 9, "method": "tools/list"])
        #expect(afterClose.status == 404)
        var noSession = h.client()
        noSession.sessionId = nil
        #expect(try await noSession.post(["jsonrpc": "2.0", "id": 10, "method": "tools/list"]).status == 400)
    }

    @Test func idleSessionsAreSwept() async throws {
        var configuration = MCPServerHost.Configuration()
        configuration.idleTimeout = .milliseconds(150)
        configuration.sweepInterval = .milliseconds(50)
        let h = try await Harness.make(configuration: configuration)
        defer { Task { await h.host.stop() } }
        var client = h.client()
        _ = try await client.handshake()
        var second = h.client()
        _ = try await second.handshake()
        #expect(await h.host.sessionCount == 2)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await h.host.sessionCount == 0)
        #expect(try await client.post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]).status == 404)
        #expect(h.log.all.filter { $0.contains("expired") }.count == 2)
    }

    @Test func approvalRoundTripThroughTheHook() async throws {
        let h = try await Harness.make()
        defer { Task { await h.host.stop() } }
        var hookClient = h.client()
        hookClient.url = h.info.approvalURL
        let hook = hookClient

        // A tool the policy does not gate is allowed at once.
        let free = try await hook.post(["tool_name": "mcp__timeline__project_list", "tool_input": [:]])
        #expect(free.status == 200)
        #expect(free.messages.first?["hookSpecificOutput"]?["permissionDecision"] == "allow")
        #expect(free.messages.first?["hookSpecificOutput"]?["hookEventName"] == "PreToolUse")

        // A gated tool without a token is allowed too: the server-side gate raises the card.
        let first = try await hook.post([
            "tool_name": "mcp__timeline__render_export", "tool_input": ["preset": "reel9x16"],
        ])
        #expect(first.messages.first?["hookSpecificOutput"]?["permissionDecision"] == "allow")

        // Mint a pending request (what the tool does), then the hook blocks on the retry until the grant.
        let decision = await h.services.approvals.check(
            tool: "render_export", input: ToolInput(["preset": "reel9x16"]), estimate: Estimate(seconds: 30),
            actor: .agent(sessionId: "s"), sessionId: "s")
        guard case .required(let request) = decision else {
            Issue.record("expected a request")
            return
        }
        let waiting = Task {
            try await hook.post([
                "tool_name": "mcp__timeline__render_export", "hook_event_name": "PreToolUse",
                "tool_input": ["preset": "reel9x16", "approvalToken": .string(request.token.rawValue)],
            ])
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!waiting.isCancelled)
        await h.services.approvals.grant(request.token)
        let granted = try await waiting.value
        #expect(granted.status == 200)
        #expect(granted.messages.first?["hookSpecificOutput"]?["permissionDecision"] == "allow", "\(granted.messages)")
        #expect(
            granted.messages.first?["hookSpecificOutput"]?["permissionDecisionReason"]?.stringValue?.contains(
                "accepted") == true)
        // The token is still usable by the server-side gate (the hook did not consume it).
        #expect(await h.services.approvals.consume(request.token))

        // A denial through the host's gate answers deny.
        guard
            case .required(let second) = await h.host.approvalGate.check(
                tool: "render_export", input: ToolInput(), estimate: .none, actor: .human, sessionId: nil)
        else {
            Issue.record("expected a request")
            return
        }
        let denying = Task {
            try await hook.post([
                "tool_name": "mcp__timeline__render_export",
                "tool_input": ["preset": "reel9x16", "approvalToken": .string(second.token.rawValue)],
            ])
        }
        try await Task.sleep(for: .milliseconds(100))
        await h.host.approvalGate.deny(second.token, reason: "not now")
        let denied = try await denying.value
        #expect(denied.messages.first?["hookSpecificOutput"]?["permissionDecision"] == "deny")
        #expect(
            denied.messages.first?["hookSpecificOutput"]?["permissionDecisionReason"]?.stringValue?.contains("not now")
                == true)

        let malformed = try await hook.post("not an object")
        #expect(malformed.status == 400)
        #expect(h.log.all.contains { $0.contains("approval render_export -> allow") })

        // A tool that supplies a presentation gets it back on the request the host's gate minted, so the
        // card raised for the hook path shows the tool's details, not the generic summary.
        guard
            case .required(let presented) = await h.host.approvalGate.check(
                tool: "publish_youtube", input: ToolInput(["title": "Band rehearsal"]), estimate: .none,
                presentation: Fixtures.publishPresentation, actor: .human, sessionId: nil)
        else {
            Issue.record("expected a request")
            return
        }
        #expect(presented.presentation == Fixtures.publishPresentation)
        #expect(presented.inputSummary == Fixtures.publishPresentation.summary)
        #expect(await h.services.approvals.pending().contains { $0.token == presented.token })
        #expect(await h.services.approvals.checks.last?.presentation == Fixtures.publishPresentation)
        let output = ToolOutput.approvalRequired(presented)
        #expect(output.structured?["details"]?.arrayValue?.count == 3)
        #expect(output.structured?["details"]?[0]?["label"] == "Channel")
    }

    @Test func approvalHookTimesOut() async throws {
        var configuration = MCPServerHost.Configuration()
        configuration.approvalTimeout = .milliseconds(100)
        let h = try await Harness.make(configuration: configuration)
        defer { Task { await h.host.stop() } }
        guard
            case .required(let request) = await h.services.approvals.check(
                tool: "render_export", input: ToolInput(), estimate: .none, actor: .human, sessionId: nil)
        else {
            Issue.record("expected a request")
            return
        }
        let decision = await h.host.approvalDecision(
            tool: "render_export", input: ToolInput(["approvalToken": .string(request.token.rawValue)]))
        #expect(decision.decision == "deny" && decision.reason.contains("Timed out"))
    }

    @Test func serverSideGateHoldsOverHTTPToo() async throws {
        let h = try await Harness.make()
        defer { Task { await h.host.stop() } }
        var client = h.client()
        _ = try await client.handshake()
        let first = try await client.post(MCPTestClient.call(2, "render_export", ["preset": "proRes"]))
        #expect(first.result?["structuredContent"]?["status"] == "approval_required")
        let token = try #require(first.result?["structuredContent"]?["approvalToken"]?.stringValue)
        #expect(await h.services.approvals.pending().count == 1)
        await h.host.approvalGate.grant(ApprovalToken(token))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-\(UUID().uuidString)/x.mov")
        let second = try await client.post(
            MCPTestClient.call(
                3, "render_export",
                ["preset": "proRes", "approvalToken": .string(token), "outputPath": .string(out.path)]))
        #expect(second.result?["structuredContent"]?["status"] == "done", "\(second.messages)")
        try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
    }
}
