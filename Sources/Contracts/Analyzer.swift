import Foundation
import TimelineCore

/// The derived artifacts MediaKit produces and `recordAssetAnalysis` records (`Asset.analyses` is keyed
/// by the raw value). Matches the artifact kinds of storage.md section 11.
public enum AnalysisKind: String, Codable, Sendable, Hashable, CaseIterable {
    case probe
    case transcript
    case silence
    case shots
    case peaks
    case onsetEnvelope = "onset-8k"
    case thumbnails
    case loudness
    case alignment
}

/// `<contentHash>/<kind>/<paramsHash>`: the cache key recorded on the asset and used by the cache index
/// (`artifacts` primary key is the same triple). `paramsHash` covers the generator version plus its
/// parameters, so a change to either invalidates the artifact.
public enum AnalysisCacheKey {
    public static func make(contentHash: String, kind: AnalysisKind, paramsHash: String) -> String {
        "\(contentHash)/\(kind.rawValue)/\(paramsHash)"
    }

    public static func make<P: Encodable>(contentHash: String, kind: AnalysisKind, version: Int, parameters: P) throws
        -> String
    {
        let params = try StableHash.fnv1a(encoding: parameters)
        return make(contentHash: contentHash, kind: kind, paramsHash: "v\(version)-\(params)")
    }
}

// MARK: - Transcript

public struct TranscriptWord: Hashable, Sendable, Codable {
    public var text: String
    /// Media-relative times. From SpeechAnalyzer they sit on a 60 ms grid and a word's `t1` equals the
    /// next word's `t0` (or the pause start), not the acoustic offset.
    public var t0: RationalTime
    public var t1: RationalTime
    /// 0...1; SpeechAnalyzer flags doubtful proper nouns at 0.44-0.58.
    public var confidence: Double
    public var speaker: String?

    public init(text: String, t0: RationalTime, t1: RationalTime, confidence: Double, speaker: String? = nil) {
        self.text = text
        self.t0 = t0
        self.t1 = t1
        self.confidence = confidence
        self.speaker = speaker
    }
}

/// A phrase-sized result as the engine emitted it (SpeechAnalyzer: about 1.3 s each), with alternatives.
public struct TranscriptSegment: Hashable, Sendable, Codable {
    public var text: String
    public var range: TimeRange
    public var alternatives: [String]

    public init(text: String, range: TimeRange, alternatives: [String] = []) {
        self.text = text
        self.range = range
        self.alternatives = alternatives
    }
}

public struct Transcript: Hashable, Sendable, Codable {
    public var words: [TranscriptWord]
    public var segments: [TranscriptSegment]
    /// BCP-47 tag of the locale used.
    public var language: String
    /// "speechanalyzer", "whisperkit", ...
    public var engine: String
    public var cacheKey: String

    public init(
        words: [TranscriptWord], segments: [TranscriptSegment] = [], language: String, engine: String, cacheKey: String
    ) {
        self.words = words
        self.segments = segments
        self.language = language
        self.engine = engine
        self.cacheKey = cacheKey
    }

    public var text: String { words.map(\.text).joined(separator: " ") }
}

public struct TranscriptionOptions: Hashable, Sendable, Codable {
    /// Ask for speaker labels (needs a diarising engine; SpeechAnalyzer has none).
    public var speakerLabels: Bool
    /// Names and terms to bias recognition toward (SpeechAnalyzer: `SFCustomLanguageModelData`; Whisper: prompt).
    public var vocabulary: [String]
    /// Keep the engine's phrase alternatives in `segments`.
    public var alternatives: Bool

    public init(speakerLabels: Bool = false, vocabulary: [String] = [], alternatives: Bool = false) {
        self.speakerLabels = speakerLabels
        self.vocabulary = vocabulary
        self.alternatives = alternatives
    }
}

// MARK: - Silence, shots, envelope

public struct SilenceParameters: Hashable, Sendable, Codable {
    public var thresholdDB: Double
    public var minimumDurationSeconds: Double

    public init(thresholdDB: Double = -40, minimumDurationSeconds: Double = 0.5) {
        self.thresholdDB = thresholdDB
        self.minimumDurationSeconds = minimumDurationSeconds
    }
}

public struct SilenceRanges: Hashable, Sendable, Codable {
    public var ranges: [TimeRange]
    public var parameters: SilenceParameters
    public var cacheKey: String

