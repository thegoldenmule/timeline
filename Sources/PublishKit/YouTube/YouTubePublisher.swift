import Contracts
import Foundation
import Synchronization
import TimelineCore

/// The YouTube `Publisher` (publish-plan.md section 4.1): a publish is a job of kind `.publish` whose
/// stages are verify (the file's hash matches the render's) -> session (`videos.insert`, resumable) ->
/// upload (`ResumableUpload`) -> processing poll -> thumbnail -> captions -> playlist. The optional
/// steps fail as receipt warnings, never as job failures. Tokens come from the `AccountProvider` per
/// request and never enter an event, the receipt, or the outcome.
public final class YouTubePublisher: Publisher, Sendable {
    public static let scopes = ["openid", "email", "https://www.googleapis.com/auth/youtube.force-ssl"]
    /// The rate `estimate` assumes before any upload has been measured: 5 MB/s.
    public static let defaultUploadRate: Double = 5_000_000

    public let destination: PublishDestination = .youtube
    public let requiredScopes: [String] = scopes

    private let accounts: any AccountProvider
    private let api: YouTubeAPI
    private let quota: QuotaMeter
    private let audited: Bool
    private let options: UploadOptions
    private let clock: any Clock
    private let sleep: Sleeper
    private let measuredRate: Mutex<Double>

    /// - Parameters:
    ///   - session: the `URLSession` every request goes through (`FakeYouTubeServer.sessionConfiguration()`
    ///     in tests).
    ///   - quota: the per-library-root meter (D11).
    ///   - audited: the client configuration's flag (D6); false keeps `publicUploadsAllowed` false.
    ///   - sleep: replaced in tests so backoff and the processing poll take no wall time; nil is `Task.sleep`,
    ///     formed in the body rather than as a default argument (a default-argument async closure trips the
    ///     task allocator once it suspends; docs/design/contracts-notes.md).
    public init(
        accounts: any AccountProvider, session: URLSession, quota: QuotaMeter, audited: Bool = false,
        options: UploadOptions = UploadOptions(), clock: any Clock = SystemClock(),
        sleep: Sleeper? = nil
    ) {
        self.accounts = accounts
        self.api = YouTubeAPI(session: session, requestTimeout: options.requestTimeout)
        self.quota = quota
        self.audited = audited
        self.options = options
        self.clock = clock
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
        self.measuredRate = Mutex(Self.defaultUploadRate)
    }

    /// Bytes per second of the last completed upload (or the default before one ran).
    public var uploadRate: Double { measuredRate.withLock { $0 } }

    // MARK: Publisher

    public func validate(_ request: PublishRequest) async throws -> [String] {
        try YouTubeValidation.validate(request)
    }

    public func estimate(_ request: PublishRequest) async -> Estimate {
        let bytes = Self.fileSize(request.fileURL) ?? 0
        return Estimate(seconds: Double(bytes) / uploadRate, usd: 0, bytes: bytes)
    }

    public func quota() async -> PublishQuota { await quota.snapshot() }

    public func capabilities() async -> PublishCapabilities {
        PublishCapabilities(publicUploadsAllowed: audited, note: audited ? nil : PublishCapabilities.unauditedNote)
    }

    public func publish(
        _ request: PublishRequest, publishId: String, resuming: PublishSession?,
        onEvent: @escaping @Sendable (PublishEvent) async -> Void
    ) -> Job {
        let bytes = Self.fileSize(request.fileURL)
        return Job(
            kind: .publish, memoryClass: .small, label: "Publish \(request.title)",
            estimatedBytes: bytes.map { min($0, 2 * options.chunkBytes) }
        ) { context in
            try await self.run(request, publishId: publishId, resuming: resuming, context: context, onEvent: onEvent)
        }
    }

    public func remoteStatus(remoteId: String, accountId: String) async throws -> RemotePublishStatus {
        let tokens = TokenBox(accounts: accounts, accountId: accountId, clock: clock)
        return try await authorized(tokens, units: YouTubeAPI.Cost.videosList) { token in
            try await self.api.videoStatus(token: token, videoId: remoteId)
        }
    }

    // MARK: The job

