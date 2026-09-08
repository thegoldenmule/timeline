import Contracts
import Foundation
import Synchronization
import TimelineCore

/// The context a `FakeJobRunner` hands to a job: progress goes to the handle's stream and is recorded.
public final class FakeJobContext: JobContext, Sendable {
    public let jobId: JobID
    private let continuation: AsyncStream<JobProgress>.Continuation
    private let reports = Mutex<[JobProgress]>([])

    public init(jobId: JobID, continuation: AsyncStream<JobProgress>.Continuation) {
        self.jobId = jobId
        self.continuation = continuation
    }

    public func report(_ progress: JobProgress) {
        reports.withLock { $0.append(progress) }
        continuation.yield(progress)
    }

    public var isCancelled: Bool { Task.isCancelled }
    public func checkCancellation() throws { try Task.checkCancellation() }

    public var reported: [JobProgress] { reports.withLock { $0 } }

    func finish() { continuation.finish() }
}

/// Runs jobs as `Task`s, honours cancellation, records every submission. `Mode.awaitCompletion` makes
/// `submit` return only after the job finished, for deterministic tests; `.concurrent` is the real shape.
public actor FakeJobRunner: JobRunner {
    public enum Mode: Sendable {
        case concurrent
        case awaitCompletion
    }

    public struct Submission: Sendable, Hashable {
        public var id: JobID
        public var kind: JobKind
        public var memoryClass: MemoryClass
        public var label: String
    }

    public let budget: JobBudget
    public let mode: Mode
    public private(set) var submissions: [Submission] = []
    public private(set) var contexts: [JobID: FakeJobContext] = [:]
    private var tasks: [JobID: Task<JobOutcome, any Error>] = [:]
    private var runningIds: [JobID] = []
    public private(set) var cancelled: [JobID] = []

    public init(mode: Mode = .concurrent, budget: JobBudget = .unlimited) {
        self.mode = mode
        self.budget = budget
    }

    public func submit(_ job: Job) async -> JobHandle {
        submissions.append(Submission(id: job.id, kind: job.kind, memoryClass: job.memoryClass, label: job.label))
        let (stream, continuation) = AsyncStream<JobProgress>.makeStream(bufferingPolicy: .unbounded)
        let context = FakeJobContext(jobId: job.id, continuation: continuation)
        contexts[job.id] = context
        runningIds.append(job.id)
        let id = job.id
        let task = Task<JobOutcome, any Error> { [weak self] in
            let result: Result<JobOutcome, any Error>
            do {
                result = .success(try await job.run(context))
            } catch {
                result = .failure(error)
            }
            context.finish()
            await self?.finished(id)
            return try result.get()
        }
        tasks[job.id] = task
        let handle = JobHandle(id: job.id, kind: job.kind, label: job.label, progress: stream, task: task)
        if mode == .awaitCompletion { _ = try? await task.value }
        return handle
    }

    public func cancel(_ id: JobID) {
        cancelled.append(id)
        tasks[id]?.cancel()
    }

    public func running() -> [JobID] { runningIds }
    public func queued() -> [JobID] { [] }

    /// Waits for every submitted job to end (success, failure, or cancellation).
    public func drain() async {
        for task in tasks.values { _ = try? await task.value }
    }

    private func finished(_ id: JobID) {
        runningIds.removeAll { $0 == id }
    }
}
