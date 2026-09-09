import AVFoundation
import Contracts
import CoreImage
import Foundation
import TimelineCore

/// The senses pipeline on Apple frameworks: SpeechAnalyzer transcription, RMS silence detection, histogram shot
/// detection, waveform peaks, and the streamed 8 kHz onset envelope. Every result is content-addressed under
/// `Cache/sha256/ab/cd/<hash>/`, keyed by `(contentHash, kind, paramsHash)` in `cache.sqlite`, and returned with
/// the cache key the caller records through `MediaKit.analysisOperation`. Unchanged parameters hit the cache;
/// a changed parameter or generator version produces a new artifact. Every method honours task cancellation.
public final class AppleMediaAnalyzer: MediaAnalyzer, Sendable {
    public let cache: CacheIndex
    public let peaksStore: PeaksStore
    private let clock: any Clock
    private let reservations = LocaleReservations()

    public var layout: LibraryLayout { cache.layout }

    public init(cache: CacheIndex, clock: any Clock = SystemClock()) {
        self.cache = cache
        self.peaksStore = PeaksStore(cache: cache, clock: clock)
        self.clock = clock
    }

    // MARK: Cache plumbing

    struct CacheSlot {
        var paramsHash: String
        var cacheKey: String
        var url: URL
        var relativePath: String
        var existing: ArtifactRecord?
    }

    private func slot<P: Encodable>(
        _ media: MediaReference, kind: AnalysisKind, version: Int, parameters: P, file: String
    )
        throws -> CacheSlot
    {
        let paramsHash = try MediaKit.paramsHash(version: version, parameters: parameters)
        let dir = layout.artifactDir(contentHash: media.contentHash)
        let record = try cache.artifact(contentHash: media.contentHash, kind: kind, paramsHash: paramsHash)
        var existing: ArtifactRecord?
        if let record {
            if FileManager.default.fileExists(atPath: cache.url(for: record).path) {
                existing = record
            } else {
                try cache.removeArtifact(contentHash: media.contentHash, kind: kind, paramsHash: paramsHash)
            }
        }
        return CacheSlot(
            paramsHash: paramsHash,
            cacheKey: AnalysisCacheKey.make(contentHash: media.contentHash, kind: kind, paramsHash: paramsHash),
            url: dir.appendingPathComponent(file),
            relativePath: cache.artifactPath(contentHash: media.contentHash, name: file),
            existing: existing)
    }

    private func store<T: Encodable>(
        _ value: T, in slot: CacheSlot, media: MediaReference, kind: AnalysisKind, summary: JSONValue?
    )
        throws
    {
        try FileManager.default.createDirectory(
            at: slot.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: slot.url, options: .atomic)
        try record(slot, media: media, kind: kind, summary: summary)
    }

    private func record(_ slot: CacheSlot, media: MediaReference, kind: AnalysisKind, summary: JSONValue?) throws {
        let now = clock.now()
        try cache.ensureMedia(contentHash: media.contentHash, url: media.url, now: now)
        try cache.recordArtifact(
            contentHash: media.contentHash, kind: kind, paramsHash: slot.paramsHash, path: slot.relativePath,
            summary: summary, now: now)
    }

