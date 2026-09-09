// AudioAlign: finds where a short target recording (a DAW render) sits inside a long reference recording (a
// camera track), with sub-sample offset, clock drift in ppm, and a verification-based confidence.
//
// Pipeline (see docs/design/implementation-plan.md, spikes/audio-align/SPIKE.md):
//   1. `OnsetEnvelopeBuilder`: stream the audio in chunks, FIR-decimate to `envelopeSampleRate`, bandpass,
//      STFT into log-spaced bands, half-wave-rectified log-power difference, running-median detrend.
//   2. `CoarsePass`: FFT normalised cross-correlation of the two envelopes, candidate list by cutoff ratio.
//   3. `FinePass`: GCC-PHAT on full-rate windows around each candidate, parabolic peak interpolation,
//      Theil-Sen drift line, inlier / MAD verification, then a drift-corrected second pass.
//   4. `OnsetAligner`: orchestration, cancellation, progress, and the `Alignment` DTO.
//
// Every tunable reads from `AlignmentParameters`; the few the contract does not carry yet live in
// `AlignerDefaults` and are proposed in docs/design/contracts-proposals/audio-align.md.
import Foundation
import Synchronization

public enum AudioAlignError: Error, Sendable, Equatable {
    /// The file has no audio track.
    case noAudioTrack(URL)
    /// AVFoundation could not decode the file.
    case decodingFailed(URL, String)
    /// A cached envelope file is not a whole number of little-endian Float32 values or is empty.
    case invalidEnvelopeFile(URL)
    /// `AlignmentParameters` holds a value the aligner cannot work with.
    case invalidParameters(String)
    /// One of the inputs is too short to produce a single envelope frame.
    case inputTooShort(URL?)
}

/// Tunables the spike used that `AlignmentParameters` does not carry yet. Each is documented with the value the
/// spike validated; the proposed contract additions are in docs/design/contracts-proposals/audio-align.md.
enum AlignerDefaults {
    /// Blackman-windowed sinc FIR length for the full-rate to envelope-rate decimation (spike: 127 taps at 48 kHz).
    static let decimationFilterTaps = 127
    /// FIR cutoff as a fraction of the envelope-rate Nyquist frequency (spike: 3.6 kHz of 4 kHz).
    static let decimationCutoffFraction = 0.9
    /// Added to each STFT band power before the log so digital silence does not produce `log(0)`. The spike
    /// normalised its input to unit RMS first; streaming cannot, so this is in absolute band-power units of a
    /// unit-RMS signal (about -90 dB relative to it) and only matters for silence.
    static let logPowerFloor: Float = 1e-6
    /// The fine pass's "second peak" must be at least this far from the PHAT peak (spike: 48 samples at 48 kHz).
    static let phatSecondPeakExclusionMs = 1.0
    /// A fine window only counts as an inlier when its PHAT peak is at least this many times the best value
    /// outside the exclusion zone. Measured on the synthetic pairs: 1.8-2.8 for true alignments down to -10 dB
    /// SNR, 1.0-1.25 for false candidates and unrelated material (spike: 2.1-2.5 vs 1.0-1.1).
    static let minimumPhatPeakRatio: Float = 1.5
    /// Fewer fine windows than this cannot support a drift fit; drift is then reported as zero.
    static let minimumWindowsForDriftFit = 3
    /// A candidate needs at least this many measured fine windows (inside the reference) to be verified.
    static let minimumVerificationWindows = 2
    /// Number of points the coarse correlation curve is max-pooled to for `AlignmentProof.correlation`.
    static let proofCorrelationPoints = 2048
    /// Sub-sample resolution of `Alignment.offset`: the timescale is the reference sample rate times this, so a
    /// 48 kHz reference gets 48,000,000 units per second (1/1000 sample, about 21 ns). Falls back to the plain
    /// sample rate if the product does not fit `Int32`.
    static let offsetTimescaleMultiplier = 1000
    /// Frames per read while streaming a file into the envelope builder.
    static let streamingChunkFrames = 65536
}

/// Cooperative cancellation for the blocking pipeline, which runs on a background queue where `Task.isCancelled`
/// has no task to consult: `OnsetAligner` flips the flag from `withTaskCancellationHandler`.
public final class CancellationToken: Sendable {
    private let flag = Atomic<Bool>(false)

    public init() {}

    public var isCancelled: Bool { flag.load(ordering: .relaxed) || Task.isCancelled }

    public func cancel() { flag.store(true, ordering: .relaxed) }

    /// Throws `CancellationError` once cancelled, mirroring `Task.checkCancellation()`.
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
