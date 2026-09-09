import Contracts
import Foundation
import TimelineCore

/// What the token endpoint answered. Never `Codable`: it carries the refresh token.
public struct TokenResponse: Sendable {
    public var accessToken: String
    public var expiresAt: Date
    public var refreshToken: String?
    /// Google's canonical scope strings (`email` comes back as `.../auth/userinfo.email`).
    public var scopes: [String]
    public var idToken: String?

    public init(accessToken: String, expiresAt: Date, refreshToken: String?, scopes: [String], idToken: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.scopes = scopes
        self.idToken = idToken
    }
}

/// The claims PublishKit reads from an `id_token`.
public struct IDTokenClaims: Sendable, Hashable {
    public var sub: String
    public var email: String?
    public var emailVerified: Bool?
    public var name: String?
    public var picture: URL?
}

/// Google's OAuth 2.0 endpoints for an installed app, hand-rolled over `URLSession` (publish-plan.md D3;
/// docs/research/10-google-account-auth.md "Exact HTTP sequence").
public struct GoogleOAuthClient: Sendable {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    public let configuration: GoogleClientConfiguration
    public let session: URLSession
    private let clock: any Clock

    public init(configuration: GoogleClientConfiguration, session: URLSession, clock: any Clock = SystemClock()) {
        self.configuration = configuration
        self.session = session
        self.clock = clock
    }

    // MARK: Step 1: the authorization request

    /// `response_type=code`, the scopes, the S256 challenge, `state`, `access_type=offline`,
    /// `prompt=consent`, and `login_hint` when given.
    public func authorizationURL(scopes: [String], redirectURI: URL, pkce: PKCE, loginHint: String? = nil) -> URL {
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var fields = [
            ("client_id", configuration.clientId), ("redirect_uri", redirectURI.absoluteString),
            ("response_type", "code"), ("scope", scopes.joined(separator: " ")), ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"), ("state", pkce.state), ("access_type", "offline"),
            ("prompt", "consent"),
        ]
        if let loginHint, !loginHint.isEmpty { fields.append(("login_hint", loginHint)) }
        // Strict percent-encoding (`:` and `/` included), the form Google documents.
        components.percentEncodedQuery = String(decoding: FormEncoding.encode(fields), as: UTF8.self)
        return components.url!
    }

    // MARK: Step 2: the code exchange

    public func exchange(code: String, verifier: String, redirectURI: URL) async throws -> TokenResponse {
        var fields = [("client_id", configuration.clientId)]
        if let secret = configuration.clientSecret { fields.append(("client_secret", secret)) }
        fields += [
            ("code", code), ("code_verifier", verifier), ("grant_type", "authorization_code"),
            ("redirect_uri", redirectURI.absoluteString),
        ]
        return try await token(fields)
    }

    // MARK: Step 3: refresh

    /// A new access token; `400 invalid_grant` (revoked, or the 7-day Testing expiry) throws
    /// `AccountError.reauthorizationRequired`.
    public func refresh(refreshToken: String) async throws -> TokenResponse {
        var fields = [("client_id", configuration.clientId)]
        if let secret = configuration.clientSecret { fields.append(("client_secret", secret)) }
        fields += [("refresh_token", refreshToken), ("grant_type", "refresh_token")]
        var response = try await token(fields)
        if response.refreshToken == nil { response.refreshToken = refreshToken }
        return response
    }

    // MARK: Step 5: revoke

    /// `POST /revoke?token=`; 200 and 400 both count as revoked (the token is gone either way).
    public func revoke(token: String) async throws {
        var components = URLComponents(url: Self.revokeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()
        let (_, response) = try await perform(request)
        guard response.statusCode == 200 || response.statusCode == 400 else {
            throw AccountError.network("revoke answered \(response.statusCode)")
        }
    }

    // MARK: The id_token

    /// Decodes the payload of the JWT without checking the signature: the token came directly from
    /// Google over TLS (10 "Exact HTTP sequence" step 2).
    public static func decodeIDToken(_ jwt: String) throws -> IDTokenClaims {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let data = Base64URL.decode(String(parts[1])),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AccountError.protocolError("malformed id_token") }
        guard let sub = object["sub"] as? String, !sub.isEmpty else {
            throw AccountError.protocolError("id_token has no sub")
        }
        return IDTokenClaims(
            sub: sub, email: object["email"] as? String, emailVerified: object["email_verified"] as? Bool,
            name: object["name"] as? String, picture: (object["picture"] as? String).flatMap(URL.init(string:)))
    }

    /// Google reports `email` and `profile` as `.../auth/userinfo.email` and `.../auth/userinfo.profile`.
    public static func canonicalScope(_ scope: String) -> String {
        switch scope {
        case "email": "https://www.googleapis.com/auth/userinfo.email"
        case "profile": "https://www.googleapis.com/auth/userinfo.profile"
        default: scope
        }
    }

    /// The requested scopes the grant lacks (canonical forms compared).
    public static func missingScopes(requested: [String], granted: [String]) -> [String] {
        let have = Set(granted.map(canonicalScope))
        return requested.filter { !have.contains(canonicalScope($0)) }
    }

    // MARK: Plumbing

    private func token(_ fields: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.encode(fields)
        let (data, response) = try await perform(request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard response.statusCode == 200 else {
            let error = object["error"] as? String ?? "http \(response.statusCode)"
            let description = object["error_description"] as? String ?? ""
            if error == "invalid_grant" {
                throw AccountError.reauthorizationRequired(description.isEmpty ? error : description)
            }
            throw AccountError.protocolError(
                "token endpoint: \(error) \(description)".trimmingCharacters(in: .whitespaces))
        }
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            throw AccountError.protocolError("token response without access_token")
        }
        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let scopes = (object["scope"] as? String ?? "").split(separator: " ").map(String.init)
        return TokenResponse(
            accessToken: accessToken, expiresAt: clock.now().addingTimeInterval(expiresIn).millisecondPrecision,
            refreshToken: object["refresh_token"] as? String, scopes: scopes, idToken: object["id_token"] as? String)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AccountError.protocolError("non-HTTP response from \(request.url?.host() ?? "?")")
            }
            return (data, http)
        } catch let error as AccountError {
            throw error
        } catch {
            throw AccountError.network(error.localizedDescription)
        }
    }
}
