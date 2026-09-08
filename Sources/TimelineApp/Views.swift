import AVKit
import Contracts
import Foundation
import Observation
import SwiftUI
import TimelineCore

/// Boots the composition root and opens the fixture project; the consoles hang off the services.
@MainActor @Observable
final class AppModel {
    private(set) var services: AppServices?
    private(set) var document: ProjectDocument?
    private(set) var jobs: JobConsole?
    private(set) var tools: ToolConsole?
    private(set) var agent: AgentConsole?
    private(set) var bootError: String?
    var lastCommandError: String?

    func boot() async {
        guard services == nil else { return }
        do {
            let services = try await AppServices.fakes()
            self.services = services
            jobs = JobConsole(services: services)
            tools = ToolConsole(services: services)
            agent = AgentConsole(services: services)
            let document = try await ProjectDocument.open(at: AppServices.fixtureURL, using: services)
            self.document = document
            document.player.play()
        } catch {
            bootError = "\(error)"
        }
    }

    /// Runs a store command from a button, surfacing the `EditorError` in the window.
    func perform(_ body: @MainActor @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await body()
                lastCommandError = nil
            } catch {
                lastCommandError = "\(error)"
            }
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let document = model.document, let jobs = model.jobs, let tools = model.tools, let agent = model.agent {
                EditorView(model: model, document: document, jobs: jobs, tools: tools, agent: agent)
            } else if let error = model.bootError {
                ContentUnavailableView(
                    "Could not open the fixture project", systemImage: "xmark.octagon", description: Text(error))
            } else {
                ProgressView("Opening three-clips…")
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .task { await model.boot() }
    }
}

