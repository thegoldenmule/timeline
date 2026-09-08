# Spike: cheapest way to make a live `AVPlayer` reflect a timeline edit

Date: 2026-09-08. macOS 26.3, Apple M4 Max, Swift 6.3.3, SwiftPM only (`swift-tools-version: 6.2`, `.macOS(.v26)`,
Swift 6 language mode). Code: `Package.swift` + 5 files in `Sources/PreviewUpdateSpike/`, 566 lines. Run with
`swift run PreviewUpdateSpike "$PWD"` from this directory (media in `./tmp/`; `SPIKE_RUNS=n` sets runs per cell,
default 5; `SPIKE_SHARED_CI=1` shares one `CIContext` across compositor instances). Debug build; all numbers below are
medians of 5 runs unless noted. Raw per-run logs: `tmp/run-5.log` (slow-audio regime) and `tmp/run-5b.log` (fast regime).

## Verdict

- **B (replace `playerItem.videoComposition` on the live item) is the answer for every edit that does not change the
  composition's track segments: 2 ms paused (no seek needed, the player re-renders by itself), 32 ms = one frame
  period while playing, zero frame gap, zero stalls.** It comfortably meets the 50 ms target.
- **A/D (new `AVPlayerItem`) is unavoidable for segment edits. Compile cost is negligible (0.7 ms for 200 clips);
  the whole cost is `readyToPlay`, and that cost is 100% audio.** A 200-clip item with the video tracks only reaches
  `readyToPlay` in 2-4 ms; with 2 AAC audio tracks it took 15-25 ms in the "fast" regime and 340-590 ms in a "slow"
  regime that this machine was in for the first four process runs (see "Bimodal audio startup" below; the 264 ms the
  reviewer quoted from the earlier spike is the same phenomenon). `A_videoOnly` hit 10 ms paused / 41 ms playing.
- **C (mutating the live `AVMutableComposition`) is unsafe: silently ignored while paused (the item then delivers no
  frames at all, even after a seek), and while playing it stalls playback for 0.4-1.6 s and still shows old content.**
  `item.asset === composition` is true (no copy), but the playback pipeline snapshots the segments at attach time.
- `AVQueuePlayer` double-buffering (D2) buys nothing (queued items are not prepared: `status` stays `.unknown` until
  they become current). A second `AVPlayer` (D3) hides the *freeze* while playing (the old item keeps delivering frames
  until the new one is ready) but not the *delay*. Pre-warming via a hidden player and then moving the item over is
  impossible (`NSInvalidArgumentException: An AVPlayerItem cannot be associated with more than one instance of AVPlayer`,
  even after `replaceCurrentItem(with: nil)` on the warm player).

## What was built

- Synthetic media reused from `spikes/compositor` (4 x 4 s 1280x720 30 fps H.264 + AAC, red/green/blue/yellow, 16-bit
  frame barcode) plus one clip with LPCM audio. `Probe` reads a composed frame's centre mean colour + barcode directly
  from the locked `CVPixelBuffer` (no copy) so the poll loop can run every 1 ms.
- Timeline: 200 one-second clips back-to-back (200 s), alternating video tracks 1/2 (A/B roll), audio tracks 3/4,
  cycling the 4 sources and `sourceIn` 0/1/2 s; one `Instr` (`AVVideoCompositionInstructionProtocol`) per clip carrying
  `base` track + `opacity`; `passthroughTrackID = kCMPersistentTrackID_Invalid` so the compositor runs every frame.
- `Compiler` (`@MainActor`): loads + caches `AVAssetTrack`s once, `buildComposition` (`insertTimeRange` x 400),
  `buildVideoComposition` (`AVMutableVideoComposition`, `customVideoCompositorClass = Compositor.self`),
  `spliceInPlace` (strategy C: `removeTimeRange` + `insertTimeRange` on the live tracks).
- `Compositor`: `AVVideoCompositing` on a Metal `CIContext`, base frame with optional opacity; instrumented with
  per-frame ns, and lifecycle timestamps (init / `renderContextChanged` / first `startRequest`) relative to an edit mark.
