# Spike: Apple SpeechAnalyzer / SpeechTranscriber file transcription from a CLI

Date: 2026-09-08. Machine: macOS 26.3, Apple M4 Max, Xcode 26.5 SDK, Swift 6.3.3, SwiftPM only.
Everything lives in `spikes/speech/`. Code: `Sources/speechspike/main.swift` (135 lines), `Package.swift`.
Helpers: `wer.py`, `inspect.py`. Test audio: `speech.{aiff,wav,m4a}` generated from `script.txt`.

## Verdict

**Assumption validated.** `SpeechAnalyzer` + `SpeechTranscriber` transcribes an audio file from a plain,
ad-hoc-signed, bundle-less SwiftPM executable with **no entitlement, no Info.plist, no TCC prompt, no
microphone access**, returning **true per-word `audioTimeRange` and per-word confidence**, at
**~65x realtime** (71.0 s of audio in 1.07 s wall including model prep). Locale assets download
silently via `AssetInventory` (~85 MB, 5 s for a cold `de_DE`). It can be the default engine; the JSON shape
`{ words: [{text,start,end,confidence}], segments: [...] }` falls out directly. WhisperKit is only needed as
a fallback for pre-macOS-26 hosts, unsupported locales (30 supported), or if proper-noun accuracy proves
insufficient (see WER).

## Test material

- `script.txt`: 191 words, distinctive proper nouns (Marisol Okonkwo, Dmitri Vasquez, Blackmagic, Zoom F8, Sundance)
  and spelled-out numbers. `say -v Samantha -o speech.aiff -f script.txt` → 71.0 s, 22050 Hz mono 16-bit BE.
  (`--data-format=LEI16@48000` fails on `say` with "Opening output file failed: fmt?" for AIFF; default format used.)
- `afconvert -f WAVE -d LEI16@16000 -c 1` → `speech.wav`; `afconvert -f m4af -d aac` → `speech.m4a`.

## Exact API calls that worked

```swift
import Speech, AVFoundation, CoreMedia

// Discovery (instant, ~60 ms): 30 supported locales; 9 en_* installed system-wide on this Mac.
let supported = await SpeechTranscriber.supportedLocales
let installed = await SpeechTranscriber.installedLocales
SpeechTranscriber.isAvailable   // true

// Module. Presets exist too (.timeIndexedTranscriptionWithAlternatives etc.).
let transcriber = SpeechTranscriber(
    locale: Locale(identifier: "en_US"),
    transcriptionOptions: [],                       // only option is .etiquetteReplacements
    reportingOptions: [.alternativeTranscriptions], // add .volatileResults for progressive output
    attributeOptions: [.audioTimeRange, .transcriptionConfidence])

// Assets. status(forModules:) returned .supported (not .installed) even though en_US was in
// installedLocales, because the locale was not yet *reserved* for this process. The request then
// took 0.2 s (no real download). A cold de_DE took 5.0 s / ~85 MB.
let status = await AssetInventory.status(forModules: [transcriber])
if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await req.downloadAndInstall()   // req.progress is a Foundation.Progress (0→55%→100%)
}

// Analyze a file.
let file = try AVAudioFile(forReading: url)         // wav 16k, aiff 22.05k BE, m4a AAC all fine
let analyzer = SpeechAnalyzer(modules: [transcriber])
let collector = Task { var out: [SpeechTranscriber.Result] = []
    for try await r in transcriber.results { out.append(r) }; return out }   // start BEFORE analysis
try await analyzer.prepareToAnalyze(in: file.processingFormat)              // 0.11–0.18 s
let last = try await analyzer.analyzeSequence(from: file)                  // returns CMTime of last sample
try await analyzer.finalizeAndFinish(through: last ?? .zero)                // ends `results` stream
let results = try await collector.value

// Per-word extraction: each AttributedString run carries the attributes.
for run in result.text.runs {
    let range: CMTimeRange? = run.audioTimeRange
    let conf: Double?       = run.transcriptionConfidence
    let word = String(result.text[run.range].characters)
}
// Result fields: range (CMTimeRange), resultsFinalizationTime, isFinal, text, alternatives: [AttributedString]
```

`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` reported `1 ch, 16000 Hz, Int16`; the analyzer
resamples internally, no manual conversion needed (22.05 kHz AIFF and AAC m4a gave identical results).

`swift-tools-version` must be **6.2** (not 6.0) for `.macOS(.v26)` in `platforms:`.

## Speed / resources (release build, second run, `/usr/bin/time -l`)

| file | sample rate | prepare | analyze+finalize | total wall | realtime factor |
|---|---|---|---|---|---|
| speech.wav | 16 kHz | 0.18 s | 0.90 s | 1.07 s | 66x |
| speech.m4a | 22.05 kHz AAC | 0.17 s | 0.93 s | 1.10 s | 64x |
| speech.aiff | 22.05 kHz BE | 0.14 s | 0.94 s | 1.08 s | 66x |
| + `.volatileResults` | 16 kHz | 0.11 s | 1.02 s | 1.14 s | 62x |
| `DictationTranscriber` | 16 kHz | 0.26 s | 1.85 s | 2.11 s | 34x |
| de_DE model on English audio | 16 kHz | – | – | 0.8 s | 88x (garbage output, as expected) |

