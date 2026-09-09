import Contracts
import Foundation
import TimelineCore

/// Tunables of the upload and the processing poll (publish-plan.md D5).
public struct UploadOptions: Sendable, Hashable {
    /// Non-final chunks must be a multiple of this.
    public static let chunkGranularity: Int64 = 262_144

    /// 32 MiB: a multiple of 256 KiB, small enough for memory class `.small`.
    public var chunkBytes: Int64
    /// Retries of one chunk before the job fails.
    public var maxAttempts: Int
    public var requestTimeout: TimeInterval
    /// The first backoff; doubles per attempt with jitter, capped at `maxBackoff`; `Retry-After` wins.
    public var backoffUnit: Duration
    public var maxBackoff: Duration
    /// Processing poll: 15 s doubling to 60 s, at most 20 polls.
    public var processingPollInitial: Duration
    public var processingPollMaximum: Duration
    public var maxProcessingPolls: Int

    public init(
        chunkBytes: Int64 = 32 << 20, maxAttempts: Int = 10, requestTimeout: TimeInterval = 120,
        backoffUnit: Duration = .seconds(1), maxBackoff: Duration = .seconds(64),
        processingPollInitial: Duration = .seconds(15), processingPollMaximum: Duration = .seconds(60),
        maxProcessingPolls: Int = 20
    ) {
        self.chunkBytes = chunkBytes
        self.maxAttempts = maxAttempts
        self.requestTimeout = requestTimeout
        self.backoffUnit = backoffUnit
        self.maxBackoff = maxBackoff
        self.processingPollInitial = processingPollInitial
        self.processingPollMaximum = processingPollMaximum
        self.maxProcessingPolls = maxProcessingPolls
    }

    /// Throws `PublishError.invalidRequest` unless `chunkBytes` is a positive multiple of 256 KiB.
    public func validate() throws {
        guard chunkBytes > 0, chunkBytes % Self.chunkGranularity == 0 else {
            throw PublishError.invalidRequest(
                "chunkBytes must be a positive multiple of \(Self.chunkGranularity), not \(chunkBytes)")
        }
        guard maxAttempts >= 1 else { throw PublishError.invalidRequest("maxAttempts must be at least 1") }
    }
}

/// Vends a bearer for the next request; `invalidating` is the token a 401 rejected, so the source
/// refreshes instead of answering from its cache.
public typealias TokenSource = @Sendable (_ invalidating: AccessToken?) async throws -> AccessToken

/// A sleeper the tests replace so backoff and polling take no wall time.
public typealias Sleeper = @Sendable (Duration) async throws -> Void

/// The resumable protocol's state machine (docs/research/11-youtube-upload.md section 2): chunked `PUT`s
/// with the next offset always taken from the `308 Range` header; on a 5xx or a connection error a
/// status query (`Content-Range: bytes */total`) then a resume with exponential backoff, at most
/// `maxAttempts`; `401` refreshes the token and resends the same chunk; `404` on the status query means
/// the session is gone (`PublishError.sessionExpired`). The session-start request is the publisher's
/// (`YouTubeAPI.startResumableUpload`); this type moves bytes.
public struct ResumableUpload: Sendable {
    public struct Outcome: Sendable {
        /// The video resource of the final `201`.
        public var video: JSONValue
        public var session: PublishSession
    }

    public let session: URLSession
    public let options: UploadOptions
    private let sleep: Sleeper
    private let clock: any Clock

    public init(
        session: URLSession, options: UploadOptions = UploadOptions(), clock: any Clock = SystemClock(),
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.session = session
        self.options = options
        self.clock = clock
        self.sleep = sleep
    }

