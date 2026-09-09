import Contracts
import ContractsTestSupport
import Foundation
import Synchronization
import Testing
import TimelineCore

@testable import PublishKit

/// A seeded fake server with a file token store and an accounts file in a temporary directory.
private struct ProviderHarness {
    let server: FakeYouTubeServer
    let directory: URL
    let tokenStore: FileTokenStore
    let accountsFile: AccountsFile
    let cacheDir: URL
    let refreshToken: String
    let configuration = GoogleClientConfiguration(clientId: "id-1.apps.googleusercontent.com", clientSecret: "s")

    init(label: String) async throws {
        server = FakeYouTubeServer()
        refreshToken = await server.seedFixtureAccount()
        directory = try temporaryDirectory(label)
        tokenStore = FileTokenStore(url: directory.appendingPathComponent("google-tokens.json"))
        accountsFile = AccountsFile(url: directory.appendingPathComponent("accounts.json"))
        cacheDir = directory.appendingPathComponent("Cache", isDirectory: true)
    }

    func provider(
        configured: Bool = true, presenter: FakeAuthorizationPresenter? = nil, clock: any Clock = SystemClock(),
        recordMaxAge: TimeInterval = GoogleAccountProvider.recordMaxAge, timeout: Duration = .seconds(10)
    ) -> GoogleAccountProvider {
        GoogleAccountProvider(
            configuration: configured ? configuration : nil, tokenStore: tokenStore, accountsFile: accountsFile,
            presenter: presenter ?? FakeAuthorizationPresenter(mode: .completeCallback, server: server),
            session: URLSession(configuration: server.sessionConfiguration()), clock: clock, listenerTimeout: timeout,
            recordMaxAge: recordMaxAge, cacheDir: cacheDir, environment: ["TIMELINE_ROOT": directory.path])
    }

    /// A previously connected account: the credential in the store, the record in the file.
    func seedStored(refreshedAt: Date = Date(), channelTitle: String = "Skeleton Channel") async throws {
        try await tokenStore.save(
            StoredCredential(
                accountId: "sub-1", refreshToken: refreshToken, scopes: Fixtures.publishScopes,
                clientId: configuration.clientId, grantedAt: refreshedAt))
        var record = Fixtures.connectedGoogleAccount
        record.refreshedAt = refreshedAt
        record.channelTitle = channelTitle
        record.tokenStatus = .expired
        try accountsFile.save([record])
    }

    func tokenRequests() async -> Int { await server.requests.filter { $0.path == "/token" }.count }
    func revokes() async -> [FakeYouTubeServer.RecordedRequest] {
        await server.requests.filter { $0.path == "/revoke" }
    }
    func channelLists() async -> Int { await server.requests.filter { $0.path == "/youtube/v3/channels" }.count }
}

/// Collects the lists a `changes` stream yields.
private final class ChangeCollector: Sendable {
    private final class Store: Sendable {
        let lists = Mutex<[[ConnectedAccount]]>([])
    }

    private let store: Store
    let task: Task<Void, Never>

    init(_ stream: AsyncStream<[ConnectedAccount]>) {
        let store = Store()
        self.store = store
        task = Task {
            for await list in stream { store.lists.withLock { $0.append(list) } }
        }
    }

    var received: [[ConnectedAccount]] { store.lists.withLock { $0 } }

