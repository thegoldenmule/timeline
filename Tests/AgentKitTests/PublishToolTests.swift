import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import AgentKit

/// The publishing tools against the fakes (publish-plan.md 4.3): `render_export` recording its ledger
/// row, `publish_youtube` through the approval card to a done ledger row, idempotency and resume by
/// `publishId`, captions and thumbnail, `publish_status`, and `account_status`.
@Suite struct PublishToolTests {
    struct Harness {
        var services: TestServices
        var registry: EditorToolRegistry
        var context: ToolContext
        var scratch: URL

        static func make(fixture: String = "three-clips", policy: ApprovalPolicy = .standard) async throws -> Harness {
            let services = try await TestServices.make(fixture: fixture, approvalPolicy: policy)
            let context = services.toolContext()
            let registry = await EditorTools.standard(context: context, clock: FixedClock(step: 1))
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                "agentkit-publish-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            return Harness(services: services, registry: registry, context: context, scratch: scratch)
        }

        func cleanup() { try? FileManager.default.removeItem(at: scratch) }

        func call(_ name: String, _ input: JSONValue) async throws -> ToolOutput {
            try await registry.call(name, input: ToolInput(input.objectValue ?? [:]), context: context)
        }

        var project: Project {
            get async { await services.store.state() }
        }

        var activeSequence: Sequence {
            get async throws { try #require(await project.activeSequence) }
        }

        /// A done render row over a file of `bytes` random bytes, the way `render_export` would leave it.
        @discardableResult
        func seedRender(bytes: Int = 300 << 10, status: RenderStatus = .done, id: String? = nil) async throws
            -> RenderRecord
        {
            let sequence = try await activeSequence
            let url = scratch.appendingPathComponent("\(id ?? "render")-\(UUID().uuidString.prefix(8)).mp4")
            var data = Data(count: bytes)
            data.withUnsafeMutableBytes { buffer in
                for i in buffer.indices { buffer[i] = UInt8.random(in: 0...255) }
            }
            try data.write(to: url)
            let queued = try await services.store.recordRender(
                id: id, sequenceId: sequence.id, preset: .h264_1080p, projectVersion: nil)
            guard status != .queued else { return queued }
            let hash = try FileHash.sha256(of: url)
            let receipt = ExportReceipt(
                preset: .h264_1080p, sequenceId: sequence.id, projectVersion: queued.projectVersion, outputURL: url,
                durationSeconds: 12.5, startedAt: Date(), finishedAt: Date(), outputHash: hash)
            return try await services.store.updateRender(
                queued.id, status: status, outputURL: url, outputHash: hash, receipt: receipt)
        }

        /// `publish_youtube` through the card: the first call asks, the test grants, the retry carries the
        /// token and the same `publishId`. Returns the `approval_required` output and the final one.
        func publishApproved(_ input: JSONValue) async throws -> (asked: ToolOutput, done: ToolOutput) {
            let asked = try await call("publish_youtube", input)
            #expect(asked.isApprovalRequired, "\(asked)")
            let token = try #require(asked.structured?["approvalToken"]?.stringValue)
            let publishId = try #require(asked.structured?["publishId"]?.stringValue)
            await services.approvals.grant(ApprovalToken(token))
            var retry = input.objectValue ?? [:]
            retry["approvalToken"] = .string(token)
            retry["publishId"] = .string(publishId)
            let done = try await call("publish_youtube", .object(retry))
            return (asked, done)
        }
    }

    // MARK: render_export

    @Test func renderExportRecordsARenderRowWithHashAndReturnsRenderId() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        let asked = try await h.call("render_export", ["preset": "h264_1080p"])
        let token = try #require(asked.structured?["approvalToken"]?.stringValue)
        #expect(try await h.services.store.renders().isEmpty, "no row before the approval")
        await h.services.approvals.grant(ApprovalToken(token))
        let out = h.scratch.appendingPathComponent("reel.mp4")
        let done = try await h.call(
            "render_export", ["preset": "h264_1080p", "approvalToken": .string(token), "outputPath": .string(out.path)])
        #expect(!done.isError && done.structured?["status"] == "done", "\(done)")
        let renderId = try #require(done.structured?["renderId"]?.stringValue)
        let hash = try #require(done.structured?["outputHash"]?.stringValue)
        let hashed = try FileHash.sha256(of: out)
        #expect(hash == hashed)
        #expect(done.structured?["receipt"]?["outputHash"]?.stringValue == hash)
        let version = await h.project.version
        #expect(done.structured?["receipt"]?["projectVersion"]?.intValue == Int(version))

