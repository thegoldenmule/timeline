import Contracts
import ContractsTestSupport
import Foundation
import Synchronization
import Testing
import TimelineCore

@testable import PublishKit

@Suite struct PublisherTests {
    @Test func wholeJobProducesAReceiptWithResumedCountOne() async throws {
        let harness = try await PublishHarness(label: "whole")
        let request = try harness.request()
        await harness.server.dropConnection(afterBytes: 2 * mib)
        let (receipt, events) = try await harness.publish(request, publishId: "publish-7")
        #expect(receipt.publishId == "publish-7" && receipt.destination == .youtube && receipt.accountId == "sub-1")
        #expect(receipt.channelId == "UC-fake" && receipt.channelTitle == "Skeleton Channel")
        #expect(receipt.renderId == "render-1" && receipt.contentHash == request.expectedContentHash)
        #expect(receipt.projectVersion == 18)
        #expect(receipt.remoteId == "fake-video-1" && receipt.remoteURL == URL(string: "https://youtu.be/fake-video-1"))
        #expect(receipt.studioURL == URL(string: "https://studio.youtube.com/video/fake-video-1/edit"))
        #expect(receipt.requestedPrivacy == .private && receipt.privacy == .private)
        #expect(receipt.bytesUploaded == 5 * mib && receipt.resumedCount == 1)
        #expect(receipt.captionIds == ["fake-caption-1"] && !receipt.thumbnailSet && receipt.playlistItemId == nil)
        #expect(receipt.processingStatus == "processed" && receipt.finishedAt >= receipt.startedAt)
        #expect(receipt.warnings.count == 1 && receipt.warnings[0].contains("made for kids"))
        #expect(events.stages == [.verify, .session, .upload, .processing, .captions])
        #expect(events.uploaded?.0 == "fake-video-1")
        #expect(await harness.server.statusQueries.count == 1)
        #expect(await !harness.server.hasOverlappingChunks)
        let submissions = await harness.runner.submissions
        #expect(
            submissions.count == 1 && submissions[0].kind == .publish
                && submissions[0].label == "Publish Band rehearsal")
        // Quota bookkeeping: one upload, 3 polls, one caption.
        let quota = await harness.publisher.quota()
        #expect(quota.uploadsUsed == 1 && quota.unitsUsed == 3 + 400)
        #expect(await harness.server.video("fake-video-1")?.snippet["title"] == "Band rehearsal")
        #expect(await harness.server.video("fake-video-1")?.snippet["categoryId"] == "22")
        #expect(await harness.server.video("fake-video-1")?.snippet["defaultLanguage"] == "en")
    }

    @Test func verifyRefusesAModifiedFile() async throws {
        let harness = try await PublishHarness(label: "verify")
        var request = try harness.request(bytes: 300 * 1024)
        let found = try #require(request.expectedContentHash)
        request.expectedContentHash = "sha256-" + String(repeating: "0", count: 64)
        let run = await harness.submit(request)
        await #expect(throws: PublishError.hashMismatch(expected: request.expectedContentHash!, found: found)) {
            _ = try await run.handle.wait()
        }
        #expect(run.events.stages == [.verify] && run.events.sessions.isEmpty)
        #expect(await harness.server.requests.isEmpty)
        #expect(await harness.server.uploadsUsed == 0)
        // A missing file fails the same stage.
        var gone = request
        gone.fileURL = harness.directory.appendingPathComponent("gone.mp4")
        let missing = await harness.submit(gone)
        await #expect(throws: PublishError.fileMissing(gone.fileURL)) { _ = try await missing.handle.wait() }
        // No expected hash: the file is accepted and the receipt carries the hash it computed.
        request.expectedContentHash = nil
        let (receipt, _) = try await harness.publish(request)
        #expect(receipt.contentHash == found)
    }

    @Test func receiptReportsTheApiPrivacyAndWarnsWhenForcedPrivate() async throws {
        let harness = try await PublishHarness(label: "forced-private")
        var request = try harness.request(bytes: mib, captions: false)
        request.privacy = .unlisted
        await harness.server.forcePrivate(true)
        let (receipt, _) = try await harness.publish(request)
        #expect(receipt.requestedPrivacy == .unlisted && receipt.privacy == .private)
        #expect(receipt.warnings.contains("Uploaded as private: project not audited"))
        #expect(await harness.server.video("fake-video-1")?.privacy == "private")
        // The metadata still asked for unlisted: nothing was altered before sending.
        #expect(await harness.server.sessions.values.first?.metadata["status"]?["privacyStatus"] == "unlisted")

        await harness.server.forcePrivate(false)
        var unlisted = try harness.request(bytes: mib, captions: false, name: "two.mp4")
        unlisted.privacy = .unlisted
        let (second, _) = try await harness.publish(unlisted, publishId: "publish-2")
        #expect(second.privacy == .unlisted && !second.warnings.contains { $0.contains("private") })
    }

    @Test func thumbnailForbiddenIsAWarningNotAFailure() async throws {
        let harness = try await PublishHarness(label: "thumbnail")
        var request = try harness.request(bytes: mib, captions: false)
        request.thumbnail = PublishThumbnail(fileURL: try jpegFile(bytes: 20_000, in: harness.directory))
        await harness.server.forbidThumbnail()
        let (receipt, events) = try await harness.publish(request)
        #expect(!receipt.thumbnailSet && receipt.remoteId == "fake-video-1")
        #expect(receipt.warnings.contains { $0.hasPrefix("Thumbnail not set") && $0.contains("youtube.com/verify") })
        #expect(events.stages.contains(.thumbnail))
        #expect(await harness.server.thumbnails.isEmpty)
        #expect(await harness.publisher.quota().unitsUsed == 3, "a refused thumbnail is not charged by the fake")

        let (ok, _) = try await harness.publish(request, publishId: "publish-2")
        #expect(ok.thumbnailSet && !ok.warnings.contains { $0.hasPrefix("Thumbnail") })
        #expect(await harness.server.thumbnails["fake-video-2"] == 20_000)
        let set = try #require(await harness.server.requests.last { $0.path == "/upload/youtube/v3/thumbnails/set" })
        #expect(set.headers["Content-Type"] == "image/jpeg" && set.query["videoId"] == "fake-video-2" && set.hasBearer)
    }

    @Test func captionsAreInsertedPerTrackAsSRT() async throws {
        let harness = try await PublishHarness(label: "captions")
        var request = try harness.request(bytes: mib)
        request.captions.append(
            PublishCaptionTrack(language: "de", name: "Deutsch", format: .vtt, cues: Fixtures.captionCues))
        let (receipt, events) = try await harness.publish(request)
        #expect(receipt.captionIds == ["fake-caption-1", "fake-caption-2"])
        #expect(events.stages.contains(.captions))
        let captions = await harness.server.captions(forVideo: "fake-video-1")
        #expect(captions.map(\.language) == ["en", "de"] && captions.map(\.name) == ["English", "Deutsch"])
        let srt = try #require(captions.first?.body)
        #expect(srt == SRTWriter.text(for: Fixtures.captionCues))
        // The body parses as SRT with the fixture's two cues at timeline times.
        let blocks = srt.split(separator: "\n\n").map { $0.split(separator: "\n").map(String.init) }
        #expect(blocks.count == 2)
        #expect(blocks[0] == ["1", "00:00:00,500 --> 00:00:02,002", "Hello there"])
        #expect(blocks[1] == ["2", "00:00:02,502 --> 00:00:04,504", "and welcome"])
        #expect(captions[1].body.hasPrefix("WEBVTT\n\n00:00:00.500 --> 00:00:02.002\nHello there"))
        let inserts = await harness.server.requests.filter { $0.path == "/upload/youtube/v3/captions" }
        #expect(
            inserts.count == 2
                && inserts.allSatisfy { $0.query["uploadType"] == "multipart" && $0.query["part"] == "snippet" })
        #expect(inserts.allSatisfy { $0.headers["Content-Type"]?.hasPrefix("multipart/related; boundary=") == true })
        #expect(await harness.publisher.quota().unitsUsed == 3 + 800)
    }

    @Test func duplicateCaptionIs409Warning() async throws {
        let harness = try await PublishHarness(label: "captions-409")
        var request = try harness.request(bytes: mib)
        request.captions.append(request.captions[0])
        let (receipt, _) = try await harness.publish(request)
        #expect(receipt.captionIds == ["fake-caption-1"])
        #expect(receipt.warnings.contains("Caption track \"English\" (en) already exists on the video"))
        #expect(await harness.server.captions(forVideo: "fake-video-1").count == 1)
    }

    @Test func playlistInsertIsOptional() async throws {
        let harness = try await PublishHarness(label: "playlist")
        var request = try harness.request(bytes: mib, captions: false)
        request.playlistId = "PL-1"
        let (receipt, events) = try await harness.publish(request)
        #expect(receipt.playlistItemId == "fake-playlist-item-1" && events.stages.last == .playlist)
        #expect(await harness.server.playlistItems.map(\.playlistId) == ["PL-1"])

        // Without a playlist the stage is skipped.
        let plain = try harness.request(bytes: mib, captions: false, name: "two.mp4")
        let (second, secondEvents) = try await harness.publish(plain, publishId: "publish-2")
        #expect(second.playlistItemId == nil && !secondEvents.stages.contains(.playlist))

        // A failing insert is a warning: the quota runs out right before the playlist step.
        let server = harness.server
        var third = try harness.request(bytes: mib, captions: false, name: "three.mp4")
        third.playlistId = "PL-2"
        let run = await harness.submit(third, publishId: "publish-3") { event in
            if case .stage(.playlist) = event { await server.quotaExceeded() }
        }
        let outcome = try await run.receipt()
        #expect(outcome.playlistItemId == nil && outcome.remoteId == "fake-video-3")
        #expect(outcome.warnings.contains { $0.hasPrefix("Not added to playlist PL-2") })
        #expect(await harness.server.playlistItems.count == 1)
    }

    @Test func processingRejectionFailsTheJobWithTheReason() async throws {
        let harness = try await PublishHarness(label: "rejected")
        await harness.server.scriptProcessing(uploadStatus: "rejected", reason: "length")
        let run = await harness.submit(try harness.request(bytes: mib, captions: false))
        await #expect(throws: PublishError.rejected(reason: "length")) { _ = try await run.handle.wait() }
        #expect(run.events.uploaded?.0 == "fake-video-1", "the upload itself completed")
        #expect(
            harness.sleeps.durations == [.seconds(15), .seconds(30)], "two waits before the third poll reported it")

        let failed = try await PublishHarness(label: "failed")
        await failed.server.scriptProcessing(uploadStatus: "failed", reason: "codec")
        let failedRun = await failed.submit(try failed.request(bytes: mib, captions: false))
        await #expect(throws: PublishError.processingFailed("codec")) { _ = try await failedRun.handle.wait() }

        // Still processing after every poll: a warning, not a failure.
        let slow = try await PublishHarness(label: "slow")
        await slow.server.setProcessingPollsUntilDone(100)
        let (receipt, _) = try await slow.publish(try slow.request(bytes: mib, captions: false))
        #expect(receipt.processingStatus == "uploaded")
        #expect(receipt.warnings.contains { $0.contains("still processing") })
        #expect(slow.sleeps.count == 19)
        #expect(slow.sleeps.durations.prefix(3) == [.seconds(15), .seconds(30), .seconds(60)])
        #expect(slow.sleeps.durations.allSatisfy { $0 <= .seconds(60) })
        #expect(await slow.server.requests.filter { $0.path == "/youtube/v3/videos" }.count == 20)
    }

    @Test func madeForKidsNilOmitsTheField() async throws {
        let harness = try await PublishHarness(label: "kids")
        let request = try harness.request(bytes: mib, captions: false)
        #expect(request.madeForKids == nil)
        let (receipt, _) = try await harness.publish(request)
        let metadata = try #require(await harness.server.sessions.values.first?.metadata)
        #expect(metadata["status"]?["selfDeclaredMadeForKids"] == nil)
        #expect(metadata["status"]?["privacyStatus"] == "private")
        #expect(receipt.madeForKids == nil)
        #expect(receipt.warnings.contains { $0.contains("YouTube Studio") })

        var declared = try harness.request(bytes: mib, captions: false, name: "two.mp4")
        declared.madeForKids = false
        let (second, _) = try await harness.publish(declared, publishId: "publish-2")
        let sessions = await harness.server.sessions.values.sorted { $0.id < $1.id }
        #expect(sessions.last?.metadata["status"]?["selfDeclaredMadeForKids"] == false)
        #expect(second.madeForKids == false && !second.warnings.contains { $0.contains("YouTube Studio") })
        #expect(YouTubeAPI.videoResource(for: declared)["status"]?["selfDeclaredMadeForKids"] == false)
        #expect(YouTubeAPI.videoResource(for: request)["status"]?["selfDeclaredMadeForKids"] == nil)
    }

    @Test func containsSyntheticMediaIsSent() async throws {
        let harness = try await PublishHarness(label: "synthetic")
        var request = try harness.request(bytes: mib, captions: false)
        request.containsSyntheticMedia = true
        request.publishAt = Date(timeIntervalSince1970: 1_788_912_000)
        request.recordingDate = Date(timeIntervalSince1970: 1_788_825_600)
        let (receipt, _) = try await harness.publish(request)
        let metadata = try #require(await harness.server.sessions.values.first?.metadata)
        #expect(metadata["status"]?["containsSyntheticMedia"] == true)
        #expect(metadata["status"]?["publishAt"] == "2026-09-09T00:00:00.000Z")
        #expect(metadata["recordingDetails"]?["recordingDate"] == "2026-09-08T00:00:00.000Z")
        #expect(metadata["snippet"]?["tags"] == ["live", "rehearsal"])
        #expect(receipt.containsSyntheticMedia && receipt.publishAt == request.publishAt)
        let start = try #require(
            await harness.server.requests.first { $0.method == "POST" && $0.path == "/upload/youtube/v3/videos" })
        #expect(start.query["part"] == "snippet,status,recordingDetails")
        #expect(YouTubeAPI.videoResource(for: request)["status"]?["containsSyntheticMedia"] == true)
    }

    @Test func notifySubscribersIsAQueryParameter() async throws {
        let harness = try await PublishHarness(label: "notify")
        let request = try harness.request(bytes: mib, captions: false)
        _ = try await harness.publish(request)
        var notify = try harness.request(bytes: mib, captions: false, name: "two.mp4")
        notify.notifySubscribers = true
        _ = try await harness.publish(notify, publishId: "publish-2")
        let starts = await harness.server.requests.filter {
            $0.method == "POST" && $0.path == "/upload/youtube/v3/videos"
        }
        #expect(starts.map { $0.query["notifySubscribers"] } == ["false", "true"])
        #expect(starts.allSatisfy { $0.query["uploadType"] == "resumable" && $0.query["part"] == "snippet,status" })
        #expect(starts.allSatisfy { $0.headers["Content-Type"]?.hasPrefix("application/json") == true && $0.hasBearer })
        let metadata = try #require(await harness.server.sessions.values.first?.metadata)
        #expect(metadata["snippet"]?["notifySubscribers"] == nil && metadata["status"]?["notifySubscribers"] == nil)
    }

    @Test func onEventSequenceIsSessionUploadedStages() async throws {
        let harness = try await PublishHarness(label: "events")
        var request = try harness.request(bytes: 2 * mib)
        request.thumbnail = PublishThumbnail(fileURL: try jpegFile(bytes: 1000, in: harness.directory))
        request.playlistId = "PL-9"
        let (_, events) = try await harness.publish(request)
        var kinds: [String] = []
        for event in events.events {
            switch event {
            case .stage(let stage): kinds.append("stage:\(stage.rawValue)")
            case .session(let session): kinds.append("session:\(session.bytesConfirmed / mib)")
            case .uploaded(let id, _): kinds.append("uploaded:\(id)")
            }
        }
        #expect(
            kinds == [
                "stage:verify", "stage:session", "session:0", "stage:upload", "session:1", "session:2",
                "uploaded:fake-video-1", "stage:processing", "stage:thumbnail", "stage:captions", "stage:playlist",
            ])
        // The session event precedes the first byte: its URL is the fake's session URI.
        #expect(events.sessions.first?.uploadURL.absoluteString.contains("upload_id=fake-upload-1") == true)
        #expect(events.sessions.first?.bytesConfirmed == 0 && events.sessions.first?.totalBytes == 2 * mib)
    }

    @Test func noOutputContainsTheUploadURL() async throws {
        let harness = try await PublishHarness(label: "no-url")
        await harness.server.dropConnection(afterBytes: 2 * mib)
        let run = await harness.submit(try harness.request())
        let outcome = try await run.handle.wait()
        let receipt = try #require(try outcome.payload(as: PublishReceipt.self))
        let uploadURL = try #require(run.events.sessions.first?.uploadURL.absoluteString)
        #expect(uploadURL.contains("upload/youtube") && uploadURL.contains("upload_id="))
        let outcomeJSON = String(decoding: try ProjectCodec.encode(outcome), as: UTF8.self)
        let receiptJSON = String(decoding: try ProjectCodec.encode(receipt), as: UTF8.self)
        for text in [outcomeJSON, receiptJSON] {
            #expect(!text.contains("upload/youtube") && !text.contains("upload_id") && !text.contains(uploadURL))
            #expect(!text.contains("fake-access") && !text.contains("Bearer"))
        }
        let progress = try #require(run.context).reported
        #expect(progress.allSatisfy { ($0.message ?? "").isEmpty || !$0.message!.contains("upload_id") })
        #expect(receipt.remoteURL.absoluteString == "https://youtu.be/fake-video-1")
        #expect(outcome.warnings == receipt.warnings)
    }

    @Test func estimateUsesTheMeasuredRate() async throws {
        let harness = try await PublishHarness(label: "estimate")
        let request = try harness.request()
        let before = await harness.publisher.estimate(request)
        #expect(before.bytes == 5 * mib && before.usd == 0)
        #expect(before.seconds == Double(5 * mib) / YouTubePublisher.defaultUploadRate)
        #expect(harness.publisher.uploadRate == YouTubePublisher.defaultUploadRate)
        _ = try await harness.publish(request)
        let rate = harness.publisher.uploadRate
        #expect(rate != YouTubePublisher.defaultUploadRate && rate > 0)
        let after = await harness.publisher.estimate(request)
        #expect(after.seconds == Double(5 * mib) / rate && after.bytes == 5 * mib)
        let missing = await harness.publisher.estimate(
            Fixtures.publishRequest(fileURL: harness.directory.appendingPathComponent("nope.mp4")))
        #expect(missing.bytes == 0 && missing.seconds == 0)
        // A relaunched publisher starts from the default again.
        _ = try await harness.publish(request, publishId: "publish-2")
        #expect(harness.relaunchedPublisher().uploadRate == YouTubePublisher.defaultUploadRate)
    }

    @Test func capabilitiesFollowTheAuditedFlag() async throws {
        let unaudited = try await PublishHarness(label: "unaudited")
        let capabilities = await unaudited.publisher.capabilities()
        #expect(!capabilities.publicUploadsAllowed && capabilities.note == PublishCapabilities.unauditedNote)
        let audited = try await PublishHarness(label: "audited", audited: true)
        let allowed = await audited.publisher.capabilities()
        #expect(allowed.publicUploadsAllowed && allowed.note == nil)
        #expect(unaudited.publisher.destination == .youtube)
        #expect(unaudited.publisher.requiredScopes == Fixtures.publishScopes)
        // An audited project that still gets a private answer reports the difference, not the audit.
        await audited.server.forcePrivate(true)
        var request = try audited.request(bytes: mib, captions: false)
        request.privacy = .public
        let (receipt, _) = try await audited.publish(request)
        #expect(receipt.privacy == .private && receipt.requestedPrivacy == .public)
        #expect(receipt.warnings.contains("YouTube reported privacy private instead of public"))
    }

    @Test func remoteStatusDecodesUploadAndProcessingState() async throws {
        let harness = try await PublishHarness(label: "remote-status")
        let (receipt, _) = try await harness.publish(try harness.request(bytes: mib, captions: false))
        let status = try await harness.publisher.remoteStatus(remoteId: receipt.remoteId, accountId: "sub-1")
        #expect(status.uploadStatus == "processed" && status.privacy == .private)
        #expect(status.processingStatus == "succeeded" && status.failureReason == nil && status.rejectionReason == nil)
        let gone = try await harness.publisher.remoteStatus(remoteId: "nope", accountId: "sub-1")
        #expect(gone.uploadStatus == "deleted" && gone.privacy == nil)
        await #expect(throws: PublishError.notConnected("sub-2")) {
            _ = try await harness.publisher.remoteStatus(remoteId: receipt.remoteId, accountId: "sub-2")
        }
        #expect(await harness.publisher.quota().unitsUsed == 3 + 2)
        // A rejected video reports its reason.
        await harness.server.scriptProcessing(uploadStatus: "rejected", reason: "duplicate")
        await harness.server.setProcessingPollsUntilDone(0)
        let run = await harness.submit(
            try harness.request(bytes: mib, captions: false, name: "two.mp4"), publishId: "p-2")
        await #expect(throws: PublishError.rejected(reason: "duplicate")) { _ = try await run.handle.wait() }
        let rejected = try await harness.publisher.remoteStatus(remoteId: "fake-video-2", accountId: "sub-1")
        #expect(rejected.uploadStatus == "rejected" && rejected.rejectionReason == "duplicate")
        // Reauthorization surfaces as the publish error.
        await harness.accounts.requireReauthorization("grant expired")
        await #expect(throws: PublishError.reauthorizationRequired("grant expired")) {
            _ = try await harness.publisher.remoteStatus(remoteId: "fake-video-1", accountId: "sub-1")
        }
    }
}
