import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import TimelineCore

@testable import TimelineUI

/// A store over the caption fixture with a done render on disk, and the fakes the sheet needs.
@MainActor
struct PublishFixture {
    let store: FakeProjectStore
    let publisher: FakePublisher
    let project: Project
    let sequence: Sequence
    let directory: URL

    static func make(renders: Int = 1) async throws -> PublishFixture {
        let store = try Fixtures.store("linked-transition-caption-undone")
        let project = await store.project
        let sequence = try #require(project.activeSequence ?? project.sequences.values.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publish-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = PublishFixture(
            store: store, publisher: FakePublisher(), project: project, sequence: sequence, directory: directory)
        for i in 0..<renders { _ = try await fixture.addRender(name: "render-\(i).mp4") }
        return fixture
    }

    /// Records a render and marks it done with a real (small) output file.
    @discardableResult
    func addRender(name: String, status: RenderStatus = .done, bytes: Int = 4096) async throws -> RenderRecord {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        let record = try await store.recordRender(
            id: nil, sequenceId: sequence.id, preset: .h264_1080p, projectVersion: nil)
        guard status != .queued else { return record }
        let receipt = ExportReceipt(
            preset: .h264_1080p, sequenceId: sequence.id, projectVersion: project.version, outputURL: url,
            durationSeconds: 12.5, startedAt: Fixtures.fixtureDate, finishedAt: Fixtures.fixtureDate,
            outputHash: try FileHash.sha256(of: url))
        return try await store.updateRender(
            record.id, status: status, outputURL: url, outputHash: receipt.outputHash, receipt: receipt)
    }

    func model(
        accounts: [ConnectedAccount] = [Fixtures.connectedGoogleAccount], playhead: RationalTime = Fixtures.frames(30)
    ) async -> PublishSheetModel {
        let model = PublishSheetModel(
            renders: store, publisher: publisher, accounts: accounts, sequence: sequence, projectName: project.name,
            playhead: playhead, thumbnailDirectory: directory.appendingPathComponent("thumbnails"),
            validationDelay: .milliseconds(20))
        await model.load()
        return model
    }
}

@MainActor
@Suite("Account view")
struct AccountViewTests {
    @Test func accountViewShowsSetupWhenUnconfigured() async throws {
        let provider = FakeAccountProvider(configured: false)
        let model = AccountsModel(provider: provider)
        await model.start()
        defer { model.stop() }
        #expect(!model.isConfigured)
        #expect(model.accounts.isEmpty)
        #expect(AccountText.setup == "Add a Google OAuth client to enable publishing")
        for path in [
            "TIMELINE_GOOGLE_CLIENT_ID", "TIMELINE_GOOGLE_CLIENT_JSON", "google-oauth-client.json", "TIMELINE_ROOT",
        ] {
            #expect(AccountText.setupPaths.contains(path))
        }
        // Connecting without a client reports the provider's error instead of opening anything.
        await model.connect()
        #expect(model.error?.contains("No OAuth client is configured") == true)
        #expect(ImageRenderer(content: AccountView(model: model).frame(width: 400)).cgImage != nil)
    }

    @Test func accountViewConnectsAndShowsConnectedAs() async throws {
        let provider = FakeAccountProvider()
        let model = AccountsModel(provider: provider, notices: [AccountText.unverifiedApp, AccountText.testingExpiry])
        await model.start()
        defer { model.stop() }
        #expect(model.isConfigured && model.accounts.isEmpty)
        await model.connect()
        #expect(!model.isConnecting)
        #expect(model.error == nil)
        #expect(model.accounts.map(\.id) == [Fixtures.connectedGoogleAccount.id])
        let calls = await provider.connectCalls
        #expect(calls == [FakeAccountProvider.ConnectCall(scopes: Fixtures.publishScopes, loginHint: nil)])
        let account = try #require(model.accounts.first)
        #expect(AccountRowView.connectedAs(account) == "Skeleton Channel (@skeleton)")
        #expect(AccountRowView.statusText(account.tokenStatus) == "Connected")
        #expect(AccountText.unverifiedApp.contains("not verified by Google"))
        #expect(AccountText.testingExpiry.contains("7 days"))
        #expect(AccountText.consent.contains("YouTube Terms of Service"))
        #expect(AccountText.manageAccessURL.absoluteString == "https://myaccount.google.com/permissions")
        #expect(ImageRenderer(content: AccountView(model: model).frame(width: 420)).cgImage != nil)
        let row = AccountRowView(account: account, onReconnect: {}, onDisconnect: {})
        #expect(ImageRenderer(content: row.frame(width: 400)).cgImage != nil)
    }