    func waitForCount(_ count: Int) async {
        for _ in 0..<200 where received.count < count { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

@Suite struct AccountProviderTests {
    @Test func connectThroughTheListenerAndTheFakeServerYieldsAConnectedAccount() async throws {
        let harness = try await ProviderHarness(label: "connect")
        let presenter = FakeAuthorizationPresenter(mode: .completeCallback, server: harness.server)
        let provider = harness.provider(presenter: presenter)
        let changes = ChangeCollector(provider.changes)
        #expect(provider.isConfigured && provider.kind == .google)
        #expect(await provider.accounts().isEmpty)

        let account = try await provider.connect(scopes: Fixtures.publishScopes, loginHint: nil)
        #expect(account.id == "sub-1" && account.provider == .google && account.email == "me@example.com")
        #expect(account.channelId == "UC-fake" && account.channelTitle == "Skeleton Channel")
        #expect(account.channelHandle == "@skeleton" && account.avatarURL?.host() == "yt3.ggpht.com")
        #expect(account.scopes == Fixtures.publishScopes)
        if case .valid(let expiresAt) = account.tokenStatus {
            #expect(expiresAt > Date().addingTimeInterval(3500))
        } else {
            Issue.record("expected a valid token status")
        }
        #expect(account.connectedAt == account.refreshedAt)

        // The browser saw the authorization URL with the listener's redirect and PKCE.
        let opened = try #require(presenter.openedURLs.first)
        #expect(opened.host() == "accounts.google.com")
        let query = Dictionary(
            (URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            },
            uniquingKeysWith: { a, _ in a })
        #expect(
            query["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true
                && query["redirect_uri"]?.hasSuffix("/callback") == true)
        #expect(query["code_challenge_method"] == "S256" && query["access_type"] == "offline")
        #expect(presenter.performedCallbacks.count == 1)

        // Credential stored, record persisted 0600, list and stream updated.
        let credential = try #require(try await harness.tokenStore.load(accountId: "sub-1"))
        #expect(
            credential.refreshToken.hasPrefix("fake-refresh-") && credential.clientId == harness.configuration.clientId)
        #expect(credential.scopes == Fixtures.publishScopes)
        #expect(try PrivateFile.mode(of: harness.accountsFile.url).map { $0 & 0o777 } == 0o600)
        #expect(try harness.accountsFile.load() == [account])
        #expect(await provider.accounts() == [account])
        await changes.waitForCount(1)
        #expect(changes.received == [[account]])
        changes.task.cancel()

        // The access token from the exchange is cached: no refresh for the next request.
        let requests = await harness.tokenRequests()
        let token = try await provider.accessToken(for: "sub-1", minimumLifetime: .seconds(60))
        #expect(token.value.hasPrefix("fake-access-"))
        #expect(await harness.tokenRequests() == requests)
        #expect(await harness.channelLists() == 1)
    }

    @Test func connectRefusesWhenARequiredScopeWasUntickedAndRevokesTheGrant() async throws {
        let harness = try await ProviderHarness(label: "scopes")
        await harness.server.setGrantedScopes(["openid", "email"])
        let provider = harness.provider()
        do {
            _ = try await provider.connect(scopes: Fixtures.publishScopes, loginHint: "me@example.com")
            Issue.record("expected denied")
        } catch AccountError.denied(let detail) {
            #expect(detail.contains("youtube.force-ssl"))
        }
        let revokes = await harness.revokes()
        #expect(revokes.count == 1 && revokes[0].query["token"]?.hasPrefix("fake-refresh-") == true)
        #expect(try await harness.tokenStore.list().isEmpty)
        #expect(await provider.accounts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.accountsFile.url.path))
    }

    @Test func noChannelIsReported() async throws {
        let server = FakeYouTubeServer()
        await server.seedAccount(sub: "sub-9", email: "nine@example.com", noChannel: true)
        let directory = try temporaryDirectory("no-channel")
        let store = FileTokenStore(url: directory.appendingPathComponent("google-tokens.json"))
        let provider = GoogleAccountProvider(
            configuration: GoogleClientConfiguration(clientId: "id-1"), tokenStore: store,
            accountsFile: AccountsFile(url: directory.appendingPathComponent("accounts.json")),
            presenter: FakeAuthorizationPresenter(mode: .completeCallback, server: server),
            session: URLSession(configuration: server.sessionConfiguration()), listenerTimeout: .seconds(10))
        await #expect(throws: AccountError.noChannel("nine@example.com")) {
            _ = try await provider.connect(scopes: Fixtures.publishScopes, loginHint: nil)
        }
        #expect(await server.requests.filter { $0.path == "/revoke" }.count == 1)
        #expect(try await store.list().isEmpty)
        #expect(await provider.accounts().isEmpty)
    }

    @Test func accessTokenRefreshesWithinMinimumLifetime() async throws {
        let harness = try await ProviderHarness(label: "refresh")
        try await harness.seedStored()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_788_825_600))
        let provider = harness.provider(clock: clock)
        #expect(await provider.accounts().first?.tokenStatus == .expired)

        let first = try await provider.accessToken(for: "sub-1", minimumLifetime: .seconds(60))
        #expect(first.value.hasPrefix("fake-access-"))
        #expect(await harness.tokenRequests() == 1)
        #expect(first.expiresAt == clock.now().addingTimeInterval(FakeYouTubeServer.accessTokenLifetime))
        #expect(first.scopes.contains("https://www.googleapis.com/auth/youtube.force-ssl"))
        #expect(await provider.accounts().first?.tokenStatus == .valid(expiresAt: first.expiresAt))

