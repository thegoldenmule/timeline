import Contracts
import Foundation
import Synchronization
import TimelineCore

/// An in-process fake of Google's OAuth and YouTube Data API endpoints, reached through
/// `URLSession` with `sessionConfiguration()`: a `URLProtocol` intercepts every request to
/// `accounts.google.com`, `oauth2.googleapis.com`, `openidconnect.googleapis.com`, and
/// `www.googleapis.com`, so PublishKit talks to Google's real URLs and never to the network.
///
/// Endpoints (bodies shaped like Google's JSON):
/// - `POST /token`: `authorization_code` (needs `code`, `code_verifier`, `redirect_uri`, `client_id`; the
///   code comes from `issueAuthorizationCode(for:)`, or any `fake-code-*` from `FakeAuthorizationPresenter`,
///   which binds to the first seeded account) answers `access_token`, `expires_in`, `refresh_token`,
///   `scope` (canonical: `email` becomes `.../auth/userinfo.email`, the way Google reports it), `id_token`
///   (an unsigned JWT carrying `sub` and `email`); `refresh_token` answers a new access token, or
///   `400 invalid_grant` after `revokeRefreshToken(sub:)`.
/// - `POST /revoke`: 200 for a known token, 400 otherwise; both delete what they can.
/// - `GET /v1/userinfo`: `sub`, `email` for the bearer.
/// - `GET /youtube/v3/channels?mine=true`: one channel, or `items: []` for a `noChannel` account (Google
///   omits the key; decode it as optional).
/// - `POST /upload/youtube/v3/videos?uploadType=resumable`: validates `X-Upload-Content-Length`, stores the
///   metadata, answers 200 with `Location`; counts one upload.
/// - `PUT <session>` with `Content-Range: bytes a-b/total`: rejects (400) a chunk whose `a` is not the
///   confirmed offset, a non-final chunk that is not a multiple of 262,144 bytes, a body whose length
///   differs from the range, or a missing `Content-Length`; answers `308` with `Range: bytes=0-<confirmed-1>`
///   or `201` with the video resource when complete (`privacyStatus` downgraded to `private` under
///   `forcePrivate`).
/// - `PUT <session>` with `Content-Range: bytes */total`: `308` + `Range`, `308` without `Range` when nothing
///   is stored, `201` when complete, `404` after `expireSession()`.
/// - `GET /youtube/v3/videos?id=`: `uploaded`/`processing` for `processingPollsUntilDone` polls, then
///   `processed`, or the outcome from `scriptProcessing(uploadStatus:reason:)`.
/// - `POST /upload/youtube/v3/thumbnails/set?videoId=`: 200, or `403 forbidden` under `forbidThumbnail()`.
/// - `POST /upload/youtube/v3/captions?uploadType=multipart`: parses the multipart body, answers a caption
///   id, `409` for a duplicate language + name on the same video.
/// - `POST /youtube/v3/playlistItems`, `DELETE /youtube/v3/videos?id=` (204).
///
/// Every API request without a valid bearer answers `401` (`WWW-Authenticate: Bearer error="invalid_token"`,
/// Google's `authError` body); every API request costs the documented units (`channels.list` 1,
/// `videos.list` 1, `thumbnails.set` 50, `captions.insert` 400, `playlistItems.insert` 50,
/// `videos.delete` 50) and `videos.insert` costs one of the 100 daily uploads; chunk `PUT`s cost nothing.
///
/// Faults are consumed once unless `times:` says otherwise: `dropConnection(afterBytes:)` (the protocol
/// fails the chunk `PUT` with `URLError.networkConnectionLost` once that many body bytes, cumulative
/// across chunks, have been forwarded; the fake keeps the bytes it received, rounded down to 256 KiB),
/// `respond(status:times:)` on the next chunk `PUT`s, `quotaExceeded(times:)`, `uploadLimitExceeded(times:)`,
/// `forbidThumbnail(times:)`, `expireSession()`, `revokeRefreshToken(sub:)`, `expireAccessTokensNow()` (the
/// next bearer answers `401` once), `retryAfter(seconds:)` (a `Retry-After` header on the next fault
/// responses). `forcePrivate(_:)` is a switch, not a one-shot: it models the unaudited project.
public actor FakeYouTubeServer {
    // MARK: Types

    public struct SeededAccount: Sendable, Hashable {
        public var sub: String
        public var email: String
        public var channelId: String
        public var channelTitle: String
        public var handle: String
        public var noChannel: Bool
    }

    public struct UploadSession: Sendable, Hashable {
        public var id: String
        public var metadata: JSONValue
        public var totalBytes: Int64
        public var bytesConfirmed: Int64
        public var videoId: String?
        public var query: [String: String]
        public var expired: Bool
        public var uploadURL: URL
    }

    public struct Video: Sendable, Hashable {
        public var id: String
        public var snippet: JSONValue
        public var status: JSONValue
        public var privacy: String
        public var uploadStatus: String
        public var processingStatus: String
        public var processingPollsLeft: Int
        public var failureReason: String?
        public var rejectionReason: String?
    }

    public struct Caption: Sendable, Hashable {
        public var id: String
        public var videoId: String
        public var language: String
        public var name: String
        public var body: String
    }

    public struct PlaylistItem: Sendable, Hashable {
        public var id: String
        public var playlistId: String
        public var videoId: String
    }

    /// One request as the fake saw it. The bearer value is never recorded, only its presence.
    public struct RecordedRequest: Sendable, Hashable {
        public var method: String
        public var host: String
        public var path: String
        public var query: [String: String]
        /// `Content-Range`, `Content-Length`, `Content-Type`, `X-Upload-Content-Length`, `X-Upload-Content-Type`.
        public var headers: [String: String]
        public var hasBearer: Bool
        public var bodyBytes: Int
        /// True when the connection was dropped by `dropConnection(afterBytes:)` while reading the body.
        public var dropped: Bool

        public var contentRange: String? { headers["Content-Range"] }
        /// `bytes */total`.
        public var isStatusQuery: Bool { contentRange?.hasPrefix("bytes */") == true }
        /// The `a-b` of `bytes a-b/total`, for overlap checks.
        public var chunkRange: ClosedRange<Int64>? {
            guard let parsed = FakeYouTubeServer.parseContentRange(contentRange), let start = parsed.start,
                let end = parsed.end
            else { return nil }
            return start...end
        }
        public var isChunk: Bool { chunkRange != nil }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private struct Registration: Sendable {
        weak var server: FakeYouTubeServer?
        init(_ server: FakeYouTubeServer) { self.server = server }
    }

    // MARK: Constants

    public static let hosts: Set<String> = [
        "accounts.google.com", "oauth2.googleapis.com", "openidconnect.googleapis.com", "www.googleapis.com",
    ]
    /// The chunk granularity Google requires of non-final chunks.
    public static let chunkGranularity: Int64 = 262_144
    public static let uploadsLimit = 100
    public static let unitsLimit = 10_000
    public static let accessTokenLifetime: TimeInterval = 3599

    private static let registry = Mutex<[String: Registration]>([:])

    static func registered(_ id: String) -> FakeYouTubeServer? { registry.withLock { $0[id]?.server } }

    // MARK: State

    public nonisolated let id: String
    public private(set) var accounts: [String: SeededAccount] = [:]
    private var seededOrder: [String] = []
    private var refreshTokens: [String: String] = [:]
    private var accessTokens: [String: (sub: String, expiresAt: Date)] = [:]
    private var authorizationCodes: [String: (sub: String, scopes: [String])] = [:]
    private var consumedCodes: Set<String> = []
    public private(set) var sessions: [String: UploadSession] = [:]
    public private(set) var videos: [String: Video] = [:]
    /// Thumbnail bytes by video id.
    public private(set) var thumbnails: [String: Int] = [:]
    public private(set) var captions: [Caption] = []
    public private(set) var playlistItems: [PlaylistItem] = []
    public private(set) var requests: [RecordedRequest] = []
    /// The `a...b` of every chunk the fake accepted (308 or 201), in order.
    public private(set) var acceptedChunks: [ClosedRange<Int64>] = []
    public private(set) var uploadsUsed = 0
    public private(set) var unitsUsed = 0
    /// Polls of `videos.list` before a video reports `processed` (default 2).
    public private(set) var processingPollsUntilDone = 2
    private var grantedScopesOverride: [String]?
    private var counters: [String: Int] = [:]

    private var dropRemaining: Int64?
    private var respondFault: (status: Int, remaining: Int)?
    private var quotaExceededRemaining = 0
    private var uploadLimitExceededRemaining = 0
    private var forbidThumbnailRemaining = 0
    private var forcePrivateEnabled = false
    private var expireAccessTokenOnce = false
    private var retryAfterSeconds: Int?
    private var revokedRefreshTokens: Set<String> = []
    private var scriptedProcessing: (uploadStatus: String, reason: String)?

    public init(id: String = "fake-youtube-\(UUID().uuidString)") {
        self.id = id
        Self.registry.withLock { $0[id] = Registration(self) }
    }

    /// An ephemeral configuration whose only protocol is this fake; hand it to the code under test.
    public nonisolated func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeYouTubeURLProtocol.self]
        configuration.httpAdditionalHeaders = [FakeYouTubeURLProtocol.serverHeader: id]
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return configuration
    }

    // MARK: Seeding

    /// Seeds an account the token endpoint can authorize. Returns the refresh token (the given one, or
    /// `fake-refresh-<n>`), for tests that pre-store a credential.
    @discardableResult public func seedAccount(
        sub: String, email: String, channelId: String = "UC-fake", channelTitle: String = "Skeleton Channel",
        handle: String = "@skeleton", refreshToken: String? = nil, noChannel: Bool = false
    ) -> String {
        accounts[sub] = SeededAccount(
            sub: sub, email: email, channelId: channelId, channelTitle: channelTitle, handle: handle,
            noChannel: noChannel)
        if !seededOrder.contains(sub) { seededOrder.append(sub) }
        let token = refreshToken ?? "fake-refresh-\(next("refresh"))"
        refreshTokens[token] = sub
        return token
    }

    /// Seeds `Fixtures.connectedGoogleAccount` and returns its refresh token.
    @discardableResult public func seedFixtureAccount() -> String {
        let account = Fixtures.connectedGoogleAccount
        return seedAccount(
            sub: account.id, email: account.email ?? "me@example.com", channelId: account.channelId ?? "UC-fake",
            channelTitle: account.channelTitle ?? "Skeleton Channel", handle: account.channelHandle ?? "@skeleton")
    }

    /// A one-time authorization code for `sub` (nil: the first seeded account), so a connect flow through
    /// the loopback listener completes without a browser.
    public func issueAuthorizationCode(for sub: String? = nil, scopes: [String]? = nil) -> String {
        let code = "fake-code-\(next("code"))"
        let subject = sub ?? seededOrder.first ?? "sub-1"
        authorizationCodes[code] = (subject, scopes?.isEmpty == false ? scopes! : Fixtures.publishScopes)
        return code
    }

    /// Every later code exchange reports these scopes instead of the requested ones (a user unticking
    /// one on the consent screen). Nil restores the default.
    public func setGrantedScopes(_ scopes: [String]?) { grantedScopesOverride = scopes }

    public func setProcessingPollsUntilDone(_ polls: Int) { processingPollsUntilDone = max(0, polls) }

    /// Videos completing after this call report `uploadStatus` `failed` or `rejected` with the reason.
    public func scriptProcessing(uploadStatus: String, reason: String) { scriptedProcessing = (uploadStatus, reason) }

    /// An access token bound to `sub`, for tests that skip the token endpoint.
    public func issueAccessToken(for sub: String, lifetime: TimeInterval = accessTokenLifetime) -> String {
        let token = "fake-access-\(next("access"))"
        accessTokens[token] = (sub, Date().addingTimeInterval(lifetime))
        return token
    }

    // MARK: Faults

    public func dropConnection(afterBytes: Int64) { dropRemaining = afterBytes }
    public func respond(status: Int, times: Int = 1) { respondFault = (status, times) }
    public func quotaExceeded(times: Int = 1) { quotaExceededRemaining = times }
    public func uploadLimitExceeded(times: Int = 1) { uploadLimitExceededRemaining = times }
    public func forbidThumbnail(times: Int = 1) { forbidThumbnailRemaining = times }
    public func forcePrivate(_ enabled: Bool = true) { forcePrivateEnabled = enabled }
    public func expireSession() { for key in sessions.keys { sessions[key]?.expired = true } }
    public func revokeRefreshToken(sub: String) {
        for (token, owner) in refreshTokens where owner == sub { revokedRefreshTokens.insert(token) }
        accessTokens = accessTokens.filter { $0.value.sub != sub }
    }
    public func expireAccessTokensNow() { expireAccessTokenOnce = true }
    public func retryAfter(seconds: Int) { retryAfterSeconds = seconds }

    // MARK: Inspection

    public var chunkRequests: [RecordedRequest] { requests.filter(\.isChunk) }
    public var statusQueries: [RecordedRequest] { requests.filter(\.isStatusQuery) }
    /// True when two accepted chunk ranges overlap: a client resent confirmed bytes. Rejected and dropped
    /// chunks do not count.
    public var hasOverlappingChunks: Bool {
        let ranges = acceptedChunks.sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(ranges, ranges.dropFirst()) where b.lowerBound <= a.upperBound { return true }
        return false
    }
    public var quota: PublishQuota {
        PublishQuota(
            uploadsUsed: uploadsUsed, uploadsLimit: Self.uploadsLimit, unitsUsed: unitsUsed,
            unitsLimit: Self.unitsLimit, resetsAt: Date().addingTimeInterval(86_400))
    }
    public func video(_ id: String) -> Video? { videos[id] }
    public func captions(forVideo id: String) -> [Caption] { captions.filter { $0.videoId == id } }

    // MARK: Protocol entry points

    /// How many more body bytes the protocol may forward for this request before dropping it; nil when
    /// no drop is armed or the request is not a chunk `PUT`.
    func dropLimit(for request: URLRequest) -> Int64? {
        guard let remaining = dropRemaining, request.httpMethod == "PUT",
            let parsed = Self.parseContentRange(request.value(forHTTPHeaderField: "Content-Range")), parsed.start != nil
        else { return nil }
        return remaining
    }

    /// The protocol dropped this chunk after `forwarded` bytes: keep the granularity-aligned prefix.
    func chunkDropped(_ request: URLRequest, forwarded: Int64) {
        record(request, bodyBytes: Int(forwarded), dropped: true)
        dropRemaining = nil
        guard let uploadId = Self.query(of: request.url)["upload_id"], var session = sessions[uploadId],
            !session.expired, let parsed = Self.parseContentRange(request.value(forHTTPHeaderField: "Content-Range")),
            let start = parsed.start, start == session.bytesConfirmed
        else { return }
        let kept = forwarded / Self.chunkGranularity * Self.chunkGranularity
        session.bytesConfirmed = min(session.totalBytes, start + kept)
        sessions[uploadId] = session
    }

    /// Body bytes forwarded without a drop count against the armed drop.
    func bodyForwarded(_ bytes: Int64) {
        if let remaining = dropRemaining { dropRemaining = max(0, remaining - bytes) }
    }

    func handle(_ request: URLRequest, body: Data, bodyBytes: Int) -> Response {
        record(request, bodyBytes: bodyBytes, dropped: false)
        guard let url = request.url, let host = url.host() else { return Self.error(400, "Bad request", "badRequest") }
        let method = request.httpMethod ?? "GET"
        let path = url.path()
        switch (host, method, path) {
        case ("accounts.google.com", _, _):
            return Response(
                status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>Sign in</html>".utf8))
        case ("oauth2.googleapis.com", "POST", "/token"): return token(request, body: body)
        case ("oauth2.googleapis.com", "POST", "/revoke"): return revoke(request, body: body)
        case ("openidconnect.googleapis.com", "GET", "/v1/userinfo"):
            switch authorize(request) {
            case .failure(let response): return response
            case .success(let sub):
                let account = accounts[sub]
                return Self.json(
                    200, ["sub": .string(sub), "email": .string(account?.email ?? ""), "email_verified": true])
            }
        case ("www.googleapis.com", _, _):
            return api(request, method: method, path: path, body: body, bodyBytes: bodyBytes)
        default: return Self.error(404, "Not found", "notFound")
        }
    }

    // MARK: OAuth

    private func token(_ request: URLRequest, body: Data) -> Response {
        let form = Self.parseForm(body)
        switch form["grant_type"] {
        case "authorization_code":
            guard let code = form["code"], let verifier = form["code_verifier"], !verifier.isEmpty,
                let redirect = form["redirect_uri"], !redirect.isEmpty, let clientId = form["client_id"],
                !clientId.isEmpty
            else {
                return Self.oauthError(
                    400, "invalid_request", "Missing code, code_verifier, redirect_uri, or client_id")
            }
            let sub: String
            let scopes: [String]
            if let issued = authorizationCodes.removeValue(forKey: code) {
                (sub, scopes) = issued
            } else if code.hasPrefix("fake-code-"), !consumedCodes.contains(code), let first = seededOrder.first {
                (sub, scopes) = (first, Fixtures.publishScopes)
            } else {
                return Self.oauthError(400, "invalid_grant", "Malformed auth code.")
            }
            consumedCodes.insert(code)
            guard let account = accounts[sub] else { return Self.oauthError(400, "invalid_grant", "Unknown account.") }
            let granted = grantedScopesOverride ?? scopes
            let refresh = "fake-refresh-\(next("refresh"))"
            refreshTokens[refresh] = sub
            let access = issueAccessToken(for: sub)
            let now = Date()
            let idToken = Self.unsignedJWT([
                "iss": "https://accounts.google.com", "aud": .string(clientId), "sub": .string(sub),
                "email": .string(account.email), "email_verified": true,
                "iat": .number(now.timeIntervalSince1970.rounded(.down)),
                "exp": .number((now.timeIntervalSince1970 + 3600).rounded(.down)),
            ])
            return Self.json(
                200,
                [
                    "access_token": .string(access), "expires_in": .number(Self.accessTokenLifetime),
                    "refresh_token": .string(refresh), "scope": .string(Self.canonicalScopes(granted)),
                    "token_type": "Bearer", "id_token": .string(idToken),
                ])
        case "refresh_token":
            guard let refresh = form["refresh_token"], let sub = refreshTokens[refresh],
                !revokedRefreshTokens.contains(refresh)
            else { return Self.oauthError(400, "invalid_grant", "Token has been expired or revoked.") }
            let access = issueAccessToken(for: sub)
            return Self.json(
                200,
                [
                    "access_token": .string(access), "expires_in": .number(Self.accessTokenLifetime),
                    "scope": .string(Self.canonicalScopes(grantedScopesOverride ?? Fixtures.publishScopes)),
                    "token_type": "Bearer",
                ])
        default: return Self.oauthError(400, "unsupported_grant_type", "Invalid grant_type")
        }
    }

    private func revoke(_ request: URLRequest, body: Data) -> Response {
        let token = Self.query(of: request.url)["token"] ?? Self.parseForm(body)["token"]
        guard let token else { return Self.oauthError(400, "invalid_request", "Missing token") }
        if let sub = refreshTokens.removeValue(forKey: token) {
            revokedRefreshTokens.remove(token)
            accessTokens = accessTokens.filter { $0.value.sub != sub }
            return Self.json(200, [:])
        }
        if let owner = accessTokens.removeValue(forKey: token) {
            for (refresh, sub) in refreshTokens where sub == owner.sub { refreshTokens[refresh] = nil }
            return Self.json(200, [:])
        }
        return Self.oauthError(400, "invalid_token", "Token expired or revoked")
    }

    private func authorize(_ request: URLRequest) -> Result<String, Response> {
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer ") else {
            return .failure(Self.unauthorized())
        }
        if expireAccessTokenOnce {
            expireAccessTokenOnce = false
            return .failure(Self.unauthorized())
        }
        let token = String(header.dropFirst("Bearer ".count))
        guard let entry = accessTokens[token], entry.expiresAt > Date() else { return .failure(Self.unauthorized()) }
        return .success(entry.sub)
    }

    // MARK: YouTube API

    private func api(_ request: URLRequest, method: String, path: String, body: Data, bodyBytes: Int) -> Response {
        let query = Self.query(of: request.url)
        if path == "/upload/youtube/v3/videos", method == "PUT", let uploadId = query["upload_id"] {
            return upload(uploadId, request: request, bodyBytes: bodyBytes)
        }
        let sub: String
        switch authorize(request) {
        case .failure(let response): return response
        case .success(let s): sub = s
        }
        if quotaExceededRemaining > 0 {
            quotaExceededRemaining -= 1
            return quotaExceededResponse()
        }
        switch (method, path) {
        case ("GET", "/youtube/v3/channels"): return charging(1) { self.channels(sub: sub, query: query) }
        case ("POST", "/upload/youtube/v3/videos"): return startUpload(request: request, query: query, body: body)
        case ("GET", "/youtube/v3/videos"): return charging(1) { self.listVideos(query: query) }
        case ("DELETE", "/youtube/v3/videos"): return charging(50) { self.deleteVideo(query: query) }
        case ("POST", "/upload/youtube/v3/thumbnails/set"):
            return charging(50) { self.setThumbnail(query: query, bodyBytes: bodyBytes) }
        case ("POST", "/upload/youtube/v3/captions"):
            return charging(400) { self.insertCaption(request: request, body: body) }
        case ("POST", "/youtube/v3/playlistItems"): return charging(50) { self.insertPlaylistItem(body: body) }
        default: return Self.error(404, "Not found: \(method) \(path)", "notFound")
        }
    }

    private func charging(_ units: Int, _ body: () -> Response) -> Response {
        guard unitsUsed + units <= Self.unitsLimit else { return quotaExceededResponse() }
        unitsUsed += units
        return body()
    }

    private func quotaExceededResponse() -> Response {
        var response = Self.error(
            403, "The request cannot be completed because you have exceeded your quota.", "quotaExceeded",
            domain: "youtube.quota", status: "PERMISSION_DENIED")
        response.headers.merge(retryAfterHeader()) { a, _ in a }
        return response
    }

    private func channels(sub: String, query: [String: String]) -> Response {
        guard query["mine"] == "true" else { return Self.error(400, "mine is required", "missingRequiredParameter") }
        guard let account = accounts[sub], !account.noChannel else {
            return Self.json(
                200,
                [
                    "kind": "youtube#channelListResponse", "pageInfo": ["totalResults": 0, "resultsPerPage": 5],
                    "items": .array([]),
                ])
        }
        return Self.json(
            200,
            [
                "kind": "youtube#channelListResponse", "pageInfo": ["totalResults": 1, "resultsPerPage": 5],
                "items": .array([
                    [
                        "kind": "youtube#channel", "id": .string(account.channelId),
                        "snippet": [
                            "title": .string(account.channelTitle), "customUrl": .string(account.handle),
                            "thumbnails": [
                                "default": [
                                    "url": .string("https://yt3.ggpht.com/fake/\(account.sub)"), "width": 88,
                                    "height": 88,
                                ]
                            ],
                        ], "statistics": ["subscriberCount": "1", "videoCount": .string(String(videos.count))],
                    ]
                ]),
            ])
    }

    private func startUpload(request: URLRequest, query: [String: String], body: Data) -> Response {
        guard query["uploadType"] == "resumable" else {
            return Self.error(400, "uploadType=resumable is required", "badRequest")
        }
        guard let lengthHeader = request.value(forHTTPHeaderField: "X-Upload-Content-Length"),
            let total = Int64(lengthHeader), total >= 0
        else { return Self.error(400, "X-Upload-Content-Length is required", "badRequest") }
        guard let metadata = try? ProjectCodec.decode(JSONValue.self, from: body), metadata.objectValue != nil else {
            return Self.error(400, "The request body must be a video resource", "badRequest")
        }
        if uploadLimitExceededRemaining > 0 {
            uploadLimitExceededRemaining -= 1
            return Self.error(
                400, "The user has exceeded the number of videos they may upload.", "uploadLimitExceeded",
                domain: "youtube.video")
        }
        guard uploadsUsed < Self.uploadsLimit else { return quotaExceededResponse() }
        uploadsUsed += 1
        let uploadId = "fake-upload-\(next("upload"))"
        var components = URLComponents(string: "https://www.googleapis.com/upload/youtube/v3/videos")!
        var items = [
            URLQueryItem(name: "uploadType", value: "resumable"), URLQueryItem(name: "upload_id", value: uploadId),
        ]
        for key in ["part", "notifySubscribers"] {
            if let value = query[key] { items.append(URLQueryItem(name: key, value: value)) }
        }
        components.queryItems = items
        let uploadURL = components.url!
        sessions[uploadId] = UploadSession(
            id: uploadId, metadata: metadata, totalBytes: total, bytesConfirmed: 0, videoId: nil, query: query,
            expired: false, uploadURL: uploadURL)
        return Response(status: 200, headers: ["Location": uploadURL.absoluteString, "Content-Length": "0"])
    }

    private func upload(_ uploadId: String, request: URLRequest, bodyBytes: Int) -> Response {
        guard var session = sessions[uploadId], !session.expired else {
            return Self.error(404, "Upload session not found or expired", "notFound")
        }
        guard let parsed = Self.parseContentRange(request.value(forHTTPHeaderField: "Content-Range")) else {
            return Self.error(400, "Content-Range is required", "badRequest")
        }
        guard parsed.total == session.totalBytes else {
            return Self.error(400, "Content-Range total does not match the session", "badRequest")
        }
        guard let start = parsed.start, let end = parsed.end else {
            // Status query.
            return sessionStatus(&session)
        }
        if let fault = respondFault {
            respondFault = fault.remaining > 1 ? (fault.status, fault.remaining - 1) : nil
            var response = Self.error(fault.status, "Injected \(fault.status)", "backendError")
            response.headers.merge(retryAfterHeader()) { a, _ in a }
            return response
        }
        guard request.value(forHTTPHeaderField: "Content-Length") != nil else {
            return Self.error(400, "Content-Length is required", "badRequest")
        }
        guard start == session.bytesConfirmed else {
            return Self.error(
                400, "Chunk starts at \(start) but \(session.bytesConfirmed) bytes are confirmed", "invalid")
        }
        let length = end - start + 1
        guard Int64(bodyBytes) == length else {
            return Self.error(400, "Body has \(bodyBytes) bytes for a \(length)-byte range", "invalid")
        }
        let isFinal = end + 1 == session.totalBytes
        guard isFinal || length % Self.chunkGranularity == 0 else {
            return Self.error(400, "Non-final chunk of \(length) bytes is not a multiple of 262144", "invalid")
        }
        session.bytesConfirmed = end + 1
        acceptedChunks.append(start...end)
        return sessionStatus(&session)
    }

    private func sessionStatus(_ session: inout UploadSession) -> Response {
        defer { sessions[session.id] = session }
        if let videoId = session.videoId, let video = videos[videoId] { return Self.json(200, Self.resource(video)) }
        if session.bytesConfirmed >= session.totalBytes {
            let video = completeUpload(&session)
            return Self.json(201, Self.resource(video))
        }
        var headers = ["Content-Length": "0"]
        if session.bytesConfirmed > 0 { headers["Range"] = "bytes=0-\(session.bytesConfirmed - 1)" }
        return Response(status: 308, headers: headers)
    }

    private func completeUpload(_ session: inout UploadSession) -> Video {
        let id = "fake-video-\(next("video"))"
        let requested = session.metadata["status"]?["privacyStatus"]?.stringValue ?? "private"
        let privacy = forcePrivateEnabled ? "private" : requested
        var status = session.metadata["status"]?.objectValue ?? [:]
        status["privacyStatus"] = .string(privacy)
        status["uploadStatus"] = "uploaded"
        var video = Video(
            id: id, snippet: session.metadata["snippet"] ?? .object([:]), status: .object(status), privacy: privacy,
            uploadStatus: "uploaded", processingStatus: "processing", processingPollsLeft: processingPollsUntilDone,
            failureReason: nil, rejectionReason: nil)
        if processingPollsUntilDone == 0 { finishProcessing(&video) }
        videos[id] = video
        session.videoId = id
        return video
    }

    private func finishProcessing(_ video: inout Video) {
        if let scripted = scriptedProcessing {
            video.uploadStatus = scripted.uploadStatus
            video.processingStatus = scripted.uploadStatus == "failed" ? "failed" : "succeeded"
            if scripted.uploadStatus == "rejected" { video.rejectionReason = scripted.reason }
            if scripted.uploadStatus == "failed" { video.failureReason = scripted.reason }
        } else {
            video.uploadStatus = "processed"
            video.processingStatus = "succeeded"
        }
    }

    private func listVideos(query: [String: String]) -> Response {
        let ids = (query["id"] ?? "").split(separator: ",").map(String.init)
        var items: [JSONValue] = []
        for id in ids {
            guard var video = videos[id] else { continue }
            if video.uploadStatus == "uploaded" {
                if video.processingPollsLeft > 0 { video.processingPollsLeft -= 1 } else { finishProcessing(&video) }
                videos[id] = video
            }
            var status: [String: JSONValue] = [
                "uploadStatus": .string(video.uploadStatus), "privacyStatus": .string(video.privacy),
            ]
            if let reason = video.failureReason { status["failureReason"] = .string(reason) }
            if let reason = video.rejectionReason { status["rejectionReason"] = .string(reason) }
            var processing: [String: JSONValue] = ["processingStatus": .string(video.processingStatus)]
            if video.processingStatus == "processing" {
                processing["processingProgress"] = [
                    "partsTotal": 100, "partsProcessed": .number(Double(max(0, 100 - video.processingPollsLeft * 30))),
                    "timeLeftMs": .number(Double(video.processingPollsLeft * 1000)),
                ]
            }
            items.append([
                "kind": "youtube#video", "id": .string(id), "status": .object(status),
                "processingDetails": .object(processing),
            ])
        }
        return Self.json(
            200,
            [
                "kind": "youtube#videoListResponse", "items": .array(items),
                "pageInfo": [
                    "totalResults": .number(Double(items.count)), "resultsPerPage": .number(Double(items.count)),
                ],
            ])
    }

    private func deleteVideo(query: [String: String]) -> Response {
        guard let id = query["id"], videos.removeValue(forKey: id) != nil else {
            return Self.error(404, "Video not found.", "videoNotFound", domain: "youtube.video")
        }
        captions.removeAll { $0.videoId == id }
        thumbnails[id] = nil
        return Response(status: 204, headers: ["Content-Length": "0"])
    }

    private func setThumbnail(query: [String: String], bodyBytes: Int) -> Response {
        guard let id = query["videoId"], videos[id] != nil else {
            return Self.error(404, "Video not found.", "videoNotFound", domain: "youtube.thumbnail")
        }
        if forbidThumbnailRemaining > 0 {
            forbidThumbnailRemaining -= 1
            return Self.error(
                403, "The user is not permitted to set custom thumbnails.", "forbidden", domain: "youtube.thumbnail")
        }
        guard bodyBytes > 0 else { return Self.error(400, "Media body is required", "mediaBodyRequired") }
        guard bodyBytes <= 2 << 20 else { return Self.error(400, "The image is larger than 2 MB", "invalidImage") }
        thumbnails[id] = bodyBytes
        return Self.json(
            200,
            [
                "kind": "youtube#thumbnailSetResponse",
                "items": .array([
                    [
                        "default": [
                            "url": .string("https://i.ytimg.com/vi/\(id)/default.jpg"), "width": 120, "height": 90,
                        ]
                    ]
                ]),
            ])
    }

    private func insertCaption(request: URLRequest, body: Data) -> Response {
        guard let contentType = request.value(forHTTPHeaderField: "Content-Type"),
            let parts = Self.parseMultipart(body, contentType: contentType), parts.count >= 2,
            let snippet = try? ProjectCodec.decode(JSONValue.self, from: parts[0])["snippet"]
        else {
            return Self.error(
                400, "A multipart/related body with a snippet part and a media part is required", "badRequest")
        }
        guard let videoId = snippet["videoId"]?.stringValue, videos[videoId] != nil else {
            return Self.error(404, "Video not found.", "videoNotFound", domain: "youtube.caption")
        }
        let language = snippet["language"]?.stringValue ?? ""
        let name = snippet["name"]?.stringValue ?? ""
        guard !language.isEmpty else { return Self.error(400, "snippet.language is required", "invalidValue") }
        guard name.count <= 150 else { return Self.error(400, "snippet.name is too long", "invalidValue") }
        if captions.contains(where: { $0.videoId == videoId && $0.language == language && $0.name == name }) {
            return Self.error(
                409, "The caption track already exists.", "captionExists", domain: "youtube.caption", status: "ABORTED")
        }
        let id = "fake-caption-\(next("caption"))"
        captions.append(
            Caption(
                id: id, videoId: videoId, language: language, name: name,
                body: String(decoding: parts[1], as: UTF8.self)))
        return Self.json(
            200,
            [
                "kind": "youtube#caption", "id": .string(id),
                "snippet": [
                    "videoId": .string(videoId), "language": .string(language), "name": .string(name),
                    "trackKind": "standard", "isDraft": false, "status": "serving",
                ],
            ])
    }

    private func insertPlaylistItem(body: Data) -> Response {
        guard let snippet = (try? ProjectCodec.decode(JSONValue.self, from: body))?["snippet"],
            let playlistId = snippet["playlistId"]?.stringValue,
            let videoId = snippet["resourceId"]?["videoId"]?.stringValue
        else { return Self.error(400, "snippet.playlistId and snippet.resourceId.videoId are required", "badRequest") }
        guard videos[videoId] != nil else {
            return Self.error(404, "Video not found.", "videoNotFound", domain: "youtube.playlistItem")
        }
        let id = "fake-playlist-item-\(next("playlistItem"))"
        playlistItems.append(PlaylistItem(id: id, playlistId: playlistId, videoId: videoId))
        return Self.json(
            200,
            [
                "kind": "youtube#playlistItem", "id": .string(id),
                "snippet": [
                    "playlistId": .string(playlistId),
                    "resourceId": ["kind": "youtube#video", "videoId": .string(videoId)],
                ],
            ])
    }

    // MARK: Helpers

    private func next(_ counter: String) -> Int {
        counters[counter, default: 0] += 1
        return counters[counter]!
    }

    private func retryAfterHeader() -> [String: String] {
        guard let seconds = retryAfterSeconds else { return [:] }
        retryAfterSeconds = nil
        return ["Retry-After": String(seconds)]
    }

    private func record(_ request: URLRequest, bodyBytes: Int, dropped: Bool) {
        let keep = [
            "Content-Range", "Content-Length", "Content-Type", "X-Upload-Content-Length", "X-Upload-Content-Type",
        ]
        var headers: [String: String] = [:]
        for key in keep { if let value = request.value(forHTTPHeaderField: key) { headers[key] = value } }
        requests.append(
            RecordedRequest(
                method: request.httpMethod ?? "GET", host: request.url?.host() ?? "", path: request.url?.path() ?? "",
                query: Self.query(of: request.url), headers: headers,
                hasBearer: request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true,
                bodyBytes: bodyBytes, dropped: dropped))
    }

    static func resource(_ video: Video) -> JSONValue {
        ["kind": "youtube#video", "id": .string(video.id), "snippet": video.snippet, "status": video.status]
    }

    /// `bytes a-b/total` -> (a, b, total); `bytes */total` -> (nil, nil, total).
    static func parseContentRange(_ header: String?) -> (start: Int64?, end: Int64?, total: Int64)? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let rest = header.dropFirst("bytes ".count)
        let halves = rest.split(separator: "/", maxSplits: 1)
        guard halves.count == 2, let total = Int64(halves[1]) else { return nil }
        if halves[0] == "*" { return (nil, nil, total) }
        let bounds = halves[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start <= end else {
            return nil
        }
        return (start, end, total)
    }

    static func query(of url: URL?) -> [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    static func parseForm(_ body: Data) -> [String: String] {
        let text = String(decoding: body, as: UTF8.self)
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            result[String(key).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(key)] =
                value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
        }
        return result
    }

    /// The bodies of every part of a `multipart/related` (or `multipart/form-data`) body, in order.
    static func parseMultipart(_ body: Data, contentType: String) -> [Data]? {
        guard let boundaryRange = contentType.range(of: "boundary=") else { return nil }
        var boundary = String(contentType[boundaryRange.upperBound...])
        if let semicolon = boundary.firstIndex(of: ";") { boundary = String(boundary[..<semicolon]) }
        boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var cursor = body.startIndex
        var starts: [Data.Index] = []
        while let found = body.range(of: delimiter, in: cursor..<body.endIndex) {
            starts.append(found.lowerBound)
            cursor = found.upperBound
        }
        guard starts.count >= 2 else { return nil }
        for (a, b) in zip(starts, starts.dropFirst()) {
            var section = body[(a + delimiter.count)..<b]
            // Skip the line break after the delimiter, then the headers up to the blank line.
            if section.starts(with: Data("\r\n".utf8)) {
                section = section.dropFirst(2)
            } else if section.first == 0x0A {
                section = section.dropFirst()
            }
            let content: Data.SubSequence
            if let blank = section.range(of: Data("\r\n\r\n".utf8)) {
                content = section[blank.upperBound...]
            } else if let blank = section.range(of: Data("\n\n".utf8)) {
                content = section[blank.upperBound...]
            } else {
                content = section
            }
            var trimmed = Data(content)
            if trimmed.suffix(2) == Data("\r\n".utf8) {
                trimmed = trimmed.dropLast(2)
            } else if trimmed.last == 0x0A {
                trimmed = trimmed.dropLast()
            }
            parts.append(Data(trimmed))
        }
        return parts
    }

    static func canonicalScopes(_ scopes: [String]) -> String {
        scopes.map { scope in
            switch scope {
            case "email": "https://www.googleapis.com/auth/userinfo.email"
            case "profile": "https://www.googleapis.com/auth/userinfo.profile"
            default: scope
            }
        }.joined(separator: " ")
    }

    static func unsignedJWT(_ payload: JSONValue) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
        let body = (try? ProjectCodec.encode(payload)) ?? Data()
        return "\(base64url(header)).\(base64url(body))."
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func json(_ status: Int, _ value: JSONValue) -> Response {
        let body = (try? ProjectCodec.encode(value)) ?? Data()
        return Response(
            status: status,
            headers: ["Content-Type": "application/json; charset=UTF-8", "Content-Length": String(body.count)],
            body: body)
    }

    static func error(
        _ status: Int, _ message: String, _ reason: String, domain: String = "global", status statusName: String? = nil
    ) -> Response {
        let defaultName: String =
            switch status {
            case 400: "INVALID_ARGUMENT"
            case 401: "UNAUTHENTICATED"
            case 403: "PERMISSION_DENIED"
            case 404: "NOT_FOUND"
            case 409: "ABORTED"
            default: "INTERNAL"
            }
        let name = statusName ?? defaultName
        return json(
            status,
            [
                "error": [
                    "code": .number(Double(status)), "message": .string(message),
                    "errors": .array([
                        ["message": .string(message), "domain": .string(domain), "reason": .string(reason)]
                    ]), "status": .string(name),
                ]
            ])
    }

    static func unauthorized() -> Response {
        var response = error(
            401, "Request had invalid authentication credentials. Expected OAuth 2 access token.", "authError")
        response.headers["WWW-Authenticate"] = #"Bearer realm="https://accounts.google.com/", error="invalid_token""#
        return response
    }

    static func oauthError(_ status: Int, _ error: String, _ description: String) -> Response {
        json(status, ["error": .string(error), "error_description": .string(description)])
    }
}