    @Test func accountViewOffersReconnectWhenReauthorizationIsRequired() async throws {
        let provider = FakeAccountProvider(accounts: [Fixtures.connectedGoogleAccount])
        let model = AccountsModel(provider: provider)
        await model.start()
        defer { model.stop() }
        #expect(model.accounts.count == 1)
        #expect(!model.accounts[0].tokenStatus.needsReauthorization)

        // The provider's stream carries the revoked status to the model.
        try await provider.setTokenStatus(.reauthorizationRequired("invalid_grant"), for: "sub-1")
        #expect(await eventually { model.account("sub-1")?.tokenStatus.needsReauthorization == true })
        let revoked = try #require(model.account("sub-1"))
        #expect(AccountRowView.statusText(revoked.tokenStatus) == "Reconnect required: invalid_grant")
        #expect(ImageRenderer(content: AccountView(model: model).frame(width: 420)).cgImage != nil)

        // Reconnect runs the browser flow again with the email as the hint and the account comes back valid.
        await model.reconnect("sub-1")
        let calls = await provider.connectCalls
        #expect(calls.map(\.loginHint) == ["me@example.com"])
        #expect(calls[0].scopes == Fixtures.publishScopes)
        #expect(model.account("sub-1")?.tokenStatus.needsReauthorization == false)
        #expect(model.error == nil)
    }

    @Test func accountViewDisconnectCallsTheProvider() async throws {
        let provider = FakeAccountProvider(accounts: [Fixtures.connectedGoogleAccount])
        let model = AccountsModel(provider: provider)
        await model.start()
        defer { model.stop() }
        await model.disconnect("sub-1")
        #expect(await provider.disconnected == ["sub-1"])
        #expect(model.accounts.isEmpty)
        #expect(model.error == nil)
        // A second disconnect of the same id surfaces the provider's error.
        await model.disconnect("sub-1")
        #expect(model.error == AccountError.notConnected("sub-1").message)
        #expect(ImageRenderer(content: AccountView(model: model).frame(width: 420)).cgImage != nil)
    }

    @Test func connectFailuresAreShownAndClearOnTheNextSuccess() async throws {
        let provider = FakeAccountProvider()
        await provider.setFailNextConnect(.denied("youtube.force-ssl unticked"))
        let model = AccountsModel(provider: provider)
        await model.start()
        defer { model.stop() }
        await model.connect()
        #expect(model.error == AccountError.denied("youtube.force-ssl unticked").message)
        #expect(model.accounts.isEmpty)
        await model.connect()
        #expect(model.error == nil)
        #expect(model.accounts.count == 1)
    }
}

@MainActor
@Suite("Publish sheet")
struct PublishSheetTests {
    @Test func sheetDefaultsToPrivateAndMintsOnePublishId() async throws {
        let f = try await PublishFixture.make()
        let model = await f.model()
        #expect(model.draft.privacy == .private)
        #expect(model.draft.publishAt == nil)
        #expect(model.draft.title == f.project.name)
        #expect(model.draft.categoryId == PublishCategory.defaultId)
        #expect(model.draft.accountId == "sub-1")
        #expect(model.draft.thumbnailAt == Fixtures.frames(30))
        #expect(!model.draft.madeForKids && !model.draft.containsSyntheticMedia && !model.draft.notifySubscribers)
        let id = model.draft.publishId
        #expect(id.count == 36)
        // Edits, reloads, and requests keep the same id; a second sheet gets its own.
        model.draft.title = "Band rehearsal"
        model.draft.privacy = .unlisted
        await model.load()
        #expect(model.draft.publishId == id)
        #expect(try model.request().title == "Band rehearsal")
        let second = await f.model()
        #expect(second.draft.publishId != id)
        #expect(model.summary.hasPrefix("Upload 4 KB to Skeleton Channel (@skeleton) as unlisted"))
        #expect(PublishText.certification == Fixtures.certificationSentence)
        let view = PublishSheetView(model: model, onUpload: { _ in }, onCancel: {})
        #expect(ImageRenderer(content: view.frame(width: 520, height: 900)).cgImage != nil)
    }

