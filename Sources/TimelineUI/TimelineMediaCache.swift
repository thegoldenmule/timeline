import Contracts
import CoreGraphics
import Foundation
import Metal
import TimelineCore

/// Filmstrip textures and waveform peaks for the visible clips at the current zoom. A miss starts one
/// fetch per key (deduplicated), stores the result, and calls `onUpdate` so the view redraws; the
/// scene never waits. Entries evict oldest-first past `capacity`.
@MainActor
public final class TimelineMediaCache {
    public struct FilmstripFrame {
        public var texture: any MTLTexture
        public var time: RationalTime
    }

    public let device: any MTLDevice
    public let thumbnails: (any ThumbnailProvider)?
    public let waveforms: (any WaveformProvider)?
    public let capacity: Int
    /// Called on the main actor after every completed fetch.
    public var onUpdate: (@MainActor () -> Void)?

    private var strips: [FilmstripKey: [FilmstripFrame]] = [:]
    private var stripOrder: [FilmstripKey] = []
    private var peaks: [WaveformKey: WaveformPeaks] = [:]
    private var peakOrder: [WaveformKey] = []
    private var stripTasks: [FilmstripKey: Task<Void, Never>] = [:]
    private var peakTasks: [WaveformKey: Task<Void, Never>] = [:]
    public private(set) var fetchCount = 0
    public private(set) var failedCount = 0

    public init(
        device: any MTLDevice, thumbnails: (any ThumbnailProvider)?, waveforms: (any WaveformProvider)?,
        capacity: Int = 512
    ) {
        self.device = device
        self.thumbnails = thumbnails
        self.waveforms = waveforms
        self.capacity = capacity
    }

    public var pendingCount: Int { stripTasks.count + peakTasks.count }
    public var filmstripCount: Int { strips.count }
    public var waveformCount: Int { peaks.count }

    /// Cached frames, or nil (and a fetch in flight) on a miss.
    public func filmstrip(_ key: FilmstripKey) -> [FilmstripFrame]? {
        if let frames = strips[key] { return frames }
        guard let provider = thumbnails, stripTasks[key] == nil else { return nil }
        fetchCount += 1
        stripTasks[key] = Task { @MainActor [weak self] in
            let thumbs: [Thumbnail]?
            do {
                thumbs = try await provider.filmstrip(
                    for: key.media, range: key.sourceIn...key.sourceOut, count: key.count, height: key.height)
            } catch {
                thumbs = nil
            }
            guard let self else { return }
            if let thumbs {
                let frames = thumbs.compactMap { t -> FilmstripFrame? in
                    MetalTextures.texture(from: t.image, device: self.device).map {
                        FilmstripFrame(texture: $0, time: t.time)
                    }
                }
                self.store(frames, for: key)
            } else {
                self.failedCount += 1
            }
            self.stripTasks[key] = nil
            self.onUpdate?()
        }
        return nil
    }

    /// Cached peaks, or nil (and a fetch in flight) on a miss.
    public func peaks(_ key: WaveformKey) -> WaveformPeaks? {
        if let p = peaks[key] { return p }
        guard let provider = waveforms, peakTasks[key] == nil else { return nil }
        fetchCount += 1
        peakTasks[key] = Task { @MainActor [weak self] in
            let result: WaveformPeaks?
            do {
                result = try await provider.peaks(
                    for: key.media, range: key.sourceIn...key.sourceOut, samplesPerPixel: key.samplesPerPixel)
            } catch {
                result = nil
            }
            guard let self else { return }
            if let result { self.store(result, for: key) } else { self.failedCount += 1 }
            self.peakTasks[key] = nil
            self.onUpdate?()
        }
        return nil
    }

    private func store(_ frames: [FilmstripFrame], for key: FilmstripKey) {
        if strips[key] == nil { stripOrder.append(key) }
        strips[key] = frames
        while strips.count > capacity, let oldest = stripOrder.first {
            stripOrder.removeFirst()
            strips[oldest] = nil
        }
    }

    private func store(_ p: WaveformPeaks, for key: WaveformKey) {
        if peaks[key] == nil { peakOrder.append(key) }
        peaks[key] = p
        while peaks.count > capacity, let oldest = peakOrder.first {
            peakOrder.removeFirst()
            peaks[oldest] = nil
        }
    }

    /// Waits for every fetch in flight (tests).
    public func drain() async {
        while pendingCount > 0 {
            let tasks = Array(stripTasks.values) + Array(peakTasks.values)
            for t in tasks { await t.value }
        }
    }

    public func clear() {
        for t in stripTasks.values { t.cancel() }
        for t in peakTasks.values { t.cancel() }
        stripTasks = [:]
        peakTasks = [:]
        strips = [:]
        stripOrder = []
        peaks = [:]
        peakOrder = []
    }
}
