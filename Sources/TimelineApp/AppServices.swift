import AgentKit
import AudioAlign
import Contracts
import ContractsTestSupport
import Foundation
import MediaKit
import ProjectStore
import PublishKit
import RenderKit
import Synchronization
import TimelineCore

/// Lines the services and the MCP host log, kept for the window and printed to stderr.
final class AppLog: Sendable {
    private let lines = Mutex<[String]>([])
    let echo: Bool

    init(echo: Bool = true) { self.echo = echo }

    func log(_ line: String) {
        lines.withLock { $0.append(line) }
        if echo { FileHandle.standardError.write(Data("[timeline] \(line)\n".utf8)) }
    }

    var all: [String] { lines.withLock { $0 } }
}

/// The composition root. Every service is held as an `any` existential; `AppServices.boot` builds the
/// real modules over one `LibraryLayout` root (`~/Movies/Timeline`, or `TIMELINE_ROOT`). Nothing is a
/// fake any more except the agent runtime's scripted fallback when Claude Code is not usable.
struct AppServices: Sendable {
    /// Which agent runtime to build: probe Claude Code and fall back to the scripted loop, or the
    /// scripted loop directly (the headless check, which must not spawn `claude`).
    enum AgentMode: Sendable {
        case auto
        case fallback
    }

    let layout: LibraryLayout
    let opener: any ProjectStoreOpening
    /// RenderKit's renderer, what the tools reach through `ToolServices.renderer`.
    let renderer: any Renderer
    /// The same renderer, concretely, for `ProjectDocument`'s `PreviewPlayer` (the two-player swap).
    let previewRenderer: AVFoundationRenderer
    let jobRunner: any JobRunner
    let mediaLibrary: any MediaLibrary
    /// MediaKit's `cache.sqlite` index, shared by the library, the analyzer, and both providers.
    let cache: CacheIndex
    let thumbnails: any ThumbnailProvider
    let waveforms: any WaveformProvider
    let analyzer: any MediaAnalyzer
    let aligner: any AudioAligner
    let approvals: any ApprovalGate
    let registry: any ToolRegistry
    let agentRuntime: any AgentRuntime
    /// What `ClaudeCodeRuntime.availability()` said, or the fallback's own report.
    let agentAvailability: RuntimeAvailability
    /// True when `agentRuntime` is the scripted fallback rather than the Claude Code sidecar.
    let agentIsFallback: Bool
    let receipts: any ToolReceiptSink
    /// The Google account provider and the YouTube publisher (publish-plan.md 4.5), or how they are missing.
    let publishing: PublishingServices
    /// The open projects, what tools resolve `projectId` against. App-owned in every phase.
    let projects: OpenProjects
    let mcpHost: MCPServerHost
    let mcp: MCPConnectionInfo
    /// Where `{ url, token }` for the `timeline-mcp` stdio proxy was written.
    let proxyConfigurationURL: URL
    let log: AppLog

