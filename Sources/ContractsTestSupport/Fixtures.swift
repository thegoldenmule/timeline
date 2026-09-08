import Contracts
import Foundation
import TimelineCore

/// TimelineCore's fixtures and a few Contracts values in one place, so a module test reads like
/// `Fixtures.store("three-clips")`.
public enum Fixtures {
    public static let frameDuration = RationalTime(1001, 24000)

    /// `n` frames at 23.976.
    public static func frames(_ n: Int64) -> RationalTime { RationalTime.frames(n, of: frameDuration) }

    public static let names = ProjectFixtures.names

    /// The builder for a named fixture: `empty`, `three-clips`, `linked-transition-caption-undone`.
    public static func builder(_ name: String = "three-clips") throws(EditorError) -> ProjectBuilder {
        try ProjectFixtures.builder(for: name)
    }

    public static func project(_ name: String = "three-clips") throws(EditorError) -> Project {
        try builder(name).project
    }

    /// An in-memory store loaded with a named fixture, continuing its ids and clock.
    public static func store(_ name: String = "three-clips") throws(EditorError) -> FakeProjectStore {
        FakeProjectStore(builder: try builder(name))
    }

    /// A random valid project from a seed.
    public static func generated(seed: UInt64) throws(EditorError) -> ProjectBuilder {
        try ProjectGenerator(seed: seed).builder()
    }

    private static let commandIds = UUIDv7Generator()

    /// A command envelope with a fresh UUIDv7 id.
    public static func command(
        _ operation: Command.Operation, actor: Actor = .human, expectedVersion: Int64? = nil, label: String? = nil
    ) -> Command {
        Command(
            commandId: CommandID(minting: commandIds), actor: actor, expectedVersion: expectedVersion, label: label,
            operation: operation)
    }

    /// The first video clip on the first video track of the active sequence, sorted by start.
    public static func firstVideoClip(in project: Project) -> Clip? {
        guard let sequence = project.activeSequence ?? project.sequences.values.first else { return nil }
        return sequence.tracks.first { $0.kind == .video }?.clips.values.min { $0.start < $1.start }
    }

    /// An asset value with plausible probe data, for tests that need one without importing.
    public static func asset(
        id: AssetID = "asset-1", name: String = "IMG_1575.MOV", contentHash: String = "sha256-0123abcd",
        durationFrames: Int64 = 720, hasVideo: Bool = true, hasAudio: Bool = true
    ) -> Asset {
        Asset(
            id: id, contentHash: contentHash, libraryPath: "2026/2026-09-08/\(name)", displayName: name,
            kind: hasVideo ? .video : .audio, duration: frames(durationFrames), hasVideo: hasVideo, hasAudio: hasAudio,
            sampleRate: hasAudio ? 48000 : nil, frameDuration: hasVideo ? frameDuration : nil,
            probe: Probe(
                codec: hasVideo ? "hvc1" : "aac", width: hasVideo ? 1080 : nil, height: hasVideo ? 1920 : nil,
                fps: hasVideo ? Rational(24000, 1001) : nil, colorPrimaries: hasVideo ? "bt2020" : nil,
                transfer: hasVideo ? "arib-std-b67" : nil, rotation: hasVideo ? 90 : nil))
    }

    public static let alignment = Alignment.fixture
    public static var transcript: Transcript { AnalysisFixtures.transcript() }
    public static var silence: SilenceRanges { AnalysisFixtures.silence() }
    public static var shots: ShotList { AnalysisFixtures.shots() }
    public static var onsetEnvelope: OnsetEnvelope { AnalysisFixtures.onsetEnvelope() }

    public static let toolAccess = ToolAccess(
        serverName: "timeline", endpoint: URL(string: "http://127.0.0.1:8811/mcp")!, bearerToken: "fake-token",
        toolNames: nil)

    public static let runtimePolicy = RuntimePolicy(model: "fake-model", maxBudgetUSD: 1, maxTurns: 6)

    public static func approvalRequest(tool: String = "render_export", token: ApprovalToken = "tok-1")
        -> ApprovalRequest
    {
        ApprovalRequest(
            id: "approval-1", token: token, tool: tool, inputSummary: "\(tool)(preset=reel9x16)",
            estimate: Estimate(seconds: 42, bytes: 80 << 20), requestedAt: Date(timeIntervalSince1970: 1_788_825_600),
            actor: .agent(sessionId: "session-1"), sessionId: "session-1")
    }
}

/// Every fake wired together, and a `ToolContext` over them. This is what a module test and the walking
/// skeleton start from.
public struct TestServices: Sendable {
    public var store: FakeProjectStore
    public var projects: FakeProjectDirectory
    public var renderer: FakeRenderer
    public var jobRunner: FakeJobRunner
    public var mediaLibrary: FakeMediaLibrary
    public var thumbnails: FakeThumbnailProvider
    public var waveforms: FakeWaveformProvider
    public var analyzer: FakeAnalyzer
    public var aligner: FakeAudioAligner
    public var agentRuntime: FakeAgentRuntime
    public var registry: InMemoryToolRegistry
    public var approvals: FakeApprovalGate
    public var receipts: FakeToolReceiptSink

    /// Builds every fake around the named fixture project.
    public static func make(fixture: String = "three-clips", approvalPolicy: ApprovalPolicy = .standard) async throws
        -> TestServices
    {
        let store = try Fixtures.store(fixture)
        let projects = FakeProjectDirectory()
        await projects.add(store, frontmost: true)
        return TestServices(
            store: store, projects: projects, renderer: FakeRenderer(), jobRunner: FakeJobRunner(),
            mediaLibrary: try FakeMediaLibrary(), thumbnails: FakeThumbnailProvider(),
            waveforms: FakeWaveformProvider(),
            analyzer: FakeAnalyzer(), aligner: FakeAudioAligner(), agentRuntime: FakeAgentRuntime(),
            registry: InMemoryToolRegistry(), approvals: FakeApprovalGate(policy: approvalPolicy),
            receipts: FakeToolReceiptSink())
    }

    public var services: ToolServices {
        ToolServices(
            renderer: renderer, mediaLibrary: mediaLibrary, analyzer: analyzer, aligner: aligner, jobRunner: jobRunner,
            thumbnails: thumbnails, waveforms: waveforms, receipts: receipts)
    }

    public func toolContext(actor: Actor = .agent(sessionId: "session-1"), sessionId: String? = "session-1")
        -> ToolContext
    {
        ToolContext(projects: projects, services: services, approvals: approvals, actor: actor, sessionId: sessionId)
    }
}
