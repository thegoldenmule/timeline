# Research synthesis: AI-driven video editor for macOS

Date: 2026-09-08. Seven research passes (rendering engines, web UI, AI senses/hands, LLM-tool architecture, macOS platform, Claude SDK/MCP, native Mac app) plus a check of this machine. The detailed reports with sources are the numbered files in this folder.

## Recommendation in one paragraph

Build a native macOS app with a pure-Swift editing core and AVFoundation as the single render engine. The declarative timeline document (JSON, IDs, rational time) is the source of truth; every feature is a pure operation on that document; a compiler turns the document into an `AVMutableComposition` + custom Metal/Core Image compositor that serves preview, frame grabs, and export from one code path. Tools over the document are exposed through an in-process MCP server so Claude Code can be the agent on day one, with an embedded agent added later. Keep ffmpeg as an optional sidecar for probing and exotic formats, not as the engine.

## Why native beats web UI + ffmpeg daemon for this product

1. **One renderer instead of two.** In the web path the browser composites a canvas preview while ffmpeg renders the final; every transition, caption style, and color op is implemented twice and needs parity tests. AVFoundation's `AVVideoCompositing` is used by `AVPlayerItem`, `AVAssetExportSession`, and `AVAssetImageGenerator` alike. This is the biggest win for "isolate and test."
2. **Live multi-track preview is built in.** `AVPlayerItem.videoComposition` plays a composition with the custom compositor live; `seekingWaitsForVideoCompositionRendering` gives scrub accuracy. The web path must build a WebCodecs compositor (Mediabunny) plus a proxy pipeline, and still previews in 8-bit SDR.
3. **iPhone footage is handled correctly for free.** iPhone HDR is Dolby Vision 8.4 over HLG, 10-bit HEVC, variable frame rate, with a Spatial Audio APAC track ffmpeg cannot decode. AVFoundation passes HDR through, decodes everything in hardware, and reads the Photos library via PhotoKit. The ffmpeg path needs `ffmpeg-full`, libplacebo tone mapping, explicit stream mapping, and loses Dolby Vision on export.
4. **First-party senses on device.** SpeechAnalyzer (about 45x realtime, word timings), Vision (faces, OCR, saliency, person masks), SoundAnalysis, VTFrameProcessor (slow-mo, super resolution), Foundation Models for cheap classification. All free, offline, no model downloads.
5. **Agent integration is orthogonal to UI stack.** Tools operate on the document and are exposed over MCP. The Swift MCP SDK has server + Streamable HTTP; Claude Code attaches with one command. The agent runtime can change without touching the editor.

### Comparison at a glance

| Dimension | Native (SwiftUI/AppKit + AVFoundation) | Web UI + local ffmpeg daemon | Hybrid: Swift core + web timeline in WKWebView |
|---|---|---|---|
| Live multi-track preview | Built in: `AVPlayerItem.videoComposition` with the custom compositor; `seekingWaitsForVideoCompositionRendering` for scrub accuracy | Must build a WebCodecs compositor (Mediabunny) and a proxy pipeline; preview is 8-bit SDR | Native preview in an `AVPlayerLayer` |
| Renderers to maintain | One | Two (canvas preview, ffmpeg final) plus parity tests | One |
| HDR / HEVC / ProRes / Spatial Audio | First-party, hardware, HDR passthrough | Needs ffmpeg-full, tone mapping, explicit stream maps; Dolby Vision lost | Native |
| On-device senses | SpeechAnalyzer, Vision, SoundAnalysis, Foundation Models, VTFrameProcessor for free | Shell out to Swift CLIs (yap) or Python | Native |
| Agent integration | Tools in Swift, MCP swift-sdk server; no Agent SDK for Swift (Claude Code sidecar or Messages API) | Claude Agent SDK in-process; one language for tools, MCP, UI | Swift tools + MCP; Agent SDK possible in a Node sidecar |
| Timeline UI component | None maintained in Swift; build in AppKit/Metal | None permissive for React either; build 1-2k lines of DOM/canvas | Web timeline; two toolchains and a bridge |
| Coding-agent velocity | Slower: Xcode loop, Swift 6 concurrency, AVFoundation gotchas | Fastest: Vite, Playwright, React | Mixed |
| Distribution | One signed, notarized bundle | Daemon + browser tab, or Electron | One bundle |

