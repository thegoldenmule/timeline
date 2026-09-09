import Contracts
import Foundation
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix
import TimelineCore

/// What a client needs to reach the server: the endpoint URL and the per-launch bearer token. The app
/// hands it to the embedded runtime, shows it to the user for `claude mcp add`, and writes it to the
/// proxy's config file.
public struct MCPConnectionInfo: Hashable, Sendable, Codable {
    public var serverName: String
    public var url: URL
    public var token: String
    public var approvalURL: URL

    public init(serverName: String, url: URL, token: String, approvalURL: URL) {
        self.serverName = serverName
        self.url = url
        self.token = token
        self.approvalURL = approvalURL
    }

    /// The `ToolAccess` the `AgentRuntime` takes.
    public var toolAccess: ToolAccess {
        ToolAccess(serverName: serverName, endpoint: url, bearerToken: token)
    }

    /// `claude mcp add --transport http <name> <url> --header "Authorization: Bearer <token>"`.
    public var claudeMCPAddCommand: String {
        "claude mcp add --transport http \(serverName) \(url.absoluteString) --header \"Authorization: Bearer \(token)\""
    }

    /// `claude mcp add <name> -- timeline-mcp`, with the proxy reading `mcp.json`.
    public var claudeMCPAddProxyCommand: String { "claude mcp add \(serverName) -- timeline-mcp" }

    /// Writes `{ "url", "token" }` for the stdio proxy (`~/Library/Application Support/Timeline/mcp.json`).
    public func writeProxyConfiguration(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["url": self.url.absoluteString, "token": token, "serverName": serverName],
            options: [.sortedKeys, .prettyPrinted])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static var defaultProxyConfigurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Timeline/mcp.json")
    }
}

