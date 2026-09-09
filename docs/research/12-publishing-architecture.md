# Publishing architecture: connect a Google account, upload to YouTube

Date: 2026-09-09. Scope: how a "connect a Google account and upload a render to YouTube" feature fits the module rules of `docs/design/implementation-plan.md`, the `Contracts` surface, the storage design, the approval gate, the app, and the agent. This document is about placement and shape; the two companion files in this folder (Google auth on macOS; YouTube Data API upload) verify the provider facts. Where a Google or YouTube figure is quoted below it is marked *[memory]* and the companion is the citation. Everything about this repository was read from the sources on 2026-09-09 and is stated as fact.

## Recommendation in one paragraph

Add one leaf module, `PublishKit`, that imports only `TimelineCore` and `Contracts` (plus swift-nio, already in the package graph, for the OAuth loopback listener) and ships `GoogleAccountProvider` (OAuth 2.0 with PKCE, loopback redirect, Keychain token store) and `YouTubePublisher` (resumable upload, metadata, thumbnail, captions) behind two new `Contracts` protocols, `AccountProvider` and `Publisher`. A publish is a `Job` of a new kind `.publish` whose outcome is a `PublishReceipt`; it is recorded in a new `publishes` table in `project.sqlite` next to `renders`, linked by `render_id` and the render's `output_hash`, and it is not an event. The `publish_youtube` tool is gated `.always` by the `ApprovalPolicy`, defaults to `private`, and the approval card shows title, privacy, and channel; the human path calls the same tool through `ToolConsole`, so both paths take the same gate round trip. Tests run PublishKit's real code against a `URLProtocol` fake of Google's endpoints in `ContractsTestSupport` (which may not import swift-nio), keep one opt-in live test behind an environment variable, and extend the skeleton check with a fault-injected, resumed upload. Two things must land before any of this: `render_export` must start recording rows in the existing `renders` table (nothing does today), and the ledger must be reachable through `Contracts`.

## 0. What exists today, and the two gaps