- `Harness` (`@MainActor`): headless `AVQueuePlayer` + `AVPlayerItemVideoOutput` (`seekingWaitsForVideoCompositionRendering
  = true`). For each run: park the playhead mid-clip (paused) or play through the clip from 0.6 s earlier; apply the edit;
  poll the output every 1 ms recording `(wall, itemTimeForDisplay)` of every frame; stop when a frame's centre colour
  matches the edited clip (tolerance 48/channel; opacity 0.5 expected as 255 * 0.5^(1/2.2) = 186 because CI blends in
  linear light). Then keep polling 1 s to catch post-swap stutter. Frame gap = longest wall interval between consecutive
  delivered frames; stalls = 1 ms polls where `timeControlStatus != .playing` while rate should be 1.
- Edits: B uses an instruction-only edit (opacity 1 -> 0.5 on the clip under the playhead); everything else swaps the
  source file of the clip under the playhead (a segment edit, same duration so instructions are unchanged).

## Results: edit -> first composed frame reflecting the edit (200 clips, 2V + 2A, debug build)

Fast-audio regime (`tmp/run-5b.log`, 5 runs per cell). "sync" = synchronous main-actor work (compile + objects + swap
call). "ready" = `item.status == .readyToPlay` from the edit. "seek" = `await item.seek(to: t, .zero, .zero)`.
"frame" = time after the previous columns' step until the edited frame is on the output; the **edit-to-frame total
is ready + seek + frame** (for B/C just "frame").

| Strategy | State | sync ms | readyToPlay ms | seek ms | frame ms | **edit->frame total ms** | max frame gap ms | item-time jump ms | stalls (1 ms polls) | ok |
|---|---|---|---|---|---|---|---|---|---|---|
| A_rebuild (new comp+vc+item, replace, then seek) | paused | 2.4 | 16.4 | 5.1 | 0.0 | **~22** | - | - | 0 | 4/5 |
| A_rebuild | playing | 14.7 | 143.9 | 22.7 | 0.1 | **~167** | 198 | -165 | 3 | 5/5 |
| A_preloaded (`comp.load(.duration,.tracks)`, `preferredForwardBufferDuration = 1`) | paused | 3.4 | 19.8 | 6.7 | 0.1 | **~27** | - | - | 0 | 4/5 |
| A_preloaded | playing | 14.7 | 145.0 | 23.2 | 0.1 | **~168** | 156 | -16 | 4 | 5/5 |
| A_videoOnly (audio tracks removed, seek before attach) | paused | 3.7 | 14.9 | 0.0 | 10.4 | **~25** | - | - | 0 | 5/5 |
| A_videoOnly | playing | 13.3 | 40.7 | 0.0 | 10.4 | **~51** | 67 | -14 | 2 | 5/5 |
| **B_videoComposition (`item.videoComposition = new`)** | paused | 1.0 | - | - | 2.2 | **2.2** | - | - | 0 | 5/5 |
| **B_videoComposition** | playing | 2.0 | - | - | 32.0 | **32.0** | 36 (= 1 frame) | -3 | 0 | 5/5 |
| D1_seekBeforeAttach (seek the detached item, then replace) | paused | 3.7 | 22.0 | 0.0 | 7.3 | **~29** | - | - | 0 | 5/5 |
| D1_seekBeforeAttach | playing | 14.2 | 146.7 | 0.0 | 8.3 | **~155** | 143 | -15 | 4 | 5/5 |
| D2_queuePlayer (`insert(after:)` + `advanceToNextItem()`) | paused | 3.3 | 16.8 | 0.4 | 7.4 | **~25** | - | - | 0 | 5/5 |
| D2_queuePlayer | playing | 15.5 | 144.0 | 1.2 | 8.4 | **~154** | 186 | -153 | 0 | 5/5 |
| D3_secondPlayer (prepare on 2nd AVPlayer, switch players) | paused | 2.4 | 16.2 | - | 7.4 | **~24** | - | - | 0 | 5/5 |
| D3_secondPlayer | playing | 11.4 | 46.2 | - | 59.8 | **~106** | 140 | -12 | 1 | 5/5 |
| C_mutateInPlace (`removeTimeRange`/`insertTimeRange` on live comp) | paused | 0.1 | - | - | never | **never** (0 frames even after re-seek) | - | - | 0 | 0/5 |
| C_mutateInPlace | playing | 0.3 | - | - | never* | **never*** | 437-1569 (stall) | - | 0 | 0/5 |

