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
// Every tunable reads from `AlignmentParameters`; the two implementation choices that are not tunables
// (the offset timescale multiplier and the streaming chunk size) live in `AlignerDefaults`.
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

/// Implementation choices that are not tunables (the tunables all live in `AlignmentParameters`).
enum AlignerDefaults {
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
