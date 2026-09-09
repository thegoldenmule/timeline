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

    /// `render_export` requests carry the gate's generic summary; a `publish_youtube` request carries a
    /// presentation (Channel, Privacy, Certification rows) and uses its summary.
    public static func approvalRequest(tool: String = "render_export", token: ApprovalToken = "tok-1")
        -> ApprovalRequest
    {
        let presentation = tool == "publish_youtube" ? publishPresentation : nil
        return ApprovalRequest(
            id: "approval-1", token: token, tool: tool,
            inputSummary: presentation?.summary ?? "\(tool)(preset=reel9x16)",
            estimate: Estimate(seconds: 42, bytes: 80 << 20), requestedAt: Date(timeIntervalSince1970: 1_788_825_600),
            actor: .agent(sessionId: "session-1"), sessionId: "session-1", presentation: presentation)
    }

    // MARK: Publishing

    /// The scope set of publish-plan.md D2.
    public static let publishScopes = ["openid", "email", "https://www.googleapis.com/auth/youtube.force-ssl"]

    /// The sentence YouTube's API Terms 9.1 require next to the upload click.
    public static let certificationSentence =
        "By clicking Upload you certify that the content you are uploading complies with the YouTube Terms of Service"

    public static let fixtureDate = Date(timeIntervalSince1970: 1_788_825_600)

    /// `sub-1`, `me@example.com`, channel `UC-fake` "Skeleton Channel" `@skeleton`, a valid token.
    public static let connectedGoogleAccount = ConnectedAccount(
        id: "sub-1", provider: .google, email: "me@example.com", displayName: "Me", channelId: "UC-fake",
        channelTitle: "Skeleton Channel", channelHandle: "@skeleton",
        avatarURL: URL(string: "https://yt3.ggpht.com/fake/sub-1"), scopes: publishScopes, connectedAt: fixtureDate,
        refreshedAt: fixtureDate, tokenStatus: .valid(expiresAt: fixtureDate.addingTimeInterval(3600)))

    /// Two SRT cues matching the `linked-transition-caption-undone` fixture's caption clips.
    public static let captionCues = [
        CaptionCue(start: frames(12), end: frames(48), text: "Hello there"),
        CaptionCue(start: frames(60), end: frames(108), text: "and welcome"),
    ]

    /// "Band rehearsal", private, category 22, one English SRT caption track with two cues, no thumbnail.
    public static func publishRequest(
        renderId: String = "render-1", fileURL: URL = URL(fileURLWithPath: "/tmp/exports/band-rehearsal.mp4"),
        accountId: String = connectedGoogleAccount.id
    ) -> PublishRequest {
        PublishRequest(
            destination: .youtube, accountId: accountId, renderId: renderId, fileURL: fileURL,
            expectedContentHash: nil, projectVersion: 18, title: "Band rehearsal",
            description: "Recorded 2026-09-08.", tags: ["live", "rehearsal"], categoryId: "22", language: "en",
            privacy: .private,
            captions: [
                PublishCaptionTrack(
                    trackId: "track-c1", language: "en", name: "English", format: .srt, cues: captionCues)
            ], durationSeconds: 12.5, width: 1920, height: 1080)
    }

    public static func publishReceipt(publishId: String = "publish-1", remoteId: String = "fake-video-1")
        -> PublishReceipt
    {
        PublishReceipt(
            publishId: publishId, destination: .youtube, accountId: connectedGoogleAccount.id,
            channelId: connectedGoogleAccount.channelId, channelTitle: connectedGoogleAccount.channelTitle,
            renderId: "render-1", contentHash: "sha256-\(String(repeating: "ab", count: 32))", projectVersion: 18,
            remoteId: remoteId, remoteURL: URL(string: "https://youtu.be/\(remoteId)")!,
            studioURL: URL(string: "https://studio.youtube.com/video/\(remoteId)/edit"), requestedPrivacy: .private,
            privacy: .private, containsSyntheticMedia: false, bytesUploaded: 5 << 20, resumedCount: 1,
            thumbnailSet: false, captionIds: ["fake-caption-1"], processingStatus: "processed",
            startedAt: fixtureDate, finishedAt: fixtureDate.addingTimeInterval(9), warnings: [])
    }

    /// The card content of a `publish_youtube` approval.
    public static let publishPresentation = ApprovalPresentation(
        summary: "Publish \"Band rehearsal\" to YouTube as Private",
        details: [
            ApprovalDetail("Channel", "Skeleton Channel (@skeleton)"),
            ApprovalDetail("Privacy", "private"),
            ApprovalDetail("Certification", certificationSentence),
        ])
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
    /// Configured, with `Fixtures.connectedGoogleAccount` already connected.
    public var accounts: FakeAccountProvider
    public var publisher: FakePublisher
    public var authorizationPresenter: FakeAuthorizationPresenter

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
            receipts: FakeToolReceiptSink(), accounts: FakeAccountProvider(accounts: [Fixtures.connectedGoogleAccount]),
            publisher: FakePublisher(), authorizationPresenter: FakeAuthorizationPresenter())
    }

    public var services: ToolServices {
        ToolServices(
            renderer: renderer, mediaLibrary: mediaLibrary, analyzer: analyzer, aligner: aligner, jobRunner: jobRunner,
            thumbnails: thumbnails, waveforms: waveforms, receipts: receipts, accounts: [.google: accounts],
            publishers: [.youtube: publisher])
    }

    public func toolContext(actor: Actor = .agent(sessionId: "session-1"), sessionId: String? = "session-1")
        -> ToolContext
    {
        ToolContext(projects: projects, services: services, approvals: approvals, actor: actor, sessionId: sessionId)
    }
}