| Piece | State on 2026-09-09 | Consequence for publishing |
|---|---|---|
| `renders` table, `RenderRow`, `SQLiteProjectStore.recordRender` / `updateRender` / `renders()` | Implemented and tested (`PackageAndRendersTests.rendersTableHoldsReceiptsOutsideTheEvents`) | The ledger a publish links to exists |
| Callers of `recordRender` outside `ProjectStore` | None. `render_export` (`Sources/AgentKit/Tools/RenderTools.swift`) compiles, submits the export job, waits, and returns the `ExportReceipt`; it never touches the store's render ledger. The toolbar Export button calls the same tool | **Gap 1:** there is no render id to publish. `render_export` must record a row before submit and update it on completion, and return `renderId` |
| `ProjectStore` protocol (`Sources/Contracts/ProjectStore.swift`) | No render API; `integration.md` already lists "ProjectStore has no public receipt API" as an open question | **Gap 2:** AgentKit (a leaf) cannot reach `SQLiteProjectStore.recordRender` without importing ProjectStore, which the rules forbid. A `Contracts` protocol is required, following the `ProjectStoreCopying` precedent (a refinement of `ProjectStore` the app's store adopts and a tool downcasts to) |
| `renders/` inside the `.tlproj` package | Created by `ProjectPackage.createDirectories`; never written to. Exports go to `<root>/Exports/` (and, without `outputPath`, to `LibraryLayout.default.root`, ignoring `TIMELINE_ROOT`, a known issue in `integration.md`) | Publishing uploads from `renders.output_path`, wherever it points; the path bug should be fixed in the same commit as gap 1 |
| `ApprovalPolicy.standard` | `render_export: .always`, `generate_tts` by cost; gate summary is the generic `tool(key=value, ...)` string from `StandardApprovalGate.summary` | The publish card needs a richer summary (channel is not in the input) |
| `JobKind` | `export, transcription, alignment, hashing, import, analysis, thumbnails, peaks` | Add `.publish` |
| `ToolServices` | Optionals; `EditorTools.requiredService` hides tools whose service is missing | The publishing tools can be hidden until an OAuth client is configured and an account is connected, with no new mechanism |
| `MCPServerHost` | swift-nio `ServerBootstrap` on 127.0.0.1, bearer token on every request, one `HTTPHandler` per connection | Reusable pattern for a loopback OAuth listener; not reusable as the listener itself (wrong module, bearer check would 401 the browser) |
| App bundle | `TimelineApp` is an SPM executable with no bundle (`AppDelegate` sets the activation policy by hand) | No `CFBundleURLTypes`, so custom-scheme redirects and `ASWebAuthenticationSession` are unavailable until the app ships as a bundle; loopback redirect is the path that works now |
| HTTP client code | `URLSession` in `StdioProxy`, `MCPServerHostTests`, and `SkeletonCheck` only | No HTTP client abstraction to inherit; `URLSession` with an injected configuration is the way in |
| Live-test gating | `LiveClaudeTests` behind `TIMELINE_LIVE_CLAUDE=1`, transcripts recorded via `TIMELINE_LIVE_TRANSCRIPT_OUT` | Same pattern for the one real-account test |

## 1. Module placement

### Options

| Option | For | Against |
|---|---|---|
| **New leaf `PublishKit`** (`GoogleAuth` + `YouTubeUploader` + the two `Contracts` conformances) | Matches the plan's "each new feature is a new leaf module"; testable against fakes; the app wires it like every other service; a second destination (Vimeo, Drive) is a second `Publisher` in the same module or a sibling with the same shape; the OAuth code is reusable for Drive/Photos import later | One more target and test target for the lead to declare |
| Extend `AgentKit` | The swift-nio listener is there | AgentKit is the MCP/agent module; the app's Publish sheet would import an agent module for a network feature; PublishKit could never be a sibling of anything AgentKit needs |
| Extend `MediaKit` | Already links CryptoKit and GRDB, has `CacheIndex` for non-project state | MediaKit is the senses/library module; OAuth and uploads are a different kind of risk surface (network, secrets) and would grow its test target, which is already the slow one |
| Put it in `TimelineApp` | No `Package.swift` change | Untestable in isolation, violates the "logic in `swift test`-able packages" rule, and blocks the parallel-agent workflow |

**Decision: `PublishKit`.** Files:

```
Sources/PublishKit/
  PublishKit.swift                 // module doc, shared helpers (base64url, JSON date formats)
  Google/GoogleClientConfiguration.swift   // client id/secret loaded from a file or env var; never in the repo
  Google/PKCE.swift                // code verifier + S256 challenge (CryptoKit SHA256)
  Google/LoopbackRedirectListener.swift    // swift-nio HTTP listener on 127.0.0.1:0, one request, one response
  Google/GoogleOAuthClient.swift   // authorize URL, code exchange, refresh, revoke (URLSession)
  Google/TokenStore.swift          // protocol + KeychainTokenStore (Security) + FileTokenStore (dev/tests)
  Google/GoogleAccountProvider.swift       // AccountProvider: connect/disconnect/accessToken/changes
  YouTube/YouTubeAPI.swift         // request builders: videos.insert (resumable), videos.list, channels.list, thumbnails.set, captions.insert
  YouTube/ResumableUpload.swift    // chunked PUT loop with 308 handling, status query, resume
  YouTube/YouTubePublisher.swift   // Publisher: validate, estimate, publish (Job), status
  YouTube/YouTubeErrors.swift      // Google error JSON -> PublishError (quotaExceeded, forbidden, ...)
Tests/PublishKitTests/
  PKCETests.swift, LoopbackListenerTests.swift, OAuthFlowTests.swift, ResumableUploadTests.swift,
  PublisherTests.swift, LiveYouTubeTests.swift
  Transcripts/                     // recorded request/response pairs, scrubbed, replayed by the fake server
```

Imports: `TimelineCore`, `Contracts`, `Foundation`, `CryptoKit` (framework, not a package; MediaKit links it the same way), `Security`, `NIOCore`/`NIOPosix`/`NIOHTTP1` (products of `swift-nio`, already a package dependency). PublishKit must not import AppKit: opening the browser is a closure the app injects (`open: @Sendable (URL) -> Void`, the app passes `NSWorkspace.shared.open`), and `AuthenticationServices` is deferred until the app is a bundle (see 8.4). No new external package is justified: PKCE is 30 lines over CryptoKit, the OAuth client is URLSession, and the resumable protocol is a loop. AppAuth and GoogleSignIn are Objective-C, expect an app bundle and a client plist, and would be the largest dependency in the package for three endpoints.

### Package.swift changes (the lead's commit)

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

Plus `PublishKitTests` in the Makefile's `TEST_TARGETS` (targets run one at a time) and a `PublishKit` row in the conventions table (`May import: TimelineCore, Contracts, swift-nio`). `AuthenticationServices` is not linked now; it is one line to add when an `ASWebAuthenticationSession` presenter lands.

## 2. The `Contracts` surface

All additive. Every protocol gets a fake in `ContractsTestSupport` and a compile-checked usage example in `Tests/ContractsTests/UsageExampleTests.swift`, per the plan.

### 2.1 Render ledger (closes gaps 1 and 2)

`Sources/Contracts/Renderer.swift`, next to `ExportReceipt`:

```swift
public enum RenderStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case queued, running, done, failed, cancelled
}

/// A row of the project's `renders` ledger (storage.md section 5): operational, never an event.
public struct RenderRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: String                    // renders.render_id
    public var sequenceId: SequenceID
    public var preset: ExportPreset
    public var projectVersion: Int64
    public var status: RenderStatus
    public var requestedAt: Date
    public var completedAt: Date?
    public var outputURL: URL?
    public var outputHash: String?           // "sha256-..." of the finished file, same form as Asset.contentHash
    public var receipt: ExportReceipt?
}

/// Stores that keep the render ledger. `SQLiteProjectStore` and `FakeProjectStore` adopt it; a tool
/// reaches it with `store as? any RenderLedger`, the way Fork reaches `ProjectStoreCopying`.
public protocol RenderLedger: ProjectStore {
    func recordRender(sequenceId: SequenceID, preset: ExportPreset, projectVersion: Int64) async throws -> RenderRecord
    func updateRender(_ id: String, status: RenderStatus, outputURL: URL?, outputHash: String?, receipt: ExportReceipt?) async throws -> RenderRecord
    func renders() async throws -> [RenderRecord]
    func render(_ id: String) async throws -> RenderRecord?
}
```

`render_export` then: resolve store, `recordRender(... status: .queued)`, submit, `updateRender(.running)` on the first progress report, `updateRender(.done, outputURL:, outputHash:, receipt:)` after `wait()`, `.failed`/`.cancelled` on error. The hash comes from the export job itself: `ExportReceipt` gains `outputHash`, computed at the end of `AVFoundationRenderer.export` with the same streamed SHA-256 loop as MediaKit's `ContentHash` (RenderKit links CryptoKit; 20 lines, since neither RenderKit nor AgentKit may import MediaKit), so `render_export` only copies it into the row. PublishKit's `verify` stage carries its own copy of the loop to compare against. Output gains `renderId`. The default output path uses `context.services.mediaLibrary?.layout` like `ToolSupport.mediaURL` does, fixing the `TIMELINE_ROOT` issue.

### 2.2 Accounts (`Sources/Contracts/Accounts.swift`)

```swift
public enum AccountProviderKind: String, Codable, Sendable, Hashable, CaseIterable { case google }

public enum AccountTokenStatus: Hashable, Sendable, Codable {
    case valid(expiresAt: Date)
    case expired                              // access token gone, refresh token present
    case reauthorizationRequired(String)      // refresh failed: revoked, or the 7-day Testing-status expiry
}

/// The non-secret half of a connected account: what settings and the approval card show.
public struct ConnectedAccount: Hashable, Sendable, Codable, Identifiable {
    public var id: String                     // provider-scoped stable subject (Google `sub`), never the email
    public var provider: AccountProviderKind
    public var email: String?
    public var displayName: String?
    public var channelId: String?             // the YouTube channel bound to the account
    public var channelTitle: String?
    public var avatarURL: URL?
    public var scopes: [String]
    public var connectedAt: Date
    public var tokenStatus: AccountTokenStatus
}

/// A bearer token. Deliberately not Codable and with a redacting `description`, so it cannot land in a
/// receipt, a tool output, a log line, or a JSON fixture by accident.
public struct AccessToken: Sendable, CustomStringConvertible {
    public var value: String
    public var expiresAt: Date
    public var scopes: [String]
    public var authorizationHeader: String { "Bearer \(value)" }
    public var description: String { "AccessToken(expires \(expiresAt), \(scopes.count) scopes)" }
}

public enum AccountError: Error, Hashable, Sendable, Codable {
    case notConfigured(String)    // no OAuth client; the sheet shows how to add one
    case cancelled                // the user closed the browser or the sheet
    case denied(String)           // consent refused
    case notConnected(String)     // unknown account id
    case reauthorizationRequired(String)
    case keychain(status: Int32)
    case network(String)
}

/// Connects, disconnects, and vends tokens for one provider. `connect` is `@MainActor` because it
/// presents a browser (or, later, an `ASWebAuthenticationSession`); everything else is pure async work.
public protocol AccountProvider: Sendable {
    var kind: AccountProviderKind { get }
    func accounts() async -> [ConnectedAccount]
    @MainActor func connect(scopes: [String]) async throws -> ConnectedAccount
    /// Revokes the refresh token with the provider (best effort) and deletes the Keychain item.
    func disconnect(_ id: String) async throws
    /// Re-reads channel and profile; refreshes the token if needed.
    func refresh(_ id: String) async throws -> ConnectedAccount
    /// A token valid for at least `minimumLifetime`, refreshed transparently. Callers hold it only for one request.
    func accessToken(for id: String, minimumLifetime: Duration) async throws -> AccessToken
    /// A fresh stream per access (the `Broadcaster` rule of contracts-notes.md).
    var changes: AsyncStream<[ConnectedAccount]> { get }
}
```

Scopes are strings because they are provider vocabulary; `YouTubePublisher.requiredScopes` lists `youtube.upload` (insert) and `youtube.force-ssl` (captions, thumbnails, status reads) *[memory; the auth companion confirms the minimal set]*.

### 2.3 Publishing (`Sources/Contracts/Publishing.swift`)

```swift
public enum PublishDestination: String, Codable, Sendable, Hashable, CaseIterable { case youtube }
public enum PublishPrivacy: String, Codable, Sendable, Hashable, CaseIterable { case `private`, unlisted, `public` }

public enum PublishThumbnail: Hashable, Sendable, Codable {
    case frame(at: RationalTime)      // grabbed with Renderer.frame at publish time, 1280x720 JPEG
    case file(URL)
}

public struct PublishCaptionTrack: Hashable, Sendable, Codable {
    public var language: String       // BCP-47
    public var name: String
    public var format: Format         // .srt | .vtt
    public var body: Data             // rendered from the sequence's caption track, timeline-relative
}

public struct PublishRequest: Hashable, Sendable, Codable {
    public var destination: PublishDestination
    public var accountId: String
    public var renderId: String
    public var fileURL: URL
    public var expectedContentHash: String?   // renders.output_hash; the job refuses a file that hashes differently
    public var title: String                  // YouTube: 1-100 chars, no "<" or ">" [memory]
    public var description: String            // <= 5000 bytes [memory]
    public var tags: [String]                 // <= 500 chars in total [memory]
    public var privacy: PublishPrivacy        // default .private (section 4)
    public var publishAt: Date?               // requires .private; YouTube flips to public at that time [memory]
    public var madeForKids: Bool              // selfDeclaredMadeForKids; required by the API [memory]
    public var categoryId: String?
    public var language: String?
    public var thumbnail: PublishThumbnail?
    public var captions: [PublishCaptionTrack]
    public var notifySubscribers: Bool        // default false
    public var projectVersion: Int64?         // copied from the render row
}

/// Enough to continue an interrupted upload after a crash or relaunch: the resumable session URI is a
/// capability URL, so it lives in the ledger only, never in a receipt, tool output, or log.
public struct PublishSession: Hashable, Sendable, Codable {
    public var uploadURL: URL
    public var totalBytes: Int64
    public var bytesConfirmed: Int64
    public var startedAt: Date
}

public enum PublishStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case queued, uploading, processing, done, failed, cancelled
}

/// Returned as the publish job's payload and stored in `publishes.receipt`. No secrets.
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
    public var privacy: PublishPrivacy        // as reported back by the API after upload (section 8.4)
    public var publishAt: Date?
    public var bytesUploaded: Int64
    public var resumedCount: Int
    public var thumbnailSet: Bool
    public var captionIds: [String]
    public var processingStatus: String?
    public var startedAt: Date
    public var finishedAt: Date
    public var warnings: [String]
}

public struct PublishRecord: Hashable, Sendable, Codable, Identifiable {   // a `publishes` row
    public var id: String
    public var renderId: String
    public var destination: PublishDestination
    public var accountId: String
    public var status: PublishStatus
    public var request: PublishRequest
    public var session: PublishSession?
    public var remoteId: String?
    public var remoteURL: URL?
    public var receipt: PublishReceipt?
    public var error: String?
    public var requestedAt: Date
    public var completedAt: Date?
}

public enum PublishError: Error, Hashable, Sendable, Codable {
    case invalidRequest(String)
    case fileMissing(URL)
    case hashMismatch(expected: String, found: String)
    case notConnected(String)
    case quotaExceeded(resetsAt: Date?)
    case forbidden(String)                    // e.g. thumbnails.set on an unverified channel
    case uploadFailed(status: Int, reason: String)
    case processingFailed(String)
    case cancelled
    case network(String)
}

public protocol Publisher: Sendable {
    var destination: PublishDestination { get }
    var requiredScopes: [String] { get }
    /// Local checks only (lengths, file exists, privacy/publishAt consistency); returns warnings.
    func validate(_ request: PublishRequest) async throws -> [String]
    /// Bytes from the file size, seconds from a running upload-rate estimate, usd 0.
    func estimate(_ request: PublishRequest) async -> Estimate
    /// The upload as a job (kind `.publish`, class `.small`: memory is one chunk). Outcome payload: `PublishReceipt`.
    /// `resuming` continues a session from the ledger; the job reports `PublishSession` updates through `onSession`
    /// so the ledger can persist them, and progress with `fraction = bytes / total` and `stage` in
    /// verify | upload | thumbnail | captions | processing.
    func publish(_ request: PublishRequest, publishId: String, resuming: PublishSession?,
                 onSession: @escaping @Sendable (PublishSession) async -> Void) -> Job
    func remoteStatus(remoteId: String, accountId: String) async throws -> (status: PublishStatus, privacy: PublishPrivacy, processing: String?)
}

public protocol PublishLedger: ProjectStore {
    func recordPublish(_ request: PublishRequest, id: String?) async throws -> PublishRecord
    func updatePublish(_ id: String, status: PublishStatus, session: PublishSession?, remoteId: String?, remoteURL: URL?, receipt: PublishReceipt?, error: String?) async throws -> PublishRecord
    func publishes() async throws -> [PublishRecord]
    func publish(_ id: String) async throws -> PublishRecord?
    func publishes(forRender renderId: String) async throws -> [PublishRecord]
}
```

`JobKind` gains `case publish`. `ToolServices` gains `accounts: [AccountProviderKind: any AccountProvider] = [:]` and `publishers: [PublishDestination: any Publisher] = [:]`.

### 2.4 Credentials never leak

- `AccessToken` is not `Codable`; `PublishRequest`, `PublishReceipt`, `PublishRecord`, and every tool output are `Codable` and contain none. `YouTubePublisher` asks `accountProvider.accessToken(for:minimumLifetime: .minutes(5))` before every request (each chunk included) and puts it in a header; nothing else holds it.
- `PublishSession.uploadURL` is stored in `publishes.session` only. `remoteStatus`, the tool outputs, and the receipt carry `remoteId`/`remoteURL`.
- `MCPServerHost.summary` and `StandardApprovalGate.summary` already strip `approvalToken`; the publishing inputs contain no secret fields to strip. The client secret lives outside the repo (2.5) and is read once by `GoogleClientConfiguration`.
- The URLSession used for Google is `ephemeral` with no cookie or credential storage, and `URLSessionConfiguration.urlCache = nil`.

### 2.5 Where the OAuth client comes from

`GoogleClientConfiguration.load()` reads, in order: `TIMELINE_GOOGLE_CLIENT_JSON` (path), `~/Library/Application Support/Timeline/google-oauth-client.json` (the `client_secret_*.json` the Google Cloud console downloads for a "Desktop app" client, `installed` key; the "secret" of an installed client is not confidential *[memory]*), or `<root>/google-oauth-client.json` when `TIMELINE_ROOT` is set. Missing file: `AppServices` leaves `accounts[.google]` nil, `EditorTools.requiredService` hides `publish_youtube` and `publish_status`, and the settings sheet says "Add a Google OAuth client to enable publishing" with the path. A `.gitignore` line for the file name.

### 2.6 Approval presentation

`ApprovalRequest.inputSummary` is minted by the gate from the input alone, so it cannot name the channel. Additive change, same shape as the `status(of:)` addition in contracts-notes.md:

```swift
public struct ApprovalPresentation: Hashable, Sendable, Codable {
    public var summary: String                      // "Publish 'Band rehearsal' to YouTube as Private"
    public var details: [(label: String, value: String)]  // encoded as an ordered array of pairs
}
// ApprovalRequest gains `public var presentation: ApprovalPresentation?` (decoded as nil when absent)
// ApprovalGate gains
func check(tool: String, input: ToolInput, estimate: Estimate, presentation: ApprovalPresentation?, actor: Actor, sessionId: String?) async -> ApprovalDecision
// with a protocol extension so the existing 5-argument form forwards `nil`, and `ToolContext.checkApproval(tool:input:estimate:presentation:)`.
```

`StandardApprovalGate` and `FakeApprovalGate` use `presentation?.summary ?? summary(tool, input)`. `ToolOutput.approvalRequired` adds `"details"` next to `"summary"`, and `ToolLoopSession.request(from:)` decodes it, so the fallback loop's card shows the same details as the MCP path. `ApprovalCardView` renders `details` as a label/value grid under the summary.

### 2.7 Fakes in `ContractsTestSupport`

| Fake | Behaviour |
|---|---|
| `FakeAccountProvider` | Seeded with `[ConnectedAccount]`; `connect` returns the next scripted account or throws `failNextConnect`; `accessToken` returns `fake-token-<n>` with a configurable lifetime and counts refreshes; `disconnect` records; `changes` over a `Broadcaster` |
| `FakePublisher` | Records every request; `publish` reports `verify`, `upload` (N steps), `thumbnail`, `captions`, `processing`, and returns a receipt with `remoteId: "fake-video-<n>"`; `failAt(fraction:)` throws `PublishError.network` once at that point (the resumed run records `resuming != nil` and `resumedCount`); `refuseHash` makes it throw `hashMismatch` |
| `FakeProjectStore` | Adopts `RenderLedger` and `PublishLedger` in memory, mirroring the SQLite semantics (unknown id throws, terminal states set `completedAt`) |
| `FakeYouTubeServer` | A `URLProtocol` subclass plus a state actor (section 7.1): token endpoint, `channels.list`, resumable `videos.insert`, chunk PUTs with `Content-Range`, `308` with `Range`, status query, `videos.list`, `thumbnails.set`, `captions.insert`, fault injection |
| `Fixtures` additions | `Fixtures.connectedGoogleAccount`, `Fixtures.publishRequest(renderId:)`, `Fixtures.publishReceipt`, and a `publish_youtube` approval request for the card snapshot |

`TestServices.make` gains `accounts: FakeAccountProvider` and `publisher: FakePublisher`, wired into `services`.

## 3. Persistence

### 3.1 The connected account

| What | Where | Why |
|---|---|---|
| Refresh token, current access token, expiry, scopes, client id it was issued for | Keychain, `kSecClassGenericPassword`, `kSecAttrService = "com.thegoldenmule.timeline.google-oauth"`, `kSecAttrAccount = <sub>`, value = JSON, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; not `kSecAttrSynchronizable` | The one place macOS protects secrets. Behind a `TokenStore` protocol inside PublishKit (`KeychainTokenStore`, `FileTokenStore`) because an unsigned SPM binary's Keychain item is re-prompted after every rebuild (the code signature changes), which tests and the headless check cannot answer. `TIMELINE_TOKEN_STORE=file` selects the file store during development; it writes `<root>/Cache/google-tokens.json` with mode 0600 and is refused when `TIMELINE_ROOT` is unset |
| `ConnectedAccount` record (sub, email, channel id/title, avatar URL, scopes, connectedAt) | `~/Library/Application Support/Timeline/accounts.json`, or `<root>/accounts.json` under `TIMELINE_ROOT`, the same rule `MCPConnectionInfo.defaultProxyConfigurationURL` follows | Per-user, cross-project, not derived, so not `Cache/` (deleting `Cache/` must not disconnect an account) and not a project. Small enough for JSON; no SQLite needed |
| Avatar image, daily quota estimate | `Cache/` (`accounts/<sub>/avatar.jpg`, `accounts/<sub>/quota.json`) | Regenerable |

`CacheIndex` is MediaKit's and PublishKit cannot import it; the JSON file avoids a second migrator over `cache.sqlite` (the same reason `ProjectStore.CacheDatabase` is unused, contracts-notes.md).

### 3.2 Publish receipts: a `publishes` table

| Option | Verdict |
|---|---|
| A `publishes` table next to `renders`, `render_id` foreign key | **Chosen.** One render can be published several times (a retry after a failure, unlisted then public, two channels); a publish has its own lifecycle (`queued -> uploading -> processing -> done`) and its own resumable session; `renders` stays a pure export ledger. Same rule as renders: operational rows, not events, so a finished upload never bumps the project version and never makes a mid-turn agent stale (timeline-model.md section 6) |
| A JSON column on `renders` | One publish per render, status conflated with export status, resume state overwriting itself on retry; rejected |
| Events (`RenderPublished`) | Explicitly excluded by timeline-model.md; would also put a remote id into undo history |
| A row in `cache.sqlite` | Wrong scope: a publish belongs to the project that produced the render and must travel with the `.tlproj` |

Migration `v2` in `Sources/ProjectStore/Schema.swift` (GRDB `registerMigration("v2")`, `PRAGMA user_version = 2`, `Schema.currentUserVersion = 2`):

```sql
CREATE TABLE publishes (                        -- operational, not part of the event stream
  publish_id      TEXT PRIMARY KEY,
  render_id       TEXT NOT NULL REFERENCES renders(render_id),
  destination     TEXT NOT NULL CHECK (destination IN ('youtube')),
  account_id      TEXT NOT NULL,                -- provider subject; the account record lives outside the project
  requested_at    TEXT NOT NULL, completed_at TEXT,
  status          TEXT NOT NULL CHECK (status IN ('queued','uploading','processing','done','failed','cancelled')),
  request         TEXT NOT NULL,                -- JSON PublishRequest (no secrets by construction)
  session         TEXT,                         -- JSON PublishSession: upload URI + bytes confirmed, for resume
  bytes_total     INTEGER, bytes_sent INTEGER,
  remote_id       TEXT, remote_url TEXT,
  project_version INTEGER NOT NULL,             -- copied from the render row at request time
  receipt         TEXT,                         -- JSON PublishReceipt
  error           TEXT
) STRICT;
CREATE INDEX publishes_render_idx ON publishes(render_id, requested_at);
```

`PublishRow` in `QueryRows.swift` mirrors `RenderRow` (`FetchableRecord`, `PersistableRecord`, snake-case coding keys); `SQLiteProjectStore` gains `recordPublish` / `updatePublish` / `publishes()` / `publish(_:)` / `publishes(forRender:)` and adopts `PublishLedger`. `rebuildProjections` does not touch `renders` or `publishes` (they are not projections), and `saveAs` copies them with the database (a fork inherits its parent's publish history, which is correct: the videos exist). The existing `PackageAndRendersTests` pattern (`arguments: Backend.allCases`) covers the new rows.

### 3.3 Linking a publish to its render

Three fields, all copied at request time: `render_id` (identity), `renders.output_hash` into `request.expectedContentHash` (integrity: the job re-hashes the file in its `verify` stage and fails with `hashMismatch` if the export was overwritten since, telling the user to re-export), and `project_version` (provenance: "what was published" is the state the render row recorded). `PublishReceipt` carries all three, so `publish_status` can answer "which version of the project is on YouTube" from the project alone.

## 4. Approval and safety

- `ApprovalPolicy.standard` gains `"publish_youtube": .always`. `publish_status` and `account_status` are read-only and `.never`. The rule holds for every caller (MCP, embedded runtime, `ToolConsole`), which is the design's point.
- **Human path confirms too.** The Publish sheet's "Publish" button calls `tools.call("publish_youtube", ...)` through `ToolConsole`, which already turns `approval_required` into a card on the stack and retries with the token on approve. So the sheet is the form, the card is the confirmation, and the same code path serves both actors. No separate confirmation dialog.
- **Default privacy is `private`.** The tool schema's `privacy` default is `private`; `unlisted` is accepted; `public` requires the literal value and the card renders the privacy value in a warning colour. A `publishAt` with anything other than `private` is an `invalidRequest`. The sheet's segmented control defaults to Private.
- **The card** (`ApprovalPresentation`): summary `Publish "<title>" to YouTube as <Privacy>`; details: Channel (`<channelTitle>` / `<email>`), Privacy, Scheduled (if any), File (`<name>`, size), Render (`<preset>`, project v`<n>`), Thumbnail (frame at t / file / none), Captions (`<n>` tracks, languages), Made for kids. `Estimate(seconds: size / measured rate, usd: 0, bytes: size)` fills the existing estimate line.
- **Idempotency.** `publish_youtube` takes an optional `publishId`; a call whose id already has a non-terminal or `done` row returns that row's status instead of uploading again (the `commands` idempotency idea, applied to a non-command). A retry after a tool timeout therefore never double-posts.
- **Quota guard.** Before submitting, the tool checks the local daily estimate (3.1) and refuses with `quotaExceeded(resetsAt:)` when the next insert would exceed it, so a denied-after-upload failure is rare.
- **Cancellation.** `JobCenter.cancel` cancels the task; the job stops at the next chunk boundary, records `cancelled` with the session so the user can resume from the job list (YouTube keeps a partial resumable session for a while *[memory]*; a stale session falls back to a fresh insert).

## 5. UI

| Piece | Module | Notes |
|---|---|---|
| `AccountsSettingsView(provider:)` | `TimelineUI` | Over `any AccountProvider`: rows with avatar, channel title, email, token status; Connect (runs `connect(scopes:)`, shows "waiting for the browser"), Reconnect (on `reauthorizationRequired`), Disconnect. Snapshot-tested against `FakeAccountProvider` |
| `PublishSheetModel` (`@MainActor @Observable`) and `PublishSheetView` | `TimelineUI` | Holds a `PublishRequest` draft. Render picker from `RenderLedger.renders()` newest first (a button "Export first" when empty); title (defaults to the project name), description, tags, privacy (Private default), schedule `DatePicker` enabled only for Private, made-for-kids, thumbnail (current playhead frame via `Renderer.frame`, or a file), captions: one checkbox per caption track of the active sequence; a live summary line "Upload 812 MB to <channel> as Private"; validation warnings from `Publisher.validate`. Captions are rendered from the sequence's caption track with `CaptionFormats.srt(_:)` (a pure helper in `Contracts/Captions.swift`, timeline-relative), not from the raw transcript, because transcript times are media-relative and wrong after any cut; when a sequence has no caption track the sheet offers "Add captions from transcript", which is the existing `caption_add` tool |
| `PublishOutcomeView(outcome:)` | `TimelineUI` | Decodes a `PublishReceipt` from `JobOutcome.payload` and shows "View on YouTube" (`Link(destination: receipt.remoteURL)`) and "Open in Studio"; `JobProgressView` shows it for finished `.publish` entries, and the progress row shows stage and ETA from `JobProgress` |
| `PublishHistoryView(ledger:)` | `TimelineUI` | The project's publishes with status, privacy, channel, link, and Resume for `failed`/`cancelled` rows with a session |
| `ApprovalCardView` details grid | `TimelineUI` | Section 2.6 |
| Toolbar "Publish" button, Settings scene, `PublishConsole` | `TimelineApp` | The button opens the sheet; the sheet's Publish calls `tools.call("publish_youtube")` (section 4); the console tracks the returned `jobId` in `JobCenter` (the tool returns before the job ends, so the app needs the handle: the tool registers the handle in a small `PublishJobs` directory on `ToolServices`, or the console re-finds it via `JobRunner.running()`; the first is simpler). A `Settings { AccountsSettingsView(...) }` scene in `TimelineWindowApp`. `NSWorkspace.shared.open` is the injected browser opener |

## 6. Agent surface

Tool count goes from 15 to 17; `account_status` is folded into `publish_status` to stay near the "about 15" guideline.

**`publish_youtube`** (`annotations: openWorld: true, destructive: false, idempotent: false`, `requiredService`: `publishers[.youtube]`, `accounts[.google]`, `jobRunner`):

```json
{ "type": "object", "required": ["title"], "additionalProperties": false,
  "properties": {
    "projectId":     { "type": "string" },
    "renderId":      { "type": "string", "description": "A render from render_export (default: the newest done render of the active sequence)." },
    "publishId":     { "type": "string", "description": "Idempotency key; a retry with the same id returns the existing publish instead of uploading again." },
    "accountId":     { "type": "string", "description": "Connected Google account (default: the only one)." },
    "title":         { "type": "string", "minLength": 1, "maxLength": 100 },
    "description":   { "type": "string", "maxLength": 5000 },
    "tags":          { "type": "array", "items": { "type": "string" } },
    "privacy":       { "type": "string", "enum": ["private", "unlisted", "public"], "default": "private",
                       "description": "Never public unless the user asked for it in so many words." },
    "publishAt":     { "type": "string", "format": "date-time", "description": "Schedule; requires privacy private." },
    "madeForKids":   { "type": "boolean", "default": false },
    "thumbnailAt":   { "$ref": "#/$defs/time", "description": "Timeline time of the frame to use as the thumbnail." },
    "captionTrackIds": { "type": "array", "items": { "type": "string" }, "description": "Caption tracks of the sequence to upload as subtitle tracks." },
    "waitSeconds":   { "type": "integer", "minimum": 0, "maximum": 600, "default": 120,
                       "description": "How long to wait for the upload before answering status uploading; poll publish_status after." },
    "approvalToken": { "type": "string" } } }
```

Output: `status` (`approval_required | uploading | processing | done | failed`), `publishId`, `jobId`, `renderId`, `remoteId`, `url`, `privacy` (as reported back), `channelTitle`, `bytesUploaded`, `bytesTotal`, `receipt` (the `PublishReceipt` when done), `warnings`, `projectId`. Examples: `{"title": "Band rehearsal, 8 Sept"}` and `{"renderId": "r-1", "title": "Reel", "privacy": "unlisted", "captionTrackIds": ["cap-1"], "approvalToken": "tok-1"}`. The blocking-with-cutoff shape is deliberate: `render_export` blocks for the whole job, which is fine for a 6 s export but not for a 10-minute upload against `MCPServerHost.idleTimeout` (600 s) and the sidecar's tool timeout.

**`publish_status`** (read-only): input `projectId`, optional `publishId`; output `accounts: [{ id, provider, channelTitle, email, tokenStatus, scopes }]`, `configured: Bool`, `publishes: [{ publishId, renderId, status, privacy, url, bytesSent, bytesTotal, stage, error, projectVersion }]` (newest first, or the one asked for). This is how a receipt reaches the agent after a `waitSeconds` cutoff and how a Skill checks the account before proposing anything.

**Skill** `Sources/AgentKit/Skills/publish-to-youtube/SKILL.md`: use when the user says "upload", "publish", "post to YouTube". Procedure: `publish_status` (stop and tell the user to connect an account in Settings if none); `project_describe` for the sequence, its caption tracks, and a title suggestion from the first transcript segment; `render_export` (approval; note `renderId`); `publish_youtube` with `privacy: "private"` unless the user asked for unlisted or public, `captionTrackIds` when a caption track exists, `thumbnailAt` at a shot the user liked, a fresh `publishId`; on `approval_required` wait and retry with the token and the same `publishId`; on `uploading` poll `publish_status` every 30 s; report the URL, privacy, and the project version published; never retry with a new `publishId` after a timeout. `allowed-tools: mcp__timeline__*` like the others.

Receipts: the tool output's `receipt` field (structured), `ToolReceipt` rows in `receipts.jsonl` as for every tool, and the `publishes` row read back by `publish_status`.

## 7. Testing

### 7.1 Without Google

`ContractsTestSupport` may import only `TimelineCore`, `Contracts`, AVFoundation, and CoreImage (conventions.md), so the shared fake of Google's endpoints cannot be a swift-nio server. It is a `URLProtocol`:

- `FakeYouTubeServer` (actor: accounts, videos, resumable sessions, quota counter, fault script) plus `FakeYouTubeURLProtocol` registered on an `URLSessionConfiguration.ephemeral` the test hands to PublishKit (`YouTubePublisher(session:)`, `GoogleOAuthClient(session:)`). In-process, no port, deterministic, and it sees `uploadTask(with:from:)` bodies and drains `httpBodyStream` for file-backed tasks.
- Endpoints: `POST /token` (code exchange, refresh, `invalid_grant` on a revoked token), `GET /youtube/v3/channels?mine=true`, `POST /upload/youtube/v3/videos?uploadType=resumable` (returns `Location`), `PUT <session>` with `Content-Range` (`308 Resume Incomplete` with `Range: bytes=0-N` until complete, then `200` with the video JSON; a `Content-Range: bytes */total` query returns the confirmed offset), `GET /youtube/v3/videos?part=status,processingDetails`, `POST /upload/youtube/v3/thumbnails/set`, `POST /upload/youtube/v3/captions`, `DELETE /youtube/v3/videos`.
- Faults: `dropConnection(afterBytes:)`, `respond(503, times:)`, `quotaExceeded`, `forbiddenThumbnail`, `forcePrivate` (the unverified-project behaviour, section 8.4), `slowChunk(ms)`.
- Recorded transcripts in `Tests/PublishKitTests/Transcripts/` (scrubbed request/response pairs from the one live run, the `AgentKitTests/Transcripts` convention) seed the fake's response bodies so its JSON matches Google's, not a hand-typed guess.

Tests: PKCE vectors; loopback listener answers one `GET /callback?code=&state=`, rejects a wrong `state`, times out, and closes its port (PublishKit's own test target may use NIO, and it replaces the browser with a `URLSession` GET); OAuth code exchange and refresh through the fake; `KeychainTokenStore` behind `TIMELINE_KEYCHAIN_TESTS=1` (an unsigned test binary prompts), `FileTokenStore` always; resumable upload of a 5 MiB `TestMedia` clip in 1 MiB chunks completes, resumes after a dropped connection at 40% without re-sending confirmed bytes, resumes from a `PublishSession` after a simulated relaunch, caps retries on repeated 503s, maps `quotaExceeded` and `forbidden`, refreshes a token that expires mid-upload; `hashMismatch` on a modified file; the whole `publish` job through `FakeJobRunner` producing a `PublishReceipt` with `resumedCount == 1`; AgentKit: `publish_youtube` returns `approval_required` with `details` containing Channel and Privacy, retries with the token, hides when unconfigured, rejects `publishAt` with `unlisted`, returns the existing row for a repeated `publishId`; a schema contract test as for every tool; TimelineUI snapshots of the sheet, the card with details, the accounts list, and the outcome link.

### 7.2 With a real account (manual, opt-in)

`LiveYouTubeTests`, `.enabled(if: TIMELINE_LIVE_YOUTUBE == "1")`, needs `TIMELINE_GOOGLE_CLIENT_JSON` and a connected account (`TIMELINE_TOKEN_STORE=file` with a token obtained once through the app, or `TIMELINE_YOUTUBE_REFRESH_TOKEN`). It uploads a 2 s `TestMedia.videoWithAudio` clip as `private` titled `timeline-live-test <ISO date>`, waits for `processingDetails`, sets a thumbnail (tolerating `forbidden`), then `videos.delete`s it so the channel stays clean. Cost per run about 1,650 quota units *[memory]*, so it is never in `make test`. `TIMELINE_LIVE_TRANSCRIPT_OUT` records the scrubbed exchange for 7.1.

### 7.3 The skeleton check

`AppServices.boot` gains `publishing: PublishingMode` (`.auto` reads the client file; `.fake` builds the real `GoogleAccountProvider` over a `FileTokenStore` in the temporary root and the real `YouTubePublisher` over `FakeYouTubeServer`'s session, with one seeded account). The check adds one step after `agent`:

```
ok   publish: render r-… recorded (h264_1080p, v18); publish_youtube -> approval_required (Channel: Skeleton Channel, Privacy: private);
     approved; upload 5 MiB in 1 MiB chunks, dropped at 40%, resumed once; publishes row done, remote fake-video-1, url https://youtu.be/fake-video-1
```

It asserts the render row exists with `output_hash`, the card's details, the job's stages in order, the resumed count, the `publishes` row after `close` and reopen, and that `publish_status` over MCP returns the row. `DemoAgentScript` gains a `publish_youtube` call after the export so the agent path's approval round trip covers it as well.

## 8. Risks

### 8.1 Multi-GB uploads, CoreMedia, and URLSession

The upload must never read the file through AVFoundation and never hold it in memory: `FileHandle.read(upToCount:)` of one chunk (32 MiB, a multiple of 256 KiB as the protocol requires *[memory]*) into `Data`, `URLSession.uploadTask(with:from:)` per chunk, memory class `.small` honestly. `Data(contentsOf:)` on a 4 GB export would break the budget the runner enforces. Per-chunk request timeouts (`timeoutIntervalForRequest` 120 s) with `waitsForConnectivity`; a stalled chunk is retried from the confirmed offset, which is what the resumable protocol is for. Background `URLSession` needs a bundle identifier and is unavailable to the SPM executable; when the app becomes a bundle it is the way to survive termination. Hold a `ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Uploading to YouTube")` token for the job's duration so a laptop lid does not end a two-hour upload. The runner's `maxConcurrent[.medium] = 2` means an export and a transcription can run beside an upload; the `verify` stage's SHA-256 pass reads the file once at 2.3 GB/s and is the only disk-heavy step. The `swift test` stall in `integration.md` is a CoreMedia reader/writer interaction; the upload path opens no AV session, but the test target still runs alone under `make test`.

### 8.2 Sandbox and entitlements, if the app is sandboxed later

`com.apple.security.network.client` (Google), `com.apple.security.network.server` (the loopback OAuth listener and, already, the MCP host), `keychain-access-groups` when the data-protection Keychain is used, `com.apple.security.files.user-selected.read-only` for thumbnail files, and a security-scoped bookmark for the `Exports/` folder outside the container. None of this exists today (App Sandbox is mandatory only for the Mac App Store, research 07) and the loopback listener is the one item a reviewer would ask about; the custom-scheme redirect through `ASWebAuthenticationSession` removes it, which is why `AuthorizationPresenter` is a protocol from day one.

### 8.3 Quota

Default 10,000 units per project per day, `videos.insert` 1,600, `captions.insert` 400, `thumbnails.set` 50, list calls 1, reset at midnight Pacific *[memory; the upload companion confirms]*. That is six uploads a day before a quota increase request, and a failed upload is charged. Behaviour: the local counter (3.1) blocks the seventh with `quotaExceeded(resetsAt:)` before any bytes move; `videos.list` polling for processing uses exponential backoff capped at 10 polls; the sheet shows "about N uploads left today". A quota increase requires the audit in 8.4.

### 8.4 The unverified-app consent screen and Testing status

During development the OAuth consent screen shows "Google hasn't verified this app" with an Advanced link, and a project in Testing status admits at most 100 test users and expires refresh tokens after seven days *[memory]*, which surfaces as `reauthorizationRequired` and a Reconnect button, not as a failed upload. Videos inserted by an unverified project are set to private regardless of the requested status *[memory; important to confirm]*, so the receipt records the privacy the API reports back and the tool warns when it differs from the request. Publishing `youtube.upload`, a sensitive scope, to the public needs the verification and the API compliance audit, with a privacy policy and demo video; plan that before any user other than the developer connects an account.

### 8.5 Token expiry during a long upload

Access tokens last an hour *[memory]*; a 2 GB upload on a slow link takes longer. Every chunk asks `accessToken(for:minimumLifetime: .minutes(5))`, so the refresh happens between chunks and the resumable session continues. A refresh that fails mid-upload persists the `PublishSession` and marks the row `failed` with `reauthorizationRequired`, and Resume in the history view picks it up after reconnecting.

### 8.6 Smaller items

- The loopback listener binds an ephemeral port only while a connect flow is open, checks `state` against a single-use nonce, answers the browser with a plain "You can close this window" page, and shuts down on the first request or after five minutes.
- A fork (`saveAs`) copies `publishes`; the fork's history correctly shows the parent's uploads.
- `publish_status` must never return `session.uploadURL`; a unit test asserts the tool output and the receipt contain no `upload/youtube` string.
- `render_export` without `outputPath` writes under `~/Movies/Timeline/Exports` even under `TIMELINE_ROOT` (integration.md); fixing it is part of the gap-1 commit, otherwise the headless publish step uploads from the wrong root.

## 9. Order of work

1. `Contracts`: `RenderRecord`/`RenderLedger`, `ApprovalPresentation`, `JobKind.publish`, `Accounts.swift`, `Publishing.swift`, `Captions.swift`, `ToolServices` fields; fakes and usage examples in the same commit. (Small, reviewed, merged first, per conventions.)
2. `Package.swift`: `PublishKit` target and tests; Makefile; conventions table. (The lead.)
3. `ProjectStore`: `RenderLedger` adoption, migration `v2` with `publishes`, `PublishRow`, `PublishLedger`.
4. `AgentKit`: `render_export` records renders and returns `renderId`; `publish_youtube`, `publish_status`; the Skill; schema tests.
5. `PublishKit`: auth, upload, publisher, fake-server tests, the live test.
6. `TimelineUI`: sheet, settings, outcome link, history, card details.
7. `TimelineApp`: wiring, Settings scene, `PublishingMode.fake`, the skeleton step, `DemoAgentScript`.

Steps 3 to 6 are independent once 1 and 2 have merged, which is the parallel shape the plan wants.
