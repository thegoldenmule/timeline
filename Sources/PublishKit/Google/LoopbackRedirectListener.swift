import Contracts
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

/// The loopback half of the desktop OAuth flow (publish-plan.md D1): binds `127.0.0.1:0`, accepts one
/// `GET /callback`, verifies `state`, captures `code` or `error`, answers a static "You can close this
/// window" page, and closes its port. Anything else on the port (a browser's `/favicon.ico`) is a 404
/// that keeps the listener open. `waitForCode` throws `AccountError.cancelled` after `timeout`,
/// `AccountError.denied` for an `error` parameter, and `AccountError.protocolError` for a wrong state.
public actor LoopbackRedirectListener {
    public enum Outcome: Sendable, Hashable {
        case code(String)
        case denied(String)
        case stateMismatch
    }

    public static let defaultTimeout: Duration = .seconds(300)

    public let expectedState: String
    public let path: String
    public let timeout: Duration
    private var group: MultiThreadedEventLoopGroup?
    private var channel: (any Channel)?
    private let outcome: AsyncStream<Outcome>
    private let continuation: AsyncStream<Outcome>.Continuation

    public init(expectedState: String, path: String = "/callback", timeout: Duration = defaultTimeout) {
        self.expectedState = expectedState
        self.path = path
        self.timeout = timeout
        (outcome, continuation) = AsyncStream<Outcome>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// The bound port, nil before `start` or after the listener closed.
    public var port: Int? { channel?.localAddress?.port }

    /// The bound address (`127.0.0.1`), nil before `start` or after the listener closed.
    public var boundAddress: String? { channel?.localAddress?.ipAddress }

    /// The `redirect_uri` for the authorization request: `http://127.0.0.1:<port><path>`.
    public var redirectURI: URL? { port.flatMap { URL(string: "http://127.0.0.1:\($0)\(path)") } }

    /// Binds the port and returns the redirect URI.
    @discardableResult public func start() async throws -> URL {
        if let redirectURI { return redirectURI }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let handlerConfiguration = CallbackHandler.Configuration(
            path: path, expectedState: expectedState,
            deliver: { [continuation] outcome in continuation.yield(outcome) })
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(CallbackHandler(configuration: handlerConfiguration))
                }
            }
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            try? await group.shutdownGracefully()
            self.group = nil
            throw AccountError.network("could not bind the loopback redirect listener: \(error)")
        }
        guard let redirectURI else {
            await stop()
            throw AccountError.network("the loopback redirect listener has no port")
        }
        return redirectURI
    }

    /// Waits for the one callback, then closes the port whatever the outcome.
    public func waitForCode() async throws -> String {
        let received: Outcome? = try await withThrowingTaskGroup(of: Outcome?.self) { group in
            group.addTask { [outcome] in
                var iterator = outcome.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await stop()
        switch received {
        case .code(let code): return code
        case .denied(let reason): throw AccountError.denied(reason)
        case .stateMismatch: throw AccountError.protocolError("state mismatch on the redirect")
        case nil: throw AccountError.cancelled
        }
    }

    /// Closes the port; safe to call more than once.
    public func stop() async {
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        if let group {
            try? await group.shutdownGracefully()
        }
        group = nil
    }
}

/// One request on the loopback port. Runs on the event loop; delivers the outcome through a closure and
/// closes the connection after answering.
private final class CallbackHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    struct Configuration: Sendable {
        var path: String
        var expectedState: String
        var deliver: @Sendable (LoopbackRedirectListener.Outcome) -> Void
    }

    private static let page = """
        <!doctype html><html><head><meta charset="utf-8"><title>Timeline</title>
        <style>body{font-family:-apple-system,sans-serif;margin:3em;color:#222}</style></head>
        <body><h1>Connected</h1><p>You can close this window and return to Timeline.</p></body></html>
        """

    private let configuration: Configuration
    private var head: HTTPRequestHead?
    private let delivered = Mutex(false)

    init(configuration: Configuration) { self.configuration = configuration }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): head = h
        case .body: break
        case .end:
            guard let h = head else { return }
            head = nil
            respond(to: h, context: context)
        }
    }

    private func respond(to head: HTTPRequestHead, context: ChannelHandlerContext) {
        let components = URLComponents(string: head.uri)
        let requestPath = components?.path ?? head.uri
        guard head.method == .GET, requestPath == configuration.path else {
            write(status: .notFound, body: "Not found", contentType: "text/plain; charset=utf-8", context: context)
            return
        }
        let query = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let outcome: LoopbackRedirectListener.Outcome
        let status: HTTPResponseStatus
        let body: String
        if query["state"] != configuration.expectedState {
            outcome = .stateMismatch
            status = .badRequest
            body = "State mismatch. Return to Timeline and try again."
        } else if let error = query["error"] {
            outcome = .denied(error)
            status = .ok
            body = Self.page.replacingOccurrences(of: "<h1>Connected</h1>", with: "<h1>Not connected</h1>")
        } else if let code = query["code"], !code.isEmpty {
            outcome = .code(code)
            status = .ok
            body = Self.page
        } else {
            outcome = .stateMismatch
            status = .badRequest
            body = "Missing code."
        }
        let type = status == .ok ? "text/html; charset=utf-8" : "text/plain; charset=utf-8"
        write(status: status, body: body, contentType: type, context: context)
        let first = delivered.withLock { flag -> Bool in
            defer { flag = true }
            return !flag
        }
        if first { configuration.deliver(outcome) }
    }

    private func write(status: HTTPResponseStatus, body: String, contentType: String, context: ChannelHandlerContext) {
        var head = HTTPResponseHead(version: .http1_1, status: status)
        let data = Data(body.utf8)
        head.headers.add(name: "Content-Type", value: contentType)
        head.headers.add(name: "Content-Length", value: String(data.count))
        head.headers.add(name: "Cache-Control", value: "no-store")
        head.headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: data)))), promise: nil)
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        nonisolated(unsafe) let ctx = context
        promise.futureResult.whenComplete { _ in ctx.close(promise: nil) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
