import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import AgentKit

/// The tools against the fakes: `timeline_apply` round trip (stale version, `$ref`, idempotent retry),
/// approval gating, receipts, and every other tool's happy path.
@Suite struct ToolTests {
    struct Harness {
        var services: TestServices
        var registry: EditorToolRegistry
        var context: ToolContext

        static func make(fixture: String = "three-clips", policy: ApprovalPolicy = .standard) async throws -> Harness {
            let services = try await TestServices.make(fixture: fixture, approvalPolicy: policy)
            let context = services.toolContext()
            let registry = await EditorTools.standard(context: context, clock: FixedClock(step: 1))
            return Harness(services: services, registry: registry, context: context)
        }

        func call(_ name: String, _ input: JSONValue) async throws -> ToolOutput {
            try await registry.call(name, input: ToolInput(input.objectValue ?? [:]), context: context)
        }

        var project: Project {
            get async { await services.store.state() }
        }

        func videoClips() async -> [Clip] {
            let p = await project
            return p.activeSequence!.tracks.filter { $0.kind == .video }.flatMap { $0.clips.values }.sorted {
                $0.start < $1.start
            }
        }
    }

    @Test func standardRegistryListsEveryToolWhenServicesArePresent() async throws {
        let h = try await Harness.make()
        #expect(await h.registry.list().map(\.name) == EditorTools.names)
        let bare = ToolContext(
            projects: FakeProjectDirectory(), services: ToolServices(), approvals: FakeApprovalGate(), actor: .human)
        let reduced = await EditorTools.standard(context: bare)
        let names = await reduced.list().map(\.name)
        #expect(names.contains("project_list") && names.contains("timeline_apply") && !names.contains("render_export"))
        #expect(!names.contains("align_audio") && !names.contains("look_at"))
    }

    @Test func projectListAndDescribe() async throws {
        let h = try await Harness.make()
        let list = try await h.call("project_list", [:])
        #expect(!list.isError)
        #expect(list.structured?["count"]?.intValue == 1)
        #expect(list.structured?["projects"]?[0]?["isFrontmost"] == .bool(true))
        let projectId = try #require(list.structured?["projects"]?[0]?["projectId"]?.stringValue)

        let summary = try await h.call("project_describe", [:])
        #expect(summary.structured?["projectId"]?.stringValue == projectId)
        let currentVersion = await h.project.version
        #expect(summary.structured?["version"]?.intValue == Int(currentVersion))
        #expect(summary.structured?["sequences"]?[0]?["tracks"] == nil)
        #expect((summary.structured?["assets"]?.arrayValue?.count ?? 0) == 3)

        let tracks = try await h.call("project_describe", ["level": "tracks", "projectId": .string(projectId)])
        let trackList = try #require(tracks.structured?["sequences"]?[0]?["tracks"]?.arrayValue)
        #expect(!trackList.isEmpty)
        #expect(trackList.contains { ($0["clips"]?.arrayValue?.count ?? 0) > 0 })

        let full = try await h.call("project_describe", ["level": "full"])
        #expect(full.structured?["project"]?["id"]?.stringValue == projectId)
        let validator = JSONSchemaValidator(root: ProjectTools.projectDescribe.outputSchema!)
        #expect(validator.validate(full.structured!).isEmpty)

        let missing = try await h.call("project_describe", ["projectId": "nope"])
        #expect(missing.isError && missing.text?.contains("nope") == true)

        let ranged = try await h.call(
            "project_describe",
            ["level": "tracks", "range": ["start": ["v": 0, "ts": 24000], "end": ["v": 1, "ts": 24000]]])
        let rangedClips = ranged.structured?["sequences"]?[0]?["tracks"]?.arrayValue?.flatMap {
            $0["clips"]?.arrayValue ?? []
        }
        #expect((rangedClips?.count ?? 0) < (trackList.flatMap { $0["clips"]?.arrayValue ?? [] }.count))
    }

    @Test func timelineQuery() async throws {
        let h = try await Harness.make()
        let clips = try await h.call("timeline_query", ["filter": ["kind": "clips", "trackKind": "video"]])
        #expect(!clips.isError)
        let count = clips.structured?["count"]?.intValue ?? 0
        #expect(count == (await h.videoClips()).count)
        let first = try #require(clips.structured?["results"]?[0])
        let one = try await h.call("timeline_query", ["filter": ["kind": "clips", "clipId": first["clipId"]!]])
        #expect(one.structured?["count"]?.intValue == 1)
        let assets = try await h.call("timeline_query", ["filter": ["kind": "assets", "textContains": "img"]])
        #expect(assets.structured?["count"]?.intValue == 1)
        let history = try await h.call("timeline_query", ["filter": ["kind": "history", "limit": 2]])
        #expect(history.structured?["count"]?.intValue == 2)
        let tracks = try await h.call("timeline_query", ["filter": ["kind": "tracks"]])
        #expect((tracks.structured?["count"]?.intValue ?? 0) >= 2)
        let bad = try await h.call("timeline_query", ["filter": ["kind": "planets"]])
        #expect(bad.isError)
    }

