import AVFoundation
import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

/// One compile-checked usage example per protocol, through the existential a module would hold.
@Suite struct UsageExampleTests {
    @Test func mediaLibraryImportLocateRelinkOffline() async throws {
        let fake = try FakeMediaLibrary()
        let library: any MediaLibrary = fake
        let dir = try TestMedia.Directory(prefix: "ImportTest")
        let tone = try await TestMedia.tone(frequency: 440, duration: 1, in: dir.url, name: "tone")

        let result = try await library.importAsset(url: tone.url, mode: .copy)
        #expect(!result.alreadyInLibrary)
        #expect(result.asset.kind == .audio && result.asset.hasAudio && !result.asset.hasVideo)
        #expect(result.asset.sampleRate == 48000)
        #expect(abs(result.asset.duration.seconds - 1) < 0.01)
        #expect(result.asset.libraryPath.hasSuffix("/tone.caf") && !result.asset.libraryPath.hasPrefix("/"))
        #expect(result.operation.contentHash == result.asset.contentHash)
        #expect(FileManager.default.fileExists(atPath: result.libraryURL.path))
        #expect(library.layout.url(for: result.asset) == result.libraryURL)
        #expect(await library.locate(contentHash: result.asset.contentHash) == result.libraryURL)

        let again = try await library.importAsset(url: tone.url, mode: .copy)
        #expect(again.alreadyInLibrary && again.asset == result.asset)

        // Relink: move the library copy elsewhere, the hash still matches.
        let moved = dir.file("moved.caf")
        try FileManager.default.moveItem(at: result.libraryURL, to: moved)
        #expect(await library.checkOffline(assets: [result.asset]) == [result.asset.id])
        let relinked = try await library.relink(result.asset, to: moved)
        #expect(relinked.libraryPath == moved.standardizedFileURL.path && !relinked.offline)
        #expect(await library.checkOffline(assets: [relinked]).isEmpty)
        await #expect(throws: MediaError.self) { try await library.relink(Fixtures.asset(), to: moved) }

        // Probe a video file and run an import as a job.
        let video = try await TestMedia.videoWithAudio(duration: 1, in: dir.url, name: "av")
        let probe = try await library.probe(url: video.url)
        #expect(probe.width == 1280 && probe.height == 720 && probe.codec == "avc1")
        let runner: any JobRunner = FakeJobRunner()
        let outcome = try await runner.submit(library.importJob(url: video.url, mode: .reference)).wait()
        let imported = try #require(try outcome.payload(as: ImportResult.self))
        #expect(imported.asset.kind == .video && imported.asset.hasAudio)
        #expect(imported.asset.frameDuration == RationalTime(1, 30))
        #expect(imported.libraryURL == video.url)
        #expect(await fake.imports.count == 3)
        await #expect(throws: MediaError.self) { try await library.importAsset(url: dir.file("nope.mov"), mode: .copy) }
    }

    @Test func thumbnailAndWaveformProviders() async throws {
        let thumbnails: any ThumbnailProvider = FakeThumbnailProvider()
        let media = MediaReference(asset: Fixtures.asset(), layout: .default)
        let strip = try await thumbnails.filmstrip(
            for: media, range: .zero...Fixtures.frames(240), count: 5, height: 36)
        #expect(strip.count == 5)
        #expect(strip.map(\.time) == [0, 60, 120, 180, 240].map(Fixtures.frames))
        #expect(strip.allSatisfy { $0.image.height == 36 && $0.image.width == 64 })
        #expect(
            try await thumbnails.thumbnail(for: media, at: Fixtures.frames(10), height: 20)?.time == Fixtures.frames(10)
        )

