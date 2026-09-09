import Contracts
import ContractsTestSupport
import Foundation
import Synchronization
import Testing
import TimelineCore

@testable import PublishKit

@Suite struct ResumableUploadTests {
    @Test func uploads5MiBIn1MiBChunksWith308RangeDrivingTheOffset() async throws {
        let harness = try await PublishHarness(label: "chunks")
        let request = try harness.request(captions: false)
        let (receipt, events) = try await harness.publish(request)
        #expect(receipt.remoteId == "fake-video-1" && receipt.bytesUploaded == 5 * mib && receipt.resumedCount == 0)
        let chunks = await harness.server.chunkRequests
        #expect(chunks.count == 5 && chunks.allSatisfy { $0.headers["Content-Length"] == String(mib) })
        let expectedRanges = (Int64(0)..<5).map { "bytes \($0 * mib)-\(($0 + 1) * mib - 1)/\(5 * mib)" }
        #expect(chunks.compactMap(\.contentRange) == expectedRanges)
        #expect(await harness.server.acceptedChunks == (Int64(0)..<5).map { ($0 * mib)...(($0 + 1) * mib - 1) })
        #expect(await harness.server.statusQueries.isEmpty)
        // One session event before the first byte, then one per confirmed chunk, monotonic.
        let confirmed = events.sessions.map(\.bytesConfirmed)
        #expect(confirmed == [0, mib, 2 * mib, 3 * mib, 4 * mib, 5 * mib])
        #expect(events.sessions.allSatisfy { $0.totalBytes == 5 * mib })
        let start = try #require(
            await harness.server.requests.first { $0.path == "/upload/youtube/v3/videos" && $0.method == "POST" })
        #expect(
            start.headers["X-Upload-Content-Length"] == String(5 * mib)
                && start.headers["X-Upload-Content-Type"] == "video/mp4")
        #expect(await harness.server.uploadsUsed == 1)
    }

    @Test func resumesAfterADroppedConnectionWithoutResendingConfirmedBytes() async throws {
        let harness = try await PublishHarness(label: "drop")
        let request = try harness.request(captions: false)
        await harness.server.dropConnection(afterBytes: 2 * mib)
        let (receipt, events) = try await harness.publish(request)
        #expect(receipt.resumedCount == 1 && receipt.remoteId == "fake-video-1")
        #expect(await harness.server.statusQueries.count == 1)
        #expect(await !harness.server.hasOverlappingChunks)
        let chunks = await harness.server.chunkRequests
        #expect(chunks.filter(\.dropped).count == 1 && chunks.count == 5)
        #expect(await harness.server.acceptedChunks.map(\.lowerBound) == [0, 2 * mib, 3 * mib, 4 * mib])
        #expect(events.sessions.map(\.bytesConfirmed) == [0, mib, 2 * mib, 3 * mib, 4 * mib, 5 * mib])
        #expect(events.sessions.last?.resumedCount == 1)
        // One backoff before the status query; the rest are the processing poll's 15 s and 30 s.
        #expect(
            harness.sleeps.durations.count == 3 && harness.sleeps.durations.dropFirst() == [.seconds(15), .seconds(30)])
        #expect(harness.sleeps.durations[0] <= .milliseconds(1))
    }

    @Test func resumesFromAPersistedSessionAfterASimulatedRelaunch() async throws {
        let harness = try await PublishHarness(label: "relaunch", maxAttempts: 3)
        let request = try harness.request(captions: false)
        // Once 2 MiB are confirmed, the next three chunk PUTs answer 503: the attempts are spent.
        let server = harness.server
        let first = await harness.submit(request) { event in
            if case .session(let session) = event, session.bytesConfirmed == 2 * mib, session.resumedCount == 0 {
                await server.respond(status: 503, times: 3)
            }
        }
        await #expect(throws: PublishError.uploadFailed(status: 503, reason: "gave up after 3 attempts (Injected 503)"))
        {
            _ = try await first.handle.wait()
        }
        let persisted = try #require(first.events.sessions.last)
        #expect(persisted.bytesConfirmed == 2 * mib && persisted.resumedCount == 2, "two in-job resumes")
        #expect(await server.statusQueries.count == 2, "one status query per failed attempt before giving up")

        // A new publisher (the app relaunched) continues from the ledger's session.
        let queriesBefore = await server.statusQueries.count
        let second = await harness.submit(request, resuming: persisted, publisher: harness.relaunchedPublisher())
        let receipt = try await second.receipt()
        #expect(receipt.resumedCount == 3 && receipt.remoteId == "fake-video-1" && receipt.bytesUploaded == 5 * mib)
        #expect(await server.statusQueries.count == queriesBefore + 1)
        #expect(await !server.hasOverlappingChunks)
        #expect(await server.acceptedChunks.map(\.lowerBound) == [0, mib, 2 * mib, 3 * mib, 4 * mib])
        #expect(second.events.sessions.first?.bytesConfirmed == 2 * mib)
        #expect(second.events.sessions.first?.resumedCount == 2, "the ledger's count, before the resume")
        #expect(second.events.sessions.last?.resumedCount == 3)
        #expect(await server.uploadsUsed == 1, "no new session was opened")
    }

    @Test func retriesOn503WithBackoffAndGivesUpAfterTenAttempts() async throws {
        let harness = try await PublishHarness(label: "503")
        let request = try harness.request(bytes: 2 * mib, captions: false)
        await harness.server.respond(status: 503, times: 20)
        let run = await harness.submit(request)
        do {
            _ = try await run.handle.wait()
            Issue.record("expected uploadFailed")
        } catch PublishError.uploadFailed(let status, let reason) {
            #expect(status == 503 && reason.contains("after 10 attempts"))
        }
        let chunks = await harness.server.chunkRequests
        #expect(chunks.count == 10 && chunks.allSatisfy { $0.contentRange == "bytes 0-\(mib - 1)/\(2 * mib)" })
        #expect(await harness.server.statusQueries.count == 9)
        let sleeps = harness.sleeps.durations
        #expect(sleeps.count == 9)
        #expect(zip(sleeps, sleeps.dropFirst()).allSatisfy { $0 <= $1 }, "\(sleeps)")
        #expect(sleeps[8] >= sleeps[0] * 64, "exponential: attempt 9 is at least 2^6 times attempt 1 with jitter")
        #expect(sleeps.allSatisfy { $0 <= .milliseconds(256) })
        #expect(run.events.sessions.map(\.bytesConfirmed).allSatisfy { $0 == 0 })
    }

    @Test func honoursRetryAfter() async throws {
        let harness = try await PublishHarness(label: "retry-after")
        let request = try harness.request(bytes: 2 * mib, captions: false)
        await harness.server.retryAfter(seconds: 7)
        await harness.server.respond(status: 503, times: 1)
        let (receipt, _) = try await harness.publish(request)
        #expect(receipt.remoteId == "fake-video-1" && receipt.resumedCount == 1)
        #expect(harness.sleeps.durations == [.seconds(7), .seconds(15), .seconds(30)], "Retry-After, then the poll")
        #expect(await harness.server.chunkRequests.count == 3)
        #expect(await harness.server.statusQueries.count == 1)
        #expect(ResumableUpload.backoff(attempt: 1, retryAfter: 3, options: harness.options) == .seconds(3))
        let plain = ResumableUpload.backoff(
            attempt: 4, retryAfter: nil, options: UploadOptions(backoffUnit: .seconds(1)))
        #expect(plain >= .seconds(4) && plain <= .seconds(8))
        let capped = ResumableUpload.backoff(
            attempt: 30, retryAfter: nil, options: UploadOptions(maxBackoff: .seconds(64)))
        #expect(capped <= .seconds(64) && capped >= .seconds(32))
    }

    @Test func refreshesA401MidUploadAndResendsTheSameChunk() async throws {
        let harness = try await PublishHarness(label: "401")
        let request = try harness.request(bytes: 3 * mib, captions: false)
        let server = harness.server
        // The second chunk is rejected as unauthorized once.
        let run = await harness.submit(request) { event in
            if case .session(let session) = event, session.bytesConfirmed == mib {
                await server.respond(status: 401, times: 1)
            }
        }
        let receipt = try await run.receipt()
        #expect(receipt.remoteId == "fake-video-1" && receipt.resumedCount == 0)
        let chunks = await server.chunkRequests
        #expect(chunks.count == 4)
        #expect(chunks[1].contentRange == chunks[2].contentRange, "the same chunk was resent")
        #expect(await !server.hasOverlappingChunks)
        #expect(await server.statusQueries.isEmpty)
        // One token, then one refresh after the 401: the upload asked for a token that outlives the
        // rejected one, which the provider cannot serve from its cache.
        #expect(await harness.accounts.tokenRequests == 2)
        #expect(harness.sleeps.durations == [.seconds(15), .seconds(30)], "no backoff, only the poll")

        // The processing poll refreshes on a 401 the same way.
        let second = try await PublishHarness(label: "401-poll")
        let poll = try second.request(bytes: mib, captions: false)
        let secondServer = second.server
        let pollRun = await second.submit(poll) { event in
            if case .uploaded = event { await secondServer.expireAccessTokensNow() }
        }
        #expect(try await pollRun.receipt().processingStatus == "processed")
        #expect(await second.accounts.tokenRequests == 2)
        #expect(await secondServer.requests.filter { $0.path == "/youtube/v3/videos" }.count == 4)
    }

    @Test func quotaExceededFailsWithResetTime() async throws {
        let harness = try await PublishHarness(label: "quota")
        let request = try harness.request(bytes: mib, captions: false)
        await harness.server.quotaExceeded()
        let run = await harness.submit(request)
        do {
            _ = try await run.handle.wait()
            Issue.record("expected quotaExceeded")
        } catch PublishError.quotaExceeded(let resetsAt) {
            let reset = try #require(resetsAt)
            #expect(reset > Date() && reset <= Date().addingTimeInterval(86_400 + 60))
            #expect(reset == QuotaMeter.resetsAt(after: Date()))
        }
        // The day is marked exhausted locally: the next publish is refused before any request.
        let quota = await harness.publisher.quota()
        #expect(quota.uploadsRemaining == 0 && quota.unitsRemaining == 0)
        let requests = await harness.server.requests.count
        let again = await harness.submit(try harness.request(bytes: mib, captions: false, name: "two.mp4"))
        await #expect(throws: PublishError.self) { _ = try await again.handle.wait() }
        #expect(await harness.server.requests.count == requests)
        #expect(run.events.stages == [.verify, .session] && run.events.sessions.isEmpty)
    }

    @Test func uploadLimitExceededFails() async throws {
        let harness = try await PublishHarness(label: "upload-limit")
        let request = try harness.request(bytes: mib, captions: false)
        await harness.server.uploadLimitExceeded()
        let run = await harness.submit(request)
        await #expect(throws: PublishError.uploadLimitExceeded) { _ = try await run.handle.wait() }
        #expect(run.events.sessions.isEmpty)
        // The channel's limit is not the project's quota: a failed insert still counts one call here.
        #expect(await harness.publisher.quota().uploadsUsed == 1)
        #expect(await harness.publisher.quota().uploadsRemaining == 99)
    }

    @Test func expiredSessionOpensANewOneOnce() async throws {
        let harness = try await PublishHarness(label: "expired")
        let request = try harness.request(captions: false)
        let server = harness.server
        let expired = Mutex(0)
        // The first session dies once 2 MiB are in; the publisher opens a second one.
        let run = await harness.submit(request) { event in
            if case .session(let session) = event, session.bytesConfirmed == 2 * mib,
                session.uploadURL.absoluteString.contains("fake-upload-1")
            {
                expired.withLock { $0 += 1 }
                await server.expireSession()
            }
        }
        let receipt = try await run.receipt()
        #expect(receipt.remoteId == "fake-video-1" && receipt.resumedCount == 1 && receipt.bytesUploaded == 5 * mib)
        #expect(expired.withLock { $0 } == 1)
        #expect(await server.uploadsUsed == 2)
        let urls = Set(run.events.sessions.map(\.uploadURL))
        #expect(urls.count == 2)
        #expect(run.events.sessions.last?.uploadURL.absoluteString.contains("fake-upload-2") == true)
        #expect(await server.statusQueries.count == 1, "the 404 came from the status query after the chunk failed")
        #expect(await server.acceptedChunks.filter { $0.lowerBound == 0 }.count == 2, "the new session starts over")

        // A second expiry fails the job with sessionExpired.
        let second = try await PublishHarness(label: "expired-twice")
        let secondServer = second.server
        let twice = await second.submit(try second.request(captions: false)) { event in
            if case .session(let session) = event, session.bytesConfirmed == 2 * mib {
                await secondServer.expireSession()
            }
        }
        await #expect(throws: PublishError.sessionExpired) { _ = try await twice.handle.wait() }
        #expect(await secondServer.uploadsUsed == 2)
    }

    @Test func cancellationStopsAtAChunkBoundaryAndReportsTheSession() async throws {
        let harness = try await PublishHarness(label: "cancel")
        let request = try harness.request(captions: false)
        // Through the existential: on the concrete actor type, `handle(for:)` resolves to the protocol
        // extension's async default (nil) instead of the actor's synchronous method.
        let runner: any JobRunner = harness.runner
        let log = EventLog()
        let jobId = Mutex<JobID?>(nil)
        let job = harness.publisher.publish(request, publishId: "publish-1", resuming: nil) { event in
            log.append(event)
            if case .session(let session) = event, session.bytesConfirmed == 2 * mib {
                guard let id = jobId.withLock({ $0 }) else { return }
                // The app cancels through the handle the runner hands out for the tool's job.
                let tracked = await runner.handle(for: id)
                #expect(tracked?.id == id && tracked?.kind == .publish)
                tracked?.cancel()
            }
        }
        jobId.withLock { $0 = job.id }
        let handle = await runner.submit(job)
        await #expect(throws: CancellationError.self) { _ = try await handle.wait() }
        let last = try #require(log.sessions.last)
        #expect(last.bytesConfirmed == 2 * mib && last.totalBytes == 5 * mib)
        #expect(await harness.server.chunkRequests.count == 2, "the third chunk never started")
        #expect(await harness.server.sessions.values.first?.bytesConfirmed == 2 * mib)
        #expect(log.uploaded == nil)
        // The session is valid for a resume.
        let (receipt, events) = try await harness.publish(request, resuming: last)
        #expect(receipt.resumedCount == 1 && receipt.bytesUploaded == 5 * mib)
        #expect(events.sessions.first?.bytesConfirmed == 2 * mib)
        #expect(await !harness.server.hasOverlappingChunks)
    }

    @Test func chunkSizeMustBeAMultipleOf256KiB() async throws {
        #expect(throws: PublishError.self) { try UploadOptions(chunkBytes: 1_000_000).validate() }
        #expect(throws: PublishError.self) { try UploadOptions(chunkBytes: 0).validate() }
        try UploadOptions(chunkBytes: 262_144).validate()
        try UploadOptions().validate()
        #expect(UploadOptions().chunkBytes == 32 << 20 && UploadOptions().chunkBytes % 262_144 == 0)
        #expect(UploadOptions().maxAttempts == 10 && UploadOptions().requestTimeout == 120)
        let harness = try await PublishHarness(label: "chunk-size", chunkBytes: 1_000_000)
        let run = await harness.submit(try harness.request(bytes: mib, captions: false))
        do {
            _ = try await run.handle.wait()
            Issue.record("expected invalidRequest")
        } catch PublishError.invalidRequest(let reason) {
            #expect(reason.contains("262144"))
        }
        #expect(await harness.server.chunkRequests.isEmpty)
    }

    @Test func progressFractionIsBytesConfirmedOverTotal() async throws {
        let harness = try await PublishHarness(label: "progress")
        let request = try harness.request(captions: false)
        let run = await harness.submit(request)
        _ = try await run.receipt()
        let context = try #require(run.context)
        let uploads = context.reported.filter { $0.stage == PublishStage.upload.rawValue }
        let fractions = uploads.compactMap(\.fraction)
        #expect(fractions == [0, 0.2, 0.4, 0.6, 0.8, 1.0])
        #expect(fractions == run.events.sessions.map(\.fraction))
        #expect(uploads.dropFirst().dropLast().allSatisfy { $0.etaSeconds != nil })
        #expect(uploads.last?.etaSeconds == 0)
        let stages = context.reported.compactMap(\.stage)
        #expect(stages.first == "verify" && stages.contains("processing"))
        #expect(context.reported.last == .done)
        #expect(run.job.kind == .publish && run.job.memoryClass == .small)
    }

    @Test func memoryStaysUnderTwoChunks() async throws {
        let chunk = Int64(8) << 20
        let harness = try await PublishHarness(label: "memory", chunkBytes: chunk)
        let request = try harness.request(bytes: 64 * mib, captions: false)
        let before = residentBytes()
        let (receipt, _) = try await harness.publish(request)
        let after = residentBytes()
        #expect(receipt.bytesUploaded == 64 * mib)
        #expect(await harness.server.chunkRequests.count == 8)
        let delta = Int64(after) - Int64(before)
        #expect(delta < 4 * chunk, "resident grew by \(delta / mib) MiB")
        let job = harness.publisher.publish(request, publishId: "p", resuming: nil) { _ in }
        #expect(job.estimatedBytes == 2 * chunk, "the job declares at most two chunks of memory")
    }
}

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}
