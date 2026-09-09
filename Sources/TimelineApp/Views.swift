import AVKit
import AppKit
import Contracts
import Foundation
import Observation
import RenderKit
import SwiftUI
import TimelineCore
import TimelineUI
import UniformTypeIdentifiers

/// Boots the composition root and opens the default project; the consoles and centres hang off the services.
@MainActor @Observable
final class AppModel {
    private(set) var services: AppServices?
    private(set) var document: ProjectDocument?
    private(set) var approvals: ApprovalCenter?
    private(set) var jobs = JobCenter()
    private(set) var tools: ToolConsole?
    private(set) var agent: AgentConsole?
    private(set) var publish: PublishConsole?
    private(set) var bootError: String?
    private(set) var bootStage = "Starting services"
    var lastCommandError: String?

    func boot() async {
        guard services == nil else { return }
        do {
            let services = try await AppServices.boot()
            self.services = services
            let approvals = ApprovalCenter(gate: services.approvals)
            await approvals.start()
            self.approvals = approvals
            let tools = ToolConsole(services: services)
            self.tools = tools
            agent = AgentConsole(services: services, approvals: approvals)
            let publish = PublishConsole(services: services, tools: tools, jobs: jobs)
            await publish.start()
            self.publish = publish
            bootStage = "Opening project"
            try await open(AppServices.defaultProjectURL(in: services.layout), create: true)
        } catch {
            bootError = "\(error)"
        }
    }

    /// Opens (or creates) the package at `url`, closing the current document first.
    func open(_ url: URL, create: Bool) async throws {
        guard let services else { return }
        if let document {
            await document.close(using: services)
            self.document = nil
            await publish?.attach(nil)
        }
        let name = url.deletingPathExtension().lastPathComponent
        let document =
            create
            ? try await ProjectDocument.openOrCreate(at: url, name: name, using: services)
            : try await ProjectDocument.open(at: url, using: services)
        self.document = document
        await publish?.attach(document)
    }

