import Foundation
import TimelineCore

// MARK: - Request

public enum PublishDestination: String, Codable, Sendable, Hashable, CaseIterable { case youtube }

public enum PublishPrivacy: String, Codable, Sendable, Hashable, CaseIterable {
    case `private`
    case unlisted
    case `public`
}

public enum CaptionFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case srt
    case vtt
}

/// A JPEG or PNG on disk (YouTube: at most 2 MB, 16:9 or 9:16). `sourceTime` is set when the file was
/// grabbed from the sequence, so the card can say "frame at 12.4 s".
public struct PublishThumbnail: Hashable, Sendable, Codable {
    public var fileURL: URL
    public var sourceTime: RationalTime?

    public init(fileURL: URL, sourceTime: RationalTime? = nil) {
        self.fileURL = fileURL
        self.sourceTime = sourceTime
    }
}

/// One caption cue in timeline time (see `CaptionCues` in Captions.swift).
public struct CaptionCue: Hashable, Sendable, Codable {
    public var start: RationalTime
    public var end: RationalTime
    public var text: String

    public init(start: RationalTime, end: RationalTime, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct PublishCaptionTrack: Hashable, Sendable, Codable {
    public var trackId: TrackID?
    /// BCP-47.
    public var language: String
    /// At most 150 characters.
    public var name: String
    public var format: CaptionFormat
    public var cues: [CaptionCue]

    public init(
        trackId: TrackID? = nil, language: String, name: String, format: CaptionFormat = .srt, cues: [CaptionCue]
    ) {
        self.trackId = trackId
        self.language = language
        self.name = name
        self.format = format
        self.cues = cues
    }
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
    /// YouTube: 1-100 characters, no "<" or ">".
    public var title: String
    /// At most 5,000 bytes.
    public var description: String
    /// At most 500 characters in total.
    public var tags: [String]
    /// Assignable category id, e.g. "22".
    public var categoryId: String?
    /// `snippet.defaultLanguage`.
    public var language: String?
    /// Default `.private` (publish-plan.md D6).
    public var privacy: PublishPrivacy
    /// Requires `.private`.
    public var publishAt: Date?
    /// nil: not declared (the agent path); the sheet sets true or false (ToS 9.1, D9).
    public var madeForKids: Bool?
    /// Default false, always confirmed by the human.
    public var containsSyntheticMedia: Bool
    /// Default false.
    public var notifySubscribers: Bool
    public var recordingDate: Date?
    public var thumbnail: PublishThumbnail?
    public var captions: [PublishCaptionTrack]
    public var playlistId: String?
    /// From the render: what the Shorts warnings and the estimate use.
    public var durationSeconds: Double?
    public var width: Int?
    public var height: Int?

    public init(
        destination: PublishDestination = .youtube, accountId: String, renderId: String, fileURL: URL,
        expectedContentHash: String? = nil, projectVersion: Int64? = nil, title: String, description: String = "",
        tags: [String] = [], categoryId: String? = nil, language: String? = nil, privacy: PublishPrivacy = .private,
        publishAt: Date? = nil, madeForKids: Bool? = nil, containsSyntheticMedia: Bool = false,
        notifySubscribers: Bool = false, recordingDate: Date? = nil, thumbnail: PublishThumbnail? = nil,
        captions: [PublishCaptionTrack] = [], playlistId: String? = nil, durationSeconds: Double? = nil,
        width: Int? = nil, height: Int? = nil
    ) {
        self.destination = destination
        self.accountId = accountId
        self.renderId = renderId
        self.fileURL = fileURL
        self.expectedContentHash = expectedContentHash
        self.projectVersion = projectVersion
        self.title = title
        self.description = description
        self.tags = tags
        self.categoryId = categoryId
        self.language = language
        self.privacy = privacy
        self.publishAt = publishAt
        self.madeForKids = madeForKids
        self.containsSyntheticMedia = containsSyntheticMedia
        self.notifySubscribers = notifySubscribers
        self.recordingDate = recordingDate
        self.thumbnail = thumbnail
        self.captions = captions
        self.playlistId = playlistId
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
    }
}

// MARK: - Progress and outcome

/// Enough to continue an interrupted upload after a crash or relaunch. The upload URL is a capability
/// URL: it lives in the ledger only (`publishes.session`), never in a receipt, a tool output, or a log.
public struct PublishSession: Hashable, Sendable, Codable {
    public var uploadURL: URL
    public var totalBytes: Int64
    public var bytesConfirmed: Int64
    public var startedAt: Date
    public var resumedCount: Int

    public init(uploadURL: URL, totalBytes: Int64, bytesConfirmed: Int64 = 0, startedAt: Date, resumedCount: Int = 0) {
        self.uploadURL = uploadURL
        self.totalBytes = totalBytes
        self.bytesConfirmed = bytesConfirmed
        self.startedAt = startedAt
        self.resumedCount = resumedCount
    }

    /// `bytesConfirmed / totalBytes`, 0 for an empty total.
    public var fraction: Double { totalBytes > 0 ? Double(bytesConfirmed) / Double(totalBytes) : 0 }
}

public enum PublishStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case queued
    case uploading
    case processing
    case done
    case failed
    case cancelled

    public var isTerminal: Bool { self == .done || self == .failed || self == .cancelled }
}

/// The stages a publish job reports as `JobProgress.stage` (raw values), in order.
public enum PublishStage: String, Codable, Sendable, Hashable, CaseIterable {
    case verify
    case session
    case upload
    case processing
    case thumbnail
    case captions
    case playlist
}

/// What a running publish tells its owner, so the ledger can be kept current while the job runs.
public enum PublishEvent: Hashable, Sendable {
    /// Created, or bytes confirmed.
    case session(PublishSession)
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
    /// YouTube `videoId`.
    public var remoteId: String
    /// `https://youtu.be/<id>`.
    public var remoteURL: URL
    /// `https://studio.youtube.com/video/<id>/edit`.
    public var studioURL: URL?
    public var requestedPrivacy: PublishPrivacy
    /// As reported back by the API after upload (publish-plan.md D6).
    public var privacy: PublishPrivacy
    public var publishAt: Date?
    public var madeForKids: Bool?
    public var containsSyntheticMedia: Bool
    public var bytesUploaded: Int64
    public var resumedCount: Int
    public var thumbnailSet: Bool
    public var captionIds: [String]
    public var playlistItemId: String?
    /// uploaded | processed | failed | rejected.
    public var processingStatus: String?
    public var startedAt: Date
    public var finishedAt: Date
    public var warnings: [String]

