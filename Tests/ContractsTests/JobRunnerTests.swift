import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@Suite struct FakeJobRunnerTests {
    @Test func progressStreamDeliversEveryReportThenEnds() async throws {
        let runner: any JobRunner = FakeJobRunner()
        let job = Job(kind: .hashing, memoryClass: .small, label: "Hash") { context in
            for i in 1...3 {
                context.report(JobProgress(fraction: Double(i) / 3, message: "chunk \(i)"))
            }
            return JobOutcome(payload: ["ok": true])
        }
        let handle = await runner.submit(job)
        var seen: [JobProgress] = []
        for await p in handle.progress { seen.append(p) }
        let fractions: [Double?] = [1.0 / 3, 2.0 / 3, 1]
        #expect(seen.map(\.fraction) == fractions)
        let outcome = try await handle.wait()
        #expect(outcome.payload?["ok"] == true)
        #expect(await runner.running().isEmpty)
    }

    @Test func cancellationStopsTheJob() async throws {
        let fake = FakeJobRunner()
        let runner: any JobRunner = fake
        let job = Job(kind: .transcription, memoryClass: .medium, label: "Transcribe") { context in
            var ticks = 0
            while true {
                try context.checkCancellation()
                ticks += 1
                context.report(JobProgress(fraction: nil, message: "tick \(ticks)"))
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let handle = await runner.submit(job)
        var iterator = handle.progress.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await runner.running() == [job.id])
        await runner.cancel(job.id)
        await #expect(throws: CancellationError.self) { try await handle.wait() }
        #expect(await fake.cancelled == [job.id])
        #expect(await runner.running().isEmpty)
        #expect(await fake.submissions.map(\.kind) == [.transcription])
    }

    @Test func handleCancelIsEquivalent() async throws {
        let runner = FakeJobRunner()
        let handle = await runner.submit(
            Job(kind: .analysis, memoryClass: .large, label: "Slow") { _ in
                try await Task.sleep(for: .seconds(30))
                return JobOutcome()
            })
        handle.cancel()
        await #expect(throws: CancellationError.self) { try await handle.wait() }
    }

    @Test func awaitCompletionModeReturnsFinishedHandles() async throws {
        let runner = FakeJobRunner(mode: .awaitCompletion)
        let handle = await runner.submit(
            Job(kind: .peaks, memoryClass: .small, label: "Peaks") { _ in JobOutcome(urls: [URL(fileURLWithPath: "/p")])
            })
        #expect(await runner.running().isEmpty)
        #expect(try await handle.wait().urls.count == 1)
    }

    @Test func failuresPropagate() async throws {
        let runner = FakeJobRunner()
        let handle = await runner.submit(
            Job(kind: .import, memoryClass: .small, label: "Import") { _ in
                throw JobError.failed(code: "io", message: "disk full")
            })
        await #expect(throws: JobError.failed(code: "io", message: "disk full")) { try await handle.wait() }
    }

    @Test func budgetDescribesClasses() {
        let job = Job(kind: .export, memoryClass: .medium, label: "x") { _ in JobOutcome() }
        #expect(JobBudget.conservative.bytes(for: job) == 2 << 30)
        var sized = job
        sized.estimatedBytes = 10
        #expect(JobBudget.conservative.bytes(for: sized) == 10)
        #expect(JobBudget.conservative.maxConcurrent[.large] == 1)
    }
}