    private func run(
        _ request: PublishRequest, publishId: String, resuming: PublishSession?, context: any JobContext,
        onEvent: @escaping @Sendable (PublishEvent) async -> Void
    ) async throws -> JobOutcome {
        try options.validate()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "Uploading \(request.title) to YouTube")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let startedAt = resuming?.startedAt ?? clock.now()
        var warnings: [String] = []
        let tokens = TokenBox(accounts: accounts, accountId: request.accountId, clock: clock)

        func stage(_ stage: PublishStage, fraction: Double? = nil) async throws {
            try context.checkCancellation()
            context.report(JobProgress(fraction: fraction, stage: stage.rawValue))
            await onEvent(.stage(stage))
        }

        // verify
        try await stage(.verify)
        guard let total = Self.fileSize(request.fileURL) else { throw PublishError.fileMissing(request.fileURL) }
        let contentHash = try FileHash.sha256(of: request.fileURL)
        if let expected = request.expectedContentHash, expected != contentHash {
            throw PublishError.hashMismatch(expected: expected, found: contentHash)
        }
        let contentType = YouTubeAPI.contentType(for: request.fileURL)

        // session
        try await stage(.session)
        var session: PublishSession
        var isResume = false
        if let resuming, resuming.totalBytes == total {
            session = resuming
            isResume = true
        } else {
            session = try await startSession(request, tokens: tokens, total: total, contentType: contentType)
        }
        await onEvent(.session(session))

        // upload
        try await stage(.upload, fraction: session.fraction)
        let uploadStartedAt = clock.now()
        let uploadStartedFrom = session.bytesConfirmed
        let upload = ResumableUpload(session: api.session, options: options, clock: clock, sleep: sleep)
        let progress: @Sendable (PublishSession, Double?) async -> Void = { state, eta in
            context.report(JobProgress(fraction: state.fraction, stage: PublishStage.upload.rawValue, etaSeconds: eta))
            await onEvent(.session(state))
        }
        let tokenSource: TokenSource = { invalidating in try await tokens.token(invalidating: invalidating) }
        var outcome: ResumableUpload.Outcome
        do {
            outcome = try await upload.run(
                fileURL: request.fileURL, upload: session, contentType: contentType, resuming: isResume,
                token: tokenSource, context: context, onSession: progress)
        } catch PublishError.sessionExpired {
            // The session is gone: open a new one with the same metadata, once (publish-plan.md section 0).
            var fresh = try await startSession(request, tokens: tokens, total: total, contentType: contentType)
            fresh.resumedCount = session.resumedCount + 1
            fresh.startedAt = session.startedAt
            session = fresh
            await onEvent(.session(session))
            outcome = try await upload.run(
                fileURL: request.fileURL, upload: session, contentType: contentType, resuming: false,
                token: tokenSource, context: context, onSession: progress)
        } catch let error as YouTubeAPIError {
            throw await translate(error)
        }
        session = outcome.session
        let elapsed = clock.now().timeIntervalSince(uploadStartedAt)
        let moved = session.bytesConfirmed - uploadStartedFrom
        if elapsed > 0, moved > 0 { measuredRate.withLock { $0 = Double(moved) / elapsed } }

        guard let videoId = outcome.video["id"]?.stringValue, !videoId.isEmpty else {
            throw PublishError.uploadFailed(status: 201, reason: "the final response carries no video id")
        }
        let remoteURL = URL(string: "https://youtu.be/\(videoId)")!
        await onEvent(.uploaded(remoteId: videoId, remoteURL: remoteURL))
        var privacy =
            outcome.video["status"]?["privacyStatus"]?.stringValue.flatMap(PublishPrivacy.init(rawValue:))
            ?? request.privacy