    public init(
        publishId: String, destination: PublishDestination, accountId: String, channelId: String? = nil,
        channelTitle: String? = nil, renderId: String, contentHash: String, projectVersion: Int64? = nil,
        remoteId: String, remoteURL: URL, studioURL: URL? = nil, requestedPrivacy: PublishPrivacy,
        privacy: PublishPrivacy, publishAt: Date? = nil, madeForKids: Bool? = nil, containsSyntheticMedia: Bool,
        bytesUploaded: Int64, resumedCount: Int = 0, thumbnailSet: Bool = false, captionIds: [String] = [],
        playlistItemId: String? = nil, processingStatus: String? = nil, startedAt: Date, finishedAt: Date,
        warnings: [String] = []
    ) {
        self.publishId = publishId
        self.destination = destination
        self.accountId = accountId
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.renderId = renderId
        self.contentHash = contentHash
        self.projectVersion = projectVersion
        self.remoteId = remoteId
        self.remoteURL = remoteURL
        self.studioURL = studioURL
        self.requestedPrivacy = requestedPrivacy
        self.privacy = privacy
        self.publishAt = publishAt
        self.madeForKids = madeForKids
        self.containsSyntheticMedia = containsSyntheticMedia
        self.bytesUploaded = bytesUploaded
        self.resumedCount = resumedCount
        self.thumbnailSet = thumbnailSet
        self.captionIds = captionIds
        self.playlistItemId = playlistItemId
        self.processingStatus = processingStatus
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.warnings = warnings
    }
}

/// A `publishes` row (storage.md section 5 companion table; operational, never an event).
public struct PublishRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var renderId: String
    public var destination: PublishDestination
    public var accountId: String
    public var status: PublishStatus
    public var request: PublishRequest
    /// Kept while the upload can be resumed; dropped with `PublishUpdate.clearsSession` once it finished.
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

