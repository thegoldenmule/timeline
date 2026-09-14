import AVFoundation
import AgentKit
import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import TimelineCore
import TimelineUI

/// `swift run TimelineApp --skeleton-check`: the end-to-end check on the real services, without a
/// window. It boots the composition root over a temporary library root, creates a project, imports
/// synthetic media through the real library, browses the cross-project catalog and duplicates another
/// project's asset into this one, edits through TimelineUI's view model and the tool registry, runs analyses and an alignment through the job runner, talks to the MCP host over HTTP,
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
            let services = try await AppServices.boot(root: root, agent: .fallback, publishing: .fake, log: log)
            try require(await services.mcpHost.isRunning, "boot", "MCP host is not running")
            try require(
                FileManager.default.fileExists(atPath: services.proxyConfigurationURL.path), "boot",
                "proxy configuration was not written")
            ok(
                "boot",
                "root \(root.lastPathComponent), MCP \(services.mcp.url.absoluteString), "
                    + "\(await services.registry.list().count) tools, agent fallback, publishing fake")

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

            // 3c. The media library: the catalog over every package on this machine, and a duplicate of a
            //     foreign project's asset into this one (one importAsset, no second copy of the file).
            let second = try await TestMedia.tone(frequency: 660, duration: 1, in: media.url, name: "second-project")
            let secondImport = try await services.mediaLibrary.importAsset(url: second.url, mode: .copy)
            let secondURL = services.layout.projectsDir.appendingPathComponent("Second.tlproj", isDirectory: true)
            let secondStore = try await services.opener.create(
                at: secondURL, name: "Second", settings: ProjectSettings(),
                sequence: .init(name: "Sequence 1", frameDuration: RationalTime(1, 30), width: 1920, height: 1080))
            _ = try await secondStore.apply(
                Command(
                    commandId: CommandID(minting: UUIDv7Generator()), actor: .system, label: "Import second",
                    operation: .importAsset(secondImport.operation)))
            try await secondStore.close()

            let catalog = services.catalog
            try require(try await catalog.refresh() >= 2, "library", "the scan found fewer than two packages")
            let catalogProjects = try await catalog.projects()
            let skeletonRow = try unwrap(
                catalogProjects.first { $0.name == "Skeleton" }, "library", "the catalog did not find Skeleton")
            try require(
                skeletonRow.isReadable, "library", "Skeleton is unreadable: \(skeletonRow.unreadableReason ?? "")")
            let everything = try await catalog.items()
            try require(
                everything.filter { $0.projectId == skeletonRow.id }.count == 4, "library",
                "the catalog sees \(everything.filter { $0.projectId == skeletonRow.id }.count) assets in Skeleton")
            let foreign = try unwrap(
                try await catalog.items(excluding: [skeletonRow.id]).first {
                    $0.contentHash == secondImport.asset.contentHash
                }, "library", "the second package's asset is not in the catalog")
            try require(foreign.projectName == "Second", "library", "foreign item names \(foreign.projectName ?? "no")")

            // The duplicate: one importAsset, the same file, one clip at the target.
            let libraryFilesBefore = SkeletonCheck.fileCount(under: services.layout.libraryDir)
            let versionBeforeDuplicate = document.version
            let importer = MediaImporter(services: services, document: document, jobs: JobCenter())
            let duplicated = try await importer.insert(
                [LibraryDragItem(foreign.asset, projectId: foreign.projectId, url: foreign.url(defaultRoot: root))],
                at: TimelineDropTarget(trackId: nil, at: RationalTime(1, 1)))
            try require(
                duplicated.assets.count == 1 && duplicated.clipIds.count == 1 && duplicated.ignored.isEmpty, "library",
                "duplicate: \(duplicated.assets.count) assets, \(duplicated.clipIds.count) clips")
            try require(
                document.version == versionBeforeDuplicate + 2, "library",
                "duplicate applied \(document.version - versionBeforeDuplicate) commands, expected importAsset + addClip"
            )
            try require(document.project.assets.count == 5, "library", "the duplicate did not add exactly one asset")
            try require(
                SkeletonCheck.fileCount(under: services.layout.libraryDir) == libraryFilesBefore, "library",
                "the duplicate copied the file again")

            // The same item a second time: the project's asset is reused, only a clip is added.
            let versionBeforeSecond = document.version
            let again = try await importer.insert(
                [LibraryDragItem(foreign.asset, projectId: foreign.projectId, url: foreign.url(defaultRoot: root))],
                at: TimelineDropTarget(trackId: nil, at: RationalTime(5, 1)))
            try require(
                again.assets.first?.id == duplicated.assets.first?.id, "library", "the second insert re-imported")
            try require(
                document.project.assets.count == 5 && document.version == versionBeforeSecond + 1, "library",
                "the second insert applied \(document.version - versionBeforeSecond) commands")

            // The Import button path: into the library, never onto the timeline.
            let buttonPath = try await importer.importFiles([avClip.url])
            try require(
                buttonPath.clipIds.isEmpty && buttonPath.assets.count == 1, "library",
                "the Import button added \(buttonPath.clipIds.count) clips")
            try require(document.project.assets.count == 5, "library", "the Import button re-imported an asset")

            // Clear the two duplicate clips so the edit step starts on an empty timeline.
            for clipId in duplicated.clipIds + again.clipIds {
                let removed = try await document.apply(
                    .removeClip(.init(clipId: .id(clipId), mode: .overwrite)), label: "Remove library clip")
                try await document.waitForVersion(removed.version)
            }
            try require(
                document.sequence?.tracks.allSatisfy { $0.clips.isEmpty } == true, "library",
                "the timeline is not empty after the library step")
            ok(
                "library",
                "\(catalogProjects.count) packages scanned, \(everything.count) items; "
                    + "Second/\(foreign.asset.displayName) duplicated into Skeleton with one importAsset "
                    + "(no second copy under Library/), inserted again with none; Import button left the tracks empty")

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

            // The razor through the calls a click makes: arm it, hover inside the tone clip, cut. One
            // command, into the store and back out into the scene, with the blade drawn before it lands.
            let beforeRazor = try unwrap(document.sequence, "razor", "no sequence")
            let toneOnA1 = try unwrap(
                beforeRazor.track(a1.id)?.clips.values.first { $0.assetId == tone.id }, "razor", "no tone clip")
            let a1Count = beforeRazor.track(a1.id)?.clips.count ?? 0
            viewModel.selectTool(.razor)
            let toneRow = try unwrap(viewModel.layout.row(for: a1.id), "razor", "A1 is not laid out")
            let cutAt = toneClipCutPoint(viewModel: viewModel, clip: toneOnA1, row: toneRow)
            viewModel.updateRazor(at: cutAt, modifiers: [])
            let razorTarget = try unwrap(viewModel.razorTarget, "razor", "the hover resolved nothing")
            try require(razorTarget.clipIds == [toneOnA1.id], "razor", "the blade named the wrong clips")
            let razorScene = TimelineSceneBuilder.build(from: viewModel)
            try require(
                razorScene.overlayQuads.contains { $0.color.matches(TimelineTheme.razorIndicator) }, "razor",
                "the scene drew no blade")
            let cut = try unwrap(
                await viewModel.commitRazor(), "razor", "\(String(describing: viewModel.lastError))")
            try await document.waitForVersion(cut.version)
            let afterRazor = try unwrap(document.sequence, "razor", "no sequence")
            try require(
                afterRazor.track(a1.id)?.clips.count == a1Count + 1, "razor",
                "A1 has \(afterRazor.track(a1.id)?.clips.count ?? 0) clips, expected \(a1Count + 1)")
            try require(
                afterRazor.clip(toneOnA1.id) != nil
                    && afterRazor.track(a1.id)?.clips.values.contains { $0.start == razorTarget.at } == true,
                "razor", "no right half at the cut")
            viewModel.selectTool(.selection)
            try require(viewModel.razorTarget == nil, "razor", "putting the tool away left the blade drawn")

            // Track controls through the header-button path: one command each, into the store and back out
            // into the scene, and an audio solo leaves the video alone.
            let soloed = try unwrap(await viewModel.toggle(.solo, on: a1.id), "tracks", "solo emitted no command")
            try await document.waitForVersion(soloed.version)
            let withSolo = try unwrap(document.sequence, "tracks", "no sequence")
            try require(withSolo.track(a1.id)?.solo == true, "tracks", "A1 is not soloed")
            let videoTrack = try unwrap(withSolo.track(v1.id), "tracks", "no V1")
            try require(withSolo.silence(of: videoTrack) == nil, "tracks", "an audio solo silenced the video")
            let soloScene = TimelineSceneBuilder.build(from: viewModel)
            try require(
                soloScene.overlayQuads.contains { $0.color == TimelineTheme.soloBadge }, "tracks",
                "the scene drew no solo state")
            let unsoloed = try unwrap(await viewModel.toggle(.solo, on: a1.id), "tracks", "unsolo emitted no command")
            try await document.waitForVersion(unsoloed.version)
            try require(document.sequence?.track(a1.id)?.solo == false, "tracks", "A1 stayed soloed")
            ok(
                "edit",
                "linked clips v\(added.version), split via TimelineViewModel v\(split.version), "
                    + "dissolve v\(transition.version); scene draws \(scene.stats.clipsDrawn) clips, 1 transition; "
                    + "razor cut the tone clip on A1 at \(razorTarget.at.seconds)s v\(cut.version); "
                    + "solo on A1 v\(soloed.version) drew its accent and left V1 audible, off again v\(unsoloed.version)"
            )

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
            // Four imported files plus the one duplicated out of the second project's library.
            try require(assetCount == 5, "project_describe", "\(assetCount) assets")
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
            let agent = AssistantConsole(services: services, approvals: approvals)
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

            // 11b. Rename: the toolbar sheet's one command, right after Fork because that is the pair it
            //      has to be told apart from — Fork makes a new package under a new name, Rename changes
            //      this project's name and leaves the package where it is (docs/plans/project-rename.md).
            let preRenameVersion = original.version
            let preRenameLive = original.history.live.count
            var blank = ProjectRename(current: original.project.name)
            blank.name = "   "
            try require(blank.operation == nil, "rename", "a blank name produced a command")
            var draft = ProjectRename(current: original.project.name)
            draft.name = "  Skeleton renamed  "
            let renameOp = try unwrap(draft.operation, "rename", "the draft produced no command")
            let renamed = try await original.apply(renameOp)
            try await original.waitForVersion(renamed.version)
            try require(
                original.project.name == "Skeleton renamed", "rename", "name is \(original.project.name)")
            try require(
                original.history.live.count == preRenameLive + 1, "rename",
                "the rename filed \(original.history.live.count - preRenameLive) transactions")
            try require(
                original.history.latestLive?.label == "Rename project", "rename",
                "last transaction is \(original.history.latestLive?.label ?? "nil")")
            // The package on disk is untouched: the name and the file name are separate facts.
            try require(
                original.url.lastPathComponent == "Skeleton.tlproj"
                    && FileManager.default.fileExists(atPath: projectURL.path), "rename",
                "the package moved to \(original.url.lastPathComponent)")
            // A second rename to the same name sends nothing at all.
            var unchanged = ProjectRename(current: original.project.name)
            unchanged.name = "Skeleton renamed"
            try require(unchanged.operation == nil, "rename", "an unchanged name produced a command")
            try require(
                original.version == renamed.version, "rename", "the no-op moved the version to \(original.version)")
            // The library panel's rows for the open project are built from the live document, so they
            // carry the new name with no rescan of the catalog (docs/plans/project-rename.md, 5).
            let libraryPanel = MediaLibraryModel(
                viewModel: original.viewModel, catalog: services.catalog, layout: services.layout,
                thumbnails: services.thumbnails)
            try require(
                !libraryPanel.openProjectItems.isEmpty
                    && libraryPanel.openProjectItems.allSatisfy { $0.projectName == "Skeleton renamed" }, "rename",
                "the library panel still names the project "
                    + "\(libraryPanel.openProjectItems.first?.projectName ?? "nothing")")
            ok(
                "rename",
                "v\(preRenameVersion) -> v\(original.version) as one \"Rename project\" transaction; "
                    + "package still Skeleton.tlproj; blank and unchanged names send nothing; "
                    + "\(libraryPanel.openProjectItems.count) library rows renamed without a rescan")

            // 11c. Export: the toolbar sheet's draft. The button used to send `preset: "reel9x16"` whatever
            //      the sequence was, and the compositor pads rather than crops, so a 1920x1080 sequence
            //      came back as a strip in a tall black frame (docs/plans/export-sheet.md). The draft's
            //      default, the badge on the preset that would pad, the path it shows, and then the real
            //      gated call with the preset as an object rather than a name.
            let exportSequence = try unwrap(original.sequence, "export", "no sequence")
            let sequenceFrame = CGSize(width: exportSequence.width, height: exportSequence.height)
            var exportDraft = ExportDraft(sequence: exportSequence, exportsDirectory: services.layout.exportsDir)
            try require(
                exportDraft.presetName == ExportText.matchSequence, "export",
                "the default preset is \(exportDraft.presetName)")
            try require(
                exportDraft.outputSize == sequenceFrame, "export", "the default frame is \(exportDraft.outputSize)")
            try require(exportDraft.framing.isExact, "export", "the default letterboxed the sequence")
            // The one assertion that pins the sheet's copy of the default-path formula to the tool's.
            try require(
                exportDraft.outputURL
                    == ExportDestination.url(
                        sequenceName: exportSequence.name, presetName: exportDraft.preset.name,
                        fileExtension: exportDraft.preset.fileExtension, in: services.layout.exportsDir), "export",
                "the sheet's default path is \(exportDraft.outputURL.path)")
            // What the old button did, now visible before it happens rather than after.
            var reel = exportDraft
            reel.presetName = ExportPreset.reel9x16.name
            try require(
                reel.outputSize == CGSize(width: 1080, height: 1920), "export", "the reel frame is \(reel.outputSize)")
            guard case .letterbox(let bar) = reel.framing.bars else {
                throw Failure(step: "export", reason: "the reel preset reported \(reel.framing.bars)")
            }
            try require(
                exportDraft.badge(forPresetNamed: ExportPreset.reel9x16.name) == ExportText.letterboxBadge, "export",
                "the reel row carried no badge")
            // The call the sheet makes: the whole ExportPreset as an object, and the path it showed.
            exportDraft.chose(root.appendingPathComponent("Exports/skeleton-sheet.mp4"))
            // The window's job list follows work a *tool* submitted, which is what makes an export
            // visible while it runs. The sheet's Export goes through `render_export`, and the tool owns
            // the only handle until the job is over, so before this the export ran with nothing on
            // screen: no row, no progress, no sign it had started.
            let exportJobs = JobCenter()
            if let budgeted = services.jobRunner as? BudgetedJobRunner {
                await budgeted.observe { handle in
                    Task { @MainActor in exportJobs.track(handle) }
                }
            } else {
                throw Failure(step: "export", reason: "the runner is not the app's, so nothing follows its jobs")
            }
            let sheetApproval = approveNext("render_export", on: approvals)
            let sheetExport = try await tools.call(
                "render_export",
                input: ToolInput([
                    "preset": try JSONValue(encoding: exportDraft.preset),
                    "sequenceId": .string(exportDraft.sequenceId.rawValue),
                    "outputPath": .string(exportDraft.outputURL.path),
                ]))
            try require(await sheetApproval.value != nil, "export", "the sheet's export raised no approval")
            try require(
                sheetExport.structured?["status"]?.stringValue == "done", "export", sheetExport.text ?? "export")
            try require(
                FileManager.default.fileExists(atPath: exportDraft.outputURL.path), "export",
                "no file at \(exportDraft.outputURL.path)")
            let writtenTracks = try await AVURLAsset(url: exportDraft.outputURL).loadTracks(withMediaType: .video)
            let writtenTrack: AVAssetTrack = try unwrap(writtenTracks.first, "export", "the export has no video track")
            let written = try await writtenTrack.load(.naturalSize)
            try require(
                written == sequenceFrame, "export",
                "the file is \(written), not the sequence's \(ExportFraming.pixels(sequenceFrame))")
            let sheetRenderId = try unwrap(sheetExport.structured?["renderId"]?.stringValue, "export", "no renderId")
            let sheetLedger = try unwrap(original.renderLedger, "export", "the store keeps no render ledger")
            let sheetRow = try unwrap(try await sheetLedger.render(sheetRenderId), "export", "no render row")
            try require(sheetRow.status == RenderStatus.done, "export", "the render row is \(sheetRow.status)")
            try require(
                sheetRow.preset.size == ExportPreset.OutputSize.matchSequence, "export",
                "the ledger row's preset is \(sheetRow.preset.size)")
            // The row, and the progress that reached it: an indeterminate spinner would not have told
            // the user whether a long export was moving.
            var exportEntry: JobCenter.Entry?
            for _ in 0..<200 {
                exportEntry = exportJobs.entries.first { $0.kind == .export }
                if exportEntry?.progress.fraction != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let trackedExport = try unwrap(exportEntry, "export", "the export raised no row in the job list")
            let reportedFraction = try unwrap(
                trackedExport.progress.fraction, "export", "the export row never reported a fraction")
            try require(
                reportedFraction > 0, "export", "the export row's progress stayed at \(reportedFraction)")
            ok(
                "export",
                "the sheet defaults to \(ExportFraming.pixels(exportDraft.outputSize)) match-sequence; the reel preset "
                    + "flags \(Int(bar.rounded())) px of letterbox first; gated export wrote "
                    + "\(ExportFraming.pixels(written)) to \(exportDraft.outputURL.lastPathComponent) and a render row; "
                    + "the window's job list followed it to \(Int(reportedFraction * 100))%")

            // 11d. Format: the user's own case, end to end. Every project is created 1920x1080 whatever it
            //      holds, and the compositor fits each source into that frame *before* any export is framed,
            //      so a project of portrait clips exported "match sequence" is a pillarboxed landscape file
            //      while the export sheet correctly reports no letterboxing — it draws the later stage. The
            //      format sheet is what sees the earlier one (docs/plans/sequence-format.md).
            let portraitClip = try await TestMedia.videoWithAudio(
                .tone(frequency: 330), size: CGSize(width: 720, height: 1280), duration: 2, in: media.url,
                name: "portrait")
            let portraitURL = services.layout.projectsDir.appendingPathComponent("Portrait.tlproj")
            let portraitDoc = try await ProjectDocument.create(at: portraitURL, name: "Portrait", using: services)
            let portraitTrack = try unwrap(portraitDoc.sequence?.tracks.first { $0.kind == .video }, "format", "no V1")
            _ = try await MediaImporter(services: services, document: portraitDoc, jobs: JobCenter())
                .importFiles([portraitClip.url], at: TimelineDropTarget(trackId: portraitTrack.id, at: .zero))
            let createdSequence = try unwrap(portraitDoc.sequence, "format", "no sequence")
            try require(
                createdSequence.frameSize == FrameSize(width: 1920, height: 1080), "format",
                "a new project is \(createdSequence.frameSize)")

            let firstLook = FormatMismatch(sequence: createdSequence, assets: portraitDoc.project.assets)
            try require(!firstLook.isClean, "format", "portrait footage in a landscape frame reported clean")
            let offender = try unwrap(firstLook.worst, "format", "no offending clip")
            guard case .pillarbox(let pillar) = offender.bars else {
                throw Failure(step: "format", reason: "the bars are \(offender.bars)")
            }
            // The export sheet is blind to this on purpose, and proving it is the point: its own framing is
            // exact, because the sequence does fill the frame it is being exported at.
            let blindDraft = ExportDraft(sequence: createdSequence, exportsDirectory: services.layout.exportsDir)
            try require(
                blindDraft.framing.isExact, "format",
                "the export framing should be exact here; it is \(blindDraft.framing.bars)")

            var format = SequenceFormat(sequence: createdSequence, assets: portraitDoc.project.assets)
            try require(format.recommendsMatchMedia, "format", "matching the media was not recommended")
            format.selection = .matchMedia
            try require(
                format.size == FrameSize(width: 720, height: 1280), "format", "match media gives \(format.size)")
            try require(format.resultingMismatch.isClean, "format", "matching left bars behind")
            let beforeFormat = portraitDoc.version
            let clipsBeforeFormat =
                portraitDoc.project.sequences[createdSequence.id]?.tracks
                .reduce(0) { $0 + $1.clips.count } ?? 0
            let formatted = try await portraitDoc.apply(
                try unwrap(format.operation, "format", "no operation"), label: "Change sequence format")
            try await portraitDoc.waitForVersion(formatted.version)
            let resized = try unwrap(portraitDoc.sequence, "format", "no sequence after the resize")
            try require(
                resized.frameSize == FrameSize(width: 720, height: 1280), "format",
                "the sequence is \(resized.frameSize)")
            try require(
                portraitDoc.version == beforeFormat + 1, "format",
                "the resize took \(portraitDoc.version - beforeFormat) versions")
            let clipsAfterFormat = resized.tracks.reduce(0) { $0 + $1.clips.count }
            try require(
                clipsAfterFormat == clipsBeforeFormat, "format",
                "the resize changed the clip count from \(clipsBeforeFormat) to \(clipsAfterFormat)")
            try require(
                FormatMismatch(sequence: resized, assets: portraitDoc.project.assets).isClean, "format",
                "the footage still does not fill the frame")

            // The export sheet over the resized sequence: its default is the footage's own frame and
            // nothing is boxed at either stage, so the user's next click cannot undo the fix.
            let afterDraft = ExportDraft(sequence: resized, exportsDirectory: services.layout.exportsDir)
            try require(
                afterDraft.outputSize == CGSize(width: 720, height: 1280), "format",
                "the sheet would export \(ExportFraming.pixels(afterDraft.outputSize))")
            try require(afterDraft.framing.isExact, "format", "the sheet would box the resized sequence")
            try require(
                FormatMismatch(sequence: resized, assets: portraitDoc.project.assets).isClean, "format",
                "the footage still does not fill the resized frame")

            // The file itself: portrait in, portrait out. This is the line that was landscape before.
            let portraitCompiled = try await services.renderer.compile(
                resized, assets: portraitDoc.project.assets, options: .full)
            let portraitOut = services.layout.exportsDir.appendingPathComponent("portrait-match.mp4")
            let portraitJob = await services.jobRunner.submit(
                services.renderer.export(portraitCompiled, preset: ExportDraft.matchSequence, to: portraitOut))
            _ = try await portraitJob.wait()
            let portraitTracks = try await AVURLAsset(url: portraitOut).loadTracks(withMediaType: .video)
            let portraitTrackOut: AVAssetTrack = try unwrap(
                portraitTracks.first, "format", "the portrait export has no video track")
            let portraitSize = try await portraitTrackOut.load(.naturalSize)
            try require(
                portraitSize == CGSize(width: 720, height: 1280), "format",
                "the file is \(ExportFraming.pixels(portraitSize)), not the sequence's 720 × 1280")

            // And it is one undo, like every other edit.
            try require(await portraitDoc.viewModel.undo()?.status == .applied, "format", "the resize did not undo")
            try require(
                portraitDoc.sequence?.frameSize == FrameSize(width: 1920, height: 1080), "format",
                "undo left the sequence at \(String(describing: portraitDoc.sequence?.frameSize))")
            await portraitDoc.close(using: services)
            ok(
                "format",
                "a new project holding one 720x1280 clip is 1920x1080 and pillarboxes it by "
                    + "\(Int(pillar.rounded())) px, which the export sheet's own framing calls exact; match "
                    + "media resized to 720x1280 in one transaction, kept \(clipsAfterFormat) clip(s), wrote "
                    + "\(ExportFraming.pixels(portraitSize)) to \(portraitOut.lastPathComponent), and undid")

            // 12. Publish: connect the fixture Google account through the real loopback flow, export through
            //     render_export (a render row), then publish_youtube through the registry: approval_required
            //     with the card's rows, approved on the stack, retried with the token; the fake drops the
            //     connection once mid-upload and the upload resumes; the receipt, the ledger rows, the caption
            //     insert, publish_status over MCP, and account_status are asserted.
            let provider = try unwrap(services.accounts, "publish", "no account provider")
            let publisher = try unwrap(services.publisher, "publish", "no publisher")
            let fakeYouTube = try unwrap(services.publishing.fakeServer, "publish", "no fake YouTube server")
            let connected = try await provider.connect(scopes: publisher.requiredScopes, loginHint: nil)
            try require(connected.id == "sub-1", "publish", "connected \(connected.id)")
            try require(
                connected.channelHandle == "@skeleton", "publish", "handle \(connected.channelHandle ?? "nil")")
            try require(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("google-tokens.json").path),
                "publish", "no token file under the root")
            // A caption track with two cues, so the publish inserts an SRT track (D7).
            let publishSequence = try unwrap(original.sequence, "publish", "no sequence")
            let captionTrackId = TrackID(minting: UUIDv7Generator())
            let captioned = try await original.apply(
                .addCaptionTrack(
                    .init(id: captionTrackId, sequenceId: .id(publishSequence.id), name: "English", language: "en")),
                label: "Add captions")
            try await original.waitForVersion(captioned.version)
            let cues = try await original.apply(
                .replaceCaptions(
                    .init(
                        trackId: .id(captionTrackId),
                        items: [
                            .init(start: RationalTime(1, 2), duration: RationalTime(3, 2), text: "Hello there"),
                            .init(start: RationalTime(5, 2), duration: RationalTime(2, 1), text: "and welcome"),
                        ])), label: "Caption text")
            try await original.waitForVersion(cues.version)
            // The export, gated like the toolbar button's, records a render row with the file's hash.
            let publishExportURL = root.appendingPathComponent("Exports/skeleton-publish.mp4")
            let exportApproval = approveNext("render_export", on: approvals)
            let exported = try await tools.call(
                "render_export",
                input: ToolInput(["preset": "h264_1080p", "outputPath": .string(publishExportURL.path)]))
            try require(await exportApproval.value != nil, "publish", "render_export raised no approval")
            try require(exported.structured?["status"]?.stringValue == "done", "publish", exported.text ?? "export")
            let renderId = try unwrap(exported.structured?["renderId"]?.stringValue, "publish", "no renderId")
            let renderLedger = try unwrap(original.renderLedger, "publish", "the store keeps no render ledger")
            let renderRow = try unwrap(
                try await renderLedger.render(renderId), "publish", "no render row \(renderId)")
            let exportHash = try FileHash.sha256(of: publishExportURL)
            try require(renderRow.status == .done, "publish", "render row is \(renderRow.status)")
            try require(renderRow.outputHash == exportHash, "publish", "render row hash differs from the file")
            try require(
                renderRow.outputURL?.path == publishExportURL.path, "publish",
                "render row path \(renderRow.outputURL?.path ?? "nil")")
            let exportBytes =
                (try FileManager.default.attributesOfItem(atPath: publishExportURL.path)[.size] as? Int64) ?? 0
            // publish_youtube as the human: approval_required first, with the card's rows.
            let publishInput = ToolInput([
                "renderId": .string(renderId), "title": "Skeleton publish",
                "captionTrackIds": [.string(captionTrackId.rawValue)],
                "thumbnailAt": try JSONValue(encoding: RationalTime(1, 2)), "waitSeconds": 60,
            ])
            let asked = try await services.callTool("publish_youtube", input: publishInput, actor: .human)
            try require(asked.isApprovalRequired, "publish", "expected approval_required, got \(asked.text ?? "")")
            let publishId = try unwrap(asked.structured?["publishId"]?.stringValue, "publish", "no publishId")
            let askedRequest = try unwrap(ToolLoopSession.request(from: asked), "publish", "no request in the output")
            let detailLabels = askedRequest.presentation?.details.map(\.label) ?? []
            for label in ["Channel", "Privacy", "Captions", "Thumbnail", "Certification"] {
                try require(detailLabels.contains(label), "publish", "card has no \(label) row: \(detailLabels)")
            }
            let cardPrivacy = askedRequest.presentation?.details.first { $0.label == "Privacy" }?.value
            try require(cardPrivacy == "private", "publish", "card privacy \(cardPrivacy ?? "nil")")
            try require(askedRequest.presentation?.warnings.isEmpty == true, "publish", "unexpected warnings")
            // Approved on the stack (the card the window shows), then retried with the token and the same id.
            let publishApproval = approveNext("publish_youtube", on: approvals)
            let approvedRequest = try unwrap(await publishApproval.value, "publish", "the card never reached the stack")
            try require(approvedRequest.token == askedRequest.token, "publish", "the stack saw another request")
            try require(
                approvedRequest.presentation?.details.count == detailLabels.count, "publish",
                "the stack's card lost its rows")
            let chunk = services.publishing.uploadOptions.chunkBytes
            let dropAfter = max(1, exportBytes / 2)
            await fakeYouTube.dropConnection(afterBytes: dropAfter)
            var retryInput = publishInput
            retryInput.arguments["approvalToken"] = .string(askedRequest.token.rawValue)
            retryInput.arguments["publishId"] = .string(publishId)
            let published = try await services.callTool("publish_youtube", input: retryInput, actor: .human)
            try require(!published.isError, "publish", published.text ?? "publish error")
            let publishedStatus = published.structured?["status"]?.stringValue
            try require(
                publishedStatus == "done", "publish", "status \(publishedStatus ?? "nil"): \(published.text ?? "")")
            let receipt = try unwrap(
                try published.structured?["receipt"]?.decoded(as: PublishReceipt.self), "publish", "no receipt")
            try require(receipt.remoteId == "fake-video-1", "publish", "remoteId \(receipt.remoteId)")
            try require(
                receipt.remoteURL.absoluteString == "https://youtu.be/fake-video-1", "publish",
                "url \(receipt.remoteURL)")
            try require(
                receipt.privacy == .private && receipt.requestedPrivacy == .private, "publish",
                "privacy \(receipt.privacy)")
            try require(receipt.resumedCount >= 1, "publish", "resumedCount \(receipt.resumedCount)")
            try require(
                receipt.bytesUploaded == exportBytes, "publish", "uploaded \(receipt.bytesUploaded) of \(exportBytes)")
            try require(receipt.contentHash == exportHash, "publish", "receipt hash differs from the file")
            try require(receipt.captionIds.count == 1, "publish", "captions \(receipt.captionIds)")
            try require(receipt.thumbnailSet, "publish", "thumbnail not set")
            try require(receipt.madeForKids == nil, "publish", "madeForKids was sent")
            try require(published.structured?["publishId"]?.stringValue == publishId, "publish", "publishId changed")
            let publishJSON = PrettyJSON.string(published.structured)
            try require(
                !publishJSON.contains("upload/youtube") && !publishJSON.contains("fake-token"), "publish",
                "the output leaks the session or a token")
            // What the fake saw: one status query after the drop, no overlapping ranges, one SRT caption body.
            let statusQueries = await fakeYouTube.statusQueries.count
            try require(statusQueries == 1, "publish", "\(statusQueries) status queries")
            try require(await !fakeYouTube.hasOverlappingChunks, "publish", "overlapping chunk ranges")
            let droppedChunks = await fakeYouTube.chunkRequests.filter(\.dropped).count
            try require(droppedChunks == 1, "publish", "\(droppedChunks) dropped chunks")
            let insertedCaptions = await fakeYouTube.captions(forVideo: "fake-video-1")
            try require(insertedCaptions.count == 1, "publish", "\(insertedCaptions.count) captions on the video")
            try require(
                insertedCaptions[0].body.contains("Hello there") && insertedCaptions[0].body.contains("-->"), "publish",
                "caption body is not SRT: \(insertedCaptions[0].body.prefix(60))")
            try require(
                await fakeYouTube.video("fake-video-1")?.privacy == "private", "publish", "the video is not private")
            // The ledger: the publish row done with the receipt and no session; no project version bump.
            let publishLedger = try unwrap(original.publishLedger, "publish", "the store keeps no publish ledger")
            let publishRow = try unwrap(try await publishLedger.publish(publishId), "publish", "no publish row")
            try require(
                publishRow.status == .done && publishRow.receipt != nil && publishRow.session == nil, "publish",
                "row \(publishRow.status), receipt \(publishRow.receipt != nil), session \(publishRow.session != nil)")
            try require(
                publishRow.renderId == renderId && publishRow.remoteId == "fake-video-1", "publish", "row links")
            try require(original.version == cues.version, "publish", "publishing bumped the project version")
            // publish_status over MCP lists it, without the session; account_status shows the channel.
            let statusReply = try await probe.post(MCPProbe.call(4, "publish_status", [:]))
            let statusContent = statusReply.result?["structuredContent"]
            let statusRows = statusContent?["publishes"]?.arrayValue ?? []
            try require(
                statusRows.first?["publishId"]?.stringValue == publishId, "publish",
                "publish_status over MCP lists \(statusRows.count) rows")
            try require(
                statusRows.first?["status"]?.stringValue == "done"
                    && statusRows.first?["url"]?.stringValue == "https://youtu.be/fake-video-1", "publish",
                "publish_status row \(String(describing: statusRows.first))")
            try require(
                !PrettyJSON.string(statusContent).contains("upload/youtube"), "publish",
                "publish_status leaks the session"
            )
            let accountStatus = try await tools.call("account_status")
            let statusAccounts = accountStatus.structured?["accounts"]?.arrayValue ?? []
            try require(
                accountStatus.structured?["configured"]?.boolValue == true, "publish", "account_status: not configured")
            try require(
                statusAccounts.first?["channelHandle"]?.stringValue == "@skeleton"
                    && statusAccounts.first?["channelTitle"]?.stringValue == "Skeleton Channel", "publish",
                "account_status accounts \(statusAccounts)")
            try require(await services.approvals.pending().isEmpty, "publish", "gate still has pending requests")
            ok(
                "publish",
                "connected \(connected.id) (\(connected.channelTitle ?? "") \(connected.channelHandle ?? "")); "
                    + "render \(renderId.prefix(8))… done (h264_1080p, v\(renderRow.projectVersion), "
                    + "\(exportHash.prefix(15))…); publish_youtube -> approval_required "
                    + "(\(detailLabels.joined(separator: ", "))); approved on the stack, retried; "
                    + String(
                        format: "%.1f MiB in %d KiB chunks, dropped after %.2f MiB, resumed %d; ",
                        Double(exportBytes) / 1_048_576, Int(chunk >> 10), Double(dropAfter) / 1_048_576,
                        receipt.resumedCount)
                    + "done \(receipt.remoteId) \(receipt.remoteURL.absoluteString) private, 1 caption, "
                    + "thumbnail set; row done, no session; publish_status over MCP lists it; "
                    + "account_status shows \(connected.channelHandle ?? "")")

            // 13. The OAuth client set in the window: an `.auto` stack over its own root starts
            //     unconfigured with the publish tools unregistered, and saving a client through the store
            //     the panel uses configures the same provider and publisher and puts the tools back — no
            //     relaunch (docs/plans/publish-client-setup.md).
            let clientRoot = root.appendingPathComponent("client-check", isDirectory: true)
            try FileManager.default.createDirectory(at: clientRoot, withIntermediateDirectories: true)
            let clientEnvironment = ["TIMELINE_ROOT": clientRoot.path, "TIMELINE_TOKEN_STORE": "file"]
            let auto = try await PublishingServices.make(
                mode: .auto, layout: LibraryLayout(root: clientRoot), environment: clientEnvironment,
                log: AppLog(echo: false))
            let clientStore = try unwrap(auto.clientStore, "client", "no client store in .auto")
            let autoProvider = try unwrap(auto.accounts, "client", "no provider in .auto")
            try require(!autoProvider.isConfigured, "client", "provider configured before a client was set")
            try require(auto.publisher != nil, "client", "no publisher to reconfigure")
            let clientRegistry = EditorToolRegistry(tools: EditorTools.all)
            await auto.syncTools(in: clientRegistry)
            try require(
                await clientRegistry.tool(named: "publish_youtube") == nil, "client",
                "publish_youtube registered without a client")
            try require(
                await clientRegistry.tool(named: "account_status") != nil, "client", "account_status dropped")

            let saved = try await clientStore.save(
                clientId: "check-123.apps.googleusercontent.com", clientSecret: "check-secret", audited: false)
            try require(saved.isEditable, "client", "the saved client reads as not editable")
            await auto.apply(
                await clientStore.configuration(), registry: clientRegistry, environment: clientEnvironment)
            try require(autoProvider.isConfigured, "client", "the provider did not take the saved client")
            try require(
                auto.state == .configured(clientId: "check-123.apps.googleusercontent.com", audited: false),
                "client", "state \(auto.state)")
            let backNames = await clientRegistry.list().map(\.name)
            try require(
                backNames.contains("publish_youtube") && backNames.contains("publish_status"), "client",
                "the publish tools did not come back")
            let clientFile = clientRoot.appendingPathComponent("google-oauth-client.json")
            let clientMode =
                try FileManager.default.attributesOfItem(atPath: clientFile.path)[.posixPermissions]
                as? NSNumber
            try require(clientMode?.int16Value == 0o600, "client", "client file mode \(clientMode ?? 0)")

            try await clientStore.remove()
            await auto.apply(nil, registry: clientRegistry, environment: clientEnvironment)
            try require(!autoProvider.isConfigured, "client", "the provider kept the removed client")
            try require(
                await clientRegistry.tool(named: "publish_youtube") == nil, "client",
                "publish_youtube stayed after the client was removed")
            ok(
                "client",
                "unconfigured .auto stack: publish_youtube hidden; saved check-123... at \(clientFile.path) "
                    + "(0600) -> provider configured, publish_youtube and publish_status back; removed -> hidden again")

            // 14. Close, reopen from disk, same version and state; then shut down.
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
            let reopenedRow = try await reopened.publishLedger?.publish(publishId) ?? nil
            try require(
                reopenedRow?.status == .done && reopenedRow?.session == nil, "reopen",
                "publish row after reopen: \(String(describing: reopenedRow?.status))")
            try require(
                try await reopened.renderLedger?.render(renderId)?.status == .done, "reopen", "render row after reopen")
            await reopened.close(using: services)
            await services.shutdown()
            let receipts = await (services.receipts as? ReceiptLog)?.receipts.count ?? 0
            ok(
                "reopen",
                "v\(finalVersion) after close and reopen, state and history equal, publish row done; "
                    + "\(receipts) tool receipts logged")

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

    /// Approves the next request for `tool` that lands on the stack, the way a human would; nil on timeout.
    private static func approveNext(_ tool: String, on approvals: ApprovalCenter, timeout: Duration = .seconds(20))
        -> Task<ApprovalRequest?, Never>
    {
        Task { @MainActor in
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let request = approvals.requests.first(where: { $0.tool == tool }) {
                    await approvals.approve(request)
                    return request
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }
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

extension SkeletonCheck {
    /// Regular files under `root`, so the check can prove a duplicate did not copy the original again.
    static func fileCount(under root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return 0 }
        var count = 0
        for case let url as URL in enumerator
        where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            count += 1
        }
        return count
    }
}

/// A view point one second into `clip` on its row: what the pointer would be over.
@MainActor
private func toneClipCutPoint(viewModel: TimelineViewModel, clip: Clip, row: TrackRow) -> CGPoint {
    CGPoint(x: viewModel.layout.x(forSeconds: clip.start.seconds + 1), y: row.midY)
}
