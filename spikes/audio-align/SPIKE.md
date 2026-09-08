# Spike: aligning a short clean DAW render inside a long noisy camera recording

Throwaway-but-inspectable Swift package (`swift build -c release && swift run audio-align`, `swift test`).
Foundation + Accelerate (vDSP) only; no Xcode project; Swift 6 language mode; macOS 26; 583 lines total
(`Sources/AlignCore/{Synth,DSP,Align}.swift`, `Sources/audio-align/main.swift`, 3 unit tests).
Machine: Apple M4 Max, 64 GB, macOS 26.3, Swift 6.3.3. Wall-clock effort: ~35 min.

## Assumption under test

We can find where a 3-5 min DAW render sits inside a 60-120 min camera track with sub-frame accuracy,
estimate clock drift in ppm, and produce a trustworthy confidence, using:
coarse FFT cross-correlation of 8 kHz onset envelopes -> GCC-PHAT fine pass at 48 kHz around the coarse lag ->
Theil-Sen line through per-window offsets for drift -> confidence from peak ratios and fit residual.

**Verdict: validated.** Offset error is ~0.02 ms (< 1 sample @48k) in every case with SNR >= -10 dB, drift is
recovered to 0.1 ppm, the whole alignment takes 0.7 s for a 60-min camera file (1.1 s for 120 min), and the
repeated-song case is reported as two candidates rather than a single confident answer.

## Test signals (all synthesized, no media)

Everything is generated from a sample-rate-independent "score" (note events with times in seconds), so the DAW
and camera renders are computed exactly at their own rates and ground truth is known to the sample without any
resampler in the synth path. Clock drift is simulated by rendering the DAW at 44100 * (1 + 23e-6) Hz and
labelling it 44100.

- Performance (4 min): 3 melodic voices (notes 200-600 ms, 4 harmonics, attack/decay), sustained triads changing
  every 2-4 s, percussive hits every 0.5 s +-100 ms (decaying sines at 180 Hz, 2-5 kHz random, 7 kHz).
- Camera (60 min @48k, one case 120 min): pink noise (Kellet filter) scaled to SNR vs. the performance RMS,
  performance with 6-tap room reverb (13-113 ms), a bass line present *only* in the camera (41-110 Hz),
  wind rumble (white -> 30 Hz one-pole, RMS 2x performance), soft-knee compressor (4:1, 6 dB knee,
  threshold -6 dB re. perf RMS, 5 ms / 200 ms, AGC stand-in).
- DAW (@44.1k, +23 ppm unless noted): clean performance, different reverb (21-89 ms), low shelf +6 dB @200 Hz,
  high shelf -6 dB @4 kHz, no noise, no bass. "Head partial" case renders the DAW from 30 s into the performance.
- Repeated song: the performance appears at 30:05.123 and again at 50:05.123, the second copy with 10% of
  melodic notes re-pitched.

## Results (M4 Max, release build)

Offset error = fitted intercept (camera position of DAW sample 0) minus ground truth. "Fine pass 1" is the
Theil-Sen fit of 24 x 10 s GCC-PHAT windows; "pass 2" re-runs the fine pass after resampling the DAW by the
estimated drift (so the peaks are no longer smeared by drift inside a window).

