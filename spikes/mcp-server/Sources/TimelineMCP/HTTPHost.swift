import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

/// Minimal NIO listener that routes HTTP requests to per-session StatefulHTTPServerTransports.
/// The SDK provides the transport (request->response + SSE) but NOT the socket listener; this is the glue.
actor HTTPHost {
    typealias ServerFactory = @Sendable () async -> Server
    private let port: Int, endpoint: String, factory: ServerFactory
    private var sessions: [String: (Server, StatefulHTTPServerTransport)] = [:]

    init(port: Int, endpoint: String = "/mcp", factory: @escaping ServerFactory) { self.port = port; self.endpoint = endpoint; self.factory = factory }

    func run() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap { ch.pipeline.addHandler(Handler(host: self)) }
            }
            .bind(host: "127.0.0.1", port: port).get()
        log("HTTP listening on http://127.0.0.1:\(port)\(endpoint)")
        try await channel.closeFuture.get()
    }

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        guard req.path == endpoint else { return .error(statusCode: 404, .invalidRequest("Not Found")) }
        if let sid = req.header(HTTPHeaderName.sessionID) {
            guard let (_, transport) = sessions[sid] else { return .error(statusCode: 404, .invalidRequest("Session not found")) }
            let resp = await transport.handleRequest(req)
            if req.method == "DELETE", resp.statusCode == 200 { sessions[sid] = nil; log("session \(sid.prefix(8)) closed") }
            return resp
        }
        guard req.method == "POST", let body = req.body, isInitialize(body) else {
            return .error(statusCode: 400, .invalidRequest("Missing \(HTTPHeaderName.sessionID) header"))
        }
        struct Fixed: SessionIDGenerator { let id: String; func generateSessionID() -> String { id } }
        let sid = UUID().uuidString
        // Default pipeline includes OriginValidator.localhost() (Host + Origin checks) - DNS-rebinding protection is built in.
        let transport = StatefulHTTPServerTransport(sessionIDGenerator: Fixed(id: sid), validationPipeline: nil)
        let server = await factory()
        do { try await server.start(transport: transport) } catch { return .error(statusCode: 500, .internalError("\(error)")) }
        sessions[sid] = (server, transport)
        let resp = await transport.handleRequest(req)
        if case .error = resp { sessions[sid] = nil; await transport.disconnect() } else { log("session \(sid.prefix(8)) created") }
        return resp
    }
}

private final class Handler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let host: HTTPHost
    private var head: HTTPRequestHead?
    private var body = Data()
    init(host: HTTPHost) { self.host = host }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): head = h; body = Data()
        case .body(let buf): body.append(contentsOf: buf.readableBytesView)
        case .end:
            guard let h = head else { return }
            head = nil
            var headers: [String: String] = [:]
            for (n, v) in h.headers { headers[n] = headers[n].map { $0 + ", " + v } ?? v }
            let req = HTTPRequest(method: h.method.rawValue, headers: headers, body: body.isEmpty ? nil : body,
                                  path: String(h.uri.split(separator: "?").first ?? Substring(h.uri)))
            nonisolated(unsafe) let ctx = context
            let loop = context.eventLoop
            Task { [host] in
                let resp = await host.handle(req)
                let rh = { var r = HTTPResponseHead(version: h.version, status: .init(statusCode: resp.statusCode)); for (n, v) in resp.headers { r.headers.add(name: n, value: v) }; return r }()
                loop.execute { ctx.write(self.wrapOutboundOut(.head(rh)), promise: nil); ctx.flush() }
                if case .stream(let stream, _) = resp {
                    for try await chunk in stream {
                        loop.execute { ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: chunk)))), promise: nil) }
                    }
                } else if let d = resp.bodyData {
                    loop.execute { ctx.write(self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: d)))), promise: nil) }
                }
                loop.execute { ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil) }
            }
        }
    }
}

/// SDK's JSONRPCMessageKind is internal, so sniff the initialize request ourselves.
private func isInitialize(_ body: Data) -> Bool {
    ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["method"] as? String == "initialize"
}