Tauri is not a shortcut: it uses WKWebView on macOS, which only gained full WebCodecs audio in Safari 26 and has no directory picker. Electron gives Chrome's behavior but adds a second runtime.

## What native costs

- AVFoundation learning curve and old samples (AVCustomEdit 2017). Known traps: Core Animation captions via `animationTool` work only in export, so render captions inside the compositor instead; custom compositors must opt into HDR pixel formats; audio has volume ramps and a tap but no per-clip effects graph without an offline `AVAudioEngine` pass.
- No maintained open-source Swift NLE timeline component exists. Plan to build the timeline as an AppKit/Metal view inside a SwiftUI shell (SwiftUI `Canvas` has no per-element interactivity).
- No Claude Agent SDK for Swift. Use Claude Code as a sidecar over MCP, a community Messages-API SDK (SwiftAnthropic, MIT), or `ClaudeForFoundationModels` once on macOS 27.
- MCP swift-sdk is pre-1.0. Xcode iteration is slower than Vite, and coding agents are stronger at React than SwiftUI; keep the UI thin and the logic in `swift test`-able packages.

**Hedge:** if timeline UI velocity dominates, keep the Swift core and host a TypeScript timeline in a `WKWebView` (preview stays native in an `AVPlayerLayer`). Do not pick pure web + ffmpeg for a product whose inputs are iPhone HDR footage.

## This machine (verified 2026-09-08)

| Item | Value |
|---|---|
| macOS | 26.3 (25D125), Apple M4 Max, 40 cores, 64 GB unified memory |
| Xcode / Swift | Xcode at /Applications/Xcode.app, Swift 6.3.3 |
| ffmpeg | Homebrew `ffmpeg` 8.1.1, slim build: has VideoToolbox, x264/x265, svt-av1, libvmaf; **no libass, no drawtext, no subtitles, no libplacebo, no whisper** |
| ffmpeg-full | Available in homebrew-core at 9.0.1 (keg-only), adds libass, libplacebo, whisper-cpp, tesseract, zimg, frei0r |
| Runtimes | Node 25.5.0, Bun 1.3.10, Python 3.14.5, uv |
| Local LLMs | Ollama with qwen3.8 (17 GB) installed; LM Studio installed |
| Browser | Google Chrome (full HEVC 10-bit WebCodecs on macOS) |

64 GB means transcription, a 30B-class local model, and hardware encode can run concurrently.

## Architecture

```
Packages/
  EditorCore     pure Swift: Project schema, EditOp enum, apply/invert, invariants, JSON codec
  RenderKit      Project -> AVMutableComposition + AVMutableVideoComposition + AVMutableAudioMix
                 one AVVideoCompositing (Metal/Core Image): transitions, transforms, overlays, captions
                 AVPlayerItem factory, AVAssetImageGenerator frames, async AVAssetExportSession / AVAssetWriter
  AnalysisKit    actors over SpeechAnalyzer, Vision, SoundAnalysis, ffprobe; typed annotations cached per asset
  Providers      Klipy/Giphy memes, Pexels/Pixabay b-roll, TTS (Apple, Kokoro, ElevenLabs), Freesound, Splice MCP
  AgentKit       Tool registry (name, description, JSON Schema, annotations, handler) -> MCP server (swift-sdk)
                 optional embedded agent: Claude Code CLI sidecar or Messages API; Foundation Models for cheap passes
  App            SwiftUI shell; timeline as NSViewRepresentable Metal view; AVPlayerLayer preview; approval cards
```

Dependencies point inward: `EditorCore` imports nothing but Foundation; `RenderKit` depends on `EditorCore`; the App depends on everything.

