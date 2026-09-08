import Contracts
import ContractsTestSupport
import Foundation
import TimelineCore

/// The composition root. Every service is held as an `any` existential so that Phase 2 swaps one fake
/// for the real module by changing a single line in `AppServices.fakes()`; nothing else in the app
/// names a concrete type. See docs/design/walking-skeleton.md for the swap table.
struct AppServices: Sendable {
    /// The in-memory key the fixture project is registered under; a `.tlproj` URL in Phase 2.
    static let fixtureURL = URL(fileURLWithPath: "/fixtures/three-clips.tlproj")

    let opener: any ProjectStoreOpening
    let renderer: any Renderer
    let jobRunner: any JobRunner
    let mediaLibrary: any MediaLibrary
    let thumbnails: any ThumbnailProvider
    let waveforms: any WaveformProvider
    let analyzer: any MediaAnalyzer
    let aligner: any AudioAligner
    let approvals: any ApprovalGate
    let registry: any ToolRegistry
    let agentRuntime: any AgentRuntime
    let receipts: any ToolReceiptSink
    /// The open projects, what tools resolve `projectId` against. App-owned in every phase.
    let projects: OpenProjects

    /// Every service from the fakes in `ContractsTestSupport`. Phase 2 swap points are marked.
    static func fakes() async throws -> AppServices {
        let opener = FakeProjectStoreOpener()  // Phase 2: ProjectStore's SQLite opener
        await opener.register(try Fixtures.store("three-clips"), at: fixtureURL)
        let approvals = FakeApprovalGate(policy: .standard)  // Phase 2: AgentKit's gate
        let registry = InMemoryToolRegistry()  // Phase 2: AgentKit's registry with the real tool set
        for tool in DemoTools.all { await registry.register(tool) }
        return AppServices(
            opener: opener,
            renderer: FakeRenderer(),  // Phase 2: RenderKit
            jobRunner: FakeJobRunner(),  // Phase 2: the budgeted runner
            mediaLibrary: try FakeMediaLibrary(),  // Phase 2: MediaKit
            thumbnails: FakeThumbnailProvider(),  // Phase 2: MediaKit
            waveforms: FakeWaveformProvider(),  // Phase 2: MediaKit
            analyzer: FakeAnalyzer(),  // Phase 2: MediaKit
            aligner: FakeAudioAligner(),  // Phase 2: AudioAlign
            approvals: approvals,
            registry: registry,
            agentRuntime: FakeAgentRuntime(script: DemoAgentScript.events),  // Phase 2: AgentKit's sidecar
            receipts: FakeToolReceiptSink(),  // Phase 2: ProjectStore's `commands` metadata
            projects: OpenProjects())
    }

    /// The services a tool handler may reach. Everything is wired, so no tool answers `serviceUnavailable`.
    var toolServices: ToolServices {
        ToolServices(
            renderer: renderer, mediaLibrary: mediaLibrary, analyzer: analyzer, aligner: aligner, jobRunner: jobRunner,
            thumbnails: thumbnails, waveforms: waveforms, receipts: receipts)
    }

    func toolContext(actor: Actor, sessionId: String? = nil) -> ToolContext {
        ToolContext(
            projects: projects, services: toolServices, approvals: approvals, actor: actor, sessionId: sessionId)
    }

    /// The registry call every UI surface and the agent bridge go through.
    func callTool(_ name: String, input: ToolInput, actor: Actor, sessionId: String? = nil) async throws -> ToolOutput {
        try await registry.call(name, input: input, context: toolContext(actor: actor, sessionId: sessionId))
    }
}

/// The document-based app's open projects: the `ProjectDirectory` tools resolve against. The first
/// project opened is frontmost until `setFrontmost` says otherwise.
actor OpenProjects: ProjectDirectory {
    private var entries: [(id: ProjectID, store: any ProjectStore, url: URL?)] = []
    private var frontmostId: ProjectID?

    func add(_ store: any ProjectStore, url: URL?) async {
        let id = await store.projectId
        entries.removeAll { $0.id == id }
        entries.append((id, store, url))
        if frontmostId == nil { frontmostId = id }
    }

    func setFrontmost(_ id: ProjectID) { frontmostId = id }

    func open() async -> [ProjectSummary] {
        var result: [ProjectSummary] = []
        for e in entries {
            result.append(ProjectSummary(await e.store.state(), url: e.url, isFrontmost: e.id == frontmostId))
        }
        return result
    }

    func frontmost() async -> ProjectSummary? {
        guard let id = frontmostId, let e = entries.first(where: { $0.id == id }) else { return nil }
        return ProjectSummary(await e.store.state(), url: e.url, isFrontmost: true)
    }

    func store(for id: ProjectID) -> (any ProjectStore)? { entries.first { $0.id == id }?.store }
}