\* The harness reported a colour match at ~1600 ms in these runs, but that is the playhead reaching clip idx+2 whose
natural colour equals the edited colour (source+2); the edited clip itself never appeared. Playback froze for
0.4-1.6 s after the mutation and resumed with the old segments.

Slow-audio regime (`tmp/run-5.log`, same code paths for A/B/D, 5 runs). Only the audio-bearing new-item strategies moved:

| Strategy | State | readyToPlay ms | seek ms | edit->frame total ms | max frame gap ms | stalls |
|---|---|---|---|---|---|---|
| A_rebuild | paused | 360 | 4.7 | ~365 | - | 0 |
| A_rebuild | playing | 577 | 266 | ~843 | 878 | 159 |
| A_preloaded | paused | 388 | 4.8 | ~393 | - | 0 |
| A_preloaded | playing | 589 | 764 | ~1353 | 1403 | 160 |
| B_videoComposition | paused / playing | - | - | **2.2 / 31.7** | - / 36 | 0 |
| D1_seekBeforeAttach | paused | 377 | 0 | ~377 | - | 0 |
| D1_seekBeforeAttach | playing | 572 | 0 | ~572 | 678 | 155 |
| D2_queuePlayer | paused / playing | 365 / 525 | 0.4 / 1.3 | ~365 / ~527 | - / 743 | 0 |

Compositor lifecycle inside a slow swap (per-run notes): compositor `init` at 1.4 ms after the swap call, `CIContext`
init 0.2-1.7 ms, but `renderContextChanged` and the first `startRequest` only at ~335-350 ms (paused) / ~490-520 ms
(playing). The dead time is inside AVFoundation's item preparation, before the video composition session starts.

### Bimodal audio startup (the reviewer's 264 ms)

`readyToPlay` drivers, fresh `AVPlayer` + `AVPlayerItem` per run, paused, no seek (E4):

| Item | slow regime (run 1-4) | fast regime (run 5+) |
|---|---|---|
| 200 clips, 2V + 2A AAC, custom compositor | 444 ms | 14-18 ms |
| 200 clips, 2V + 2A AAC, no videoComposition | 340 ms | 8-10 ms |
| **200 clips, 2V only (audio tracks removed), custom compositor** | **4.1 ms** | **2-4 ms** |
| 1 clip, 1V + 1A, custom compositor | 157 ms | 4-5 ms |
| plain `AVURLAsset` red.mov (H.264 + AAC), no videoComposition | 157 ms | 5-6 ms |
| plain `AVURLAsset` red-pcm.mov (LPCM audio) | not measured | 5 ms |
| 200 clips, 2V + 2A LPCM, custom compositor | not measured | 8 ms |

Across four separate process launches every audio-bearing item (any clip count, any codec path, even a plain single
file) cost ~157 ms + ~1 ms per audio segment; from the fifth launch on the same binary took 5-25 ms and stayed there
for three more launches. Nothing in the audio code path changed between those runs (the LPCM clip generation was added,
which only runs `AVAssetWriter`). Default output device was the built-in speakers throughout. Root cause not
identified in the time box; the correlation with audio is exact (video-only was 2-4 ms in both regimes), so the likely
suspect is CoreAudio output-session/HAL setup per `AVPlayerItem`. **Design consequence: do not promise A/D latency
based on the fast regime; make the video-only path the one that carries the interactive promise.**

## E: compile scaling and per-frame cost

| Metric | 20 clips | 200 clips |
|---|---|---|
| `buildComposition` (400 `insertTimeRange` at 200; tracks preloaded) | 0.1 ms | 0.7-0.9 ms |
| `buildVideoComposition` (instructions array + `AVMutableVideoComposition`) | 0.0 ms | 0.0 ms |
| `item.videoComposition = vc` setter | 0.2 ms (23 ms the very first time in a process) | 0.1-0.2 ms |
| `loadTracks(withMediaType:)` for the 4 source files (once, cached) | 5-18 ms total | same |
| fresh player+item `readyToPlay` (fast regime) | 10 ms | 13 ms |
| `startRequest` mean / max while playing 2 s (60 frames) | 1.7-2.1 / 2.7-6.8 ms | 1.6-1.8 / 3.1-4.0 ms |

