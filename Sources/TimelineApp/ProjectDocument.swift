import AVFoundation
import Contracts
import Foundation
import Observation
import ProjectStore
import RenderKit
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
/// inspector, and history draw from that), and RenderKit's `PreviewPlayer` showing the compiled active
/// sequence. Every store change arrives on `changes`; the document then re-reads state and hands the
/// sequence to the preview, which applies instructions to the live item or swaps in a new one on its
/// second player so the picture never freezes. Main-actor bound because it owns the players.
@MainActor @Observable
final class ProjectDocument {
    enum RenderPath: String, Sendable {
        case none
        case structural
        case instructionsOnly
    }

    let store: any ProjectStore
    let url: URL
    /// RenderKit's two-player preview; `preview.layers` are what the player view hosts.
    let preview: PreviewPlayer
    /// TimelineUI's mirror of the store: selection, playhead, zoom, gestures, one command per release.
    let viewModel: TimelineViewModel

    private(set) var project: Project
    private(set) var history: History
    /// Every change delivered on the store's stream, in order.
    private(set) var changes: [ProjectChange] = []
    private(set) var lastRenderPath: RenderPath = .none
    /// Bumped each time the preview swaps to a new player item.
    private(set) var playerItemGeneration = 0
    /// The project version the preview reflects: set after the render refresh for a change completes.
    private(set) var renderedVersion: Int64 = 0
    private(set) var playheadSeconds: Double = 0
    private(set) var isPlaying = false
    private(set) var lastError: String?

    private var subscription: Task<Void, Never>?
    private var timeObservers: [(AVPlayer, Any)] = []
    private var seekingFromPlayer = false
    private static let commandIds = UUIDv7Generator()

    private init(
        store: any ProjectStore, preview: PreviewPlayer, url: URL, project: Project, history: History,
        viewModel: TimelineViewModel
    ) {
        self.store = store
        self.preview = preview
        self.url = url
        self.project = project
        self.history = history
        self.viewModel = viewModel
        self.renderedVersion = project.version
    }

    var compiled: Compiled? { preview.compiled }
    var playerItem: AVPlayerItem? { preview.currentItem }

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

    /// Forks this project: copies its whole event stream into a new package at `url`, closes this document,
    /// opens the copy, and records the new name as the fork's first transaction. The original is untouched
    /// and both packages share the media library. Returns the document over the fork.
    func fork(to url: URL, name: String, using services: AppServices) async throws -> ProjectDocument {
        guard let copying = store as? any ProjectStoreCopying else { throw ForkError.unsupported }
        try await copying.saveAs(to: url)
        let originalName = project.name
        await close(using: services)
        let forked = try await ProjectDocument.open(at: url, using: services)
        let result = try await forked.apply(.renameProject(.init(name: name)), label: "Fork of \(originalName)")
        try await forked.waitForVersion(result.version)
        return forked
    }

    enum ForkError: Error, CustomStringConvertible {
        case unsupported
        var description: String { "This project's store cannot be copied" }
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
            store: store, preview: PreviewPlayer(renderer: services.previewRenderer), url: url, project: project,
            history: history, viewModel: viewModel)
        try await document.loadPreview()
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

    // MARK: Transport

    func togglePlayback() {
        if preview.isPlaying { preview.pause() } else { preview.play() }
        isPlaying = preview.isPlaying
    }

    // MARK: Waiting (for the headless check and sequenced edits)

    /// Returns once the change stream has delivered `version`, the mirror reflects it, and the render
    /// refresh for it has run.
    func waitForVersion(_ version: Int64, timeout: Duration = .seconds(30)) async throws {
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
        guard let item = preview.currentItem else { throw DocumentError.noPlayerItem }
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
        for (player, observer) in timeObservers { player.removeTimeObserver(observer) }
        timeObservers = []
        preview.pause()
        for player in preview.players { player.replaceCurrentItem(with: nil) }
        await services.projects.remove(project.id)
        do {
            try await store.close()
        } catch {
            lastError = "Close failed: \(error)"
        }
    }

    // MARK: Rendering

    /// An empty sequence has nothing to compile (`RenderError.sequenceEmpty`): the preview stays
    /// unloaded until the first clip lands.
    private func loadPreview() async throws {
        guard let sequence else { throw DocumentError.noActiveSequence }
        do {
            _ = try await preview.load(sequence, assets: project.assets)
            playerItemGeneration = preview.swaps.count
            lastRenderPath = .structural
        } catch RenderError.sequenceEmpty {
            lastRenderPath = .none
        }
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

    /// `PreviewPlayer.update`: instruction-only edits replace the live item's composition and mix,
    /// structural edits are compiled and swapped in on the idle player. The gesture path
    /// (`beginGesture` / `endGesture`, video-only compiles during a drag) is not driven yet: the timeline
    /// previews a gesture on a scratch copy and emits its one command on release.
    private func refreshRender() async {
        guard let sequence else { return }
        do {
            let update = try await preview.update(sequence, assets: project.assets)
            switch update {
            case .instructionsOnly: lastRenderPath = .instructionsOnly
            case .structural: lastRenderPath = .structural
            }
            playerItemGeneration = preview.swaps.count
            lastError = nil
        } catch RenderError.sequenceEmpty {
            preview.pause()
            for player in preview.players { player.replaceCurrentItem(with: nil) }
            lastRenderPath = .none
            lastError = nil
        } catch {
            lastError = "Render update failed: \(error)"
        }
    }

    // MARK: Playhead

    /// The active player drives the timeline's playhead while playing; the timeline drives the player
    /// (a ruler click, arrow keys) while paused. Both players carry an observer because a structural
    /// swap changes which one is active.
    private func observePlayhead() {
        let interval = CMTime(value: 1, timescale: 30)
        for player in preview.players {
            let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, player === self.preview.activePlayer else { return }
                    self.playheadSeconds = time.isNumeric ? time.seconds : 0
                    self.isPlaying = self.preview.isPlaying
                    if self.preview.isPlaying {
                        self.seekingFromPlayer = true
                        self.viewModel.setPlayhead(RationalTime(seconds: self.playheadSeconds, timescale: 48000))
                        self.seekingFromPlayer = false
                    }
                }
            }
            timeObservers.append((player, observer))
        }
        observeViewModelPlayhead()
    }

    private func observeViewModelPlayhead() {
        withObservationTracking {
            _ = viewModel.playhead
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.followViewModelPlayhead()
                self.observeViewModelPlayhead()
            }
        }
    }

    private func followViewModelPlayhead() async {
        guard !seekingFromPlayer, !preview.isPlaying else { return }
        let target = viewModel.playhead.seconds
        guard abs(target - playheadSeconds) > 0.001 else { return }
        playheadSeconds = target
        await preview.seek(to: CMTime(seconds: target, preferredTimescale: 48000))
    }
}