    @Test func sheetDisablesScheduleUnlessPrivate() async throws {
        let f = try await PublishFixture.make()
        let model = await f.model()
        let date = Fixtures.fixtureDate.addingTimeInterval(86_400)
        #expect(model.canSchedule)
        model.draft.publishAt = date
        #expect(try model.request().publishAt == date)

        model.draft.privacy = .unlisted
        #expect(!model.canSchedule)
        #expect(model.draft.publishAt == nil)
        #expect(try model.request().publishAt == nil)
        await model.validateNow()
        #expect(model.validationError == nil)

        model.draft.privacy = .public
        model.draft.publishAt = date
        #expect(model.draft.publishAt == nil)
        model.draft.privacy = .private
        model.draft.publishAt = date
        #expect(model.canSchedule && model.draft.publishAt == date)
        await model.validateNow()
        #expect(model.validationError == nil)
        #expect(
            ImageRenderer(
                content: PublishSheetView(model: model, onUpload: { _ in }, onCancel: {}).frame(
                    width: 520, height: 900)
            ).cgImage != nil)
    }

    @Test func sheetSelectsTheNewestDoneRenderAndEveryCaptionTrack() async throws {
        let f = try await PublishFixture.make(renders: 0)
        let older = try await f.addRender(name: "older.mp4")
        let newest = try await f.addRender(name: "newest.mp4")
        let queued = try await f.addRender(name: "queued.mp4", status: .queued)
        let failed = try await f.addRender(name: "failed.mp4", status: .failed)
        let model = await f.model()
        #expect(model.renderRecords.map(\.id) == [failed.id, queued.id, newest.id, older.id])
        #expect(model.publishableRenders.map(\.id) == [newest.id, older.id])
        #expect(model.draft.renderId == newest.id)
        #expect(model.renderHint == nil)
        #expect(PublishSheetView.renderLabel(newest).hasPrefix("newest.mp4 · H.264 1080p"))

        let captionTracks = f.sequence.tracks.filter { $0.kind == .caption }
        #expect(captionTracks.count == 1)
        #expect(model.captionTracks.map(\.trackId) == captionTracks.map(\.id))
        #expect(model.draft.captionTrackIds == captionTracks.map(\.id))
        #expect(model.captionTracks[0].cues == Fixtures.captionCues)
        #expect(model.captionTracks[0].language == "en")

        let request = try model.request()
        #expect(request.renderId == newest.id)
        #expect(request.fileURL == newest.outputURL)
        #expect(request.expectedContentHash == newest.outputHash)
        #expect(request.projectVersion == newest.projectVersion)
        #expect(request.captions.map(\.trackId) == captionTracks.map(\.id))
        #expect(request.captions[0].format == .srt)
        #expect(request.language == "en")
        #expect(request.durationSeconds == 12.5)
        #expect(request.width == 1920 && request.height == 1080)
        #expect(request.destination == .youtube && request.accountId == "sub-1")

        // Unticking the track drops it from the request; ticking restores track order.
        let id = captionTracks[0].id
        model.setCaptionTrack(id, selected: false)
        #expect(!model.isCaptionTrackSelected(id))
        #expect(try model.request().captions.isEmpty)
        model.setCaptionTrack(id, selected: true)
        #expect(try model.request().captions.count == 1)

        // Without a done render the sheet says so and cannot upload.
        let empty = try await PublishFixture.make(renders: 0)
        let none = await empty.model()
        #expect(none.draft.renderId == nil)
        #expect(none.renderHint == PublishText.exportFirst)
        #expect(!none.canUpload)
        #expect(throws: PublishSheetModel.RequestError.noRender) { try none.request() }
        #expect(
            ImageRenderer(
                content: PublishSheetView(model: none, onUpload: { _ in }, onCancel: {}).frame(
                    width: 520, height: 800)
            ).cgImage != nil)
    }

    @Test func sheetShowsValidationWarningsFromThePublisher() async throws {
        let f = try await PublishFixture.make()
        await f.publisher.setWarnOnValidate(true)
        let model = await f.model()
        #expect(model.warnings == ["fake warning"])
        #expect(model.validationError == nil)
        #expect(model.canUpload)
        let validatedAfterLoad = await f.publisher.validated.count

        // An edit validates again after the debounce, without an explicit call.
        model.draft.title = "   "
        #expect(await eventually { model.validationError != nil })
        #expect(model.validationError == PublishError.invalidRequest("title is empty").message)
        #expect(model.warnings.isEmpty)
        #expect(!model.canUpload)
        #expect(await f.publisher.validated.count == validatedAfterLoad + 1)

        // Several quick edits collapse into one validation.
        model.draft.title = "B"
        model.draft.title = "Ba"
        model.draft.title = "Band"
        #expect(await eventually { model.validationError == nil && model.warnings == ["fake warning"] })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await f.publisher.validated.count == validatedAfterLoad + 2)
        #expect(await f.publisher.validated.last?.title == "Band")
        #expect(model.canUpload)
        #expect(
            ImageRenderer(
                content: PublishSheetView(model: model, onUpload: { _ in }, onCancel: {}).frame(
                    width: 520, height: 900)
            ).cgImage != nil)
    }

    @Test func sheetShowsTheForcedPrivateNoticeWhenPublicUploadsAreNotAllowed() async throws {
        let f = try await PublishFixture.make()
        let model = await f.model()
        #expect(model.capabilities?.publicUploadsAllowed == false)
        #expect(model.forcedPrivateNotice == PublishCapabilities.unauditedNote)
        model.draft.privacy = .public
        #expect(model.forcedPrivateNotice == PublishCapabilities.unauditedNote)
        #expect(
            ImageRenderer(
                content: PublishSheetView(model: model, onUpload: { _ in }, onCancel: {}).frame(
                    width: 520, height: 900)
            ).cgImage != nil)

        await f.publisher.setCapabilities(PublishCapabilities(publicUploadsAllowed: true))
        await model.load()
        #expect(model.forcedPrivateNotice == nil)
        await f.publisher.setCapabilities(PublishCapabilities(publicUploadsAllowed: false, note: "Audit pending"))
        await model.load()
        #expect(model.forcedPrivateNotice == "Audit pending")
    }

    @Test func sheetShowsUploadsRemaining() async throws {
        let f = try await PublishFixture.make()
        let resetsAt = Fixtures.fixtureDate.addingTimeInterval(3600)
        await f.publisher.setQuota(PublishQuota(uploadsUsed: 97, unitsUsed: 5000, resetsAt: resetsAt))
        let model = await f.model()
        #expect(model.uploadsRemainingText == "3 uploads left today")
        #expect(model.canUpload)
        await f.publisher.setQuota(PublishQuota(uploadsUsed: 99, unitsUsed: 5000, resetsAt: resetsAt))
        await model.load()
        #expect(model.uploadsRemainingText == "1 upload left today")
        await f.publisher.setQuota(PublishQuota(uploadsUsed: 100, unitsUsed: 5000, resetsAt: resetsAt))
        await model.load()
        #expect(model.uploadsRemainingText == "0 uploads left today")
        #expect(!model.canUpload)
        #expect(
            ImageRenderer(
                content: PublishSheetView(model: model, onUpload: { _ in }, onCancel: {}).frame(
                    width: 520, height: 900)
            ).cgImage != nil)
    }

    @Test func draftCarriesMadeForKidsExplicitly() async throws {
        let f = try await PublishFixture.make()
        let model = await f.model()
        #expect(model.draft.madeForKids == false)
        #expect(try model.request().madeForKids == false)
        model.draft.madeForKids = true
        #expect(try model.request().madeForKids == true)

        // The draft encodes the field even when false, unlike the agent path's nil.
        let data = try ProjectCodec.encoder.encode(model.draft)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"madeForKids\":true"))
        let decoded = try ProjectCodec.decoder.decode(PublishDraft.self, from: data)
        #expect(decoded == model.draft)
        var plain = model.draft
        plain.madeForKids = false
        let plainJSON = try #require(String(data: try ProjectCodec.encoder.encode(plain), encoding: .utf8))
        #expect(plainJSON.contains("\"madeForKids\":false"))
        #expect(PublishText.madeForKidsHelp.contains("COPPA"))
        #expect(PublishText.syntheticMediaHelp.contains("AI"))

        // The other declarations and fields ride through too.
        model.draft.containsSyntheticMedia = true
        model.draft.tags = ["live", "rehearsal"]
        model.draft.description = "Recorded 2026-09-08."
        model.draft.categoryId = "10"
        model.draft.notifySubscribers = true
        model.draft.playlistId = "  PL-1 "
        let request = try model.request()
        #expect(request.containsSyntheticMedia && request.notifySubscribers)
        #expect(request.tags == ["live", "rehearsal"] && request.categoryId == "10")
        #expect(request.description == "Recorded 2026-09-08." && request.playlistId == "PL-1")
        #expect(PublishCategory.assignable.contains { $0.id == "10" && $0.name == "Music" })
    }

    @Test func sheetWritesTheThumbnailFrameIntoTheRequest() async throws {
        let f = try await PublishFixture.make()
        let model = await f.model()
        #expect(try model.request().thumbnail == nil)

        let image = try #require(
            CGContext(
                data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage())
        var grabbed: [RationalTime] = []
        model.frameGrabber = { time in
            grabbed.append(time)
            return image
        }
        await model.grabThumbnail()
        #expect(grabbed == [Fixtures.frames(30)])
        #expect(model.thumbnailImage != nil)

        let request = try model.request()
        let thumbnail = try #require(request.thumbnail)
        #expect(thumbnail.sourceTime == Fixtures.frames(30))
        #expect(thumbnail.fileURL.pathExtension == "jpg")
        #expect(FileManager.default.fileExists(atPath: thumbnail.fileURL.path))
        #expect(thumbnail.fileURL.lastPathComponent == "\(model.draft.publishId).jpg")
        // Validation never writes the file; turning the thumbnail off drops it from the request.
        #expect(try model.request(writingThumbnail: false).thumbnail == nil)
        model.draft.thumbnailAt = nil
        #expect(try model.request().thumbnail == nil)
        #expect(
            ImageRenderer(
                content: PublishSheetView(model: model, onUpload: { _ in }, onCancel: {}).frame(
                    width: 520, height: 900)
            ).cgImage != nil)
    }

    @Test func uploadHandsOverTheDraftOrTheRequest() async throws {
        let f = try await PublishFixture.make()
        let model = await f.model()
        model.draft.title = "Band rehearsal"
        let submitted = PublishSheetView(model: model, onSubmit: { _ in }, onCancel: {})
        #expect(ImageRenderer(content: submitted.frame(width: 520, height: 900)).cgImage != nil)
        // The built request is what the publisher validated and what the fake accepts as a job.
        let request = try model.request()
        #expect(try await f.publisher.validate(request).isEmpty)
        #expect(request.title == "Band rehearsal" && request.madeForKids == false)
    }
}

