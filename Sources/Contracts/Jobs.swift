import Foundation
import TimelineCore

public enum JobTag: IDTag { public static let kind = "job" }
public typealias JobID = TypedID<JobTag>

/// What a job does; drives labels, telemetry, and per-kind concurrency limits.
public enum JobKind: String, Codable, Sendable, Hashable, CaseIterable {
    case export
    case transcription
    case alignment
    case hashing
    case `import`
    case analysis
    case thumbnails
    case peaks
    /// An upload to a `PublishDestination`; the outcome payload is a `PublishReceipt`.
    case publish
}

/// The memory a job needs while it runs, declared up front so the runner can enforce the budget from
/// the platform decisions ("design for 16 GB"): a transcription session is about 100-300 MB system-side,
/// an export holds a few frames plus the encoder, aligning a 2-hour recording peaks well under 1 GB
/// when envelopes stream, and a local LLM pass is `large`.
public enum MemoryClass: String, Codable, Sendable, Hashable, CaseIterable {
    /// Under ~256 MB: hashing, thumbnails, peaks, probes.
    case small
    /// Up to ~2 GB: export, transcription, alignment.
    case medium
    /// Several GB: local model inference, whole-file analysis.
    case large
}

/// Progress as reported by a job (named to avoid Foundation.Progress). `fraction` is nil while indeterminate.
public struct JobProgress: Hashable, Sendable, Codable {
    public var fraction: Double?
    public var message: String?
    public var stage: String?
    public var etaSeconds: Double?

    public init(fraction: Double? = nil, message: String? = nil, stage: String? = nil, etaSeconds: Double? = nil) {
        self.fraction = fraction
        self.message = message
        self.stage = stage
        self.etaSeconds = etaSeconds
    }

    public static let indeterminate = JobProgress()
    public static let done = JobProgress(fraction: 1)
}

/// What a finished job hands back: files it wrote and a typed payload encoded as JSON (an
/// `ImportResult`, an `ExportReceipt`, a `Transcript`, ...). Decode with `payload(as:)`.
public struct JobOutcome: Hashable, Sendable, Codable {
    public var urls: [URL]
    public var payload: JSONValue?
    public var warnings: [String]

    public init(urls: [URL] = [], payload: JSONValue? = nil, warnings: [String] = []) {
        self.urls = urls
        self.payload = payload
        self.warnings = warnings
    }

    public init<T: Encodable>(urls: [URL] = [], encoding value: T, warnings: [String] = []) throws {
        self.init(urls: urls, payload: try JSONValue(encoding: value), warnings: warnings)
    }

    public func payload<T: Decodable>(as type: T.Type) throws -> T? {
        try payload?.decoded(as: type)
    }
}

public enum JobError: Error, Hashable, Sendable, Codable {
    /// The runner refused the job (over budget, shutting down).
    case rejected(reason: String)
    /// The job body failed; `message` is for the user, `code` for logs.
    case failed(code: String, message: String)

    public var message: String {
        switch self {
        case .rejected(let reason): "Job rejected: \(reason)"
        case .failed(_, let message): message
        }
    }
}

extension JobError: LocalizedError {
    public var errorDescription: String? { message }
}

/// What a running job sees: report progress and cooperate with cancellation. The runner cancels the
/// task the job runs on, so `Task.checkCancellation()` works too; `checkCancellation()` is the same
/// thing spelled through the context for jobs that hop threads.
public protocol JobContext: Sendable {
    var jobId: JobID { get }
    func report(_ progress: JobProgress)
    var isCancelled: Bool { get }
    func checkCancellation() throws
}

/// A unit of background work. `run` is the whole job; everything else describes it for the queue and the UI.
/// Export, transcription, alignment, hashing, import copying, and analysis all run through a `JobRunner`,
/// never as bare `Task`s, so the memory budget and cancellation have one owner.
public struct Job: Sendable, Identifiable {
    public var id: JobID
    public var kind: JobKind
    public var memoryClass: MemoryClass
    public var label: String
    /// Rough memory this job needs, overriding the class default when known (bytes).
    public var estimatedBytes: Int64?
    public var run: @Sendable (any JobContext) async throws -> JobOutcome

    public init(
        id: JobID = JobID(minting: UUIDv7Generator()), kind: JobKind, memoryClass: MemoryClass, label: String,
        estimatedBytes: Int64? = nil, run: @escaping @Sendable (any JobContext) async throws -> JobOutcome
    ) {
        self.id = id
        self.kind = kind
        self.memoryClass = memoryClass
        self.label = label
        self.estimatedBytes = estimatedBytes
        self.run = run
    }
}

/// The runner's admission policy: never let the running set exceed `maxBytes` (classes cost their
/// `bytesPerClass` unless the job says otherwise) and never run more than `maxConcurrent[class]` at once.
public struct JobBudget: Hashable, Sendable, Codable {
    public var maxBytes: Int64
    public var maxConcurrent: [MemoryClass: Int]
    public var bytesPerClass: [MemoryClass: Int64]

    public init(maxBytes: Int64, maxConcurrent: [MemoryClass: Int], bytesPerClass: [MemoryClass: Int64]) {
        self.maxBytes = maxBytes
        self.maxConcurrent = maxConcurrent
        self.bytesPerClass = bytesPerClass
    }

    /// A budget for a 16 GB machine: 4 GB for jobs, one large job at a time.
    public static let conservative = JobBudget(
        maxBytes: 4 << 30, maxConcurrent: [.small: 8, .medium: 2, .large: 1],
        bytesPerClass: [.small: 256 << 20, .medium: 2 << 30, .large: 4 << 30])

    /// Unlimited, for tests.
    public static let unlimited = JobBudget(
        maxBytes: .max, maxConcurrent: [.small: .max, .medium: .max, .large: .max],
        bytesPerClass: [.small: 0, .medium: 0, .large: 0])

    public func bytes(for job: Job) -> Int64 { job.estimatedBytes ?? bytesPerClass[job.memoryClass] ?? 0 }
}

/// The caller's view of a submitted job. `progress` is one stream per handle (buffered, finishes when the
/// job ends); `wait()` returns the outcome or rethrows the job's error (`CancellationError` when cancelled).
public struct JobHandle: Sendable, Identifiable {
    public var id: JobID
    public var kind: JobKind
    public var label: String
    public var progress: AsyncStream<JobProgress>
    public var task: Task<JobOutcome, any Error>

    public init(
        id: JobID, kind: JobKind, label: String, progress: AsyncStream<JobProgress>, task: Task<JobOutcome, any Error>
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.progress = progress
        self.task = task
    }

    public func wait() async throws -> JobOutcome { try await task.value }
    public func cancel() { task.cancel() }
}

/// Runs `Job`s under a `JobBudget`. Submission never blocks: a job over budget queues until room frees
/// up. Cancellation is cooperative: the job's task is cancelled and it should stop at its next check.
public protocol JobRunner: Sendable {
    var budget: JobBudget { get async }
    func submit(_ job: Job) async -> JobHandle
    func cancel(_ id: JobID) async
    /// Jobs currently executing (not the queued ones).
    func running() async -> [JobID]
    /// Jobs admitted but waiting for budget.
    func queued() async -> [JobID]
    /// A handle over a job this runner knows (queued, running, or finished), so a job submitted by a
    /// tool can be tracked by the app's job list. The returned handle shares the job's task and gets a
    /// fresh progress stream; only one consumer should read each stream. Default: nil.
    func handle(for id: JobID) async -> JobHandle?
}

extension JobRunner {
    public func handle(for id: JobID) async -> JobHandle? { nil }
}