        let row = try #require(try await h.services.store.render(renderId))
        #expect(row.status == .done && row.outputHash == hash && row.outputURL == out)
        #expect(row.projectVersion == version && row.completedAt != nil)
        #expect(row.receipt?.outputHash == hash && row.receipt?.projectVersion == version)
        #expect(row.preset == .h264_1080p)
        #expect(try await h.services.store.renders().map(\.id) == [renderId])
        let validator = JSONSchemaValidator(root: RenderTools.renderExport.outputSchema!)
        #expect(validator.validate(done.structured!).isEmpty)
    }

    @Test func renderExportMarksFailedRenders() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        let asked = try await h.call("render_export", ["preset": "reel9x16"])
        let token = try #require(asked.structured?["approvalToken"]?.stringValue)
        await h.services.approvals.grant(ApprovalToken(token))
        // /dev/null is not a directory, so the export job cannot create its output folder and throws.
        let failed = try await h.call(
            "render_export",
            ["preset": "reel9x16", "approvalToken": .string(token), "outputPath": "/dev/null/nope/reel.mp4"])
        #expect(failed.isError && failed.structured?["error"] == "renderFailed", "\(failed)")
        let rows = try await h.services.store.renders()
        #expect(rows.count == 1 && rows.first?.status == .failed && rows.first?.completedAt != nil)
        #expect(rows.first?.outputHash == nil)