    @Test func timelineApplyRoundTripsWithStaleRefAndIdempotentRetry() async throws {
        let h = try await Harness.make()
        let clips = await h.videoClips()
        let clip = try #require(clips.first)
        let version = await h.project.version

        // 1. A plain move with the right version applies and bumps the version.
        let target = RationalTime.frames(48, of: Fixtures.frameDuration)
        let move: JSONValue = [
            "expectedVersion": .number(Double(version)), "commandId": "move-1",
            "ops": [
                [
                    "type": "moveClip", "clipId": .string(clip.id.rawValue), "mode": "overwrite",
                    "to": ["start": try JSONValue(encoding: target)],
                ]
            ],
        ]
        let applied = try await h.call("timeline_apply", move)
        #expect(!applied.isError, "\(applied)")
        #expect(applied.structured?["status"] == "applied")
        let v1 = try #require(applied.structured?["version"]?.intValue)
        #expect(Int64(v1) > version)
        #expect(applied.structured?["changedIds"]?.arrayValue?.contains(.string(clip.id.rawValue)) == true)
        #expect(applied.structured?["txnId"]?.stringValue != nil)
        let movedStart = await h.services.store.state().activeSequence?.clip(clip.id)?.start
        #expect(movedStart == target)
        #expect(await h.services.store.receivedCommands.last?.actor == .agent(sessionId: "session-1"))
        let outputValidator = JSONSchemaValidator(root: ApplyTools.timelineApply.outputSchema!)
        #expect(outputValidator.validate(applied.structured!).isEmpty)

        // 2. Retrying the same commandId (even with the now-stale version) replays the stored result.
        let retry = try await h.call("timeline_apply", move)
        #expect(!retry.isError)
        #expect(retry.structured?["status"] == "replayed")
        #expect(retry.structured?["version"]?.intValue == v1)
        #expect(await h.services.store.version() == Int64(v1))

        // 3. A new commandId with the stale version is rejected with ChangedSince inline.
        var stale = move
        stale["commandId"] = "move-2"
        let rejected = try await h.call("timeline_apply", stale)
        #expect(rejected.isError)
        #expect(rejected.structured?["error"] == "staleVersion")
        #expect(rejected.structured?["current"]?.intValue == v1)
        let since = try #require(rejected.structured?["changedSince"])
        #expect(since["fromVersion"]?.intValue == Int(version) && since["toVersion"]?.intValue == v1)
        #expect(since["transactions"]?.arrayValue?.count == 1)
        #expect(since["transactions"]?[0]?["changedIds"]?.arrayValue?.contains(.string(clip.id.rawValue)) == true)
        #expect(since["transactions"]?[0]?["events"]?.arrayValue?.contains { $0["type"] == "ClipMoved" } == true)
        #expect(rejected.structured?["hint"]?.stringValue?.contains("new commandId") == true)
        let decoded = try rejected.structured!.decoded(as: EditorError.self)
        if case .staleVersion(let current, let changed) = decoded {
            #expect(current == Int64(v1) && changed?.transactions.count == 1)
        } else {
            Issue.record("expected staleVersion")
        }

        // 4. $ref: split, then add a transition onto the new cut, in one batch.
        let sequence = try #require(await h.project.activeSequence)
        let moved = try #require(sequence.clip(clip.id))
        let cut = moved.start + RationalTime.frames(30, of: sequence.frameDuration)
        let batch: JSONValue = [
            "expectedVersion": .number(Double(v1)), "commandId": "split-dissolve",
            "ops": [
                ["type": "splitClip", "clipId": .string(clip.id.rawValue), "at": try JSONValue(encoding: cut)],
                [
                    "type": "addTransition", "leftClipId": .string(clip.id.rawValue), "rightClipId": ["$ref": 0],
                    "kind": "dissolve",
                    "duration": try JSONValue(encoding: RationalTime.frames(8, of: sequence.frameDuration)),
                ],
            ],
        ]
        let split = try await h.call("timeline_apply", batch)
        #expect(!split.isError, "\(split)")
        let after = try #require(await h.project.activeSequence)
        #expect(after.transitions.count == sequence.transitions.count + 1)
        let transition = try #require(after.transitions.values.first { $0.leftClipId == clip.id })
        #expect(after.clip(transition.rightClipId)?.start == cut)
        #expect(split.structured?["opCount"]?.intValue == 2)
        #expect(await h.services.store.history().latestLive?.label == "2 edits")

        // 5. Decoding errors are readable, and undo/redo travel through the same tool.
        let malformed = try await h.call(
            "timeline_apply", ["expectedVersion": 1, "ops": [["type": "moveClip", "clipId": "x"]]])
        #expect(malformed.isError && malformed.text?.contains("to") == true)
        let v2 = await h.project.version
        let undo = try await h.call(
            "timeline_apply", ["expectedVersion": .number(Double(v2)), "ops": [["type": "undo"]]])
        let afterUndo = await h.project.activeSequence?.transitions.count
        #expect(!undo.isError && afterUndo == sequence.transitions.count)
        let redo = try await h.call("redo", [:])
        let afterRedo = await h.project.activeSequence?.transitions.count
        #expect(!redo.isError && afterRedo == sequence.transitions.count + 1)
        let undo2 = try await h.call("undo", [:])
        #expect(!undo2.isError)
        let nothing = try await h.call("redo", ["expectedVersion": 0])
        #expect(nothing.isError && nothing.structured?["error"] == "staleVersion")

        // 6. Receipts were recorded for every call with the session and outcome.
        let receipts = await h.services.receipts.receipts
        #expect(receipts.map(\.toolName).prefix(3) == ["timeline_apply", "timeline_apply", "timeline_apply"])
        #expect(receipts[0].outcome == .applied && receipts[0].version == Int64(v1) && receipts[0].txnId != nil)
        #expect(receipts[1].outcome == .applied)
        #expect(receipts[2].outcome == .rejected)
        #expect(receipts.allSatisfy { $0.sessionId == "session-1" && $0.actor == .agent(sessionId: "session-1") })
        #expect(receipts.filter { $0.outcome == .applied }.allSatisfy { $0.projectId != nil })
    }

