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
    private(set) var assistant: AssistantConsole?
    private(set) var publish: PublishConsole?
    /// The library panel's state over the open document and the machine-wide catalog.
    private(set) var library: MediaLibraryModel?
    private(set) var bootError: String?
    private(set) var bootStage = "Starting services"
    var lastCommandError: String?
    /// A one-line note in the status bar, for things that went right but are worth saying (an import
    /// that stopped at the library rather than the timeline).
    var lastStatusNote: String?

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
            assistant = AssistantConsole(services: services, approvals: approvals)
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
        // Remembered so a package the user keeps outside the projects directory stays browsable.
        await services.catalog.register(packageAt: url)
        await install(document)
    }

    /// Makes `document` the window's document and routes the timeline's two drops to the importer:
    /// files from Finder, and rows dragged out of the library panel.
    private func install(_ document: ProjectDocument) async {
        document.viewModel.onDropMedia = { [weak self] urls, target in self?.importFiles(urls, at: target) }
        document.viewModel.onDropLibraryItems = { [weak self] items, target in
            self?.insertLibraryItems(items, at: target)
        }
        self.document = document
        await publish?.attach(document)
        guard let services else { return }
        let library = MediaLibraryModel(
            viewModel: document.viewModel, catalog: services.catalog, layout: services.layout,
            thumbnails: services.thumbnails)
        self.library = library
        // A library drag reaches the assistant panel as a bare file URL; the library is what turns it back
        // into a row, so the chip keeps its poster and duration.
        assistant?.composer.resolve = { [weak library] url in library?.dragItem(forPath: url.path) }
        Task { @MainActor in await library.load() }
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

    /// Imports the media files through the library as jobs and records their assets. Nothing lands on
    /// the timeline: only a drop on the timeline itself asks for clips, through `importFiles(_:at:)`.
    /// Non-media files are skipped with a note in the status bar.
    func importFiles(_ urls: [URL]) {
        runImport(urls) { importer, media in
            let outcome = try await importer.importFiles(media)
            return "Imported \(outcome.assets.count) file\(outcome.assets.count == 1 ? "" : "s") into the library"
        }
    }

    /// The timeline drop: the same import, then the clips land back to back from `target`.
    func importFiles(_ urls: [URL], at target: TimelineDropTarget) {
        runImport(urls) { importer, media in
            try await importer.importFiles(media, at: target)
            return nil
        }
    }

    /// The window-wide drop (preview, sidebar, status bar): the files go into the library, nowhere else.
    /// The timeline has its own drop target and inserts there.
    func dropFiles(_ urls: [URL]) {
        importFiles(urls)
    }

    /// Reports the non-media files, runs `body` on an importer, and surfaces its note or its error.
    private func runImport(
        _ urls: [URL], _ body: @MainActor @escaping (MediaImporter, [URL]) async throws -> String?
    ) {
        guard let services, let document else { return }
        let ignored = urls.filter { !MediaFileTypes.isMedia($0) }
        lastCommandError =
            ignored.isEmpty
            ? nil
            : "Ignored \(ignored.count) non-media file\(ignored.count == 1 ? "" : "s"): "
                + ignored.map(\.lastPathComponent).joined(separator: ", ")
        guard ignored.count < urls.count else { return }
        lastStatusNote = nil
        let importer = MediaImporter(services: services, document: document, jobs: jobs)
        Task { @MainActor in
            do {
                lastStatusNote = try await body(importer, urls)
            } catch {
                lastCommandError = "\(error)"
            }
        }
    }

    /// A library row dropped on the timeline, double-clicked, or inserted from its context menu: the
    /// asset is duplicated into this project when it belongs to another one, then a clip lands at
    /// `target` (nil means the playhead).
    func insertLibraryItems(_ items: [LibraryDragItem], at target: TimelineDropTarget? = nil) {
        guard let services, let document else { return }
        let at = target ?? TimelineDropTarget(trackId: nil, at: document.viewModel.playhead)
        let importer = MediaImporter(services: services, document: document, jobs: jobs)
        lastStatusNote = nil
        Task { @MainActor in
            do {
                let outcome = try await importer.insert(items, at: at)
                lastCommandError =
                    outcome.ignored.isEmpty
                    ? nil
                    : "Could not find \(outcome.ignored.count) file\(outcome.ignored.count == 1 ? "" : "s"): "
                        + outcome.ignored.map(\.lastPathComponent).joined(separator: ", ")
            } catch {
                lastCommandError = "\(error)"
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
            await services.catalog.register(packageAt: url)
            await self.install(forked)
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

    /// The assistant composer's Send: the first message starts the session, later ones continue it.
    func sendToAssistant(_ message: String) {
        guard let assistant else { return }
        perform { try await assistant.send(message) }
    }

    /// Stages files for the next assistant message. Unlike every other panel in the window this imports
    /// nothing: the assistant is handed the paths and decides what to do with them.
    func presentAttachPanel() {
        guard let assistant else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Attach files to the next assistant message — nothing is imported"
        panel.prompt = "Attach"
        if panel.runModal() == .OK { assistant.composer.add(urls: panel.urls) }
    }

    private func selectedAssets(_ document: ProjectDocument) -> [Asset] {
        document.viewModel.selectedClips.compactMap { clip in clip.assetId.flatMap { document.project.assets[$0] } }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    /// Owned here, not in `EditorView`: that view is rebuilt whenever the document changes, and the
    /// panel sizes have to outlive it.
    @State private var panels = PanelLayoutModel()

    var body: some View {
        Group {
            if let services = model.services, let document = model.document, let approvals = model.approvals,
                let tools = model.tools, let assistant = model.assistant, let publish = model.publish
            {
                EditorView(
                    model: model, panels: panels, services: services, document: document, approvals: approvals,
                    jobs: model.jobs, tools: tools, assistant: assistant, publish: publish)
            } else if let error = model.bootError {
                ContentUnavailableView("Could not start", systemImage: "xmark.octagon", description: Text(error))
            } else {
                ProgressView(model.bootStage)
            }
        }
        // The minimum follows the panels, so collapsing one lets the window get narrower rather than
        // just freeing space inside it.
        .frame(minWidth: panels.minimumWindowWidth, minHeight: 700)
        .task { await model.boot() }
    }
}

struct EditorView: View {
    @Bindable var model: AppModel
    let panels: PanelLayoutModel
    let services: AppServices
    let document: ProjectDocument
    let approvals: ApprovalCenter
    let jobs: JobCenter
    let tools: ToolConsole
    let assistant: AssistantConsole
    let publish: PublishConsole

    var body: some View {
        HStack(spacing: 0) {
            PanelChrome(.assistant, layout: panels) {
                AssistantStatusBar(
                    transcript: assistant.transcript, isStarting: assistant.isStarting,
                    onStop: { model.perform { await assistant.cancel() } },
                    onClear: { assistant.newSession() })
            } content: {
                AssistantSection(assistant: assistant, model: model)
            }
            PanelDivider(.assistant, layout: panels)
            if let library = model.library {
                PanelChrome(.library, layout: panels) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.load() } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(library.isLoading)
                    Button("Import…", systemImage: "square.and.arrow.down") { model.presentImportPanel() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                } content: {
                    MediaLibraryView(
                        model: library, onInsert: { model.insertLibraryItems($0) },
                        onImport: { model.presentImportPanel() })
                }
                PanelDivider(.library, layout: panels)
            }
            centreColumn
            PanelDivider(.rightColumn, layout: panels)
            rightColumn
        }
        // Fill the window whatever the panels contain. A panel whose content sizes to itself — an empty
        // library, say — would otherwise leave the row short.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // What the columns have to share. `PanelLayoutModel` clamps every width against it, so a drag
        // can never squeeze the timeline out and shrinking the window pulls the panels in instead.
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            panels.availableWidthChanged($0)
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
        .dropDestination(for: URL.self) { urls, _ in
            model.dropFiles(urls)
            return true
        }
    }

    /// Built by hand because `EditorView` holds a plain `let document` and `toolbarContent` is a
    /// `@ToolbarContentBuilder` property, which cannot declare one — the same reason
    /// `publishSheetPresented` below is written this way.
    private var activeTool: Binding<TimelineTool> {
        Binding(
            get: { document.viewModel.activeTool }, set: { document.viewModel.selectTool($0) })
    }

    /// The preview, the timeline, and the status bar: the one column that takes whatever the panels
    /// leave it.
    private var centreColumn: some View {
        VStack(spacing: 0) {
            PreviewLayerView(preview: document.preview)
                .frame(minHeight: 240)
            Divider()
            TimelineView(viewModel: document.viewModel)
                .frame(minHeight: 220)
            statusBar
        }
        .frame(minWidth: PanelTheme.centreMinimum, maxWidth: .infinity)
    }

    private var publishSheetPresented: Binding<Bool> {
        Binding(get: { publish.sheet != nil }, set: { if !$0 { publish.dismissSheet() } })
    }

    /// The inspector over the activity panel. Both shut and the column is a single rail — two stacked
    /// header bars in a 400pt column would be a lot of chrome around nothing.
    @ViewBuilder private var rightColumn: some View {
        if panels.isCollapsed(.rightColumn) {
            PanelRail([.inspector, .activity], layout: panels)
        } else {
            VStack(spacing: 0) {
                PanelChrome(.inspector, layout: panels) {
                    InspectorView(viewModel: document.viewModel)
                }
                PanelDivider(.inspector, layout: panels)
                PanelChrome(.activity, layout: panels) {
                    ScrollView { activityStack }
                }
            }
            .frame(width: panels.size(.rightColumn))
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                panels.availableHeightChanged($0)
            }
        }
    }

    /// What the window is doing and has done: cards waiting on an answer, jobs running, publishes,
    /// the history, the last tool this window called, and how to reach the app from Claude Code.
    private var activityStack: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionGap) {
            ApprovalStackView(center: approvals)
                .padding(PanelTheme.panelInset)
            Divider()
            JobList(center: jobs)
            Divider()
            PublishSection(publish: publish)
            Divider()
            HistoryView(viewModel: document.viewModel)
                .frame(height: 220)
            if !tools.lastTool.isEmpty {
                Divider()
                ToolSection(tools: tools)
            }
            Divider()
            MCPSection(services: services)
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
            Button("Library", systemImage: "rectangle.stack") {
                withAnimation(PanelChromeAnimation.collapse) { panels.toggle(.library) }
            }
            .keyboardShortcut(PanelID.library.shortcut, modifiers: [.command, .option])
            .help("Show or hide the media library")
        }
        ToolbarItemGroup {
            // No `.keyboardShortcut`: SwiftUI installs those as key equivalents, which AppKit dispatches
            // before `keyDown` reaches the first responder, so a bare "c" would arm the razor while the
            // user was typing in the assistant composer. Every timeline key lives in `TimelineMetalView`.
            Picker("Tool", selection: activeTool) {
                ForEach(TimelineTool.allCases, id: \.self) { tool in
                    Label(tool == .razor ? "Razor" : "Select", systemImage: tool.symbolName).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .help("Select (V) or Razor (C) — the keys work when the timeline has focus")
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
            if let note = model.lastStatusNote { Text(note).foregroundStyle(.secondary).lineLimit(1) }
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

/// The last tool the *window* called — Analyze, Align, Export, Publish — with its structured answer,
/// collapsed until it is asked for. The assistant's calls are not here: it reaches the MCP host itself and
/// its calls are folded into the transcript. The section is hidden until a control has called something.
struct ToolSection: View {
    let tools: ToolConsole
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                if let text = tools.lastOutput?.text { Text(text).font(.caption) }
                Text(tools.structuredText).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(30)
                if let error = tools.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            HStack(spacing: 6) {
                Image(
                    systemName: tools.isCalling
                        ? "hourglass" : (tools.error == nil ? "wrench.and.screwdriver" : "xmark.octagon")
                )
                .foregroundStyle(tools.error == nil ? Color.secondary : Color.red)
                Text(tools.lastTool).font(.system(.caption, design: .monospaced))
                Spacer(minLength: 0)
            }
            .help("The last tool this window called; the assistant's calls are in its transcript")
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
                    ? "Embedded assistant: scripted fallback (\(a.detail ?? "claude not usable"))"
                    : "Embedded assistant: Claude Code \(a.version ?? "") (\(a.detail ?? ""))"
            )
            .font(.caption).foregroundStyle(.secondary)
            Text("Library root: \(services.layout.root.path)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

/// The assistant panel's body: what the session has said so far, and the composer under it. Its state
/// and its Stop / New session controls are the panel header's (`AssistantStatusBar`). There is no
/// "start" control — the first message starts the session — and files dropped anywhere in the panel are
/// staged, not imported.
struct AssistantSection: View {
    let assistant: AssistantConsole
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let transcript = assistant.transcript {
                AssistantPanelView(transcript: transcript)
            } else {
                ContentUnavailableView {
                    Label("No session yet", systemImage: "sparkles")
                } description: {
                    Text("Say what you want done. Drop clips anywhere in this panel to hand the assistant their paths.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = assistant.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            AssistantComposerView(
                composer: assistant.composer, isBusy: assistant.isRunning || assistant.isStarting,
                placeholder: assistant.transcript == nil
                    ? "Tell the assistant what to do — drop clips anywhere here" : "Message the assistant",
                onSend: { model.sendToAssistant($0) }, onAttach: { model.presentAttachPanel() })
        }
        // `AssistantDropHost` hosts this in an `NSView`, which sizes to what it is given: without the
        // fill the column would come out empty.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole panel takes the drop, not just the message box.
        .assistantAttachmentTarget(assistant.composer)
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
