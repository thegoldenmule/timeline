import Foundation
import TimelineCore

/// Where an aligner reads audio from. Long recordings are consumed as streams; nothing here
/// implies the whole file is resident.
public enum AudioSource: Sendable, Hashable {
    /// Decode the audio track of a media file (video or audio) on demand.
    case file(URL, contentHash: String?)
    /// A precomputed onset envelope at `AlignmentParameters.envelopeSampleRate` / `envelopeHop`
    /// (little-endian Float32, one value per hop), as MediaKit caches under `onset-8k.f32`.
    /// The aligner still needs `audioURL` for the fine pass.
    case envelope(URL, audioURL: URL, contentHash: String)

    public var contentHash: String? {
        switch self {
        case .file(_, let hash): hash
        case .envelope(_, _, let hash): hash
        }
    }
}

/// One coarse candidate, refined and verified by the fine pass.
public struct AlignmentCandidate: Codable, Sendable, Hashable {
    /// Offset of the target's start relative to the reference's start (positive: target starts later).
    /// Expressed at `referenceSampleRate * 1000` (48,000,000 per second for a 48 kHz reference) so the
    /// sub-sample residual of the parabolic interpolation survives in a `RationalTime`.
    public var offset: RationalTime
    /// Positive when the target clock runs fast: target time `t` maps to reference time
    /// `offset + t / (1 + driftPPM * 1e-6)`. Correct by resampling the target by `1 + driftPPM * 1e-6`.
    public var driftPPM: Double
    /// Fine-pass verification signal in 0...1 (inlier fraction weighted by fit residual), not the coarse peak ratio.
    public var confidence: Double
    public var verified: Bool
    /// Normalised cross-correlation score of the coarse peak, for diagnostics.
    public var coarseScore: Double
    public var inlierFraction: Double
    public var fitMADMs: Double

    public init(
        offset: RationalTime, driftPPM: Double, confidence: Double, verified: Bool,
        coarseScore: Double, inlierFraction: Double, fitMADMs: Double
    ) {
        self.offset = offset
        self.driftPPM = driftPPM
        self.confidence = confidence
        self.verified = verified
        self.coarseScore = coarseScore
        self.inlierFraction = inlierFraction
        self.fitMADMs = fitMADMs
    }
}

/// Data behind the proof image the UI and the `align_audio` tool draw: the coarse correlation
/// curve (downsampled) and the per-window fine offsets with the drift line fitted through them.
public struct AlignmentProof: Codable, Sendable, Hashable {
    /// The coarse NCC curve max-pooled to `AlignmentParameters.proofCorrelationPoints` so peaks survive;
    /// `correlationLagStepSeconds` is the pooled step.
    public var correlation: [Float]
    public var correlationLagStartSeconds: Double
    public var correlationLagStepSeconds: Double
    public var windowTimesSeconds: [Double]
    /// Absolute reference positions (ms) of target sample 0 implied by each fine window; the fitted line
    /// is `fitInterceptMs - fitSlopePPM * 1e-3 * windowTimesSeconds`.
    public var windowOffsetsMs: [Double]
    public var windowInliers: [Bool]
    public var fitSlopePPM: Double
    public var fitInterceptMs: Double

    public init(
        correlation: [Float], correlationLagStartSeconds: Double, correlationLagStepSeconds: Double,
        windowTimesSeconds: [Double], windowOffsetsMs: [Double], windowInliers: [Bool],
        fitSlopePPM: Double, fitInterceptMs: Double
    ) {
        self.correlation = correlation
        self.correlationLagStartSeconds = correlationLagStartSeconds
        self.correlationLagStepSeconds = correlationLagStepSeconds
        self.windowTimesSeconds = windowTimesSeconds
        self.windowOffsetsMs = windowOffsetsMs
        self.windowInliers = windowInliers
        self.fitSlopePPM = fitSlopePPM
        self.fitInterceptMs = fitInterceptMs
    }
}

/// Result of aligning `target` against `reference`. Derived data: cached by content hashes and
/// `parametersHash`, never an event.
public struct Alignment: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        /// Exactly one verified candidate.
        case aligned
        /// More than one verified candidate (repeated material); the user or agent picks.
        case ambiguous
        /// No candidate verified; `offset` is nil rather than a wrong answer.
        case failed
    }

    public var status: Status
    /// The best verified candidate's offset (see `AlignmentCandidate.offset` for its timescale), or nil
    /// when `status == .failed`.
    public var offset: RationalTime?
    /// See `AlignmentCandidate.driftPPM`.
    public var driftPPM: Double
    public var confidence: Double
    /// All candidates, best first.
    public var candidates: [AlignmentCandidate]
    public var proof: AlignmentProof?
    public var referenceHash: String?
    public var targetHash: String?
    /// Hash of the aligner version plus the `AlignmentParameters` used (the cache key's last part).
    public var parametersHash: String
    public var elapsedSeconds: Double

    public init(
        status: Status, offset: RationalTime?, driftPPM: Double, confidence: Double,
        candidates: [AlignmentCandidate], proof: AlignmentProof?, referenceHash: String?,
        targetHash: String?, parametersHash: String, elapsedSeconds: Double
    ) {
        self.status = status
        self.offset = offset
        self.driftPPM = driftPPM
        self.confidence = confidence
        self.candidates = candidates
        self.proof = proof
        self.referenceHash = referenceHash
        self.targetHash = targetHash
        self.parametersHash = parametersHash
        self.elapsedSeconds = elapsedSeconds
    }
}

/// Aligns a target recording (typically a short DAW render) inside a reference recording
/// (typically a long camera track). Pure work: `nonisolated async`, cancellable through task
/// cancellation, and it never retimes the reference.
public protocol AudioAligner: Sendable {
    func align(
        reference: AudioSource, target: AudioSource, parameters: AlignmentParameters
    ) async throws -> Alignment
}