- Client process: **20.6 MB max RSS, 7.4 MB peak footprint, 0.05 s user CPU.** The model runs out-of-process in
  `/System/Library/Frameworks/Speech.framework/.../XPCServices/localspeechrecognition.xpc` (sampled at ~100 MB RSS,
  ~22% CPU). `/usr/bin/time -l` therefore does not measure the model; budget ~100–300 MB system-side per session.
- Process exits cleanly after `finalizeAndFinish`; no lingering XPC. `SpeechAnalyzer.Options.modelRetention`
  (`.whileInUse/.lingering/.processLifetime`) exists for keeping the model warm in a long-lived app.

## Asset download behavior

- Asset store: `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition/` (root-owned,
  managed by `mobileassetd`/`assetsubscriptiond`). 155 MB before, 240 MB after adding de_DE → **~85 MB per locale**.
- Cold `de_DE`: `assetInstallationRequest` non-nil, `downloadAndInstall()` took **5.0 s** on this connection,
  `Progress` went 0% → 55% → 100%. **No dialog, no approval, no TCC entry, no entitlement.** Works from an
  ad-hoc "linker-signed" binary with identifier `speechspike` and `TeamIdentifier=not set`.
- Reservation model: `AssetInventory.reservedLocales` / `maximumReservedLocales == 5`. Requesting assets
  *reserves* the locale for the calling process' identity; it persisted across runs. `AssetInventory.release(reservedLocale:)`
  returned `true` and cleaned up (`--release de_DE` flag in the spike). An app supporting many languages must
  manage these 5 slots.
- `status(forModules:)` reports `.supported` (not `.installed`) until the locale is reserved for you, even when
  `installedLocales` already lists it — always call `assetInstallationRequest` and handle nil vs non-nil.

## Accuracy (WER vs `script.txt`, `wer.py`, lowercase, punctuation stripped)

| engine | raw WER | WER with numbers normalized in ref (`ninety six`→`96`) |
|---|---|---|
| SpeechTranscriber (wav/m4a/aiff identical) | 15.7% | **7.7%** |
| DictationTranscriber | 20.4% | 14.2% |
| yap 1.2.1 (`--word-timestamps`) | – | 7.7% (identical text and timestamps) |

Residual errors after number normalization are all names/compounds on synthetic TTS speech:
`marisol okonkwo→marisola conquo`, `dmitri vasquez→dimitri vosquez`, `blackmagic→black magic`,
`timecode→time code`, `realtime→real time`, `uncertain→on certain`, `plain→plane`, one dropped `at`.
Numbers are always rendered as digits ("92nd", "400", "118"). Low confidence flagged exactly the doubtful tokens:
`F8` 0.44, `macOS` 0.50, `Video` 0.58; everything else ≥ 0.65, most > 0.9. Confidence is usable for
the "highlight uncertain words" feature.

## Timestamp granularity findings

- **Per word.** Each `AttributedString` run in `result.text` is one word (leading space included) with its own
  `audioTimeRange` and `transcriptionConfidence`. 186/186 words had both. No run covered multiple words, so no
  even-splitting heuristic was needed.
- **Grid: 60 ms.** All boundaries are multiples of 0.06 s (0, 0.48, 0.60, 0.72, 1.14, 1.56, 1.98 …). Good enough
  for click-to-seek; not sample-accurate.
- **Consecutive words abut exactly**: 176/185 gaps are 0.000 s, 9 gaps of 60–120 ms at sentence pauses, **zero
  overlaps**. I.e. a word's `end` is effectively the next word's `start` (or the pause start), not the acoustic
  offset of the word. Word durations 0.06–1.14 s, median 0.33 s.
- **Result chunks are phrase-sized**: 56 final results for 71 s (≈1.3 s each, e.g. `"Welcome to the"`,
  `" Timeline"`, `" Video Editor Spike."`). Segment ranges abut exactly (0.72→0.72, 1.14→1.14…). Punctuation and
  capitalization are included. `alternatives` has 1–4 entries per result (`" Today we"` / `" Today, we"`).
- **Final vs volatile**: without `.volatileResults` every result is `isFinal == true` (`resultsFinalizationTime ==
  range.end`). With it you get 308 volatile + 56 final results; volatile ones grow character-by-character
  (`"W"`, `"Wel"`, `"Welcome to"`…) and carry a **bogus range** (`0.00–52.48`) and `finalizationTime 0` — ignore
  volatile ranges, only use final results for timestamps. Volatile mode cost only +7% wall time.
- `DictationTranscriber` returns just 2 huge results (0–60 s, 60–71 s) but still per-word ranges; it uses a
  different (60 ms grid, slightly offset: 0.42/0.54/0.69) model with worse WER and no punctuation. Not useful here.
