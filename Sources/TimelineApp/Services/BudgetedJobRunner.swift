import Contracts
import Foundation
import Synchronization
import TimelineCore

/// The context a `BudgetedJobRunner` hands to a job: progress fans out to every handle's stream (a
/// `Broadcaster`, so `handle(for:)` can open a fresh stream for a job a tool submitted earlier).
final class RunnerJobContext: JobContext, Sendable {
    let jobId: JobID
    private let broadcaster = Broadcaster<JobProgress>()
    private let last = Mutex<JobProgress?>(nil)

    init(jobId: JobID) {
        self.jobId = jobId
    }

    func report(_ progress: JobProgress) {
        last.withLock { $0 = progress }
        broadcaster.send(progress)
    }

    var isCancelled: Bool { Task.isCancelled }
    func checkCancellation() throws { try Task.checkCancellation() }
    var lastProgress: JobProgress? { last.withLock { $0 } }
    /// Every report after this call, ending when the job ends.
    func progressStream() -> AsyncStream<JobProgress> { broadcaster.subscribe() }
    func finish() { broadcaster.finish() }
}

/// The app's `JobRunner`: a FIFO queue admitted against a `JobBudget`. A job runs when its bytes fit
/// under `maxBytes` next to the running set and its memory class is under `maxConcurrent`; otherwise
/// it waits in submission order (a small job never jumps a large one, so nothing starves). A job that
/// could never fit is rejected. Cancellation before admission removes the job from the queue; after
/// admission it is the cooperative `Task` cancellation the contract describes.
actor BudgetedJobRunner: JobRunner {
    private struct Waiting {
        var job: Job
        var continuation: CheckedContinuation<Void, Never>
    }

    private struct Running {
        var bytes: Int64
        var memoryClass: MemoryClass
    }

    nonisolated let budget: JobBudget
    private var waiting: [Waiting] = []
    private var runningJobs: [JobID: Running] = [:]
    private var order: [JobID] = []
    private var tasks: [JobID: Task<JobOutcome, any Error>] = [:]
    /// Every submission, kept after completion so `handle(for:)` can answer for a finished job.
    private var records: [JobID: Record] = [:]
    /// Jobs cancelled before their continuation was registered.
    private var cancelledEarly: Set<JobID> = []
    private(set) var completed = 0

    private struct Record {
        var kind: JobKind
        var label: String
        var context: RunnerJobContext
        var task: Task<JobOutcome, any Error>
    }

    init(budget: JobBudget = .conservative) {
        self.budget = budget
    }

    var usedBytes: Int64 { runningJobs.values.reduce(0) { $0 + $1.bytes } }

    func submit(_ job: Job) -> JobHandle {
        let context = RunnerJobContext(jobId: job.id)
        let stream = context.progressStream()
        let id = job.id
        let task = Task<JobOutcome, any Error> { [weak self] in
            guard let self else { throw JobError.rejected(reason: "The job runner is gone") }
            do {
                try await self.admit(job)
            } catch {
                context.finish()
                await self.forget(id)
                throw error
            }
            let result: Result<JobOutcome, any Error>
            do {
                result = .success(try await job.run(context))
            } catch {
                result = .failure(error)
            }
            context.finish()
            await self.release(id)
            return try result.get()
        }
        tasks[id] = task
        records[id] = Record(kind: job.kind, label: job.label, context: context, task: task)
        return JobHandle(id: id, kind: job.kind, label: job.label, progress: stream, task: task)
    }

    func cancel(_ id: JobID) {
        tasks[id]?.cancel()
        dequeue(id)
    }

    func running() -> [JobID] { order.filter { runningJobs[$0] != nil } }

    func queued() -> [JobID] { waiting.map(\.job.id) }

    /// A handle over a submitted job: the same task, a fresh progress stream (reports after this call;
    /// a finished job yields an ended stream). Nil for an unknown id. What the window uses to track a
    /// job a tool submitted (`publish_youtube` answers with its `jobId`).
    func handle(for id: JobID) -> JobHandle? {
        guard let record = records[id] else { return nil }
        return JobHandle(
            id: id, kind: record.kind, label: record.label, progress: record.context.progressStream(),
            task: record.task)
    }

    /// Waits for every submitted job to end (the headless check).
    func drain() async {
        for task in tasks.values { _ = try? await task.value }
    }

    // MARK: Admission

    private func admit(_ job: Job) async throws {
        try Task.checkCancellation()
        let bytes = budget.bytes(for: job)
        guard bytes <= budget.maxBytes, (budget.maxConcurrent[job.memoryClass] ?? .max) > 0 else {
            throw JobError.rejected(
                reason: "\(job.label) needs \(bytes >> 20) MB, over the \(budget.maxBytes >> 20) MB budget")
        }
        if waiting.isEmpty, fits(job) {
            start(job)
            return
        }
        let id = job.id
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if cancelledEarly.remove(id) != nil {
                    continuation.resume()
                    return
                }
                waiting.append(Waiting(job: job, continuation: continuation))
            }
        } onCancel: {
            Task { await self.dequeue(id) }
        }
        try Task.checkCancellation()
        // Resumed by `pump`, which started the job before resuming.
    }

    private func fits(_ job: Job) -> Bool {
        let bytes = budget.bytes(for: job)
        let sameClass = runningJobs.values.filter { $0.memoryClass == job.memoryClass }.count
        return usedBytes + bytes <= budget.maxBytes && sameClass < (budget.maxConcurrent[job.memoryClass] ?? .max)
    }

    private func start(_ job: Job) {
        runningJobs[job.id] = Running(bytes: budget.bytes(for: job), memoryClass: job.memoryClass)
        order.append(job.id)
    }

    private func release(_ id: JobID) {
        runningJobs[id] = nil
        order.removeAll { $0 == id }
        tasks[id] = nil
        completed += 1
        pump()
    }

    private func forget(_ id: JobID) {
        tasks[id] = nil
        dequeue(id)
    }

    /// Admits waiting jobs in order while the head fits.
    private func pump() {
        while let head = waiting.first, fits(head.job) {
            waiting.removeFirst()
            start(head.job)
            head.continuation.resume()
        }
    }

    private func dequeue(_ id: JobID) {
        if let i = waiting.firstIndex(where: { $0.job.id == id }) {
            let entry = waiting.remove(at: i)
            entry.continuation.resume()
            pump()
        } else if runningJobs[id] == nil, tasks[id] != nil {
            cancelledEarly.insert(id)
        }
    }
}