    /// Runs an async action from a button, surfacing its error in the window. The publish console
    /// re-reads the ledgers afterwards, so an export enables the Publish button.
    func perform(_ body: @MainActor @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await body()
                lastCommandError = nil
            } catch {
                lastCommandError = "\(error)"
            }
            await publish?.refresh()
        }
    }

    // MARK: Actions

    /// Imports each file through the library as a job, records the asset, and appends it to the timeline.
    func importFiles(_ urls: [URL]) {
        guard let services, let document else { return }
        for url in urls {
            perform {
                let handle = await self.jobs.submit(
                    services.mediaLibrary.importJob(url: url, mode: .copy), to: services.jobRunner)
                let outcome = try await handle.wait()
                guard let result = try outcome.payload(as: ImportResult.self) else { return }
                var asset = result.asset
                if let existing = document.project.assets.values.first(where: { $0.contentHash == asset.contentHash }) {
                    asset = existing
                } else {
                    let applied = try await document.apply(
                        .importAsset(result.operation), label: "Import \(asset.displayName)")
                    try await document.waitForVersion(applied.version)
                }
                let added = try await document.appendClip(for: asset)
                try await document.waitForVersion(added.version)
            }
        }
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio, .image, .mpeg4Movie, .quickTimeMovie, .wav, .aiff, .mp3]
        panel.message = "Import media into the library"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func presentOpenPanel() {
        guard let services else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = services.layout.projectsDir
        panel.message = "Choose a .tlproj package"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try await self.open(url, create: false) }
    }

    func presentNewPanel() {
        guard let services else { return }
        let panel = NSSavePanel()
        panel.directoryURL = services.layout.projectsDir
        panel.nameFieldStringValue = "Untitled.tlproj"
        panel.message = "Create a project package"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != "tlproj" { url = url.appendingPathExtension("tlproj") }
        perform { try await self.open(url, create: true) }
    }

    /// Copies the current project's whole stream into a new package and switches the window to it.
    func presentForkPanel() {
        guard let services, let document else { return }
        let panel = NSSavePanel()
        panel.directoryURL = services.layout.projectsDir
        panel.nameFieldStringValue = "\(document.project.name) fork.tlproj"
        panel.message = "Fork this project into a new package"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != "tlproj" { url = url.appendingPathExtension("tlproj") }
        let name = url.deletingPathExtension().lastPathComponent
        perform {
            self.document = nil
            let forked = try await document.fork(to: url, name: name, using: services)
            self.document = forked
            await self.publish?.attach(forked)
        }
    }

    /// The Publish sheet over the newest done render; the sheet's Upload goes through `publish_youtube`.
    func presentPublishSheet() {
        publish?.presentSheet()
    }

    /// Runs silence, onset-envelope, and (for video) shot detection on the selected clip's asset.
    func analyzeSelection() {
        guard let document, let tools, let asset = selectedAssets(document).first else { return }
        var kinds: [JSONValue] = ["silence", "onsetEnvelope"]
        if asset.hasVideo { kinds.append("shots") }
        perform {
            _ = try await tools.call(
                "media_analyze", input: ToolInput(["assetId": .string(asset.id.rawValue), "kinds": .array(kinds)]))
        }
    }

    /// Aligns the second selected clip's audio inside the first's and moves it into place.
    func alignSelection() {
        guard let document, let tools, let sequence = document.sequence else { return }
        let clips = document.viewModel.selectedClips
        guard clips.count == 2, let referenceId = clips[0].assetId, let targetId = clips[1].assetId else {
            lastCommandError = "Select two clips: the reference first, then the clip to align"
            return
        }
        perform {
            let output = try await tools.call(
                "align_audio",
                input: ToolInput([
                    "referenceAssetId": .string(referenceId.rawValue), "targetAssetId": .string(targetId.rawValue),
                ]))
            guard output.structured?["status"]?.stringValue == "aligned",
                let offset = try output.structured?["offset"]?.decoded(as: RationalTime.self)
            else { return }
            let reference = clips[0]
            let target = clips[1]
            let start = reference.start - reference.sourceIn + offset + target.sourceIn
            _ = try await document.apply(
                .moveClip(
                    .init(
                        clipId: .id(target.id), to: .init(start: start.floored(to: sequence.frameDuration)),
                        mode: .overwrite)), label: "Align clip")
        }
    }

    func exportReel() {
        guard let tools else { return }
        perform { _ = try await tools.call("render_export", input: ToolInput(["preset": "reel9x16"])) }
    }

    func startAgent(goal: String) {
        guard let agent else { return }
        perform { try await agent.start(goal: goal) }
    }

    private func selectedAssets(_ document: ProjectDocument) -> [Asset] {
        document.viewModel.selectedClips.compactMap { clip in clip.assetId.flatMap { document.project.assets[$0] } }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let services = model.services, let document = model.document, let approvals = model.approvals,
                let tools = model.tools, let agent = model.agent, let publish = model.publish
            {
                EditorView(
                    model: model, services: services, document: document, approvals: approvals, jobs: model.jobs,
                    tools: tools, agent: agent, publish: publish)
            } else if let error = model.bootError {
                ContentUnavailableView("Could not start", systemImage: "xmark.octagon", description: Text(error))
            } else {
                ProgressView(model.bootStage)
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .task { await model.boot() }
    }
}