    @Test func schemaViolationsAreRejectedBeforeTheHandlerRuns() async throws {
        let h = try await Harness.make()
        let output = try await h.call("timeline_apply", ["ops": []])
        #expect(output.isError && output.structured?["error"] == "invalidInput")
        #expect(output.structured?["violations"]?.arrayValue?.isEmpty == false)
        #expect(await h.services.store.receivedCommands.isEmpty)
        let unknown = try await h.call("project_describe", ["level": "everything"])
        #expect(unknown.isError)
        await #expect(throws: ToolError.unknownTool("nope")) { try await h.call("nope", [:]) }
    }

    @Test func transitionAddReportsHandles() async throws {
        let h = try await Harness.make()
        let clips = await h.videoClips()
        let version = await h.project.version
        // Adjacent pair on V1: the fixture's first two clips.
        let left = clips[0]
        let leftEnd = try #require(await h.project.activeSequence).end(of: left)
        let right = try #require(clips.first { $0.start == leftEnd })
        let added = try await h.call(
            "transition_add",
            [
                "expectedVersion": .number(Double(version)), "leftClipId": .string(left.id.rawValue),
                "rightClipId": .string(right.id.rawValue), "durationFrames": 4, "transitionId": "t-1",
                "alignment": "endOnCut",
            ])
        #expect(!added.isError, "\(added)")
        #expect(added.structured?["transitionId"] == "t-1")
        let addedDuration = await h.project.activeSequence?.transitions["t-1"]?.duration
        #expect(addedDuration == RationalTime.frames(4, of: Fixtures.frameDuration))
        let versionAfterAdd = await h.project.version
        let tooLong = try await h.call(
            "transition_add",
            [
                "expectedVersion": .number(Double(versionAfterAdd)), "leftClipId": .string(left.id.rawValue),
                "rightClipId": .string(right.id.rawValue), "durationFrames": 100_000,
            ])
        #expect(tooLong.isError)
        #expect(["transitionHandles", "invalid"].contains(tooLong.structured?["error"]?.stringValue ?? ""))
    }

    @Test func captionAddFromTextAndTranscript() async throws {
        let h = try await Harness.make()
        let version = await h.project.version
        let text = try await h.call(
            "caption_add",
            [
                "expectedVersion": .number(Double(version)), "source": "text",
                "text": "Welcome back. Today we build a timeline! Stay tuned?",
                "style": ["fontSize": 64, "position": "center", "extra": [:]],
            ])
        #expect(!text.isError, "\(text)")
        #expect(text.structured?["itemCount"]?.intValue == 3)
        let trackId = try #require(text.structured?["trackId"]?.stringValue)
        let track = try #require(await h.project.activeSequence?.tracks.first { $0.id.rawValue == trackId })
        #expect(track.kind == .caption && track.clips.count == 3 && track.captionStyle?.fontSize == 64)

        let versionAfterText = await h.project.version
        let transcript = try await h.call(
            "caption_add",
            [
                "expectedVersion": .number(Double(versionAfterText)), "source": "transcript",
                "trackId": .string(trackId), "maxWordsPerCaption": 3,
            ])
        #expect(!transcript.isError, "\(transcript)")
        #expect(transcript.structured?["transcriptCacheKey"]?.stringValue?.contains("/transcript/") == true)
        let replaced = try #require(await h.project.activeSequence?.tracks.first { $0.id.rawValue == trackId })
        #expect(replaced.clips.count == transcript.structured?["itemCount"]?.intValue)
        #expect(replaced.clips.values.allSatisfy { ($0.words?.count ?? 0) <= 3 && $0.text != nil })
        #expect(h.services.analyzer.calls.count == 1)

        let versionAfterTranscript = await h.project.version
        let explicit = try await h.call(
            "caption_add",
            [
                "expectedVersion": .number(Double(versionAfterTranscript)), "source": "text",
                "items": [["start": ["v": 0, "ts": 24000], "duration": ["v": 24024, "ts": 24000], "text": "Hi"]],
            ])
        #expect(explicit.structured?["itemCount"]?.intValue == 1)
        let captionTracks = await h.project.activeSequence?.tracks.filter { $0.kind == .caption }.count
        #expect(captionTracks == 2)
    }

