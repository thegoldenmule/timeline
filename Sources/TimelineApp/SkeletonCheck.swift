import AVFoundation
import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import TimelineCore
import TimelineUI

/// `swift run TimelineApp --skeleton-check`: the end-to-end check on the real services, without a
/// window. It boots the composition root over a temporary library root, creates a project, imports
/// synthetic media through the real library, edits through TimelineUI's view model and the tool
/// registry, runs analyses and an alignment through the job runner, talks to the MCP host over HTTP,
/// runs the scripted agent through the approval gate, undoes and redoes, then closes and reopens the
/// project. Prints one line per step; returns false (exit 1) with the reason on the first failure.
@MainActor
enum SkeletonCheck {
    struct Failure: Error, CustomStringConvertible {
        var step: String
        var reason: String
        var description: String { "\(step): \(reason)" }
    }

    static func run() async -> Bool {
        let started = ContinuousClock.now
        var steps: [String] = []
        func ok(_ step: String, _ detail: String) {
            steps.append(step)
            print("ok   \(step): \(detail)")
        }
        func require(_ condition: Bool, _ step: String, _ reason: @autoclosure () -> String) throws {
            if !condition { throw Failure(step: step, reason: reason()) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TimelineSkeleton-\(UUID().uuidString.prefix(8))", isDirectory: true)
        setenv("TIMELINE_ROOT", root.path, 1)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            // 1. Composition root over a temporary library root; the MCP host is listening after boot.
            let log = AppLog(echo: false)
            let services = try await AppServices.boot(root: root, agent: .fallback, log: log)
            try require(await services.mcpHost.isRunning, "boot", "MCP host is not running")
            try require(
                FileManager.default.fileExists(atPath: services.proxyConfigurationURL.path), "boot",
                "proxy configuration was not written")
            ok(
                "boot",
                "root \(root.lastPathComponent), MCP \(services.mcp.url.absoluteString), "
                    + "\(await services.registry.list().count) tools, agent fallback")

            // 2. Create a project in the temp root (SQLite package), open it, reach readyToPlay.
            let projectURL = services.layout.projectsDir.appendingPathComponent("Skeleton.tlproj", isDirectory: true)
            let document = try await ProjectDocument.create(at: projectURL, name: "Skeleton", using: services)
            try require(
                FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("project.sqlite").path),
                "create", "no project.sqlite in the package")
            try require(document.sequence?.tracks.count == 2, "create", "expected V1 and A1")
            try require(
                document.compiled == nil && document.lastRenderPath == .none, "create", "an empty sequence compiled")
            ok(
                "create",
                "\(document.project.name) v\(document.version) at \(projectURL.lastPathComponent); "
                    + "empty sequence, nothing to preview yet")

            // 3. Synthetic media through the real library: hash, copy, sidecar, cache row, asset command.
            let media = try TestMedia.Directory(prefix: "SkeletonMedia")
            defer { media.cleanup() }
            // 2 s: `TestMedia.videoWithAudio` can stall past a couple of seconds (RenderKit's note).
            let avClip = try await TestMedia.videoWithAudio(
                .tone(frequency: 440), duration: 2, in: media.url, name: "av-tone")
            let toneClip = try await TestMedia.tone(duration: 3, in: media.url, name: "tone")
            // The default parameters need 10 s fine windows and 10 s of overlap, so the render is 20 s.
            let pair = try await TestMedia.alignmentPair(
                cameraDuration: 60, renderDuration: 20, offsetSeconds: 7.345, driftPPM: 23, snrDB: 5, in: media.url,
                name: "pair")
            var imported: [String: Asset] = [:]
            for (label, url) in [
                ("av", avClip.url), ("tone", toneClip.url), ("camera", pair.camera.url), ("render", pair.render.url),
            ] {
                let handle = await services.jobRunner.submit(services.mediaLibrary.importJob(url: url, mode: .copy))
                let outcome = try await handle.wait()
                let result = try unwrap(try outcome.payload(as: ImportResult.self), "import", "no ImportResult")
                try require(!result.alreadyInLibrary, "import", "\(label) was already in the library")
                try require(
                    result.libraryURL.path.hasPrefix(services.layout.libraryDir.path), "import",
                    "\(label) landed outside the library: \(result.libraryURL.path)")
                try require(
                    FileManager.default.fileExists(atPath: result.libraryURL.appendingPathExtension("json").path),
                    "import", "\(label) has no sidecar")
                try require(result.asset.contentHash.hasPrefix("sha256-"), "import", "\(label) hash is not SHA-256")
                try require(
                    try services.cache.media(contentHash: result.asset.contentHash) != nil, "import",
                    "\(label) has no cache row")
                let applied = try await document.apply(.importAsset(result.operation), label: "Import \(label)")
                try await document.waitForVersion(applied.version)
                imported[label] = result.asset
            }
            let av = try unwrap(imported["av"], "import", "no av asset")
            let tone = try unwrap(imported["tone"], "import", "no tone asset")
            try require(av.hasVideo && av.hasAudio && !tone.hasVideo && tone.hasAudio, "import", "probe kinds")

            // 3b. The drop path (MediaImporter, what the timeline and window drops call): the av file dropped
            //     at 3 s on V1 resolves to the existing asset by hash and lands as linked clips at 3 s; a text
            //     file in the same drop is ignored. The clips are removed again so the edit step starts empty.
            let dropTrack = try unwrap(document.sequence?.tracks.first { $0.kind == .video }, "import", "no V1")
            let dropped = try await MediaImporter(services: services, document: document, jobs: JobCenter())
                .importFiles(
                    [avClip.url, media.url.appendingPathComponent("notes.txt")],
                    at: TimelineDropTarget(trackId: dropTrack.id, at: RationalTime(3, 1)))
            try require(
                dropped.ignored.map(\.lastPathComponent) == ["notes.txt"] && dropped.clipIds.count == 1, "import",
                "drop: \(dropped.ignored.count) ignored, \(dropped.clipIds.count) clips")
            try require(document.project.assets.count == 4, "import", "the drop re-imported an asset")
            let droppedSequence = try unwrap(document.sequence, "import", "no sequence after the drop")
            let droppedClip = try unwrap(droppedSequence.clip(dropped.clipIds[0]), "import", "dropped clip missing")
            let droppedGroup = try unwrap(droppedClip.linkGroupId, "import", "the dropped clip was not linked")
            let droppedMembers = droppedSequence.members(of: droppedGroup)
            try require(
                droppedClip.trackId == dropTrack.id && droppedMembers.count == 2
                    && droppedMembers.allSatisfy { $0.start == RationalTime(3, 1) }, "import",
                "dropped clips at \(droppedMembers.map { $0.start.seconds }) on \(droppedMembers.map(\.trackId))")
            let cleared = try await document.apply(
                .removeClip(.init(clipId: .id(droppedClip.id), mode: .overwrite)), label: "Remove dropped clip")
            try await document.waitForVersion(cleared.version)
            try require(
                document.sequence?.tracks.allSatisfy { $0.clips.isEmpty } == true, "import",
                "the timeline is not empty after removing the dropped clips")
            ok(
                "import",
                "\(imported.count) assets copied into Library/ with sidecars and cache rows; "
                    + "av \(av.duration.seconds)s \(av.probe.width ?? 0)x\(av.probe.height ?? 0), "
                    + "tone \(tone.duration.seconds)s @\(tone.sampleRate ?? 0) Hz; "
                    + "drop at 3 s on V1 -> \(droppedMembers.count) linked clips at \(droppedClip.start.seconds) s, "
                    + "notes.txt ignored")

            // 4. Linked clips, a split through TimelineUI's view model, and a transition.
            let sequence = try unwrap(document.sequence, "clips", "no active sequence")
            let v1 = try unwrap(sequence.tracks.first { $0.kind == .video }, "clips", "no V1")
            let a1 = try unwrap(sequence.tracks.first { $0.kind == .audio }, "clips", "no A1")
            let clip1Id = ClipID(minting: UUIDv7Generator())
            let clip2Id = ClipID(minting: UUIDv7Generator())
            let added = try await document.apply(
                .batch([
                    .addClip(
                        .init(
                            id: clip1Id, sequenceId: .id(sequence.id), trackId: .id(v1.id), assetId: .id(av.id),
                            at: .zero, sourceIn: .zero, sourceOut: RationalTime(3, 2), mode: .overwrite, link: .auto)),
                    .addClip(
                        .init(
                            id: clip2Id, sequenceId: .id(sequence.id), trackId: .id(v1.id), assetId: .id(av.id),
                            at: RationalTime(3, 2), sourceIn: RationalTime(1, 2), sourceOut: RationalTime(2, 1),
                            mode: .overwrite, link: .auto)),
                    .addClip(
                        .init(
                            sequenceId: .id(sequence.id), trackId: .id(a1.id), assetId: .id(tone.id),
                            at: RationalTime(3, 1), sourceIn: .zero, sourceOut: tone.duration, mode: .overwrite,
                            link: .none)),
                ]), label: "Add clips")
            try await document.waitForVersion(added.version)
            let afterAdd = try unwrap(document.sequence, "clips", "no sequence")
            let clip1 = try unwrap(afterAdd.clip(clip1Id), "clips", "clip 1 missing")
            let group = try unwrap(clip1.linkGroupId, "clips", "clip 1 was not auto-linked")
            try require(
                afterAdd.members(of: group).count == 2, "clips", "link group has \(afterAdd.members(of: group).count)")
            try require(
                afterAdd.track(a1.id)?.clips.count == 3, "clips", "A1 has \(afterAdd.track(a1.id)?.clips.count ?? 0)")
            let viewModel = document.viewModel
            viewModel.setPlayhead(RationalTime(4, 5))
            viewModel.select(clip1Id)
            let split = try unwrap(
                await viewModel.splitAtPlayhead(), "split", "\(String(describing: viewModel.lastError))")
            try await document.waitForVersion(split.version)
            let afterSplit = try unwrap(document.sequence, "split", "no sequence")
            try require(
                afterSplit.track(v1.id)?.clips.count == 3, "split",
                "V1 has \(afterSplit.track(v1.id)?.clips.count ?? 0)")
            try require(afterSplit.track(a1.id)?.clips.count == 4, "split", "the linked audio was not split")
            let rightHalf = try unwrap(
                afterSplit.track(v1.id)?.clips.values.first { $0.start == RationalTime(4, 5) }, "split", "no right half"
            )
            let transition = try await document.apply(
                .addTransition(
                    .init(
                        leftClipId: .id(rightHalf.id), rightClipId: .id(clip2Id), kind: "dissolve",
                        duration: RationalTime(8, 15))), label: "Add dissolve")
            try await document.waitForVersion(transition.version)
            try require(document.sequence?.transitions.count == 1, "transition", "no transition in the sequence")
            try require(document.lastRenderPath == .structural, "transition", "expected a structural render update")
            let scene = TimelineSceneBuilder.build(from: viewModel)
            try require(scene.stats.clipsDrawn == 7, "scene", "TimelineUI drew \(scene.stats.clipsDrawn) clips")
            try require(scene.stats.transitionsDrawn == 1, "scene", "TimelineUI drew no transition")
            ok(
                "edit",
                "linked clips v\(added.version), split via TimelineViewModel v\(split.version), "
                    + "dissolve v\(transition.version); scene draws \(scene.stats.clipsDrawn) clips, 1 transition")

            // 4b. RenderKit over the imported clips: the preview item plays, a grabbed frame has content,
            //     and an H.264 export through the job runner writes a file with a duration.
            let compiled = try unwrap(document.compiled, "render", "no Compiled after the edits")
            try require(compiled.duration.seconds > 3, "render", "compiled duration \(compiled.duration.seconds)s")
            try await document.waitForReadyToPlay(timeout: .seconds(20))
            let grabbed = try await services.renderer.frame(
                compiled, at: RationalTime(1, 2), size: CGSize(width: 320, height: 180))
            try require(!SkeletonCheck.isBlank(grabbed), "render", "the frame at 0.5 s is blank")
            let exportURL = root.appendingPathComponent("Exports/skeleton-1080p.mp4")
            let exportHandle = await services.jobRunner.submit(
                services.renderer.export(compiled, preset: .h264_1080p, to: exportURL))
            let exportOutcome = try await exportHandle.wait()
            let exportReceipt = try unwrap(try exportOutcome.payload(as: ExportReceipt.self), "render", "no receipt")
            try require(
                FileManager.default.fileExists(atPath: exportURL.path), "render", "no export at \(exportURL.path)")
            let exportedSeconds = try await AVURLAsset(url: exportURL).load(.duration).seconds
            try require(exportedSeconds > 0, "render", "exported file has no duration")
            ok(
                "render",
                String(
                    format: "compiled %.2fs, item readyToPlay, frame at 0.5 s %dx%d not blank, h264_1080p export %.2fs "
                        + "in %.1fs to %@",
                    compiled.duration.seconds, grabbed.width, grabbed.height, exportedSeconds,
                    exportReceipt.finishedAt.timeIntervalSince(exportReceipt.startedAt), exportURL.lastPathComponent))

            // 5. Silence and onset envelope through the analyzer, via the job runner, recorded on the asset.
            let tools = ToolConsole(services: services)
            let analyzed = try await tools.call(
                "media_analyze",
                input: ToolInput(["assetId": .string(av.id.rawValue), "kinds": ["silence", "onsetEnvelope"]]))
            try require(!analyzed.isError, "analyze", analyzed.text ?? "error")
            let analyzedVersion = Int64(try unwrap(analyzed.structured?["version"]?.intValue, "analyze", "no version"))
            try await document.waitForVersion(analyzedVersion)
            let analyses = document.project.assets[av.id]?.analyses ?? [:]
            try require(
                analyses["silence"] != nil && analyses["onset-8k"] != nil, "analyze", "analyses \(analyses.keys)")
            let artifacts = try services.cache.artifacts(contentHash: av.contentHash)
            try require(artifacts.count >= 2, "analyze", "\(artifacts.count) artifacts in cache.sqlite")
            for artifact in artifacts {
                try require(
                    FileManager.default.fileExists(atPath: services.cache.url(for: artifact).path), "analyze",
                    "missing artifact file \(artifact.path)")
            }
            let frames = analyzed.structured?["results"]?["onsetEnvelope"]?["frameCount"]?.intValue ?? 0
            try require(frames > 100, "analyze", "onset envelope has \(frames) frames")
            ok(
                "analyze",
                "silence + onset-8k on \(av.displayName): \(frames) envelope frames, \(artifacts.count) artifacts "
                    + "under Cache/, recorded at v\(analyzedVersion)")

            // 6. The real aligner on the synthetic camera/render pair, through align_audio and the runner.
            let camera = try unwrap(imported["camera"], "align", "no camera asset")
            let render = try unwrap(imported["render"], "align", "no render asset")
            let aligned = try await tools.call(
                "align_audio",
                input: ToolInput([
                    "referenceAssetId": .string(camera.id.rawValue), "targetAssetId": .string(render.id.rawValue),
                ]))
            try require(!aligned.isError, "align", aligned.text ?? "error")
            try require(aligned.structured?["status"]?.stringValue == "aligned", "align", aligned.text ?? "not aligned")
            let offset = try unwrap(aligned.structured?["offsetSeconds"]?.numberValue, "align", "no offsetSeconds")
            let error = abs(offset - pair.truth.offsetSeconds)
            try require(
                error < 0.001, "align", "offset \(offset) is \(error * 1000) ms from \(pair.truth.offsetSeconds)")
            let drift = aligned.structured?["driftPPM"]?.numberValue ?? 0
            ok(
                "align",
                String(
                    format: "offset %.4f s (truth %.3f, error %.3f ms), drift %.1f ppm (truth %.0f), confidence %.2f",
                    offset, pair.truth.offsetSeconds, error * 1000, drift, pair.truth.driftPPM,
                    aligned.structured?["confidence"]?.numberValue ?? 0))

            // 7. project_describe and timeline_apply through the real registry.
            let describe = try await tools.describeProject()
            try require(!describe.isError, "project_describe", describe.text ?? "error")
            try require(
                describe.structured?["version"]?.intValue == Int(document.version), "project_describe", "stale version")
            let assetCount = describe.structured?["assets"]?.arrayValue?.count ?? 0
            try require(assetCount == 4, "project_describe", "\(assetCount) assets")
            let generationBefore = document.playerItemGeneration
            let op = try JSONValue(
                encoding: Command.Operation.setClipOpacity(.init(clipId: .id(rightHalf.id), after: .constant(0.5))))
            let applied = try await tools.call(
                "timeline_apply",
                input: ToolInput(["ops": .array([op]), "expectedVersion": .number(Double(document.version))]))
            try require(!applied.isError, "timeline_apply", applied.text ?? "error")
            let appliedVersion = Int64(
                try unwrap(applied.structured?["version"]?.intValue, "timeline_apply", "no version"))
            try await document.waitForVersion(appliedVersion)
            try require(document.lastRenderPath == .instructionsOnly, "timeline_apply", "expected instructions-only")
            try require(document.playerItemGeneration == generationBefore, "timeline_apply", "player item replaced")
            let stale = try await tools.call(
                "timeline_apply",
                input: ToolInput(["ops": .array([op]), "expectedVersion": .number(Double(appliedVersion - 1))]))
            try require(
                stale.structured?["error"]?.stringValue == "staleVersion", "timeline_apply", "stale not rejected")
            ok(
                "tools",
                "project_describe v\(document.version) with \(assetCount) assets; timeline_apply v\(appliedVersion) "
                    + "instructions-only; stale expectedVersion rejected with changedSince")

            // 8. The MCP host over HTTP: unauthenticated refused, initialize, tools/list, a tool call.
            var probe = MCPProbe(url: services.mcp.url, token: nil)
            let refused = try await probe.post(MCPProbe.initialize)
            try require(refused.status == 401, "mcp", "request without the token got \(refused.status)")
            probe.token = services.mcp.token
            let initialized = try await probe.handshake()
            try require(initialized.status == 200, "mcp", "initialize got \(initialized.status)")
            try require(probe.sessionId != nil, "mcp", "no Mcp-Session-Id header")
            let serverName = initialized.result?["serverInfo"]?["name"]?.stringValue
            let listed = try await probe.post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
            let names = (listed.result?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            try require(names.contains("project_describe") && names.contains("timeline_apply"), "mcp", "tools \(names)")
            let called = try await probe.post(MCPProbe.call(3, "project_list", [:]))
            let count = called.result?["structuredContent"]?["count"]?.intValue
            try require(count == 1, "mcp", "project_list over MCP answered \(String(describing: count))")
            let hostCalls = await services.mcpHost.calls.count
            try require(hostCalls == 1, "mcp", "host recorded \(hostCalls) calls")
            ok(
                "mcp",
                "401 without token; initialize -> \(serverName ?? "?") session \(probe.sessionId!.prefix(8)); "
                    + "tools/list \(names.count) tools; project_list over HTTP sees 1 project")

            // 9. The scripted agent through the real gate: export gated, approved on the stack, retried.
            let approvals = ApprovalCenter(gate: services.approvals)
            await approvals.start()
            let agent = AgentConsole(services: services, approvals: approvals)
            try await agent.start(goal: "Export a vertical reel")
            let deadline = ContinuousClock.now + .seconds(20)
            while approvals.requests.isEmpty, !(agent.transcript?.isFinished ?? false) {
                guard ContinuousClock.now < deadline else {
                    throw Failure(step: "agent", reason: "no approval request")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let request = try unwrap(approvals.requests.first, "agent", "session finished without asking for approval")
            try require(request.tool == "render_export", "agent", "request for \(request.tool)")
            await approvals.approve(request)
            await agent.runToCompletion()
            let transcript = try unwrap(agent.transcript, "agent", "no transcript")
            try require(transcript.failure == nil, "agent", "failed: \(transcript.failure?.message ?? "")")
            guard
                case .toolCall(_, _, _, let exportOutput, let exportError)? = transcript.items.first(where: {
                    $0.id == "tool-call-export"
                })
            else { throw Failure(step: "agent", reason: "no export tool call in the transcript") }
            try require(
                !exportError && exportOutput?["status"]?.stringValue == "done", "agent",
                "export \(String(describing: exportOutput))")
            let exportPath = exportOutput?["outputPath"]?.stringValue ?? ""
            try require(FileManager.default.fileExists(atPath: exportPath), "agent", "no export file at \(exportPath)")
            try require(await services.approvals.pending().isEmpty, "agent", "gate still has pending requests")
            ok(
                "agent",
                "\(transcript.items.count) items, finished \"\(transcript.items.compactMap { if case .finished(_, let r, _) = $0 { r } else { nil } }.first ?? "")\"; "
                    + "export gated, approved on the stack, retried, wrote \(URL(fileURLWithPath: exportPath).lastPathComponent)"
            )

            // 10. Undo and redo through TimelineUI's view model and the store's history fold.
            let beforeUndo = document.version
            try require(viewModel.canUndo, "undo", "canUndo is false")
            let undone = try unwrap(await viewModel.undo(), "undo", "\(String(describing: viewModel.lastError))")
            try await document.waitForVersion(undone.version)
            try require(document.history.redoTarget != nil, "undo", "redo stack is empty after undo")
            try require(
                document.changes.last?.kind == .undo, "undo",
                "change kind \(String(describing: document.changes.last?.kind))")
            let redone = try unwrap(await viewModel.redo(), "redo", "\(String(describing: viewModel.lastError))")
            try await document.waitForVersion(redone.version)
            try require(document.history.redoTarget == nil, "redo", "redo stack not empty after redo")
            try require(
                redone.version > undone.version && undone.version > beforeUndo, "redo", "versions not increasing")
            ok(
                "undo/redo",
                "v\(beforeUndo) -> v\(undone.version) -> v\(redone.version), \(document.history.live.count) live transactions"
            )

            // 11. Fork: the copy carries the whole stream plus one rename; the original is untouched.
            let forkURL = projectURL.deletingLastPathComponent().appendingPathComponent("Skeleton fork.tlproj")
            let preForkVersion = document.version
            let preForkLive = document.history.live.count
            let fork = try await document.fork(to: forkURL, name: "Skeleton fork", using: services)
            try require(fork.project.name == "Skeleton fork", "fork", "name is \(fork.project.name)")
            try require(fork.version > preForkVersion, "fork", "version \(fork.version) <= \(preForkVersion)")
            try require(fork.history.live.count == preForkLive + 1, "fork", "history not carried over")
            try require(
                fork.history.latestLive?.label == "Fork of Skeleton", "fork",
                "last transaction is \(fork.history.latestLive?.label ?? "nil")")
            try require(fork.project.assets.count == document.project.assets.count, "fork", "assets differ")
            await fork.close(using: services)
            let original = try await ProjectDocument.open(at: projectURL, using: services)
            try require(original.version == preForkVersion, "fork", "original changed: v\(document.version)")
            try require(original.project.name == "Skeleton", "fork", "original renamed")
            ok(
                "fork",
                "Skeleton fork.tlproj at v\(fork.version) with \(fork.history.live.count) live transactions; original still v\(preForkVersion)"
            )

            // 12. Close, reopen from disk, same version and state; then shut down.
            let finalVersion = original.version
            let finalState = original.project
            await original.close(using: services)
            let reopened = try await ProjectDocument.open(at: projectURL, using: services)
            try require(reopened.version == finalVersion, "reopen", "version \(reopened.version) != \(finalVersion)")
            let before = String(decoding: try finalState.canonicalJSON(), as: UTF8.self)
            let after = String(decoding: try reopened.project.canonicalJSON(), as: UTF8.self)
            try require(
                before == after, "reopen", "state differs after reopen: \(SkeletonCheck.firstDifference(before, after))"
            )
            try require(reopened.history.live.count == original.history.live.count, "reopen", "history differs")
            await reopened.close(using: services)
            await services.shutdown()
            let receipts = await (services.receipts as? ReceiptLog)?.receipts.count ?? 0
            ok(
                "reopen",
                "v\(finalVersion) after close and reopen, state and history equal; \(receipts) tool receipts logged")

            let elapsed = ContinuousClock.now - started
            print("\nSkeleton check passed: \(steps.count) steps in \(elapsed) -- \(steps.joined(separator: ", "))")
            return true
        } catch {
            print("FAIL \(error)")
            return false
        }
    }

    /// True when every pixel of `image` is the same colour (a black or missing frame).
    static func isBlank(_ image: CGImage) -> Bool {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true }
        let first = pixels[0..<3]
        return stride(from: 0, to: pixels.count, by: 4).allSatisfy { pixels[$0..<($0 + 3)].elementsEqual(first) }
    }

    /// A window around the first byte where two canonical documents diverge.
    static func firstDifference(_ a: String, _ b: String) -> String {
        let ca = Array(a), cb = Array(b)
        var i = 0
        while i < ca.count, i < cb.count, ca[i] == cb[i] { i += 1 }
        let lo = max(0, i - 80)
        return
            "at \(i): before …\(String(ca[lo..<min(ca.count, i + 80)]))… after …\(String(cb[lo..<min(cb.count, i + 80)]))…"
    }

    private static func unwrap<T>(_ value: T?, _ step: String, _ reason: @autoclosure () -> String) throws -> T {
        guard let value else { throw Failure(step: step, reason: reason()) }
        return value
    }
}

/// A minimal Streamable HTTP client for the check: bearer header, session id, SSE or JSON bodies.
struct MCPProbe {
    var url: URL
    var token: String?
    var sessionId: String?
    private let session = URLSession(configuration: .ephemeral)

    struct Reply {
        var status: Int
        var headers: [String: String]
        var messages: [JSONValue]
        var result: JSONValue? { messages.last?["result"] }
    }

    static let initialize: JSONValue = [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:],
            "clientInfo": ["name": "skeleton-check", "version": "0"],
        ],
    ]

    static func call(_ id: Int, _ tool: String, _ arguments: JSONValue) -> JSONValue {
        [
            "jsonrpc": "2.0", "id": .number(Double(id)), "method": "tools/call",
            "params": ["name": .string(tool), "arguments": arguments],
        ]
    }

    func post(_ json: JSONValue) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try ProjectCodec.encode(json)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
        let contentType = headers["content-type"] ?? ""
        let messages: [JSONValue]
        if contentType.hasPrefix("text/event-stream") {
            messages = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("data:") }
                .compactMap { line in
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard !payload.isEmpty else { return nil }
                    return try? ProjectCodec.decode(JSONValue.self, from: Data(payload.utf8))
                }
        } else {
            messages = (try? ProjectCodec.decode(JSONValue.self, from: data)).map { [$0] } ?? []
        }
        return Reply(status: http.statusCode, headers: headers, messages: messages)
    }

    /// initialize + notifications/initialized, binding the probe to the new session.
    mutating func handshake() async throws -> Reply {
        let reply = try await post(MCPProbe.initialize)
        sessionId = reply.headers["mcp-session-id"]
        if sessionId != nil { _ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"]) }
        return reply
    }
}