Instruction lookup by time is done by AVFoundation before `startRequest` (the request carries
`videoCompositionInstruction`); the compositor never touches the instructions array, so per-frame cost is flat in N
(measured identical at 20 and 200). Compile is linear and ~4 us per segment insert; it is not a factor.

## Exact APIs used and gotchas

- `AVPlayerItem.videoComposition` **is settable on a live item** (documented as settable; verified: takes effect
  within one frame while playing, immediately while paused with no seek). `AVPlayerItem.audioMix` is likewise
  settable (not measured). `AVPlayerItem.asset` is read-only (`var asset: AVAsset { get }`): there is no way to point
  an existing item at a new composition.
- `AVPlayerItem.seek(to:toleranceBefore:toleranceAfter:) async -> Bool` on a **detached** item (before
  `replaceCurrentItem`) returns in 0.0 ms and is honoured once attached; the same seek issued after attaching while
  the player is at rate 1.0 costs 23-266 ms (up to 840 ms in the slow regime). Always seek before attaching.
- `AVPlayer.replaceCurrentItem(with:)` keeps `rate` (stays 1.0; the new item starts playing when ready; the harness
  never had to re-issue `play()`). `timeControlStatus` flips to `.waitingToPlayAtSpecifiedRate` for the whole
  preparation (audio would drop out for that long).
- Item-time jump: a new item seeked to the *old* `currentTime()` comes up ~latency behind the wall clock (-15 to -165 ms
  in the fast regime, -530 to -1400 ms in the slow one). If continuity matters, seek to `currentTime + expected latency`
  or pause on structural edits.
- `AVQueuePlayer.insert(_:after:)`: queued items are **not** prepared (`status` stays `.unknown` = 0 until
  `advanceToNextItem()`); the swap then costs exactly as much as `replaceCurrentItem`.
- An `AVPlayerItem` can be attached to exactly one `AVPlayer` for its lifetime: `replaceCurrentItem(with: nil)` on the
  warm player followed by attaching to the real player throws `NSInvalidArgumentException` (uncatchable from Swift).
  A second `AVPlayer` (with its own `AVPlayerLayer`) that becomes the visible one is the only double-buffering option.
- Strategy C: `AVMutableCompositionTrack.removeTimeRange(_:)` shifts later segments earlier; a following
  `insertTimeRange(_:of:at:)` at the same start shifts them back, so the splice is net-neutral (`comp.duration` stayed
  200 s). The live item ignored it (paused: 0 frames delivered afterwards, `status` still `.readyToPlay`, `error` nil;
  playing: 26-38 old frames, then a 0.4-1.6 s stall). A fresh item on the same mutated composition showed the edit,
  so the mutation itself is valid; only the live pipeline does not track it. Treat compositions handed to a player item
  as frozen.
- `AVAssetTrack.asset` is a **weak** reference: caching tracks without keeping their `AVURLAsset` alive makes
  `insertTimeRange` fail with `AVFoundationErrorDomain -11800 / OSStatus -12780`. Keep the assets in the cache.
- `AVPlayerItemVideoOutput` is per item; create a new output for each new item and switch the poll loop to it.
  `copyPixelBuffer(forItemTime:itemTimeForDisplay:)` takes an `UnsafeMutablePointer<CMTime>?` for the display time.
  In 1 of 5 paused full-rebuild runs the seek-target frame never became `hasNewPixelBuffer` within 3 s (`4/5 ok` rows);
  a defensive re-seek is cheap (5 ms) if the output stays silent.