    /// The overlap the real app hit: transcript word times abut, `captions(from:)` snaps a start to the
    /// nearest frame and ceils an end, so caption N+1 began before caption N ended and `replaceCaptions`
    /// rejected the whole call - at every `maxWordsPerCaption`, including 1.
    @Test func captionsFromATranscriptNeverOverlap() {
        let frame = RationalTime(value: 1001, timescale: 30000)  // 29.97
        func time(_ seconds: Double) -> RationalTime {
            RationalTime(value: Int64((seconds * 30000).rounded()), timescale: 30000)
        }
        // Two chunks whose word times touch at 1.01s: the first ceils up to frame 31, the second snaps
        // down to frame 30.
        let items = [
            Command.Operation.CaptionInput(
                start: time(0.5).snapped(to: frame),
                duration: time(1.01).ceiled(to: frame) - time(0.5).snapped(to: frame),
                text: "hello there", words: []),
            Command.Operation.CaptionInput(
                start: time(1.01).snapped(to: frame), duration: time(0.6), text: "friend",
                words: [CaptionWord(text: "friend", t0: .zero, t1: time(0.6))]),
        ]
        #expect(items[1].start < items[0].start + items[0].duration, "the input must actually overlap")

        let fixed = ApplyTools.deoverlapped(items, frameDuration: frame)
        #expect(fixed.count == 2)
        for i in fixed.indices.dropFirst() {
            #expect(fixed[i].start >= fixed[i - 1].start + fixed[i - 1].duration)
        }
        #expect(fixed.allSatisfy { $0.duration.isPositive })
        #expect(fixed.map(\.text) == ["hello there", "friend"])

        // Two chunks inside one frame merge instead of becoming a zero-length caption, keeping the words.
        let sameFrame = [
            Command.Operation.CaptionInput(
                start: .zero, duration: time(0.2), text: "a", words: [CaptionWord(text: "a", t0: .zero, t1: time(0.01))]
            ),
            Command.Operation.CaptionInput(
                start: RationalTime(value: 10, timescale: 30000), duration: time(0.2), text: "b",
                words: [CaptionWord(text: "b", t0: .zero, t1: time(0.01))]),
        ]
        let merged = ApplyTools.deoverlapped(sameFrame, frameDuration: frame)
        #expect(merged.count == 1)
        #expect(merged[0].text == "a b" && merged[0].words.count == 2)
        #expect(merged[0].duration.isPositive)
    }

    @Test func renderExportIsGatedByApproval() async throws {
        let h = try await Harness.make()
        let first = try await h.call("render_export", ["preset": "reel9x16"])
        #expect(first.isApprovalRequired && !first.isError)
        let token = try #require(first.structured?["approvalToken"]?.stringValue)
        #expect(first.structured?["estimate"]?["seconds"]?.numberValue ?? 0 > 0)
        #expect(first.structured?["tool"] == "render_export")
        #expect(h.services.renderer.calls.isEmpty)

        // Retrying before the grant asks again with a new token.
        let again = try await h.call("render_export", ["preset": "reel9x16", "approvalToken": .string(token)])
        #expect(again.isApprovalRequired && again.structured?["approvalToken"]?.stringValue != token)

        await h.services.approvals.grant(ApprovalToken(token))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentkit-\(UUID().uuidString)/reel.mp4")
        let done = try await h.call(
            "render_export", ["preset": "reel9x16", "approvalToken": .string(token), "outputPath": .string(out.path)])
        #expect(!done.isError && !done.isApprovalRequired, "\(done)")
        #expect(done.structured?["status"] == "done")
        #expect(done.structured?["outputPath"]?.stringValue == out.path)
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(done.structured?["receipt"]?["preset"]?["name"] == "Reel 9:16")
        #expect(await h.services.jobRunner.submissions.map(\.kind) == [.export])
        #expect(h.services.renderer.calls.contains { if case .export = $0 { true } else { false } })
        #expect(await h.services.approvals.consumed == [ApprovalToken(token)])

        let receipts = await h.services.receipts.receipts
        #expect(receipts.map(\.outcome) == [.approvalRequired, .approvalRequired, .applied])
        try? FileManager.default.removeItem(at: out.deletingLastPathComponent())

        let unknown = try await h.call("render_export", ["preset": "vhs"])
        #expect(unknown.isError)
    }

