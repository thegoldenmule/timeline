import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

/// A temp directory with a file of random bytes to publish.
private struct Upload {
    let directory: URL
    let file: URL
    let size: Int64

    init(bytes: Int = 300 << 10) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PublishingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("band-rehearsal.mp4")
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in for i in buffer.indices { buffer[i] = UInt8.random(in: 0...255) } }
        try data.write(to: file)
        size = Int64(bytes)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private let requestFixtureJSON = """
    {"accountId":"sub-1","captions":[{"cues":[{"end":{"ts":24000,"v":48048},"start":{"ts":24000,"v":12012},"text":"Hello there"},{"end":{"ts":24000,"v":108108},"start":{"ts":24000,"v":60060},"text":"and welcome"}],"format":"srt","language":"en","name":"English","trackId":"track-c1"}],"categoryId":"22","containsSyntheticMedia":false,"description":"Recorded 2026-09-08.","destination":"youtube","durationSeconds":12.5,"fileURL":"file:///tmp/exports/band-rehearsal.mp4","height":1080,"language":"en","notifySubscribers":false,"privacy":"private","projectVersion":18,"renderId":"render-1","tags":["live","rehearsal"],"title":"Band rehearsal","width":1920}
    """

@Suite struct PublishingTests {
    @Test func publishRequestAndReceiptRoundTripThroughTheProjectCodec() throws {
        let request = Fixtures.publishRequest()
        let data = try ProjectCodec.encode(request)
        #expect(
            String(decoding: data, as: UTF8.self) == requestFixtureJSON.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(try ProjectCodec.decode(PublishRequest.self, from: Data(requestFixtureJSON.utf8)) == request)
        #expect(request.madeForKids == nil, "the agent path never declares the audience")

        var scheduled = request
        scheduled.publishAt = Fixtures.fixtureDate
        scheduled.madeForKids = false
        scheduled.thumbnail = PublishThumbnail(
            fileURL: URL(fileURLWithPath: "/tmp/t.jpg"), sourceTime: Fixtures.frames(48))
        scheduled.playlistId = "PL-1"
        scheduled.recordingDate = Fixtures.fixtureDate
        #expect(try ProjectCodec.decode(PublishRequest.self, from: try ProjectCodec.encode(scheduled)) == scheduled)

        let receipt = Fixtures.publishReceipt()
        let receiptData = try ProjectCodec.encode(receipt)
        #expect(try ProjectCodec.decode(PublishReceipt.self, from: receiptData) == receipt)
        let json = try JSONValue(encoding: receipt)
        #expect(json["remoteURL"] == "https://youtu.be/fake-video-1")
        #expect(json["startedAt"] == "2026-09-08T00:00:00.000Z")
        #expect(json["privacy"] == "private" && json["madeForKids"] == nil)

        let record = PublishRecord(
            id: "publish-1", renderId: "render-1", destination: .youtube, accountId: "sub-1", status: .failed,
            request: request,
            session: PublishSession(
                uploadURL: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=x")!,
                totalBytes: 10, bytesConfirmed: 5, startedAt: Fixtures.fixtureDate, resumedCount: 1), bytesTotal: 10,
            bytesSent: 5, projectVersion: 18, error: "network", requestedAt: Fixtures.fixtureDate,
            completedAt: Fixtures.fixtureDate)
        #expect(try ProjectCodec.decode(PublishRecord.self, from: try ProjectCodec.encode(record)) == record)
        #expect(record.isResumable)
        for value in [
            PublishQuota(uploadsUsed: 3, unitsUsed: 450, resetsAt: Fixtures.fixtureDate),
            PublishQuota(uploadsUsed: 100, unitsUsed: 10_500, resetsAt: Fixtures.fixtureDate),
        ] { #expect(try ProjectCodec.decode(PublishQuota.self, from: try ProjectCodec.encode(value)) == value) }
        #expect(PublishQuota(uploadsUsed: 100, unitsUsed: 10_500, resetsAt: Fixtures.fixtureDate).uploadsRemaining == 0)
        #expect(PublishQuota(uploadsUsed: 3, unitsUsed: 450, resetsAt: Fixtures.fixtureDate).unitsRemaining == 9550)
        let capabilities = PublishCapabilities(publicUploadsAllowed: false, note: PublishCapabilities.unauditedNote)
        #expect(
            try ProjectCodec.decode(PublishCapabilities.self, from: try ProjectCodec.encode(capabilities))
                == capabilities)
        let remote = RemotePublishStatus(uploadStatus: "rejected", privacy: .private, rejectionReason: "length")
        #expect(try ProjectCodec.decode(RemotePublishStatus.self, from: try ProjectCodec.encode(remote)) == remote)
        let errors: [PublishError] = [
            .invalidRequest("title"), .fileMissing(URL(fileURLWithPath: "/x.mp4")),
            .hashMismatch(expected: "a", found: "b"), .notConnected("sub-1"), .reauthorizationRequired("x"),
            .quotaExceeded(resetsAt: Fixtures.fixtureDate), .quotaExceeded(resetsAt: nil), .uploadLimitExceeded,
            .forbidden("thumbnail"), .sessionExpired, .uploadFailed(status: 503, reason: "backendError"),
            .rejected(reason: "length"), .processingFailed("transcodeFailed"), .cancelled, .network("lost"),
        ]
        for error in errors {
            #expect(try ProjectCodec.decode(PublishError.self, from: try ProjectCodec.encode(error)) == error)
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
        #expect(PublishStatus.allCases.filter(\.isTerminal) == [.done, .failed, .cancelled])
        #expect(JobKind.allCases.contains(.publish))
    }

    @Test func publishSessionNeverAppearsInAReceipt() throws {
        let receipt = Fixtures.publishReceipt()
        let json = String(decoding: try ProjectCodec.encode(receipt), as: UTF8.self)
        #expect(!json.contains("upload/youtube"))
        #expect(!json.contains("upload_id"))
        let outcome = try JobOutcome(encoding: receipt)
        #expect(!String(decoding: try ProjectCodec.encode(outcome), as: UTF8.self).contains("upload/youtube"))
    }

    @Test func fakePublisherProducesAReceiptThroughAJobRunner() async throws {
        let upload = try Upload()
        defer { upload.cleanup() }
        let fake = FakePublisher(clock: FixedClock(step: 1))
        let publisher: any Publisher = fake
        var request = Fixtures.publishRequest(renderId: "render-1", fileURL: upload.file)
        request.thumbnail = PublishThumbnail(fileURL: upload.file, sourceTime: Fixtures.frames(12))
        request.playlistId = "PL-1"
        #expect(try await publisher.validate(request).isEmpty)
        let estimate = await publisher.estimate(request)
        #expect(estimate.bytes == upload.size && estimate.usd == 0 && (estimate.seconds ?? 0) > 0)
        #expect(await publisher.quota().uploadsRemaining == 100)
        #expect(await publisher.capabilities().publicUploadsAllowed == false)

        let events = EventLog()
        let job = publisher.publish(request, publishId: "publish-1", resuming: nil) { await events.append($0) }
        #expect(job.kind == .publish && job.memoryClass == .small)
        let runner = FakeJobRunner()
        let handle = await runner.submit(job)
        var stages: [String] = []
        var fractions: [Double] = []
        for await progress in handle.progress {
            if let stage = progress.stage, stages.last != stage { stages.append(stage) }
            if progress.stage == "upload", let fraction = progress.fraction { fractions.append(fraction) }
        }
        let outcome = try await handle.wait()
        let receipt = try #require(try outcome.payload(as: PublishReceipt.self))
        #expect(stages == ["verify", "session", "upload", "processing", "thumbnail", "captions", "playlist"])
        #expect(fractions == [0.2, 0.4, 0.6, 0.8, 1.0])
        #expect(
            receipt.remoteId == "fake-video-1" && receipt.remoteURL.absoluteString == "https://youtu.be/fake-video-1")
        #expect(receipt.publishId == "publish-1" && receipt.renderId == "render-1")
        #expect(receipt.bytesUploaded == upload.size && receipt.resumedCount == 0)
        let hash = try FileHash.sha256(of: upload.file)
        #expect(receipt.contentHash == hash)
        #expect(receipt.privacy == .private && receipt.requestedPrivacy == .private && receipt.warnings.isEmpty)
        #expect(receipt.thumbnailSet && receipt.captionIds == ["fake-caption-1"] && receipt.playlistItemId != nil)
        #expect(receipt.channelTitle == "Skeleton Channel" && receipt.processingStatus == "processed")

        let seen = await events.events
        let sessionIndex = try #require(seen.firstIndex { if case .session = $0 { true } else { false } })
        guard case .session(let first) = seen[sessionIndex] else { return }
        #expect(first.totalBytes == upload.size && first.bytesConfirmed == 0)
        #expect(
            sessionIndex < (seen.firstIndex(of: .stage(.upload)) ?? -1), "the session is emitted before any bytes move")
        #expect(seen.prefix(2) == [.stage(.verify), .stage(.session)])
        #expect(seen.contains(.uploaded(remoteId: "fake-video-1", remoteURL: receipt.remoteURL)))
        let confirmed = seen.compactMap { event -> Int64? in
            if case .session(let s) = event { return s.bytesConfirmed }
            return nil
        }
        #expect(confirmed == confirmed.sorted() && confirmed.last == upload.size)
        #expect(await fake.publishCalls.map(\.publishId) == ["publish-1"])
        #expect(await publisher.quota().uploadsUsed == 1)
        #expect(
            try await publisher.remoteStatus(remoteId: "fake-video-1", accountId: "sub-1").uploadStatus == "processed")
        #expect(try await publisher.remoteStatus(remoteId: "nope", accountId: "sub-1").uploadStatus == "deleted")
    }

    @Test func fakePublisherFailsOnceAndResumes() async throws {
        let upload = try Upload(bytes: 1 << 20)
        defer { upload.cleanup() }
        let fake = FakePublisher()
        await fake.setFailAt(.upload, fraction: 0.4)
        let request = Fixtures.publishRequest(fileURL: upload.file)
        let events = EventLog()
        let runner = FakeJobRunner()
        let first = await runner.submit(
            fake.publish(request, publishId: "p-1", resuming: nil) { await events.append($0) })
        await #expect(throws: PublishError.network("injected")) { try await first.wait() }
        let session = try #require(await events.lastSession)
        #expect(session.bytesConfirmed > 0 && session.bytesConfirmed < upload.size)

        let second = await runner.submit(
            fake.publish(request, publishId: "p-1", resuming: session) { await events.append($0) })
        let receipt = try #require(try await second.wait().payload(as: PublishReceipt.self))
        #expect(receipt.resumedCount == 1)
        let confirmed = await events.confirmedBytes
        #expect(confirmed == confirmed.sorted(), "bytesConfirmed is monotonic across the two runs")
        #expect(confirmed.last == upload.size)
        #expect(await fake.publishCalls.map { $0.resuming?.bytesConfirmed } == [nil, session.bytesConfirmed])
    }

    @Test func fakePublisherCancelsAtAStepAndKeepsTheSession() async throws {
        let upload = try Upload()
        defer { upload.cleanup() }
        let fake = FakePublisher()
        await fake.setStepDelay(.milliseconds(20))
        let events = EventLog()
        let runner = FakeJobRunner()
        let handle = await runner.submit(
            fake.publish(Fixtures.publishRequest(fileURL: upload.file), publishId: "p-1", resuming: nil) {
                await events.append($0)
            })
        for await progress in handle.progress where progress.stage == "upload" && (progress.fraction ?? 0) >= 0.2 {
            break
        }
        await runner.cancel(handle.id)
        await #expect(throws: CancellationError.self) { try await handle.wait() }
        let session = try #require(await events.lastSession)
        #expect(session.bytesConfirmed < upload.size)
        #expect(await events.events.allSatisfy { if case .uploaded = $0 { false } else { true } })
    }

    @Test func fakePublisherRefusesAHashMismatch() async throws {
        let upload = try Upload()
        defer { upload.cleanup() }
        let fake = FakePublisher()
        await fake.setRefuseHash(true)
        var request = Fixtures.publishRequest(fileURL: upload.file)
        request.expectedContentHash = "sha256-expected"
        let handle = await FakeJobRunner().submit(fake.publish(request, publishId: "p-1", resuming: nil) { _ in })
        let error = await #expect(throws: PublishError.self) { try await handle.wait() }
        guard case .hashMismatch(let expected, let found) = error else {
            Issue.record("expected hashMismatch, got \(String(describing: error))")
            return
        }
        let actual = try FileHash.sha256(of: upload.file)
        #expect(expected == "sha256-expected" && found == actual)
        let missing = await FakeJobRunner().submit(
            fake.publish(
                Fixtures.publishRequest(fileURL: upload.directory.appendingPathComponent("nope.mp4")), publishId: "p-2",
                resuming: nil
            ) { _ in })
        await #expect(throws: PublishError.self) { try await missing.wait() }
    }

    @Test func fakePublisherForcesPrivateWithAWarning() async throws {
        let upload = try Upload()
        defer { upload.cleanup() }
        let fake = FakePublisher()
        await fake.setForcePrivate(true)
        var request = Fixtures.publishRequest(fileURL: upload.file)
        request.privacy = .public
        let handle = await FakeJobRunner().submit(fake.publish(request, publishId: "p-1", resuming: nil) { _ in })
        let outcome = try await handle.wait()
        let receipt = try #require(try outcome.payload(as: PublishReceipt.self))
        #expect(receipt.requestedPrivacy == .public && receipt.privacy == .private)
        #expect(receipt.warnings == ["Uploaded as private: project not audited"])
        #expect(outcome.warnings == receipt.warnings)
    }

    @Test func fakePublisherValidates() async throws {
        let fake = FakePublisher()
        let publisher: any Publisher = fake
        var request = Fixtures.publishRequest()
        request.title = " "
        await #expect(throws: PublishError.self) { _ = try await publisher.validate(request) }
        request = Fixtures.publishRequest()
        request.privacy = .unlisted
        request.publishAt = Fixtures.fixtureDate
        await #expect(throws: PublishError.self) { _ = try await publisher.validate(request) }
        await fake.setWarnOnValidate(true)
        #expect(try await publisher.validate(Fixtures.publishRequest()) == ["fake warning"])
        #expect(await fake.validated.count == 3)
        #expect(publisher.requiredScopes == Fixtures.publishScopes && publisher.destination == .youtube)
    }

    @Test func captionCuesAreTimelineRelativeAndSorted() throws {
        let project = try Fixtures.project("linked-transition-caption-undone")
        let sequence = try #require(project.activeSequence)
        let track = try #require(sequence.tracks.first { $0.kind == .caption })
        let cues = CaptionCues.make(from: track, in: sequence)
        #expect(cues == Fixtures.captionCues)
        #expect(cues.map(\.start) == cues.map(\.start).sorted())
        for (cue, clip) in zip(cues, track.clips.values.sorted { $0.start < $1.start }) {
            #expect(cue.start == clip.start && cue.end == sequence.end(of: clip) && cue.text == clip.text)
        }
        // Empty text and zero-length clips are skipped; a non-caption track yields nothing.
        var edited = track
        var blank = try #require(edited.clips.values.first)
        blank.id = "caption-blank"
        blank.text = "   "
        edited.clips[blank.id] = blank
        var zero = blank
        zero.id = "caption-zero"
        zero.text = "zero"
        zero.sourceOut = zero.sourceIn
        edited.clips[zero.id] = zero
        #expect(CaptionCues.make(from: edited, in: sequence) == cues)
        #expect(CaptionCues.make(from: try #require(sequence.tracks.first { $0.kind == .video }), in: sequence).isEmpty)
        let tracks = CaptionCues.tracks(in: sequence)
        #expect(tracks.count == 1 && tracks[0].trackId == track.id && tracks[0].language == "en")
        #expect(tracks[0].format == .srt && tracks[0].cues == cues)
    }

    @Test func fileHashMatchesMediaKitFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileHash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        let expected = "sha256-ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(try FileHash.sha256(of: file) == expected)
        #expect(FileHash.sha256(of: Data("abc".utf8)) == expected)
        #expect(try FileHash.sha256(of: file, bufferSize: 1) == expected)
        let empty = directory.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(
            try FileHash.sha256(of: empty) == "sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(throws: (any Error).self) { try FileHash.sha256(of: directory.appendingPathComponent("missing")) }
    }

    @Test func libraryLayoutHasAnExportsDirectory() {
        let layout = LibraryLayout(root: URL(fileURLWithPath: "/tmp/T"))
        #expect(layout.exportsDir.path == "/tmp/T/Exports")
        #expect(layout.exportsDir.hasDirectoryPath)
    }
}

/// Collects `PublishEvent`s from a job's `onEvent`.
private actor EventLog {
    private(set) var events: [PublishEvent] = []
    func append(_ event: PublishEvent) { events.append(event) }
    var lastSession: PublishSession? {
        for event in events.reversed() { if case .session(let s) = event { return s } }
        return nil
    }
    var confirmedBytes: [Int64] {
        events.compactMap { event in
            if case .session(let s) = event { return s.bytesConfirmed }
            return nil
        }
    }
}