        // processing
        try await stage(.processing, fraction: 1)
        var processingStatus: String?
        var interval = options.processingPollInitial
        var polls = 0
        pollLoop: while polls < options.maxProcessingPolls {
            try context.checkCancellation()
            polls += 1
            let status = try await authorized(tokens, units: YouTubeAPI.Cost.videosList) { token in
                try await self.api.videoStatus(token: token, videoId: videoId)
            }
            processingStatus = status.uploadStatus
            if let reported = status.privacy { privacy = reported }
            switch status.uploadStatus {
            case "processed": break pollLoop
            case "rejected": throw PublishError.rejected(reason: status.rejectionReason ?? "unspecified")
            case "failed": throw PublishError.processingFailed(status.failureReason ?? "unspecified")
            case "deleted": throw PublishError.processingFailed("the video is gone from YouTube")
            default:
                guard polls < options.maxProcessingPolls else { break pollLoop }
                try await sleep(interval)
                interval = min(interval * 2, options.processingPollMaximum)
            }
        }
        if processingStatus != "processed" {
            warnings.append("YouTube is still processing the video; check YouTube Studio for the result")
        }

        // thumbnail (optional)
        var thumbnailSet = false
        if let thumbnail = request.thumbnail {
            try await stage(.thumbnail, fraction: 1)
            do {
                let data = try Data(contentsOf: thumbnail.fileURL)
                let type = YouTubeValidation.thumbnailContentType(of: thumbnail.fileURL) ?? "image/jpeg"
                try await authorized(tokens, units: YouTubeAPI.Cost.thumbnailsSet) { token in
                    try await self.api.setThumbnail(token: token, videoId: videoId, imageData: data, contentType: type)
                }
                thumbnailSet = true
            } catch let error as PublishError where error == .cancelled {
                throw error
            } catch let error as YouTubeAPIError where error.status == 403 {
                warnings.append(
                    "Thumbnail not set: custom thumbnails need a phone-verified channel (youtube.com/verify): \(error.message)"
                )
            } catch {
                warnings.append("Thumbnail not set: \(Self.describe(error))")
            }
        }

        // captions (optional, one insert per track)
        var captionIds: [String] = []
        if !request.captions.isEmpty {
            try await stage(.captions, fraction: 1)
            for track in request.captions {
                let body: Data =
                    switch track.format {
                    case .srt: SRTWriter.data(for: track.cues)
                    case .vtt: VTTWriter.data(for: track.cues)
                    }
                do {
                    let id = try await authorized(tokens, units: YouTubeAPI.Cost.captionsInsert) { token in
                        try await self.api.insertCaption(
                            token: token, videoId: videoId, language: track.language, name: track.name, body: body)
                    }
                    captionIds.append(id)
                } catch let error as YouTubeAPIError where error.isConflict {
                    warnings.append("Caption track \"\(track.name)\" (\(track.language)) already exists on the video")
                } catch {
                    warnings.append(
                        "Caption track \"\(track.name)\" (\(track.language)) not added: \(Self.describe(error))")
                }
            }
        }

        // playlist (optional)
        var playlistItemId: String?
        if let playlistId = request.playlistId {
            try await stage(.playlist, fraction: 1)
            do {
                playlistItemId = try await authorized(tokens, units: YouTubeAPI.Cost.playlistItemsInsert) { token in
                    try await self.api.insertPlaylistItem(token: token, playlistId: playlistId, videoId: videoId)
                }
            } catch {
                warnings.append("Not added to playlist \(playlistId): \(Self.describe(error))")
            }
        }

        if privacy != request.privacy {
            if privacy == .private, !audited {
                warnings.append("Uploaded as private: project not audited")
            } else {
                warnings.append("YouTube reported privacy \(privacy.rawValue) instead of \(request.privacy.rawValue)")
            }
        }
        if request.madeForKids == nil {
            warnings.append("Audience not declared: set \"made for kids\" in YouTube Studio right after the upload")
        }

