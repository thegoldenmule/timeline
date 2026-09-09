import Contracts
import Foundation
import Synchronization

/// An `AuthorizationPresenter` that stands in for the browser. It records every URL it was asked to
/// open and, depending on `mode`, performs the loopback callback itself after `callbackDelay`:
/// `.completeCallback` parses `redirect_uri` and `state` from the authorization URL and performs
/// `GET <redirect_uri>?state=<state>&code=<code>` with a plain `URLSession` (the code comes from the
/// `FakeYouTubeServer` when one is given, so the token exchange finds it, else `fake-code-<n>`);
/// `.deny` calls back with `?error=access_denied&state=<state>`; `.ignore` never calls back, for
/// timeout tests.
public final class FakeAuthorizationPresenter: AuthorizationPresenter, Sendable {
    public enum Mode: Sendable, Hashable {
        case completeCallback
        case deny
        case ignore
    }

    private struct State {
        var opened: [URL] = []
        var callbacks: [URL] = []
        var counter = 0
    }

    public let mode: Mode
    public let callbackDelay: Duration
    private let server: FakeYouTubeServer?
    private let sub: String?
    private let state = Mutex(State())

    /// - Parameters:
    ///   - server: when given, `.completeCallback` asks it for an authorization code bound to `sub`
    ///     (or its first seeded account), with the scopes named in the authorization URL.
    public init(
        mode: Mode = .completeCallback, server: FakeYouTubeServer? = nil, sub: String? = nil,
        callbackDelay: Duration = .milliseconds(50)
    ) {
        self.mode = mode
        self.server = server
        self.sub = sub
        self.callbackDelay = callbackDelay
    }

    /// Every authorization URL opened, in order.
    public var openedURLs: [URL] { state.withLock { $0.opened } }

    /// Every callback URL this presenter fetched, in order.
    public var performedCallbacks: [URL] { state.withLock { $0.callbacks } }

    @MainActor public func open(_ authorizationURL: URL) async throws {
        let n = state.withLock { s in
            s.opened.append(authorizationURL)
            s.counter += 1
            return s.counter
        }
        guard mode != .ignore else { return }
        let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let redirect = query["redirect_uri"].flatMap(URL.init(string:)) else {
            throw AccountError.protocolError("authorization URL has no redirect_uri")
        }
        let stateValue = query["state"] ?? ""
        let scopes = (query["scope"] ?? "").split(separator: " ").map(String.init)
        let delay = callbackDelay
        let mode = self.mode
        let server = self.server
        let sub = self.sub
        Task.detached { [self] in
            try? await Task.sleep(for: delay)
            var items: [URLQueryItem] = [URLQueryItem(name: "state", value: stateValue)]
            switch mode {
            case .completeCallback:
                let code: String
                if let server {
                    code = await server.issueAuthorizationCode(for: sub, scopes: scopes)
                } else {
                    code = "fake-code-\(n)"
                }
                items.append(URLQueryItem(name: "code", value: code))
            case .deny: items.append(URLQueryItem(name: "error", value: "access_denied"))
            case .ignore: return
            }
            guard var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false) else { return }
            callback.queryItems = (callback.queryItems ?? []) + items
            guard let url = callback.url else { return }
            self.state.withLock { $0.callbacks.append(url) }
            _ = try? await URLSession.shared.data(from: url)
        }
    }
}