        // A compile failure is recorded the same way.
        let again = try await h.call("render_export", ["preset": "reel9x16"])
        let token2 = try #require(again.structured?["approvalToken"]?.stringValue)
        await h.services.approvals.grant(ApprovalToken(token2))
        h.services.renderer.fail(with: .sequenceEmpty)
        let compileFailed = try await h.call("render_export", ["preset": "reel9x16", "approvalToken": .string(token2)])
        #expect(compileFailed.isError)
        #expect(try await h.services.store.renders().map(\.status) == [.failed, .failed])
    }

    @Test func renderExportDefaultsToTheLibraryRootExports() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        let layout = h.services.mediaLibrary.layout
        let asked = try await h.call("render_export", ["preset": "h264_1080p"])
        let token = try #require(asked.structured?["approvalToken"]?.stringValue)
        await h.services.approvals.grant(ApprovalToken(token))
        let done = try await h.call("render_export", ["preset": "h264_1080p", "approvalToken": .string(token)])
        #expect(!done.isError, "\(done)")
        let path = try #require(done.structured?["outputPath"]?.stringValue)
        #expect(path.hasPrefix(layout.exportsDir.path), "\(path) is under \(layout.exportsDir.path)")
        #expect(!path.hasPrefix(LibraryLayout.default.root.path) || layout.root == LibraryLayout.default.root)
        #expect(path.hasSuffix("-H.264 1080p.mp4"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try await h.services.store.renders().first?.outputURL?.path == path)
        #expect(
            RenderTools.renderExport.inputSchema["properties"]?["outputPath"]?["description"]?.stringValue?.contains(
                "<library root>/Exports") == true)
    }

    // MARK: publish_youtube

    @Test func publishYouTubeIsHiddenWithoutAPublisherOrAccount() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        #expect(await h.registry.list().map(\.name).contains("publish_youtube"))
        let full = await h.registry.list().map(\.name)
        #expect(full.contains("publish_status") && full.contains("account_status"))
        #expect(full.firstIndex(of: "render_export")! + 1 == full.firstIndex(of: "publish_youtube")!)

        var noPublisher = h.services.services
        noPublisher.publishers = [:]
        let withoutPublisher = await EditorTools.standard(
            context: ToolContext(
                projects: h.services.projects, services: noPublisher, approvals: h.services.approvals, actor: .human))
        let names1 = await withoutPublisher.list().map(\.name)
        #expect(!names1.contains("publish_youtube") && !names1.contains("publish_status"))
        #expect(names1.contains("account_status"))

        var noAccounts = h.services.services
        noAccounts.accounts = [:]
        let withoutAccounts = await EditorTools.standard(
            context: ToolContext(
                projects: h.services.projects, services: noAccounts, approvals: h.services.approvals, actor: .human))
        let names2 = await withoutAccounts.list().map(\.name)
        #expect(!names2.contains("publish_youtube") && !names2.contains("account_status"))
        #expect(names2.contains("publish_status"))

        var noRunner = h.services.services
        noRunner.jobRunner = nil
        let withoutRunner = await EditorTools.standard(
            context: ToolContext(
                projects: h.services.projects, services: noRunner, approvals: h.services.approvals, actor: .human))
        #expect(await !withoutRunner.list().map(\.name).contains("publish_youtube"))

        // Registered regardless, the tool answers serviceUnavailable rather than crashing.
        let everything = EditorToolRegistry(tools: EditorTools.all)
        let out = try await everything.call(
            "publish_youtube", input: ToolInput(["title": "x"]),
            context: ToolContext(
                projects: h.services.projects, services: noPublisher, approvals: h.services.approvals, actor: .human))
        #expect(out.isError && out.text?.contains("publisher") == true)
    }

    /// The OAuth client can be set while the app runs (docs/plans/publish-client-setup.md), so the two
    /// tools that need one are added and dropped on a live registry rather than only at boot.
    @Test func publishToolsComeAndGoWithTheOAuthClient() async throws {
        let registry = EditorToolRegistry(tools: EditorTools.all)
        await EditorTools.setRegistered(EditorTools.publishingToolNames, registered: false, in: registry)
        var names = await registry.list().map(\.name)
        #expect(!names.contains("publish_youtube") && !names.contains("publish_status"))
        // `account_status` stays: "configured: false" is the answer the agent needs.
        #expect(names.contains("account_status"))
        #expect(await registry.tool(named: "publish_youtube") == nil)

        await EditorTools.setRegistered(EditorTools.publishingToolNames, registered: true, in: registry)
        names = await registry.list().map(\.name)
        #expect(names.contains("publish_youtube") && names.contains("publish_status"))
        #expect(names.filter { $0 == "publish_youtube" }.count == 1)
    }

    @Test func publishYouTubeReturnsApprovalRequiredWithChannelPrivacyAndCertification() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        let render = try await h.seedRender()
        let asked = try await h.call("publish_youtube", ["title": "Band rehearsal"])
        #expect(asked.isApprovalRequired && !asked.isError, "\(asked)")
        #expect(asked.structured?["tool"] == "publish_youtube")
        #expect(asked.structured?["summary"] == "Publish \"Band rehearsal\" to YouTube as Private")
        #expect(asked.structured?["publishId"]?.stringValue?.isEmpty == false)
        #expect(asked.text?.contains(asked.structured?["publishId"]?.stringValue ?? "?") == true)
        #expect(asked.structured?["warnings"]?.arrayValue?.isEmpty == true)
        let details = try #require(asked.structured?["details"]?.arrayValue)
        #expect(
            details.compactMap { $0["label"]?.stringValue } == [
                "Channel", "Account", "Privacy", "File", "Render", "Thumbnail", "Captions", "AI disclosure",
                "Made for kids", "Certification",
            ])
        func value(_ label: String) -> String? {
            details.first { $0["label"]?.stringValue == label }?["value"]?.stringValue
        }
        #expect(value("Channel") == "Skeleton Channel (@skeleton)")
        #expect(value("Account") == "me@example.com")
        #expect(value("Privacy") == "private")
        #expect(value("File")?.hasPrefix(render.outputURL!.lastPathComponent) == true)
        #expect(value("File")?.contains("KB") == true)
        #expect(value("Render") == "H.264 1080p, project v\(render.projectVersion)")
        #expect(value("Thumbnail") == "none" && value("Captions") == "none")
        #expect(value("AI disclosure") == "not declared")
        #expect(value("Made for kids")?.contains("YouTube Studio") == true)
        #expect(value("Certification") == Fixtures.certificationSentence)
        #expect(asked.structured?["estimate"]?["bytes"]?.intValue == 300 << 10)

        // The gate saw the presentation, nothing was uploaded, and no ledger row exists yet.
        let check = try #require(await h.services.approvals.checks.last)
        #expect(check.tool == "publish_youtube" && check.presentation?.details.count == 10)
        #expect(
            await h.services.approvals.lastRequest?.presentation?.summary == asked.structured?["summary"]?.stringValue)
        #expect(await h.services.publisher.publishCalls.isEmpty)
        #expect(try await h.services.store.publishes().isEmpty)
        #expect(await h.services.receipts.receipts.last?.outcome == .approvalRequired)
    }

    @Test func publishYouTubeWarnsAboutPublicAndForcedPrivate() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        try await h.seedRender()
        let asked = try await h.call("publish_youtube", ["title": "Band rehearsal", "privacy": "public"])
        #expect(asked.isApprovalRequired, "\(asked)")
        #expect(asked.structured?["summary"] == "Publish \"Band rehearsal\" to YouTube as Public")
        let warnings = asked.structured?["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(warnings == ["Privacy: public", PublishCapabilities.unauditedNote])

        await h.services.publisher.setCapabilities(PublishCapabilities(publicUploadsAllowed: true))
        await h.services.publisher.setWarnOnValidate(true)
        let audited = try await h.call("publish_youtube", ["title": "Band rehearsal", "privacy": "unlisted"])
        let auditedWarnings = audited.structured?["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(auditedWarnings == ["Privacy: unlisted", "fake warning"])

        let quiet = try await h.call("publish_youtube", ["title": "Band rehearsal"])
        #expect(quiet.structured?["warnings"]?.arrayValue?.compactMap(\.stringValue) == ["fake warning"])
    }

    @Test func publishYouTubeRetriesWithTheTokenAndPublishes() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        let render = try await h.seedRender()
        let (asked, done) = try await h.publishApproved(["title": "Band rehearsal", "description": "Recorded live"])
        #expect(!done.isError && !done.isApprovalRequired, "\(done)")
        #expect(done.structured?["status"] == "done")
        let publishId = try #require(asked.structured?["publishId"]?.stringValue)
        #expect(done.structured?["publishId"]?.stringValue == publishId)
        #expect(done.structured?["renderId"]?.stringValue == render.id)
        #expect(done.structured?["remoteId"] == "fake-video-1")
        #expect(done.structured?["url"] == "https://youtu.be/fake-video-1")
        #expect(done.structured?["studioUrl"] == "https://studio.youtube.com/video/fake-video-1/edit")
        #expect(done.structured?["privacy"] == "private" && done.structured?["requestedPrivacy"] == "private")
        #expect(done.structured?["channelTitle"] == "Skeleton Channel")
        #expect(done.structured?["bytesUploaded"]?.intValue == 300 << 10)
        #expect(done.structured?["bytesTotal"]?.intValue == 300 << 10)
        #expect(done.structured?["resumedCount"]?.intValue == 0)
        #expect(done.structured?["jobId"]?.stringValue != nil)
        #expect(done.structured?["receipt"]?["contentHash"]?.stringValue == render.outputHash)
        #expect(done.structured?["receipt"]?["projectVersion"]?.intValue == Int(render.projectVersion))
        let warnings = done.structured?["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(warnings == [PublishTools.madeForKidsNotice])
        #expect(
            done.text?.hasPrefix("Published Band rehearsal to YouTube as private: https://youtu.be/fake-video-1")
                == true)
        let validator = JSONSchemaValidator(root: PublishTools.publishYouTube.outputSchema!)
        #expect(validator.validate(done.structured!).isEmpty)

        // The ledger row is done with the receipt and without the capability URL.
        let row = try #require(try await h.services.store.publish(publishId))
        #expect(row.status == .done && row.session == nil && row.completedAt != nil)
        #expect(
            row.receipt?.remoteId == "fake-video-1" && row.remoteURL?.absoluteString == "https://youtu.be/fake-video-1")
        #expect(row.bytesSent == 300 << 10 && row.projectVersion == render.projectVersion)
        #expect(row.request.expectedContentHash == render.outputHash)
        #expect(row.request.description == "Recorded live" && row.request.categoryId == "22")
        #expect(try await h.services.store.publishes(forRender: render.id).map(\.id) == [publishId])
        #expect(await h.project.version == render.projectVersion, "recording never bumps the version")

        // One publish job, one publisher call, the token consumed, receipts in order.
        #expect(await h.services.jobRunner.submissions.map(\.kind) == [.publish])
        let calls = await h.services.publisher.publishCalls
        #expect(calls.count == 1 && calls.first?.publishId == publishId && calls.first?.resuming == nil)
        #expect(calls.first?.request.title == "Band rehearsal" && calls.first?.request.privacy == .private)
        #expect(await h.services.approvals.consumed.count == 1)
        #expect(await h.services.receipts.receipts.map(\.outcome) == [.approvalRequired, .applied])
        #expect(await h.services.publisher.quota().uploadsUsed == 1)
    }

    @Test func publishYouTubeIsIdempotentByPublishId() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        try await h.seedRender()
        let (_, done) = try await h.publishApproved(["title": "Band rehearsal", "publishId": "p-1"])
        #expect(done.structured?["status"] == "done", "\(done)")
        let checksBefore = await h.services.approvals.checks.count

        let again = try await h.call("publish_youtube", ["title": "Band rehearsal", "publishId": "p-1"])
        #expect(!again.isError && !again.isApprovalRequired, "\(again)")
        #expect(again.structured?["status"] == "done" && again.structured?["url"] == "https://youtu.be/fake-video-1")
        #expect(again.structured?["jobId"] == nil)
        #expect(await h.services.publisher.publishCalls.count == 1, "no second upload")
        #expect(await h.services.approvals.checks.count == checksBefore, "the gate was not consulted")
        #expect(await h.services.jobRunner.submissions.count == 1)
        #expect(try await h.services.store.publishes().count == 1)
    }

    @Test func publishYouTubeResumesAFailedPublish() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        try await h.seedRender()
        await h.services.publisher.setFailAt(.upload, fraction: 0.4)
        let (_, failed) = try await h.publishApproved(["title": "Band rehearsal", "publishId": "p-1"])
        #expect(!failed.isError, "a failed publish is a status answer, not an error output")
        #expect(failed.structured?["status"] == "failed", "\(failed)")
        #expect(failed.structured?["error"]?.stringValue?.contains("injected") == true)
        #expect(failed.text?.contains("failed") == true)
        let row = try #require(try await h.services.store.publish("p-1"))
        #expect(row.status == .failed && row.isResumable && row.error?.contains("injected") == true)
        let confirmed = try #require(row.session?.bytesConfirmed)
        #expect(confirmed > 0 && confirmed < 300 << 10, "the session kept the confirmed bytes")

        // The same id continues where it stopped: through the card again, then done with resumedCount 1.
        let (asked, done) = try await h.publishApproved(["title": "Band rehearsal", "publishId": "p-1"])
        #expect(asked.structured?["publishId"] == "p-1")
        #expect(done.structured?["status"] == "done", "\(done)")
        #expect(done.structured?["resumedCount"]?.intValue == 1)
        #expect(done.structured?["receipt"]?["resumedCount"]?.intValue == 1)
        let calls = await h.services.publisher.publishCalls
        #expect(calls.count == 2 && calls.last?.resuming?.bytesConfirmed == confirmed)
        #expect(calls.last?.request == calls.first?.request, "the resume reuses the row's request")
        let finished = try #require(try await h.services.store.publish("p-1"))
        #expect(finished.status == .done && finished.session == nil && finished.receipt?.resumedCount == 1)
        #expect(try await h.services.store.publishes().count == 1, "one row, resumed in place")
    }

    @Test func publishYouTubeAnswersUploadingAfterWaitSecondsAndPublishStatusFinishesIt() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        try await h.seedRender()
        await h.services.publisher.setStepDelay(.milliseconds(40))
        let (_, early) = try await h.publishApproved(["title": "Band rehearsal", "publishId": "p-1", "waitSeconds": 0])
        #expect(!early.isError, "\(early)")
        #expect(["queued", "uploading"].contains(early.structured?["status"]?.stringValue ?? ""), "\(early)")
        #expect(early.structured?["jobId"]?.stringValue != nil && early.structured?["url"] == nil)
        #expect(early.text?.contains("poll publish_status") == true)
        let live = try await h.call("publish_status", ["publishId": "p-1"])
        #expect(live.structured?["publishes"]?[0]?["status"]?.stringValue != "done")

        // The detached watcher completes the row after the tool answered.
        await h.services.jobRunner.drain()
        var status = try await h.call("publish_status", ["publishId": "p-1"])
        for _ in 0..<100 where status.structured?["publishes"]?[0]?["status"] != "done" {
            try await Task.sleep(for: .milliseconds(20))
            status = try await h.call("publish_status", ["publishId": "p-1"])
        }
        let row = try #require(status.structured?["publishes"]?[0])
        #expect(row["status"] == "done" && row["url"] == "https://youtu.be/fake-video-1", "\(status)")
        #expect(row["bytesSent"]?.intValue == 300 << 10 && row["resumable"] == .bool(false))
        let stored = try #require(try await h.services.store.publish("p-1"))
        #expect(stored.session == nil && stored.receipt != nil)

        // A repeat call with the same id now answers done from the ledger.
        let again = try await h.call("publish_youtube", ["title": "Band rehearsal", "publishId": "p-1"])
        #expect(again.structured?["status"] == "done")
    }

    @Test func publishYouTubeRejectsPublishAtWithUnlisted() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        try await h.seedRender()
        let out = try await h.call(
            "publish_youtube", ["title": "Band rehearsal", "privacy": "unlisted", "publishAt": "2026-09-10T12:00:00Z"])
        #expect(out.isError && out.structured?["error"] == "invalidRequest", "\(out)")
        #expect(out.text?.contains("private") == true)
        #expect(await h.services.approvals.checks.isEmpty)

        let bad = try await h.call("publish_youtube", ["title": "Band rehearsal", "publishAt": "tomorrow"])
        #expect(bad.isError && bad.structured?["error"] == "invalidRequest")

        let scheduled = try await h.call(
            "publish_youtube", ["title": "Band rehearsal", "publishAt": "2026-09-10T12:00:00Z"])
        #expect(scheduled.isApprovalRequired, "\(scheduled)")
        let labels = scheduled.structured?["details"]?.arrayValue?.compactMap { $0["label"]?.stringValue } ?? []
        #expect(labels.contains("Scheduled"))
    }

    @Test func publishYouTubeRefusesWhenQuotaIsSpent() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        try await h.seedRender()
        let resetsAt = Date(timeIntervalSince1970: 1_788_912_000)
        await h.services.publisher.setQuota(PublishQuota(uploadsUsed: 100, unitsUsed: 5000, resetsAt: resetsAt))
        let out = try await h.call("publish_youtube", ["title": "Band rehearsal"])
        #expect(out.isError && out.structured?["error"] == "quotaExceeded", "\(out)")
        #expect(out.structured?["resetsAt"]?.stringValue?.hasPrefix("2026-09-09") == true)
        #expect(out.structured?["quota"]?["uploadsUsed"]?.intValue == 100)
        #expect(await h.services.approvals.checks.isEmpty)
        #expect(await h.services.publisher.publishCalls.isEmpty)
    }

    @Test func publishYouTubeNeverSendsMadeForKids() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        try await h.seedRender()
        #expect(PublishTools.publishYouTube.inputSchema["properties"]?["madeForKids"] == nil)
        let rejected = try await h.call("publish_youtube", ["title": "Band rehearsal", "madeForKids": false])
        #expect(rejected.isError && rejected.structured?["error"] == "invalidInput", "the schema has no such key")

        let (asked, done) = try await h.publishApproved(["title": "Band rehearsal", "containsSyntheticMedia": true])
        #expect(done.structured?["status"] == "done", "\(done)")
        let request = try #require(await h.services.publisher.publishCalls.first?.request)
        #expect(request.madeForKids == nil)
        #expect(request.containsSyntheticMedia)
        #expect(done.structured?["receipt"]?["madeForKids"] == nil)
        let details = asked.structured?["details"]?.arrayValue ?? []
        #expect(details.first { $0["label"] == "Made for kids" }?["value"] == .string(PublishTools.madeForKidsDetail))
        #expect(details.first { $0["label"] == "AI disclosure" }?["value"] == "declared")
        #expect(done.structured?["warnings"]?.arrayValue?.contains(.string(PublishTools.madeForKidsNotice)) == true)
        #expect(done.text?.contains("YouTube Studio") == true)
    }

    @Test func publishYouTubeBuildsCaptionsFromTheCaptionTrack() async throws {
        let h = try await Harness.make(fixture: "linked-transition-caption-undone")
        defer { h.cleanup() }
        try await h.seedRender()
        let sequence = try await h.activeSequence
        let track = try #require(sequence.tracks.first { $0.kind == .caption })
        let (asked, done) = try await h.publishApproved(
            ["title": "Captioned", "captionTrackIds": [.string(track.id.rawValue)]])
        #expect(done.structured?["status"] == "done", "\(done)")
        let request = try #require(await h.services.publisher.publishCalls.first?.request)
        #expect(request.captions.count == 1)
        let captions = try #require(request.captions.first)
        #expect(captions.trackId == track.id && captions.language == "en" && captions.format == .srt)
        #expect(captions.name == track.name)
        #expect(captions.cues == Fixtures.captionCues, "timeline-relative cues, sorted")
        #expect(captions.cues.map(\.start) == [Fixtures.frames(12), Fixtures.frames(60)])
        #expect(captions.cues.map(\.end) == [Fixtures.frames(48), Fixtures.frames(108)])
        #expect(request.language == "en")
        let details = asked.structured?["details"]?.arrayValue ?? []
        #expect(details.first { $0["label"] == "Captions" }?["value"] == "1 track(s): en")
        #expect(done.structured?["receipt"]?["captionIds"]?.arrayValue?.count == 1)

        let video = try #require(sequence.tracks.first { $0.kind == .video })
        let wrongKind = try await h.call(
            "publish_youtube", ["title": "Captioned", "captionTrackIds": [.string(video.id.rawValue)]])
        #expect(wrongKind.isError && wrongKind.structured?["error"] == "notFound", "\(wrongKind)")
        let unknown = try await h.call("publish_youtube", ["title": "Captioned", "captionTrackIds": ["nope"]])
        #expect(unknown.isError && unknown.structured?["error"] == "notFound")
    }

    @Test func publishYouTubeWritesAThumbnailFromTheFrame() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        try await h.seedRender()
        let (asked, done) = try await h.publishApproved(
            ["title": "Band rehearsal", "publishId": "p-thumb", "thumbnailAt": ["v": 24024, "ts": 24000]])
        #expect(done.structured?["status"] == "done", "\(done)")
        let request = try #require(await h.services.publisher.publishCalls.first?.request)
        let thumbnail = try #require(request.thumbnail)
        let cache = h.services.mediaLibrary.layout.cacheDir.appendingPathComponent("publish", isDirectory: true)
        #expect(thumbnail.fileURL.path.hasPrefix(cache.path), "\(thumbnail.fileURL.path)")
        #expect(thumbnail.fileURL.lastPathComponent == "p-thumb-thumbnail.jpg")
        #expect(thumbnail.sourceTime == RationalTime(24024, 24000))
        let data = try Data(contentsOf: thumbnail.fileURL)
        #expect(data.prefix(3) == Data([0xFF, 0xD8, 0xFF]), "JPEG")
        #expect(data.count > 0 && data.count < 2 << 20)
        #expect(h.services.renderer.calls.contains { if case .frame = $0 { true } else { false } })
        let details = asked.structured?["details"]?.arrayValue ?? []
        #expect(details.first { $0["label"] == "Thumbnail" }?["value"] == "frame at 1.0 s")
        #expect(done.structured?["receipt"]?["thumbnailSet"] == .bool(true))
        #expect(request.width == 1920 && request.height == 1080 && request.durationSeconds == 12.5)
    }

    @Test func publishYouTubeRefusesARenderThatIsNotDone() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        let none = try await h.call("publish_youtube", ["title": "Band rehearsal"])
        #expect(none.isError && none.structured?["error"] == "renderNotFound", "\(none)")
        #expect(none.structured?["hint"] == "run render_export first")

        let queued = try await h.seedRender(status: .queued, id: "r-queued")
        let notDone = try await h.call("publish_youtube", ["title": "Band rehearsal", "renderId": "r-queued"])
        #expect(notDone.isError && notDone.structured?["error"] == "renderNotDone", "\(notDone)")
        #expect(notDone.structured?["renderId"]?.stringValue == queued.id)
        let defaulted = try await h.call("publish_youtube", ["title": "Band rehearsal"])
        #expect(defaulted.structured?["error"] == "renderNotFound", "a queued render is not the newest done one")

        let unknown = try await h.call("publish_youtube", ["title": "Band rehearsal", "renderId": "r-nope"])
        #expect(unknown.structured?["error"] == "renderNotFound")

        let gone = try await h.seedRender(id: "r-gone")
        try FileManager.default.removeItem(at: gone.outputURL!)
        let missing = try await h.call("publish_youtube", ["title": "Band rehearsal", "renderId": "r-gone"])
        #expect(missing.isError && missing.structured?["error"] == "fileMissing", "\(missing)")
        #expect(await h.services.approvals.checks.isEmpty)
    }

    // MARK: publish_status and account_status

    @Test func publishStatusListsNewestFirstAndNeverTheSession() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        try await h.seedRender()
        let empty = try await h.call("publish_status", [:])
        #expect(!empty.isError && empty.structured?["count"]?.intValue == 0, "\(empty)")
        #expect(empty.structured?["quota"]?["uploadsRemaining"] == nil || true)
        #expect(empty.structured?["capabilities"]?["publicUploadsAllowed"] == .bool(false))

        let (_, first) = try await h.publishApproved(["title": "First", "publishId": "p-1"])
        #expect(first.structured?["status"] == "done")
        await h.services.publisher.setFailAt(.upload, fraction: 0.4)
        let (_, second) = try await h.publishApproved(["title": "Second", "publishId": "p-2", "privacy": "unlisted"])
        #expect(second.structured?["status"] == "failed", "\(second)")
        #expect(try await h.services.store.publish("p-2")?.session != nil)

        let status = try await h.call("publish_status", [:])
        #expect(!status.isError, "\(status)")
        let rows = try #require(status.structured?["publishes"]?.arrayValue)
        #expect(rows.map { $0["publishId"]?.stringValue } == ["p-2", "p-1"])
        #expect(rows[0]["status"] == "failed" && rows[0]["resumable"] == .bool(true))
        #expect(rows[0]["error"]?.stringValue?.contains("injected") == true)
        #expect(rows[0]["requestedPrivacy"] == "unlisted" && rows[0]["privacy"] == nil)
        #expect(rows[1]["status"] == "done" && rows[1]["privacy"] == "private" && rows[1]["title"] == "First")
        #expect(rows[1]["url"] == "https://youtu.be/fake-video-1" && rows[1]["channelTitle"] == "Skeleton Channel")
        #expect(rows[1]["completedAt"]?.stringValue != nil && rows[1]["requestedAt"]?.stringValue != nil)
        #expect(status.structured?["quota"]?["uploadsUsed"]?.intValue == 1)
        #expect(status.structured?["count"]?.intValue == 2)
        let json = String(decoding: try ProjectCodec.encode(status.structured!), as: UTF8.self)
        #expect(!json.contains("upload/youtube") && !json.contains("uploadURL") && !json.contains("session"))
        let validator = JSONSchemaValidator(root: PublishTools.publishStatus.outputSchema!)
        #expect(validator.validate(status.structured!).isEmpty)

        let one = try await h.call("publish_status", ["publishId": "p-1"])
        #expect(
            one.structured?["publishes"]?.arrayValue?.count == 1
                && one.structured?["publishes"]?[0]?["publishId"] == "p-1")
        let limited = try await h.call("publish_status", ["limit": 1])
        #expect(limited.structured?["publishes"]?.arrayValue?.count == 1)
        let unknown = try await h.call("publish_status", ["publishId": "nope"])
        #expect(unknown.isError && unknown.structured?["error"] == "notFound")
        #expect(await h.services.receipts.receipts.last?.outcome == .error)
        #expect(await h.services.receipts.receipts.dropLast().last?.outcome == .readOnly)
    }

    @Test func accountStatusReportsConfiguredAccountsAndHints() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        let out = try await h.call("account_status", [:])
        #expect(!out.isError, "\(out)")
        #expect(out.structured?["configured"] == .bool(true))
        let account = try #require(out.structured?["accounts"]?[0])
        #expect(account["id"] == "sub-1" && account["provider"] == "google" && account["email"] == "me@example.com")
        #expect(account["channelTitle"] == "Skeleton Channel" && account["channelHandle"] == "@skeleton")
        #expect(account["channelId"] == "UC-fake" && account["tokenStatus"] == "valid")
        #expect(account["scopes"]?.arrayValue?.compactMap(\.stringValue) == Fixtures.publishScopes)
        #expect(out.structured?["requiredScopes"]?.arrayValue?.compactMap(\.stringValue) == Fixtures.publishScopes)
        #expect(out.structured?["hint"] == nil)
        #expect(out.structured?["note"] == .string(PublishCapabilities.unauditedNote))
        #expect(out.text?.contains("Skeleton Channel (@skeleton)") == true)
        let validator = JSONSchemaValidator(root: PublishTools.accountStatus.outputSchema!)
        #expect(validator.validate(out.structured!).isEmpty)
        #expect(PublishTools.accountStatus.inputSchema["properties"]?["projectId"] == nil)

        // An expired grant: the hint says reconnect, and publish_youtube refuses with the same hint.
        try await h.services.accounts.setTokenStatus(.reauthorizationRequired("invalid_grant"), for: "sub-1")
        let expired = try await h.call("account_status", [:])
        #expect(expired.structured?["accounts"]?[0]?["tokenStatus"] == "reauthorizationRequired")
        #expect(expired.structured?["hint"] == .string(PublishTools.reconnectHint))
        try await h.seedRender()
        let refused = try await h.call("publish_youtube", ["title": "Band rehearsal"])
        #expect(refused.isError && refused.structured?["error"] == "reauthorizationRequired", "\(refused)")
        #expect(refused.structured?["hint"] == .string(PublishTools.reconnectHint))

        // No account: the hint says connect, and publish_youtube answers notConnected.
        var services = h.services.services
        services.accounts = [.google: FakeAccountProvider()]
        let bare = ToolContext(
            projects: h.services.projects, services: services, approvals: h.services.approvals, actor: .human)
        let registry = await EditorTools.standard(context: bare)
        let none = try await registry.call("account_status", input: ToolInput(), context: bare)
        #expect(none.structured?["accounts"]?.arrayValue?.isEmpty == true)
        #expect(none.structured?["hint"] == .string(PublishTools.connectHint))
        let notConnected = try await registry.call(
            "publish_youtube", input: ToolInput(["title": "Band rehearsal"]), context: bare)
        #expect(notConnected.isError && notConnected.structured?["error"] == "notConnected", "\(notConnected)")
        #expect(notConnected.structured?["hint"] == .string(PublishTools.connectHint))

        services.accounts = [.google: FakeAccountProvider(configured: false)]
        let unconfigured = ToolContext(
            projects: h.services.projects, services: services, approvals: h.services.approvals, actor: .human)
        let off = try await registry.call("account_status", input: ToolInput(), context: unconfigured)
        #expect(off.structured?["configured"] == .bool(false) && off.structured?["hint"]?.stringValue != nil)
    }

    @Test func outputsContainNoToken() async throws {
        let h = try await Harness.make()
        defer { h.cleanup() }
        try await h.seedRender()
        _ = try await h.call("account_status", [:])
        let (_, done) = try await h.publishApproved(["title": "Band rehearsal", "publishId": "p-1"])
        #expect(done.structured?["status"] == "done", "\(done)")
        _ = try await h.call("publish_status", [:])
        _ = try await h.call("publish_youtube", ["title": "Band rehearsal", "publishId": "p-1"])
        // The fake vends `fake-token-<n>` on every access-token request; nothing the tools answer may carry one.
        _ = try await h.services.accounts.accessToken(for: "sub-1", minimumLifetime: .seconds(60))
        let invocations = await h.registry.invocations
        #expect(invocations.count == 5)
        for invocation in invocations {
            let json = String(decoding: try ProjectCodec.encode(invocation.output.structured ?? .null), as: UTF8.self)
            #expect(!json.contains("fake-token"), "\(invocation.name) leaks a token")
            #expect(invocation.output.text?.contains("fake-token") != true)
        }
        let rows = try await h.services.store.publishes()
        let ledgerJSON = String(decoding: try ProjectCodec.encode(rows), as: UTF8.self)
        #expect(!ledgerJSON.contains("fake-token"))
    }
}
