import AVFoundation
import Contracts
import Foundation
import Observation
import ProjectStore
import TimelineCore
import TimelineUI

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

/// One open project as the window sees it: the store, TimelineUI's view model over it (the timeline,
/// inspector, and history draw from that), the compiled active sequence, and the `AVPlayer` showing it.
/// Every store change arrives on `changes`; the document then re-reads state, runs `Renderer.update`,
/// and either applies instructions to the live item or swaps in a new one. Main-actor bound because it
/// owns the player and its item.
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
    /// TimelineUI's mirror of the store: selection, playhead, zoom, gestures, one command per release.
    let viewModel: TimelineViewModel

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
    private var seekingFromViewModel = false
    private static let commandIds = UUIDv7Generator()

    private init(
        store: any ProjectStore, renderer: any Renderer, url: URL, project: Project, history: History,
        viewModel: TimelineViewModel
    ) {
        self.store = store
        self.renderer = renderer
        self.url = url
        self.project = project
        self.history = history
        self.viewModel = viewModel
        self.renderedVersion = project.version
    }

    /// Opens the package at `url`, registers it as an open project, compiles, attaches the player item,
    /// and starts mirroring changes. The change stream is subscribed before the state is read, so no
    /// transaction can slip between the two.
    static func open(at url: URL, using services: AppServices) async throws -> ProjectDocument {
        let store = try await services.opener.open(at: url)
        return try await attach(store, url: url, using: services)
    }

    /// Opens the package at `url`, creating a blank project there when it does not exist yet.
    static func openOrCreate(at url: URL, name: String, using services: AppServices) async throws -> ProjectDocument {
        if ProjectPackage(url: url).exists { return try await open(at: url, using: services) }
        return try await create(at: url, name: name, using: services)
    }

    /// Creates a project with one 1080p30 sequence and a video and an audio track.
    static func create(at url: URL, name: String, using services: AppServices) async throws -> ProjectDocument {
        let store = try await services.opener.create(
            at: url, name: name, settings: ProjectSettings(),
            sequence: .init(name: "Sequence 1", frameDuration: RationalTime(1, 30), width: 1920, height: 1080))
        let sequenceId = await store.state().activeSequenceId
        if let sequenceId {
            let command = Command(
                commandId: CommandID(minting: commandIds), actor: .system, label: "Add tracks",
                operation: .batch([
                    .addTrack(.init(sequenceId: .id(sequenceId), kind: .video, name: "V1")),
                    .addTrack(.init(sequenceId: .id(sequenceId), kind: .audio, name: "A1")),
                ]))
            _ = try await store.apply(command)
        }
        return try await attach(store, url: url, using: services)
    }

    private static func attach(_ store: any ProjectStore, url: URL, using services: AppServices) async throws
        -> ProjectDocument
    {
        await services.projects.add(store, url: url)
        let changes = store.changes
        let project = await store.state()
        let history = await store.history()
        let viewModel = TimelineViewModel(
            store: store, thumbnails: services.thumbnails, waveforms: services.waveforms,
            libraryLayout: services.layout)
        await viewModel.load()
        viewModel.startObserving()
        let document = ProjectDocument(
            store: store, renderer: services.renderer, url: url, project: project, history: history,
            viewModel: viewModel)
        try await document.compileAndAttach()
        document.subscribe(to: changes)
        document.observePlayhead()
        return document
    }

    var version: Int64 { project.version }
    var sequence: Sequence? { project.activeSequence }
    var canUndo: Bool { viewModel.canUndo }
    var canRedo: Bool { viewModel.canRedo }

    // MARK: Commands

    @discardableResult
    func apply(_ operation: Command.Operation, label: String? = nil, actor: Actor = .human) async throws(EditorError)
        -> CommandResult
    {
        let command = Command(
            commandId: CommandID(minting: ProjectDocument.commandIds), actor: actor, label: label,
            operation: operation)
        return try await store.apply(command)
    }

    @discardableResult
    func undo() async throws(EditorError) -> CommandResult { try await apply(.undo(.init())) }

    @discardableResult
    func redo() async throws(EditorError) -> CommandResult { try await apply(.redo) }

    /// The first unlocked track of `kind`, created at the end when the sequence has none.
    func track(of kind: TrackKind) async throws(EditorError) -> Track {
        guard let sequence else { throw .notFound(id: "activeSequence") }
        if let track = sequence.tracks.first(where: { $0.kind == kind && !$0.locked }) { return track }
        let name = kind == .video ? "V\(sequence.tracks.filter { $0.kind == .video }.count + 1)" : "A1"
        let result = try await apply(
            .addTrack(.init(sequenceId: .id(sequence.id), kind: kind, name: name)), label: "Add track")
        try await waitForVersionOrThrow(result.version)
        guard let track = self.sequence?.tracks.first(where: { $0.kind == kind && !$0.locked }) else {
            throw .notFound(id: "track")
        }
        return track
    }

    /// The end of the last clip on any track, where an appended clip goes.
    var sequenceEnd: RationalTime {
        guard let sequence else { return .zero }
        var end = RationalTime.zero
        for track in sequence.tracks {
            for clip in track.clips.values { end = RationalTime.max(end, sequence.end(of: clip)) }
        }
        return end
    }

    /// Appends the whole asset at the end of the timeline on a matching track; video auto-links its audio.
    @discardableResult
    func appendClip(for asset: Asset) async throws(EditorError) -> CommandResult {
        guard let sequence else { throw .notFound(id: "activeSequence") }
        let kind: TrackKind = asset.hasVideo ? .video : .audio
        let track = try await track(of: kind)
        if asset.hasVideo, asset.hasAudio { _ = try await self.track(of: .audio) }
        return try await apply(
            .addClip(
                .init(
                    sequenceId: .id(sequence.id), trackId: .id(track.id), assetId: .id(asset.id), at: sequenceEnd,
                    sourceIn: .zero, sourceOut: asset.duration, mode: .overwrite, link: .auto)),
            label: "Add \(asset.displayName)")
    }

    // MARK: Waiting (for the headless check and sequenced edits)

    /// Returns once the change stream has delivered `version`, the mirror reflects it, and the render
    /// refresh for it has run.
    func waitForVersion(_ version: Int64, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while renderedVersion < version || viewModel.project.version < version {
            guard ContinuousClock.now < deadline else { throw DocumentError.timedOut("version \(version)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForVersionOrThrow(_ version: Int64) async throws(EditorError) {
        do {
            try await waitForVersion(version)
        } catch {
            throw .invalid(reason: "\(error)")
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

    func close(using services: AppServices) async {
        subscription?.cancel()
        viewModel.stopObserving()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        await services.projects.remove(project.id)
        do {
            try await store.close()
        } catch {
            lastError = "Close failed: \(error)"
        }
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

    /// RenderKit swap point: the gesture path (video-only compile during a drag, audio on release) and
    /// the second-player swap for structural edits while playing plug in here.
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

    // MARK: Playhead

    /// The player drives the timeline's playhead while playing; the timeline drives the player (a
    /// ruler click, arrow keys) while paused.
    private func observePlayhead() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playheadSeconds = time.isNumeric ? time.seconds : 0
                if self.player.rate > 0 {
                    self.seekingFromViewModel = true
                    self.viewModel.setPlayhead(RationalTime(seconds: self.playheadSeconds, timescale: 48000))
                    self.seekingFromViewModel = false
                }
            }
        }
        observeViewModelPlayhead()
    }

    private func observeViewModelPlayhead() {
        withObservationTracking {
            _ = viewModel.playhead
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.followViewModelPlayhead()
                self.observeViewModelPlayhead()
            }
        }
    }

    private func followViewModelPlayhead() {
        guard !seekingFromViewModel, player.rate == 0 else { return }
        let target = viewModel.playhead.seconds
        guard abs(target - playheadSeconds) > 0.001 else { return }
        playheadSeconds = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