### The document

```
Project { version, settings{ fps (rational), width, height, sampleRate },
          assets{ id -> { path, kind, duration, fps, hasAudio, color{ primaries, transfer }, analysis? } },
          tracks[ { id, kind: video|audio, clips[ { id, assetId, start, in, out, speed,
                    transform{ x,y,scale,rotation,opacity }, effects[], transitionIn?, transitionOut?, audio{ gain, fadeIn, fadeOut } } ] } ],
          captions[ { id, style, items[ { id, start, end, words[ { text, t0, t1 } ] } ] } ],
          markers[] }
```

Times are integer frames at project rate (or `{value, timescale}` like `CMTime`). Every mutation is an `EditOp` with an inverse; the document carries a monotonically increasing `version` used for optimistic locking between the human and the agent (`timeline_apply` fails with a compact diff when `baseVersion` is stale). Move to Yjs/Automerge-style CRDTs only if truly concurrent editing is needed.

### Tool surface (keep about 15 visible; defer the rest via tool search)

Senses: `project_describe`, `media_import`, `media_analyze(level)`, `transcript_search`, `look_at(asset, timestamps)` returns a contact sheet image, `get_moments`.
Hands: `align_audio(referenceAsset, targetAsset)` returns offset, drift ppm, confidence, candidates, proof image; `timeline_apply({ ops[], baseVersion })`, `timeline_query`, `caption_add(style, source)`, `transition_add`, `overlay_add` (meme, image, text), `effect_add`, `audio_mix` (duck under speech, normalize LUFS), `find_broll`, `find_meme`, `generate_tts`.
Output: `render_preview(range)`, `render_export(preset)` gated by approval and cost estimate, `export_fcpxml`.

Each tool returns `{ version, changedIds, warnings, thumbnail? }`, never logs. Procedures such as "TikTok captions" or "jump-cut talking head" are Agent Skills (SKILL.md) that sequence these tools.

### Testing pyramid

| Layer | Tooling | Needs media? |
|---|---|---|
| EditOp apply/invert, invariants, JSON round trip | Swift Testing, property-style generators | no |
| Compiler Project -> AVComposition (track count, segments, time ranges, instructions) | Swift Testing on the composition objects | no |
| Compositor frames | synthetic assets written in-test with AVAssetWriter (solid colors, test pattern); `AVAssetImageGenerator` + swift-snapshot-testing with perceptual tolerance | synthetic only |
| Tool contracts | every tool has JSON Schema, descriptions on all fields, example payload validates | no |
| Agent scenarios | fake model replays recorded tool calls through the real loop; graders assert on document JSON | no |
| LLM evals | 20-50 tasks nightly with a real model, state-based graders (promptfoo/Braintrust) | tokens |
| Export smoke | full export of a fixture project, ffprobe/AVAsset assertions on codec, color tags, duration | yes |

## AI senses pipeline (run at import, cached per asset hash)

probe -> proxy (only if needed for UI thumbnails) -> transcript (SpeechAnalyzer fast pass; WhisperKit + SpeakerKit precision pass; cloud fallback) -> silence ranges -> shot boundaries and keyframes -> face/saliency boxes (Vision) -> OCR for screen recordings (Vision) -> loudness and beats -> VLM descriptions per shot (local Qwen3-VL via Ollama, or Claude on contact sheets, or Gemini agentic video for whole-file narrative) -> `moments.json` of scored highlights.

## Generation providers ("hands")

- Memes and GIFs: Tenor's API shut down on 2026-06-30. Use Klipy (free with attribution) or paid Giphy.
- B-roll: Pexels and Pixabay APIs, free with generous limits.
- Voice: Apple voices offline, Kokoro-82M locally via MLX, ElevenLabs or OpenAI for quality.
- Music and SFX: Freesound, Pixabay, Splice's official MCP server. Suno and Udio still have no public API.
- AI video: expensive garnish only. Sora 2's API is being removed on 2026-09-24.