extension FakeYouTubeServer.Response: Error {}

/// The `URLProtocol` half of `FakeYouTubeServer`: matches Google's hosts, finds the server through the
/// `X-Fake-YouTube-Server` header the session configuration adds, drains the body (an upload task's
/// `httpBodyStream` included), and answers with the server's response, or fails the request with
/// `URLError.networkConnectionLost` when a drop is armed.
public final class FakeYouTubeURLProtocol: URLProtocol, @unchecked Sendable {
    public static let serverHeader = "X-Fake-YouTube-Server"

    private struct LoaderRef: @unchecked Sendable { let loader: FakeYouTubeURLProtocol }

    private let stopped = Mutex(false)

    override public class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return FakeYouTubeServer.hosts.contains(host)
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let request = self.request
        // The protocol instance is only ever touched from this task once loading started; URLSession
        // holds it until `stopLoading`. The wrapper is what lets the task own it.
        let ref = LoaderRef(loader: self)
        Task.detached {
            let loader = ref.loader
            guard let id = request.value(forHTTPHeaderField: Self.serverHeader),
                let server = FakeYouTubeServer.registered(id)
            else {
                loader.fail(URLError(.cannotFindHost))
                return
            }
            let isChunk =
                request.httpMethod == "PUT"
                && FakeYouTubeServer.parseContentRange(request.value(forHTTPHeaderField: "Content-Range"))?.start != nil
            let limit = await server.dropLimit(for: request)
            let (data, bytes, dropped) = Self.readBody(request, limit: limit, keep: !isChunk)
            if dropped {
                await server.chunkDropped(request, forwarded: Int64(bytes))
                loader.fail(URLError(.networkConnectionLost))
                return
            }
            if isChunk { await server.bodyForwarded(Int64(bytes)) }
            let response = await server.handle(request, body: data, bodyBytes: bytes)
            loader.deliver(response, for: request)
        }
    }

    override public func stopLoading() { stopped.withLock { $0 = true } }

    private func deliver(_ response: FakeYouTubeServer.Response, for request: URLRequest) {
        guard !stopped.withLock({ $0 }), let url = request.url,
            let http = HTTPURLResponse(
                url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)
        else { return }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty { client?.urlProtocol(self, didLoad: response.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ error: URLError) {
        guard !stopped.withLock({ $0 }) else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    /// Reads the request body. With a `limit`, stops once that many bytes were read and reports a drop.
    /// `keep` false counts bytes without retaining them (video chunks).
    private static func readBody(_ request: URLRequest, limit: Int64?, keep: Bool) -> (Data, Int, Bool) {
        if let body = request.httpBody {
            if let limit, Int64(body.count) >= limit { return (Data(), Int(limit), true) }
            return (keep ? body : Data(), body.count, false)
        }
        guard let stream = request.httpBodyStream else { return (Data(), 0, false) }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var count = 0
        var buffer = [UInt8](repeating: 0, count: 256 << 10)
        while true {
            var wanted = buffer.count
            if let limit { wanted = Int(min(Int64(wanted), limit - Int64(count))) }
            if wanted <= 0 { return (data, count, true) }
            let n = stream.read(&buffer, maxLength: wanted)
            if n <= 0 { break }
            count += n
            if keep { data.append(buffer, count: n) }
            if let limit, Int64(count) >= limit { return (data, count, true) }
        }
        return (data, count, false)
    }
}
