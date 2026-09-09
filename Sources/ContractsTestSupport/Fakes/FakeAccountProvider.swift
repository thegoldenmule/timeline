import Contracts
import Foundation
import TimelineCore

/// An `AccountProvider` that connects scripted accounts without a browser. `connect` returns the next
/// of `scriptedAccounts` (default: `Fixtures.connectedGoogleAccount` with the requested scopes) or
/// throws `failNextConnect`; `accessToken` vends `fake-token-<n>` for an hour and counts requests;
/// `setTokenStatus(.reauthorizationRequired, for:)` makes token requests and refreshes throw the way a
/// revoked grant does; `changes` yields the full list after every mutation.
public actor FakeAccountProvider: AccountProvider {
    public struct ConnectCall: Sendable, Hashable {
        public var scopes: [String]
        public var loginHint: String?

        public init(scopes: [String], loginHint: String?) {
            self.scopes = scopes
            self.loginHint = loginHint
        }
    }

    public nonisolated let kind: AccountProviderKind = .google
    public nonisolated let isConfigured: Bool
    public private(set) var connected: [ConnectedAccount]
    public private(set) var scriptedAccounts: [ConnectedAccount] = []
    public private(set) var failNextConnect: AccountError?
    public private(set) var connectCalls: [ConnectCall] = []
    public private(set) var tokenRequests = 0
    public private(set) var disconnected: [String] = []
    public private(set) var refreshed: [String] = []
    private var tokenCounter = 0
    private let clock: any Clock
    private let broadcaster = Broadcaster<[ConnectedAccount]>()

    /// Lifetime of every vended token: one hour.
    public static let tokenLifetime: TimeInterval = 3600

    public init(configured: Bool = true, accounts: [ConnectedAccount] = [], clock: any Clock = SystemClock()) {
        self.isConfigured = configured
        self.connected = accounts
        self.clock = clock
    }

    // MARK: AccountProvider

    public func accounts() -> [ConnectedAccount] { connected }

    @MainActor public func connect(scopes: [String], loginHint: String?) async throws -> ConnectedAccount {
        try await performConnect(scopes: scopes, loginHint: loginHint)
    }

    public func disconnect(_ id: String) throws {
        guard let index = connected.firstIndex(where: { $0.id == id }) else { throw AccountError.notConnected(id) }
        connected.remove(at: index)
        disconnected.append(id)
        broadcaster.send(connected)
    }

    public func refresh(_ id: String) throws -> ConnectedAccount {
        guard let index = connected.firstIndex(where: { $0.id == id }) else { throw AccountError.notConnected(id) }
        if case .reauthorizationRequired(let reason) = connected[index].tokenStatus {
            throw AccountError.reauthorizationRequired(reason)
        }
        let now = clock.now()
        connected[index].refreshedAt = now
        connected[index].tokenStatus = .valid(expiresAt: now.addingTimeInterval(Self.tokenLifetime))
        refreshed.append(id)
        broadcaster.send(connected)
        return connected[index]
    }

    public func accessToken(for id: String, minimumLifetime: Duration) throws -> AccessToken {
        guard let index = connected.firstIndex(where: { $0.id == id }) else { throw AccountError.notConnected(id) }
        if case .reauthorizationRequired(let reason) = connected[index].tokenStatus {
            throw AccountError.reauthorizationRequired(reason)
        }
        tokenRequests += 1
        tokenCounter += 1
        let expiresAt = clock.now().addingTimeInterval(Self.tokenLifetime)
        if connected[index].tokenStatus == .expired {
            connected[index].tokenStatus = .valid(expiresAt: expiresAt)
            broadcaster.send(connected)
        }
        return AccessToken(value: "fake-token-\(tokenCounter)", expiresAt: expiresAt, scopes: connected[index].scopes)
    }

    public nonisolated var changes: AsyncStream<[ConnectedAccount]> { broadcaster.subscribe() }

    // MARK: Scripting

    /// Accounts `connect` returns, in order, before falling back to the fixture.
    public func setScriptedAccounts(_ accounts: [ConnectedAccount]) { scriptedAccounts = accounts }

    /// The next `connect` throws this once.
    public func setFailNextConnect(_ error: AccountError?) { failNextConnect = error }

    /// Adds or replaces a connected account without a `connect` call and broadcasts.
    public func add(_ account: ConnectedAccount) {
        connected.removeAll { $0.id == account.id }
        connected.append(account)
        broadcaster.send(connected)
    }

    /// Sets the token status of a connected account and broadcasts; `.reauthorizationRequired` makes
    /// `accessToken(for:)` and `refresh` throw.
    public func setTokenStatus(_ status: AccountTokenStatus, for id: String) throws {
        guard let index = connected.firstIndex(where: { $0.id == id }) else { throw AccountError.notConnected(id) }
        connected[index].tokenStatus = status
        broadcaster.send(connected)
    }

    private func performConnect(scopes: [String], loginHint: String?) throws -> ConnectedAccount {
        connectCalls.append(ConnectCall(scopes: scopes, loginHint: loginHint))
        guard isConfigured else { throw AccountError.notConfigured("FakeAccountProvider(configured: false)") }
        if let error = failNextConnect {
            failNextConnect = nil
            throw error
        }
        let now = clock.now()
        var account: ConnectedAccount
        if !scriptedAccounts.isEmpty {
            account = scriptedAccounts.removeFirst()
        } else {
            account = Fixtures.connectedGoogleAccount
            account.scopes = scopes
            account.connectedAt = now
            account.refreshedAt = now
            account.tokenStatus = .valid(expiresAt: now.addingTimeInterval(Self.tokenLifetime))
        }
        connected.removeAll { $0.id == account.id }
        connected.append(account)
        broadcaster.send(connected)
        return account
    }
}
