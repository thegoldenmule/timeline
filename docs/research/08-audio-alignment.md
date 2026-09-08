# Aligning a DAW render to iPhone camera audio: research report

Research date: 2026-09-08. Web search quota was exhausted mid-task, so every source below was fetched directly by URL; claims I could not verify online are marked "(engineering knowledge, unverified)".

## 1. Algorithms

### Cross-correlation family (the workhorse)
- **Plain / normalized cross-correlation.** Offset = argmax of the cross-correlation; the FFT route uses the cross-correlation theorem (IFFT of X·conj(Y)), which is the only practical approach for long files ([Wikipedia, cross-correlation](https://en.wikipedia.org/wiki/Cross-correlation)). Normalizing by the two windows' energies gives a scale-free score in [-1, 1], which matters when one side is a compressed camera mic and the other a clean mix.
- **GCC-PHAT** (Knapp & Carter 1976, "The generalized correlation method for estimation of time delay", ~4.8k citations per [Semantic Scholar](https://api.semanticscholar.org/graph/v1/paper/DOI:10.1109/TASSP.1976.1162830?fields=title,authors,year,abstract,citationCount)) whitens the cross-spectrum: G(f) = X(f)Y*(f)/|X(f)Y*(f)|. Because it keeps only phase, it sharpens the peak and is markedly more robust to reverberation and EQ differences than raw correlation, but it becomes uninformative in low-SNR segments and so must be gated or combined with a prior ([Anguera, PhD thesis section on GCC-PHAT](https://www.xavieranguera.com/phdthesis/node92.html)). For our case (room mic vs. DAW mix with different EQ, compression and reverb) PHAT or a partially-whitened variant (|G|^rho with rho ~ 0.5-0.8) is the right default; full whitening over-emphasizes bands where the camera only has noise, so bandlimit first.
- **Correlation on features instead of waveform.** BBC R&D's `audio-offset-finder` cross-correlates *standardised MFCC sequences* after resampling to 8 kHz and reports a "standard score" (peak height in standard deviations over the correlation function); scores > 10 are typically accurate to ~0.01 s, < 5 need manual checking, and repeated musical sections are a stated failure mode ([bbc/audio-offset-finder](https://github.com/bbc/audio-offset-finder), Apache-2.0, active in 2026, Python 3.8-3.12). This is exactly the feature-level "second-peak" confidence metric we want.
- **Onset / spectral-flux envelopes.** librosa's `onset_strength` computes a log-power mel spectrogram, a half-wave-rectified first difference over `lag` frames, an optional local-max filter across frequency to suppress vibrato, and a mean across bins ([librosa.onset.onset_strength](https://librosa.org/doc/0.10.2/generated/librosa.onset.onset_strength.html)). Correlating two onset envelopes is very robust to timbre/EQ/reverb mismatch because only *when* things happen matters, and it survives heavy AGC because it is a per-frame relative measure. Resolution is the hop size (e.g. 2.9 ms at 8 kHz/256 hop), so it is a coarse stage, refined later on waveform.
- **Sub-sample refinement.** Fit a parabola through the peak and its neighbours: p = 0.5(a - c)/(a - 2b + c) in bins, p in [-0.5, 0.5]; exact for Gaussian-shaped peaks and accurate near any smooth peak ([J.O. Smith, CCRMA](https://ccrma.stanford.edu/~jos/sasp/Quadratic_Interpolation_Spectral_Peaks.html)). Apply it on the full-rate correlation to get sub-sample offsets, which matters for phase-coherent *mixing* of camera and DAW audio (a few samples of error at 48 kHz produces comb filtering above ~2 kHz; irrelevant if you simply *replace* the camera audio).

### Sequence alignment: DTW on chroma/MFCC
DTW is O(NM) and normally constrained to a Sakoe-Chiba band; FastDTW approximates it in O(N) with a multi-resolution scheme ([Wikipedia, DTW](https://en.wikipedia.org/wiki/Dynamic_time_warping)). librosa provides `sequence.dtw` with `subseq=True` for finding a short query inside a long reference and `global_constraints`/`band_rad` for banding ([librosa.sequence.dtw](https://librosa.org/doc/0.10.2/generated/librosa.sequence.dtw.html)). DTW is overkill for two recordings of the *same performance* (the warp is a straight line plus tiny drift); its value here is (a) confidence — a DTW path that is almost perfectly linear confirms the correlation result — and (b) diagnosing the multi-take case where the DAW file contains several performances of the same song. Aurio/AudioAlign (.NET, AGPL-3.0, last updated 2023) is a full implementation of fingerprinting (Haitsma-Kalker, Wang, Chromaprint, Echoprint) plus on-line time warping for exactly this kind of multi-recording alignment ([protyposis/Aurio](https://github.com/protyposis/Aurio)).

### Fingerprint / landmark approaches (fast, robust coarse offset)
Shazam-style constellation hashing pairs spectrogram peaks into (f1, f2, dt) hashes; a match is a *cluster of hashes agreeing on one time offset*, which is the offset estimate itself ([Wang 2003 paper](https://www.ee.columbia.edu/~dpwe/papers/Wang03-shazam.pdf); overview in [Wikipedia, acoustic fingerprint](https://en.wikipedia.org/wiki/Acoustic_fingerprint)). Implementations that expose the offset:
- **audfprint** (Dan Ellis, Python, MIT): 20 hashes/s default; "anything more than 5 or 6 consistently-timed matching hashes indicates a true match", random chance gives < 1% temporally consistent hashes; `--find-time-range` reports the matched span in both files ([dpwe/audfprint](https://github.com/dpwe/audfprint)).
- **Dejavu** (Python, MIT) returns `offset_seconds`; requires MySQL/Postgres; 109 open issues, maintenance uncertain ([worldveil/dejavu](https://github.com/worldveil/dejavu)).
- **Panako** (Java, AGPL-3.0, v2.1 May 2022) reports match start/stop in query and reference *and* a "time factor (%)" — i.e. it estimates drift/speed change — and is robust to time-stretch and pitch shift ([JorenSix/Panako](https://github.com/JorenSix/Panako)). **Olaf** by the same author is a portable C landmark fingerprinter (AGPL-3.0) that reports start/stop times and targets embedded/native use ([JorenSix/Olaf](https://github.com/JorenSix/Olaf)).
- **Chromaprint/AcoustID** (v1.6.1, July 2026) is a chroma-based whole-track identifier; it is not designed for offset estimation ([acoustid.org/chromaprint](https://acoustid.org/chromaprint)).
- **audalign** (Python, MIT, ~600 commits, active) wraps fingerprinting, waveform correlation, spectrogram correlation and a "visual" recognizer, plus `fine_align` for a second-pass refinement — the same coarse-then-fine architecture recommended below ([benfmiller/audalign](https://github.com/benfmiller/audalign)).
- **ShazamKit** (Apple, macOS 12+): `SHCustomCatalog.addReferenceSignature(_:representing:)` lets you fingerprint the *DAW render* on-device; `SHSignatureGenerator` builds signatures from `AVAudioPCMBuffer`s or an `AVAsset`; the match result `SHMatchedMediaItem` exposes `matchOffset` ("the timecode in the reference recording that matches the start of the query, in seconds"), `predictedCurrentMatchOffset`, `frequencySkew` and `confidence` ([SHMatchedMediaItem](https://developer.apple.com/documentation/shazamkit/shmatchedmediaitem), [SHCustomCatalog](https://developer.apple.com/documentation/shazamkit/shcustomcatalog), [SHSignatureGenerator](https://developer.apple.com/documentation/shazamkit/shsignaturegenerator)). WWDC22 recommends one signature per full asset because "a longer signature provides more opportunities for ShazamKit to match audio peaks", and documents `timeRanges` for syncing content to positions in the audio ([WWDC22 10028](https://developer.apple.com/videos/play/wwdc2022/10028/); [WWDC21 10044](https://developer.apple.com/videos/play/wwdc2021/10044/)). So yes, ShazamKit *can* give an offset, but the precision is undocumented (fingerprint frame granularity, likely tens of ms), it gives no drift slope beyond `frequencySkew`, and it is a black box. Treat it as an optional zero-code coarse stage or a cross-check, never the final answer.

### Robustness to camera-mic vs. clean-mix mismatch
The camera mic hears room reverb, audience noise, wind, AGC pumping, and instruments (or crowd) absent from the DAW mix; the DAW mix has DI'd instruments and effects absent in the room. Mitigations that all the tools above converge on: mono downmix; bandpass roughly 300 Hz-3 kHz where both share energy and wind/rumble are gone; log-compress or whiten (PHAT) so AGC and level differences do not dominate; correlate *features* (onset envelope, MFCC) for the coarse stage; and treat the ratio of best peak to second-best peak, not the absolute peak, as the confidence.

## 2. Clock drift

- **Magnitude.** Ordinary crystal oscillators are specified at roughly ±20 to ±100 ppm (that is 1.7-8.6 s/day for RTCs), TCXOs under 5 ppm ([Wikipedia, real-time clock](https://en.wikipedia.org/wiki/Real-time_clock)); temperature moves them further ([Wikipedia, crystal oscillator](https://en.wikipedia.org/wiki/Crystal_oscillator)). Two independent devices differ by the *difference* of their errors, typically 5-50 ppm (engineering knowledge, unverified). 10 ppm = 0.6 ms/min = 6 ms per 10 min = 36 ms/h (about one 24 fps frame per hour); 50 ppm = 30 ms per 10 min = 180 ms/h. For a 3-5 minute song, drift is 2-15 ms — at or below audibility for lip-sync but audible as comb filtering if the two audios are *mixed* (see accuracy section).
- **44.1 vs 48 (vs 96) kHz** is not drift; it is a nominal ratio. Convert nominally first (AVAudioConverter or by simply treating time in seconds), then measure residual ppm.
- **iPhone specifics.** AVFoundation captures video with a frame-duration *range* (`activeVideoMinFrameDuration`/`activeVideoMaxFrameDuration`), so the Camera app's video is variable-frame-rate under low light ([Apple docs](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration)). Audio, however, is written as a continuous 48 kHz AAC track with its own timestamps; VFR video affects *frame* timing, not audio sample timing, so align against the audio track and let the container carry the video (engineering knowledge, unverified). Apple gives no ppm spec for the iPhone audio clock; measure empirically across several devices (the windowed-slope method below gives you that measurement for free).
- **Detecting drift.** Estimate the offset in overlapping windows (e.g. 20-30 s every 10 s) with the *same* correlator, discard windows whose confidence is low (silence, applause), then fit offset(t) = b + m·t by robust regression (Theil-Sen or RANSAC); m is the drift in ppm ×1e6. Panako's "time factor" and ShazamKit's `frequencySkew` are the fingerprint equivalents. Syncaila, Auto-Align Post 2 (whose "Dynamic mode enables continuous phase/time correction for moving actors or cameras", ±100 ms static range) and PluralEyes all did or do some form of this ([Auto-Align Post 2](https://www.soundradix.com/products/auto-align-post-2/); [Syncaila](https://www.syncaila.com/)).
- **Correcting drift.** Options: (a) do nothing when |m|·duration < ~5 ms (e.g. under ~8 min at 10 ppm); (b) resample the DAW audio by the factor (1+m) — a *sample-rate change*, not a pitch-preserving time stretch, because a 10-50 ppm pitch change is inaudible (0.0009 cents at 50 ppm) and resampling is artefact-free. In Swift use `AVAudioConverter` between two PCM formats whose sample rates differ by the factor (it supports arbitrary PCM sample-rate conversion; quality/algorithm are configurable) ([AVAudioConverter](https://developer.apple.com/documentation/avfaudio/avaudioconverter)). Off-line equivalents: ffmpeg `aresample=async=...` for automatic timestamp-driven stretch/squeeze or `asetrate`+`aresample`; `atempo` is pitch-preserving and unnecessary here ([ffmpeg filters](https://ffmpeg.org/ffmpeg-filters.html)). Rubber Band (GPL/commercial, v4.0 Oct 2024) is likewise unnecessary unless you want pitch preservation ([breakfastquay.com](https://breakfastquay.com/rubberband/)). `sync-audio-tracks` explicitly does *not* handle drift ("Different speed/framerate/framedrops are not supported") ([codonaft/sync-audio-tracks](https://github.com/codonaft/sync-audio-tracks)) — a good reminder that most simple tools stop at a single offset.

## 3. Existing tools and libraries (status as of 2026)

Commercial / NLE:
- **PluralEyes** (Red Giant/Maxon): the waveform-sync pioneer; Maxon put it into "limited maintenance mode", ending support and bug fixes 1 Feb 2024 ([CineD](https://www.cined.com/pluraleyes-discontinued-pioneer-in-syncing-videos-based-on-waveforms/)).
- **Syncaila** (macOS/Windows, v3.0.5 Aug 2026): multi-hour multi-source audio sync, exports FCPXML/AAF/XML, one-time licence; claims improved handling of poor/repetitive audio ([syncaila.com](https://www.syncaila.com/)).
- **Tentacle Sync Studio** (macOS 11+): timecode-based (reads audio-track LTC with tolerant decoders); the product page does not advertise waveform sync ([tentaclesync.com](https://tentaclesync.com/sync-studio)).
- **Sound Radix Auto-Align Post 2** ($399; Pro Tools AudioSuite, Resolve Studio, Premiere, ARA2/VST/AU): static and dynamic time/phase alignment of boom vs. lav, ±100 ms range, Emmy and Sci-Tech awards ([product page](https://www.soundradix.com/products/auto-align-post-2/)); **Auto-Align 2** ($199, AAX/AU/VST3/ARA2) is the studio multi-mic version ([product page](https://www.soundradix.com/products/auto-align-2/)). These are the quality bar for *mixing* camera + DAW audio without comb filtering.
- **Final Cut Pro** "Synchronize Clips" with "Use audio for synchronization" does "precision sync adjustments using audio waveforms"; Apple warns "some audio recordings are not suited" and that it can take a long time ([Apple support](https://support.apple.com/guide/final-cut-pro/sync-audio-and-video-verc1fabc30/mac)). Premiere's Merge Clips/Synchronize-by-audio and DaVinci Resolve's waveform Auto Sync do the same; both fetches failed/timed out, so treat as unverified detail.
- **Wave Agent** (Sound Devices) is a metadata/polyphonic-to-mono tool, and **Vordio** (v6.14, June 2026) is a reconform/interchange tool; neither does audio alignment ([vordio.net](https://vordio.net/)).

Open source (ranked for us in section 6): audio-offset-finder (Apache-2.0), audalign (MIT), audfprint (MIT), syncstart (MIT; scipy FFT correlation, optional lowpass/denoise, produces diagnostic plots — [rpuntaie/syncstart](https://github.com/rpuntaie/syncstart)), sync-audio-tracks (Apache-2.0; FFTW/SoX/ffmpeg shell tool, no drift), Aurio/AudioAlign (AGPL-3.0), Panako/Olaf (AGPL-3.0), Dejavu (MIT), Chromaprint (LGPL, offset-unsuitable), librosa (ISC), Essentia (AGPL-3.0 with paid commercial licence, [licensing](https://essentia.upf.edu/licensing_information.html)), aubio (GPL, commercial by arrangement, [aubio.org](https://aubio.org/)), Sonic Annotator/Vamp (GPL, [vamp-plugins.org](https://vamp-plugins.org/sonic-annotator/)).

Apple frameworks: `vDSP_conv` does direct correlation (positive filter stride) or convolution (negative stride) in O(N·P) — fine for a few-thousand-sample refinement window, hopeless for whole tracks ([vDSP_conv](https://developer.apple.com/documentation/accelerate/vdsp_conv)). `vDSP.FFT` / `vDSP_fft_zrip` / `vDSP_DFT_zrop` give power-of-two (radix 2/3/5) FFTs; real FFT output is packed (DC and Nyquist share element 0) and unscaled (divide forward real by 2, inverse by n) ([vDSP.FFT](https://developer.apple.com/documentation/accelerate/vdsp/fft), [data packing](https://developer.apple.com/documentation/accelerate/understanding-data-packing-for-fourier-transforms)). `AVAudioConverter` handles the resampling. ShazamKit as above. There is no Apple-supplied "Auto Align" Audio Unit; that name belongs to Sound Radix.

## 4. Accuracy targets
ITU-R BT.1359-1 ("Relative timing of sound and vision for broadcasting", in force since 1998) places the detectability threshold at about 45 ms audio-lead to 125 ms audio-lag; EBU R37 asks for +40/-60 ms end-to-end and ±5/-15 ms per production stage; ATSC recommends +15/-45 ms; film practice ±22 ms ([ITU](https://www.itu.int/rec/R-REC-BT.1359-1-199811-I/en); [Wikipedia summary](https://en.wikipedia.org/wiki/Audio-to-video_synchronization)). Musicians watching their own hands are stricter than broadcast viewers, so target **< 1 video frame (< ~20 ms) for replacement** and **< 1 sample-equivalent (< 0.1 ms) for mixing**. Correlation on 48 kHz audio with parabolic interpolation reaches the second target on transient-rich material; the first target is met by the 8 kHz coarse stage alone.

## 5. Recommended pipeline for Swift + Accelerate

Inputs: camera asset (reference timebase, because video must not be retimed) and DAW asset (target). Output `{offsetSeconds, driftPPM, confidence, diagnostics}` meaning: DAW time t_daw maps to camera time t_cam = offset + (1 + drift)·t_daw.

```
func alignAudio(reference cam: AVAsset, target daw: AVAsset) -> Alignment {
  // 1. Decode both to Float32 mono. AVAssetReader + AVAudioConverter,
  //    output 8 kHz for the coarse stage (nominal rate conversion
  //    absorbs 44.1/48/96 mismatch). Keep a second 48 kHz mono copy of
  //    each for refinement (stream it; do not hold 2 h at 48 kHz).
  camLo = decodeMono(cam, rate: 8000);  dawLo = decodeMono(daw, rate: 8000)

  // 2. Condition: 300 Hz-3 kHz Butterworth bandpass (vDSP_biquad),
  //    then features. Compute BOTH:
  //    (a) onset envelope: STFT 512/hop 128 (16 ms/62.5 fps), log-mel
  //        (24 bands), half-wave-rectified diff, mean over bands,
  //        subtract local median (robust to AGC).
  //    (b) waveform bandpassed + soft-clipped (tanh) -> for PHAT.
  featCam = onsetEnvelope(camLo); featDaw = onsetEnvelope(dawLo)

  // 3. Coarse offset by FFT cross-correlation of onset envelopes.
  //    N = nextPow2(len(featDaw) + len(featCam)); zero-pad both;
  //    FFT (vDSP.FFT, radix2); R = FFT(cam) * conj(FFT(daw));
  //    optionally R /= (|R|^0.7 + eps)  // partial PHAT;
  //    r = IFFT(R); normalise by sliding energy of the overlapped
  //    portions (compute with cumulative sums) so partial overlap
  //    isn't penalised. peak = argmax over lags where overlap >= 20 s.
  //    Memory: 2 h @ 62.5 fps = 450k frames -> N = 2^20, trivial.
  //    If the DAW file is very long relative to the clip, correlate
  //    the clip against 10-minute DAW chunks with overlap instead.
  (lagCoarse, peakRatio) = fftXcorr(featCam, featDaw)  // lag in frames

  // 4. Multi-take check: collect all peaks > 0.5 * best. If several
  //    exist at spacings > clip length, the DAW session likely contains
  //    repeats of the song; report candidates rather than choosing.

  // 5. Refine at 48 kHz: take a 30 s excerpt with high onset energy,
  //    slice DAW around lagCoarse ± 100 ms, PHAT xcorr on the bandpassed
  //    waveform (FFT size 2^21 or vDSP_conv for the ±4800-sample window),
  //    then parabolic interpolation: p = 0.5(a-c)/(a-2b+c).
  offsetFine = refine(cam48, daw48, near: lagCoarse)   // seconds, sub-sample

  // 6. Drift: repeat step 5 in windows every 10 s along the overlap.
  //    Keep windows whose peak/second-peak ratio > 3 (or std-score > 8).
  //    Theil-Sen fit offset_i = b + m * t_i.  driftPPM = m * 1e6.
  //    If |m| * overlap < 3 ms or fewer than 4 good windows: driftPPM = 0.
  (b, m, residualRMS) = robustLineFit(windowOffsets)

  // 7. Confidence = combine(
  //       coarse peak-to-second-peak ratio (>3 good, <1.5 fail),
  //       std-score of coarse peak (audio-offset-finder convention),
  //       fraction of drift windows that agreed within 2 ms,
  //       residualRMS of line fit (< 1 ms good)).
  //    Verify: apply (b, m), recompute normalised correlation at lag 0
  //    on three disjoint 10 s excerpts; all must exceed 0.3 (features)
  //    or the result is flagged "unverified".
  return Alignment(offsetSeconds: b, driftPPM: m*1e6,
                   confidence: c, candidates: peaks, windows: windowOffsets)
}
```

Applying the result: if `driftPPM == 0`, place the DAW clip at `offsetSeconds` on the timeline (AVMutableComposition `insertTimeRange(at:)` with sample-accurate CMTime). Otherwise render a corrected file with `AVAudioConverter` from `Format(sampleRate: 48000)` to `Format(sampleRate: 48000 * (1 + m))`, relabel as 48 kHz, then place. For mixing rather than replacing, use the sub-sample offset and consider a small all-pass/fractional-delay stage; if you cannot achieve < 0.1 ms you will hear comb filtering and should offer "replace" as the default.

Handling hard camera audio: heavy AGC/compression — the onset-envelope path is level-invariant and PHAT discards magnitude; wind noise — the 300 Hz high-pass removes most of it, and low-confidence windows are dropped from the drift fit; audience noise between songs — windows with low onset energy are excluded. Efficiency for 2 h DAW vs. 3 min clips: 8 kHz mono float of 2 h is 230 MB — decode once, cache the onset envelope (3.6 MB) per asset, and correlate each clip against the cached envelope; 2^20-point FFTs in vDSP take milliseconds on Apple Silicon. Several camera clips against one DAW take is just a loop with the cached DAW features; the multi-peak list from step 4 handles a DAW file containing several takes.

## 6. Reuse/port ranking
1. **bbc/audio-offset-finder** (Apache-2.0): port its standardised-MFCC correlation and standard-score confidence to Swift; smallest, best-documented, permissive.
2. **audalign** (MIT): reference architecture for coarse fingerprint/correlation + `fine_align`; use for prototyping and as an oracle in tests.
3. **audfprint** (MIT): port the landmark hasher if you want a fingerprint stage; its offset-histogram voting is a few hundred lines.
4. **ShazamKit** (Apple, no code): free coarse offset + `frequencySkew`; sanity-check only.
5. **syncstart / sync-audio-tracks** (MIT / Apache-2.0): trivial FFT-xcorr scripts, useful as test fixtures, no drift.
6. **Aurio/AudioAlign** (AGPL-3.0, .NET): best algorithmic reference for multi-recording alignment with time warping, but licence and runtime rule out linking.
7. **Panako/Olaf** (AGPL-3.0): the only ones that natively estimate speed change; study, do not link.
8. **librosa** (ISC): use in the Python prototype for onset_strength, chroma and DTW to validate the Swift port.
9. **Essentia, aubio, Vamp**: copyleft or commercial licences and heavy deps; not needed since vDSP covers the DSP.

## 7. Exposing it to the agent and the user
- Tool schema: `align_audio(referenceAssetID, targetAssetID, options{maxDriftPPM, allowMultiTake})` returning `{offsetSeconds, driftPPM, confidence (0-1), status: verified|unverified|ambiguous|failed, candidates:[{offset, score}], windows:[{t, offset, score}], proofImagePath, previewURL}`. The agent should refuse to auto-apply below a confidence threshold and instead present candidates.
- Visual proof: render two 10 s waveform/onset strips (camera above, DAW below, shifted by the result) at the loudest transient plus the drift scatter with the fitted line; a straight line through tight points is instantly convincing, a fan of points says "multi-take or bad audio". Also render a 5 s A/B preview clip with the DAW audio swapped in.
- Nudging: expose ±1 frame and ±1 ms controls that update `offsetSeconds` and re-render the strips; after a nudge recompute the local normalised correlation and show it, so the user sees the score drop as they move away from the optimum.
- Automatic verification: peak-to-second-peak ratio, residual correlation after applying the alignment on disjoint excerpts, agreement between the coarse (envelope) and fine (waveform) estimates within 10 ms, and the drift-fit residual; disagreement between ShazamKit's `matchOffset` and our offset by more than ~100 ms is a cheap red flag.

## Sources
- https://github.com/bbc/audio-offset-finder
- https://github.com/benfmiller/audalign
- https://github.com/dpwe/audfprint
- https://github.com/worldveil/dejavu
- https://github.com/JorenSix/Panako
- https://github.com/JorenSix/Olaf
- https://github.com/protyposis/Aurio
- https://github.com/rpuntaie/syncstart
- https://github.com/codonaft/sync-audio-tracks
- https://acoustid.org/chromaprint
- https://www.ee.columbia.edu/~dpwe/papers/Wang03-shazam.pdf
- https://en.wikipedia.org/wiki/Acoustic_fingerprint
- https://en.wikipedia.org/wiki/Cross-correlation
- https://en.wikipedia.org/wiki/Dynamic_time_warping
- https://www.xavieranguera.com/phdthesis/node92.html
- https://api.semanticscholar.org/graph/v1/paper/DOI:10.1109/TASSP.1976.1162830?fields=title,authors,year,abstract,citationCount
- https://ccrma.stanford.edu/~jos/sasp/Quadratic_Interpolation_Spectral_Peaks.html
- https://librosa.org/doc/0.10.2/generated/librosa.onset.onset_strength.html
- https://librosa.org/doc/0.10.2/generated/librosa.sequence.dtw.html
- https://en.wikipedia.org/wiki/Real-time_clock
- https://en.wikipedia.org/wiki/Crystal_oscillator
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration
- https://developer.apple.com/documentation/avfaudio/avaudioconverter
- https://ffmpeg.org/ffmpeg-filters.html
- https://breakfastquay.com/rubberband/
- https://developer.apple.com/documentation/shazamkit/shmatchedmediaitem
- https://developer.apple.com/documentation/shazamkit/shcustomcatalog
- https://developer.apple.com/documentation/shazamkit/shsignaturegenerator
- https://developer.apple.com/videos/play/wwdc2021/10044/
- https://developer.apple.com/videos/play/wwdc2022/10028/
- https://developer.apple.com/documentation/accelerate/vdsp_conv
- https://developer.apple.com/documentation/accelerate/vdsp/fft
- https://developer.apple.com/documentation/accelerate/understanding-data-packing-for-fourier-transforms
- https://www.cined.com/pluraleyes-discontinued-pioneer-in-syncing-videos-based-on-waveforms/
- https://www.syncaila.com/
- https://tentaclesync.com/sync-studio
- https://www.soundradix.com/products/auto-align-post-2/
- https://www.soundradix.com/products/auto-align-2/
- https://support.apple.com/guide/final-cut-pro/sync-audio-and-video-verc1fabc30/mac
- https://vordio.net/
- https://essentia.upf.edu/licensing_information.html
- https://aubio.org/
- https://vamp-plugins.org/sonic-annotator/
- https://www.itu.int/rec/R-REC-BT.1359-1-199811-I/en
- https://en.wikipedia.org/wiki/Audio-to-video_synchronization