- Swift 6 isolation: `AVPlayer`, `AVPlayerItem`, `AVPlayerItemVideoOutput`, `AVMutableComposition` are not
  `Sendable`; the whole harness is `@MainActor` and polls with `Task.sleep(for: .milliseconds(1))`, which is fine
  (1 ms granularity observed). The compositor is `final class: NSObject, AVVideoCompositing, @unchecked Sendable`
  with `OSAllocatedUnfairLock(initialState:)` for stats; instructions are `@unchecked Sendable`. `.macOS(.v26)` exists
  with `swift-tools-version: 6.2` (the earlier spike needed `"26.0"` on 6.0).
- One compositor instance is created per `AVPlayerItem` (91 instances / 76 `renderContextChanged` over a run) at
  ~1.4 ms after attach; `CIContext(mtlDevice:)` costs 0.2-1.7 ms, so sharing it (`SPIKE_SHARED_CI=1`) is not worth
  the complexity. Any real per-instance caches (font atlases, LUTs) should be process-static though.
- `AVMutableVideoComposition` is deprecated on macOS 26 in favour of `AVVideoComposition.Configuration`; still used
  here for speed. Setting the config-based value type on the item should behave identically for strategy B.

## Recommendation for `Renderer.update(compiled, from:, to:)`

1. **Diff, then pick the path.** `Compiled` should carry a structural fingerprint of the track segments (per track:
   `[(sourceURL, sourceRange, targetStart)]`) separately from the instruction/audio-mix payload.
   - Segments equal, instructions/audio differ -> **B**: `item.videoComposition = new` (and `item.audioMix = new`).
     Covers transform, opacity, crop, colour, transition type/curve, captions/titles, speed *ramps expressed in the
     compositor*, any parameter of an effect, and also instruction time-range changes (e.g. moving a dissolve's
     midpoint) as long as the underlying segments are untouched. Promise: <10 ms paused, <= 1 frame playing.
   - Segments differ (trim, slip, move, insert, delete, ripple, reorder, source swap, speed change that alters the
     segment mapping) -> **A via the D1 pattern**: build comp+vc (<1 ms), new `AVPlayerItem` + new
     `AVPlayerItemVideoOutput`, `seek` the detached item to the target time, then `replaceCurrentItem`. Never touch the
     old composition (C).
2. **Make the gesture-time item video-only.** During a drag that emits structural edits, swap in an item whose
   composition has no audio tracks (10 ms paused / ~50 ms playing, immune to the slow-audio regime). On gesture end /
   idle (or when the user presses play), build the full A/V item and swap it in; hide that swap while playing with a
   second `AVPlayer` + layer (D3) so the picture never freezes even if audio preparation takes 500 ms.
   Alternative worth a follow-up spike: keep audio permanently in a separate audio-only `AVPlayer` slaved to the video
   player's timebase, so structural video edits never pay the audio cost at all.
3. **Playing-state behaviour for structural edits**: either pause -> swap -> resume (simplest, honest), or seek the new
   item to `currentTime + measured latency` to avoid the backwards jump. Expect ~150 ms of `waitingToPlayAtSpecifiedRate`
   with audio in the fast regime.
4. **Definition of done latency** (200-clip timeline, edit -> first updated frame on `AVPlayerItemVideoOutput`, measured
   by this harness, median of 5): instruction-only edits **<= 10 ms paused, <= 40 ms playing**; structural edits
   **<= 50 ms paused (video-only item)**, **<= 150 ms with audio in the fast regime**, and never a frozen picture while
   playing (D3). Do not promise <150 ms for audio-bearing swaps until the slow-audio regime is understood; record
   `readyToPlay` in telemetry so the bimodality is visible in the field.

## Not verified / blocked

- Root cause of the slow-audio regime (340-590 ms `readyToPlay` for any audio-bearing item in the first four process
  runs, 5-25 ms afterwards). Reproduce with `system_profiler`/`log show` around CoreAudio, try `AVAudioSession`-less
  playback tweaks, and test with headphones/Bluetooth output.
- Audio dropout was inferred from `timeControlStatus` stalls (150-160 x 1 ms polls per slow swap), not by capturing the
  mixed audio.
- On-screen `AVPlayerLayer` behaviour during swaps (headless output only); `AVVideoComposition.Configuration` on the
  live item; `audioMix` replacement latency; release-build numbers; edits that change instruction time ranges under B
  (only the opacity parameter was changed).