/// The MCP server of the editor: swift-sdk 0.12.1 Streamable HTTP over a swift-nio listener bound to
/// 127.0.0.1. One `Server` per HTTP session over the shared editor state (the `ToolContext`), a
/// bearer-token check on every request in front of the SDK's Origin/Host validation, an idle-session
/// sweep (Claude Code never sends DELETE), and a `/approval` endpoint for the runtime's `PreToolUse`
/// hook. The approval gate inside the tools stays authoritative; the hook only improves the UX.
public actor MCPServerHost {
    public struct Configuration: Sendable {
        public var serverName: String
        public var version: String
        public var instructions: String
        /// 0 picks an ephemeral port.
        public var port: Int
        /// The bearer token every request must carry; nil mints a random one per `start()`.
        public var token: String?
        public var mcpPath: String
        public var approvalPath: String
        /// Sessions with no request for this long are closed by the sweep.
        public var idleTimeout: Duration
        public var sweepInterval: Duration
        /// How long `/approval` waits for the human before answering deny.
        public var approvalTimeout: Duration
        /// Where server-side log lines go (tool calls, sessions); nil is silent.
        public var log: (@Sendable (String) -> Void)?

        public init(
            serverName: String = "timeline", version: String = "0.1.0",
            instructions: String =
                "Timeline video editor. Call project_list, then project_describe (level tracks) to get ids and the current version before timeline_apply. Mutations take expectedVersion and an idempotent commandId; a staleVersion error carries a changedSince diff. Expensive tools return approval_required with an approvalToken; retry the same call with the token once the user approved.",
            port: Int = 0, token: String? = nil, mcpPath: String = "/mcp", approvalPath: String = "/approval",
            idleTimeout: Duration = .seconds(600), sweepInterval: Duration = .seconds(30),
            approvalTimeout: Duration = .seconds(600), log: (@Sendable (String) -> Void)? = nil
        ) {
            self.serverName = serverName
            self.version = version
            self.instructions = instructions
            self.port = port
            self.token = token
            self.mcpPath = mcpPath
            self.approvalPath = approvalPath
            self.idleTimeout = idleTimeout
            self.sweepInterval = sweepInterval
            self.approvalTimeout = approvalTimeout
            self.log = log
        }
    }

    public struct CallRecord: Sendable, Hashable {
        public var sessionId: String
        public var tool: String
        public var isError: Bool
        public var at: Date
    }

    public enum HostError: Error, Sendable {
        case notStarted
        case alreadyStarted
        case bindFailed(String)
    }

    private struct Session {
        var server: Server
        var transport: StatefulHTTPServerTransport
        var lastActivity: ContinuousClock.Instant
    }

    public let configuration: Configuration
    private let registry: any ToolRegistry
    private let baseContext: ToolContext
    private let approvals: RecordingApprovalGate
    private var sessions: [String: Session] = [:]
    private var group: MultiThreadedEventLoopGroup?
    private var channel: (any Channel)?
    private var sweep: Task<Void, Never>?
    private var info: MCPConnectionInfo?
    /// Every tool call served, in order (the "server log" the plan wants a test to read).
    public private(set) var calls: [CallRecord] = []
    /// Session ids created so far, in order.
    public private(set) var sessionLog: [String] = []

    /// - Parameters:
    ///   - registry: the tools to expose.
    ///   - context: the shared editor state; each session gets a copy with its own `sessionId` and
    ///     `actor: .agent(sessionId:)`, and with `approvals` wrapped so `/approval` can see verdicts.
    public init(registry: any ToolRegistry, context: ToolContext, configuration: Configuration = Configuration()) {
        self.registry = registry
        self.baseContext = context
        self.approvals = RecordingApprovalGate(wrapping: context.approvals)
        self.configuration = configuration
    }

    /// The gate the sessions use: the app's gate with verdicts recorded, so the approval card may call
    /// either this or the underlying gate.
    public nonisolated var approvalGate: any ApprovalGate { approvals }

    public var connectionInfo: MCPConnectionInfo? { info }
    public var isRunning: Bool { channel != nil }
    public var sessionCount: Int { sessions.count }
    public var port: Int? { channel?.localAddress?.port }

    // MARK: Lifecycle

    @discardableResult
    public func start() async throws -> MCPConnectionInfo {
        guard channel == nil else { throw HostError.alreadyStarted }
        let token = configuration.token ?? MCPServerHost.mintToken()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(HTTPHandler(host: self))
                }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: configuration.port).get()
        } catch {
            try? await group.shutdownGracefully()
            self.group = nil
            throw HostError.bindFailed(String(describing: error))
        }
        self.channel = channel
        let port = channel.localAddress?.port ?? configuration.port
        let info = MCPConnectionInfo(
            serverName: configuration.serverName, url: URL(string: "http://127.0.0.1:\(port)\(configuration.mcpPath)")!,
            token: token, approvalURL: URL(string: "http://127.0.0.1:\(port)\(configuration.approvalPath)")!)
        self.info = info
        sweep = Task { [weak self, interval = configuration.sweepInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.sweepIdleSessions()
            }
        }
        log("listening on \(info.url.absoluteString)")
        return info
    }

    public func stop() async {
        sweep?.cancel()
        sweep = nil
        for (id, session) in sessions {
            await session.server.stop()
            log("session \(id.prefix(8)) closed (stop)")
        }
        sessions.removeAll()
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        if let group {
            try? await group.shutdownGracefully()
        }
        group = nil
        info = nil
    }

    /// Closes sessions idle for longer than `idleTimeout`; returns how many it closed.
    @discardableResult
    public func sweepIdleSessions(now: ContinuousClock.Instant = .now) async -> Int {
        var closed = 0
        for (id, session) in sessions where now - session.lastActivity > configuration.idleTimeout {
            sessions[id] = nil
            await session.server.stop()
            closed += 1
            log("session \(id.prefix(8)) expired")
        }
        return closed
    }

    static func mintToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func log(_ line: String) { configuration.log?("[\(configuration.serverName)-mcp] \(line)") }

    // MARK: Request routing

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard let info else { return .error(statusCode: 503, .internalError("Server not started")) }
        guard MCPServerHost.bearer(of: request) == info.token else {
            log("401 \(request.method) \(request.path ?? "")")
            return .error(
                statusCode: 401, .invalidRequest("Unauthorized: missing or invalid bearer token"),
                extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer realm=\"\(configuration.serverName)\""])
        }
        switch request.path {
        case configuration.mcpPath: return await handleMCP(request)
        case configuration.approvalPath: return await handleApproval(request)
        default: return .error(statusCode: 404, .invalidRequest("Not Found"))
        }
    }

    static func bearer(of request: HTTPRequest) -> String? {
        guard let header = request.header(HTTPHeaderName.authorization) else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        return parts[1]
    }

    private func handleMCP(_ request: HTTPRequest) async -> HTTPResponse {
        if let sid = request.header(HTTPHeaderName.sessionID) {
            guard var session = sessions[sid] else {
                return .error(statusCode: 404, .invalidRequest("Not Found: Invalid or expired session ID"))
            }
            session.lastActivity = .now
            sessions[sid] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                sessions[sid] = nil
                await session.server.stop()
                log("session \(sid.prefix(8)) closed")
            }
            return response
        }
        guard request.method.uppercased() == "POST", let body = request.body, MCPServerHost.isInitialize(body) else {
            return .error(statusCode: 400, .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
        }
        let sid = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionID(id: sid),
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: port), AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(), SessionValidator(),
            ]))
        let server = makeServer(sessionId: sid)
        do {
            try await server.start(transport: transport)
        } catch {
            return .error(statusCode: 500, .internalError(String(describing: error)))
        }
        sessions[sid] = Session(server: server, transport: transport, lastActivity: .now)
        let response = await transport.handleRequest(request)
        if case .error = response {
            sessions[sid] = nil
            await server.stop()
        } else {
            sessionLog.append(sid)
            log("session \(sid.prefix(8)) created")
        }
        return response
    }

    static func isInitialize(_ body: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["method"] as? String == "initialize"
    }

    private struct FixedSessionID: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }

    /// One `Server` per session over the shared registry and a per-session `ToolContext`.
    private func makeServer(sessionId: String) -> Server {
        var sessionContext = baseContext
        sessionContext.sessionId = sessionId
        sessionContext.actor = .agent(sessionId: sessionId)
        sessionContext.approvals = approvals
        let context = sessionContext
        let server = Server(
            name: configuration.serverName, version: configuration.version, instructions: configuration.instructions,
            capabilities: .init(tools: .init(listChanged: false)))
        let registry = self.registry
        Task {
            await server.withMethodHandler(ListTools.self) { [weak self] _ in
                await self?.log("tools/list (\(sessionId.prefix(8)))")
                return ListTools.Result(tools: await registry.list().map(MCPBridge.tool))
            }
            await server.withMethodHandler(CallTool.self) { [weak self] params in
                let input = MCPBridge.input(params.arguments)
                await self?.log("tools/call \(params.name) \(MCPServerHost.summary(input)) (\(sessionId.prefix(8)))")
                let output: ToolOutput
                do {
                    output = try await registry.call(params.name, input: input, context: context)
                } catch ToolError.unknownTool(let name) {
                    throw MCPError.invalidParams("Unknown tool: \(name)")
                } catch let error as ToolError {
                    output = .error(code: "tool_error", message: error.message)
                }
                await self?.record(
                    CallRecord(sessionId: sessionId, tool: params.name, isError: output.isError, at: Date()))
                await self?.log(
                    "  -> \(output.isError ? "error" : output.isApprovalRequired ? "approval_required" : "ok") \(output.text?.prefix(120) ?? "")"
                )
                return MCPBridge.result(output)
            }
        }
        return server
    }

    private func record(_ call: CallRecord) { calls.append(call) }

    static func summary(_ input: ToolInput) -> String {
        let keys = input.arguments.keys.sorted().filter { $0 != "approvalToken" }
        return "{"
            + keys.map { key in
                let v = input.arguments[key]!
                switch v {
                case .string(let s): return "\(key)=\(s.prefix(40))"
                case .number(let n): return "\(key)=\(n == n.rounded() ? String(Int64(n)) : String(n))"
                case .bool(let b): return "\(key)=\(b)"
                case .null: return "\(key)=null"
                case .array(let a): return "\(key)=[\(a.count)]"
                case .object(let o): return "\(key)={\(o.count)}"
                }
            }.joined(separator: ", ") + "}"
    }

    // MARK: Approval endpoint

    /// The `PreToolUse` hook posts Claude Code's hook payload (`tool_name`, `tool_input`, ...) here and
    /// gets the hook's JSON answer back. Decision: tools the policy does not gate are allowed; a call
    /// without a token is allowed (the server-side gate will answer `approval_required` and raise the
    /// card); a call carrying a pending token waits for the human, then answers deny when the token was
    /// denied through this host's gate and allow otherwise (the server-side gate consumes it).
    private func handleApproval(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method.uppercased() == "POST", let body = request.body,
            let payload = try? JSONDecoder().decode(JSONValue.self, from: body), payload.objectValue != nil
        else {
            return .error(statusCode: 400, .invalidRequest("Bad Request: expected a PreToolUse hook payload"))
        }
        let rawName = payload["tool_name"]?.stringValue ?? ""
        let toolName = MCPServerHost.stripServerPrefix(rawName, serverName: configuration.serverName)
        let input = ToolInput(payload["tool_input"]?.objectValue ?? [:])
        let decision = await approvalDecision(tool: toolName, input: input)
        log("approval \(toolName) -> \(decision.decision) (\(decision.reason))")
        let answer: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse", "permissionDecision": decision.decision,
                "permissionDecisionReason": decision.reason,
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])) ?? Data()
        return .data(data, headers: [HTTPHeaderName.contentType: "application/json"])
    }

    public struct HookDecision: Sendable, Hashable {
        public var decision: String
        public var reason: String
    }

    /// The hook decision for a tool call (exposed for tests and the embedded runtime).
    public func approvalDecision(tool: String, input: ToolInput) async -> HookDecision {
        let policy = await approvals.policy
        guard policy.requiresApproval(tool: tool, estimate: .none) || policy.rule(for: tool) != .never else {
            return HookDecision(decision: "allow", reason: "\(tool) needs no approval")
        }
        guard let token = input.approvalToken else {
            return HookDecision(decision: "allow", reason: "\(tool) will ask for approval server-side")
        }
        let deadline = ContinuousClock.now + configuration.approvalTimeout
        while await approvals.isPending(token) {
            if ContinuousClock.now > deadline {
                return HookDecision(decision: "deny", reason: "Timed out waiting for approval of \(tool)")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let reason = await approvals.denialReason(for: token) {
            return HookDecision(decision: "deny", reason: "The user denied \(tool)\(reason.map { ": \($0)" } ?? "")")
        }
        return HookDecision(decision: "allow", reason: "Approval token accepted for \(tool)")
    }

    static func stripServerPrefix(_ name: String, serverName: String) -> String {
        let prefix = "mcp__\(serverName)__"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }
}

/// Wraps the app's `ApprovalGate` and remembers which tokens were denied through it, so the hook can
/// answer `deny` instead of letting the server-side gate mint a fresh request.
public actor RecordingApprovalGate: ApprovalGate {
    private let base: any ApprovalGate
    private var denied: [ApprovalToken: String?] = [:]
    private var granted: Set<ApprovalToken> = []

    public init(wrapping base: any ApprovalGate) { self.base = base }

    public var policy: ApprovalPolicy {
        get async { await base.policy }
    }

    public func check(tool: String, input: ToolInput, estimate: Estimate, actor: Actor, sessionId: String?) async
        -> ApprovalDecision
    {
        await base.check(tool: tool, input: input, estimate: estimate, actor: actor, sessionId: sessionId)
    }

    public func grant(_ token: ApprovalToken) async {
        granted.insert(token)
        await base.grant(token)
    }

    public func deny(_ token: ApprovalToken, reason: String?) async {
        denied[token] = reason
        await base.deny(token, reason: reason)
    }

    public func consume(_ token: ApprovalToken) async -> Bool { await base.consume(token) }

    public func pending() async -> [ApprovalRequest] { await base.pending() }

    public nonisolated var requests: AsyncStream<ApprovalRequest> { base.requests }

    /// True while the underlying gate lists the token as pending.
    public func isPending(_ token: ApprovalToken) async -> Bool {
        await base.pending().contains { $0.token == token }
    }

    /// The reason recorded when `deny` went through this gate; `.some(nil)` for a deny without reason.
    public func denialReason(for token: ApprovalToken) -> String?? {
        guard let entry = denied[token] else { return nil }
        return .some(entry)
    }
}

// MARK: - NIO glue

/// Collects one HTTP request, hands it to the host, and streams the response back (SSE bodies are
/// written chunk by chunk as the transport produces them). Same pattern as the SDK's conformance app.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let host: MCPServerHost
    private var head: HTTPRequestHead?
    private var body = Data()

    init(host: MCPServerHost) { self.host = host }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body = Data()
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let h = head else { return }
            head = nil
            var headers: [String: String] = [:]
            for (name, value) in h.headers { headers[name] = headers[name].map { $0 + ", " + value } ?? value }
            let path = String(h.uri.split(separator: "?", maxSplits: 1).first ?? Substring(h.uri))
            let request = HTTPRequest(
                method: h.method.rawValue, headers: headers, body: body.isEmpty ? nil : body, path: path)
            let keepAlive = h.isKeepAlive
            let version = h.version
            let loop = context.eventLoop
            let writer = ResponseWriter(context: context)
            Task { [host] in
                let response = await host.handle(request)
                var responseHead = HTTPResponseHead(version: version, status: .init(statusCode: response.statusCode))
                for (name, value) in response.headers { responseHead.headers.add(name: name, value: value) }
                if !keepAlive { responseHead.headers.replaceOrAdd(name: "Connection", value: "close") }
                let bodyData = response.bodyData
                switch response {
                case .stream(let stream, _):
                    let head = responseHead
                    loop.execute { writer.writeHead(head) }
                    do {
                        for try await chunk in stream {
                            loop.execute { writer.writeBody(chunk) }
                        }
                    } catch {}
                    loop.execute { writer.end(close: !keepAlive) }
                default:
                    responseHead.headers.replaceOrAdd(name: "Content-Length", value: String(bodyData?.count ?? 0))
                    let head = responseHead
                    loop.execute {
                        writer.writeHead(head)
                        if let bodyData { writer.writeBody(bodyData) }
                        writer.end(close: !keepAlive)
                    }
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

/// Writes response parts on the channel's event loop; the context is only ever touched there.
private final class ResponseWriter: @unchecked Sendable {
    private let context: ChannelHandlerContext

    init(context: ChannelHandlerContext) { self.context = context }

    func writeHead(_ head: HTTPResponseHead) {
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        context.flush()
    }

    func writeBody(_ data: Data) {
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: data)))), promise: nil)
    }

    func end(close: Bool) {
        let promise: EventLoopPromise<Void>? = close ? context.eventLoop.makePromise() : nil
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: promise)
        if close {
            nonisolated(unsafe) let ctx = context
            promise?.futureResult.whenComplete { _ in ctx.close(promise: nil) }
        }
    }
}