        let waveforms: any WaveformProvider = FakeWaveformProvider()
        let peaks = try await waveforms.peaks(
            for: media, range: RationalTime(1, 1)...RationalTime(2, 1), samplesPerPixel: 480)
        #expect(peaks.sampleRate == 48000 && peaks.hop == 480 && peaks.startSample == 48000)
        #expect(peaks.count == 101)
        #expect(zip(peaks.min, peaks.max).allSatisfy { $0 <= 0 && $1 >= 0 && $0 == -$1 })
    }

    @Test func analyzerReturnsFixturesAndCancels() async throws {
        let fake = FakeAnalyzer()
        let analyzer: any MediaAnalyzer = fake
        let media = MediaReference(url: URL(fileURLWithPath: "/tmp/a.mov"), contentHash: "sha256-feed")
        let transcript = try await analyzer.transcribe(
            media, locale: Locale(identifier: "en_US"), options: TranscriptionOptions())
        #expect(transcript.words.count == 7 && transcript.cacheKey.hasPrefix("sha256-feed/transcript/"))
        #expect(transcript.text.hasPrefix("Welcome to the"))
        #expect(try await analyzer.detectSilence(media, parameters: SilenceParameters()).ranges.count == 2)
        #expect(try await analyzer.detectShots(media, parameters: ShotParameters()).shots.count == 3)
        #expect(try await analyzer.waveformPeaks(media, samplesPerPixel: 4800).count == 101)
        let envelope = try await analyzer.onsetEnvelope(media, parameters: AlignmentParameters())
        #expect(envelope.sampleRate == 8000 && envelope.hop == 128 && envelope.samples?.count == 625)
        #expect(fake.calls.count == 5)

        fake.setTranscript(Transcript(words: [], language: "de", engine: "custom", cacheKey: "k"))
        #expect(
            try await analyzer.transcribe(media, locale: Locale(identifier: "de_DE"), options: TranscriptionOptions())
                .engine == "custom")

        let slow: any MediaAnalyzer = FakeAnalyzer(delay: .seconds(10))
        let task = Task { try await slow.detectShots(media, parameters: ShotParameters()) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func audioAligner() async throws {
        let fake = FakeAudioAligner()
        let aligner: any AudioAligner = fake
        let camera = AudioSource.file(URL(fileURLWithPath: "/tmp/cam.mov"), contentHash: "sha256-cam")
        let render = AudioSource.envelope(
            URL(fileURLWithPath: "/tmp/onset.f32"), audioURL: URL(fileURLWithPath: "/tmp/mix.wav"),
            contentHash: "sha256-mix")
        let alignment = try await aligner.align(reference: camera, target: render, parameters: AlignmentParameters())
        #expect(alignment.status == .aligned && alignment.offset == RationalTime(352_560, 48000))
        #expect(alignment.referenceHash == "sha256-cam" && alignment.targetHash == "sha256-mix")
        #expect(fake.calls.count == 1 && fake.calls[0].reference == camera)
        fake.setResult(.failedFixture)
        #expect(
            try await aligner.align(reference: camera, target: render, parameters: AlignmentParameters()).offset == nil)
    }

    @Test func agentRuntimeReplaysAScriptWithAnApprovalRoundTrip() async throws {
        let request = Fixtures.approvalRequest()
        let script: [AgentEvent] = [
            .turnStarted(index: 1),
            .toolCall(id: "c1", name: "render_export", input: ["preset": "reel9x16"]),
            .approvalRequested(request),
            .toolResult(id: "c1", output: ["status": "done"], isError: false),
            .finished(result: "Exported.", cost: CostReport(usd: 0.02)),
        ]
        let fake = FakeAgentRuntime(script: script)
        let runtime: any AgentRuntime = fake
        #expect(await runtime.availability().isUsable)
        let session = try await runtime.startSession(
            goal: "export a reel", tools: Fixtures.toolAccess, policy: Fixtures.runtimePolicy)
        var seen: [AgentEvent] = []
        for await event in session.events {
            seen.append(event)
            if case .approvalRequested(let r) = event { await session.approve(r, verdict: .approve) }
        }
        #expect(seen == script)
        let fakeSession = try #require(fake.sessions.first?.session)
        #expect(fakeSession.verdicts.map(\.verdict) == [.approve])
        #expect(fake.sessions.first?.goal == "export a reel")

        fake.setAvailability(RuntimeAvailability(installed: false, loggedIn: false, detail: "claude not found"))
        await #expect(throws: AgentFailure.self) {
            try await runtime.startSession(goal: "x", tools: Fixtures.toolAccess, policy: Fixtures.runtimePolicy)
        }
    }

    @Test func agentSessionMultiTurnAndCancel() async throws {
        let runtime = FakeAgentRuntime(
            script: [.assistantText("one")], followUps: [[.assistantText("two")], [.assistantText("three")]])
        let session = try await runtime.startSession(goal: "g", tools: Fixtures.toolAccess, policy: RuntimePolicy())
        var iterator = session.events.makeAsyncIterator()
        #expect(await iterator.next() == .assistantText("one"))
        try await session.send("more")
        #expect(await iterator.next() == .assistantText("two"))
        await session.cancel()
        var rest: [AgentEvent] = []
        while let e = await iterator.next() { rest.append(e) }
        #expect(rest.last == .failed(.cancelled))
        await #expect(throws: AgentFailure.self) { try await session.send("after cancel") }
    }

    @Test func toolRegistryCallsThroughTheContext() async throws {
        let services = try await TestServices.make()
        let registry: any ToolRegistry = services.registry
        await registry.register(
            Tool(
                name: "timeline_apply", description: "Apply a command",
                inputSchema: ["type": "object", "properties": ["op": ["type": "object"]]],
                annotations: ToolAnnotations(idempotent: true)
            ) { input, context in
                let store = try await context.store(for: input)
                let op = try #require(input["op"]).decoded(as: Command.Operation.self)
                let result = try await store.apply(
                    Command(commandId: CommandID("cmd-\(input.argsHash)"), actor: context.actor, operation: op))
                return try ToolOutput(encoding: result, text: "Applied \(result.version)")
            })
        await registry.register(
            Tool(name: "render_export", description: "Export", inputSchema: ["type": "object"]) { input, context in
                switch await context.checkApproval(tool: "render_export", input: input, estimate: Estimate(seconds: 42))
                {
                case .granted: return .text("exported")
                case .required(let request): return .approvalRequired(request)
                }
            })
        #expect(await registry.list().map(\.name) == ["timeline_apply", "render_export"])
        #expect(await registry.tool(named: "nope") == nil)

        let context = services.toolContext()
        let clip = try #require(Fixtures.firstVideoClip(in: await services.store.state()))
        let op = try JSONValue(
            encoding: Command.Operation.setClipOpacity(.init(clipId: .id(clip.id), after: .constant(0.5))))
        let output = try await registry.call("timeline_apply", input: ToolInput(["op": op]), context: context)
        #expect(!output.isError)
        #expect(output.structured?["status"] == "applied")
        #expect(await services.store.version() == output.structured?["version"]?.intValue.map(Int64.init))
        #expect(await services.store.receivedCommands.last?.actor == .agent(sessionId: "session-1"))

        let invalid = try JSONValue(encoding: Command.Operation.removeClip(.init(clipId: "missing")))
        let rejected = try await registry.call("timeline_apply", input: ToolInput(["op": invalid]), context: context)
        #expect(rejected.isError && rejected.structured?["error"] == "notFound")

        let export = try await registry.call("render_export", input: ToolInput(["preset": "proRes"]), context: context)
        #expect(export.isApprovalRequired)
        let token = try #require(export.structured?["approvalToken"]?.stringValue)
        await services.approvals.grant(ApprovalToken(token))
        let retried = try await registry.call(
            "render_export", input: ToolInput(["preset": "proRes", "approvalToken": .string(token)]), context: context)
        #expect(retried.text == "exported")

        await #expect(throws: ToolError.unknownTool("nope")) {
            try await registry.call("nope", input: ToolInput(), context: context)
        }
        let receipts = await services.receipts.receipts
        #expect(receipts.map(\.outcome) == [.applied, .error, .approvalRequired, .applied])
        let finalVersion = await services.store.version()
        #expect(receipts[0].toolName == "timeline_apply" && receipts[0].version == finalVersion)
        #expect(receipts[0].sessionId == "session-1")
    }

    @Test func toolContextResolvesProjects() async throws {
        let services = try await TestServices.make(fixture: "empty")
        let context = services.toolContext(actor: .human, sessionId: nil)
        let frontmost = try await context.store(for: ToolInput())
        #expect(await frontmost.projectId == services.store.projectId)
        let byId = try await context.store(for: ToolInput(["projectId": .string(services.store.projectId.rawValue)]))
        #expect(await byId.projectId == services.store.projectId)
        await #expect(throws: ToolError.projectNotFound("missing")) {
            try await context.store(for: ToolInput(["projectId": "missing"]))
        }
        #expect(
            context.services.renderer != nil && context.services.aligner != nil && context.services.jobRunner != nil)
        let empty = ToolContext(
            projects: FakeProjectDirectory(), services: ToolServices(), approvals: FakeApprovalGate(), actor: .system)
        await #expect(throws: ToolError.noProject) { try await empty.store(for: ToolInput()) }
    }

    @Test func broadcasterFansOutAndFinishes() async {
        let broadcaster = Broadcaster<Int>()
        let a = broadcaster.subscribe()
        let b = broadcaster.subscribe()
        broadcaster.send(1)
        broadcaster.send(2)
        broadcaster.finish()
        var seenA: [Int] = []
        for await x in a { seenA.append(x) }
        var seenB: [Int] = []
        for await x in b { seenB.append(x) }
        #expect(seenA == [1, 2] && seenB == [1, 2])
        var late = broadcaster.subscribe().makeAsyncIterator()
        #expect(await late.next() == nil)
        #expect(StableHash.fnv1a("abc") == StableHash.fnv1a(Data("abc".utf8)))
        #expect(StableHash.fnv1a("abc") != StableHash.fnv1a("abd"))
    }
}
