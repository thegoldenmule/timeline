import AVFoundation
import Contracts
import Foundation
import Synchronization
import TimelineCore

/// `peaks.json`: min/max of the mono mixdown at three hops (storage.md section 2), computed in one streamed
/// decode; coarser levels are folded from the finest.
struct PeaksFile: Codable, Sendable {
    struct Level: Codable, Sendable {
        var hop: Int
        var min: [Float]
        var max: [Float]
    }

    var version: Int
    var sampleRate: Int
    var firstSample: Int64
    var frames: Int64
    var levels: [Level]
}

/// Computes, caches, and serves waveform peaks. Shared by `PeaksWaveformProvider` (the timeline) and
/// `AppleMediaAnalyzer.waveformPeaks` (whole-file peaks at a zoom). Requests finer than the finest cached level
/// decode just the requested range instead.
public final class PeaksStore: Sendable {
    struct Parameters: Hashable, Sendable, Codable {
        var hops: [Int]
    }

    public static let version = 1
    /// Source samples per pair at each cached level: 10.7 ms, 171 ms, and 2.7 s at 48 kHz.
    public static let defaultHops = [512, 8192, 131_072]

    public let cache: CacheIndex
    public let hops: [Int]
    private let clock: any Clock
    private let memo = Mutex<[String: PeaksFile]>([:])
    private let memoLimit = 16

    public init(cache: CacheIndex, hops: [Int] = PeaksStore.defaultHops, clock: any Clock = SystemClock()) {
        self.cache = cache
        self.hops = hops.sorted()
        self.clock = clock
    }

    var parameters: Parameters { Parameters(hops: hops) }

    func paramsHash() throws -> String { try MediaKit.paramsHash(version: PeaksStore.version, parameters: parameters) }

    func cacheKey(contentHash: String) throws -> String {
        AnalysisCacheKey.make(contentHash: contentHash, kind: .peaks, paramsHash: try paramsHash())
    }

    /// The cached peaks file, computing it on a miss. `hit` reports whether the artifact already existed.
    func peaksFile(for media: MediaReference) async throws -> (file: PeaksFile, hit: Bool) {
        if let memoized = memo.withLock({ $0[media.contentHash] }) { return (memoized, true) }
        let params = try paramsHash()
        if let record = try cache.artifact(contentHash: media.contentHash, kind: .peaks, paramsHash: params) {
            let url = cache.url(for: record)
            if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(PeaksFile.self, from: data),
                file.version == PeaksStore.version
            {
                remember(media.contentHash, file)
                return (file, true)
            }
            try cache.removeArtifact(contentHash: media.contentHash, kind: .peaks, paramsHash: params)
        }
        let file = try await compute(media)
        let dir = cache.layout.artifactDir(contentHash: media.contentHash)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("peaks.json")
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
        let now = clock.now()
        try cache.ensureMedia(contentHash: media.contentHash, url: media.url, now: now)
        try cache.recordArtifact(
            contentHash: media.contentHash, kind: .peaks, paramsHash: params,
            path: cache.artifactPath(contentHash: media.contentHash, name: "peaks.json"),
            summary: .object([
                "sampleRate": .number(Double(file.sampleRate)), "frames": .number(Double(file.frames)),
                "hops": .array(hops.map { .number(Double($0)) }),
            ]), now: now)
        remember(media.contentHash, file)
        return (file, false)
    }

    private func remember(_ hash: String, _ file: PeaksFile) {
        memo.withLock { memo in
            if memo.count >= memoLimit, let victim = memo.keys.first { memo.removeValue(forKey: victim) }
            memo[hash] = file
        }
    }

    private func compute(_ media: MediaReference) async throws -> PeaksFile {
        let fine = hops[0]
        var mins: [Float] = []
        var maxs: [Float] = []
        var curMin = Float.greatestFiniteMagnitude
        var curMax = -Float.greatestFiniteMagnitude
        var filled = 0
        let info = try await AudioDecoder.readMono(url: media.url) { samples in
            for v in samples {
                if v < curMin { curMin = v }
                if v > curMax { curMax = v }
                filled += 1
                if filled == fine {
                    mins.append(curMin)
                    maxs.append(curMax)
                    curMin = .greatestFiniteMagnitude
                    curMax = -.greatestFiniteMagnitude
                    filled = 0
                }
            }
        }
        if filled > 0 {
            mins.append(curMin)
            maxs.append(curMax)
        }
        var levels = [PeaksFile.Level(hop: fine, min: mins.map(PeaksStore.round), max: maxs.map(PeaksStore.round))]
        for hop in hops.dropFirst() {
            let base = levels[levels.count - 1]
            let factor = max(1, hop / base.hop)
            let level = PeaksStore.fold(base, factor: factor, hop: hop)
            levels.append(level)
        }
        return PeaksFile(
            version: PeaksStore.version, sampleRate: Int(info.sampleRate), firstSample: info.firstSample,
            frames: info.framesDecoded, levels: levels)
    }

