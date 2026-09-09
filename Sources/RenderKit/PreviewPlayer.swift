import AVFoundation
import Contracts
import CoreMedia
import Foundation
import TimelineCore

/// The viewer's player pair. Owns two `AVPlayer`s and two `AVPlayerLayer`s and performs the structural swap
/// from spikes/preview-update (D1 + D3): a new item is seeked while detached, prepared on the idle player,
/// and only then made visible, so the picture never freezes while the audio-bearing item comes up.
/// Instruction-only edits go straight to the live item. During a gesture every structural edit compiles
/// video-only (2-4 ms to `readyToPlay` versus 15-590 ms with audio); `endGesture` swaps the audio back in.
@MainActor
public final class PreviewPlayer {
    /// One structural swap, for telemetry: the bimodal audio startup must stay visible in the field.
    public struct SwapRecord: Sendable, Hashable {
        /// From the swap call to `readyToPlay` on the new item.
        public var readyToPlayMs: Double
        /// From the swap call to the new player being the visible one.
        public var totalMs: Double
        public var hasAudio: Bool
        public var wasPlaying: Bool
        public var ready: Bool
    }

    public let renderer: AVFoundationRenderer
    public let players: [AVPlayer]
    public let layers: [AVPlayerLayer]
    public private(set) var compiled: Compiled?
    public private(set) var activeIndex = 0
    public private(set) var swaps: [SwapRecord] = []
    public private(set) var isGestureActive = false
    /// Called for every new item before it is seeked and attached (tests attach an `AVPlayerItemVideoOutput`).
    public var configureItem: ((AVPlayerItem) -> Void)?
    /// How far ahead of the current time a swap while playing seeks the new item, to hide its startup.
    public var seekAhead = CMTime(value: 1, timescale: 30)
    /// The longest a swap waits for `readyToPlay` before giving up on the new item.
    public var readyTimeout: Duration = .seconds(10)
    public var options: RenderOptions = .preview

    public var isMuted: Bool = false {
        didSet { for p in players { p.isMuted = isMuted } }
    }

    public init(renderer: AVFoundationRenderer) {
        self.renderer = renderer
        let players = [AVPlayer(), AVPlayer()]
        for p in players {
            p.actionAtItemEnd = .pause
            p.automaticallyWaitsToMinimizeStalling = false
        }
        self.players = players
        layers = players.map { AVPlayerLayer(player: $0) }
        layers[1].isHidden = true
    }

    public var activePlayer: AVPlayer { players[activeIndex] }
    public var activeLayer: AVPlayerLayer { layers[activeIndex] }
    public var currentItem: AVPlayerItem? { activePlayer.currentItem }
    public var isPlaying: Bool { activePlayer.rate != 0 }
    public var currentTime: CMTime { currentItem?.currentTime() ?? .zero }

    // MARK: Loading and editing

    /// Compiles `sequence` with `options` and swaps it in.
    @discardableResult
    public func load(_ sequence: Sequence, assets: [AssetID: Asset]) async throws -> Compiled {
        let compiled = try await renderer.compile(sequence, assets: assets, options: effectiveOptions)
        try await swap(to: compiled)
        return compiled
    }

    /// Structural edits until `endGesture` compile without audio.
    public func beginGesture() { isGestureActive = true }

    /// Restores audio: compiles the audio-bearing item and swaps it in behind the picture.
    public func endGesture(_ sequence: Sequence, assets: [AssetID: Asset]) async throws {
        isGestureActive = false
        guard let compiled, compiled.options != effectiveOptions else { return }
        let full = try await renderer.compile(sequence, assets: assets, options: effectiveOptions)
        try await swap(to: full)
    }

    /// Reflects an edit: instruction-only edits update the live item, structural ones swap in a new item.
    @discardableResult
    public func update(_ sequence: Sequence, assets: [AssetID: Asset]) async throws -> RenderUpdate {
        guard let current = compiled else {
            return .structural(try await load(sequence, assets: assets))
        }
        if current.options != effectiveOptions {
            let next = try await renderer.compile(sequence, assets: assets, options: effectiveOptions)
            try await swap(to: next)
            return .structural(next)
        }
        let result = try await renderer.update(current, to: sequence, assets: assets)
        switch result {
        case .instructionsOnly(let next):
            if let item = currentItem { renderer.apply(next, to: item) }
            compiled = next
        case .structural(let next):
            try await swap(to: next)
        }
        return result
    }

    private var effectiveOptions: RenderOptions {
        var o = options
        if isGestureActive { o.audio = false }
        return o
    }

    // MARK: Transport

    public func play() { activePlayer.play() }
    public func pause() { activePlayer.pause() }

    public func seek(to time: CMTime) async {
        guard let item = currentItem else { return }
        await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func seek(to time: RationalTime) async { await seek(to: CMTime(time)) }

    // MARK: Swap

    /// Prepares a new item on the idle player and switches to it. The old player keeps delivering frames
    /// until the new item is ready, so the picture never freezes.
    @discardableResult
    public func swap(to next: Compiled) async throws -> SwapRecord {
        let start = ContinuousClock.now
        let wasPlaying = isPlaying
        let time = currentTime
        let item = renderer.playerItem(for: next)
        configureItem?(item)
        if compiled != nil, time.isNumeric {
            let target = wasPlaying ? time + seekAhead : time
            await item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        let incomingIndex = 1 - activeIndex
        let incoming = players[incomingIndex]
        incoming.isMuted = isMuted
        incoming.replaceCurrentItem(with: item)
        let deadline = ContinuousClock.now + readyTimeout
        while item.status == .unknown, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let ready = item.status == .readyToPlay
        let readyMs = milliseconds(from: start)
        if wasPlaying { incoming.play() }
        let outgoing = activePlayer
        activeIndex = incomingIndex
        layers[incomingIndex].isHidden = false
        layers[1 - incomingIndex].isHidden = true
        outgoing.pause()
        outgoing.replaceCurrentItem(with: nil)
        compiled = next
        let record = SwapRecord(
            readyToPlayMs: readyMs, totalMs: milliseconds(from: start), hasAudio: next.hasAudio, wasPlaying: wasPlaying,
            ready: ready)
        swaps.append(record)
        return record
    }
}
