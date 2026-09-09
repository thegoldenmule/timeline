# Publish plan: connect a Google account, upload to YouTube

Status: implementation plan, 2026-09-09. Feature: connect a Google account from the app and upload a render to the user's YouTube channel, from the Publish sheet and from the agent's tools. Sources: `docs/research/10-google-account-auth.md` (auth), `11-youtube-upload.md` (upload), `12-publishing-architecture.md` (placement). Rules: `docs/design/implementation-plan.md`, `conventions.md`, `contracts-notes.md`, `integration.md`, `storage.md`, `timeline-model.md`. This document is written so the implementation agents do not need to read the research; the section references say where the reasoning lives.

Shape in one paragraph: one new leaf module, `PublishKit` (imports `TimelineCore`, `Contracts`, swift-nio), ships `GoogleAccountProvider` (OAuth 2.0 with PKCE, loopback redirect in the default browser, Keychain or file token store) and `YouTubePublisher` (resumable chunked upload with resume, processing poll, thumbnail, captions, playlist) behind two new `Contracts` protocols, `AccountProvider` and `Publisher`. A publish is a `Job` of kind `.publish` recorded in a new `publishes` table next to `renders`, never an event. The `publish_youtube` tool is gated `.always`; the Publish sheet calls the same tool through `ToolConsole`, so the human path and the agent path take the same approval round trip and the approval card is the express consent YouTube's policies require. Everything new is tested against fakes in `ContractsTestSupport`, including a `URLProtocol` fake of Google's endpoints; one opt-in live test uploads and deletes a private clip.

## 0. Where the research disagreed, and what this plan uses

Rule from the brief: 10 and 11 win on Google facts, 12 wins on codebase facts. Resolutions:

| Topic | 12 said | 10 / 11 say | This plan |
|---|---|---|---|
| Quota | `videos.insert` 1,600 units of 10,000/day, "six uploads a day" (12 §8.3, *[memory]*) | Since 2026-06-01 `videos.insert` is its own bucket: 100 calls/day at 1 per call; 10,000 units/day for everything else; `thumbnails.set` 50, `captions.insert` 400, `videos.list` 1, `playlistItems.insert` 50 (11 §6) | 11. The quota guard counts uploads against 100/day and units against 10,000/day (section 1, D11) |
| Scopes | `youtube.upload` + `youtube.force-ssl` (12 §2.2) | `captions.insert` accepts only `youtube.force-ssl`; policy III.D.2.b forbids unused scopes; one scope covers insert, thumbnails, captions, playlists, `channels.list` (11 §1); `openid email` gives `sub` in the `id_token` (10 §6) | `openid email https://www.googleapis.com/auth/youtube.force-ssl` (D2) |
| Private-only uploads from unaudited projects | *[memory; important to confirm]* (12 §8.4) | Confirmed from `videos.insert` docs: projects created after 2020-07-28 upload private until the compliance audit passes; `publishAt` cannot work before that (11 intro, §6) | Treated as fact; surfaced in the sheet, the card, and the receipt (D6) |
| Live test cost | about 1,650 units (12 §7.2) | 1 upload call + about 105 units (11 §6) | 11; still opt-in, never in `make test` |
| Chunking | 32 MiB chunks *[memory]* (12 §8.1) | Chunks must be multiples of 256 KiB; whole-file `PUT` is Google's default; `URLSession` cannot upload a byte range of a file, so a resume either copies the tail or sends `Data` chunks (11 §2, §9) | Chunked `PUT` of 32 MiB `Data` chunks read through `FileHandle` (D5); the reason is 11 §9's `URLSession` limitation, not throughput |
| Retry policy | unspecified | 500/502/503/504 and connection errors: query status, resume, exponential backoff with jitter, cap 10, honour `Retry-After`; `401` refresh once; `403 quotaExceeded`; `400 uploadLimitExceeded`; `404` on status query = session gone (11 §2) | Exactly that (D5) |
| Dev token file location | `<root>/Cache/google-tokens.json` (12 §3.1) | Keychain in the signed app; a `0600` file outside the cache for the unbundled binary (10 §2, §Recommendation 4) | `<root>/google-tokens.json` under `TIMELINE_ROOT`, else `~/Library/Application Support/Timeline/google-tokens.json`; never under `Cache/`, which is disposable (D4) |
| Client id source | a file the console downloads, never in the repo (12 §2.5) | embed as constants (10 §Recommendation 1) | 12 (codebase rule: no credentials in the repo) plus the brief's `TIMELINE_GOOGLE_CLIENT_ID` env var (D3) |
| Tool count | fold `account_status` into `publish_status` to stay near 15 (12 §6) | n/a | Three tools as the brief specifies: `publish_youtube`, `publish_status`, `account_status` (18 tools) |
| `selfDeclaredMadeForKids` | tool input `madeForKids` default `false` (12 §6) | ToS 9.1: either let the user set it before upload or tell them to set it on YouTube immediately after (11 §3, §6) | The agent never sends the field; only the sheet sets it; the card and the tool output carry the "set the audience in YouTube Studio" notice (D9) |
| Session lifetime | "YouTube keeps a partial session for a while *[memory]*" | Finite, undocumented; Drive/GCS document one week; design for `404` (11 §2) | Persist the session; on `404` start a new session with the same metadata once, then fail `sessionExpired` |

Codebase facts from 12 §0 that this plan relies on and that were re-verified on 2026-09-09: `renders` exists and nothing outside `ProjectStore` writes it; `render_export` (`Sources/AgentKit/Tools/RenderTools.swift`) never records a row and defaults its output path to `LibraryLayout.default.root/Exports`, ignoring `TIMELINE_ROOT`; `ApprovalRequest.inputSummary` is minted by the gate from the input alone; `JobKind` has no `.publish`; `ToolServices` holds optionals and `EditorTools.requiredService` hides tools whose service is missing; `MCPServerHost` is a swift-nio `ServerBootstrap` on 127.0.0.1; `TimelineApp` is an SPM executable with no bundle; `TimelineApp` already depends on `ContractsTestSupport`; there are 378 `@Test` functions.

## 1. Decisions

Each one line, with the reason and the research section.

