import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@Suite struct AccountsTests {
    @Test func accessTokenRedactsItself() {
        let token = AccessToken(
            value: "ya29.secret-value-that-must-not-leak", expiresAt: Fixtures.fixtureDate.addingTimeInterval(3600),
            scopes: Fixtures.publishScopes)
        #expect(!"\(token)".contains("secret"))
        #expect(!String(reflecting: token).contains("secret"))
        #expect(!String(describing: [token]).contains("secret"))
        #expect("\(token)".contains("3 scopes"))
        #expect(token.authorizationHeader == "Bearer ya29.secret-value-that-must-not-leak")
        #expect(token.isValid(for: .seconds(300), now: Fixtures.fixtureDate))
        #expect(!token.isValid(for: .seconds(3660), now: Fixtures.fixtureDate))
    }

    @Test func connectedAccountAndErrorsRoundTrip() throws {
        let account = Fixtures.connectedGoogleAccount
        let data = try ProjectCodec.encode(account)
        #expect(try ProjectCodec.decode(ConnectedAccount.self, from: data) == account)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"tokenStatus\":{\"valid\":{\"expiresAt\":\"2026-09-08T01:00:00.000Z\"}}"))
        for status in [AccountTokenStatus.expired, .reauthorizationRequired("invalid_grant")] {
            let back = try ProjectCodec.decode(AccountTokenStatus.self, from: try ProjectCodec.encode(status))
            #expect(back == status)
        }
        #expect(AccountTokenStatus.reauthorizationRequired("x").needsReauthorization)
        let errors: [AccountError] = [
            .notConfigured("set TIMELINE_GOOGLE_CLIENT_ID"), .cancelled, .denied("scope"), .notConnected("sub-9"),
            .reauthorizationRequired("invalid_grant"), .noChannel("sub-1"), .storage("errSecItemNotFound"),
            .network("timeout"), .protocolError("state mismatch"),
        ]
        for error in errors {
            #expect(try ProjectCodec.decode(AccountError.self, from: try ProjectCodec.encode(error)) == error)
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }

    @Test func fakeProviderConnectsListsRefreshesAndDisconnects() async throws {
        let fake = FakeAccountProvider(clock: FixedClock(step: 60))
        let provider: any AccountProvider = fake
        #expect(provider.kind == .google && provider.isConfigured)
        #expect(await provider.accounts().isEmpty)

        let connected = try await provider.connect(scopes: Fixtures.publishScopes, loginHint: "me@example.com")
        #expect(connected.id == "sub-1" && connected.channelHandle == "@skeleton")
        #expect(connected.scopes == Fixtures.publishScopes)
        #expect(await provider.accounts() == [connected])
        #expect(await fake.connectCalls == [.init(scopes: Fixtures.publishScopes, loginHint: "me@example.com")])

        let token = try await provider.accessToken(for: "sub-1", minimumLifetime: .seconds(300))
        #expect(token.value == "fake-token-1" && token.scopes == Fixtures.publishScopes)
        #expect(token.expiresAt > connected.connectedAt)
        #expect(await fake.tokenRequests == 1)

        let refreshed = try await provider.refresh("sub-1")
        #expect(refreshed.refreshedAt > connected.refreshedAt)
        #expect(await fake.refreshed == ["sub-1"])

        try await provider.disconnect("sub-1")
        #expect(await provider.accounts().isEmpty)
        #expect(await fake.disconnected == ["sub-1"])
        await #expect(throws: AccountError.notConnected("sub-1")) { try await provider.disconnect("sub-1") }
        await #expect(throws: AccountError.notConnected("sub-1")) {
            _ = try await provider.accessToken(for: "sub-1", minimumLifetime: .seconds(1))
        }

        await fake.setFailNextConnect(.denied("youtube.force-ssl unticked"))
        await #expect(throws: AccountError.denied("youtube.force-ssl unticked")) {
            _ = try await provider.connect(scopes: Fixtures.publishScopes, loginHint: nil)
        }
        let unconfigured: any AccountProvider = FakeAccountProvider(configured: false)
        #expect(!unconfigured.isConfigured)
        await #expect(throws: AccountError.self) {
            _ = try await unconfigured.connect(scopes: Fixtures.publishScopes, loginHint: nil)
        }
    }

    @Test func fakeProviderReportsReauthorizationRequired() async throws {
        let fake = FakeAccountProvider(accounts: [Fixtures.connectedGoogleAccount])
        let provider: any AccountProvider = fake
        _ = try await provider.accessToken(for: "sub-1", minimumLifetime: .seconds(300))
        try await fake.setTokenStatus(.reauthorizationRequired("invalid_grant"), for: "sub-1")
        await #expect(throws: AccountError.reauthorizationRequired("invalid_grant")) {
            _ = try await provider.accessToken(for: "sub-1", minimumLifetime: .seconds(300))
        }
        await #expect(throws: AccountError.reauthorizationRequired("invalid_grant")) {
            _ = try await provider.refresh("sub-1")
        }
        #expect(await provider.accounts().first?.tokenStatus.needsReauthorization == true)
        // Reconnecting replaces the record and clears the status.
        let again = try await provider.connect(scopes: Fixtures.publishScopes, loginHint: "me@example.com")
        #expect(await provider.accounts() == [again] && !again.tokenStatus.needsReauthorization)
        #expect(await fake.tokenRequests == 1)
    }

    @Test func changesStreamYieldsAfterEveryMutation() async throws {
        let fake = FakeAccountProvider()
        let provider: any AccountProvider = fake
        let changes = provider.changes
        let collector = Task { () -> [[String]] in
            var seen: [[String]] = []
            for await accounts in changes {
                seen.append(accounts.map(\.id))
                if seen.count == 4 { break }
            }
            return seen
        }
        _ = try await provider.connect(scopes: Fixtures.publishScopes, loginHint: nil)
        try await fake.setTokenStatus(.expired, for: "sub-1")
        _ = try await provider.refresh("sub-1")
        try await provider.disconnect("sub-1")
        #expect(await collector.value == [["sub-1"], ["sub-1"], ["sub-1"], []])
        // A late subscriber sees only later changes.
        var late = provider.changes.makeAsyncIterator()
        await fake.add(Fixtures.connectedGoogleAccount)
        #expect(await late.next()?.map(\.id) == ["sub-1"])
    }

    @Test func presenterPerformsTheCallbackItself() async throws {
        let presenter = FakeAuthorizationPresenter(mode: .completeCallback, callbackDelay: .milliseconds(1))
        let opened: any AuthorizationPresenter = presenter
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:1/callback"),
            URLQueryItem(name: "state", value: "abc"), URLQueryItem(name: "scope", value: "openid email"),
        ]
        try await opened.open(components.url!)
        #expect(presenter.openedURLs == [components.url!])
        for _ in 0..<200 where presenter.performedCallbacks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let callback = try #require(presenter.performedCallbacks.first)
        let query = Dictionary(
            URLComponents(url: callback, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { a, _ in a })
        #expect(query["state"] == "abc" && query["code"] == "fake-code-1")
        #expect(callback.absoluteString.hasPrefix("http://127.0.0.1:1/callback?"))

        let ignoring = FakeAuthorizationPresenter(mode: .ignore)
        try await ignoring.open(components.url!)
        #expect(ignoring.openedURLs.count == 1 && ignoring.performedCallbacks.isEmpty)
    }
}
