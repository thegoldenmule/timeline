import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import PublishKit

@Suite struct OAuthClientTests {
    private let redirect = URL(string: "http://127.0.0.1:4242/callback")!

    private func client(secret: String? = "shh", server: FakeYouTubeServer) -> GoogleOAuthClient {
        GoogleOAuthClient(
            configuration: GoogleClientConfiguration(clientId: "id-1.apps.googleusercontent.com", clientSecret: secret),
            session: URLSession(configuration: server.sessionConfiguration()))
    }

    private func query(_ url: URL) -> [String: String] {
        Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            },
            uniquingKeysWith: { a, _ in a })
    }

    @Test func authorizationURLCarriesEveryDocumentedParameter() async {
        let server = FakeYouTubeServer()
        let pkce = PKCE.make()
        let url = client(server: server).authorizationURL(
            scopes: Fixtures.publishScopes, redirectURI: redirect, pkce: pkce, loginHint: "me@example.com")
        #expect(url.host() == "accounts.google.com" && url.path() == "/o/oauth2/v2/auth")
        let q = query(url)
        #expect(q["client_id"] == "id-1.apps.googleusercontent.com")
        #expect(q["redirect_uri"] == "http://127.0.0.1:4242/callback")
        #expect(q["response_type"] == "code")
        #expect(q["scope"] == "openid email https://www.googleapis.com/auth/youtube.force-ssl")
        #expect(q["code_challenge"] == pkce.challenge && q["code_challenge_method"] == "S256")
        #expect(q["state"] == pkce.state)
        #expect(q["access_type"] == "offline" && q["prompt"] == "consent")
        #expect(q["login_hint"] == "me@example.com")
        #expect(url.absoluteString.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A4242%2Fcallback"))
        let noHint = client(server: server).authorizationURL(scopes: ["openid"], redirectURI: redirect, pkce: pkce)
        #expect(query(noHint)["login_hint"] == nil)
    }

    @Test func exchangesACodeWithTheVerifier() async throws {
        let server = FakeYouTubeServer()
        await server.seedFixtureAccount()
        let code = await server.issueAuthorizationCode(for: "sub-1", scopes: Fixtures.publishScopes)
        let response = try await client(server: server).exchange(code: code, verifier: "v-1", redirectURI: redirect)
        #expect(!response.accessToken.isEmpty && response.refreshToken?.hasPrefix("fake-refresh-") == true)
        #expect(response.idToken != nil)
        #expect(response.expiresAt > Date().addingTimeInterval(3500))
        #expect(
            response.scopes == [
                "openid", "https://www.googleapis.com/auth/userinfo.email",
                "https://www.googleapis.com/auth/youtube.force-ssl",
            ])
        #expect(GoogleOAuthClient.missingScopes(requested: Fixtures.publishScopes, granted: response.scopes).isEmpty)
        // The fake refused an exchange without the verifier or the redirect: this one carried both.
        let token = try #require(await server.requests.last { $0.path == "/token" })
        #expect(token.method == "POST" && token.headers["Content-Type"] == "application/x-www-form-urlencoded")
        // A reused code is an invalid grant, reported as reauthorization.
        await #expect(throws: AccountError.self) {
            _ = try await client(server: server).exchange(code: code, verifier: "v-1", redirectURI: redirect)
        }
    }

    @Test func refreshesAndKeepsTheRefreshToken() async throws {
        let server = FakeYouTubeServer()
        let refresh = await server.seedFixtureAccount()
        let response = try await client(server: server).refresh(refreshToken: refresh)
        #expect(response.accessToken.hasPrefix("fake-access-"))
        #expect(response.refreshToken == refresh, "Google sends no new refresh token; the old one stays")
        #expect(response.idToken == nil)
        let again = try await client(server: server).refresh(refreshToken: refresh)
        #expect(again.accessToken != response.accessToken)
    }

    @Test func invalidGrantIsReauthorizationRequired() async throws {
        let server = FakeYouTubeServer()
        let refresh = await server.seedFixtureAccount()
        await server.revokeRefreshToken(sub: "sub-1")
        do {
            _ = try await client(server: server).refresh(refreshToken: refresh)
            Issue.record("expected invalid_grant")
        } catch AccountError.reauthorizationRequired(let reason) {
            #expect(reason.contains("expired or revoked"))
        }
    }

    @Test func revokeTreats200And400AsSuccess() async throws {
        let server = FakeYouTubeServer()
        let refresh = await server.seedFixtureAccount()
        try await client(server: server).revoke(token: refresh)
        try await client(server: server).revoke(token: refresh)
        try await client(server: server).revoke(token: "never-issued")
        let revokes = await server.requests.filter { $0.path == "/revoke" }
        #expect(revokes.count == 3 && revokes.allSatisfy { $0.method == "POST" && $0.query["token"] != nil })
    }

    @Test func decodesSubAndEmailFromTheIdToken() async throws {
        let server = FakeYouTubeServer()
        await server.seedFixtureAccount()
        let code = await server.issueAuthorizationCode(for: "sub-1")
        let response = try await client(server: server).exchange(code: code, verifier: "v", redirectURI: redirect)
        let claims = try GoogleOAuthClient.decodeIDToken(try #require(response.idToken))
        #expect(claims.sub == "sub-1" && claims.email == "me@example.com" && claims.emailVerified == true)
        #expect(throws: AccountError.protocolError("malformed id_token")) {
            _ = try GoogleOAuthClient.decodeIDToken("not.a.jwt")
        }
        let noSub = "e30.\(Base64URL.encode(Data(#"{"email":"x@y"}"#.utf8)))."
        #expect(throws: AccountError.protocolError("id_token has no sub")) {
            _ = try GoogleOAuthClient.decodeIDToken(noSub)
        }
    }

    @Test func clientSecretIsSentOnlyWhenConfigured() async throws {
        // The form is built by `FormEncoding`; the fake records only the body length, and the two
        // refreshes differ by exactly the `&client_secret=s3cret` field.
        let server = FakeYouTubeServer()
        let refresh = await server.seedFixtureAccount()
        _ = try await client(secret: "s3cret", server: server).refresh(refreshToken: refresh)
        _ = try await client(secret: nil, server: server).refresh(refreshToken: refresh)
        let tokens = await server.requests.filter { $0.path == "/token" }
        #expect(tokens.count == 2)
        #expect(tokens[0].bodyBytes - tokens[1].bodyBytes == "&client_secret=s3cret".utf8.count)
        let form = String(
            decoding: FormEncoding.encode([
                ("client_id", "id-1"), ("client_secret", "s3cret"), ("grant_type", "refresh_token"),
            ]),
            as: UTF8.self)
        #expect(form == "client_id=id-1&client_secret=s3cret&grant_type=refresh_token")
        #expect(
            String(decoding: FormEncoding.encode([("redirect_uri", "http://127.0.0.1:1/callback")]), as: UTF8.self)
                == "redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback")
        let exchange = try await client(secret: nil, server: server).exchange(
            code: await server.issueAuthorizationCode(for: "sub-1"), verifier: "v", redirectURI: redirect)
        #expect(exchange.refreshToken != nil)
        let last = try #require(await server.requests.last { $0.path == "/token" })
        let expected = FormEncoding.encode([
            ("client_id", "id-1.apps.googleusercontent.com"), ("code", "fake-code-1"), ("code_verifier", "v"),
            ("grant_type", "authorization_code"), ("redirect_uri", redirect.absoluteString),
        ])
        #expect(last.bodyBytes == expected.count)
    }
}