## Libraries: use, study, avoid

| Verdict | Library | License | Why |
|---|---|---|---|
| use | AVFoundation, VideoToolbox, Vision, SpeechAnalyzer, PhotoKit, ScreenCaptureKit | Apple | Engine, hardware codecs, senses, footage access |
| use | argmax-oss-swift (WhisperKit, SpeakerKit) | MIT | Word alignment and diarization on the Neural Engine |
| use | MCP swift-sdk | MIT | Server + Streamable HTTP so Claude Code can drive the app; pre-1.0 |
| use | SwiftAnthropic; ClaudeForFoundationModels | MIT; Apache-2.0 | Messages API today; official Foundation Models bridge on macOS 27 |
| use | swift-snapshot-testing, DSWaveformImage | MIT | Frame snapshots; waveform drawing |
| use | GRDB 7, swift-uuidv7 | MIT | Project event store; time-ordered ids |
| use | yap, PySceneDetect, madmom, SigLIP 2 via MLX | MIT / BSD / Apache | CLI transcription for scripts; shots; beats; frame search |
| use | libass, LGPL arm64 ffmpeg, typed-ffmpeg | ISC / LGPL / MIT | Optional sidecar: ASS karaoke import, ffprobe, GIF/WebM export |
| use (hybrid only) | Mediabunny, React 19 + Zustand + zundo, dnd-kit | MPL-2.0 / MIT | Only if a web timeline is hosted in WKWebView |
| study | Diffusion Studio editor | MPL-2.0 | Open-sourced Aug 2026, agent-first: `dapi` CLI, composition validator, filmstrip and contact-sheet commands |
| study | video-use, Kinocut | MIT / Apache-2.0 | EDL plus self-evaluation loop; receipts and fail-closed quality gates |
| study | OpenReel, Omniclip, Descript, Shotstack JSON, AVCustomEdit sample | various | Timeline UX, WebCodecs pipeline, text-based editing, schema shape, custom compositor reference |
| study | bbc/audio-offset-finder, audalign | Apache-2.0 / MIT | Audio alignment reference and prototyping oracle |
| avoid | fluent-ffmpeg, ffmpeg-python, MoviePy as engine, editly | | Archived, dormant, slow, or stalled |
| avoid | Remotion as the core | source-available | Automation tier is $100/mo minimum beyond 3 people; fine as an optional graphics plugin |
| avoid | MLT, GStreamer Editing Services, Motion Canvas, Etro | LGPL / GPL | Heavy second engine, dormant, or GPL |
| avoid | Ultralytics YOLO, Tenor API, Sora 2 API, Tauri for media UI | AGPL / n.a. | License, shut down, being removed, WKWebView gaps |

Prose version of the same list follows for grep-ability.

**Use (native path):** AVFoundation, VideoToolbox, Vision, SpeechAnalyzer (+ `yap` CLI for scripting), argmax-oss-swift / WhisperKit (MIT), MCP swift-sdk, SwiftAnthropic (MIT) or Claude Code CLI, ClaudeForFoundationModels (macOS 27), swift-snapshot-testing, DSWaveformImage, PhotoKit, ScreenCaptureKit. Optional: libass (ISC) for ASS karaoke import, an LGPL arm64 ffmpeg/ffprobe build, PySceneDetect (BSD) or TransNetV2 for dissolves, madmom (BSD) for beats, SigLIP 2 via MLX for frame search.
**Use (if a web timeline is hosted in WKWebView):** React 19 + Zustand + zundo, dnd-kit, wavesurfer.js renderer with precomputed peaks.
**Study:** Diffusion Studio editor (MPL-2.0, agent-first, `dapi` CLI and `check` validator), video-use by browser-use (MIT, EDL + self-evaluation loop), Kinocut (receipts and fail-closed quality gates), OpenReel, Omniclip, Descript's text-based editing, Shotstack's JSON schema.
**Avoid:** fluent-ffmpeg (archived), ffmpeg-python (dormant), MoviePy as an engine, editly (stalled), Motion Canvas (dormant), Etro (GPL), Remotion as the core (automation tier is $100/mo minimum beyond 3 people), MLT/GES (heavy second engine), Ultralytics YOLO (AGPL; use RF-DETR), Tenor API (shut down 2026-06-30; use Klipy or paid Giphy), Sora 2 API (removed 2026-09-24), Tauri for a media UI (WKWebView WebCodecs gaps).