    @Test func mediaAnalyzeRequiresApprovalForTranscriptionWhenPolicySaysSo() async throws {
        let policy = ApprovalPolicy(rules: ["media_analyze": .whenEstimate(above: Estimate(seconds: 0))])
        let h = try await Harness.make(policy: policy)
        let assetId = try #require(await h.project.assets.values.first { $0.hasAudio && $0.hasVideo }?.id.rawValue)
        let silence = try await h.call("media_analyze", ["assetId": .string(assetId), "kinds": ["silence", "shots"]])
        #expect(!silence.isError && !silence.isApprovalRequired, "\(silence)")
        #expect(silence.structured?["results"]?["silence"]?["count"]?.intValue == 2)
        #expect(silence.structured?["results"]?["shots"]?["count"]?.intValue == 3)
        let recorded = await h.project.assets[AssetID(assetId)]?.analyses
        #expect(recorded?["silence"]?.cacheKey.contains("/silence/") == true && recorded?["shots"] != nil)
        #expect(await h.services.jobRunner.submissions.map(\.kind) == [.analysis, .analysis])

        let asks = try await h.call("media_analyze", ["assetId": .string(assetId), "kinds": ["transcript"]])
        #expect(asks.isApprovalRequired)
        let token = try #require(asks.structured?["approvalToken"]?.stringValue)
        await h.services.approvals.grant(ApprovalToken(token))
        let transcribed = try await h.call(
            "media_analyze", ["assetId": .string(assetId), "kinds": ["transcript"], "approvalToken": .string(token)])
        #expect(!transcribed.isError && !transcribed.isApprovalRequired, "\(transcribed)")
        #expect(transcribed.structured?["results"]?["transcript"]?["words"]?.intValue == 7)
        let transcriptAnalysis = await h.project.assets[AssetID(assetId)]?.analyses["transcript"]
        #expect(transcriptAnalysis != nil)
        #expect(await h.services.jobRunner.submissions.last?.kind == .transcription)
    }

    @Test func transcriptSearchFindsPhrasesAndPlacesThem() async throws {
        let h = try await Harness.make()
        let clip = try #require(await h.videoClips().first)
        let assetId = try #require(clip.assetId)
        let none = try await h.call("transcript_search", ["query": "welcome"])
        #expect(none.structured?["count"]?.intValue == 0)  // no transcript recorded yet
        let hits = try await h.call(
            "transcript_search", ["query": "Video Editor", "assetId": .string(assetId.rawValue)])
        #expect(hits.structured?["count"]?.intValue == 1, "\(hits)")
        let hit = try #require(hits.structured?["hits"]?[0])
        #expect(hit["text"] == "Video Editor")
        #expect(hit["context"]?.stringValue?.contains("Timeline") == true)
        // The fixture words sit in the first 2.5 s; the clip's sourceIn is 1 s, so the hit lands on it.
        let placements = hit["placements"]?.arrayValue ?? []
        #expect(placements.contains { $0["clipId"]?.stringValue == clip.id.rawValue })
        let miss = try await h.call("transcript_search", ["query": "banana", "assetId": .string(assetId.rawValue)])
        #expect(miss.structured?["count"]?.intValue == 0)
    }

    @Test func lookAtReturnsAContactSheet() async throws {
        let h = try await Harness.make()
        let assetId = try #require(await h.project.assets.values.first { $0.hasVideo }?.id.rawValue)
        let out = try await h.call(
            "look_at",
            [
                "assetId": .string(assetId), "height": 60,
                "timestamps": [
                    ["v": 0, "ts": 24000], ["v": 24024, "ts": 24000], ["v": 48048, "ts": 24000],
                    ["v": 72072, "ts": 24000],
                ],
            ])
        #expect(!out.isError, "\(out)")
        #expect(out.images.count == 1 && out.images[0].mimeType == "image/png")
        #expect(out.images[0].data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(out.structured?["frames"]?.arrayValue?.count == 4)
        #expect(out.structured?["columns"]?.intValue == 3 && out.structured?["rows"]?.intValue == 2)
        #expect(out.structured?["width"]?.intValue == 3 * (60 * 16 / 9))
        #expect(h.services.thumbnails.calls.count == 4)
    }

    @Test func renderPreviewReturnsFrames() async throws {
        let h = try await Harness.make()
        let one = try await h.call("render_preview", ["at": ["v": 24024, "ts": 24000], "width": 160])
        #expect(!one.isError && one.images.count == 1, "\(one)")
        #expect(one.structured?["frames"]?.arrayValue?.count == 1)
        let many = try await h.call(
            "render_preview",
            ["range": ["start": ["v": 0, "ts": 24000], "end": ["v": 240240, "ts": 24000]], "count": 5, "width": 96])
        #expect(many.structured?["frames"]?.arrayValue?.count == 5)
        #expect(h.services.renderer.calls.filter { if case .frame = $0 { true } else { false } }.count == 6)
    }