    static func fold(_ level: PeaksFile.Level, factor: Int, hop: Int) -> PeaksFile.Level {
        let count = (level.min.count + factor - 1) / factor
        var mins = [Float](repeating: 0, count: count)
        var maxs = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let range = i * factor..<Swift.min((i + 1) * factor, level.min.count)
            mins[i] = level.min[range].min() ?? 0
            maxs[i] = level.max[range].max() ?? 0
        }
        return PeaksFile.Level(hop: hop, min: mins, max: maxs)
    }

    /// Four decimals keep `peaks.json` compact; the timeline draws at most a few hundred pixels tall.
    static func round(_ v: Float) -> Float { (v * 10000).rounded() / 10000 }

    /// Peaks over `range` (nil: the whole file) at `samplesPerPixel`. Returns the nearest cached level folded to
    /// a multiple of its hop, or a direct decode of the range when the request is finer than the finest level.
    public func peaks(for media: MediaReference, range: ClosedRange<RationalTime>?, samplesPerPixel: Int) async throws
        -> WaveformPeaks
    {
        let spp = max(1, samplesPerPixel)
        let (file, _) = try await peaksFile(for: media)
        let sampleRate = file.sampleRate
        let startSample =
            range.map { Int64(($0.lowerBound.seconds * Double(sampleRate)).rounded()) } ?? file.firstSample
        let endSample =
            range.map { Int64(($0.upperBound.seconds * Double(sampleRate)).rounded()) } ?? file.firstSample
            + file.frames
        guard let level = file.levels.last(where: { $0.hop <= spp }) else {
            return try await decodeRange(media, file: file, startSample: startSample, endSample: endSample, hop: spp)
        }
        let factor = max(1, spp / level.hop)
        let hop = factor * level.hop
        let first = Swift.max(0, Int((startSample - file.firstSample) / Int64(hop)))
        let last = Int((Swift.max(endSample, startSample) - file.firstSample + Int64(hop) - 1) / Int64(hop))
        var mins: [Float] = []
        var maxs: [Float] = []
        mins.reserveCapacity(Swift.max(0, last - first))
        maxs.reserveCapacity(Swift.max(0, last - first))
        var i = first
        while i < last {
            try Task.checkCancellation()
            let lo = i * factor
            let hi = Swift.min((i + 1) * factor, level.min.count)
            if lo < hi {
                mins.append(level.min[lo..<hi].min() ?? 0)
                maxs.append(level.max[lo..<hi].max() ?? 0)
            } else {
                break
            }
            i += 1
        }
        return WaveformPeaks(
            sampleRate: sampleRate, hop: hop, startSample: file.firstSample + Int64(first) * Int64(hop), min: mins,
            max: maxs)
    }

    private func decodeRange(
        _ media: MediaReference, file: PeaksFile, startSample: Int64, endSample: Int64, hop: Int
    ) async throws -> WaveformPeaks {
        let sampleRate = Double(file.sampleRate)
        let alignedStart = (startSample / Int64(hop)) * Int64(hop)
        let cmRange = CMTimeRange(
            start: CMTime(value: alignedStart, timescale: CMTimeScale(sampleRate)),
            end: CMTime(value: Swift.max(endSample, alignedStart + Int64(hop)), timescale: CMTimeScale(sampleRate)))
        var mins: [Float] = []
        var maxs: [Float] = []
        var curMin = Float.greatestFiniteMagnitude
        var curMax = -Float.greatestFiniteMagnitude
        var filled = 0
        let info = try await AudioDecoder.readMono(url: media.url, range: cmRange) { samples in
            for v in samples {
                if v < curMin { curMin = v }
                if v > curMax { curMax = v }
                filled += 1
                if filled == hop {
                    mins.append(curMin)
                    maxs.append(curMax)
                    curMin = .greatestFiniteMagnitude
                    curMax = -.greatestFiniteMagnitude
                    filled = 0
                }
            }
        }
        if filled > 0 {
            mins.append(curMin)
            maxs.append(curMax)
        }
        return WaveformPeaks(sampleRate: file.sampleRate, hop: hop, startSample: info.firstSample, min: mins, max: maxs)
    }
}

/// The timeline's `WaveformProvider` over `PeaksStore`.
public final class PeaksWaveformProvider: WaveformProvider, Sendable {
    public let store: PeaksStore

    public init(store: PeaksStore) { self.store = store }

    public convenience init(cache: CacheIndex) { self.init(store: PeaksStore(cache: cache)) }

    public func peaks(for media: MediaReference, range: ClosedRange<RationalTime>, samplesPerPixel: Int) async throws
        -> WaveformPeaks
    {
        try await store.peaks(for: media, range: range, samplesPerPixel: samplesPerPixel)
    }
}