    public init(ranges: [TimeRange], parameters: SilenceParameters, cacheKey: String) {
        self.ranges = ranges
        self.parameters = parameters
        self.cacheKey = cacheKey
    }
}

public struct ShotParameters: Hashable, Sendable, Codable {
    /// 0...1 frame-difference threshold for a cut.
    public var threshold: Double
    public var minimumShotSeconds: Double

    public init(threshold: Double = 0.3, minimumShotSeconds: Double = 0.5) {
        self.threshold = threshold
        self.minimumShotSeconds = minimumShotSeconds
    }
}

public struct Shot: Hashable, Sendable, Codable {
    public var range: TimeRange
    /// A representative frame inside the shot.
    public var keyframeAt: RationalTime

    public init(range: TimeRange, keyframeAt: RationalTime) {
        self.range = range
        self.keyframeAt = keyframeAt
    }
}

public struct ShotList: Hashable, Sendable, Codable {
    public var shots: [Shot]
    public var parameters: ShotParameters
    public var cacheKey: String

    public init(shots: [Shot], parameters: ShotParameters, cacheKey: String) {
        self.shots = shots
        self.parameters = parameters
        self.cacheKey = cacheKey
    }
}

/// The onset envelope the aligner's coarse pass correlates: one Float32 per `hop` samples at
/// `sampleRate` (defaults 8000 / 128, i.e. 62.5 frames per second). Cached as `onset-8k.f32`
/// (little-endian Float32); `url` points at that file when it exists, `samples` carries the values
/// when the caller asked for them in memory. At least one is set.
public struct OnsetEnvelope: Hashable, Sendable, Codable {
    public var url: URL?
    public var samples: [Float]?
    public var sampleRate: Int
    public var hop: Int
    public var frameCount: Int
    public var cacheKey: String

    public init(url: URL? = nil, samples: [Float]? = nil, sampleRate: Int, hop: Int, frameCount: Int, cacheKey: String)
    {
        precondition(url != nil || samples != nil, "An OnsetEnvelope carries a file or samples")
        self.url = url
        self.samples = samples
        self.sampleRate = sampleRate
        self.hop = hop
        self.frameCount = frameCount
        self.cacheKey = cacheKey
    }

    /// The `AudioSource` the aligner consumes, when the envelope is on disk.
    public func audioSource(audioURL: URL, contentHash: String) -> AudioSource? {
        url.map { .envelope($0, audioURL: audioURL, contentHash: contentHash) }
    }
}

public enum AnalysisError: Error, Hashable, Sendable, Codable {
    case unsupportedLocale(String)
    case noAudioTrack
    case noVideoTrack
    case engineUnavailable(String)
    case failed(String)
}

// MARK: - Protocol

/// The senses pipeline behind one door. One protocol rather than five because the implementation owns
/// shared state every method needs (the cache index, the five SpeechAnalyzer locale reservation slots,
/// the memory budget) and because tools and the App resolve a single `analyzer` service; the fake is
/// one object with fixtures per method. Every method is pure `nonisolated async` work, cancellable
/// through task cancellation, and returns a `cacheKey` the caller records with `recordAssetAnalysis`.
///
/// Measured facts the implementation lives by (spikes/speech): SpeechAnalyzer runs about 65x realtime
/// with the model out of process (100-300 MB system-side, 20 MB in the client); locale assets are
/// about 85 MB and download silently; a process may reserve at most 5 locales, so `transcribe` reserves
/// on entry and releases on exit; `results` must be consumed concurrently with `analyzeSequence`; the
/// ranges on volatile results are bogus and ignored.
public protocol MediaAnalyzer: Sendable {
    func transcribe(_ media: MediaReference, locale: Locale, options: TranscriptionOptions) async throws -> Transcript

    func detectSilence(_ media: MediaReference, parameters: SilenceParameters) async throws -> SilenceRanges

    func detectShots(_ media: MediaReference, parameters: ShotParameters) async throws -> ShotList

    /// Peaks over the whole file at `samplesPerPixel`, what the cache stores per zoom level.
    func waveformPeaks(_ media: MediaReference, samplesPerPixel: Int) async throws -> WaveformPeaks

    /// The 8 kHz onset envelope at the alignment parameters' rate and hop, streamed so a 2-hour file is
    /// never resident.
    func onsetEnvelope(_ media: MediaReference, parameters: AlignmentParameters) async throws -> OnsetEnvelope
}