    @Test func alignAudioRunsThroughTheJobRunnerWithAProof() async throws {
        let h = try await Harness.make()
        let project = await h.project
        let camera = try #require(project.assets.values.first { $0.hasVideo && $0.hasAudio })
        let mix = try #require(project.assets.values.first { !$0.hasVideo && $0.hasAudio })
        let out = try await h.call(
            "align_audio", ["referenceAssetId": .string(camera.id.rawValue), "targetAssetId": .string(mix.id.rawValue)])
        #expect(!out.isError, "\(out)")
        #expect(out.structured?["status"] == "aligned")
        #expect(abs((out.structured?["offsetSeconds"]?.numberValue ?? 0) - 7.345) < 0.001)
        #expect(out.structured?["candidates"]?.arrayValue?.count == 1)
        #expect(out.images.count == 1)
        #expect(await h.services.jobRunner.submissions.map(\.kind) == [.alignment])
        let call = try #require(h.services.aligner.calls.first)
        #expect(call.reference.contentHash == camera.contentHash && call.target.contentHash == mix.contentHash)
        let validator = JSONSchemaValidator(root: AlignTools.alignAudio.outputSchema!)
        #expect(validator.validate(out.structured!).isEmpty)

        let noVideoAudio = try #require(project.assets.values.first { !$0.hasAudio })
        let refused = try await h.call(
            "align_audio",
            ["referenceAssetId": .string(noVideoAudio.id.rawValue), "targetAssetId": .string(mix.id.rawValue)])
        #expect(refused.isError)

        h.services.aligner.setResult(.failedFixture)
        let failed = try await h.call(
            "align_audio", ["referenceAssetId": .string(camera.id.rawValue), "targetAssetId": .string(mix.id.rawValue)])
        #expect(
            failed.structured?["status"] == "failed" && failed.structured?["offset"] == nil && failed.images.isEmpty)
    }

    @Test func alignAudioAsksForApprovalOnLongInputsWhenPolicySaysSo() async throws {
        let policy = ApprovalPolicy(rules: ["align_audio": .always])
        let h = try await Harness.make(policy: policy)
        let project = await h.project
        let camera = try #require(project.assets.values.first { $0.hasVideo && $0.hasAudio })
        let mix = try #require(project.assets.values.first { !$0.hasVideo && $0.hasAudio })
        // The fixture camera clip is 30 s: no approval even with an `always` rule.
        let short = try await h.call(
            "align_audio", ["referenceAssetId": .string(camera.id.rawValue), "targetAssetId": .string(mix.id.rawValue)])
        #expect(!short.isApprovalRequired)
        // A two-hour reference asks.
        var long = camera
        long.id = "long-cam"
        long.contentHash = "sha256-long"
        long.duration = RationalTime(7200, 1)
        try await h.services.store.apply(.restoreAsset(.init(asset: long)))
        let asks = try await h.call(
            "align_audio", ["referenceAssetId": "long-cam", "targetAssetId": .string(mix.id.rawValue)])
        #expect(asks.isApprovalRequired, "\(asks)")
        #expect(asks.structured?["estimate"]?["seconds"]?.numberValue == 2)
    }

    @Test func mediaImportRecordsTheAssetOnce() async throws {
        let h = try await Harness.make(fixture: "empty")
        let dir = try TestMedia.Directory(prefix: "AgentKitImport")
        let tone = try await TestMedia.tone(frequency: 440, duration: 1, in: dir.url, name: "tone")
        let version = await h.project.version
        let imported = try await h.call("media_import", ["url": .string(tone.url.path), "mode": "copy"])
        #expect(!imported.isError, "\(imported)")
        #expect(imported.structured?["alreadyInLibrary"] == .bool(false))
        #expect(imported.structured?["alreadyInProject"] == .bool(false))
        #expect(imported.structured?["version"]?.intValue == Int(version) + 1)
        let assetId = try #require(imported.structured?["asset"]?["assetId"]?.stringValue)
        let importedKind = await h.project.assets[AssetID(assetId)]?.kind
        #expect(importedKind == .audio)
        #expect(await h.services.jobRunner.submissions.map(\.kind) == [.import])

        let again = try await h.call("media_import", ["url": .string("file://" + tone.url.path)])
        #expect(again.structured?["alreadyInLibrary"] == .bool(true))
        #expect(again.structured?["alreadyInProject"] == .bool(true))
        #expect(again.structured?["status"] == "noop")
        let assetCount = await h.project.assets.count
        #expect(assetCount == 1)

        let missing = try await h.call("media_import", ["url": .string(dir.file("nope.mov").path)])
        #expect(missing.isError && missing.structured?["error"] == "mediaError")
    }

    @Test func serviceUnavailableIsAnErrorOutput() async throws {
        let h = try await Harness.make()
        var services = h.services.services
        services.renderer = nil
        let context = ToolContext(
            projects: h.services.projects, services: services, approvals: h.services.approvals, actor: .human)
        let registry = EditorToolRegistry(tools: EditorTools.all)
        let out = try await registry.call("render_preview", input: ToolInput(), context: context)
        #expect(out.isError && out.text?.contains("renderer") == true)
    }
}

/// `timeline_cut` resolves which clips a time falls inside before it sends anything, because `decide`
/// snaps the point per track and then throws on anything not strictly inside — and a batch has no
/// per-operation recovery, so one clip resolved wrong takes the whole call with it.
@Suite("timeline_cut") struct CutToolTests {
    typealias Harness = ToolTests.Harness

