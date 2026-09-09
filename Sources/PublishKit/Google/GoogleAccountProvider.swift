import Contracts
import Foundation
import TimelineCore

/// The Google `AccountProvider` (publish-plan.md D1 to D4, D13, D14): connect = PKCE -> loopback listener
/// -> `presenter.open` -> code -> exchange -> `id_token` sub and email -> `channels.list` -> persist the
/// credential (token store) and the record (`accounts.json`) -> `changes`. Access tokens are cached in
/// memory per account and refreshed when they would not outlive `minimumLifetime`; an `invalid_grant`
/// marks the record `reauthorizationRequired`, persists it, and throws. Disconnect revokes (best
/// effort), deletes the credential and the record, and clears the quota cache immediately.
public actor GoogleAccountProvider: AccountProvider {
    /// A record older than this is refreshed on load (YouTube policy III.E.4.c: 30 days).
    public static let recordMaxAge: TimeInterval = 30 * 86_400

    public nonisolated let kind: AccountProviderKind = .google
    public nonisolated let isConfigured: Bool
    public let configuration: GoogleClientConfiguration?
    public let accountsFile: AccountsFile

    private let tokenStore: any TokenStore
    private let presenter: any AuthorizationPresenter
    private let oauth: GoogleOAuthClient?
    private let api: YouTubeAPI
    private let clock: any Clock
    private let listenerTimeout: Duration
    private let recordMaxAge: TimeInterval
    private let cacheDir: URL?
    private let environment: [String: String]
    private let broadcaster = Broadcaster<[ConnectedAccount]>()
    private var records: [ConnectedAccount]?
    private var tokens: [String: AccessToken] = [:]

    /// - Parameters:
    ///   - configuration: nil leaves the provider unconfigured (`isConfigured` false, `connect` throws
    ///     `AccountError.notConfigured` with the setup hint).
    ///   - session: the `URLSession` for Google's endpoints.
    ///   - cacheDir: the library's `Cache/` directory; disconnect deletes the quota file there.
    public init(
        configuration: GoogleClientConfiguration?, tokenStore: any TokenStore, accountsFile: AccountsFile,
        presenter: any AuthorizationPresenter, session: URLSession, clock: any Clock = SystemClock(),
        listenerTimeout: Duration = LoopbackRedirectListener.defaultTimeout, recordMaxAge: TimeInterval = recordMaxAge,
        cacheDir: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.configuration = configuration
        self.isConfigured = configuration != nil
        self.tokenStore = tokenStore
        self.accountsFile = accountsFile
        self.presenter = presenter
        self.oauth = configuration.map { GoogleOAuthClient(configuration: $0, session: session, clock: clock) }
        self.api = YouTubeAPI(session: session)
        self.clock = clock
        self.listenerTimeout = listenerTimeout
        self.recordMaxAge = recordMaxAge
        self.cacheDir = cacheDir
        self.environment = environment
    }

    // MARK: AccountProvider

    public func accounts() async -> [ConnectedAccount] { await loadedRecords() }

    @MainActor public func connect(scopes: [String], loginHint: String?) async throws -> ConnectedAccount {
        try await performConnect(scopes: scopes, loginHint: loginHint)
    }

    public func disconnect(_ id: String) async throws {
        var current = await loadedRecords()
        guard current.contains(where: { $0.id == id }) else { throw AccountError.notConnected(id) }
        if let oauth, let credential = try? await tokenStore.load(accountId: id) {
            try? await oauth.revoke(token: credential.refreshToken)
        }
        try await tokenStore.delete(accountId: id)
        tokens[id] = nil
        current.removeAll { $0.id == id }
        try persist(current)
        if let cacheDir {
            try? FileManager.default.removeItem(at: QuotaMeter.fileURL(cacheDir: cacheDir))
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("avatars/\(id)", isDirectory: true))
        }
    }

    public func refresh(_ id: String) async throws -> ConnectedAccount {
        guard await loadedRecords().contains(where: { $0.id == id }) else { throw AccountError.notConnected(id) }
        let token = try await accessToken(for: id, minimumLifetime: .seconds(60))
        let channel: YouTubeAPI.ChannelInfo?
        do {
            channel = try await api.myChannel(token: token)
        } catch let error as YouTubeAPIError {
            throw AccountError.network("channels.list: \(error.message)")
        } catch let error as PublishError {
            throw AccountError.network(error.message)
        }
        var current = records ?? []
        guard let index = current.firstIndex(where: { $0.id == id }) else { throw AccountError.notConnected(id) }
        var record = current[index]
        if let channel {
            record.channelId = channel.id
            record.channelTitle = channel.title
            record.channelHandle = channel.handle
            record.avatarURL = channel.avatarURL
        }
        record.refreshedAt = clock.now()
        record.tokenStatus = .valid(expiresAt: token.expiresAt)
        current[index] = record
        try persist(current)
        return stored(id) ?? record
    }

    public func accessToken(for id: String, minimumLifetime: Duration) async throws -> AccessToken {
        guard await loadedRecords().contains(where: { $0.id == id }) else { throw AccountError.notConnected(id) }
        if let cached = tokens[id], cached.isValid(for: minimumLifetime, now: clock.now()) { return cached }
        guard let oauth else {
            throw AccountError.notConfigured(GoogleClientConfiguration.setupHint(environment: environment))
        }
        guard let credential = try await tokenStore.load(accountId: id) else {
            try markReauthorization("no stored credential for the account", id: id)
            throw AccountError.reauthorizationRequired("no stored credential for the account")
        }
        let response: TokenResponse
        do {
            response = try await oauth.refresh(refreshToken: credential.refreshToken)
        } catch AccountError.reauthorizationRequired(let reason) {
            try markReauthorization(reason, id: id)
            throw AccountError.reauthorizationRequired(reason)
        }
        let token = AccessToken(
            value: response.accessToken, expiresAt: response.expiresAt,
            scopes: response.scopes.isEmpty ? credential.scopes : response.scopes)
        tokens[id] = token
        var current = records ?? []
        if let index = current.firstIndex(where: { $0.id == id }) {
            let previous = current[index].tokenStatus
            current[index].tokenStatus = .valid(expiresAt: token.expiresAt)
            if case .valid = previous {
                // A routine refresh: keep the file current without waking every subscriber.
                try? persist(current, broadcast: false)
            } else {
                try persist(current)
            }
        }
        return token
    }

    public nonisolated var changes: AsyncStream<[ConnectedAccount]> { broadcaster.subscribe() }

    // MARK: Connect

    private func performConnect(scopes: [String], loginHint: String?) async throws -> ConnectedAccount {
        guard let oauth, let configuration else {
            throw AccountError.notConfigured(GoogleClientConfiguration.setupHint(environment: environment))
        }
        let pkce = PKCE.make()
        let listener = LoopbackRedirectListener(expectedState: pkce.state, timeout: listenerTimeout)
        let redirectURI = try await listener.start()
        let code: String
        do {
            let url = oauth.authorizationURL(scopes: scopes, redirectURI: redirectURI, pkce: pkce, loginHint: loginHint)
            try await presenter.open(url)
            code = try await listener.waitForCode()
        } catch {
            await listener.stop()
            throw error
        }
        let response = try await oauth.exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI)
        let missing = GoogleOAuthClient.missingScopes(requested: scopes, granted: response.scopes)
        guard missing.isEmpty else {
            if let refresh = response.refreshToken { try? await oauth.revoke(token: refresh) }
            throw AccountError.denied("the grant lacks \(missing.joined(separator: ", ")); every scope is required")
        }
        guard let refreshToken = response.refreshToken else {
            throw AccountError.protocolError("the token response carries no refresh_token")
        }
        guard let idToken = response.idToken else {
            try? await oauth.revoke(token: refreshToken)
            throw AccountError.protocolError("the token response carries no id_token")
        }
        let claims = try GoogleOAuthClient.decodeIDToken(idToken)
        let token = AccessToken(value: response.accessToken, expiresAt: response.expiresAt, scopes: response.scopes)
        let channel: YouTubeAPI.ChannelInfo?
        do {
            channel = try await api.myChannel(token: token)
        } catch let error as YouTubeAPIError {
            try? await oauth.revoke(token: refreshToken)
            throw AccountError.network("channels.list: \(error.message)")
        } catch let error as PublishError {
            try? await oauth.revoke(token: refreshToken)
            throw AccountError.network(error.message)
        }
        guard let channel else {
            try? await oauth.revoke(token: refreshToken)
            throw AccountError.noChannel(claims.email ?? claims.sub)
        }
        let now = clock.now()
        let credential = StoredCredential(
            accountId: claims.sub, refreshToken: refreshToken, scopes: scopes, clientId: configuration.clientId,
            grantedAt: now)
        try await tokenStore.save(credential)
        tokens[claims.sub] = token
        var current = await loadedRecords()
        let record = ConnectedAccount(
            id: claims.sub, provider: .google, email: claims.email, displayName: claims.name, channelId: channel.id,
            channelTitle: channel.title, channelHandle: channel.handle, avatarURL: channel.avatarURL, scopes: scopes,
            connectedAt: current.first { $0.id == claims.sub }?.connectedAt ?? now, refreshedAt: now,
            tokenStatus: .valid(expiresAt: token.expiresAt))
        current.removeAll { $0.id == claims.sub }
        current.append(record)
        try persist(current)
        return stored(claims.sub) ?? record
    }

    // MARK: Records

    /// Reads `accounts.json` once; records whose `refreshedAt` is older than `recordMaxAge` are refreshed
    /// (best effort) and a `.valid` status from a previous run becomes `.expired` (no live token here).
    private func loadedRecords() async -> [ConnectedAccount] {
        if let records { return records }
        var loaded = (try? accountsFile.load()) ?? []
        for index in loaded.indices {
            if case .valid = loaded[index].tokenStatus { loaded[index].tokenStatus = .expired }
        }
        records = loaded
        let now = clock.now()
        let stale = loaded.filter { now.timeIntervalSince($0.refreshedAt) > recordMaxAge }.map(\.id)
        for id in stale {
            _ = try? await refresh(id)
        }
        return records ?? loaded
    }

    /// Saves, then reloads, so the records in memory are exactly what the file holds (dates at the
    /// codec's millisecond precision), and broadcasts unless told not to.
    private func persist(_ accounts: [ConnectedAccount], broadcast: Bool = true) throws {
        do {
            try accountsFile.save(accounts)
            records = try accountsFile.load()
        } catch {
            records = accounts
            throw AccountError.storage("accounts file: \(error.localizedDescription)")
        }
        if broadcast { broadcaster.send(records ?? accounts) }
    }

    /// The persisted record for `id`, after a `persist`.
    private func stored(_ id: String) -> ConnectedAccount? { records?.first { $0.id == id } }

    private func markReauthorization(_ reason: String, id: String) throws {
        var current = records ?? []
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].tokenStatus = .reauthorizationRequired(reason)
        tokens[id] = nil
        try persist(current)
    }
}