        let channel = await accounts.accounts().first { $0.id == request.accountId }
        let receipt = PublishReceipt(
            publishId: publishId, destination: .youtube, accountId: request.accountId, channelId: channel?.channelId,
            channelTitle: channel?.channelTitle, renderId: request.renderId, contentHash: contentHash,
            projectVersion: request.projectVersion, remoteId: videoId, remoteURL: remoteURL,
            studioURL: URL(string: "https://studio.youtube.com/video/\(videoId)/edit"),
            requestedPrivacy: request.privacy, privacy: privacy, publishAt: request.publishAt,
            madeForKids: request.madeForKids, containsSyntheticMedia: request.containsSyntheticMedia,
            bytesUploaded: total, resumedCount: session.resumedCount, thumbnailSet: thumbnailSet,
            captionIds: captionIds, playlistItemId: playlistItemId, processingStatus: processingStatus,
            startedAt: startedAt, finishedAt: clock.now(), warnings: warnings)
        context.report(.done)
        return try JobOutcome(encoding: receipt, warnings: warnings)
    }

    // MARK: Helpers

    /// `videos.insert`: refused locally when the day's uploads are spent; counts one upload once Google
    /// answered (failed starts count too).
    private func startSession(_ request: PublishRequest, tokens: TokenBox, total: Int64, contentType: String)
        async throws -> PublishSession
    {
        guard await quota.canUpload() else {
            throw PublishError.quotaExceeded(resetsAt: await quota.snapshot().resetsAt)
        }
        let uploadURL: URL
        do {
            uploadURL = try await authorized(tokens, units: 0) { token in
                try await self.api.startResumableUpload(
                    token: token, request: request, totalBytes: total, contentType: contentType)
            }
        } catch let error as YouTubeAPIError {
            if !error.isQuotaExceeded { await quota.recordUpload() }
            throw await translate(error)
        }
        await quota.recordUpload()
        return PublishSession(uploadURL: uploadURL, totalBytes: total, bytesConfirmed: 0, startedAt: clock.now())
    }

    /// Runs one API call with a token, refreshing once on `401`, charging the units on success, and
    /// marking the day exhausted on `403 quotaExceeded`. Rethrows `YouTubeAPIError` so callers can
    /// inspect the status; everything else is already a `PublishError`.
    @discardableResult
    private func authorized<T: Sendable>(
        _ tokens: TokenBox, units: Int, _ call: @Sendable (AccessToken) async throws -> T
    ) async throws -> T {
        var token = try await tokens.token(invalidating: nil)
        var refreshed = false
        while true {
            do {
                let result = try await call(token)
                await quota.record(units: units)
                return result
            } catch let error as YouTubeAPIError {
                if error.isUnauthorized, !refreshed {
                    refreshed = true
                    token = try await tokens.token(invalidating: token)
                    continue
                }
                if error.isQuotaExceeded { await quota.markExhausted() }
                throw error
            }
        }
    }

    private func translate(_ error: YouTubeAPIError) async -> PublishError {
        if error.isQuotaExceeded {
            await quota.markExhausted()
            return .quotaExceeded(resetsAt: await quota.snapshot().resetsAt)
        }
        return error.publishError(quotaResetsAt: nil)
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as YouTubeAPIError: "\(error.status) \(error.reason ?? ""): \(error.message)"
        case let error as PublishError: error.message
        case let error as AccountError: error.message
        default: error.localizedDescription
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }
}

/// Fetches tokens from the provider per request. `invalidating` asks for one that outlives the rejected
/// token, which makes the provider refresh instead of answering from its cache.
final class TokenBox: Sendable {
    static let minimumLifetime: Duration = .seconds(60)

    private let accounts: any AccountProvider
    private let accountId: String
    private let clock: any Clock

    init(accounts: any AccountProvider, accountId: String, clock: any Clock) {
        self.accounts = accounts
        self.accountId = accountId
        self.clock = clock
    }

    func token(invalidating: AccessToken?) async throws -> AccessToken {
        var minimum = Self.minimumLifetime
        if let invalidating {
            let remaining = invalidating.expiresAt.timeIntervalSince(clock.now())
            minimum = .seconds(max(60, remaining.rounded(.up) + 1))
        }
        do {
            return try await accounts.accessToken(for: accountId, minimumLifetime: minimum)
        } catch let error as AccountError {
            throw Self.translate(error)
        }
    }

    static func translate(_ error: AccountError) -> PublishError {
        switch error {
        case .reauthorizationRequired(let detail): .reauthorizationRequired(detail)
        case .notConnected(let id): .notConnected(id)
        case .notConfigured(let detail): .notConnected(detail)
        case .network(let detail): .network(detail)
        case .cancelled: .cancelled
        default: .network(error.message)
        }
    }
}