    /// `TIMELINE_ROOT` when set (tests and the headless check), else `~/Movies/Timeline`.
    static var configuredRoot: URL {
        if let root = ProcessInfo.processInfo.environment["TIMELINE_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        }
        return LibraryLayout.default.root
    }

    /// The project the window opens by default.
    static func defaultProjectURL(in layout: LibraryLayout) -> URL {
        layout.projectsDir.appendingPathComponent("Untitled.tlproj", isDirectory: true)
    }

    /// Builds every service, starts the MCP host, and writes the proxy configuration.
    static func boot(
        root: URL = configuredRoot, agent: AgentMode = .auto, publishing: PublishingMode = .fromEnvironment(),
        log: AppLog = AppLog()
    ) async throws -> AppServices {
        let layout = LibraryLayout(root: root)
        for dir in [layout.libraryDir, layout.cacheDir, layout.projectsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let cache = try CacheIndex(layout: layout)
        let library = try FileMediaLibrary(layout: layout, cache: cache)
        let analyzer = AppleMediaAnalyzer(cache: cache)
        let thumbnails = AVThumbnailProvider(cache: cache)
        let waveforms = PeaksWaveformProvider(store: analyzer.peaksStore)
        let aligner = OnsetAligner()
        let jobRunner = BudgetedJobRunner(budget: .conservative)
        let approvals = StandardApprovalGate(policy: .standard)
        let receipts = ReceiptLog(fileURL: layout.cacheDir.appendingPathComponent("receipts.jsonl"))
        let projects = OpenProjects()
        let renderer = AVFoundationRenderer(layout: layout)
        let opener = SQLiteProjectStoreOpener(libraryRootHint: layout.root.path)
        let publishingServices = try await PublishingServices.make(mode: publishing, layout: layout, log: log)

        let toolServices = AppServices.toolServices(
            renderer: renderer, mediaLibrary: library, analyzer: analyzer, aligner: aligner, jobRunner: jobRunner,
            thumbnails: thumbnails, waveforms: waveforms, receipts: receipts, publishing: publishingServices)
        let baseContext = ToolContext(projects: projects, services: toolServices, approvals: approvals, actor: .human)
        let registry = await EditorTools.standard(context: baseContext)

        let host = MCPServerHost(
            registry: registry, context: baseContext,
            configuration: MCPServerHost.Configuration(log: { log.log($0) }))
        let mcp = try await host.start()
        let proxyURL =
            ProcessInfo.processInfo.environment["TIMELINE_ROOT"] == nil
            ? MCPConnectionInfo.defaultProxyConfigurationURL : layout.root.appendingPathComponent("mcp.json")
        try mcp.writeProxyConfiguration(to: proxyURL)
        log.log("MCP: \(mcp.claudeMCPAddCommand)")

        let call: ToolLoopRuntime.Call = { name, input, sessionId in
            var context = baseContext
            context.actor = .agent(sessionId: sessionId)
            context.sessionId = sessionId
            return try await registry.call(name, input: input, context: context)
        }
        let exportPath = layout.root.appendingPathComponent("Exports/Reel 9x16.mp4").path
        let fallback = ToolLoopRuntime(
            base: FakeAgentRuntime(script: DemoAgentScript.events(exportPath: exportPath)), gate: approvals,
            call: call)
        let agentRuntime: any AgentRuntime
        let availability: RuntimeAvailability
        let isFallback: Bool
        switch agent {
        case .fallback:
            agentRuntime = fallback
            availability = RuntimeAvailability(installed: false, loggedIn: false, detail: "scripted fallback")
            isFallback = true
        case .auto:
            let claude = ClaudeCodeRuntime(
                configuration: ClaudeCodeRuntime.Configuration(
                    workingDirectoryRoot: layout.root.appendingPathComponent("Agent", isDirectory: true),
                    approvals: host.approvalGate, log: { log.log($0) }))
            let probed = await claude.availability()
            availability = probed
            if probed.isUsable {
                agentRuntime = claude
                isFallback = false
                log.log("Claude Code \(probed.version ?? "") available: \(probed.detail ?? "")")
            } else {
                agentRuntime = fallback
                isFallback = true
                log.log("Claude Code not usable (\(probed.detail ?? "unknown")); using the scripted fallback")
            }
        }

        return AppServices(
            layout: layout, opener: opener, renderer: renderer, previewRenderer: renderer, jobRunner: jobRunner,
            mediaLibrary: library,
            cache: cache, thumbnails: thumbnails, waveforms: waveforms, analyzer: analyzer, aligner: aligner,
            approvals: approvals, registry: registry, agentRuntime: agentRuntime, agentAvailability: availability,
            agentIsFallback: isFallback, receipts: receipts, publishing: publishingServices, projects: projects,
            mcpHost: host, mcp: mcp, proxyConfigurationURL: proxyURL, log: log)
    }

    /// The services a tool handler may reach. Everything is wired, so no tool answers `serviceUnavailable`;
    /// the publisher is absent without a Google OAuth client, which hides `publish_youtube`.
    var toolServices: ToolServices {
        AppServices.toolServices(
            renderer: renderer, mediaLibrary: mediaLibrary, analyzer: analyzer, aligner: aligner, jobRunner: jobRunner,
            thumbnails: thumbnails, waveforms: waveforms, receipts: receipts, publishing: publishing)
    }

    private static func toolServices(
        renderer: any Renderer, mediaLibrary: any MediaLibrary, analyzer: any MediaAnalyzer, aligner: any AudioAligner,
        jobRunner: any JobRunner, thumbnails: any ThumbnailProvider, waveforms: any WaveformProvider,
        receipts: any ToolReceiptSink, publishing: PublishingServices
    ) -> ToolServices {
        var accounts: [AccountProviderKind: any AccountProvider] = [:]
        if let provider = publishing.accounts { accounts[.google] = provider }
        var publishers: [PublishDestination: any Publisher] = [:]
        if let publisher = publishing.publisher { publishers[.youtube] = publisher }
        return ToolServices(
            renderer: renderer, mediaLibrary: mediaLibrary, analyzer: analyzer, aligner: aligner, jobRunner: jobRunner,
            thumbnails: thumbnails, waveforms: waveforms, receipts: receipts, accounts: accounts, publishers: publishers
        )
    }

    /// The Google provider, when publishing is not switched off.
    var accounts: (any AccountProvider)? { publishing.accounts }
    /// The YouTube publisher, when a client is configured (or the fake is in use).
    var publisher: (any Publisher)? { publishing.publisher }

    func toolContext(actor: Actor, sessionId: String? = nil) -> ToolContext {
        ToolContext(
            projects: projects, services: toolServices, approvals: approvals, actor: actor, sessionId: sessionId)
    }

    /// The registry call every UI surface goes through.
    func callTool(_ name: String, input: ToolInput, actor: Actor, sessionId: String? = nil) async throws -> ToolOutput {
        try await registry.call(name, input: input, context: toolContext(actor: actor, sessionId: sessionId))
    }

    /// The policy an embedded session runs under.
    var runtimePolicy: RuntimePolicy {
        RuntimePolicy(
            maxBudgetUSD: 2, maxTurns: 12,
            systemPromptAppend:
                "You are editing inside the Timeline app. Read the project with project_describe before changing it.",
            workingDirectory: layout.root.appendingPathComponent("Agent", isDirectory: true))
    }

    func shutdown() async {
        await mcpHost.stop()
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

    func remove(_ id: ProjectID) {
        entries.removeAll { $0.id == id }
        if frontmostId == id { frontmostId = entries.last?.id }
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

/// Waits for the human's answer to an `approval_required` result by polling the gate's token status,
/// so a card answered from any surface (the stack, an agent transcript) resumes the caller.
enum ApprovalWait {
    static func verdict(for token: ApprovalToken, on gate: any ApprovalGate, timeout: Duration = .seconds(600))
        async -> ApprovalVerdict
    {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            switch await gate.status(of: token) {
            case .pending:
                try? await Task.sleep(for: .milliseconds(50))
            case .granted, .consumed:
                return .approve
            case .denied(let reason):
                return .deny(reason: reason)
            case .unknown:
                return .deny(reason: "The gate does not know this token")
            }
        }
        return .deny(reason: Task.isCancelled ? "Cancelled" : "Timed out waiting for approval")
    }
}