| Case | Coarse NCC / 2nd / ratio | Coarse err | Fine inliers | Drift (truth) | Offset err pass1 -> pass2 | MAD pass1 -> pass2 | Verdict |
|---|---|---|---|---|---|---|---|
| SNR +10 dB, +23 ppm | 0.376 / 0.040 / 9.45 | 7.0 ms | 24/24 | 23.1 (23) | -0.019 -> -0.017 ms (-0.9 smp) | 0.026 -> 0.000 ms | CONFIDENT |
| SNR 0 dB, +23 ppm | 0.248 / 0.048 / 5.13 | 7.0 ms | 24/24 | 23.1 (23) | -0.020 -> -0.018 ms | 0.022 -> 0.001 ms | CONFIDENT |
| SNR -5 dB, +23 ppm | 0.149 / 0.043 / 3.47 | 7.0 ms | 24/24 | 23.1 (23) | -0.019 -> -0.018 ms | 0.022 -> 0.001 ms | CONFIDENT |
| SNR -10 dB, +23 ppm (stress) | 0.069 / 0.043 / 1.61 | 7.0 ms | 24/24 (true) vs 0-1/12-24 (4 false cands) | 23.1 (23) | -0.021 -> -0.019 ms | 0.022 -> 0.001 ms | CONFIDENT (fine pass rejected 4 false coarse candidates) |
| SNR -15 dB, +23 ppm (stress) | 0.040 / 0.040 / 1.01 | wrong (true lag not in top 5) | 0-1 of 12-24 for all 5 | n/a | n/a | NO ALIGNMENT (correct: no false positive) |
| SNR 0 dB, no drift | 0.227 / 0.052 / 4.33 | 7.0 ms | 24/24 | -0.0 (0) | -0.018 -> -0.018 ms | 0.001 -> 0.001 ms | CONFIDENT |
| SNR 0 dB, +23 ppm, DAW starts +30 s | 0.247 / 0.049 / 5.05 | 7.0 ms | 21/21 | 23.1 (23) | -0.020 -> -0.017 ms | 0.024 -> 0.001 ms | CONFIDENT |
| Repeated song x2, SNR +10, +23 ppm | 0.373 / 0.370 / 1.01 | picks 2nd copy first | 24/24 AND 24/24 | 23.2 / 23.1 | -0.010 ms (copy 2), -0.017 ms (copy 1) | 0.027 / 0.023 ms | AMBIGUOUS: 2 candidates (3005.1 s, 1805.1 s) |
| 120-min camera, SNR 0 dB, +23 ppm | 0.201 / 0.048 / 4.16 | 4.0 ms | 24/24 | 23.1 (23) | -0.012 -> -0.017 ms | 0.025 -> 0.000 ms | CONFIDENT |