- `SpeechDetector` not tried (VAD only, not relevant to the assumption).

### Sample JSON (`out-wav.json`, trimmed)

```json
{
  "file": "speech.wav", "audioDuration": 70.997, "wallSeconds": 1.07, "realtimeFactor": 66.1,
  "assetStatusBefore": "supported", "assetDownloadSeconds": 0.2,
  "supportedLocaleCount": 30, "installedLocales": ["en_US", "en_GB", "..."],
  "transcript": "Welcome to the Timeline Video Editor Spike. Today we are testing ...",
  "words": [
    { "text": "Welcome", "start": 0,    "end": 0.48, "confidence": 0.997 },
    { "text": "to",      "start": 0.48, "end": 0.6,  "confidence": 0.998 },
    { "text": "the",     "start": 0.6,  "end": 0.72, "confidence": 0.971 },
    { "text": "Timeline","start": 0.72, "end": 1.14, "confidence": 0.875 },
    { "text": "Video",   "start": 1.14, "end": 1.56, "confidence": 0.575 },
    { "text": "Editor",  "start": 1.56, "end": 1.98, "confidence": 0.651 },
    { "text": "Spike.",  "start": 1.98, "end": 2.52, "confidence": 0.953 }
  ],
  "segments": [
    { "text": "Welcome to the", "start": 0, "end": 0.72, "isFinal": true, "finalizationTime": 0.72,
      "alternatives": ["Welcome to the"], "words": [ "...3 words as above..." ] },
    { "text": " Video Editor Spike.", "start": 1.14, "end": 2.58, "isFinal": true, "finalizationTime": 2.58,
      "alternatives": [" Video Editor Spike.", " Video editor Spike.", " Video Editor spike.", " video editor spike."],
      "words": [ "..." ] }
  ]
}
```

## Swift 6 concurrency notes

- Zero warnings in Swift 6 language mode. `SpeechAnalyzer` is an `actor`; `SpeechTranscriber` is a `Sendable`
  final class; `Result` is `Sendable`. `AnalyzerInput` is `@unchecked Sendable`.
- The `results` stream must be consumed concurrently with `analyzeSequence` (it is an `AsyncSequence` that ends
  when the analyzer finishes). Pattern: spawn a `Task` that iterates `transcriber.results` *before* calling
  `analyzeSequence(from:)`, then `await` the task after `finalizeAndFinish`. Doing it sequentially deadlocks/misses results.
- `results` is `some Sendable & AsyncSequence<Result, any Error>` (opaque, typed throws) — store results into a
  local array inside the task and return it; don't try to name the type.
- Top-level `await` in `main.swift` works fine; no `@main` needed.
- `AttributedString` runs: `run.audioTimeRange` / `run.transcriptionConfidence` resolve through
  `AttributeScopes.SpeechAttributes` with just `import Speech`; both are `CodableAttributedStringKey`, so the
  attributed text itself could be persisted.

## yap comparison

`brew install finnvoor/tools/yap` succeeded (~1 min; note zsh has no `timeout`). `yap transcribe --locale en_US
--json --word-timestamps speech.wav` ran in 1.08 s and produced **identical word boundaries and identical WER** —
yap 1.2.1 is a wrapper over the same `SpeechAnalyzer` API. Useful as a reference CLI, not an alternative engine.

## What a WhisperKit fallback would need to cover

1. **OS floor**: `SpeechAnalyzer` requires macOS 26. Anything supporting macOS 15 or earlier needs WhisperKit
   (or `SFSpeechRecognizer`, which is 1-minute-chunked and slow).
2. **Locales**: 30 supported. Whisper covers ~99 languages plus auto language detection, which the Apple API lacks
   (you must pick the locale up front; wrong locale = garbage, as the de_DE run showed).
3. **Word-end accuracy**: Apple word `end` == next word `start` on a 60 ms grid. WhisperKit word timestamps
   (DTW-based) give acoustic offsets, useful if silence-trimming per word matters.
4. **Vocabulary/prompting**: Apple offers `SFCustomLanguageModelData` (phrase counts, custom pronunciations) but no
   free-text prompt; Whisper takes an initial prompt for names like "Okonkwo", "Blackmagic".
5. **Cost**: WhisperKit large-v3-turbo on M4 Max is roughly 10–20x realtime with ~1.5 GB model download vs 65x and 85 MB
   here, and runs in-process (memory hits the app). Apple API should stay the default; WhisperKit opt-in.

## Repro

```sh
cd spikes/speech
swift build -c release
/usr/bin/time -l ./.build/release/speechspike speech.wav out-wav.json           # writes out-wav.json + out-wav.txt
./.build/release/speechspike speech.wav out.json --volatile                     # progressive results
./.build/release/speechspike speech.wav out.json --dictation                    # DictationTranscriber
./.build/release/speechspike speech.wav out.json --locale de_DE                 # forces asset download
./.build/release/speechspike x y --release de_DE                                # frees the reservation slot
python3 wer.py out-wav.json
```
