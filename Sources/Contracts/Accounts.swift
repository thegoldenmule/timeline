import Foundation
import TimelineCore

// MARK: - DTOs

public enum AccountProviderKind: String, Codable, Sendable, Hashable, CaseIterable { case google }

public enum AccountTokenStatus: Hashable, Sendable, Codable {
    /// An access token is held and valid until `expiresAt`.
    case valid(expiresAt: Date)
    /// Refresh token present, no live access token; the next `accessToken(for:)` refreshes.
    case expired
    /// Refresh failed (`invalid_grant`): revoked, or the 7-day expiry of a project in Testing status.
    case reauthorizationRequired(String)

    public var needsReauthorization: Bool {
        if case .reauthorizationRequired = self { return true }
        return false
    }
}

/// The non-secret half of a connected account: what settings, the sheet, and the approval card show.
/// Stored in `accounts.json` next to the token file (publish-plan.md D14); never carries a token.
public struct ConnectedAccount: Hashable, Sendable, Codable, Identifiable {
    /// Provider-scoped stable subject (Google `sub`), never the email.
    public var id: String
    public var provider: AccountProviderKind
    public var email: String?
    public var displayName: String?
    public var channelId: String?
    public var channelTitle: String?
    /// "@handle" from `channels.list` `snippet.customUrl`.
    public var channelHandle: String?
    public var avatarURL: URL?
    public var scopes: [String]
    public var connectedAt: Date
    /// Last `channels.list`; refreshed when older than 30 days (YouTube policy III.E.4.c).
    public var refreshedAt: Date
    public var tokenStatus: AccountTokenStatus

    public init(
        id: String, provider: AccountProviderKind, email: String? = nil, displayName: String? = nil,
        channelId: String? = nil, channelTitle: String? = nil, channelHandle: String? = nil, avatarURL: URL? = nil,
        scopes: [String], connectedAt: Date, refreshedAt: Date, tokenStatus: AccountTokenStatus
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.displayName = displayName
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.channelHandle = channelHandle
        self.avatarURL = avatarURL
        self.scopes = scopes
        self.connectedAt = connectedAt
        self.refreshedAt = refreshedAt
        self.tokenStatus = tokenStatus
    }
}

/// A bearer token. Deliberately not Codable, not Hashable, and with a redacting description, so it
/// cannot land in a receipt, a tool output, a log line, or a fixture by accident. Hold it for one
/// request; ask the provider again for the next one.
public struct AccessToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public let expiresAt: Date
    public let scopes: [String]

    public init(value: String, expiresAt: Date, scopes: [String]) {
        self.value = value
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    public var authorizationHeader: String { "Bearer \(value)" }

    /// True while the token is good for at least `lifetime` more.
    public func isValid(for lifetime: Duration, now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) >= Double(lifetime.components.seconds)
    }

    public var description: String { "AccessToken(expires \(expiresAt), \(scopes.count) scopes)" }
    public var debugDescription: String { description }
}

public enum AccountError: Error, Hashable, Sendable, Codable {
    /// No OAuth client; the message says where to put one.
    case notConfigured(String)
    /// The browser flow was abandoned or timed out.
    case cancelled
    /// Consent refused, or a required scope unticked.
    case denied(String)
    /// Unknown account id.
    case notConnected(String)
    case reauthorizationRequired(String)
    /// The Google account owns no YouTube channel.
    case noChannel(String)
    /// Keychain status or file error, described.
    case storage(String)
    case network(String)
    /// State mismatch, malformed token response.
    case protocolError(String)

    public var message: String {
        switch self {
        case .notConfigured(let detail): "No OAuth client is configured: \(detail)"
        case .cancelled: "The sign-in was cancelled"
        case .denied(let detail): "Access was denied: \(detail)"
        case .notConnected(let id): "No connected account with id \(id)"
        case .reauthorizationRequired(let detail): "Reconnect the account: \(detail)"
        case .noChannel(let detail): "The Google account has no YouTube channel: \(detail)"
        case .storage(let detail): "Credential storage failed: \(detail)"
        case .network(let detail): "Network error: \(detail)"
        case .protocolError(let detail): "Unexpected response from the provider: \(detail)"
        }
    }
}

extension AccountError: LocalizedError { public var errorDescription: String? { message } }

// MARK: - Protocols

/// Opens the provider's authorization URL for the user. The redirect comes back on the provider's own
/// loopback listener, so a presenter only has to open the URL (`NSWorkspace.shared.open` in the app,
/// a fake that performs the callback in tests, an `ASWebAuthenticationSession` presenter later).
public protocol AuthorizationPresenter: Sendable { @MainActor func open(_ authorizationURL: URL) async throws }

/// Connects, disconnects, and vends tokens for one provider. `connect` is `@MainActor` because it
/// presents a browser; everything else is pure async work. `changes` is a fresh stream per access
/// (the `Broadcaster` rule of contracts-notes.md) yielding the full account list after every change.
///
/// Rules every implementation keeps:
/// - `accounts()` and `changes` carry `ConnectedAccount` values only; a token never leaves
///   `accessToken(for:minimumLifetime:)`, and that value is never encoded.
/// - `connect` requests exactly `scopes` (installed apps have no incremental authorization) and throws
///   `AccountError.denied` when the grant comes back without one of them.
/// - `disconnect` revokes with the provider (best effort: a 200 or a 400 both count), deletes the stored
///   credential and the record, and yields the shortened list on `changes`.
/// - A refresh that fails with `invalid_grant` marks the record `reauthorizationRequired`, persists it,
///   and throws `AccountError.reauthorizationRequired`; the account stays listed so the UI can offer
///   "Reconnect".
public protocol AccountProvider: Sendable {
    var kind: AccountProviderKind { get }
    /// False when no OAuth client is configured; the UI shows how to add one, tools are hidden.
    var isConfigured: Bool { get }
    func accounts() async -> [ConnectedAccount]
    @MainActor func connect(scopes: [String], loginHint: String?) async throws -> ConnectedAccount
    /// Revokes with the provider (best effort) and deletes the stored credential and record.
    func disconnect(_ id: String) async throws
    /// Re-reads channel and profile; refreshes the token if needed.
    func refresh(_ id: String) async throws -> ConnectedAccount
    /// A token valid for at least `minimumLifetime`, refreshed transparently. Hold it for one request.
    func accessToken(for id: String, minimumLifetime: Duration) async throws -> AccessToken
    /// A fresh stream per access, yielding the full account list after every change made after the access.
    var changes: AsyncStream<[ConnectedAccount]> { get }
}