## Platform decisions

1. Minimum macOS 26 (SpeechAnalyzer, Foundation Models, full WebCodecs if a web view is used).
2. Encode with VideoToolbox: HEVC Main10 + HLG when all sources are HDR, otherwise tone-mapped SDR H.264/HEVC. Never claim Dolby Vision on output.
3. Audio: select the stereo AAC track explicitly; ignore APAC and metadata tracks. Normalize to -14 LUFS for social presets.
4. Variable frame rate is native in AVComposition; fix output rate via `videoComposition.frameDuration`.
5. Photos access via PhotoKit with the Photos permission; drag-and-drop and file pickers otherwise.
6. Distribution: Developer ID signing + notarization ($99/yr); sandbox only if targeting the Mac App Store; sign every nested binary (ffmpeg, helpers).
7. Job queue with a memory budget for transcription, local LLM, and export; on this 64 GB machine that is generous, but design for 16 GB.
8. Index QuickTime metadata (creation date, GPS, make/model, rotation, HDR flags) at import for the planner.

## Audio alignment (DAW render to camera audio)

Typical case: a 5-minute DAW render that sits somewhere inside a much longer camera recording (an hour-plus set). Cross-correlation is symmetric, so it finds where the short render lands in the long video regardless of which side is shorter; the long video's audio is the reference timebase and is never retimed. Compute the long video's onset envelope once at import and cache it, then correlate each DAW render against it. Normalize for partial overlap so a render near the start or end of the video is not penalized, and treat several strong peaks (the same song played twice in the set) as candidates for the user to pick. Well solved; Final Cut, Premiere, and Resolve all sync by waveform. Use cross-correlation, not discrete feature points: coarse pass on onset envelopes at 8 kHz via FFT cross-correlation (vDSP), fine pass with phase-transform (GCC-PHAT) correlation on 48 kHz audio plus parabolic interpolation for sub-sample accuracy, then windowed offsets fitted with a robust line to estimate clock drift in ppm. Confidence comes from the ratio of the best peak to the second peak and the residual of the drift fit. Correct drift by plain resampling with `AVAudioConverter` (a 10-50 ppm pitch change is inaudible). Replacing camera audio needs under one frame of accuracy; mixing needs under 0.1 ms or comb filtering appears. Port bbc/audio-offset-finder (Apache-2.0) for the standard-score confidence; ShazamKit custom catalogs give a free coarse cross-check via `matchOffset`. Details in 08-audio-alignment.md.

## Design documents

- `docs/design/storage.md`: media library layout, per-project event-sourced SQLite, projections, undo, agent concurrency, cache database.
- `docs/design/implementation-plan.md`: shared foundation first, then six parallel modules, then integration.

## Open questions

- How much of the timeline UI to build natively versus in a hosted web view. Suggest a two-week spike on the Metal timeline before deciding.
- Whether to ship a bundled ffmpeg at all in v1, or rely on Homebrew during development only.
- Caption rendering: Core Text into the compositor (recommended, one path) versus libass for ASS import.

## Suggested first spike (before any UI)

Swift package with `EditorCore` + `RenderKit`: load a 3-clip JSON (two iPhone HDR clips, one screen recording), compile to a composition with one crossfade and one animated caption drawn in a custom compositor, play it in `AVPlayer` in a bare window, export HEVC, and expose `timeline_apply` + `render_preview` + `look_at` over MCP so Claude Code can edit it. This exercises every risky assumption (custom compositor, HDR, scrub, MCP) in the smallest possible surface.