    /// Uploads `fileURL` into `upload`. `resuming` true starts with a status query (the local count is
    /// never trusted after an interruption). `onSession` is called with every confirmed state (before the
    /// first byte when nothing is confirmed yet, after every chunk) and an ETA in seconds.
    public func run(
        fileURL: URL, upload: PublishSession, contentType: String, resuming: Bool, token: TokenSource,
        context: (any JobContext)?, onSession: @escaping @Sendable (PublishSession, Double?) async -> Void
    ) async throws -> Outcome {
        try options.validate()
        var state = upload
        let total = state.totalBytes
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var bearer = try await token(nil)
        var attempt = 0
        var refreshed = false
        let startedAt = clock.now()
        let startedFrom = state.bytesConfirmed

        if resuming {
            state.resumedCount += 1
            if let done = try await synchronize(&state, bearer: &bearer, refreshed: &refreshed, token: token) {
                return done
            }
            await onSession(state, nil)
        }

        while state.bytesConfirmed < total {
            try context?.checkCancellation()
            try Task.checkCancellation()
            let start = state.bytesConfirmed
            let length = min(options.chunkBytes, total - start)
            try handle.seek(toOffset: UInt64(start))
            guard let chunk = try handle.read(upToCount: Int(length)), Int64(chunk.count) == length else {
                throw PublishError.fileMissing(fileURL)
            }
            var request = URLRequest(url: state.uploadURL, timeoutInterval: options.requestTimeout)
            request.httpMethod = "PUT"
            request.setValue(bearer.authorizationHeader, forHTTPHeaderField: "Authorization")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("bytes \(start)-\(start + length - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            request.setValue(String(length), forHTTPHeaderField: "Content-Length")

            let response: YouTubeAPI.HTTPResponse
            do {
                response = try await YouTubeAPI(session: session, requestTimeout: options.requestTimeout).send(
                    request, body: chunk)
            } catch {
                // Connection error: query status, back off, resume.
                try await failure(&attempt, status: nil, retryAfter: nil, message: error.localizedDescription)
                if let done = try await synchronize(&state, bearer: &bearer, refreshed: &refreshed, token: token) {
                    return done
                }
                state.resumedCount += 1
                await onSession(state, eta(state, startedAt: startedAt, startedFrom: startedFrom))
                continue
            }

            switch response.status {
            case 308:
                let confirmed = Self.confirmedBytes(rangeHeader: response.header("Range"))
                if let location = response.header("Location").flatMap(URL.init(string:)) { state.uploadURL = location }
                guard confirmed > start else {
                    try await failure(&attempt, status: 308, retryAfter: nil, message: "308 without progress")
                    continue
                }
                state.bytesConfirmed = min(confirmed, total)
                attempt = 0
                await onSession(state, eta(state, startedAt: startedAt, startedFrom: startedFrom))
            case 200, 201:
                state.bytesConfirmed = total
                await onSession(state, 0)
                guard let video = response.json else {
                    throw PublishError.uploadFailed(status: response.status, reason: "final response without a body")
                }
                return Outcome(video: video, session: state)
            case 401:
                guard !refreshed else {
                    throw PublishError.reauthorizationRequired("the access token was rejected twice")
                }
                refreshed = true
                bearer = try await token(bearer)
            case 404:
                // Confirm with a status query; it throws `sessionExpired` when the session is gone.
                if let done = try await synchronize(&state, bearer: &bearer, refreshed: &refreshed, token: token) {
                    return done
                }
            case 500, 502, 503, 504:
                let apiError = response.error
                try await failure(
                    &attempt, status: apiError.status, retryAfter: apiError.retryAfter, message: apiError.message)
                if let done = try await synchronize(&state, bearer: &bearer, refreshed: &refreshed, token: token) {
                    return done
                }
                state.resumedCount += 1
                await onSession(state, eta(state, startedAt: startedAt, startedFrom: startedFrom))
            default:
                throw response.error.publishError(quotaResetsAt: nil)
            }
        }
        // Everything was confirmed by a status query but the final resource never arrived.
        if let done = try await synchronize(&state, bearer: &bearer, refreshed: &refreshed, token: token) {
            return done
        }
        throw PublishError.uploadFailed(status: 308, reason: "the server reports every byte but no video")
    }

    // MARK: Helpers

    /// Counts a failed attempt and sleeps the backoff; throws when the attempts are spent (`status` nil
    /// is a connection error).
    private func failure(_ attempt: inout Int, status: Int?, retryAfter: TimeInterval?, message: String) async throws {
        attempt += 1
        guard attempt < options.maxAttempts else {
            guard let status else { throw PublishError.network("gave up after \(attempt) attempts (\(message))") }
            throw PublishError.uploadFailed(status: status, reason: "gave up after \(attempt) attempts (\(message))")
        }
        try await sleep(Self.backoff(attempt: attempt, retryAfter: retryAfter, options: options))
    }

    /// `Retry-After` when present, else `unit * 2^(attempt-1)` with jitter in `[0.5, 1]`, capped.
    static func backoff(attempt: Int, retryAfter: TimeInterval?, options: UploadOptions) -> Duration {
        if let retryAfter, retryAfter > 0 { return .seconds(retryAfter) }
        let unit =
            Double(options.backoffUnit.components.seconds)
            + Double(options.backoffUnit.components.attoseconds) / 1e18
        let cap =
            Double(options.maxBackoff.components.seconds) + Double(options.maxBackoff.components.attoseconds) / 1e18
        let exponential = min(cap, unit * pow(2, Double(max(0, attempt - 1))))
        let jitter = 0.5 + Double.random(in: 0...0.5)
        return .seconds(exponential * jitter)
    }

    /// The status query. Returns the outcome when the upload had already completed; otherwise updates
    /// `state.bytesConfirmed` (and the session URI when Google moved it).
    private func synchronize(
        _ state: inout PublishSession, bearer: inout AccessToken, refreshed: inout Bool, token: TokenSource
    ) async throws -> Outcome? {
        var request = URLRequest(url: state.uploadURL, timeoutInterval: options.requestTimeout)
        request.httpMethod = "PUT"
        request.setValue(bearer.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("bytes */\(state.totalBytes)", forHTTPHeaderField: "Content-Range")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        var attempt = 0
        while true {
            let response: YouTubeAPI.HTTPResponse
            do {
                response = try await YouTubeAPI(session: session, requestTimeout: options.requestTimeout).send(
                    request, body: Data())
            } catch {
                try await failure(&attempt, status: nil, retryAfter: nil, message: error.localizedDescription)
                continue
            }
            switch response.status {
            case 308:
                state.bytesConfirmed = min(state.totalBytes, Self.confirmedBytes(rangeHeader: response.header("Range")))
                if let location = response.header("Location").flatMap(URL.init(string:)) { state.uploadURL = location }
                return nil
            case 200, 201:
                state.bytesConfirmed = state.totalBytes
                guard let video = response.json else {
                    throw PublishError.uploadFailed(status: response.status, reason: "final response without a body")
                }
                return Outcome(video: video, session: state)
            case 401:
                guard !refreshed else {
                    throw PublishError.reauthorizationRequired("the access token was rejected twice")
                }
                refreshed = true
                bearer = try await token(bearer)
                request.setValue(bearer.authorizationHeader, forHTTPHeaderField: "Authorization")
            case 404:
                throw PublishError.sessionExpired
            case 500, 502, 503, 504:
                let apiError = response.error
                try await failure(
                    &attempt, status: apiError.status, retryAfter: apiError.retryAfter, message: apiError.message)
            default:
                throw response.error.publishError(quotaResetsAt: nil)
            }
        }
    }

    /// `Range: bytes=0-N` means N+1 bytes are stored; no header means none.
    static func confirmedBytes(rangeHeader: String?) -> Int64 {
        guard let header = rangeHeader?.trimmingCharacters(in: .whitespaces), header.hasPrefix("bytes=") else {
            return 0
        }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let end = Int64(bounds[1]) else { return 0 }
        return end + 1
    }

    private func eta(_ state: PublishSession, startedAt: Date, startedFrom: Int64) -> Double? {
        let elapsed = clock.now().timeIntervalSince(startedAt)
        let moved = state.bytesConfirmed - startedFrom
        guard elapsed > 0, moved > 0 else { return nil }
        let rate = Double(moved) / elapsed
        return Double(state.totalBytes - state.bytesConfirmed) / rate
    }
}
