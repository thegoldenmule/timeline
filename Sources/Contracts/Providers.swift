import CoreGraphics
import Foundation
import TimelineCore

/// A media file plus its content hash, the key every cache uses. Build one from an asset and the layout.
public struct MediaReference: Hashable, Sendable, Codable {
    public var url: URL
    public var contentHash: String

    public init(url: URL, contentHash: String) {
        self.url = url
        self.contentHash = contentHash
    }

    public init(asset: Asset, layout: LibraryLayout) {
        self.init(url: layout.url(for: asset), contentHash: asset.contentHash)
    }
}

/// One filmstrip frame.
public struct Thumbnail: Sendable {
    public var time: RationalTime
    public var image: CGImage

    public init(time: RationalTime, image: CGImage) {
        self.time = time
        self.image = image
    }
}

/// Filmstrip frames for the timeline. Implementations serve from content-addressed sprite sheets in the
/// cache when present and generate otherwise; cancellation is through the calling task. Frames are
/// evenly spaced over `range`, `count` of them, scaled to `height` (width follows the aspect ratio).
public protocol ThumbnailProvider: Sendable {
    func filmstrip(for media: MediaReference, range: ClosedRange<RationalTime>, count: Int, height: Int)
        async throws -> [Thumbnail]
}

extension ThumbnailProvider {
    /// A single frame at `time`.
    public func thumbnail(for media: MediaReference, at time: RationalTime, height: Int) async throws -> Thumbnail? {
        try await filmstrip(for: media, range: time...time, count: 1, height: height).first
    }
}

/// Min/max peaks of a mono mixdown over `range`, one pair per `hop` source samples. `startSample` is the
/// source sample of the first pair so consumers can place peaks exactly.
public struct WaveformPeaks: Hashable, Sendable, Codable {
    public var sampleRate: Int
    public var hop: Int
    public var startSample: Int64
    public var min: [Float]
    public var max: [Float]

    public init(sampleRate: Int, hop: Int, startSample: Int64, min: [Float], max: [Float]) {
        precondition(min.count == max.count, "min and max must have the same length")
        self.sampleRate = sampleRate
        self.hop = hop
        self.startSample = startSample
        self.min = min
        self.max = max
    }

    public var count: Int { min.count }
}

/// Waveform peaks for the timeline at a zoom level (`samplesPerPixel`). Implementations pick the
/// nearest cached level (`peaks.json` at two or three zooms) and decimate; cancellation is through the
/// calling task.
public protocol WaveformProvider: Sendable {
    func peaks(for media: MediaReference, range: ClosedRange<RationalTime>, samplesPerPixel: Int) async throws
        -> WaveformPeaks
}
