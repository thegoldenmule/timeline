import Contracts
import CoreGraphics
import Foundation
import Synchronization
import TimelineCore

/// Gradient filmstrips (hue follows the time within the range). Records calls, optionally sleeps per
/// frame so cancellation can be tested.
public final class FakeThumbnailProvider: ThumbnailProvider, Sendable {
    public struct Call: Sendable, Hashable {
        public var media: MediaReference
        public var range: ClosedRange<RationalTime>
        public var count: Int
        public var height: Int
    }

    private let state = Mutex<[Call]>([])
    public let delayPerFrame: Duration?
    /// Answers every request with no frames, the way the real provider does for a file it cannot draw.
    public let findsNothing: Bool

    public init(delayPerFrame: Duration? = nil, findsNothing: Bool = false) {
        self.delayPerFrame = delayPerFrame
        self.findsNothing = findsNothing
    }

    public var calls: [Call] { state.withLock { $0 } }

    public func filmstrip(for media: MediaReference, range: ClosedRange<RationalTime>, count: Int, height: Int)
        async throws -> [Thumbnail]
    {
        state.withLock { $0.append(Call(media: media, range: range, count: count, height: height)) }
        guard !findsNothing else { return [] }
        let span = range.upperBound - range.lowerBound
        var result: [Thumbnail] = []
        for i in 0..<max(count, 0) {
            try Task.checkCancellation()
            if let delay = delayPerFrame { try await Task.sleep(for: delay) }
            let step = count > 1 ? span * Int64(i) / Int64(count - 1) : .zero
            let time = range.lowerBound + step
            let fraction = span.isPositive ? step.seconds / span.seconds : 0
            let image = try SyntheticImages.gradient(
                from: SyntheticImages.hue(fraction), to: SyntheticImages.hue(fraction + 0.1),
                size: CGSize(width: height * 16 / 9, height: height))
            result.append(Thumbnail(time: time, image: image))
        }
        return result
    }
}

/// Sine-shaped peaks at 48 kHz. Records calls.
public final class FakeWaveformProvider: WaveformProvider, Sendable {
    public struct Call: Sendable, Hashable {
        public var media: MediaReference
        public var range: ClosedRange<RationalTime>
        public var samplesPerPixel: Int
    }

    private let state = Mutex<[Call]>([])
    public let sampleRate: Int

    public init(sampleRate: Int = 48000) { self.sampleRate = sampleRate }

    public var calls: [Call] { state.withLock { $0 } }

    public func peaks(for media: MediaReference, range: ClosedRange<RationalTime>, samplesPerPixel: Int) async throws
        -> WaveformPeaks
    {
        state.withLock { $0.append(Call(media: media, range: range, samplesPerPixel: samplesPerPixel)) }
        try Task.checkCancellation()
        return FakeWaveformProvider.sinePeaks(
            sampleRate: sampleRate, range: range, samplesPerPixel: max(1, samplesPerPixel))
    }

    /// Peaks of a 2 Hz amplitude-modulated signal, deterministic for a given range and zoom.
    public static func sinePeaks(sampleRate: Int, range: ClosedRange<RationalTime>, samplesPerPixel: Int)
        -> WaveformPeaks
    {
        let start = Int64((range.lowerBound.seconds * Double(sampleRate)).rounded())
        let end = Int64((range.upperBound.seconds * Double(sampleRate)).rounded())
        let count = Int(max(0, end - start) / Int64(samplesPerPixel)) + 1
        var mins: [Float] = []
        var maxs: [Float] = []
        mins.reserveCapacity(count)
        maxs.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(start + Int64(i * samplesPerPixel)) / Double(sampleRate)
            let amplitude = Float(0.8 * abs(sin(2 * .pi * 2 * t)))
            maxs.append(amplitude)
            mins.append(-amplitude)
        }
        return WaveformPeaks(sampleRate: sampleRate, hop: samplesPerPixel, startSample: start, min: mins, max: maxs)
    }
}