struct EditorView: View {
    @Bindable var model: AppModel
    let document: ProjectDocument
    let jobs: JobConsole
    let tools: ToolConsole
    let agent: AgentConsole

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PlayerView(player: document.player)
                    .frame(minHeight: 260)
                Divider()
                TimelineCanvas(document: document)
                    .frame(minHeight: 180, maxHeight: 220)
                statusBar
            }
            .frame(minWidth: 640)
            SidebarView(document: document, jobs: jobs, tools: tools, agent: agent)
                .frame(minWidth: 360, idealWidth: 400, maxWidth: 520)
        }
        .toolbar { toolbarContent }
        .navigationTitle("\(document.project.name) — v\(document.version)")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button("Nudge clip", systemImage: "arrow.right.to.line") {
                model.perform { try await document.nudgeClip() }
            }
            Button("Fade clip", systemImage: "circle.lefthalf.filled") {
                model.perform { try await document.fadeFirstClip() }
            }
            Button("Undo", systemImage: "arrow.uturn.backward") { model.perform { try await document.undo() } }
                .disabled(!document.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { model.perform { try await document.redo() } }
                .disabled(!document.canRedo)
        }
        ToolbarItemGroup {
            Button("Run fake job", systemImage: "gearshape.2") {
                model.perform { _ = try await jobs.runDemoJob(project: document.project) }
            }
            .disabled(jobs.isRunning)
            Button("Call tool", systemImage: "wrench.and.screwdriver") {
                model.perform { _ = try await tools.describeProject() }
            }
            .disabled(tools.isCalling)
            Button("Start agent", systemImage: "sparkles") {
                model.perform { try await agent.start(goal: "Export a vertical reel of the three clips") }
            }
            .disabled(agent.isRunning)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("Render path: \(document.lastRenderPath.rawValue)")
            Text("Player item #\(document.playerItemGeneration)")
            Text(String(format: "Playhead %.2fs", document.playheadSeconds))
            if let error = model.lastCommandError ?? document.lastError {
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

/// A placeholder timeline: tracks as rows, clips as rectangles, the playhead from the player.
/// TimelineUI's Metal view replaces it in Phase 2.
struct TimelineCanvas: View {
    let document: ProjectDocument

    private let rowHeight: CGFloat = 40
    private let headerWidth: CGFloat = 56

    var body: some View {
        Canvas { context, size in
            guard let sequence = document.sequence else { return }
            let duration = max(FakeRendererDuration.seconds(of: sequence), 1)
            let width = size.width - headerWidth - 8
            let scale = width / duration
            for (row, track) in sequence.tracks.enumerated() {
                let y = CGFloat(row) * rowHeight + 8
                let laneRect = CGRect(x: headerWidth, y: y, width: width, height: rowHeight - 6)
                context.fill(Path(roundedRect: laneRect, cornerRadius: 4), with: .color(.gray.opacity(0.12)))
                context.draw(
                    Text(track.name).font(.caption.monospaced()).foregroundStyle(.secondary),
                    at: CGPoint(x: 8, y: y + rowHeight / 2 - 3), anchor: .leading)
                for clip in track.clips.values.sorted(by: { $0.start < $1.start }) {
                    let x = headerWidth + CGFloat(clip.start.seconds) * scale
                    let w = max(2, CGFloat(sequence.duration(of: clip).seconds) * scale)
                    let rect = CGRect(x: x, y: y + 2, width: w, height: rowHeight - 10)
                    let opacity = clip.opacity.constantValue ?? 1
                    let color: Color = track.kind == .video ? .blue : track.kind == .audio ? .green : .orange
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.35 + 0.5 * opacity)))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(color), lineWidth: 1)
                    let label = clip.assetId.flatMap { document.project.assets[$0]?.displayName } ?? clip.text ?? "clip"
                    context.draw(
                        Text(label).font(.caption2).foregroundStyle(.primary),
                        in: rect.insetBy(dx: 4, dy: 4))
                }
            }
            let px = headerWidth + CGFloat(document.playheadSeconds) * scale
            var playhead = Path()
            playhead.move(to: CGPoint(x: px, y: 0))
            playhead.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(playhead, with: .color(.red), lineWidth: 1.5)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct SidebarView: View {
    let document: ProjectDocument
    let jobs: JobConsole
    let tools: ToolConsole
    let agent: AgentConsole

    var body: some View {
        List {
            Section("Agent") { AgentSection(agent: agent) }
            Section("Job") { JobSection(jobs: jobs) }
            Section("Tool result") { ToolSection(tools: tools) }
            Section("History (\(document.history.live.count) live)") { HistorySection(document: document) }
        }
        .listStyle(.sidebar)
    }
}

struct HistorySection: View {
    let document: ProjectDocument

    var body: some View {
        ForEach(document.history.transactions.reversed(), id: \.id) { transaction in
            HStack {
                Image(systemName: icon(for: transaction))
                    .foregroundStyle(document.history.isLive(transaction.id) ? .primary : .secondary)
                VStack(alignment: .leading) {
                    Text(transaction.label).strikethrough(isUndone(transaction))
                    Text("\(transaction.actor.description) · \(transaction.events.count) events")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func isUndone(_ transaction: TimelineCore.Transaction) -> Bool {
        transaction.kind == .edit && !document.history.isLive(transaction.id)
    }

    private func icon(for transaction: TimelineCore.Transaction) -> String {
        switch transaction.kind {
        case .edit: "pencil"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        }
    }
}

struct JobSection: View {
    let jobs: JobConsole

    var body: some View {
        if jobs.label.isEmpty {
            Text("No job run yet").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(jobs.label)
                ProgressView(value: jobs.fraction)
                if let last = jobs.progress.last {
                    Text("\(last.stage ?? "") \(last.message ?? "") · \(jobs.progress.count) events")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let outcome = jobs.outcome {
                    Text(PrettyJSON.string(outcome.payload)).font(.caption.monospaced())
                }
                if let error = jobs.error { Text(error).foregroundStyle(.red) }
            }
        }
    }
}

struct ToolSection: View {
    let tools: ToolConsole

    var body: some View {
        if tools.lastTool.isEmpty {
            Text("No tool called yet").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(tools.lastTool).bold()
                if let text = tools.lastOutput?.text { Text(text) }
                Text(tools.structuredText).font(.caption.monospaced()).textSelection(.enabled)
                if let error = tools.error { Text(error).foregroundStyle(.red) }
            }
        }
    }
}

struct AgentSection: View {
    let agent: AgentConsole

    var body: some View {
        if let pending = agent.pending {
            ApprovalCard(agent: agent, pending: pending)
        }
        if agent.entries.isEmpty {
            Text("No session started").foregroundStyle(.secondary)
        }
        ForEach(agent.entries) { entry in
            AgentEntryRow(entry: entry)
        }
        if let error = agent.error { Text(error).foregroundStyle(.red) }
    }
}

struct ApprovalCard: View {
    let agent: AgentConsole
    let pending: AgentConsole.PendingApproval

    var body: some View {
        let request = pending.gate ?? pending.scripted
        VStack(alignment: .leading, spacing: 6) {
            Label("Approval required", systemImage: "hand.raised.fill").font(.headline)
            Text(request.inputSummary)
            Text(estimate(request.estimate)).font(.caption).foregroundStyle(.secondary)
            Text(
                pending.gate == nil
                    ? "Runtime request only (the gate has nothing pending)" : "Gate request \(request.id)"
            )
            .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Approve") { Task { await agent.approve() } }.keyboardShortcut(.defaultAction)
                Button("Deny") { Task { await agent.deny() } }
            }
        }
        .padding(8)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private func estimate(_ e: Estimate) -> String {
        var parts: [String] = []
        if let s = e.seconds { parts.append(String(format: "%.0f s", s)) }
        if let b = e.bytes { parts.append("\(b >> 20) MB") }
        if let u = e.usd { parts.append(String(format: "$%.2f", u)) }
        return parts.isEmpty ? "no estimate" : parts.joined(separator: " · ")
    }
}

struct AgentEntryRow: View {
    let entry: AgentConsole.Entry

    var body: some View {
        switch entry.kind {
        case .runtime(let event):
            runtimeRow(event)
        case .appToolExecution(_, let name, let output, let retried):
            HStack(alignment: .top) {
                Image(
                    systemName: output.isError
                        ? "xmark.circle" : output.isApprovalRequired ? "hand.raised" : "checkmark.circle")
                VStack(alignment: .leading) {
                    Text("app ran \(name)\(retried ? " (with token)" : "")").font(.caption.bold())
                    Text(output.text ?? PrettyJSON.string(output.structured)).font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func runtimeRow(_ event: AgentEvent) -> some View {
        switch event {
        case .turnStarted(let index):
            Label("Turn \(index)", systemImage: "play").font(.caption).foregroundStyle(.secondary)
        case .assistantText(let text):
            Label(text, systemImage: "text.bubble")
        case .toolCall(_, let name, let input):
            Label("\(name) \(PrettyJSON.string(input))", systemImage: "wrench").font(.caption.monospaced())
        case .toolResult(_, let output, let isError):
            Label(PrettyJSON.string(output), systemImage: isError ? "xmark" : "arrow.turn.down.left")
                .font(.caption.monospaced())
        case .approvalRequested(let request):
            Label("Approval requested: \(request.inputSummary)", systemImage: "hand.raised")
        case .cost(let cost):
            Label(String(format: "$%.3f", cost.usd), systemImage: "dollarsign.circle").font(.caption)
        case .finished(let result, let cost):
            Label("Finished: \(result ?? "") ($\(cost?.usd ?? 0))", systemImage: "flag.checkered")
        case .failed(let failure):
            Label("Failed: \(failure.message)", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .raw(let value):
            Label(PrettyJSON.string(value), systemImage: "questionmark").font(.caption.monospaced())
        }
    }
}

/// `AVPlayerView` in SwiftUI. The AVKit SwiftUI overlay's `VideoPlayer` would do the same, but an SPM
/// executable that only references the overlay does not load AVKit's ObjC classes at launch (the
/// runtime fails to demangle `AVPlayerView`), so the view is wrapped by hand.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