    public init(
        id: String, renderId: String, destination: PublishDestination, accountId: String, status: PublishStatus,
        request: PublishRequest, session: PublishSession? = nil, bytesTotal: Int64? = nil, bytesSent: Int64? = nil,
        remoteId: String? = nil, remoteURL: URL? = nil, projectVersion: Int64, receipt: PublishReceipt? = nil,
        error: String? = nil, requestedAt: Date, completedAt: Date? = nil
    ) {
        self.id = id
        self.renderId = renderId
        self.destination = destination
        self.accountId = accountId
        self.status = status
        self.request = request
        self.session = session
        self.bytesTotal = bytesTotal
        self.bytesSent = bytesSent
        self.remoteId = remoteId
        self.remoteURL = remoteURL
        self.projectVersion = projectVersion
        self.receipt = receipt
        self.error = error
        self.requestedAt = requestedAt
        self.completedAt = completedAt
    }

    /// A `failed` or `cancelled` row that still holds its session can continue where it stopped.
    public var isResumable: Bool { (status == .failed || status == .cancelled) && session != nil }
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

    public init(
        status: PublishStatus? = nil, session: PublishSession? = nil, clearsSession: Bool = false,
        bytesSent: Int64? = nil, remoteId: String? = nil, remoteURL: URL? = nil, receipt: PublishReceipt? = nil,
        error: String? = nil
    ) {
        self.status = status
        self.session = session
        self.clearsSession = clearsSession
        self.bytesSent = bytesSent
        self.remoteId = remoteId
        self.remoteURL = remoteURL
        self.receipt = receipt
        self.error = error
    }
}

// MARK: - Quota and capabilities

/// The daily allowance of the Google Cloud project (publish-plan.md D11): 100 `videos.insert` calls and
/// 10,000 units for everything else, both per Pacific day.
public struct PublishQuota: Hashable, Sendable, Codable {
    public var uploadsUsed: Int
    /// 100 per project per day.
    public var uploadsLimit: Int
    public var unitsUsed: Int
    /// 10,000 per project per day.
    public var unitsLimit: Int
    /// Next midnight Pacific.
    public var resetsAt: Date

    public init(uploadsUsed: Int, uploadsLimit: Int = 100, unitsUsed: Int, unitsLimit: Int = 10_000, resetsAt: Date) {
        self.uploadsUsed = uploadsUsed
        self.uploadsLimit = uploadsLimit
        self.unitsUsed = unitsUsed
        self.unitsLimit = unitsLimit
        self.resetsAt = resetsAt
    }

    public var uploadsRemaining: Int { max(0, uploadsLimit - uploadsUsed) }
    public var unitsRemaining: Int { max(0, unitsLimit - unitsUsed) }
}

public struct PublishCapabilities: Hashable, Sendable, Codable {
    /// False until the Google Cloud project has passed the YouTube compliance audit (publish-plan.md D6).
    public var publicUploadsAllowed: Bool
    public var note: String?

    public init(publicUploadsAllowed: Bool, note: String? = nil) {
        self.publicUploadsAllowed = publicUploadsAllowed
        self.note = note
    }

    /// The sentence the sheet, the card, and `account_status` show for an unaudited project.
    public static let unauditedNote =
        "Uploads from this Google Cloud project are private until it passes the YouTube compliance audit"
}