@MainActor
@Suite("Publish outcome, history, and approval cards")
struct PublishViewTests {
    @Test func outcomeViewLinksToYouTube() async throws {
        var receipt = Fixtures.publishReceipt()
        receipt.requestedPrivacy = .public
        receipt.warnings = ["Uploaded as private: project not audited"]
        let outcome = try JobOutcome(encoding: receipt, warnings: receipt.warnings)
        let view = PublishOutcomeView(outcome: outcome)
        #expect(view.receipt?.remoteURL == URL(string: "https://youtu.be/fake-video-1"))
        #expect(view.receipt?.studioURL == URL(string: "https://studio.youtube.com/video/fake-video-1/edit"))
        #expect(PublishOutcomeView.privacyText(receipt) == "Uploaded as private (public was requested)")
        #expect(view.receipt?.madeForKids == nil)
        #expect(ImageRenderer(content: view.frame(width: 320)).cgImage != nil)
        #expect(PublishOutcomeView(outcome: JobOutcome()).receipt == nil)
        #expect(ImageRenderer(content: PublishOutcomeView(outcome: JobOutcome()).frame(width: 320)).cgImage != nil)

        // A publish job through the job centre: progress rows show the stage, the finished row the links.
        let f = try await PublishFixture.make()
        let render = try #require(try await f.store.renders().first)
        let request = Fixtures.publishRequest(renderId: render.id, fileURL: try #require(render.outputURL))
        await f.publisher.setStepDelay(.milliseconds(10))
        let job = f.publisher.publish(request, publishId: "publish-1", resuming: nil, onEvent: { _ in })
        let center = JobCenter()
        let handle = await center.submit(job, to: FakeJobRunner())
        #expect(await eventually { center.entry(handle.id)?.progress.stage == PublishStage.upload.rawValue })
        let running = try #require(center.entry(handle.id))
        #expect(running.kind == .publish)
        #expect(JobProgressView.stateText(running).hasPrefix("Uploading"))
        #expect(ImageRenderer(content: JobProgressView(entry: running, onCancel: {}).frame(width: 320)).cgImage != nil)
        await center.drain()
        let finished = try #require(center.entry(handle.id))
        #expect(finished.state == .finished)
        #expect(JobProgressView.stateText(finished) == "Published")
        let payload = try #require(finished.outcome.flatMap(PublishOutcomeView.receipt(in:)))
        #expect(payload.remoteURL == URL(string: "https://youtu.be/fake-video-1"))
        #expect(payload.captionIds == ["fake-caption-1"])
        #expect(ImageRenderer(content: JobProgressView(entry: finished, onCancel: {}).frame(width: 320)).cgImage != nil)
        #expect(ImageRenderer(content: JobList(center: center).frame(width: 320)).cgImage != nil)
        #expect(JobProgressView.stageLabel("encoding", kind: .export) == "encoding")
        #expect(JobProgressView.stageLabel("processing", kind: .publish) == "Processing on YouTube")
    }

    @Test func historyOffersResumeOnlyForResumableRows() async throws {
        let f = try await PublishFixture.make()
        let render = try #require(try await f.store.renders().first)
        let request = Fixtures.publishRequest(renderId: render.id, fileURL: try #require(render.outputURL))
        let session = PublishSession(
            uploadURL: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=u1")!,
            totalBytes: 4096, bytesConfirmed: 2048, startedAt: Fixtures.fixtureDate)
        let done = try await f.store.recordPublish(id: "p-done", request: request, projectVersion: nil)
        _ = try await f.store.updatePublish(
            done.id,
            PublishUpdate(
                status: .done, clearsSession: true, remoteId: "fake-video-1",
                remoteURL: URL(string: "https://youtu.be/fake-video-1"), receipt: Fixtures.publishReceipt()))
        let failed = try await f.store.recordPublish(id: "p-failed", request: request, projectVersion: nil)
        _ = try await f.store.updatePublish(
            failed.id, PublishUpdate(status: .failed, session: session, bytesSent: 2048, error: "Network error"))
        let cancelled = try await f.store.recordPublish(id: "p-cancelled", request: request, projectVersion: nil)
        _ = try await f.store.updatePublish(cancelled.id, PublishUpdate(status: .cancelled, session: session))
        let abandoned = try await f.store.recordPublish(id: "p-abandoned", request: request, projectVersion: nil)
        _ = try await f.store.updatePublish(abandoned.id, PublishUpdate(status: .cancelled, clearsSession: true))
        let uploading = try await f.store.recordPublish(id: "p-uploading", request: request, projectVersion: nil)
        _ = try await f.store.updatePublish(uploading.id, PublishUpdate(status: .uploading, session: session))

        let model = PublishHistoryModel(ledger: f.store)
        await model.load()
        #expect(model.records.map(\.id) == ["p-uploading", "p-abandoned", "p-cancelled", "p-failed", "p-done"])
        #expect(model.resumable.map(\.id) == ["p-cancelled", "p-failed"])
        #expect(model.records.map(model.canResume) == [false, false, true, true, false])
        let failedRow = try #require(model.records.first { $0.id == "p-failed" })
        #expect(PublishHistoryRow.detailText(failedRow) == "failed · private")
        let doneRow = try #require(model.records.first { $0.id == "p-done" })
        #expect(PublishHistoryRow.detailText(doneRow) == "done · private · Skeleton Channel")
        #expect(doneRow.remoteURL == URL(string: "https://youtu.be/fake-video-1"))
        let uploadingRow = try #require(model.records.first { $0.id == "p-uploading" })
        #expect(PublishHistoryRow.detailText(uploadingRow) == "uploading · private")

        var resumed: [String] = []
        let view = PublishHistoryView(model: model) { resumed.append($0) }
        #expect(ImageRenderer(content: view.frame(width: 360)).cgImage != nil)
        view.onResume("p-failed")
        #expect(resumed == ["p-failed"])
        let fromLedger = PublishHistoryView(ledger: f.store, onResume: { _ in })
        #expect(ImageRenderer(content: fromLedger.frame(width: 360)).cgImage != nil)
    }

    @Test func approvalCardRendersDetailsAndWarnings() async throws {
        var request = Fixtures.approvalRequest(tool: "publish_youtube")
        request.presentation?.warnings = ["Portrait video over 3:00 will not be a Short"]
        let card = ApprovalCardView(request: request, onApprove: {}, onDeny: {})
        #expect(card.summary == "Publish \"Band rehearsal\" to YouTube as Private")
        #expect(card.summary == Fixtures.publishPresentation.summary)
        #expect(card.details.map(\.label) == ["Channel", "Privacy", "Certification"])
        #expect(card.details.last?.value == Fixtures.certificationSentence)
        #expect(card.warnings == ["Portrait video over 3:00 will not be a Short"])
        #expect(card.approveTitle == "Upload")
        #expect(ImageRenderer(content: card.frame(width: 360)).cgImage != nil)

        // The card reaches the stack through the centre like any other request.
        let fake = FakeApprovalGate(policy: .standard)
        let gate: any ApprovalGate = fake
        let center = ApprovalCenter(gate: gate)
        await center.start()
        defer { center.stop() }
        let decision = await gate.check(
            tool: "publish_youtube", input: ToolInput(["title": "Band rehearsal"]), estimate: Estimate(bytes: 4096),
            presentation: request.presentation, actor: .human, sessionId: nil)
        guard case .required(let raised) = decision else {
            Issue.record("expected approval_required")
            return
        }
        #expect(raised.presentation == request.presentation)
        #expect(await eventually { center.requests.contains { $0.id == raised.id } })
        #expect(ImageRenderer(content: ApprovalStackView(center: center).frame(width: 360)).cgImage != nil)
        await center.approve(raised)
        #expect(await gate.consume(raised.token))
        #expect(await fake.checks.last?.presentation == request.presentation)
    }

    @Test func approvalCardFallsBackToInputSummary() async throws {
        let request = Fixtures.approvalRequest()
        let card = ApprovalCardView(request: request, onApprove: {}, onDeny: {})
        #expect(request.presentation == nil)
        #expect(card.summary == "render_export(preset=reel9x16)")
        #expect(card.details.isEmpty && card.warnings.isEmpty)
        #expect(card.approveTitle == "Approve")
        #expect(ImageRenderer(content: card.frame(width: 360)).cgImage != nil)
    }
}