- **D1. OAuth client type: "Desktop app"; redirect: loopback `http://127.0.0.1:<random port>/callback`, opened in the default browser through an injected `AuthorizationPresenter`.** Google's recommended desktop mechanism, works from `swift run` and from a signed `.app`, needs no bundle, `Info.plist`, entitlement, or window; custom schemes are being withdrawn and `ASWebAuthenticationSession` is unproven unbundled (10 §1, §2, Recommendation 3). `AuthorizationPresenter` is a protocol from day one so an `ASWebAuthenticationSession` presenter can replace `NSWorkspace.open` when the app ships as a bundle (12 §8.2).
- **D2. Scope set, requested once: `openid email https://www.googleapis.com/auth/youtube.force-ssl`.** Captions force `youtube.force-ssl`, which also covers `videos.insert`, `thumbnails.set`, `channels.list`, `playlistItems.insert`; policy III.D.2.b forbids extra scopes; installed apps have no incremental authorization so the set is fixed up front; `openid email` (non-sensitive) puts `sub` and `email` in the `id_token`, saving a `userinfo` call (11 §1, 10 §1, §6). A future scope change is disconnect + reconnect.
- **D3. Hand-rolled `URLSession` client, no SDK.** PKCE is 30 lines over CryptoKit, the flow is four HTTP calls, the resumable protocol is a loop; GoogleSignIn and AppAuth are Objective-C, expect a bundle and a client plist, and would be the largest dependency in the package (10 §5, 12 §1). The client id comes from `TIMELINE_GOOGLE_CLIENT_ID` (+ optional `TIMELINE_GOOGLE_CLIENT_SECRET`), else `TIMELINE_GOOGLE_CLIENT_JSON` (path to the console's `client_secret_*.json`), else `<root>/google-oauth-client.json` under `TIMELINE_ROOT`, else `~/Library/Application Support/Timeline/google-oauth-client.json`; never in the repo. The "secret" of a Desktop client is not confidential but is sent when present to avoid `invalid_client` (10 §1).
- **D4. Token storage: `TokenStore` protocol with `KeychainTokenStore` (signed `.app`) and `FileTokenStore` (dev binary, tests).** The Keychain item is a generic password, service `com.thegoldenmule.timeline.google-oauth`, account = Google `sub`, `kSecUseDataProtectionKeychain: true` + `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, falling back to the legacy keychain on `errSecMissingEntitlement`; an unsigned SPM binary re-prompts after every rebuild, so unbundled runs use a `0600` JSON file (10 §2 Keychain, Recommendation 4). Selection: `TIMELINE_TOKEN_STORE=keychain|file` wins, else `.app` bundle means Keychain, else file. Access tokens live in memory only.
- **D5. Upload: resumable session, then chunked `PUT`s of 32 MiB (`UploadOptions.chunkBytes`, a multiple of 262,144) read through `FileHandle`, next offset always from the `308 Range` header; on 5xx or a connection error query status (`Content-Range: bytes */total`) and resume, exponential backoff with jitter capped at 10 attempts, `Retry-After` honoured; `401` refreshes the token and resends the same chunk; `403 quotaExceeded` and `400 uploadLimitExceeded` fail the job with the reset time; `404` on the status query opens a new session once.** Chunks rather than a whole-file `PUT` because `URLSession` cannot upload a byte range of a file, so a resume would otherwise copy the tail of a multi-GB export; 32 MiB keeps the job honestly in memory class `.small` (11 §2, §9; 12 §8.1). The `PublishSession` (session URI, total, confirmed bytes) is persisted in the ledger before the first byte so a crash or quit resumes with a status query, never a restart. A `ProcessInfo.beginActivity(.idleSystemSleepDisabled)` token is held for the job.
- **D6. Default privacy `private`; `public` requires the literal value; `publishAt` requires `private`.** Uploads from an unaudited project are forced private anyway (11 intro); the receipt records the privacy the API reports back and warns when it differs from the request; the sheet, the card, and `account_status` carry the notice "Uploads from this Google Cloud project are private until it passes the YouTube compliance audit" driven by `Publisher.capabilities().publicUploadsAllowed` (from the client configuration's `audited` flag, default false).
- **D7. Captions come from the sequence's caption track, exported as timed SRT (default) or WebVTT; never from the raw transcript.** Transcript times are media-relative and wrong after any cut; caption clips are timeline-relative; YouTube's `sync` parameter is gone so files must carry timings; SRT is the most compatible (11 §4, 12 §5). `CaptionCues.make(track:in:)` (pure, in `Contracts`) turns caption clips into cues; PublishKit's `SRTWriter`/`VTTWriter` format them.
- **D8. Shorts are an export preset, not an API option.** YouTube classifies by shape and length (square or vertical, up to 3 minutes); `validate` warns when a portrait export is over 3:00 or when a square-or-vertical export under 3:00 will become a Short (11 §5). `ExportPreset.reel9x16` already exists; a `short9x16` preset is not part of this plan.
- **D9. `containsSyntheticMedia` defaults to `false` and is always shown for confirmation; `selfDeclaredMadeForKids` is set by the human only.** No provenance signal exists yet (no generative provider is wired), so the toggle carries the exempt list as help text; the agent may propose `containsSyntheticMedia` with a reason and the card shows it. The agent never sends `madeForKids`; the request's `madeForKids` is `Bool?` and `nil` omits the field, and the card and tool output tell the user to set the audience in YouTube Studio right after upload (ToS 9.1, 11 §3, §6).
- **D10. Idempotency key: `publishId` (UUIDv7).** A call whose id has a `queued`, `uploading`, `processing`, or `done` row returns that row's status without uploading; a `failed` or `cancelled` row with a session resumes it; the `approval_required` output carries the `publishId` it will use so the retry and the Skill pass the same one (12 §4).
- **D11. Quota guard: a local `QuotaMeter` per library root (`<root>/Cache/publish-quota.json`, disposable) counting uploads (limit 100) and units (limit 10,000) per Pacific day; the tool refuses with `quotaExceeded(resetsAt:)` before moving bytes; a `403 quotaExceeded` marks the day exhausted.** 11 §6.
- **D12. Consent text placement.** The sheet shows, under the Upload button, "By clicking Upload you certify that the content you are uploading complies with the YouTube Terms of Service" with the link (ToS 9.1, 11 §6); the approval card's details repeat the sentence as its last row, because for the agent path the card is the click; the account view shows "Timeline uses YouTube API Services. Connecting means you agree to the YouTube Terms of Service and the Google Privacy Policy", the "Manage access" link to `https://myaccount.google.com/permissions`, and the unverified-app and 7-day-testing notices (10 §4, §7).
- **D13. Disconnect = `POST /revoke` (200 or 400 both count) + delete the credential from the `TokenStore` + remove the account record + delete cached avatar and quota, immediately.** Policy III.E.4 requires deletion within 7 days of revocation and refresh or deletion of stored API data after 30 days; the account record carries `refreshedAt` and `GoogleAccountProvider.refresh` re-reads `channels.list` on boot when it is older than 30 days (10 §3, 11 §6). `publishes` rows keep `remote_id`, `remote_url`, status, and the receipt as the user's own record of their own uploads (open question 6.8).
- **D14. Account records (non-secret) live in `accounts.json` next to the token file (`<root>/accounts.json` under `TIMELINE_ROOT`, else `~/Library/Application Support/Timeline/accounts.json`).** Per user, cross project, not derived (deleting `Cache/` must not disconnect), small; the UI renders "Connected as" without touching the Keychain (12 §3.1, 10 Recommendation 5).
- **D15. Placement: `PublishKit` leaf module; `publishes` table in `project.sqlite`; render row recorded by `render_export`; approval presentation is an additive field on `ApprovalRequest`.** 12 §1, §2, §3.

## 2. Contracts changes (land first, one commit, the Contracts agent)

Owner: the Contracts agent. Files: `Sources/Contracts/*.swift`, `Sources/ContractsTestSupport/**`, `Tests/ContractsTests/*.swift`, plus `Fixtures/` JSON if a codec fixture is added. Nothing else. Everything is additive; all 378 existing tests stay green (`make test`). Where an existing test asserts a count or a policy table (for example `ApprovalPolicy.standard`), update that test in the same commit. If any exhaustive `switch` over `JobKind` exists outside `Contracts`, it does not (verified: `BudgetedJobRunner` keys on `memoryClass`, `JobProgressView` prints `rawValue`), so adding a case is safe.

### 2.1 `Sources/Contracts/Accounts.swift` (new)

```swift
import Foundation
import TimelineCore

public enum AccountProviderKind: String, Codable, Sendable, Hashable, CaseIterable { case google }

public enum AccountTokenStatus: Hashable, Sendable, Codable {
    /// An access token is held and valid until `expiresAt`.
    case valid(expiresAt: Date)
    /// Refresh token present, no live access token; the next `accessToken(for:)` refreshes.
    case expired
    /// Refresh failed (`invalid_grant`): revoked, or the 7-day expiry of a project in Testing status.
    case reauthorizationRequired(String)
}

/// The non-secret half of a connected account: what settings, the sheet, and the approval card show.
public struct ConnectedAccount: Hashable, Sendable, Codable, Identifiable {
    public var id: String                     // provider-scoped stable subject (Google `sub`), never the email
    public var provider: AccountProviderKind
    public var email: String?
    public var displayName: String?
    public var channelId: String?
    public var channelTitle: String?
    public var channelHandle: String?         // "@handle" from channels.list snippet.customUrl
    public var avatarURL: URL?
    public var scopes: [String]
    public var connectedAt: Date
    /// Last `channels.list`; refreshed when older than 30 days (YouTube policy III.E.4.c).
    public var refreshedAt: Date
    public var tokenStatus: AccountTokenStatus
    public init(...)                          // memberwise, every field
}

/// A bearer token. Deliberately not Codable, not Hashable, and with a redacting description, so it
/// cannot land in a receipt, a tool output, a log line, or a fixture by accident.
public struct AccessToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public let expiresAt: Date
    public let scopes: [String]
    public init(value: String, expiresAt: Date, scopes: [String])
    public var authorizationHeader: String { "Bearer \(value)" }
    public var description: String { "AccessToken(expires \(expiresAt), \(scopes.count) scopes)" }
    public var debugDescription: String { description }
}

public enum AccountError: Error, Hashable, Sendable, Codable {
    case notConfigured(String)                // no OAuth client; the message says where to put one
    case cancelled                            // the browser flow was abandoned or timed out
    case denied(String)                       // consent refused, or a required scope unticked
    case notConnected(String)                 // unknown account id
    case reauthorizationRequired(String)
    case noChannel(String)                    // the Google account owns no YouTube channel
    case storage(String)                      // Keychain status or file error, described
    case network(String)
    case protocolError(String)                // state mismatch, malformed token response
}

extension AccountError: LocalizedError { public var errorDescription: String? { ... } }

/// Opens the provider's authorization URL for the user. The redirect comes back on the provider's own
/// loopback listener, so a presenter only has to open the URL (`NSWorkspace.shared.open` in the app,
/// a fake that performs the callback in tests, an `ASWebAuthenticationSession` presenter later).
public protocol AuthorizationPresenter: Sendable {
    @MainActor func open(_ authorizationURL: URL) async throws
}

/// Connects, disconnects, and vends tokens for one provider. `connect` is `@MainActor` because it
/// presents a browser; everything else is pure async work. `changes` is a fresh stream per access
/// (the `Broadcaster` rule of contracts-notes.md) yielding the full account list after every change.
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
    var changes: AsyncStream<[ConnectedAccount]> { get }
}
```

### 2.2 `Sources/Contracts/Publishing.swift` (new)

```swift
public enum PublishDestination: String, Codable, Sendable, Hashable, CaseIterable { case youtube }
public enum PublishPrivacy: String, Codable, Sendable, Hashable, CaseIterable { case `private`, unlisted, `public` }
public enum CaptionFormat: String, Codable, Sendable, Hashable, CaseIterable { case srt, vtt }

/// A JPEG or PNG on disk (YouTube: at most 2 MB, 16:9 or 9:16). `sourceTime` is set when the file was
/// grabbed from the sequence, so the card can say "frame at 12.4 s".
public struct PublishThumbnail: Hashable, Sendable, Codable {
    public var fileURL: URL
    public var sourceTime: RationalTime?
}

/// One caption cue in timeline time (see `CaptionCues` in Captions.swift).
public struct CaptionCue: Hashable, Sendable, Codable {
    public var start: RationalTime
    public var end: RationalTime
    public var text: String
}

public struct PublishCaptionTrack: Hashable, Sendable, Codable {
    public var trackId: TrackID?
    public var language: String               // BCP-47
    public var name: String                   // at most 150 characters
    public var format: CaptionFormat
    public var cues: [CaptionCue]
}

/// Everything a publish needs; built by the tool from its input, or by the sheet. No secrets by
/// construction: the account is referenced by id, the token is fetched per request inside the publisher.
public struct PublishRequest: Hashable, Sendable, Codable {
    public var destination: PublishDestination
    public var accountId: String
    public var renderId: String
    public var fileURL: URL
    /// `renders.output_hash`; the job re-hashes the file and refuses one that differs (`hashMismatch`).
    public var expectedContentHash: String?
    public var projectVersion: Int64?
    public var title: String                  // YouTube: 1-100 characters, no "<" or ">"
    public var description: String            // at most 5,000 bytes
    public var tags: [String]                 // at most 500 characters in total
    public var categoryId: String?            // assignable category id, e.g. "22"
    public var language: String?              // snippet.defaultLanguage
    public var privacy: PublishPrivacy        // default .private
    public var publishAt: Date?               // requires .private
    /// nil: not declared (the agent path); the sheet sets true or false (ToS 9.1).
    public var madeForKids: Bool?
    public var containsSyntheticMedia: Bool   // default false, always confirmed by the human
    public var notifySubscribers: Bool        // default false
    public var recordingDate: Date?
    public var thumbnail: PublishThumbnail?
    public var captions: [PublishCaptionTrack]
    public var playlistId: String?
    /// From the render: what the Shorts warnings and the estimate use.
    public var durationSeconds: Double?
    public var width: Int?
    public var height: Int?
    public init(...)                          // memberwise with the defaults above
}

/// Enough to continue an interrupted upload after a crash or relaunch. The upload URL is a capability
/// URL: it lives in the ledger only, never in a receipt, a tool output, or a log.
public struct PublishSession: Hashable, Sendable, Codable {
    public var uploadURL: URL
    public var totalBytes: Int64
    public var bytesConfirmed: Int64
    public var startedAt: Date
    public var resumedCount: Int
}

public enum PublishStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case queued, uploading, processing, done, failed, cancelled
    public var isTerminal: Bool { self == .done || self == .failed || self == .cancelled }
}

public enum PublishStage: String, Codable, Sendable, Hashable, CaseIterable {
    case verify, session, upload, processing, thumbnail, captions, playlist
}

/// What a running publish tells its owner, so the ledger can be kept current while the job runs.
public enum PublishEvent: Hashable, Sendable {
    case session(PublishSession)              // created, or bytes confirmed
    case uploaded(remoteId: String, remoteURL: URL)
    case stage(PublishStage)
}

/// Returned as the publish job's payload and stored in `publishes.receipt`. No secrets, no upload URL.
public struct PublishReceipt: Hashable, Sendable, Codable {
    public var publishId: String
    public var destination: PublishDestination
    public var accountId: String
    public var channelId: String?
    public var channelTitle: String?
    public var renderId: String
    public var contentHash: String
    public var projectVersion: Int64?
    public var remoteId: String               // YouTube videoId
    public var remoteURL: URL                 // https://youtu.be/<id>
    public var studioURL: URL?                // https://studio.youtube.com/video/<id>/edit
    public var requestedPrivacy: PublishPrivacy
    public var privacy: PublishPrivacy        // as reported back by the API after upload (D6)
    public var publishAt: Date?
    public var madeForKids: Bool?
    public var containsSyntheticMedia: Bool
    public var bytesUploaded: Int64
    public var resumedCount: Int
    public var thumbnailSet: Bool
    public var captionIds: [String]
    public var playlistItemId: String?
    public var processingStatus: String?      // uploaded | processed | failed | rejected
    public var startedAt: Date
    public var finishedAt: Date
    public var warnings: [String]
}

/// A `publishes` row (storage.md section 5 companion table; operational, never an event).
public struct PublishRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var renderId: String
    public var destination: PublishDestination
    public var accountId: String
    public var status: PublishStatus
    public var request: PublishRequest
    public var session: PublishSession?
    public var bytesTotal: Int64?
    public var bytesSent: Int64?
    public var remoteId: String?
    public var remoteURL: URL?
    public var projectVersion: Int64
    public var receipt: PublishReceipt?
    public var error: String?
    public var requestedAt: Date
    public var completedAt: Date?
}

/// Fields to change on a row; nil leaves a field alone. `clearsSession` drops the capability URL once
/// the upload has finished.
public struct PublishUpdate: Hashable, Sendable {
    public var status: PublishStatus?
    public var session: PublishSession?
    public var clearsSession: Bool
    public var bytesSent: Int64?
    public var remoteId: String?
    public var remoteURL: URL?
    public var receipt: PublishReceipt?
    public var error: String?
    public init(status: PublishStatus? = nil, session: PublishSession? = nil, clearsSession: Bool = false,
                bytesSent: Int64? = nil, remoteId: String? = nil, remoteURL: URL? = nil,
                receipt: PublishReceipt? = nil, error: String? = nil)
}

public struct PublishQuota: Hashable, Sendable, Codable {
    public var uploadsUsed: Int
    public var uploadsLimit: Int              // 100 per project per day
    public var unitsUsed: Int
    public var unitsLimit: Int                // 10,000 per project per day
    public var resetsAt: Date                 // next midnight Pacific
    public var uploadsRemaining: Int { max(0, uploadsLimit - uploadsUsed) }
}

public struct PublishCapabilities: Hashable, Sendable, Codable {
    /// False until the Google Cloud project has passed the YouTube compliance audit (D6).
    public var publicUploadsAllowed: Bool
    public var note: String?
}

public enum PublishError: Error, Hashable, Sendable, Codable {
    case invalidRequest(String)
    case fileMissing(URL)
    case hashMismatch(expected: String, found: String)
    case notConnected(String)
    case reauthorizationRequired(String)
    case quotaExceeded(resetsAt: Date?)
    case uploadLimitExceeded                  // 400 uploadLimitExceeded: the channel's own daily allowance
    case forbidden(String)                    // e.g. thumbnails.set on a channel without phone verification
    case sessionExpired
    case uploadFailed(status: Int, reason: String)
    case rejected(reason: String)             // status.rejectionReason after processing
    case processingFailed(String)
    case cancelled
    case network(String)
}
extension PublishError: LocalizedError { ... }

/// One destination. `publish` returns the upload as a job (kind `.publish`, class `.small`); its
/// outcome payload is a `PublishReceipt`. `onEvent` is called from inside the job so the caller can
/// persist the session and the remote id as they appear; `resuming` continues a session from the
/// ledger. Progress: `fraction = bytesConfirmed / total` during upload, `stage` = a `PublishStage`
/// raw value, `etaSeconds` from the running rate.
public protocol Publisher: Sendable {
    var destination: PublishDestination { get }
    var requiredScopes: [String] { get }
    /// Local checks only (lengths, file exists, privacy and publishAt agree, Shorts shape); returns
    /// warnings, throws `PublishError.invalidRequest` for hard violations. Never alters the request.
    func validate(_ request: PublishRequest) async throws -> [String]
    /// Bytes from the file size, seconds from the measured upload rate, usd 0.
    func estimate(_ request: PublishRequest) async -> Estimate
    func quota() async -> PublishQuota
    func capabilities() async -> PublishCapabilities
    func publish(_ request: PublishRequest, publishId: String, resuming: PublishSession?,
                 onEvent: @escaping @Sendable (PublishEvent) async -> Void) -> Job
    func remoteStatus(remoteId: String, accountId: String) async throws -> RemotePublishStatus
}

public struct RemotePublishStatus: Hashable, Sendable, Codable {
    public var uploadStatus: String           // uploaded | processed | failed | rejected | deleted
    public var privacy: PublishPrivacy?
    public var processingStatus: String?
    public var failureReason: String?
    public var rejectionReason: String?
}
```

### 2.3 `Sources/Contracts/Renderer.swift` and `Ledgers.swift` (render ledger, closes 12 §0 gaps 1 and 2)

`ExportReceipt` gains `public var outputHash: String?` (last field, `nil` default in `init`, decodes `nil` when absent). New file `Sources/Contracts/Ledgers.swift`:

```swift
public enum RenderStatus: String, Codable, Sendable, Hashable, CaseIterable { case queued, running, done, failed, cancelled }

/// A `renders` row (storage.md section 5): operational, never an event.
public struct RenderRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var sequenceId: SequenceID
    public var preset: ExportPreset
    public var projectVersion: Int64
    public var status: RenderStatus
    public var requestedAt: Date
    public var completedAt: Date?
    public var outputURL: URL?
    public var outputHash: String?            // "sha256-<64 hex>", the same form as Asset.contentHash
    public var receipt: ExportReceipt?
}

/// Stores that keep the render ledger. `SQLiteProjectStore` and `FakeProjectStore` adopt it; a tool
/// reaches it with `store as? any RenderLedger`, the way Fork reaches `ProjectStoreCopying`.
public protocol RenderLedger: ProjectStore {
    func recordRender(id: String?, sequenceId: SequenceID, preset: ExportPreset, projectVersion: Int64?) async throws -> RenderRecord
    func updateRender(_ id: String, status: RenderStatus, outputURL: URL?, outputHash: String?, receipt: ExportReceipt?) async throws -> RenderRecord
    func renders() async throws -> [RenderRecord]      // newest first
    func render(_ id: String) async throws -> RenderRecord?
}

public protocol PublishLedger: ProjectStore {
    func recordPublish(id: String?, request: PublishRequest, projectVersion: Int64?) async throws -> PublishRecord
    func updatePublish(_ id: String, _ update: PublishUpdate) async throws -> PublishRecord
    func publishes() async throws -> [PublishRecord]   // newest first
    func publish(_ id: String) async throws -> PublishRecord?
    func publishes(forRender renderId: String) async throws -> [PublishRecord]
}
```

Rules both ledgers keep (tested on the fake and on SQLite): an unknown id throws; `done`, `failed`, and `cancelled` set `completedAt`; recording never bumps the project version or publishes a `ProjectChange`; `recordPublish` with an unknown `renderId` throws.

### 2.4 `Sources/Contracts/Captions.swift` and `Hashing.swift` (new)

```swift
/// Timeline-relative cues from a caption track: one per caption clip, `start = clip.start`,
/// `end = sequence.end(of: clip)`, text = `clip.text`, sorted by start, empty texts skipped.
public enum CaptionCues {
    public static func make(from track: Track, in sequence: Sequence) -> [CaptionCue]
}

/// Streamed SHA-256 (`sha256-<64 lowercase hex>`, MediaKit's `ContentHash` form), 8 MiB reads, so
/// RenderKit's receipts, `render_export`, PublishKit's verify stage, and the fakes agree on one form.
public enum FileHash {
    public static func sha256(of url: URL) throws -> String
}
```

`Contracts` therefore imports CryptoKit (a system framework; no `Package.swift` change is needed, the lead adds it to the conventions table). `LibraryLayout` gains `public var exportsDir: URL { root.appendingPathComponent("Exports", isDirectory: true) }` so `render_export` stops hard-coding the default root.

### 2.5 `Sources/Contracts/Approvals.swift` (presentation)

```swift
public struct ApprovalDetail: Hashable, Sendable, Codable { public var label: String; public var value: String }

/// What a tool wants the card to show instead of the gate's generic `tool(key=value)` summary.
public struct ApprovalPresentation: Hashable, Sendable, Codable {
    public var summary: String                // "Publish \"Band rehearsal\" to YouTube as Private"
    public var details: [ApprovalDetail]      // ordered label/value rows
    public var warnings: [String]             // rendered in a warning colour
}

// ApprovalRequest gains `public var presentation: ApprovalPresentation?` (last init parameter, default nil;
// synthesized Codable decodes nil when the key is absent, so recorded transcripts still parse).

public protocol ApprovalGate: Sendable {
    // existing requirements unchanged, plus:
    func check(tool: String, input: ToolInput, estimate: Estimate, presentation: ApprovalPresentation?,
               actor: Actor, sessionId: String?) async -> ApprovalDecision
}
extension ApprovalGate {
    /// Default keeps existing gates conforming: presentation is dropped. Gates that raise cards
    /// (`FakeApprovalGate`, the app's `StandardApprovalGate`, AgentKit's `RecordingApprovalGate`)
    /// override it and store the presentation on the request.
    public func check(tool:input:estimate:presentation:actor:sessionId:) async -> ApprovalDecision {
        await check(tool: tool, input: input, estimate: estimate, actor: actor, sessionId: sessionId)
    }
}
// ToolContext gains
public func checkApproval(tool: String, input: ToolInput, estimate: Estimate, presentation: ApprovalPresentation?) async -> ApprovalDecision
// ToolOutput.approvalRequired(_:) encodes "summary" = request.presentation?.summary ?? request.inputSummary,
// plus "details": [{label, value}] and "warnings": [String] (empty arrays when there is no presentation).
// ApprovalPolicy.standard gains "publish_youtube": .always, "publish_status": .never, "account_status": .never.
```

### 2.6 `Jobs.swift` and `Tools.swift`

- `JobKind` gains `case publish`.
- `JobRunner` gains `func handle(for id: JobID) async -> JobHandle?` with a protocol-extension default returning `nil`. The app's `PublishConsole` uses it to put a job the tool submitted into the `JobCenter`; `FakeJobRunner` implements it (it already keeps `tasks` and can rebuild a handle over the same task and a fresh progress stream; document that only one consumer should read progress).
- `ToolServices` gains `public var accounts: [AccountProviderKind: any AccountProvider]` and `public var publishers: [PublishDestination: any Publisher]`, both `[:]` by default in `init` (new trailing parameters, so every existing call site compiles).

### 2.7 Fakes in `Sources/ContractsTestSupport`

| Fake | File | Behaviour |
|---|---|---|
| `FakeAccountProvider` (actor) | `Fakes/FakeAccountProvider.swift` | `init(configured: Bool = true, accounts: [ConnectedAccount] = [])`; `connect` returns the next of `scriptedAccounts` (default: `Fixtures.connectedGoogleAccount` with the requested scopes) or throws `failNextConnect`; records `connectCalls` with scopes and loginHint; `accessToken` returns `AccessToken(value: "fake-token-<n>", expiresAt: now + 3600 s, scopes:)`, increments `tokenRequests`, throws `reauthorizationRequired` when `setTokenStatus(.reauthorizationRequired, for:)` was called; `disconnect` removes and records `disconnected`; `refresh` bumps `refreshedAt`; `changes` over a `Broadcaster`, sent after every mutation |
| `FakeAuthorizationPresenter` | `Fakes/FakeAuthorizationPresenter.swift` | Records opened URLs; `mode`: `.completeCallback` (parses `redirect_uri` and `state` from the URL and performs `GET <redirect_uri>?state=<state>&code=fake-code-<n>` with a plain `URLSession` after 50 ms), `.deny` (`?error=access_denied&state=`), `.ignore` (never calls back, for timeout tests) |
| `FakePublisher` (actor) | `Fakes/FakePublisher.swift` | Records every request; `validate` throws `invalidRequest` for an empty title or `publishAt` with a non-private privacy and returns `["fake warning"]` when `warnOnValidate` is set; `quota` and `capabilities` are settable (`publicUploadsAllowed` default false); `publish` reports `verify`, `session` (emits `.session` with `totalBytes` = file size), `upload` in `uploadSteps` (default 5) steps each emitting `.session` with growing `bytesConfirmed`, `.uploaded(remoteId: "fake-video-<n>", remoteURL: https://youtu.be/fake-video-<n>)`, then `processing`, `thumbnail` if set, `captions` if any, `playlist` if set; `failAt: (PublishStage, Double)?` throws `.network("injected")` once at that point; a run with `resuming != nil` starts at `bytesConfirmed` and sets `resumedCount + 1`; `refuseHash` throws `hashMismatch` in `verify`; `forcePrivate` makes the receipt's `privacy` `.private` with the warning "Uploaded as private: project not audited" |
| `FakeYouTubeServer` (actor) + `FakeYouTubeURLProtocol` | `Fakes/FakeYouTubeServer.swift` | Section 2.8 |
| `FakeProjectStore` | existing file | Adopts `RenderLedger` and `PublishLedger` in memory with the rules of 2.3; `renders`/`publishes` newest first by `requestedAt` then id; ids from the store's generator when `id` is nil |
| `FakeRenderer` | existing file | `export` fills `ExportReceipt.outputHash` with `FileHash.sha256(of:)` of the file it wrote |
| `FakeJobRunner` | existing file | `handle(for:)` |
| `FakeApprovalGate` | existing file | Implements the 6-argument `check`, stores `presentation` on the request, uses `presentation?.summary ?? summary(tool, input)` as `inputSummary` |
| `Fixtures` | existing file | `connectedGoogleAccount` (`sub-1`, `me@example.com`, channel `UC-fake`, "Skeleton Channel", `@skeleton`), `publishRequest(renderId:fileURL:)` (title "Band rehearsal", private, one SRT caption track with two cues, no thumbnail), `publishReceipt(publishId:)`, `approvalRequest(tool: "publish_youtube")` with a presentation (Channel, Privacy, Certification rows) |
| `TestServices` | existing file | Gains `accounts: FakeAccountProvider`, `publisher: FakePublisher`, `authorizationPresenter: FakeAuthorizationPresenter`; `services` wires `accounts: [.google: accounts]`, `publishers: [.youtube: publisher]` |

### 2.8 `FakeYouTubeServer`: a `URLProtocol` fake of Google's endpoints

`ContractsTestSupport` may not import swift-nio, and an in-process `URLProtocol` is deterministic and sees every request `URLSession` makes, including `uploadTask(with:from:)` bodies (delivered through `httpBodyStream`, which the protocol drains). Design:

- `public actor FakeYouTubeServer` holds state: `accounts: [sub: (email, channel)]`, `refreshTokens: [token: sub]`, `accessTokens: [token: (sub, expiresAt)]`, `sessions: [uploadId: (metadata JSON, total, confirmed, videoId?)]`, `videos: [id: (snippet, status, privacy, processingPollsLeft)]`, `thumbnails`, `captions`, `playlistItems`, `requests: [RecordedRequest]` (method, path, query, selected headers, body byte count, `Content-Range`), quota counters, and a fault script.
- `public func sessionConfiguration() -> URLSessionConfiguration`: `.ephemeral` with `protocolClasses = [FakeYouTubeURLProtocol.self]` and `httpAdditionalHeaders = ["X-Fake-YouTube-Server": id]`; the protocol class finds the actor in a static registry by that header. `canInit` matches hosts `accounts.google.com`, `oauth2.googleapis.com`, `openidconnect.googleapis.com`, `www.googleapis.com` only, so PublishKit uses Google's real URLs.
- Endpoints (bodies shaped like Google's JSON; verified against a recorded live transcript once the live test has run, see 4.1): `POST /token` (`authorization_code`: requires `code_verifier`, `redirect_uri`, a code the fake issued; returns `access_token`, `expires_in`, `refresh_token`, `scope`, `id_token` = an unsigned JWT with `sub`, `email`; `refresh_token`: new access token, `400 invalid_grant` for a revoked token); `POST /revoke` (200, or 400 for unknown); `GET /youtube/v3/channels?mine=true` (one channel, or empty `items` for a sub flagged `noChannel`); `POST /upload/youtube/v3/videos?uploadType=resumable` (validates `X-Upload-Content-Length`, stores metadata, `200` with `Location`); `PUT <session>` with `Content-Range: bytes a-b/total` (rejects a chunk whose `a != confirmed`, non-final chunks not a multiple of 262,144, or a missing `Content-Length`; answers `308` with `Range: bytes=0-<confirmed-1>` or `201` with the video resource on completion; `privacyStatus` downgraded to `private` when `forcePrivate`); `PUT <session>` with `Content-Range: bytes */total` (status query: `308`+`Range`, `308` without `Range` when nothing is stored, `201` when complete, `404` when expired); `GET /youtube/v3/videos?part=status,processingDetails&id=` (`uploaded`/`processing` for `processingPollsUntilDone` polls, then `processed`, or `failed`/`rejected` when scripted); `POST /upload/youtube/v3/thumbnails/set` (200, or `403 forbidden` when `forbidThumbnail`); `POST /upload/youtube/v3/captions?uploadType=multipart` (parses the multipart, returns a caption id, `409` for a duplicate language+name); `POST /youtube/v3/playlistItems`; `DELETE /youtube/v3/videos` (204). Every request without a valid bearer answers `401` with Google's `invalid_token` body; every API request costs the documented units and `videos.insert` costs one upload; `quotaExceeded` when scripted answers `403` with the `quotaExceeded` reason.
- Faults (each a method on the actor, consumed once unless `times:` says otherwise): `dropConnection(afterBytes:)` (the protocol fails the request with `URLError.networkConnectionLost` after forwarding that many body bytes; the fake keeps the bytes it "received" rounded down to the chunk granularity), `respond(status: Int, times: Int)` on the next chunk `PUT`s, `quotaExceeded()`, `uploadLimitExceeded()`, `forbidThumbnail()`, `forcePrivate()`, `expireSession()`, `revokeRefreshToken(sub:)`, `expireAccessTokensNow()` (the next bearer answers `401` once), `retryAfter(seconds:)`.
- Seeding: `seedAccount(sub:email:channelId:channelTitle:handle:refreshToken:)` and `issueAuthorizationCode(for sub:) -> String` so a connect flow through the loopback listener can complete without a browser.

### 2.9 Tests that prove the contracts (`Tests/ContractsTests`)

- `AccountsTests.swift`: `accessTokenRedactsItself` (`"\(token)"` and `String(reflecting:)` contain no token value), `fakeProviderConnectsListsRefreshesAndDisconnects`, `fakeProviderReportsReauthorizationRequired`, `changesStreamYieldsAfterEveryMutation`.
- `PublishingTests.swift`: `publishRequestAndReceiptRoundTripThroughTheProjectCodec` (fixture JSON under `Fixtures/publish-request.json`, dates in the codec's ISO-8601 form), `publishSessionNeverAppearsInAReceipt` (encode a receipt, assert no `upload/youtube` substring), `fakePublisherProducesAReceiptThroughAJobRunner` (stages in order, `remoteId == "fake-video-1"`), `fakePublisherFailsOnceAndResumes` (`resumedCount == 1`, `bytesConfirmed` monotonic across the two runs), `fakePublisherRefusesAHashMismatch`, `fakePublisherForcesPrivateWithAWarning`, `captionCuesAreTimelineRelativeAndSorted` (on the `linked-transition-caption-undone` fixture), `fileHashMatchesMediaKitFormat` (`sha256-ba7816bf...` for "abc").
- `LedgerTests.swift`: `fakeStoreKeepsRenderAndPublishLedgersOutsideTheEvents` (version unchanged, no `ProjectChange`), `publishLedgerLinksToRenderAndRefusesUnknownRenders`, `terminalStatesSetCompletedAt`, `clearsSessionDropsTheUploadURL`.
- `ApprovalTests.swift` additions: `presentationRidesOnTheRequestAndTheOutput` (6-argument check on `FakeApprovalGate`; `ToolOutput.approvalRequired` has `details` and `warnings`), `fiveArgumentCheckStillForwards`, `standardPolicyGatesPublishYouTube`.
- `JobRunnerTests.swift` addition: `fakeRunnerFindsAHandleById`.
- `FakeYouTubeServerTests.swift`: the resumable protocol with a raw `URLSession` (session start, three 1 MiB chunks, `308 Range` after each, `201` at the end, status query answers), `dropConnectionKeepsGranularityAlignedBytes`, `statusQueryAfterExpiryIs404`, `tokenEndpointExchangesRefreshesAndRevokes`, `bearerlessRequestsAre401`, `quotaCountsUploadsAndUnits`.
- `UsageExampleTests.swift` addition: `accountProviderAndPublisherThroughTheExistentials`.

Definition of done: `swift test --filter ContractsTests` green with these added; `make test` green (378 + new tests); zero warnings; `ApprovalPolicy.standard` documented in the doc comment.

## 3. Package.swift, Makefile, conventions (the lead, one commit, right after Contracts)

`Package.swift`:

```swift
// products
.library(name: "PublishKit", targets: ["PublishKit"]),

// targets, after AudioAlign
.target(
    name: "PublishKit",
    dependencies: [
        "TimelineCore", "Contracts",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
    ],
    swiftSettings: strict,
    linkerSettings: [.linkedFramework("Security"), .linkedFramework("CryptoKit")]),
.testTarget(
    name: "PublishKitTests",
    dependencies: ["PublishKit", "ContractsTestSupport"],
    resources: [.copy("Transcripts")],
    swiftSettings: strict),

// TimelineApp dependencies: add "PublishKit"
```

The commit also adds `Sources/PublishKit/PublishKit.swift` (module doc comment only) and `Tests/PublishKitTests/PublishKitTests.swift` (one `@Test` that imports the module) plus an empty `Tests/PublishKitTests/Transcripts/README.md`, so `make test` passes before the PublishKit agent starts.

`Makefile`: `TEST_TARGETS` gains `PublishKitTests` after `AgentKitTests` (targets run one at a time, per integration.md).

`docs/design/conventions.md` table: `Contracts` row gains CryptoKit; a `PublishKit` row: library, may import `TimelineCore`, `Contracts`, swift-nio, Security, CryptoKit; never AppKit (the browser opener is injected).

`.gitignore`: `google-oauth-client*.json`, `google-tokens.json`, `accounts.json`, `client_secret_*.json`.

## 4. Work packages (parallel, after sections 2 and 3 have merged)

Each package: one agent, one worktree, branch `module/<name>`, commits to its own directories only. `swift test --filter <Target>Tests` must pass in isolation; `make test` before the merge request; zero Swift 6 warnings.

### 4.1 PublishKit

Owner: PublishKit agent. Files: `Sources/PublishKit/**`, `Tests/PublishKitTests/**`. Must not touch: `Contracts`, `ContractsTestSupport`, `Package.swift`, any sibling module, `TimelineApp`.

```
Sources/PublishKit/
  PublishKit.swift                          module doc; base64url, ISO date helpers, `PublishKitError`
  Google/GoogleClientConfiguration.swift    D3 lookup order; `clientId`, `clientSecret?`, `audited: Bool`; `load(environment:fileManager:)`
  Google/PKCE.swift                         `PKCE.make()` -> (verifier 43 chars base64url of 32 random bytes, S256 challenge, state 16 bytes)
  Google/LoopbackRedirectListener.swift     swift-nio: bind 127.0.0.1:0, one `GET /callback`, verify `state`, capture `code` or `error`, answer a static "You can close this window" HTML page, close; 5-minute timeout -> `AccountError.cancelled`
  Google/GoogleOAuthClient.swift            authorization URL (parameters exactly as 10 "Exact HTTP sequence": `access_type=offline`, `prompt=consent`, optional `login_hint`), code exchange, refresh, revoke; `URLSession` injected; decodes the `id_token` payload (no signature check: received directly from Google over TLS, 10 §Exact HTTP sequence step 2)
  Google/TokenStore.swift                   `StoredCredential { refreshToken, scopes, clientId, grantedAt, accountId }`; `protocol TokenStore { load(accountId:), save(_:), delete(accountId:), list() }`; `KeychainTokenStore` (D4); `FileTokenStore(url:)` (0600, atomic write, refuses a world-readable existing file); `TokenStoreSelection.resolve(environment:bundleURL:root:)`
  Google/AccountsFile.swift                 `accounts.json` read/write of `[ConnectedAccount]` (D14)
  Google/GoogleAccountProvider.swift        `AccountProvider`: connect (PKCE -> listener -> presenter.open -> code -> exchange -> id_token sub/email -> channels.list -> persist credential + record -> changes), disconnect (D13), refresh, accessToken (in-memory cache per account, refresh when within `minimumLifetime`, `invalid_grant` -> mark `reauthorizationRequired`, persist, throw)
  YouTube/YouTubeAPI.swift                  request builders and decoders: videos.insert (resumable start), videos.list, channels.list, thumbnails.set, captions.insert (multipart/related), playlistItems.insert, videos.delete; Google error JSON -> `PublishError`
  YouTube/ResumableUpload.swift             D5 state machine over an injected `URLSession`; `UploadOptions { chunkBytes = 32 << 20, maxAttempts = 10, requestTimeout = 120 }`; progress and `PublishEvent.session` per confirmed chunk
  YouTube/YouTubeValidation.swift           the rules of 11 §3 as pure functions returning `[String]` warnings or throwing `invalidRequest`: title 1-100 chars without < or >, description <= 5,000 bytes, tags <= 500 chars counting commas and quoted spaces, `publishAt` only with private, category id string, caption name <= 150, thumbnail file <= 2 MB and JPEG/PNG, Shorts shape warnings (D8), "longer than 15 minutes needs a phone-verified channel" warning
  YouTube/QuotaMeter.swift                  D11; JSON at `<cacheDir>/publish-quota.json`; Pacific-day bucketing via `TimeZone(identifier: "America/Los_Angeles")`
  YouTube/YouTubePublisher.swift            `Publisher`: validate, estimate (size / measured rate, first run assumes 5 MB/s), quota, capabilities (from configuration.audited), publish job, remoteStatus; job stages: verify (FileHash == expectedContentHash) -> session -> upload -> uploaded event -> processing poll (15 s doubling to 60 s, at most 20 polls, then finish with a "still processing" warning) -> thumbnail -> captions (one insert per track; 409 -> warning) -> playlist; each optional step's failure is a warning, never a job failure (11 Recommendation 6); `ProcessInfo.beginActivity` for the job's life; cancellation at chunk boundaries records the session
  Captions/SRTWriter.swift, VTTWriter.swift  cues -> text; SRT `HH:MM:SS,mmm`, VTT `HH:MM:SS.mmm` with the `WEBVTT` header; cues clamped so `end > start`, overlapping cues nudged by one millisecond
Tests/PublishKitTests/
  PKCETests, LoopbackListenerTests, OAuthClientTests, TokenStoreTests, AccountProviderTests,
  CaptionWriterTests, ValidationTests, QuotaMeterTests, ResumableUploadTests, PublisherTests, LiveYouTubeTests
  Transcripts/                               scrubbed request/response pairs recorded by the live test (`TIMELINE_LIVE_TRANSCRIPT_OUT`), replayed to check the fake's bodies match Google's
```

Test media: PublishKit tests never use `TestMedia` or AVFoundation (the CoreMedia stall in integration.md); upload bodies are files of random bytes (`FileHandle` writes, 5 MiB in 1 MiB chunks for the resume tests, 300 KiB for the small ones). Every network test hands `FakeYouTubeServer.sessionConfiguration()` to the code under test; the loopback listener tests use a plain `URLSession` against the real port.

Definition of done (test names):

- `PKCETests`: `verifierIs43UnreservedCharacters`, `challengeMatchesRFC7636Vector` (the RFC's `dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk` example), `stateIsUniquePerAttempt`.
- `LoopbackListenerTests`: `answersOneCallbackAndClosesItsPort` (a second GET is refused), `rejectsAWrongState`, `reportsAccessDenied`, `timesOutAsCancelled`, `bindsToLoopbackOnly` (`0.0.0.0` never appears; the bound address is `127.0.0.1`).
- `OAuthClientTests`: `authorizationURLCarriesEveryDocumentedParameter`, `exchangesACodeWithTheVerifier`, `refreshesAndKeepsTheRefreshToken`, `invalidGrantIsReauthorizationRequired`, `revokeTreats200And400AsSuccess`, `decodesSubAndEmailFromTheIdToken`, `clientSecretIsSentOnlyWhenConfigured`.
- `TokenStoreTests`: `fileStoreWritesMode0600AndRoundTrips`, `fileStoreRefusesAWorldReadableFile`, `selectionPrefersTheEnvironmentThenTheBundle`, `keychainStoreRoundTrips` (`.enabled(if: TIMELINE_KEYCHAIN_TESTS == "1")`).
- `AccountProviderTests`: `connectThroughTheListenerAndTheFakeServerYieldsAConnectedAccount` (`FakeAuthorizationPresenter.completeCallback`, `FakeYouTubeServer.issueAuthorizationCode`), `connectRefusesWhenARequiredScopeWasUntickedAndRevokesTheGrant`, `noChannelIsReported`, `accessTokenRefreshesWithinMinimumLifetime`, `refreshFailureMarksReauthorizationRequiredAndPersists`, `disconnectRevokesDeletesAndBroadcasts`, `unconfiguredProviderIsNotConfiguredAndConnectThrowsNotConfigured`, `recordsOlderThan30DaysAreRefreshedOnLoad`, `accountsFileHoldsNoSecrets` (grep the JSON for the refresh token).
- `CaptionWriterTests`: `srtFormatsTimingsAndNumbering`, `vttHasHeaderAndDotMilliseconds`, `overlappingCuesAreNudged`, `emptyTracksProduceAnEmptyBody`.
- `ValidationTests`: one test per rule in `YouTubeValidation` (`titleLength`, `angleBrackets`, `descriptionBytes` with emoji, `tagsWithSpacesCountQuotes`, `publishAtRequiresPrivate`, `portraitOverThreeMinutesWarns`, `portraitUnderThreeMinutesIsAShortWarning`, `thumbnailOver2MBRejected`, `longUploadWarnsAboutVerification`).
- `QuotaMeterTests`: `countsUploadsAndUnitsPerPacificDay`, `resetsAtMidnightPacific`, `refusesTheHundredAndFirstUpload`, `quotaExceededMarksTheDayExhausted`, `survivesAMissingFile`.
- `ResumableUploadTests`: `uploads5MiBIn1MiBChunksWith308RangeDrivingTheOffset`, `resumesAfterADroppedConnectionWithoutResendingConfirmedBytes` (the fake recorded exactly one status query and no overlapping ranges), `resumesFromAPersistedSessionAfterASimulatedRelaunch` (new publisher instance, `resuming:`), `retriesOn503WithBackoffAndGivesUpAfterTenAttempts`, `honoursRetryAfter`, `refreshesA401MidUploadAndResendsTheSameChunk`, `quotaExceededFailsWithResetTime`, `uploadLimitExceededFails`, `expiredSessionOpensANewOneOnce`, `cancellationStopsAtAChunkBoundaryAndReportsTheSession`, `chunkSizeMustBeAMultipleOf256KiB`, `progressFractionIsBytesConfirmedOverTotal`, `memoryStaysUnderTwoChunks` (measure `mach_task_basic_info` resident delta on a 64 MiB file with 8 MiB chunks: under 32 MiB).
- `PublisherTests`: `wholeJobProducesAReceiptWithResumedCountOne` (through `FakeJobRunner`, with `dropConnection` at 40%), `verifyRefusesAModifiedFile`, `receiptReportsTheApiPrivacyAndWarnsWhenForcedPrivate`, `thumbnailForbiddenIsAWarningNotAFailure`, `captionsAreInsertedPerTrackAsSRT` (the fake's captured multipart body parses as SRT with the fixture cues), `duplicateCaptionIs409Warning`, `playlistInsertIsOptional`, `processingRejectionFailsTheJobWithTheReason`, `madeForKidsNilOmitsTheField` (the fake's stored metadata lacks `selfDeclaredMadeForKids`), `containsSyntheticMediaIsSent`, `notifySubscribersIsAQueryParameter`, `onEventSequenceIsSessionUploadedStages`, `noOutputContainsTheUploadURL`, `estimateUsesTheMeasuredRate`, `capabilitiesFollowTheAuditedFlag`, `remoteStatusDecodesUploadAndProcessingState`.
- `LiveYouTubeTests` (`.enabled(if: TIMELINE_LIVE_YOUTUBE == "1")`, `.timeLimit(.minutes(10))`): needs the client configuration (D3) and a connected account through `TIMELINE_TOKEN_STORE=file` (connect once through the app or through a small `--connect-google` path the App agent adds, section 4.5), uploads a 2 s clip generated with `TestMedia.videoWithAudio` (the one place PublishKit tests touch AVFoundation, and only when enabled) as `private`, title `timeline-live-test <ISO date>`, with one SRT caption track and `notifySubscribers=false`, polls until `processed`, sets a thumbnail tolerating `forbidden`, then `videos.delete`s it; writes the scrubbed exchange to `TIMELINE_LIVE_TRANSCRIPT_OUT` (tokens, emails, ids replaced) for `Transcripts/`. Cost: one upload call plus about 105 units. Never in `make test`.

### 4.2 ProjectStore

Owner: ProjectStore agent. Files: `Sources/ProjectStore/Schema.swift`, `QueryRows.swift`, `SQLiteProjectStore.swift`, `Tests/ProjectStoreTests/**`. Must not touch anything else.

Migration `v2` in `Schema.migrator` (`registerMigration("v2")`), `Schema.currentUserVersion = 2`:

```sql
CREATE TABLE publishes (                        -- operational, not part of the event stream
  publish_id      TEXT PRIMARY KEY,
  render_id       TEXT NOT NULL REFERENCES renders(render_id),
  destination     TEXT NOT NULL CHECK (destination IN ('youtube')),
  account_id      TEXT NOT NULL,                -- provider subject; the account record lives outside the project
  requested_at    TEXT NOT NULL,
  completed_at    TEXT,
  status          TEXT NOT NULL CHECK (status IN ('queued','uploading','processing','done','failed','cancelled')),
  request         TEXT NOT NULL,                -- JSON PublishRequest (no secrets by construction)
  session         TEXT,                         -- JSON PublishSession: upload URI + bytes confirmed, for resume
  bytes_total     INTEGER,
  bytes_sent      INTEGER,
  remote_id       TEXT,
  remote_url      TEXT,
  project_version INTEGER NOT NULL,             -- copied from the render row at request time
  receipt         TEXT,                         -- JSON PublishReceipt
  error           TEXT
) STRICT;
CREATE INDEX publishes_render_idx ON publishes(render_id, requested_at);
CREATE INDEX publishes_active_idx ON publishes(status) WHERE status IN ('queued','uploading','processing');
PRAGMA user_version = 2;
```

Code: `PublishRow` in `QueryRows.swift` mirroring `RenderRow` (snake-case keys, `FetchableRecord`, `PersistableRecord`); `SQLiteProjectStore` adopts `RenderLedger` (mapping `RenderRow` to `RenderRecord`: `output_path` stored absolute, `preset` and `receipt` through `ProjectCodec`) and `PublishLedger` (`recordPublish`, `updatePublish` applying a `PublishUpdate` inside one `writer.write`, `publishes()`, `publish(_:)`, `publishes(forRender:)`); the existing `recordRender`/`updateRender`/`renders()`/`render(_:)` keep their signatures. `rebuildProjections` does not touch `renders` or `publishes` (`Schema.queryTablesInDeleteOrder` unchanged). `saveAs` and `backup` copy them with the database (`VACUUM INTO`), which is correct: a fork's history shows the parent's uploads. `Recovery.migrate` already backs up a v1 file before a pending migration (`hasCompletedMigrations` is false for a v1 database once v2 is registered), which is the storage.md section 12 rule; assert it.

Tests (`Tests/ProjectStoreTests/PublishesTests.swift`, `arguments: Backend.allCases` where applicable): `publishesTableHoldsRowsOutsideTheEvents` (record, update through every status, `completedAt` on terminal states, version unchanged, no `ProjectChange`), `publishRowsLinkToRendersAndRefuseUnknownRenders` (`SQLITE_CONSTRAINT_FOREIGNKEY` surfaces as `ProjectStoreError`), `publishesForRenderAreNewestFirst`, `clearsSessionRemovesTheCapabilityURL`, `renderLedgerConformanceThroughTheExistential` (`store as? any RenderLedger`), `publishLedgerConformanceThroughTheExistential`, `v1DatabaseMigratesToV2WithABackup` (build a database with a private `DatabaseMigrator` that registers only `"v1"` using `Schema.v1`, insert a render, close, open with `SQLiteProjectStoreOpener`: `user_version == 2`, the render row survives, a `project.sqlite.pre-migration-*.bak` exists), `saveAsCarriesPublishes`, `rebuildLeavesPublishesAlone`, `receiptJSONNeverContainsTheUploadURL`. Existing `PackageAndRendersTests` stay as they are.

### 4.3 AgentKit

Owner: AgentKit agent. Files: `Sources/AgentKit/Tools/RenderTools.swift`, new `Sources/AgentKit/Tools/PublishTools.swift`, `Sources/AgentKit/Tools/EditorTools.swift`, `Sources/AgentKit/MCPServerHost.swift` (only `RecordingApprovalGate`'s 6-argument `check`), `Sources/AgentKit/Skills/publish-to-youtube/SKILL.md`, `Tests/AgentKitTests/**`. Must not touch: `Contracts`, other modules, `TimelineApp`.

**`render_export` changes.** Resolve `store as? any RenderLedger` (nil: proceed and add the warning "store keeps no render ledger; no renderId"); after the approval check and before submit, `recordRender(id: nil, sequenceId:, preset:, projectVersion: project.version)`; `updateRender(.running)` right after `submit`; after `wait()`: `outputHash = FileHash.sha256(of: outputURL)`, `receipt.outputHash = outputHash`, `receipt.projectVersion = version`, `updateRender(.done, outputURL:, outputHash:, receipt:)`; `.failed` with the error's description on `RenderError`/`JobError`, `.cancelled` on `CancellationError`. Output gains `renderId` and `outputHash`; `outputSchema` lists them. Default output path becomes `(context.services.mediaLibrary?.layout ?? .default).exportsDir.appendingPathComponent("<sequence>-<preset>.<ext>")`, which fixes the `TIMELINE_ROOT` issue in integration.md; the schema description says "default: <library root>/Exports/...".

**`publish_youtube`** (`annotations: title "Publish to YouTube", openWorld: true, destructive: false, idempotent: false`; `requiredService`: `publishers[.youtube] != nil && accounts[.google] != nil && jobRunner != nil`). Input schema (outline; `additionalProperties: false`, every property described, `$defs.time` from `OperationSchemas`):

```json
{ "type": "object", "required": ["title"], "properties": {
  "projectId":      { "type": "string" },
  "renderId":       { "type": "string", "description": "A done render from render_export (default: the newest done render of the active sequence)." },
  "publishId":      { "type": "string", "description": "Idempotency key. Reuse the value from an approval_required answer; a retry with an id that already has a publish returns its status instead of uploading again; a failed or cancelled publish with this id is resumed." },
  "accountId":      { "type": "string", "description": "Connected Google account id from account_status (default: the only connected account)." },
  "title":          { "type": "string", "minLength": 1, "maxLength": 100 },
  "description":    { "type": "string", "maxLength": 5000 },
  "tags":           { "type": "array", "items": { "type": "string" } },
  "categoryId":     { "type": "string", "description": "YouTube category id, e.g. 22 People & Blogs (default), 10 Music, 27 Education." },
  "privacy":        { "type": "string", "enum": ["private", "unlisted", "public"], "default": "private",
                      "description": "Never public unless the user asked for it in so many words. Uploads from an unaudited project are private regardless." },
  "publishAt":      { "type": "string", "format": "date-time", "description": "Schedule; requires privacy private." },
  "containsSyntheticMedia": { "type": "boolean", "default": false, "description": "YouTube's altered-or-synthetic disclosure. Propose true only for realistic generated or altered content; the human confirms on the card." },
  "thumbnailAt":    { "$ref": "#/$defs/time", "description": "Timeline time of the frame to use as the thumbnail (rendered at 1280x720 JPEG)." },
  "captionTrackIds": { "type": "array", "items": { "type": "string" }, "description": "Caption tracks of the sequence to upload as subtitle tracks (SRT)." },
  "notifySubscribers": { "type": "boolean", "default": false },
  "waitSeconds":    { "type": "integer", "minimum": 0, "maximum": 600, "default": 120, "description": "How long to wait before answering with status uploading or processing; poll publish_status after." },
  "approvalToken":  { "type": "string" } } }
```

There is no `madeForKids` property (D9). Handler, in order:

1. Services: publisher, account provider, job runner, renderer (thumbnail), else `serviceUnavailable`.
2. `resolve` the project; `ledger = store as? (any RenderLedger & any PublishLedger)` (two casts), else `serviceUnavailable("render ledger")`.
3. `accountId`: input, else the single connected account, else `.error(code: "notConnected", message: "Connect a Google account in Settings")`; an account whose `tokenStatus` is `reauthorizationRequired` answers `reauthorizationRequired` with the same hint.
4. `publishId`: input or a fresh UUIDv7. An existing row: `queued|uploading|processing|done` returns the status output of step 12 without touching the gate; `failed|cancelled` continues with `resuming = row.session` and the row's request (D10).
5. `renderId`: input, else the newest `done` render of the sequence; the row must be `done` with an existing file, else `.error(code: "renderNotFound" | "renderNotDone" | "fileMissing", hint: "run render_export first")`.
6. Build the `PublishRequest`: title, description (default ""), tags, categoryId (default "22"), privacy (default private), publishAt (with a non-private privacy: `invalidRequest`), `madeForKids: nil`, `containsSyntheticMedia`, `notifySubscribers`, captions from `captionTrackIds` via `CaptionCues.make` (unknown id or a non-caption track: `notFound`; language from the track or "en"; name = track name; format `.srt`), thumbnail from `thumbnailAt` via `renderer.compile(sequence, options: .gesture)` + `frame(at:size: 1280x720)` written as JPEG (quality 0.85, `CGImageDestination`, `ToolImages.jpeg` added to `Images.swift`) to `<layout.cacheDir>/publish/<publishId>-thumbnail.jpg`, `expectedContentHash = render.outputHash`, `projectVersion = render.projectVersion`, `durationSeconds`/`width`/`height` from the render receipt and preset.
7. `publisher.validate(request)` (throws `invalidRequest` -> `.error(code: "invalidRequest")`; warnings kept for the output and the card).
8. Quota: `publisher.quota()`; `uploadsRemaining == 0` -> `.error(code: "quotaExceeded", details: resetsAt)`.
9. Presentation: summary `Publish "<title>" to YouTube as <Privacy>`; details in this order: Channel (`<channelTitle> (<handle>)`), Account (email), Privacy, Scheduled (when set), File (`<name>, <size>`), Render (`<preset name>, project v<n>`), Thumbnail (`frame at <t> s` | none), Captions (`<n> track(s): en, de` | none), AI disclosure (`declared` | `not declared`), Made for kids (`not declared: set the audience in YouTube Studio after upload`), Certification (the ToS 9.1 sentence, D12); warnings: `privacy != private` (`"Privacy: <value>"`), `!capabilities.publicUploadsAllowed && privacy != private` (the forced-private notice), validation warnings. Estimate from `publisher.estimate`.
10. `context.checkApproval(tool:input:estimate:presentation:)`; `.required` -> `ToolOutput.approvalRequired(request)` with `publishId` added to the structured output (`text` says to retry with the token and the same `publishId`).
11. `recordPublish(id: publishId, request:, projectVersion:)` (or `updatePublish(.queued)` on a resume), `submit(publisher.publish(request, publishId:, resuming:, onEvent:))`; `onEvent` maps `.session` -> `updatePublish(status: .uploading, session:, bytesSent:)`, `.uploaded` -> `updatePublish(status: .processing, remoteId:, remoteURL:)`, `.stage` -> nothing persisted. A detached watcher `Task` awaits `handle.wait()` and writes the terminal row (`done` with receipt and `clearsSession: true`; `failed` with the error and the session kept; `cancelled`), so the ledger is completed even after the tool has answered. `QuotaMeter` bookkeeping lives inside the publisher.
12. Wait up to `waitSeconds` for the watcher; answer from the ledger row: `status` (`done | uploading | processing | failed`), `publishId`, `jobId`, `renderId`, `remoteId`, `url`, `studioUrl`, `privacy` (reported), `requestedPrivacy`, `channelTitle`, `bytesUploaded`, `bytesTotal`, `resumedCount`, `receipt` (when done), `warnings` (validation warnings, "uploaded as private" when the privacy differs, the made-for-kids notice), `projectId`. `text`: "Published <title> to YouTube as private: <url>" or "Uploading <title>: 41% (poll publish_status)".

Examples: `{"title": "Band rehearsal, 8 Sept"}` and `{"renderId": "r-1", "publishId": "p-1", "title": "Reel", "privacy": "unlisted", "captionTrackIds": ["cap-1"], "thumbnailAt": {"v": 48048, "ts": 24000}, "approvalToken": "tok-1"}`.

**`publish_status`** (read-only, `.never`): input `projectId`, optional `publishId`, optional `limit` (default 10); output `publishes: [{ publishId, renderId, status, requestedPrivacy, privacy, title, url, remoteId, bytesSent, bytesTotal, resumedCount, error, projectVersion, requestedAt, completedAt }]` newest first (or the one asked for; unknown id -> `notFound`), `quota` (`PublishQuota`), `capabilities`, `projectId`. Never `session`.

**`account_status`** (read-only, `.never`; `requiredService`: `accounts` non-empty; takes no `projectId`, so `SchemaContractTests` adds it to the `projectId` exception list next to `project_list`): output `configured: Bool`, `accounts: [{ id, provider, email, displayName, channelId, channelTitle, channelHandle, tokenStatus: "valid"|"expired"|"reauthorizationRequired", scopes, connectedAt }]`, `requiredScopes`, `hint` ("Connect a Google account in Settings" when empty, "Reconnect: the grant expired" for `reauthorizationRequired`).

`EditorTools.all` lists the three after `render_export`; `requiredService` entries as above; `RecordingApprovalGate` implements the 6-argument `check` and stores the presentation so the hook path's card shows details.

**Skill** `Sources/AgentKit/Skills/publish-to-youtube/SKILL.md` (`allowed-tools: mcp__timeline__*`): use when the user says "upload", "publish", "post to YouTube". Procedure: `account_status` (no account: stop and tell the user to connect one in Settings; `reauthorizationRequired`: ask them to reconnect); `project_describe` with `level: "tracks"` for the sequence, its caption tracks, and a title suggestion (project name, or the first caption); `render_export` (approval; keep `renderId`); `publish_youtube` with `privacy: "private"` unless the user asked for unlisted or public in so many words, `captionTrackIds` when a caption track exists, `thumbnailAt` at a frame the user liked (`render_preview` to pick one), `containsSyntheticMedia: true` only for generated or altered realistic content, a fresh `publishId`; on `approval_required` wait and retry with the token and the same `publishId`; on `uploading`/`processing` poll `publish_status` every 30 s; report the URL, the privacy YouTube reported, the project version published, and remind the user to set the audience (made for kids) in YouTube Studio; never retry with a new `publishId` after a timeout; never set privacy public on your own.

Tests: `Tests/AgentKitTests/PublishToolTests.swift`: `renderExportRecordsARenderRowWithHashAndReturnsRenderId`, `renderExportMarksFailedRenders`, `renderExportDefaultsToTheLibraryRootExports` (a `FakeMediaLibrary` layout under a temp root), `publishYouTubeIsHiddenWithoutAPublisherOrAccount`, `publishYouTubeReturnsApprovalRequiredWithChannelPrivacyAndCertification` (details labels in order; `publishId` present; `warnings` empty for private), `publishYouTubeWarnsAboutPublicAndForcedPrivate`, `publishYouTubeRetriesWithTheTokenAndPublishes` (through `FakePublisher`; ledger row `done`, receipt, `session` cleared), `publishYouTubeIsIdempotentByPublishId` (second call with the same id returns `done` without a second `FakePublisher.publish`), `publishYouTubeResumesAFailedPublish` (`failAt` upload 0.4, second call with the same id: `resumedCount == 1`), `publishYouTubeAnswersUploadingAfterWaitSecondsAndPublishStatusFinishesIt` (`waitSeconds: 0`, then `publish_status` after `runner.drain()`), `publishYouTubeRejectsPublishAtWithUnlisted`, `publishYouTubeRefusesWhenQuotaIsSpent`, `publishYouTubeNeverSendsMadeForKids` (the recorded request's `madeForKids == nil`), `publishYouTubeBuildsCaptionsFromTheCaptionTrack` (`linked-transition-caption-undone` fixture: cue count and timeline times), `publishYouTubeWritesAThumbnailFromTheFrame` (a JPEG under 2 MB exists), `publishYouTubeRefusesARenderThatIsNotDone`, `publishStatusListsNewestFirstAndNeverTheSession` (output JSON contains no `upload/youtube`), `accountStatusReportsConfiguredAccountsAndHints`, `outputsContainNoToken` (grep every structured output for `fake-token`). `SchemaContractTests.everyToolHasAStrictSchemaAndValidExamples`: count 18, exception list. `SkillsInstallerTests`: the new skill is installed. `MCPServerHostTests`: `approvalRoundTripThroughTheHook` also asserts the request carries a presentation when the tool supplied one (a test tool registered with a presentation).

### 4.4 TimelineUI

Owner: TimelineUI agent. Files: `Sources/TimelineUI/AccountView.swift` (new), `PublishSheet.swift` (new), `PublishViews.swift` (new), `ApprovalViews.swift`, `JobViews.swift`, `Tests/TimelineUITests/**`. Must not touch: `Contracts`, other modules, `TimelineApp`. Everything over `any AccountProvider`, `any Publisher`, `any RenderLedger`, `any PublishLedger`, tested with the fakes and `ImageRenderer` like `PanelTests`.

- `AccountsModel` (`@MainActor @Observable`, over `any AccountProvider`): `accounts`, `isConnecting`, `error`, `connect()` (calls `connect(scopes: publisherScopes, loginHint:)`, shows "Waiting for the browser..." while pending), `reconnect(id)` (same with `loginHint = email`), `disconnect(id)`, follows `changes`. `AccountView(model:)`: unconfigured state ("Add a Google OAuth client to enable publishing" with the D3 paths); empty state with a neutral "Connect YouTube..." button (no Google "G", no "Sign in with Google" wording, 10 §7) and the consent sentence of D12; connected rows with avatar (`AsyncImage`), channel title, `@handle`, email in secondary type, token status, Disconnect, "Manage access" link; `reauthorizationRequired` shows "Reconnect"; notices: "This app is not verified by Google yet; the consent screen shows a warning" and "While the Google Cloud project is in Testing, the connection expires after 7 days" (10 §4), both driven by a `notices: [String]` the app passes (the UI does not know the project status).
- `PublishDraft` (public, `Codable`): `publishId` (minted once per sheet presentation), `renderId`, `accountId`, `title`, `description`, `tags`, `categoryId`, `privacy`, `publishAt`, `madeForKids: Bool` (explicit, default false, required toggle with the COPPA explanation), `containsSyntheticMedia`, `thumbnailAt: RationalTime?`, `captionTrackIds`, `notifySubscribers`. `PublishSheetModel(renders: any RenderLedger, publisher: any Publisher, accounts: [ConnectedAccount], sequence: Sequence, projectName:, playhead:)`: loads renders newest first (empty: "Export first" hint), defaults (title = project name, privacy private, captions = every caption track, thumbnail = playhead), `publishAt` enabled only for private, live `validate` warnings (debounced 300 ms), `capabilities` for the forced-private notice under the privacy control, `quota` for "N uploads left today", the Shorts warning from `validate`, the summary line "Upload <size> to <channel> as <privacy>". `PublishSheetView(model:, onUpload: (PublishDraft) async -> Void, onCancel:)`: fields as above with a static US assignable category list (11 §3) as the picker, the ToS 9.1 sentence under the Upload button (D12), the thumbnail preview from a `Renderer.frame` grab the app supplies as a `CGImage?` binding.
- `PublishOutcomeView(outcome: JobOutcome)`: decodes `PublishReceipt`, shows "View on YouTube" (`Link` to `remoteURL`), "Open in Studio", privacy reported and the warnings. `JobProgressView`: for `kind == .publish`, running rows show the stage and ETA (already generic) and finished rows embed `PublishOutcomeView`. `PublishHistoryView(ledger: any PublishLedger, onResume: (String) -> Void)`: rows with status, privacy, channel, link, and Resume for `failed`/`cancelled` rows with a session.
- `ApprovalCardView`: renders `request.presentation?.summary ?? request.inputSummary`, a label/value grid for `details`, and `warnings` in `.orange`; the Approve button is labelled "Upload" when `request.tool == "publish_youtube"` (the click that certifies).

Tests: `Tests/TimelineUITests/PublishTests.swift`: `accountViewShowsSetupWhenUnconfigured`, `accountViewConnectsAndShowsConnectedAs` (through `FakeAccountProvider`), `accountViewOffersReconnectWhenReauthorizationIsRequired`, `accountViewDisconnectCallsTheProvider`, `sheetDefaultsToPrivateAndMintsOnePublishId`, `sheetDisablesScheduleUnlessPrivate`, `sheetSelectsTheNewestDoneRenderAndEveryCaptionTrack`, `sheetShowsValidationWarningsFromThePublisher`, `sheetShowsTheForcedPrivateNoticeWhenPublicUploadsAreNotAllowed`, `sheetShowsUploadsRemaining`, `draftCarriesMadeForKidsExplicitly`, `outcomeViewLinksToYouTube`, `historyOffersResumeOnlyForResumableRows`, `approvalCardRendersDetailsAndWarnings`, `approvalCardFallsBackToInputSummary`; each view renders through `ImageRenderer` (non-nil `cgImage`).

### 4.5 TimelineApp (integration owner, after 4.1 to 4.4 have merged)

Owner: the App agent. Files: `Sources/TimelineApp/**`, `docs/design/integration.md`, `docs/design/publish-setup.md` (new), `docs/design/contracts-notes.md` (a short "publishing" section). Must not touch module sources except to record a needed fix in contracts-notes.md and hand it to the module's owner.

- `AppServices`: `PublishingMode { auto, fake, off }` (default `.auto`: load `GoogleClientConfiguration`; missing -> `accounts`/`publisher` nil, log "Publishing disabled: no Google OAuth client (see docs/design/publish-setup.md)"; `.fake`: the real `GoogleAccountProvider` over a `FileTokenStore` in the temporary root and the real `YouTubePublisher` over `FakeYouTubeServer.sessionConfiguration()`, one seeded account connected through the real loopback listener with `FakeAuthorizationPresenter.completeCallback`). `WorkspaceAuthorizationPresenter` (`NSWorkspace.shared.open`). Token store by `TokenStoreSelection`. `ToolServices` gains `accounts` and `publishers`. `StandardApprovalGate` implements the 6-argument `check` and stores the presentation. `ToolLoopSession.request(from:)` decodes `details` and `warnings` into a presentation so the fallback loop's card matches the MCP path. `DemoAgentScript.events(exportPath:publish:)` adds a `publish_youtube` call after the export when `publish` is true (the skeleton check only).
- A `--connect-google` command-line path (`TimelineApp --connect-google`) that runs the connect flow headlessly with the file token store and prints the connected channel, for the live test and for anyone without the window.
- Views: toolbar "Publish" button (SF `arrow.up.circle`, YouTube branding only on the share control per policy III.F.2) opening `PublishSheetView`; `PublishConsole` (`@MainActor @Observable`) turns a `PublishDraft` into `publish_youtube` input and calls it through `ToolConsole` (so the approval card is the confirmation; no second dialog), then finds the job with `jobRunner.handle(for: jobId)` and `JobCenter.track`s it; `PublishHistoryView` in the sidebar under the job list with Resume calling the same tool with the row's `publishId`; a `Settings` scene (`Settings { AccountView(model:) }`) with the notices of 4.4 (both on, until the audit and verification questions in section 6 are answered).
- `SkeletonCheck`: boot with `publishing: .fake`; a new step `publish` after `agent` and before `undo/redo`, expected line:

```
ok   publish: render r-… recorded (h264_1080p, v18, sha256-…); publish_youtube -> approval_required (Channel: Skeleton Channel, Privacy: private, Certification present);
     approved; 5 MiB in 1 MiB chunks, dropped at 40%, resumed once; done, fake-video-1 https://youtu.be/fake-video-1; row done after reopen; publish_status over MCP lists it; account_status shows @skeleton
```

  Steps: `tools.call("render_export", preset h264_1080p, outputPath under the root)` with a helper task approving the next `ApprovalCenter` request; assert the render row (`store as? any RenderLedger`) is `done` with `outputHash == FileHash.sha256(of: file)`; `FakeYouTubeServer.dropConnection(afterBytes: 2 MiB)`; `publish_youtube` with `waitSeconds: 60`, `captionTrackIds` empty (the skeleton has no caption track), through `ToolConsole` with `UploadOptions.chunkBytes = 1 MiB` (a `PublishingMode.fake` option); assert the `approval_required` output's details include Channel, Privacy, Certification; assert the answer is `done` with `resumedCount == 1`, `remoteId == "fake-video-1"`, `privacy == "private"`; assert the fake recorded one status query and no overlapping ranges; after `close` and reopen assert `publish(_:)` returns the `done` row with no session; `publish_status` over the MCP probe returns the row and the JSON contains no `upload/youtube`; `account_status` lists the seeded account. The agent step's `DemoAgentScript` also calls `publish_youtube` so the hook-less approval round trip covers it (`request.tool` sequence: `render_export`, `publish_youtube`).
- `docs/design/integration.md`: a "Publishing" row in the service table, the new check output, the `TIMELINE_ROOT` export-path issue removed from Known issues, the receipts note updated (render and publish ledgers now exist), the new env vars (`TIMELINE_GOOGLE_CLIENT_ID`, `TIMELINE_GOOGLE_CLIENT_JSON`, `TIMELINE_TOKEN_STORE`, `TIMELINE_LIVE_YOUTUBE`, `TIMELINE_KEYCHAIN_TESTS`).
- `docs/design/publish-setup.md`, the developer's Google-side checklist (from 11 §Recommendation and 10 §Recommendation): 1. a Google Cloud project (name it without "YouTube" or "YT", policy III.F.2); 2. enable "YouTube Data API v3"; 3. OAuth consent screen: External, app name, support email, the scope `.../auth/youtube.force-ssl` with the justification "upload videos, set thumbnails, insert caption tracks, add to playlists on the user's own channel", `openid` and `email`; publishing status Testing with the developer's accounts as test users (7-day re-consent); 4. OAuth client of type Desktop app; download the JSON and place it at one of the D3 locations, or set `TIMELINE_GOOGLE_CLIENT_ID` (and `TIMELINE_GOOGLE_CLIENT_SECRET`); 5. run `TimelineApp --connect-google` or Settings > Connect YouTube and confirm `account_status`; 6. a phone-verified test channel (thumbnails, uploads over 15 minutes) and a second unverified channel to exercise the `length` rejection and the thumbnail `403`; 7. the compliance audit form (lifts private-only uploads; needs the privacy policy, homepage, and a demo video; several weeks) and OAuth verification (3-5 business days) before any non-test user; set `audited: true` in the client file when the audit passes; 8. the live test: `TIMELINE_LIVE_YOUTUBE=1 TIMELINE_TOKEN_STORE=file swift test --filter PublishKitTests.LiveYouTubeTests` and commit the scrubbed transcript; 9. the export smoke test from 11 §7 (upload an HLG export with `part=fileDetails` and confirm 10-bit BT.2020 HLG and the edit-list behaviour) once, recorded in the preset docs.

Definition of done: `make e2e` prints the new step; `make test` green; `swift run TimelineApp` shows Settings > Connect and, with a client configured, connects a real account; `TimelineApp --connect-google` works unbundled; integration.md and publish-setup.md updated; zero warnings.

## 5. Order of work

```
1. Contracts commit (section 2)                                 one agent, merged to main first (the gate)
2. Package.swift + Makefile + conventions + .gitignore (3)      the lead, immediately after; `make test` green
3. Four module agents in parallel, each in its own worktree:
     module/publish-kit   (4.1)
     module/project-store (4.2)
     module/agent-kit     (4.3)
     module/timeline-ui   (4.4)
   Each rebases on main after 1 and 2; none depends on another. The lead merges them as they finish
   (disjoint directories, conflict-free by construction).
4. App integration (4.5)                                        one agent, after all four have merged
5. Google-side setup (publish-setup.md) and the live test        the user and the App agent; can start at step 1
```

What can overlap: the user can create the Cloud project, consent screen, and Desktop client (publish-setup.md steps 1-4) while step 1 is in progress; the App agent can write publish-setup.md and the Settings scene skeleton against the fakes while step 3 runs, but must not wire `PublishKit` until it has merged. A `Contracts` change discovered in step 3 follows the conventions rule: a small proposal in `docs/design/contracts-proposals/`, merged by the lead, everyone rebases; the fakes change in the same commit.

## 6. Risks and open questions for the user

1. **Google Cloud project ownership.** Which Google account owns the project (personal `thegoldenmule.com` account or a Workspace org)? The project name must not contain "YouTube"; the consent screen needs a support email and, for verification, a homepage and privacy policy on a domain verified in Search Console (10 §4). Decide before step 5.
2. **File the compliance audit now or later?** Until it passes, every upload is private and `publishAt` cannot work (11 intro). The form wants a working app for the demo video and the privacy policy, and review takes weeks; the recommendation is to file as soon as the skeleton check passes and the sheet works on a real account, and to keep `audited: false` until then.
3. **OAuth verification timing.** `youtube.force-ssl` is sensitive: 3-5 business days, needs the homepage, privacy policy, and demo video (10 §4). Not needed while the project stays in Testing with the developer as test user; needed before anyone else connects. Until then every connection expires after 7 days (Reconnect in Settings), which the UI notices state.
4. **Bundling and signing later.** The data-protection Keychain needs a Developer ID `.app` with a provisioning profile granting `keychain-access-groups` (10 §2); `ASWebAuthenticationSession` needs a bundle; the loopback listener is the one item an App Sandbox review would ask about (12 §8.2). `TokenStore` and `AuthorizationPresenter` are protocols so both moves are one file each. Spike 2 of 10 (Keychain under Developer ID) is still open.
5. **Test channels.** Thumbnails and uploads over 15 minutes need a phone-verified channel; the `length` rejection and the thumbnail `403` need an unverified one (11 §8). Which channels?
6. **Brand channels.** `channels.list mine=true` returns the channel picked on the consent screen; the wrong one means disconnect and reconnect (10 §6). The account view's help text says so; nothing more is planned.
7. **`client_secret` handling.** The Desktop client's secret is not confidential but Google may answer `invalid_client` without it (10 §1); it is sent when the JSON file or env var carries it and is never committed. Confirm that keeping it in `~/Library/Application Support/Timeline/google-oauth-client.json` is acceptable.
8. **Data retention interpretation.** Disconnect deletes tokens, the account record, and cached channel data immediately (D13). The `publishes` rows (video id, URL, status, receipt with the channel title) stay in the user's project as their own upload record. Whether that satisfies policy III.E.4 for the audit form is a judgement call to state in the form; the alternative is to strip `channelTitle` from receipts on disconnect.
9. **Uploads outliving the project window.** The ledger watcher (4.3 step 11) writes to the store the tool resolved; closing the project mid-upload makes that write fail and is logged, the job itself continues and the session is lost from the ledger. V1 rule: the app keeps a document open while a publish job of its project is running (the close path waits or asks). Worth a follow-up if it bites.
10. **Categories and playlists.** V1 ships a static US assignable category list and no playlist picker (`playlistId` is in the request and the publisher supports it; the sheet exposes it as a text field). A `videoCategories.list`/`playlists.list` fetch cached for 30 days is a small follow-up.
11. **Skeleton check time.** The publish step adds about one to two seconds (5 MiB through the in-process fake, one drop, one resume). Acceptable.
12. **Provenance for the AI disclosure.** No generative provider exists yet, so `containsSyntheticMedia` defaults to false with the help text; when providers land, the default should be computed from asset provenance and shown with a reason (11 §3).