    func clips(_ h: Harness, _ kind: TrackKind) async -> [Clip] {
        let p = await h.project
        return p.activeSequence!.tracks.filter { $0.kind == kind }.flatMap { $0.clips.values }
            .sorted { $0.start < $1.start }
    }

    @Test func cuttingAtATimeSplitsEveryUnlockedTrackInOneTransaction() async throws {
        let h = try await Harness.make(fixture: "linked-transition-caption-undone")
        let version = await h.project.version
        // 3 s: inside the first V/A pair and inside the second caption item.
        let out = try await h.call(
            "timeline_cut", ["expectedVersion": .number(Double(version)), "at": ["v": 72000, "ts": 24000]])
        #expect(!out.isError, "\(out)")
        #expect(out.structured?["status"] == "applied")
        // The linked pair is one operation and one cut row; the caption item is its own.
        #expect(out.structured?["cutCount"] == 2)
        #expect(await clips(h, .video).count == 3)
        #expect(await clips(h, .audio).count == 3, "the linked audio came along")
        #expect(await clips(h, .caption).count == 3)

        let txns = await h.services.store.history().live.count
        #expect(await h.project.version > version)
        #expect(txns >= 1)
    }

    @Test func clipIdsCutsExactlyThoseClipsAndTrackIdsCutsThoseTracks() async throws {
        let h = try await Harness.make()
        let video = await clips(h, .video)
        let long = video[2]
        var version = await h.project.version

        let byClip = try await h.call(
            "timeline_cut",
            [
                "expectedVersion": .number(Double(version)),
                "at": try JSONValue(encoding: long.start + RationalTime(seconds: 1)),
                "clipIds": .array([.string(long.id.rawValue)]),
            ])
        #expect(!byClip.isError, "\(byClip)")
        #expect(byClip.structured?["cutCount"] == 1)
        #expect(await clips(h, .video).count == 4)
        #expect(await clips(h, .audio).count == 1, "the audio track was never addressed")

        version = await h.project.version
        let audioTrack = try #require(await h.project.activeSequence?.tracks.first { $0.kind == .audio })
        let byTrack = try await h.call(
            "timeline_cut",
            [
                "expectedVersion": .number(Double(version)), "atFrames": 120,
                "trackIds": .array([.string(audioTrack.id.rawValue)]),
            ])
        #expect(!byTrack.isError, "\(byTrack)")
        #expect(byTrack.structured?["cutCount"] == 1)
        #expect(await clips(h, .audio).count == 2)
        #expect(await clips(h, .video).count == 4, "the video tracks were left alone")
    }

    @Test func passingBothClipIdsAndTrackIdsIsRejected() async throws {
        let h = try await Harness.make()
        let out = try await h.call(
            "timeline_cut",
            [
                "expectedVersion": 1, "atFrames": 96, "clipIds": .array([.string("a")]),
                "trackIds": .array([.string("b")]),
            ])
        #expect(out.isError)
        #expect(out.structured?["message"]?.stringValue?.contains("not both") == true, "\(out)")
    }

    @Test func passingNeitherAtNorAtFramesIsRejectedAndPassingBothIsToo() async throws {
        let h = try await Harness.make()
        let neither = try await h.call("timeline_cut", ["expectedVersion": 1])
        #expect(neither.isError)
        #expect(neither.structured?["message"]?.stringValue?.contains("at or atFrames") == true, "\(neither)")

        let both = try await h.call(
            "timeline_cut", ["expectedVersion": 1, "atFrames": 96, "at": ["v": 96096, "ts": 24000]])
        #expect(both.isError)
        #expect(both.structured?["message"]?.stringValue?.contains("not both") == true, "\(both)")
    }

    @Test func aTimeOnAClipBoundaryIsSkippedWhileOtherTracksStillCut() async throws {
        let h = try await Harness.make()
        let version = await h.project.version
        // Frame 96 is exactly the seam between the first two video clips, and partway through the music.
        let out = try await h.call(
            "timeline_cut", ["expectedVersion": .number(Double(version)), "atFrames": 96])
        #expect(!out.isError, "\(out)")
        #expect(out.structured?["cutCount"] == 1, "only the audio clip straddles that time")
        #expect(await clips(h, .video).count == 3, "the seam is not a cut")
        #expect(await clips(h, .audio).count == 2)

        let skipped = try #require(out.structured?["skipped"]?.arrayValue)
        #expect(skipped.count == 3)
        #expect(skipped.allSatisfy { $0["reason"] == "notInside" })
    }

    @Test func nothingToCutIsANoopNotAnError() async throws {
        let h = try await Harness.make()
        let version = await h.project.version
        let out = try await h.call(
            "timeline_cut", ["expectedVersion": .number(Double(version)), "atFrames": 100_000])
        #expect(!out.isError, "\(out)")
        #expect(out.structured?["status"] == "noop")
        #expect(out.structured?["cutCount"] == 0)
        #expect(out.text?.contains("Nothing to cut") == true, "\(String(describing: out.text))")
        #expect(await h.project.version == version, "a no-op bumps nothing")
    }

