import AVFoundation
import Contracts
import Foundation
import Observation
import TimelineCore

enum DocumentError: Error, CustomStringConvertible {
    case noActiveSequence
    case noPlayerItem
    case playerItemFailed(String)
    case timedOut(String)

    var description: String {
        switch self {
        case .noActiveSequence: "The project has no active sequence"
        case .noPlayerItem: "No player item has been built yet"
        case .playerItemFailed(let reason): "The player item failed: \(reason)"
        case .timedOut(let what): "Timed out waiting for \(what)"
        }
    }
}

/// One open project as the UI sees it: a mirror of the store's state and history, the compiled active
/// sequence, and the `AVPlayer` showing it. Every store change arrives on `changes`; the document then
/// re-reads state, runs `Renderer.update`, and either applies instructions to the live item or swaps
/// in a new one. Main-actor bound because it owns the player and its item.
@MainActor @Observable
final class ProjectDocument {
    enum RenderPath: String, Sendable {
        case none
        case structural
        case instructionsOnly
    }

    let store: any ProjectStore
    let renderer: any Renderer
    let url: URL
    let player = AVPlayer()

    private(set) var project: Project
    private(set) var history: History
    private(set) var compiled: Compiled?
    private(set) var playerItem: AVPlayerItem?
    /// Every change delivered on the store's stream, in order.
    private(set) var changes: [ProjectChange] = []
    private(set) var lastRenderPath: RenderPath = .none
    /// Bumped each time a new player item is attached.
    private(set) var playerItemGeneration = 0
    /// The project version the player reflects: set after the render refresh for a change completes.
    private(set) var renderedVersion: Int64 = 0
    private(set) var playheadSeconds: Double = 0
    private(set) var lastError: String?

    private var subscription: Task<Void, Never>?
    private var timeObserver: Any?
    private static let commandIds = UUIDv7Generator()

    private init(store: any ProjectStore, renderer: any Renderer, url: URL, project: Project, history: History) {
        self.store = store
        self.renderer = renderer
        self.url = url
        self.project = project
        self.history = history
        self.renderedVersion = project.version
    }

    /// Opens the store at `url`, registers it as an open project, compiles, attaches the player item,
    /// and starts mirroring changes. The change stream is subscribed before the state is read, so no
    /// transaction can slip between the two.
    static func open(at url: URL, using services: AppServices) async throws -> ProjectDocument {
        let store = try await services.opener.open(at: url)
        await services.projects.add(store, url: url)
        let changes = store.changes
        let project = await store.state()
        let history = await store.history()
        let document = ProjectDocument(
            store: store, renderer: services.renderer, url: url, project: project, history: history)
        try await document.compileAndAttach()
        document.subscribe(to: changes)
        document.observePlayhead()
        return document
    }

    var version: Int64 { project.version }
    var sequence: Sequence? { project.activeSequence }
    /// The creation transaction is never undoable, so undo needs a second live transaction.
    var canUndo: Bool { history.live.count > 1 }
    var canRedo: Bool { history.redoTarget != nil }

    // MARK: Commands

    @discardableResult
    func apply(_ operation: Command.Operation, label: String? = nil) async throws(EditorError) -> CommandResult {
        let command = Command(
            commandId: CommandID(minting: ProjectDocument.commandIds), actor: .human, label: label,
            operation: operation)
        return try await store.apply(command)
    }

    @discardableResult
    func undo() async throws(EditorError) -> CommandResult { try await apply(.undo(.init())) }

    @discardableResult
    func redo() async throws(EditorError) -> CommandResult { try await apply(.redo) }

    /// The video clip that starts last on the first video track: moving it right never collides.
    var nudgeCandidate: Clip? {
        sequence?.tracks.first { $0.kind == .video }?.clips.values.max { $0.start < $1.start }
    }

    /// Moves `nudgeCandidate` right by `frames` in overwrite mode (a structural edit).
    @discardableResult
    func nudgeClip(frames: Int64 = 12) async throws(EditorError) -> CommandResult {
        guard let clip = nudgeCandidate, let sequence else { throw .notFound(id: "video clip") }
        let start = clip.start + RationalTime.frames(frames, of: sequence.frameDuration)
        return try await apply(
            .moveClip(.init(clipId: .id(clip.id), to: .init(start: start), mode: .overwrite)),
            label: "Nudge clip")
    }

    /// Halves the first video clip's opacity (an instructions-only edit).
    @discardableResult
    func fadeFirstClip() async throws(EditorError) -> CommandResult {
        let firstTrack = sequence?.tracks.first(where: { $0.kind == .video })
        guard let clip = firstTrack?.clips.values.min(by: { $0.start < $1.start }) else {
            throw .notFound(id: "video clip")
        }
        let current = clip.opacity.constantValue ?? 1
        let next = current > 0.5 ? 0.5 : 1
        return try await apply(.setClipOpacity(.init(clipId: .id(clip.id), after: .constant(next))), label: "Fade clip")
    }

    // MARK: Waiting (for the headless check)

    /// Returns once the change stream has delivered `version`, the mirror reflects it, and the render
    /// refresh for it has run.
    func waitForVersion(_ version: Int64, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while renderedVersion < version {
            guard ContinuousClock.now < deadline else { throw DocumentError.timedOut("version \(version)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitForReadyToPlay(timeout: Duration = .seconds(20)) async throws {
        guard let item = playerItem else { throw DocumentError.noPlayerItem }
        let deadline = ContinuousClock.now + timeout
        while item.status == .unknown {
            guard ContinuousClock.now < deadline else { throw DocumentError.timedOut("readyToPlay") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard item.status == .readyToPlay else {
            throw DocumentError.playerItemFailed(item.error?.localizedDescription ?? "status \(item.status.rawValue)")
        }
    }

    func close() async {
        subscription?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        try? await store.close()
    }

    // MARK: Rendering

    private func compileAndAttach() async throws {
        guard let sequence else { throw DocumentError.noActiveSequence }
        let compiled = try await renderer.compile(sequence, assets: project.assets, options: .preview)
        self.compiled = compiled
        attach(renderer.playerItem(for: compiled))
    }

    private func attach(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        playerItem = item
        playerItemGeneration += 1
    }

    private func subscribe(to changes: AsyncStream<ProjectChange>) {
        subscription = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                await self.handle(change)
            }
        }
    }

    private func handle(_ change: ProjectChange) async {
        changes.append(change)
        project = await store.state()
        history = await store.history()
        await refreshRender()
        renderedVersion = project.version
    }

    private func refreshRender() async {
        guard let sequence else { return }
        do {
            guard let compiled else {
                try await compileAndAttach()
                lastRenderPath = .structural
                return
            }
            let update = try await renderer.update(compiled, to: sequence, assets: project.assets)
            self.compiled = update.compiled
            switch update {
            case .instructionsOnly(let next):
                if let playerItem {
                    renderer.apply(next, to: playerItem)
                } else {
                    attach(renderer.playerItem(for: next))
                }
                lastRenderPath = .instructionsOnly
            case .structural(let next):
                let item = renderer.playerItem(for: next)
                let wasPlaying = player.rate > 0
                let time = player.currentTime()
                if time.isNumeric, time.seconds > 0 {
                    _ = await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                attach(item)
                if wasPlaying { player.play() }
                lastRenderPath = .structural
            }
            lastError = nil
        } catch {
            lastError = "Render update failed: \(error)"
        }
    }

    private func observePlayhead() {
        let interval = CMTime(value: 1, timescale: 20)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.playheadSeconds = time.isNumeric ? time.seconds : 0
            }
        }
    }
}