/// What `videos.list` reports about an uploaded video.
public struct RemotePublishStatus: Hashable, Sendable, Codable {
    /// uploaded | processed | failed | rejected | deleted.
    public var uploadStatus: String
    public var privacy: PublishPrivacy?
    public var processingStatus: String?
    public var failureReason: String?
    public var rejectionReason: String?

    public init(
        uploadStatus: String, privacy: PublishPrivacy? = nil, processingStatus: String? = nil,
        failureReason: String? = nil, rejectionReason: String? = nil
    ) {
        self.uploadStatus = uploadStatus
        self.privacy = privacy
        self.processingStatus = processingStatus
        self.failureReason = failureReason
        self.rejectionReason = rejectionReason
    }
}

// MARK: - Errors

public enum PublishError: Error, Hashable, Sendable, Codable {
    case invalidRequest(String)
    case fileMissing(URL)
    case hashMismatch(expected: String, found: String)
    case notConnected(String)
    case reauthorizationRequired(String)
    case quotaExceeded(resetsAt: Date?)
    /// `400 uploadLimitExceeded`: the channel's own daily allowance, separate from the project quota.
    case uploadLimitExceeded
    /// E.g. `thumbnails.set` on a channel without phone verification.
    case forbidden(String)
    case sessionExpired
    case uploadFailed(status: Int, reason: String)
    /// `status.rejectionReason` after processing.
    case rejected(reason: String)
    case processingFailed(String)
    case cancelled
    case network(String)

    public var message: String {
        switch self {
        case .invalidRequest(let reason): "Invalid publish request: \(reason)"
        case .fileMissing(let url): "The file to publish is missing: \(url.path)"
        case .hashMismatch(let expected, let found):
            "The file changed since it was rendered (expected \(expected), found \(found))"
        case .notConnected(let id): "No connected account with id \(id)"
        case .reauthorizationRequired(let detail): "Reconnect the account: \(detail)"
        case .quotaExceeded(let resetsAt):
            if let resetsAt {
                "The daily YouTube API quota is spent; it resets at \(resetsAt)"
            } else {
                "The daily YouTube API quota is spent"
            }
        case .uploadLimitExceeded: "The channel has reached its daily upload limit"
        case .forbidden(let detail): "Not permitted: \(detail)"
        case .sessionExpired: "The upload session expired"
        case .uploadFailed(let status, let reason): "Upload failed (\(status)): \(reason)"
        case .rejected(let reason): "YouTube rejected the video: \(reason)"
        case .processingFailed(let detail): "YouTube could not process the video: \(detail)"
        case .cancelled: "The publish was cancelled"
        case .network(let detail): "Network error: \(detail)"
        }
    }
}

extension PublishError: LocalizedError { public var errorDescription: String? { message } }

// MARK: - Protocol

/// One destination. `publish` returns the upload as a job (kind `.publish`, class `.small`); its
/// outcome payload is a `PublishReceipt`. `onEvent` is called from inside the job so the caller can
/// persist the session and the remote id as they appear; `resuming` continues a session from the
/// ledger. Progress: `fraction = bytesConfirmed / total` during upload, `stage` = a `PublishStage`
/// raw value, `etaSeconds` from the running rate.
///
/// Rules every implementation keeps:
/// - The job fetches its token from the `AccountProvider` per request and never puts it in an event,
///   a progress message, the receipt, or the outcome.
/// - `PublishEvent.session` is emitted before the first byte moves (so a crash resumes with a status
///   query, never a restart) and after every confirmed chunk; `.uploaded` follows the final chunk.
/// - A run with `resuming` starts from `bytesConfirmed` and reports `resumedCount + 1`.
/// - Optional steps (thumbnail, captions, playlist) fail as receipt warnings, never as job failures.
/// - Cancellation stops at a chunk boundary and leaves the last emitted session valid for a resume.
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
    func publish(
        _ request: PublishRequest, publishId: String, resuming: PublishSession?,
        onEvent: @escaping @Sendable (PublishEvent) async -> Void
    ) -> Job
    func remoteStatus(remoteId: String, accountId: String) async throws -> RemotePublishStatus
}