    @Test func theResponseNamesEachCutsNewClipAndReportsTheSnappedTime() async throws {
        let h = try await Harness.make()
        let long = await clips(h, .video)[2]
        let version = await h.project.version
        // A third of a frame past a frame boundary: `decide` rounds it, and the response must say where
        // the cut actually went rather than where it was asked for.
        let asked = long.start + RationalTime(seconds: 1) + RationalTime(300, 24000)
        let out = try await h.call(
            "timeline_cut",
            [
                "expectedVersion": .number(Double(version)), "at": try JSONValue(encoding: asked),
                "clipIds": .array([.string(long.id.rawValue)]),
            ])
        #expect(!out.isError, "\(out)")
        let cuts = try #require(out.structured?["cuts"]?.arrayValue)
        #expect(cuts.count == 1)
        #expect(cuts[0]["clipId"] == .string(long.id.rawValue))
        let landed = try #require(cuts[0]["at"])
        let v = try #require(landed["v"]?.intValue)
        #expect(Int64(v) % 1001 == 0, "the reported time is on a frame boundary")
        #expect(landed["v"] != .number(Double(asked.value)), "and it is not what was asked for")

        // The named right-hand half exists and starts at the cut.
        let newId = try #require(cuts[0]["newClipId"]?.stringValue)
        let right = try #require(await h.project.activeSequence?.clip(ClipID(newId)))
        #expect(right.start == RationalTime(Int64(v), 24000))
        #expect(await h.project.activeSequence?.clip(long.id) != nil, "the left half kept the original id")
    }

    @Test func aStaleVersionIsStillRejectedWhenThereIsNothingToCut() async throws {
        let h = try await Harness.make()
        // The empty plan goes to the store anyway, so the caller learns it is behind rather than being
        // told the far more misleading "nothing to cut".
        let out = try await h.call("timeline_cut", ["expectedVersion": 1, "atFrames": 100_000])
        #expect(out.isError)
        #expect(out.structured?["error"] == "staleVersion")
        #expect(out.structured?["changedSince"] != nil)
    }

    @Test func aStaleExpectedVersionIsRejectedWithChangedSince() async throws {
        let h = try await Harness.make()
        let out = try await h.call("timeline_cut", ["expectedVersion": 1, "atFrames": 120])
        #expect(out.isError)
        #expect(out.structured?["error"] == "staleVersion")
        #expect(out.structured?["changedSince"] != nil)
    }

    @Test func replayingTheSameCommandIdIsIdempotent() async throws {
        let h = try await Harness.make()
        let version = await h.project.version
        let input: JSONValue = [
            "expectedVersion": .number(Double(version)), "atFrames": 120, "commandId": "cut-once",
        ]
        let first = try await h.call("timeline_cut", input)
        #expect(first.structured?["status"] == "applied")
        let after = await h.project.version

        let again = try await h.call("timeline_cut", input)
        #expect(again.structured?["status"] == "replayed")
        #expect(await h.project.version == after, "the replay cut nothing a second time")
        #expect(await clips(h, .video).count == 4)
    }

    @Test func unlinkedCutsOneMemberOfALinkGroup() async throws {
        let h = try await Harness.make(fixture: "linked-transition-caption-undone")
        let version = await h.project.version
        let video = await clips(h, .video)[0]
        let out = try await h.call(
            "timeline_cut",
            [
                "expectedVersion": .number(Double(version)), "at": ["v": 72000, "ts": 24000],
                "clipIds": .array([.string(video.id.rawValue)]), "unlinked": true,
            ])
        #expect(!out.isError, "\(out)")
        #expect(out.structured?["cutCount"] == 1)
        #expect(await clips(h, .video).count == 3)
        #expect(await clips(h, .audio).count == 2, "the partner stayed whole")
    }

    @Test func aLinkGroupCrossingALockedTrackIsReportedInSkipped() async throws {
        let h = try await Harness.make(fixture: "linked-transition-caption-undone")
        let audio = try #require(await h.project.activeSequence?.tracks.first { $0.kind == .audio })
        var version = await h.project.version
        let locked = try await h.call(
            "timeline_apply",
            [
                "expectedVersion": .number(Double(version)),
                "ops": .array([["type": "setTrackLocked", "trackId": .string(audio.id.rawValue), "locked": true]]),
            ])
        #expect(!locked.isError, "\(locked)")

        version = await h.project.version
        let out = try await h.call(
            "timeline_cut", ["expectedVersion": .number(Double(version)), "at": ["v": 72000, "ts": 24000]])
        #expect(!out.isError, "a locked partner must never reach the store as a rejection")
        // The caption item still cuts; the V/A pair is passed over because `group(of:)` would reject it.
        #expect(out.structured?["cutCount"] == 1)
        let skipped = try #require(out.structured?["skipped"]?.arrayValue)
        #expect(skipped.contains { $0["reason"] == "lockedPartner" })
        #expect(await clips(h, .video).count == 2, "the video clip was not cut")
        #expect(await clips(h, .caption).count == 3)
    }
}