        // Still good for a minute: served from memory.
        let cached = try await provider.accessToken(for: "sub-1", minimumLifetime: .seconds(60))
        #expect(cached.value == first.value)
        #expect(await harness.tokenRequests() == 1)

        // Not good for an hour: refreshed.
        let refreshed = try await provider.accessToken(for: "sub-1", minimumLifetime: .seconds(3600))
        #expect(refreshed.value != first.value)
        #expect(await harness.tokenRequests() == 2)
        #expect(try await harness.tokenStore.load(accountId: "sub-1")?.refreshToken == harness.refreshToken)

        await #expect(throws: AccountError.notConnected("sub-2")) {
            _ = try await provider.accessToken(for: "sub-2", minimumLifetime: .seconds(60))
        }
        // The token never reaches the record file.
        let json = String(decoding: try Data(contentsOf: harness.accountsFile.url), as: UTF8.self)
        #expect(!json.contains(refreshed.value) && !json.contains("fake-access") && !json.contains("fake-refresh"))
    }

    @Test func refreshFailureMarksReauthorizationRequiredAndPersists() async throws {
        let harness = try await ProviderHarness(label: "invalid-grant")
        try await harness.seedStored()
        await harness.server.revokeRefreshToken(sub: "sub-1")
        let provider = harness.provider()
        let changes = ChangeCollector(provider.changes)
        do {
            _ = try await provider.accessToken(for: "sub-1", minimumLifetime: .seconds(60))
            Issue.record("expected reauthorizationRequired")
        } catch AccountError.reauthorizationRequired(let reason) {
            #expect(reason.contains("expired or revoked"))
        }
        let listed = try #require(await provider.accounts().first)
        #expect(listed.tokenStatus.needsReauthorization)
        await changes.waitForCount(1)
        #expect(changes.received.last?.first?.tokenStatus.needsReauthorization == true)
        changes.task.cancel()
        // Persisted: a fresh provider over the same files sees it, and the account stays listed.
        let reopened = harness.provider()
        #expect(await reopened.accounts().map(\.id) == ["sub-1"])
        #expect(await reopened.accounts().first?.tokenStatus.needsReauthorization == true)
        await #expect(throws: AccountError.self) { _ = try await reopened.refresh("sub-1") }
        // The credential is kept for the user to reconnect over; nothing else changed.
        #expect(try await harness.tokenStore.load(accountId: "sub-1") != nil)
    }

    @Test func disconnectRevokesDeletesAndBroadcasts() async throws {
        let harness = try await ProviderHarness(label: "disconnect")
        try await harness.seedStored()
        let quotaFile = QuotaMeter.fileURL(cacheDir: harness.cacheDir)
        try FileManager.default.createDirectory(at: harness.cacheDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: quotaFile)
        let provider = harness.provider()
        let changes = ChangeCollector(provider.changes)
        #expect(await provider.accounts().count == 1)

        try await provider.disconnect("sub-1")
        let revokes = await harness.revokes()
        #expect(revokes.count == 1 && revokes[0].method == "POST" && revokes[0].query["token"] == harness.refreshToken)
        #expect(try await harness.tokenStore.load(accountId: "sub-1") == nil)
        #expect(await provider.accounts().isEmpty)
        #expect(try harness.accountsFile.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: quotaFile.path))
        await changes.waitForCount(1)
        #expect(changes.received.last == [])
        changes.task.cancel()
        await #expect(throws: AccountError.notConnected("sub-1")) { try await provider.disconnect("sub-1") }
        // The refresh token is dead at the provider too.
        await #expect(throws: AccountError.self) {
            _ = try await GoogleOAuthClient(
                configuration: harness.configuration,
                session: URLSession(configuration: harness.server.sessionConfiguration())
            ).refresh(refreshToken: harness.refreshToken)
        }
    }

    @Test func unconfiguredProviderIsNotConfiguredAndConnectThrowsNotConfigured() async throws {
        let harness = try await ProviderHarness(label: "unconfigured")
        try await harness.seedStored()
        let provider = harness.provider(configured: false)
        #expect(!provider.isConfigured)
        do {
            _ = try await provider.connect(scopes: Fixtures.publishScopes, loginHint: nil)
            Issue.record("expected notConfigured")
        } catch AccountError.notConfigured(let hint) {
            #expect(hint.contains("TIMELINE_GOOGLE_CLIENT_ID"))
            #expect(hint.contains(harness.directory.appendingPathComponent("google-oauth-client.json").path))
        }
        // Records are still listed (the UI shows them with the setup hint); tokens cannot be minted.
        #expect(await provider.accounts().map(\.id) == ["sub-1"])
        await #expect(throws: AccountError.self) {
            _ = try await provider.accessToken(for: "sub-1", minimumLifetime: .seconds(60))
        }
        #expect(
            try GoogleClientConfiguration.load(
                environment: ["TIMELINE_ROOT": harness.directory.path], applicationSupport: harness.directory) == nil)
        let file = harness.directory.appendingPathComponent("google-oauth-client.json")
        try Data(#"{"installed":{"client_id":"from-file","client_secret":"sec"},"audited":true}"#.utf8).write(to: file)
        let loaded = try GoogleClientConfiguration.load(
            environment: ["TIMELINE_ROOT": harness.directory.path], applicationSupport: harness.directory)
        #expect(loaded == GoogleClientConfiguration(clientId: "from-file", clientSecret: "sec", audited: true))
        let env = try GoogleClientConfiguration.load(
            environment: ["TIMELINE_GOOGLE_CLIENT_ID": "from-env", "TIMELINE_ROOT": harness.directory.path],
            applicationSupport: harness.directory)
        #expect(env == GoogleClientConfiguration(clientId: "from-env", clientSecret: nil, audited: false))
        try Data("nope".utf8).write(to: file)
        #expect(throws: PublishKitError.self) {
            _ = try GoogleClientConfiguration.load(
                environment: ["TIMELINE_ROOT": harness.directory.path], applicationSupport: harness.directory)
        }
    }

    @Test func recordsOlderThan30DaysAreRefreshedOnLoad() async throws {
        let harness = try await ProviderHarness(label: "stale")
        let now = Date(timeIntervalSince1970: 1_788_825_600)
        try await harness.seedStored(refreshedAt: now.addingTimeInterval(-31 * 86_400), channelTitle: "Old name")
        let provider = harness.provider(clock: FixedClock(now))
        let accounts = await provider.accounts()
        #expect(accounts.count == 1)
        #expect(accounts[0].channelTitle == "Skeleton Channel" && accounts[0].refreshedAt == now)
        #expect(await harness.channelLists() == 1)
        #expect(await harness.tokenRequests() == 1)
        #expect(try harness.accountsFile.load().first?.refreshedAt == now)

        // A record one day old is left alone.
        let fresh = try await ProviderHarness(label: "fresh")
        try await fresh.seedStored(refreshedAt: now.addingTimeInterval(-86_400), channelTitle: "Kept")
        let untouched = fresh.provider(clock: FixedClock(now))
        #expect(await untouched.accounts().first?.channelTitle == "Kept")
        #expect(await fresh.channelLists() == 0)
        // An explicit refresh re-reads the channel.
        let refreshed = try await untouched.refresh("sub-1")
        #expect(refreshed.channelTitle == "Skeleton Channel" && refreshed.refreshedAt == now)
        #expect(await fresh.channelLists() == 1)
    }

    @Test func accountsFileHoldsNoSecrets() async throws {
        let harness = try await ProviderHarness(label: "no-secrets")
        let provider = harness.provider()
        let account = try await provider.connect(scopes: Fixtures.publishScopes, loginHint: nil)
        let credential = try #require(try await harness.tokenStore.load(accountId: account.id))
        let accountsJSON = String(decoding: try Data(contentsOf: harness.accountsFile.url), as: UTF8.self)
        #expect(!accountsJSON.contains(credential.refreshToken))
        #expect(!accountsJSON.contains("refreshToken") && !accountsJSON.contains("fake-access"))
        #expect(accountsJSON.contains("\"id\" : \"sub-1\"") || accountsJSON.contains("\"id\":\"sub-1\""))
        let tokensJSON = String(decoding: try Data(contentsOf: harness.tokenStore.url), as: UTF8.self)
        #expect(tokensJSON.contains(credential.refreshToken))
        // And the record decodes back to what the provider returned.
        #expect(try harness.accountsFile.load() == [account])
    }
}