struct EditorView: View {
    @Bindable var model: AppModel
    let services: AppServices
    let document: ProjectDocument
    let approvals: ApprovalCenter
    let jobs: JobCenter
    let tools: ToolConsole
    let agent: AgentConsole
    let publish: PublishConsole
    @State private var goal = "Describe the project, then export a vertical reel of the active sequence."

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PreviewLayerView(preview: document.preview)
                    .frame(minHeight: 240)
                Divider()
                TimelineView(viewModel: document.viewModel)
                    .frame(minHeight: 220)
                statusBar
            }
            .frame(minWidth: 640)
            sidebar
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 560)
        }
        .toolbar { toolbarContent }
        .navigationTitle("\(document.project.name) — v\(document.version)")
        .sheet(isPresented: publishSheetPresented) {
            if let sheet = publish.sheet {
                PublishSheetView(
                    model: sheet, onUpload: { draft in await publish.upload(draft) },
                    onCancel: { publish.dismissSheet() })
            }
        }
    }

    private var publishSheetPresented: Binding<Bool> {
        Binding(get: { publish.sheet != nil }, set: { if !$0 { publish.dismissSheet() } })
    }

    private var sidebar: some View {
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    InspectorView(viewModel: document.viewModel)
                        .frame(minHeight: 120)
                    Divider()
                    ApprovalStackView(center: approvals)
                        .padding(8)
                    Divider()
                    JobList(center: jobs)
                    Divider()
                    PublishSection(publish: publish)
                    Divider()
                    HistoryView(viewModel: document.viewModel)
                        .frame(height: 220)
                    Divider()
                    ToolSection(tools: tools)
                    Divider()
                    MCPSection(services: services)
                }
            }
            .frame(minHeight: 240)
            AgentSection(agent: agent, goal: $goal, model: model)
                .frame(minHeight: 200)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button("New", systemImage: "doc.badge.plus") { model.presentNewPanel() }
            Button("Open", systemImage: "folder") { model.presentOpenPanel() }
            Button("Fork", systemImage: "arrow.triangle.branch") { model.presentForkPanel() }
                .disabled(model.document == nil)
            Button("Import", systemImage: "square.and.arrow.down") { model.presentImportPanel() }
        }
        ToolbarItemGroup {
            Button("Split", systemImage: "scissors") {
                model.perform { _ = await document.viewModel.splitAtPlayhead() }
            }
            Button("Delete", systemImage: "trash") {
                model.perform { _ = await document.viewModel.deleteSelection() }
            }
            .disabled(document.viewModel.selection.isEmpty)
            Button("Undo", systemImage: "arrow.uturn.backward") {
                model.perform { _ = await document.viewModel.undo() }
            }
            .disabled(!document.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") {
                model.perform { _ = await document.viewModel.redo() }
            }
            .disabled(!document.canRedo)
        }
        ToolbarItemGroup {
            Button("Analyze", systemImage: "waveform.badge.magnifyingglass") { model.analyzeSelection() }
                .disabled(document.viewModel.selection.isEmpty || tools.isCalling)
            Button("Align", systemImage: "arrow.left.and.right.text.vertical") { model.alignSelection() }
                .disabled(document.viewModel.selection.count != 2 || tools.isCalling)
            Button("Export", systemImage: "square.and.arrow.up") { model.exportReel() }
                .disabled(tools.isCalling)
        }
        ToolbarItemGroup {
            // The share control is the one place YouTube is named (policy III.F.2); the icon is generic.
            Button("Publish", systemImage: "arrow.up.circle") { model.presentPublishSheet() }
                .disabled(!publish.canPublish || tools.isCalling)
                .help(publish.hint)
            SettingsLink {
                Label("Accounts", systemImage: "person.crop.circle")
            }
            .help("Connect a YouTube channel and see how to reach the app from Claude Code")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Button(document.isPlaying ? "Pause" : "Play", systemImage: document.isPlaying ? "pause.fill" : "play.fill")
            {
                document.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            Text(document.url.lastPathComponent)
            Text("Render: \(document.lastRenderPath.rawValue) #\(document.playerItemGeneration)")
            Text(String(format: "Playhead %.2fs", document.playheadSeconds))
            Text("Jobs: \(jobs.running.count) running")
            if let error = model.lastCommandError ?? document.lastError ?? document.viewModel.lastError.map({ "\($0)" })
            {
                Text(error).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

struct ToolSection: View {
    let tools: ToolConsole

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last tool").font(.headline)
            if tools.lastTool.isEmpty {
                Text("No tool called yet").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(tools.lastTool).bold()
                if let text = tools.lastOutput?.text { Text(text).font(.caption) }
                Text(tools.structuredText).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(30)
                if let error = tools.error { Text(error).foregroundStyle(.red) }
            }
        }
        .padding(8)
    }
}

/// The publish history of the open project (with Resume for interrupted uploads), the last
/// `publish_youtube` answer, and why the Publish button is disabled when it is.
struct PublishSection: View {
    let publish: PublishConsole

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let history = publish.history, publish.isAvailable {
                PublishHistoryView(model: history) { publishId in
                    Task { await publish.resume(publishId: publishId) }
                }
            } else {
                Text("Publishes").font(.headline).padding(.horizontal, 8)
            }
            if !publish.canPublish {
                Text(publish.hint).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            if publish.isPublishing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the approval card, then the upload runs as a job").font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }
            if let error = publish.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Settings: the Google account (connect, reconnect, disconnect, with the app's notices), how
/// publishing was configured, and how to reach the running app from Claude Code.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let services = model.services, let publish = model.publish {
                    Text("YouTube").font(.title3)
                    if let accounts = publish.accounts {
                        AccountView(model: accounts)
                    } else {
                        Text("Publishing is switched off (TIMELINE_PUBLISHING=off)").foregroundStyle(.secondary)
                    }
                    PublishingStateView(publishing: services.publishing)
                    Divider()
                    MCPSection(services: services)
                } else if let error = model.bootError {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView(model.bootStage)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
    }
}

/// Which publishing stack booted and where the tokens live; the forced-private notice until the audit.
struct PublishingStateView: View {
    let publishing: PublishingServices

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch publishing.state {
            case .configured(let clientId, let audited):
                Text("Google OAuth client \(clientId)").font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !audited {
                    Label(PublishCapabilities.unauditedNote, systemImage: "lock").font(.caption)
                        .foregroundStyle(.orange)
                }
            case .notConfigured(let hint):
                Text(hint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            case .fake:
                Label(
                    "Publishing runs against the in-process fake YouTube server (TIMELINE_PUBLISHING=fake)",
                    systemImage: "testtube.2"
                ).font(.caption).foregroundStyle(.orange)
            case .off:
                EmptyView()
            }
            if publishing.state != .off {
                Text("Refresh tokens: \(publishing.tokenStoreDescription)").font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// How to reach the running app from Claude Code, and which agent runtime the window got.
struct MCPSection: View {
    let services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MCP").font(.headline)
            Text("Connect Claude Code to this app:").font(.caption).foregroundStyle(.secondary)
            Text(services.mcp.claudeMCPAddCommand).font(.caption2.monospaced()).textSelection(.enabled)
            Text("Or through the stdio proxy (config at \(services.proxyConfigurationURL.path)):")
                .font(.caption).foregroundStyle(.secondary)
            Text(services.mcp.claudeMCPAddProxyCommand).font(.caption2.monospaced()).textSelection(.enabled)
            let a = services.agentAvailability
            Text(
                services.agentIsFallback
                    ? "Embedded agent: scripted fallback (\(a.detail ?? "claude not usable"))"
                    : "Embedded agent: Claude Code \(a.version ?? "") (\(a.detail ?? ""))"
            )
            .font(.caption).foregroundStyle(.secondary)
            Text("Library root: \(services.layout.root.path)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

struct AgentSection: View {
    let agent: AgentConsole
    @Binding var goal: String
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Goal", text: $goal).textFieldStyle(.roundedBorder)
                Button("Start agent", systemImage: "sparkles") { model.startAgent(goal: goal) }
                    .disabled(agent.isRunning || agent.isStarting)
            }
            .padding(8)
            if let transcript = agent.transcript {
                AgentPanelView(transcript: transcript)
            } else {
                Text(agent.error ?? "No session started").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

/// Hosts RenderKit's two `AVPlayerLayer`s (the preview hides the idle one), so a structural swap never
/// freezes the picture. AVKit is still linked for the day a control strip is wanted; the transport is
/// the status bar's Play button and the space bar.
struct PreviewLayerView: NSViewRepresentable {
    let preview: PreviewPlayer

    final class HostView: NSView {
        var playerLayers: [AVPlayerLayer] = []

        override func layout() {
            super.layout()
            for layer in playerLayers { layer.frame = bounds }
        }
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        for layer in preview.layers {
            layer.videoGravity = .resizeAspect
            layer.frame = view.bounds
            view.layer?.addSublayer(layer)
        }
        view.playerLayers = preview.layers
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.needsLayout = true
    }
}
