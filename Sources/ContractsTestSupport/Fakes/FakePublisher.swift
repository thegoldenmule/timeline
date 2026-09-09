import Contracts
import Foundation
import Synchronization
import TimelineCore

/// A `Publisher` that runs the whole publish job in memory. Stages, in order: `verify` (`refuseHash`
/// throws `hashMismatch`; a missing file throws `fileMissing`), `session` (emits `.session` with
/// `totalBytes` = file size and a fake upload URL), `upload` in `uploadSteps` steps each emitting
/// `.session` with growing `bytesConfirmed`, `.uploaded(remoteId: "fake-video-<n>", ...)`,
/// `processing`, `thumbnail` if set, `captions` if any, `playlist` if set. `failAt` throws
/// `PublishError.network("injected")` once at that point; a run with `resuming` starts at its
/// `bytesConfirmed` and reports `resumedCount + 1`; `forcePrivate` makes the receipt's `privacy`
/// `.private` with the warning "Uploaded as private: project not audited". Every call is recorded.
public actor FakePublisher: Publisher {
    public struct PublishCall: Sendable, Hashable {
        public var request: PublishRequest
        public var publishId: String
        public var resuming: PublishSession?
    }

    private struct Records {
        var validated: [PublishRequest] = []
        var estimated: [PublishRequest] = []
        var publishCalls: [PublishCall] = []
        var events: [PublishEvent] = []
        var statusQueries: [(remoteId: String, accountId: String)] = []
        var videoCounter = 0
        var uploadCounter = 0
        var captionCounter = 0
    }

    public nonisolated let destination: PublishDestination = .youtube
    public nonisolated let requiredScopes: [String] = Fixtures.publishScopes

    public private(set) var warnOnValidate = false
    public private(set) var refuseHash = false
    public private(set) var forcePrivate = false
    public private(set) var failAt: (stage: PublishStage, fraction: Double)?
    public private(set) var uploadSteps = 5
    /// Pause between upload steps (default zero: a `Task.yield`), so a test can cancel mid-upload.
    public private(set) var stepDelay: Duration = .zero
    public private(set) var uploadRateBytesPerSecond: Double = 5_000_000
    public private(set) var quotaValue: PublishQuota
    public private(set) var capabilitiesValue = PublishCapabilities(
        publicUploadsAllowed: false, note: PublishCapabilities.unauditedNote)
    /// `remoteStatus` answers from here; unknown ids answer `uploadStatus: "deleted"`.
    public private(set) var remoteStatuses: [String: RemotePublishStatus] = [:]
    private let records = Mutex(Records())
    private let clock: any Clock

    /// Channel details every receipt carries, from the fixture account.
    public nonisolated let channelId: String? = Fixtures.connectedGoogleAccount.channelId
    public nonisolated let channelTitle: String? = Fixtures.connectedGoogleAccount.channelTitle

    public init(clock: any Clock = SystemClock()) {
        self.clock = clock
        quotaValue = PublishQuota(uploadsUsed: 0, unitsUsed: 0, resetsAt: clock.now().addingTimeInterval(86_400))
    }

    // MARK: Records

    public var validated: [PublishRequest] { records.withLock { $0.validated } }
    public var estimated: [PublishRequest] { records.withLock { $0.estimated } }
    /// Every `publish` call, in order, including resumes.
    public var publishCalls: [PublishCall] { records.withLock { $0.publishCalls } }
    /// Every event handed to `onEvent`, across every job.
    public var events: [PublishEvent] { records.withLock { $0.events } }
    public var statusQueries: [(remoteId: String, accountId: String)] { records.withLock { $0.statusQueries } }

    // MARK: Scripting

    public func setWarnOnValidate(_ on: Bool) { warnOnValidate = on }
    public func setRefuseHash(_ on: Bool) { refuseHash = on }
    public func setForcePrivate(_ on: Bool) { forcePrivate = on }
    /// Throws `network("injected")` once when the job reaches `stage` (for `upload`, at or after `fraction`).
    public func setFailAt(_ stage: PublishStage, fraction: Double = 0) { failAt = (stage, fraction) }
    public func setUploadSteps(_ steps: Int) { uploadSteps = max(1, steps) }
    public func setStepDelay(_ delay: Duration) { stepDelay = delay }
    public func setUploadRate(bytesPerSecond: Double) { uploadRateBytesPerSecond = bytesPerSecond }
    public func setQuota(_ quota: PublishQuota) { quotaValue = quota }
    public func setCapabilities(_ capabilities: PublishCapabilities) { capabilitiesValue = capabilities }
    public func setRemoteStatus(_ status: RemotePublishStatus, for remoteId: String) {
        remoteStatuses[remoteId] = status
    }

    // MARK: Publisher

    public func validate(_ request: PublishRequest) throws -> [String] {
        records.withLock { $0.validated.append(request) }
        if request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PublishError.invalidRequest("title is empty")
        }
        if request.publishAt != nil, request.privacy != .private {
            throw PublishError.invalidRequest("publishAt requires privacy private")
        }
        return warnOnValidate ? ["fake warning"] : []
    }

    public func estimate(_ request: PublishRequest) -> Estimate {
        records.withLock { $0.estimated.append(request) }
        let bytes = Self.fileSize(request.fileURL) ?? 0
        return Estimate(seconds: Double(bytes) / uploadRateBytesPerSecond, usd: 0, bytes: bytes)
    }

    public func quota() -> PublishQuota { quotaValue }

    public func capabilities() -> PublishCapabilities { capabilitiesValue }

    public nonisolated func publish(
        _ request: PublishRequest, publishId: String, resuming: PublishSession?,
        onEvent: @escaping @Sendable (PublishEvent) async -> Void
    ) -> Job {
        records.withLock {
            $0.publishCalls.append(PublishCall(request: request, publishId: publishId, resuming: resuming))
        }
        let label = "Publish \(request.title)"
        return Job(kind: .publish, memoryClass: .small, label: label) { context in
            try await self.run(request, publishId: publishId, resuming: resuming, context: context, onEvent: onEvent)
        }
    }

    public func remoteStatus(remoteId: String, accountId: String) throws -> RemotePublishStatus {
        records.withLock { $0.statusQueries.append((remoteId, accountId)) }
        return remoteStatuses[remoteId] ?? RemotePublishStatus(uploadStatus: "deleted")
    }

    // MARK: The job

    private func run(
        _ request: PublishRequest, publishId: String, resuming: PublishSession?, context: any JobContext,
        onEvent: @escaping @Sendable (PublishEvent) async -> Void
    ) async throws -> JobOutcome {
        let startedAt = clock.now()
        var warnings: [String] = []

        func emit(_ event: PublishEvent) async {
            records.withLock { $0.events.append(event) }
            await onEvent(event)
        }
        func stage(_ stage: PublishStage, fraction: Double? = nil) async throws {
            try context.checkCancellation()
            context.report(JobProgress(fraction: fraction, stage: stage.rawValue))
            await emit(.stage(stage))
            try takeFault(stage, fraction: fraction ?? 0)
        }

        // verify
        try await stage(.verify)
        guard let total = Self.fileSize(request.fileURL) else { throw PublishError.fileMissing(request.fileURL) }
        let contentHash = try FileHash.sha256(of: request.fileURL)
        if refuseHash {
            throw PublishError.hashMismatch(
                expected: request.expectedContentHash ?? "sha256-expected", found: contentHash)
        }

        // session
        try await stage(.session)
        var session: PublishSession
        if let resuming {
            session = resuming
            session.resumedCount += 1
            session.totalBytes = total
            session.bytesConfirmed = min(resuming.bytesConfirmed, total)
        } else {
            let n = records.withLock { r in
                r.uploadCounter += 1
                return r.uploadCounter
            }
            session = PublishSession(
                uploadURL: URL(
                    string:
                        "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=fake-upload-\(n)"
                )!, totalBytes: total, bytesConfirmed: 0, startedAt: startedAt, resumedCount: 0)
        }
        await emit(.session(session))

        // upload
        try context.checkCancellation()
        await emit(.stage(.upload))
        let from = session.bytesConfirmed
        let steps = uploadSteps
        for step in 1...steps {
            try context.checkCancellation()
            if stepDelay == .zero { await Task.yield() } else { try await Task.sleep(for: stepDelay) }
            session.bytesConfirmed = step == steps ? total : from + (total - from) * Int64(step) / Int64(steps)
            let fraction = session.fraction
            let remaining = Double(total - session.bytesConfirmed) / uploadRateBytesPerSecond
            context.report(JobProgress(fraction: fraction, stage: PublishStage.upload.rawValue, etaSeconds: remaining))
            try takeFault(.upload, fraction: fraction)
            await emit(.session(session))
        }
        let videoId = records.withLock { r in
            r.videoCounter += 1
            return "fake-video-\(r.videoCounter)"
        }
        let remoteURL = URL(string: "https://youtu.be/\(videoId)")!
        await emit(.uploaded(remoteId: videoId, remoteURL: remoteURL))

        // processing and the optional steps
        try await stage(.processing, fraction: 1)
        var thumbnailSet = false
        if request.thumbnail != nil {
            try await stage(.thumbnail, fraction: 1)
            thumbnailSet = true
        }
        var captionIds: [String] = []
        if !request.captions.isEmpty {
            try await stage(.captions, fraction: 1)
            captionIds = request.captions.map { _ in
                records.withLock { r in
                    r.captionCounter += 1
                    return "fake-caption-\(r.captionCounter)"
                }
            }
        }
        var playlistItemId: String?
        if let playlistId = request.playlistId {
            try await stage(.playlist, fraction: 1)
            playlistItemId = "fake-playlist-item-\(playlistId)-\(videoId)"
        }

        let privacy: PublishPrivacy
        if forcePrivate, request.privacy != .private {
            privacy = .private
            warnings.append("Uploaded as private: project not audited")
        } else {
            privacy = request.privacy
        }
        quotaValue.uploadsUsed += 1
        remoteStatuses[videoId] = RemotePublishStatus(
            uploadStatus: "processed", privacy: privacy, processingStatus: "succeeded")
        let receipt = PublishReceipt(
            publishId: publishId, destination: destination, accountId: request.accountId, channelId: channelId,
            channelTitle: channelTitle, renderId: request.renderId, contentHash: contentHash,
            projectVersion: request.projectVersion, remoteId: videoId, remoteURL: remoteURL,
            studioURL: URL(string: "https://studio.youtube.com/video/\(videoId)/edit"),
            requestedPrivacy: request.privacy, privacy: privacy, publishAt: request.publishAt,
            madeForKids: request.madeForKids, containsSyntheticMedia: request.containsSyntheticMedia,
            bytesUploaded: total, resumedCount: session.resumedCount, thumbnailSet: thumbnailSet,
            captionIds: captionIds, playlistItemId: playlistItemId, processingStatus: "processed", startedAt: startedAt,
            finishedAt: clock.now(), warnings: warnings)
        context.report(.done)
        return try JobOutcome(encoding: receipt, warnings: warnings)
    }

    private func takeFault(_ stage: PublishStage, fraction: Double) throws {
        guard let fault = failAt, fault.stage == stage, fraction >= fault.fraction else { return }
        failAt = nil
        throw PublishError.network("injected")
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }
}