Same-run control with the DAW EQ disabled (`NOEQ=1`): no-drift offset error -0.001 ms (-0.0 samples); drifted
cases +0.011..+0.021 ms. So the constant ~-0.02 ms (~1 sample) bias above is the phase response of the DAW's
shelving EQ relative to the camera, not the estimator. It is inherent to the problem (the DAW render *is*
EQ'd differently) and still 5x inside the 0.1 ms mixing budget.

Per-window GCC-PHAT errors in pass 1 range -0.11..+0.02 ms (drift smears the whitened peak across 11 samples
within a 10 s window); pass 2 flattens them to a few microseconds. PHAT peak-to-second-peak ratio per window is
2.1-2.5 for true alignments and 1.0-1.1 for false candidates: a clean separator.

### Runtime (single-threaded, release, 60-min camera unless noted)

| Stage | Time | Notes |
|---|---|---|
| 44.1k -> 48k Hermite resample of DAW (4 min) | 0.02 s | |
| 48k -> 8k FIR decimate (vDSP_desamp) + bandpass + onset envelopes, camera + DAW | 0.45 s (0.89 s for 120 min) | dominant cost; ~90% is the 60-min camera |
| Coarse FFT cross-correlation, N = 2^18 | 0.012 s (0.020 s at 2^19) | |
| Fine GCC-PHAT, 24 x 10 s windows, N = 2^19 each | 0.09 s | per coarse candidate |
| Pass 2 (resample DAW by drift + fine again) | 0.11 s | |
| **Total alignment** | **0.70 s (1.12 s for 120 min)** | plus 0.06-0.10 s per extra candidate |

Synthesis (not part of the algorithm): pink noise 0.4 s, performance render 0.7 s, camera assembly 1.0 s (2.0 s
for 120 min), DAW 0.6 s.

Memory: peak RSS 2.0-2.1 GB for 60 min, 5.4 GB for 120 min, dominated by the synth holding the full 48 kHz camera
as Float (691 MB / 1.38 GB) plus the pink-noise buffer of the same size and a copy during camera assembly. The
alignment's own working set is small: 8 kHz camera copy 115 MB (60 min), envelopes ~1 MB, coarse FFT 2^18 x 3
arrays ~3 MB, fine pass 2^19-point buffers ~10 MB. In production the 48k -> 8k decimation should stream from
AVAudioFile in chunks so the camera never has to be resident; the fine pass only needs ~10.2 s excerpts read at
known positions.

## Algorithm parameters that worked

Coarse pass
- Decimate 48k -> 8k with a 127-tap Blackman-windowed sinc, cutoff 3.6 kHz (`vDSP_desamp` does FIR + decimate
  in one call). DAW is first Hermite-resampled 44.1k -> 48k nominally (4-point cubic, zero delay).
- Bandpass 300 Hz - 3 kHz: two RBJ Butterworth biquads (HP 300, LP 3000) via `vDSP.Biquad`.
- Onset envelope: normalize to unit RMS, STFT 512 / hop 128 (62.5 fps), Hann, power spectrum via
  `vDSP_fft_zrip` + `vDSP_zvmags`, 24 log-spaced bands 300-3000 Hz (edges forced strictly increasing),
  log(power + 1e-6), half-wave-rectified first difference, mean over bands, minus running median (63 frames =
  1 s), minus global mean.
- Cross-correlation: zero-pad to next power of two (2^18 for 60 min + 4 min, 2^19 for 120 min), product with
  conjugate, inverse, divide by 4N (see gotchas), normalize per lag by sqrt(Ea * Eb) of the *overlapping*
  segments using Double prefix sums of squares, with an energy floor of 10% of the mean power over the overlap
  (without the floor a silent camera stretch inflates NCC arbitrarily; found by the unit test).
- Minimum overlap 50% of the DAW length. Second peak = best NCC more than 312 frames (5 s) from the peak.
  Candidates: greedy non-max suppression of every lag >= 50% of the peak, max 5.

Fine pass
- 10 s excerpts every 10 s over the DAW, camera excerpt = same span +-100 ms (4800 samples), FFT size 2^19.
- GCC-PHAT: G = C * conj(D), weight 1 / (|G|^rho + eps) with rho = 1, eps = 1e-6 * max|G|, and the spectrum
  masked to 80 Hz - 7 kHz (bins outside set to zero). Peak in [0, 9600], parabolic interpolation on the three
  samples around the peak, second peak = best value more than 48 samples (1 ms) away.
- Drift: Theil-Sen (median of pairwise slopes, median intercept) of offset vs. nominal DAW time, then one
  refit on inliers (|residual| <= 0.5 ms). drift_ppm = -slope / 48000 * 1e6 (DAW clock fast => offsets shrink).
- Pass 2: Hermite-resample the 48k DAW by (1 + drift) and re-run the fine pass. Residual drift ~0.1 ppm,
  MAD 0.000-0.001 ms.

Decision rule
- A coarse candidate is "verified" if >= 60% of its fine windows are inliers (<= 0.5 ms) and the fit MAD is
  < 0.5 ms. Exactly one verified -> CONFIDENT; none -> NO ALIGNMENT; several -> AMBIGUOUS, list them all.
- Confidence scalar for the UI: clamp(coarseRatio - 1, 0, 1) * inlierFraction * max(0, 1 - MAD_ms / 0.5);
  0.95-1.00 for the good cases. Note the coarse ratio alone is a *poor* gate: at -10 dB it was 1.61 with four
  false candidates and the answer was still perfectly recoverable once the fine pass verified them.

## What failed or surprised

- **Onset envelopes cannot distinguish the repeated song.** The variant copy (10% notes re-pitched) has the
  identical rhythm, so its coarse NCC was 0.373 vs 0.370 for the true copy and the coarse pass picked the wrong
  one. GCC-PHAT also verifies both (24/24 inliers each, PHAT peak 12871 vs 13933). The only correct behaviour is
  to surface both candidates, which the code does. Pitch-aware features (chroma) could rank them but this spike
  did not try.
- **Coarse peak ratio collapses before the alignment becomes unrecoverable.** At -10 dB the coarse ratio is
  1.61 and the peak is still right; the fine pass makes the decision. At -15 dB the true lag is not in the top 5
  coarse candidates and the fine pass rejects everything: a clean "no result", not a wrong one. Real-world noise
  (crowd, HVAC, speech) is not pink and will move these thresholds; this needs real footage.
- **Drift smears the PHAT peak inside a window.** 23 ppm over 10 s is 11 samples; the whitened correlation
  becomes a plateau and parabolic interpolation wobbles by +-0.05 ms. It is well inside budget but the
  drift-corrected pass 2 removes it almost entirely and is cheap (0.11 s).
- **Naive NCC normalization blew up over silence** (unit test found it): dividing by the exact overlap energy
  is undefined for a silent stretch and numerically explodes for a near-silent one. Fixed with the 10% mean-power
  floor.
- Nothing blocked. AVFoundation was linked but not needed since no media was read; `AVAudioConverter` was not
  exercised (hand-rolled Hermite + FIR decimation used instead to keep delays exactly known).

## vDSP APIs used and gotchas

- `vDSP_create_fftsetup` / `vDSP_fft_zrip` / `vDSP_destroy_fftsetup` (packed real FFT), `vDSP_ctoz` / `vDSP_ztoc`
  (interleave <-> split), `vDSP_zvmags` (power), `vDSP_desamp` (FIR + decimate), `vDSP_hann_window`, `vDSP_vmul`,
  `vDSP_vsma`, `vDSP_vsmul`, `vDSP_rmsqv`, `vDSP_sve`, `vDSP_maxvi`, `vDSP_vclr`; Swift overlay `vDSP.Biquad`,
  `vDSP.multiply/add/subtract/hypot/maximum/mean`.
- **Packed real FFT format:** `vDSP_fft_zrip` takes n/2 split-complex values; bin 0 holds (DC, Nyquist) as
  (realp[0], imagp[0]). Multiplying two spectra with a plain complex multiply corrupts bin 0; compute
  `re[0] = a.re[0]*b.re[0]`, `im[0] = a.im[0]*b.im[0]` separately (done in `RealFFT.multiplyConj`).
- **Scaling:** forward `zrip` returns 2x the DFT; inverse is an unnormalized sum. A round trip is scaled by 2n
  (unit-tested); the inverse of a product of two forward spectra is scaled by 4n. Getting this wrong only
  rescales NCC, but then "NCC = 1 for identical signals" is false and thresholds are meaningless.
- **Zero-padding input into `vDSP_ctoz`:** `ctoz` reads `count/2` DSPComplex pairs from the real input; clear
  the split buffers first, and if the input count is odd write the last sample into `realp[count/2]`.
- `vDSP_desamp`'s decimation factor is a `vDSP_Stride`; the output count is `(n - taps) / m`. The FIR group
  delay (63 samples at 48k) is identical for both signals and cancels in the coarse lag.
- `vDSP.Biquad` coefficient order is `[b0, b1, b2, a1, a2]` per section, a0-normalized; `apply(input:)` is
  `mutating` (carries state), so the value must be `var`.
- **Swift 6:** everything here is single-threaded so no Sendable issues surfaced. Notes for production:
  `FFTSetup` is an `OpaquePointer` and `RealFFT` is a non-Sendable class (one per worker, not shared);
  `DSPSplitComplex` holds raw pointers and must be built inside `withUnsafeMutableBufferPointer` scopes;
  `mach_task_self_` is a global `var` that Swift 6 strict concurrency rejects, so peak memory was read with
  `getrusage(RUSAGE_SELF).ru_maxrss` instead. Top-level `main.swift` globals are implicitly MainActor and fine.
- Hermite resampling of the DAW at 44.1k -> 48k is not band-limited (fine for upsampling); for 48k -> 8k use
  the FIR + `vDSP_desamp` path, not Hermite, or aliased 3-8 kHz content pollutes the onset bands.

## Verdict against the product thresholds

- **< 1 frame (20 ms) for audio replacement:** yes, by three orders of magnitude, down to -10 dB SNR (pink noise
  + AGC + extra bass + rumble + different reverb/EQ). The coarse pass alone is within 7 ms (one 16 ms frame + the
  drift midpoint); the fine pass is not even needed for replacement.
- **< 0.1 ms for mixing:** yes: 0.017-0.021 ms absolute error, of which ~0.018 ms is the DAW EQ's phase (0.001 ms
  with EQ off). Drift recovered to 23.1 ppm (0.1 ppm error, i.e. 24 us over 4 min); pass 2 residual 0.1 ppm.
  Mixing a drifted DAW into a camera track requires applying the ppm correction, otherwise 23 ppm alone is
  5.5 ms of slip over 4 min.
- **Ambiguity detection:** yes. Repeated song -> two verified candidates, explicitly AMBIGUOUS. -15 dB ->
  NO ALIGNMENT rather than a confident wrong answer. The trustworthy signal is fine-pass verification
  (inlier fraction + MAD + per-window PHAT ratio), not the coarse peak ratio.
- **Speed:** 0.7 s for 60 min, 1.1 s for 120 min, single core. Streaming decimation from disk is the next thing
  to build; after that, decoding the camera file will dominate.

Next steps if this graduates: stream the camera through `AVAudioFile` in chunks for the 8 kHz copy; validate
on real footage (non-pink noise, speech, room modes, camera codecs); add a chroma/pitch feature to rank
repeated-song candidates; expose the candidate list + per-candidate confidence to the UI.