    private func load<T: Decodable>(_ type: T.Type, from slot: CacheSlot) -> T? {
        guard slot.existing != nil, let data = try? Data(contentsOf: slot.url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: Transcription

    public func transcribe(_ media: MediaReference, locale: Locale, options: TranscriptionOptions) async throws
        -> Transcript
    {
        try await transcribe(media, locale: locale, options: options, progress: nil)
    }

    /// `transcribe` with progress (model download, then analysis).
    public func transcribe(
        _ media: MediaReference, locale: Locale, options: TranscriptionOptions,
        progress: (@Sendable (JobProgress) -> Void)?
    ) async throws -> Transcript {
        let parameters = SpeechEngine.Parameters(locale: LocaleReservations.key(locale), options: options)
        let slot = try slot(
            media, kind: .transcript, version: SpeechEngine.version, parameters: parameters, file: "transcript.json")
        if var cached = load(Transcript.self, from: slot) {
            cached.cacheKey = slot.cacheKey
            return cached
        }
        let inspection = try await MediaProbe.inspect(media.url)
        guard inspection.hasAudio else { throw AnalysisError.noAudioTrack }

        // SpeechAnalyzer reads through AVAudioFile, which takes the first audio track; a multi-track file (iPhone
        // stereo AAC plus Spatial Audio) is first folded to the primary track as a temporary CAF.
        var audioURL = media.url
        var temporary: URL?
        if inspection.audioTracks.count > 1 || (try? AVAudioFile(forReading: media.url)) == nil {
            let dir = layout.artifactDir(contentHash: media.contentHash)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let caf = dir.appendingPathComponent("transcribe-input-\(UUID().uuidString.prefix(8)).caf")
            progress?(JobProgress(fraction: 0, stage: "extract"))
            _ = try await AudioDecoder.extractMono(url: media.url, to: caf)
            audioURL = caf
            temporary = caf
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        let output = try await SpeechEngine.transcribe(
            audioURL: audioURL, locale: locale, options: options, reservations: reservations, progress: progress)
        try Task.checkCancellation()
        let transcript = Transcript(
            words: output.words, segments: output.segments, language: output.language, engine: "speechanalyzer",
            cacheKey: slot.cacheKey)
        var summary: [String: JSONValue] = [
            "words": .number(Double(transcript.words.count)), "segments": .number(Double(transcript.segments.count)),
            "language": .string(transcript.language), "elapsedSeconds": .number(output.elapsedSeconds),
        ]
        if let download = output.downloadSeconds { summary["downloadSeconds"] = .number(download) }
        try store(transcript, in: slot, media: media, kind: .transcript, summary: .object(summary))
        try cache.replaceTranscriptWords(contentHash: media.contentHash, words: transcript.words)
        return transcript
    }

    /// Locales `transcribe` reserved and has not yet released (empty between transcriptions).
    func heldLocales() async -> [String] { await reservations.heldLocales() }

    /// FTS5 search over every indexed transcript, optionally restricted to the given files.
    public func searchTranscript(_ query: String, contentHashes: [String]? = nil, limit: Int = 200) throws
        -> [TranscriptHit]
    {
        try cache.searchTranscript(query, contentHashes: contentHashes, limit: limit)
    }

    // MARK: Silence

    struct SilenceComputeParameters: Hashable, Sendable, Codable {
        var thresholdDB: Double
        var minimumDurationSeconds: Double
        var windowSeconds: Double = AppleMediaAnalyzer.silenceWindowSeconds
    }

    static let silenceVersion = 1
    /// RMS window; ranges are reported to this resolution.
    static let silenceWindowSeconds = 0.01

    public func detectSilence(_ media: MediaReference, parameters: SilenceParameters) async throws -> SilenceRanges {
        let compute = SilenceComputeParameters(
            thresholdDB: parameters.thresholdDB, minimumDurationSeconds: parameters.minimumDurationSeconds)
        let slot = try slot(
            media, kind: .silence, version: AppleMediaAnalyzer.silenceVersion, parameters: compute, file: "silence.json"
        )
        if var cached = load(SilenceRanges.self, from: slot) {
            cached.cacheKey = slot.cacheKey
            return cached
        }
        var windowRMS: [Float] = []
        var window = 0
        var sum: Double = 0
        var count = 0
        var rate = 48000.0
        var firstWindow = true
        let info = try await AudioDecoder.readMono(url: media.url) { samples in
            if firstWindow {
                firstWindow = false
            }
            for v in samples {
                sum += Double(v * v)
                count += 1
                if count == window { windowRMS.append(Float((sum / Double(count)).squareRoot())); sum = 0; count = 0 }
            }
        } configure: { sampleRate in
            rate = sampleRate
            window = max(1, Int((sampleRate * AppleMediaAnalyzer.silenceWindowSeconds).rounded()))
        }
        if count > 0 { windowRMS.append(Float((sum / Double(count)).squareRoot())) }
        let threshold = Float(pow(10, parameters.thresholdDB / 20))
        let minWindows = max(
            1, Int((parameters.minimumDurationSeconds / AppleMediaAnalyzer.silenceWindowSeconds).rounded()))
        let timescale = Int32(rate)
        var ranges: [TimeRange] = []
        var runStart: Int?
        func close(_ end: Int) {
            guard let start = runStart, end - start >= minWindows else { return }
            let s = info.firstSample + Int64(start) * Int64(window)
            let e = Swift.min(info.firstSample + Int64(end) * Int64(window), info.firstSample + info.framesDecoded)
            ranges.append(TimeRange(start: RationalTime(s, timescale), end: RationalTime(e, timescale)))
        }
        for (i, rms) in windowRMS.enumerated() {
            if rms < threshold {
                if runStart == nil { runStart = i }
            } else if runStart != nil {
                close(i)
                runStart = nil
            }
        }
        if runStart != nil { close(windowRMS.count) }
        try Task.checkCancellation()
        let result = SilenceRanges(ranges: ranges, parameters: parameters, cacheKey: slot.cacheKey)
        let total = ranges.reduce(0.0) { $0 + $1.duration.seconds }
        try store(
            result, in: slot, media: media, kind: .silence,
            summary: .object(["count": .number(Double(ranges.count)), "totalSeconds": .number(total)]))
        return result
    }

    // MARK: Shots

    struct ShotComputeParameters: Hashable, Sendable, Codable {
        var threshold: Double
        var minimumShotSeconds: Double
        var gridWidth: Int = AppleMediaAnalyzer.shotGrid.width
        var gridHeight: Int = AppleMediaAnalyzer.shotGrid.height
        var binsPerChannel: Int = AppleMediaAnalyzer.shotBins
    }

    static let shotsVersion = 1
    static let shotGrid = (width: 64, height: 36)
    static let shotBins = 4

    /// Frame-difference of a 4x4x4 RGB histogram over a 64x36 sample grid of every decoded frame (decoded at
    /// reduced size when the decoder allows it). A cut is a difference above `threshold` at least
    /// `minimumShotSeconds` after the previous one; the keyframe is the shot's midpoint.
    public func detectShots(_ media: MediaReference, parameters: ShotParameters) async throws -> ShotList {
        let compute = ShotComputeParameters(
            threshold: parameters.threshold, minimumShotSeconds: parameters.minimumShotSeconds)
        let slot = try slot(
            media, kind: .shots, version: AppleMediaAnalyzer.shotsVersion, parameters: compute, file: "shots.json")
        if var cached = load(ShotList.self, from: slot) {
            cached.cacheKey = slot.cacheKey
            return cached
        }
        let asset = AVURLAsset(url: media.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AnalysisError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let timescale = duration.timescale > 0 ? duration.timescale : 600
        let reader =
            try AppleMediaAnalyzer.videoReader(asset: asset, track: track, scaled: true)
            ?? AppleMediaAnalyzer.videoReader(asset: asset, track: track, scaled: false)
        guard let (reader, output) = reader else { throw AnalysisError.failed("cannot read video") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var cuts: [CMTime] = []
        var previous: [Float]?
        var lastCut = CMTime.zero
        var frameTimes = 0
        var lastTime = CMTime.zero
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let histogram = AppleMediaAnalyzer.histogram(pixels)
            if let previous {
                var distance: Float = 0
                for i in 0..<histogram.count { distance += abs(histogram[i] - previous[i]) }
                distance *= 0.5
                if Double(distance) > parameters.threshold,
                    (time - lastCut).seconds >= parameters.minimumShotSeconds
                {
                    cuts.append(time)
                    lastCut = time
                }
            }
            previous = histogram
            frameTimes += 1
            lastTime = time
        }
        if reader.status == .failed {
            throw AnalysisError.failed(reader.error?.localizedDescription ?? "decode failed")
        }
        let end = duration.isNumeric && duration > lastTime ? duration : lastTime
        var boundaries = [CMTime.zero] + cuts + [end]
        boundaries = boundaries.map { CMTimeConvertScale($0, timescale: timescale, method: .default) }
        var shots: [Shot] = []
        for i in 0..<(boundaries.count - 1) {
            let a = boundaries[i]
            let b = boundaries[i + 1]
            guard b > a else { continue }
            let start = RationalTime(cmValue: a.value, timescale: timescale)
            let stop = RationalTime(cmValue: b.value, timescale: timescale)
            shots.append(Shot(range: TimeRange(start: start, end: stop), keyframeAt: (start + stop) / 2))
        }
        let result = ShotList(shots: shots, parameters: parameters, cacheKey: slot.cacheKey)
        try store(
            result, in: slot, media: media, kind: .shots,
            summary: .object(["count": .number(Double(shots.count)), "frames": .number(Double(frameTimes))]))
        return result
    }

    private static func videoReader(asset: AVURLAsset, track: AVAssetTrack, scaled: Bool) throws
        -> (AVAssetReader, AVAssetReaderTrackOutput)?
    {
        let reader = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if scaled {
            settings[kCVPixelBufferWidthKey as String] = shotGrid.width * 4
            settings[kCVPixelBufferHeightKey as String] = shotGrid.height * 4
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        return (reader, output)
    }

    /// Normalised RGB histogram (`shotBins` per channel) over a `shotGrid` of sample points.
    static func histogram(_ pixels: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let bins = shotBins
        var counts = [Float](repeating: 0, count: bins * bins * bins)
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return counts }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let shift = 8 - bins.trailingZeroBitCount
        for gy in 0..<shotGrid.height {
            let y = min(height - 1, (gy * height + height / 2) / shotGrid.height)
            for gx in 0..<shotGrid.width {
                let x = min(width - 1, (gx * width + width / 2) / shotGrid.width)
                let p = bytes + y * stride + x * 4
                let b = Int(p[0]) >> shift
                let g = Int(p[1]) >> shift
                let r = Int(p[2]) >> shift
                counts[(r * bins + g) * bins + b] += 1
            }
        }
        let total = Float(shotGrid.width * shotGrid.height)
        return counts.map { $0 / total }
    }

    // MARK: Peaks

    public func waveformPeaks(_ media: MediaReference, samplesPerPixel: Int) async throws -> WaveformPeaks {
        try await peaksStore.peaks(for: media, range: nil, samplesPerPixel: samplesPerPixel)
    }

    /// The cache key of the peaks artifact for `media` (`WaveformPeaks` carries none).
    public func peaksCacheKey(for media: MediaReference) throws -> String {
        try peaksStore.cacheKey(contentHash: media.contentHash)
    }

    // MARK: Onset envelope

    public func onsetEnvelope(_ media: MediaReference, parameters: AlignmentParameters) async throws -> OnsetEnvelope {
        let compute = OnsetEnvelopeBuilder.Parameters(parameters)
        let file = "onset-\(compute.sampleRate / 1000)k.f32"
        let slot = try slot(
            media, kind: .onsetEnvelope, version: OnsetEnvelopeBuilder.version, parameters: compute, file: file)
        if slot.existing != nil,
            let size = try? FileManager.default.attributesOfItem(atPath: slot.url.path)[.size] as? Int
        {
            return OnsetEnvelope(
                url: slot.url, sampleRate: compute.sampleRate, hop: compute.hop, frameCount: size / 4,
                cacheKey: slot.cacheKey)
        }
        var builder: OnsetEnvelopeBuilder?
        _ = try await AudioDecoder.readMono(url: media.url) { samples in
            builder?.push(samples)
        } configure: { sampleRate in
            builder = OnsetEnvelopeBuilder(parameters: compute, inputSampleRate: sampleRate)
        }
        guard var builder else { throw AnalysisError.noAudioTrack }
        try Task.checkCancellation()
        let envelope = builder.finish()
        try FileManager.default.createDirectory(
            at: slot.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try OnsetEnvelopeBuilder.encode(envelope).write(to: slot.url, options: .atomic)
        try record(
            slot, media: media, kind: .onsetEnvelope,
            summary: .object([
                "frames": .number(Double(envelope.count)), "sampleRate": .number(Double(compute.sampleRate)),
                "hop": .number(Double(compute.hop)),
            ]))
        return OnsetEnvelope(
            url: slot.url, sampleRate: compute.sampleRate, hop: compute.hop, frameCount: envelope.count,
            cacheKey: slot.cacheKey)
    }
}
