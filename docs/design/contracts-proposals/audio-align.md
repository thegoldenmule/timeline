# Proposed `Contracts` additions from `AudioAlign`

Status: folded 2026-09-08 (the parameters and the doc comments accepted; the optional
`OnsetEnvelopeProducer` not needed), see `../contracts-notes.md`. Owner: the AudioAlign module agent; merged
by the integration owner per `conventions.md`. `AudioAlign` now reads every value below from
`AlignmentParameters`; `AlignerDefaults` keeps only the two implementation choices.

## `AlignmentParameters` fields the spike used that the contract does not carry

The implementation plan asks for no magic numbers in the aligner. `AlignmentParameters` covers every threshold
of the decision rule, but the spike's front end, its output formatting, and two verification guards the module
tests forced use eight more values. Proposed additions, with the defaults the spike and the module tests
validated:

```swift
/// FIR length for the full-rate to `envelopeSampleRate` decimation (Blackman-windowed sinc; spike: 127 taps).
public var decimationFilterTaps: Int = 127
/// FIR cutoff as a fraction of the envelope-rate Nyquist frequency (spike: 3.6 kHz of 4 kHz).
public var decimationCutoffFraction: Double = 0.9
/// Added to each STFT band power before the log so digital silence does not produce `log(0)`. The spike
/// normalised its input to unit RMS first; the streaming builder cannot, so this is in absolute band-power
/// units of a unit-RMS signal (about -90 dB relative to it) and only matters for silence.
public var envelopeLogPowerFloor: Double = 1e-6
/// The fine pass's "second peak" must be at least this far from the PHAT peak, ms (spike: 48 samples at 48 kHz).
public var phatSecondPeakExclusionMs: Double = 1
/// A fine window counts as an inlier only when its PHAT peak is at least this many times the best value more
/// than `phatSecondPeakExclusionMs` away. Measured: 1.8-2.8 for true alignments down to -10 dB SNR, 1.0-1.25
/// for false candidates and unrelated material (spike: 2.1-2.5 vs 1.0-1.1). Without this gate, unrelated
/// material with only three fine windows verified a wrong offset: a Theil-Sen line through three points passes
/// exactly through two of them, so the inlier fraction is 2/3 and the MAD is zero.
public var minimumPhatPeakRatio: Double = 1.5
/// A candidate needs at least this many fine windows measured inside the reference to be verified (policy).
/// Windows whose reference excerpt would leave the recording are skipped rather than zero-padded.
public var minimumVerificationWindows: Int = 2
/// Fewer fine windows than this cannot support a drift fit; drift is then reported as zero (policy).
public var minimumWindowsForDriftFit: Int = 3
/// Number of points the coarse correlation curve is max-pooled to for `AlignmentProof.correlation` (policy).
public var proofCorrelationPoints: Int = 2048
```

Two more values are implementation choices rather than tunables and should stay internal:

- `offsetTimescaleMultiplier = 1000`: `Alignment.offset` is expressed at `referenceSampleRate * 1000` (48,000,000
  for a 48 kHz reference) so the sub-sample residual from parabolic interpolation survives in a `RationalTime`.
  Worth documenting on `Alignment.offset` in `Contracts/AudioAligner.swift`.
- `streamingChunkFrames = 65536`: frames per read while streaming a file into the envelope builder.

## Documentation to add to `Contracts/AudioAligner.swift`

- `AlignmentCandidate.driftPPM` / `Alignment.driftPPM`: positive when the target clock runs fast; target time
  `t` maps to reference time `offset + t / (1 + driftPPM * 1e-6)`. Correct by resampling the target by
  `1 + driftPPM * 1e-6`.
- `AlignmentProof.windowOffsetsMs`: absolute reference positions (ms) of target sample 0 implied by each fine
  window; the fitted line is `fitInterceptMs - fitSlopePPM * 1e-3 * windowTimesSeconds`.
- `AlignmentProof.correlation`: max-pooled so peaks survive; `correlationLagStepSeconds` is the pooled step.

## Optional: envelope streaming for MediaKit

`AudioAlign.OnsetEnvelopeBuilder` (chunked `append`, `finish`) and `OnsetEnvelope.write(to:)` / `read(from:)`
already implement the `onset-8k.f32` cache format described on `AudioSource.envelope`. MediaKit cannot import
`AudioAlign` (sibling rule), so if MediaKit is to produce the cache rather than call the aligner, the builder
should move behind a small `Contracts` protocol (`OnsetEnvelopeProducer`) that the composition root wires to
`AudioAlign`. Until then the app can call `OnsetAligner.onsetEnvelope(url:parameters:)` from the import job.
