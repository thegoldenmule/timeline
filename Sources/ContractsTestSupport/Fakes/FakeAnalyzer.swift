import Contracts
import Foundation
import Synchronization
import TimelineCore

/// A `MediaAnalyzer` returning fixtures. Each method records its call, honours task cancellation, sleeps
/// for `delay` when set, and throws `error` when set; results default to `AnalysisFixtures` values keyed
/// by the media's content hash.
public final class FakeAnalyzer: MediaAnalyzer, Sendable {
    public enum Call: Sendable, Hashable {
        case transcribe(MediaReference, locale: String, options: TranscriptionOptions)
        case detectSilence(MediaReference, SilenceParameters)
        case detectShots(MediaReference, ShotParameters)
        case waveformPeaks(MediaReference, samplesPerPixel: Int)
        case onsetEnvelope(MediaReference)
    }

    private struct State {
        var calls: [Call] = []
        var transcript: Transcript?
        var silence: SilenceRanges?
        var shots: ShotList?
        var envelope: OnsetEnvelope?
        var error: AnalysisError?
        var delay: Duration?
    }

    private let state = Mutex(State())

    public init(delay: Duration? = nil) {
        state.withLock { $0.delay = delay }
    }

    public var calls: [Call] { state.withLock { $0.calls } }

    public func setTranscript(_ value: Transcript?) { state.withLock { $0.transcript = value } }
    public func setSilence(_ value: SilenceRanges?) { state.withLock { $0.silence = value } }
    public func setShots(_ value: ShotList?) { state.withLock { $0.shots = value } }
    public func setEnvelope(_ value: OnsetEnvelope?) { state.withLock { $0.envelope = value } }
    public func fail(with error: AnalysisError?) { state.withLock { $0.error = error } }

    private func gate() async throws {
        try Task.checkCancellation()
        if let delay = state.withLock({ $0.delay }) { try await Task.sleep(for: delay) }
        if let error = state.withLock({ $0.error }) { throw error }
    }

    public func transcribe(_ media: MediaReference, locale: Locale, options: TranscriptionOptions) async throws
        -> Transcript
    {
        state.withLock { $0.calls.append(.transcribe(media, locale: locale.identifier, options: options)) }
        try await gate()
        return state.withLock { $0.transcript }
            ?? AnalysisFixtures.transcript(contentHash: media.contentHash, language: locale.identifier)
    }

    public func detectSilence(_ media: MediaReference, parameters: SilenceParameters) async throws -> SilenceRanges {
        state.withLock { $0.calls.append(.detectSilence(media, parameters)) }
        try await gate()
        return state.withLock { $0.silence }
            ?? AnalysisFixtures.silence(contentHash: media.contentHash, parameters: parameters)
    }

    public func detectShots(_ media: MediaReference, parameters: ShotParameters) async throws -> ShotList {
        state.withLock { $0.calls.append(.detectShots(media, parameters)) }
        try await gate()
        return state.withLock { $0.shots }
            ?? AnalysisFixtures.shots(contentHash: media.contentHash, parameters: parameters)
    }

    public func waveformPeaks(_ media: MediaReference, samplesPerPixel: Int) async throws -> WaveformPeaks {
        state.withLock { $0.calls.append(.waveformPeaks(media, samplesPerPixel: samplesPerPixel)) }
        try await gate()
        return FakeWaveformProvider.sinePeaks(
            sampleRate: 48000, range: .zero...RationalTime(10, 1), samplesPerPixel: max(1, samplesPerPixel))
    }

    public func onsetEnvelope(_ media: MediaReference, parameters: AlignmentParameters) async throws -> OnsetEnvelope {
        state.withLock { $0.calls.append(.onsetEnvelope(media)) }
        try await gate()
        return state.withLock { $0.envelope }
            ?? AnalysisFixtures.onsetEnvelope(contentHash: media.contentHash, parameters: parameters)
    }
}

/// Fixture analysis results with plausible shapes and cache keys.
public enum AnalysisFixtures {
    static let grid = RationalTime(3, 50)  // 60 ms, SpeechAnalyzer's grid

    public static func transcript(contentHash: String = "sha256-0123abcd", language: String = "en_US") -> Transcript {
        let texts = ["Welcome", "to", "the", "Timeline", "Video", "Editor", "Spike."]
        let ends: [Int64] = [8, 10, 12, 19, 26, 33, 42]
        let confidences = [0.997, 0.998, 0.971, 0.875, 0.575, 0.651, 0.953]
        var words: [TranscriptWord] = []
        var t0: Int64 = 0
        for (i, text) in texts.enumerated() {
            words.append(
                TranscriptWord(
                    text: text, t0: RationalTime.frames(t0, of: grid), t1: RationalTime.frames(ends[i], of: grid),
                    confidence: confidences[i]))
            t0 = ends[i]
        }
        let segments = [
            TranscriptSegment(
                text: "Welcome to the", range: TimeRange(start: .zero, end: RationalTime.frames(12, of: grid))),
            TranscriptSegment(
                text: "Timeline Video Editor Spike.",
                range: TimeRange(start: RationalTime.frames(12, of: grid), end: RationalTime.frames(42, of: grid)),
                alternatives: ["Timeline video editor spike."]),
        ]
        return Transcript(
            words: words, segments: segments, language: language, engine: "fake",
            cacheKey: AnalysisCacheKey.make(contentHash: contentHash, kind: .transcript, paramsHash: "fake-v1"))
    }

    public static func silence(
        contentHash: String = "sha256-0123abcd", parameters: SilenceParameters = SilenceParameters()
    )
        -> SilenceRanges
    {
        SilenceRanges(
            ranges: [
                TimeRange(start: .zero, end: RationalTime(1, 2)),
                TimeRange(start: RationalTime(9, 2), end: RationalTime(6, 1)),
            ],
            parameters: parameters,
            cacheKey: AnalysisCacheKey.make(contentHash: contentHash, kind: .silence, paramsHash: "fake-v1"))
    }

    public static func shots(contentHash: String = "sha256-0123abcd", parameters: ShotParameters = ShotParameters())
        -> ShotList
    {
        let fd = RationalTime(1001, 24000)
        func shot(_ a: Int64, _ b: Int64) -> Shot {
            Shot(
                range: TimeRange(start: RationalTime.frames(a, of: fd), end: RationalTime.frames(b, of: fd)),
                keyframeAt: RationalTime.frames((a + b) / 2, of: fd))
        }
        return ShotList(
            shots: [shot(0, 96), shot(96, 144), shot(144, 264)], parameters: parameters,
            cacheKey: AnalysisCacheKey.make(contentHash: contentHash, kind: .shots, paramsHash: "fake-v1"))
    }

    /// A 10-second envelope with a click every half second, in memory.
    public static func onsetEnvelope(
        contentHash: String = "sha256-0123abcd", parameters: AlignmentParameters = AlignmentParameters(),
        seconds: Double = 10
    ) -> OnsetEnvelope {
        let fps = Double(parameters.envelopeSampleRate) / Double(parameters.envelopeHop)
        let count = Int(seconds * fps)
        let period = Int(fps / 2)
        let samples = (0..<count).map { i -> Float in i % max(period, 1) == 0 ? 1 : 0.02 }
        return OnsetEnvelope(
            samples: samples, sampleRate: parameters.envelopeSampleRate, hop: parameters.envelopeHop, frameCount: count,
            cacheKey: AnalysisCacheKey.make(contentHash: contentHash, kind: .onsetEnvelope, paramsHash: "fake-v1"))
    }
}
