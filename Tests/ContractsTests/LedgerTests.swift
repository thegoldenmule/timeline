import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@Suite struct LedgerTests {
    private func ledgers() throws -> (store: FakeProjectStore, renders: any RenderLedger, publishes: any PublishLedger)
    {
        let store = try Fixtures.store("three-clips")
        let base: any ProjectStore = store
        let renders = try #require(base as? any RenderLedger)
        let publishes = try #require(base as? any PublishLedger)
        return (store, renders, publishes)
    }

    @Test func fakeStoreKeepsRenderAndPublishLedgersOutsideTheEvents() async throws {
        let (store, renders, publishes) = try ledgers()
        let version = await store.version()
        let sequenceId = try #require(await store.state().activeSequenceId)
        let changes = store.changes
        let watcher = Task { await changes.first { _ in true } }

        let render = try await renders.recordRender(
            id: nil, sequenceId: sequenceId, preset: .h264_1080p, projectVersion: nil)
        #expect(render.status == .queued && render.projectVersion == version && render.completedAt == nil)
        #expect(render.id.isCanonicalUUID)
        let running = try await renders.updateRender(
            render.id, status: .running, outputURL: nil, outputHash: nil, receipt: nil)
        #expect(running.status == .running && running.completedAt == nil)
        let url = URL(fileURLWithPath: "/tmp/Exports/three-clips-h264_1080p.mp4")
        let receipt = ExportReceipt(
            preset: .h264_1080p, sequenceId: sequenceId, projectVersion: version, outputURL: url, durationSeconds: 12,
            startedAt: Fixtures.fixtureDate, finishedAt: Fixtures.fixtureDate, outputHash: "sha256-abc")
        let done = try await renders.updateRender(
            render.id, status: .done, outputURL: url, outputHash: "sha256-abc", receipt: receipt)
        #expect(
            done.status == .done && done.completedAt != nil && done.outputURL == url && done.outputHash == "sha256-abc")
        #expect(done.receipt == receipt)
        #expect(try await renders.render(render.id) == done)
        #expect(try await renders.render("missing") == nil)

        let older = try await renders.recordRender(
            id: "r-explicit", sequenceId: sequenceId, preset: .reel9x16, projectVersion: 3)
        #expect(older.id == "r-explicit" && older.projectVersion == 3)
        #expect(try await renders.renders().map(\.id) == ["r-explicit", render.id], "newest first")

        var request = Fixtures.publishRequest(renderId: render.id)
        request.projectVersion = nil
        let publish = try await publishes.recordPublish(id: nil, request: request, projectVersion: nil)
        #expect(publish.status == .queued && publish.renderId == render.id && publish.projectVersion == version)
        #expect(publish.destination == .youtube && publish.accountId == "sub-1" && publish.request == request)
        #expect(publish.bytesTotal == nil, "the fixture file does not exist")
        let explicit = try await publishes.recordPublish(id: "p-explicit", request: request, projectVersion: 7)
        #expect(explicit.id == "p-explicit" && explicit.projectVersion == 7)
        #expect(try await publishes.publishes().map(\.id) == ["p-explicit", publish.id])
        #expect(try await publishes.publish(publish.id) == publish)
        #expect(try await publishes.publish("missing") == nil)

        #expect(await store.version() == version, "ledgers never bump the version")
        watcher.cancel()
        #expect(await watcher.value == nil, "ledgers never publish a ProjectChange")
        #expect(await store.storedEvents.count == Int(version))
        try await store.rebuildProjections()
    }

    @Test func publishLedgerLinksToRenderAndRefusesUnknownRenders() async throws {
        let (store, renders, publishes) = try ledgers()
        let sequenceId = try #require(await store.state().activeSequenceId)
        await #expect(throws: FakeStoreError.unknownRecord("render-1")) {
            _ = try await publishes.recordPublish(
                id: nil, request: Fixtures.publishRequest(renderId: "render-1"), projectVersion: nil)
        }
        let a = try await renders.recordRender(
            id: "r-a", sequenceId: sequenceId, preset: .h264_1080p, projectVersion: nil)
        let b = try await renders.recordRender(
            id: "r-b", sequenceId: sequenceId, preset: .reel9x16, projectVersion: nil)
        let p1 = try await publishes.recordPublish(
            id: "p-1", request: Fixtures.publishRequest(renderId: a.id), projectVersion: nil)
        let p2 = try await publishes.recordPublish(
            id: "p-2", request: Fixtures.publishRequest(renderId: a.id), projectVersion: nil)
        _ = try await publishes.recordPublish(
            id: "p-3", request: Fixtures.publishRequest(renderId: b.id), projectVersion: nil)
        #expect(try await publishes.publishes(forRender: a.id).map(\.id) == [p2.id, p1.id])
        #expect(try await publishes.publishes(forRender: b.id).map(\.id) == ["p-3"])
        #expect(try await publishes.publishes(forRender: "nope").isEmpty)
        await #expect(throws: FakeStoreError.unknownRecord("missing")) {
            _ = try await renders.updateRender("missing", status: .done, outputURL: nil, outputHash: nil, receipt: nil)
        }
        await #expect(throws: FakeStoreError.unknownRecord("missing")) {
            _ = try await publishes.updatePublish("missing", PublishUpdate(status: .done))
        }
    }

    @Test func terminalStatesSetCompletedAt() async throws {
        let (store, renders, publishes) = try ledgers()
        let sequenceId = try #require(await store.state().activeSequenceId)
        for status in RenderStatus.allCases {
            let render = try await renders.recordRender(
                id: nil, sequenceId: sequenceId, preset: .proRes, projectVersion: nil)
            let updated = try await renders.updateRender(
                render.id, status: status, outputURL: nil, outputHash: nil, receipt: nil)
            #expect((updated.completedAt != nil) == status.isTerminal, "\(status)")
        }
        let render = try await renders.recordRender(
            id: "r-1", sequenceId: sequenceId, preset: .proRes, projectVersion: nil)
        for status in PublishStatus.allCases {
            let publish = try await publishes.recordPublish(
                id: nil, request: Fixtures.publishRequest(renderId: render.id), projectVersion: nil)
            let updated = try await publishes.updatePublish(publish.id, PublishUpdate(status: status))
            #expect((updated.completedAt != nil) == status.isTerminal, "\(status)")
            #expect(updated.status == status)
        }
        // An update without a status leaves status and completedAt alone.
        let publish = try await publishes.recordPublish(
            id: "p-partial", request: Fixtures.publishRequest(renderId: render.id), projectVersion: nil)
        let partial = try await publishes.updatePublish(publish.id, PublishUpdate(bytesSent: 12, error: "later"))
        #expect(
            partial.status == .queued && partial.completedAt == nil && partial.bytesSent == 12
                && partial.error == "later")
    }

    @Test func clearsSessionDropsTheUploadURL() async throws {
        let (store, renders, publishes) = try ledgers()
        let sequenceId = try #require(await store.state().activeSequenceId)
        let render = try await renders.recordRender(
            id: "r-1", sequenceId: sequenceId, preset: .h264_1080p, projectVersion: nil)
        let publish = try await publishes.recordPublish(
            id: "p-1", request: Fixtures.publishRequest(renderId: render.id), projectVersion: nil)
        let session = PublishSession(
            uploadURL: URL(
                string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=abc")!,
            totalBytes: 100, bytesConfirmed: 40, startedAt: Fixtures.fixtureDate)
        let uploading = try await publishes.updatePublish(
            publish.id, PublishUpdate(status: .uploading, session: session, bytesSent: 40))
        #expect(uploading.session == session && uploading.bytesSent == 40 && uploading.status == .uploading)
        let remoteURL = URL(string: "https://youtu.be/fake-video-1")!
        let processing = try await publishes.updatePublish(
            publish.id, PublishUpdate(status: .processing, remoteId: "fake-video-1", remoteURL: remoteURL))
        #expect(processing.session == session, "nil leaves the session alone")
        #expect(processing.remoteId == "fake-video-1" && processing.remoteURL == remoteURL)
        let done = try await publishes.updatePublish(
            publish.id, PublishUpdate(status: .done, clearsSession: true, receipt: Fixtures.publishReceipt()))
        #expect(done.session == nil && done.receipt == Fixtures.publishReceipt() && done.completedAt != nil)
        #expect(!done.isResumable)
        let json = String(decoding: try ProjectCodec.encode(done), as: UTF8.self)
        #expect(!json.contains("upload_id"))

        let failed = try await publishes.recordPublish(
            id: "p-2", request: Fixtures.publishRequest(renderId: render.id), projectVersion: nil)
        let kept = try await publishes.updatePublish(
            failed.id, PublishUpdate(status: .failed, session: session, error: "network"))
        #expect(kept.isResumable && kept.session == session)
    }

    @Test func fakeRendererExportCarriesTheOutputHash() async throws {
        let services = try await TestServices.make()
        let project = await services.store.state()
        let sequence = try #require(project.activeSequence)
        let compiled = try await services.renderer.compile(sequence, assets: project.assets, options: .full)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LedgerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.mp4")
        let outcome = try await services.jobRunner.submit(
            services.renderer.export(compiled, preset: .h264_1080p, to: url)
        ).wait()
        let receipt = try #require(try outcome.payload(as: ExportReceipt.self))
        let hash = try FileHash.sha256(of: url)
        #expect(receipt.outputHash == hash)
        #expect(receipt.outputHash?.hasPrefix("sha256-") == true && receipt.outputHash?.count == 7 + 64)
        // Receipts written before the ledger existed decode with a nil hash.
        var json = try JSONValue(encoding: receipt).objectValue ?? [:]
        json.removeValue(forKey: "outputHash")
        #expect(try JSONValue.object(json).decoded(as: ExportReceipt.self).outputHash == nil)
    }
}
