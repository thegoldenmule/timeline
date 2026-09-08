# Research synthesis: AI-driven video editor for macOS

Date: 2026-09-08. Seven research passes (rendering engines, web UI, AI senses/hands, LLM-tool architecture, macOS platform, Claude SDK/MCP, native Mac app) plus a check of this machine. The detailed reports with sources are the numbered files in this folder.

## Recommendation in one paragraph

Build a native macOS app with a pure-Swift editing core and AVFoundation as the single render engine. The declarative timeline document (JSON, IDs, rational time) is the source of truth; every feature is a pure operation on that document; a compiler turns the document into an `AVMutableComposition` + custom Core Image/Metal compositor that serves preview, frame grabs, and export from one code path. Tools over the document are exposed through an in-process MCP server so Claude Code can be the agent on day one, with an embedded agent added later. Keep ffmpeg as an optional sidecar for probing and exotic formats, not as the engine.

The load-bearing assumptions behind this were exercised in code on this machine (reference implementations under `spikes/`): one compositor did serve `AVAssetImageGenerator`, `AVAssetExportSession`, and a headless `AVPlayerItem` with frame-exact seeks; a Swift MCP server was driven end to end by Claude Code; SpeechAnalyzer transcribed from a plain CLI process at about 65x realtime; audio alignment recovered offsets to 0.02 ms and drift to 0.1 ppm. Measured facts from those runs are folded into the sections below.

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

- AVFoundation's editing samples are old (AVCustomEdit 2017) and macOS 26 deprecates the mutable classes they use: `AVMutableVideoComposition` and its instruction classes give way to the value type `AVVideoComposition.Configuration` (which also carries `perFrameHDRDisplayMetadataPolicy` and `outputBufferDescription`), and `AVVideoCompositionCoreAnimationTool` is on the deprecation path. Build on `Configuration` from the start. Known traps, confirmed in code: Core Animation captions work only in export, so captions are rendered inside the compositor with Core Text (this worked, including a 300 ms scale-in); AVFoundation instantiates the compositor itself and calls it on its own serial queue, so the class is `@unchecked Sendable` with lock-guarded caches; `renderContextChanged` fires once per consumer session and anything sized to the render context must be rebuilt there; an `AVAssetImageGenerator` held only as a temporary never completes its request, so keep generators alive; Core Image blends in linear light, so a 50/50 dissolve of red and green reads (188,188,0) rather than the (128,128,0) gamma-space blend Final Cut and Premiere produce, which is a product decision to make explicitly; source frames requested as 8-bit BGRA arrive untagged and pure green shifts about 10% toward (0,231,40), so request native YUV source formats or tag buffers before wrapping them. Audio has volume ramps and a tap but no per-clip effects graph without an offline `AVAudioEngine` pass. Live preview after an edit, measured on a 200-clip sequence: replacing `videoComposition` on the live player item takes 2 ms paused and one frame playing, so property edits are effectively free; a structural edit needs a new player item, and its cost is entirely audio startup (2 to 4 ms for a video-only item, 15 to 25 ms with two AAC tracks in a fast regime, 340 to 590 ms in a slow regime this machine fell into for four consecutive process launches with no code change, the same phenomenon behind the earlier 264 ms figure). Mutating a composition a player already holds is silently ignored while paused and stalls playback for over a second while playing, so compositions are treated as frozen. An `AVPlayerItem` binds to one `AVPlayer` for life, and `AVQueuePlayer` does not pre-prepare queued items, so hiding a swap while playing takes a second player and layer.
- No maintained open-source Swift NLE timeline component exists. Plan to build the timeline as an AppKit/Metal view inside a SwiftUI shell (SwiftUI `Canvas` has no per-element interactivity).
- No Claude Agent SDK for Swift. The embedded agent sits behind an `AgentRuntime` protocol in `Contracts` (start a session with a goal and tool access, stream turns and tool calls, approve or deny expensive tools, report cost); the first implementation drives the Claude Code CLI as a sidecar, so the app gets Claude Code's loop, compaction, and skills for free. Verified against Claude Code 2.1.263: `--strict-mcp-config` with an inline `--mcp-config` (which supports `headers`, so each launch carries a per-launch bearer token the server checks) loads only the app's server; `--permission-mode dontAsk` plus `--allowedTools` scoped to the server runs headless; `--max-budget-usd`, `--model`, `--append-system-prompt`, and `--settings` (inline JSON, including hooks) exist; a `PreToolUse` hook may return `permissionDecision: allow | deny` and fires even for allow-listed tools, which is the documented way to surface an approval to the app's UI, while `--permission-prompt-tool` exists but its contract is undocumented and is not relied on. The stream-json event schema is not documented as stable, so the parser is tolerant and tested against recorded transcripts; the single-shot `--output-format json` result carries the cost. The sidecar must be launched with `CLAUDECODE` unset when the app itself runs under Claude Code, and the app detects `claude --version` and `claude auth status` to degrade to "MCP only" when absent. Because none of that is a contract the app controls, the authoritative approval gate lives server-side in the tools (`approval_required` plus token), and the runtime is tested against recorded transcripts with a Messages-API stub compiled against the same protocol. A Messages-API implementation (SwiftAnthropic, MIT) or `ClaudeForFoundationModels` on macOS 27 can replace the sidecar behind the same protocol.
- MCP swift-sdk (0.12.1, pin with `exact:`) ships the Streamable HTTP transport but no HTTP listener; about a hundred lines of swift-nio (already a transitive dependency) put it on a socket, an idle-session sweep is needed because Claude Code does not send `DELETE` at the end of a headless run, and the stdio variant users can register with `claude mcp add` is a proxy to the running app so the database never has a second writer. Xcode iteration is slower than Vite, and coding agents are stronger at React than SwiftUI; keep the UI thin and the logic in `swift test`-able packages. Cold release build of the MCP server was 37 s, incremental 2.4 s, 5.1 MB stripped.

**Decided (2026-09-08):** the timeline is native AppKit/Metal inside the SwiftUI shell; the WKWebView hedge is retired. Do not pick pure web + ffmpeg for a product whose inputs are iPhone HDR footage.

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
  TimelineCore   pure Swift: the model in docs/design/timeline-model.md (commands, events, decide/evolve/invert, invariants, history fold)
  RenderKit      Sequence -> AVMutableComposition + AVVideoComposition.Configuration + AVMutableAudioMix
                 one AVVideoCompositing (Core Image/Metal): transitions, transforms, overlays, captions
                 incremental update, AVPlayerItem factory, AVAssetImageGenerator frames, async export
  AnalysisKit    actors over SpeechAnalyzer, Vision, SoundAnalysis, ffprobe; typed annotations cached per asset
  Providers      Klipy/Giphy memes, Pexels/Pixabay b-roll, TTS (Apple, Kokoro, ElevenLabs), Freesound, Splice MCP
  AgentKit       Tool registry (name, description, JSON Schema, annotations, handler) -> MCP server (swift-sdk + nio listener)
                 ApprovalPolicy gate; AgentRuntime: Claude Code CLI sidecar first, Messages API later; Foundation Models for cheap passes
  App            SwiftUI shell; timeline as NSViewRepresentable Metal view; AVPlayerLayer preview; approval cards
```

Dependencies point inward: `TimelineCore` imports nothing but Foundation; `RenderKit` depends on `TimelineCore`; the App depends on everything.

### The document

Defined normatively in `docs/design/timeline-model.md`: a project holds assets and sequences; a sequence holds ordered tracks, transitions as first-class objects between adjacent clips, and markers; clips carry link groups (video and audio from one asset move together), rational times, speed, and `Animatable` transform, opacity, effects, and gain (constants only in v1); caption items are clips on caption tracks. Every mutation is a command with an edit mode (ripple or overwrite) that `decide` turns into invertible events; undo is linear across human and agent; the human's commands apply unconditionally while the agent's carry an expected version and receive a diff on conflict. One command per gesture, one batch per agent step.

### Tool surface (keep about 15 visible; defer the rest via tool search)

Every tool takes a `projectId` (default: the frontmost project); `project_list` enumerates open projects.
Senses: `project_describe(level: summary | tracks | full, range?)`, `media_import`, `media_analyze(level)`, `transcript_search`, `look_at(asset, timestamps)` returns a contact sheet image, `get_moments`.
Hands: `align_audio(referenceAsset, targetAsset, parameters?)` returns offset, drift ppm, confidence, candidates, proof image; `timeline_apply({ ops[], expectedVersion })` with client ids and `$ref` back-references, `timeline_query`, `caption_add(style, source)`, `transition_add`, `overlay_add` (meme, image, text), `effect_add`, `audio_mix` (duck under speech, normalize LUFS), `find_broll`, `find_meme`, `generate_tts`.
Output: `render_preview(range)`, `render_export(preset)`, `export_fcpxml`.

Mutating tools return `{ version, changedIds, warnings }`; a stale `expectedVersion` returns `ChangedSince`. Expensive tools (`render_export`, cloud generation) are gated server-side by an `ApprovalPolicy`: without a granted approval token they return `{ status: "approval_required", approvalToken, estimate }`, the app shows an approval card, and the agent retries with the token. This holds for every client, Claude Code included; runtime-side hooks only improve the UX. No tool returns logs. Procedures such as "TikTok captions" or "jump-cut talking head" are Agent Skills (SKILL.md) that sequence these tools.

### Testing pyramid

| Layer | Tooling | Needs media? |
|---|---|---|
| Command decide, event evolve/invert, invariants, history fold, JSON round trip | Swift Testing, property-style generators | no |
| Compiler Project -> AVComposition (track count, segments, time ranges, instructions) | Swift Testing on the composition objects | no |
| Compositor frames | synthetic assets written in-test with AVAssetWriter (solid colors, test pattern); `AVAssetImageGenerator` + swift-snapshot-testing with perceptual tolerance | synthetic only |
| Tool contracts | every tool has JSON Schema, descriptions on all fields, example payload validates | no |
| Agent scenarios | fake model replays recorded tool calls through the real loop; graders assert on document JSON | no |
| LLM evals | 20-50 tasks nightly with a real model, state-based graders (promptfoo/Braintrust) | tokens |
| Export smoke | full export of a fixture project, ffprobe/AVAsset assertions on codec, color tags, duration | yes |

## AI senses pipeline (run at import, cached per asset hash)

probe -> proxy (only if needed for UI thumbnails) -> transcript (SpeechAnalyzer default; WhisperKit + SpeakerKit for diarization, acoustic word offsets, unsupported locales, or pre-macOS-26 hosts; cloud fallback) -> silence ranges -> shot boundaries and keyframes -> face/saliency boxes (Vision) -> OCR for screen recordings (Vision) -> loudness and beats -> VLM descriptions per shot (local Qwen3-VL via Ollama, or Claude on contact sheets, or Gemini agentic video for whole-file narrative) -> `moments.json` of scored highlights.

SpeechAnalyzer, as measured here: runs from a plain, ad-hoc-signed CLI process with no entitlement, bundle, or TCC prompt; the model runs out of process (about 100 MB system-side, 20 MB in the client); 71 s of audio in 1.07 s wall; locale assets are about 85 MB each, download silently in a few seconds, and a process may hold at most 5 reserved locales, so an app must call `assetInstallationRequest` per locale and `release(reservedLocale:)` when done. Every `AttributedString` run is one word with `audioTimeRange` and `transcriptionConfidence`; timestamps sit on a 60 ms grid and a word's end equals the next word's start (or the pause start), not its acoustic offset. Consume `transcriber.results` in a task started before `analyzeSequence`, and ignore the ranges on volatile results, which are bogus. Confidence flagged exactly the doubtful proper nouns (0.44 to 0.58) and is usable for "highlight uncertain words". Word error rate on synthetic speech was 7.7% after number normalization, with names and compounds as the residual; Apple offers `SFCustomLanguageModelData` for vocabulary but no free-text prompt, which is where Whisper's initial prompt helps with names. `yap` is a wrapper over the same API with identical output.

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

Typical case: a 5-minute DAW render that sits somewhere inside a much longer camera recording (an hour-plus set). Cross-correlation is symmetric, so it finds where the short render lands in the long video regardless of which side is shorter; the long video's audio is the reference timebase and is never retimed. Compute the long video's onset envelope once at import and cache it, then correlate each DAW render against it. Normalize for partial overlap so a render near the start or end of the video is not penalized, and treat several strong peaks (the same song played twice in the set) as candidates for the user to pick. Well solved; Final Cut, Premiere, and Resolve all sync by waveform. Use cross-correlation, not discrete feature points: coarse pass on onset envelopes at 8 kHz via FFT cross-correlation (vDSP), fine pass with phase-transform (GCC-PHAT) correlation on 48 kHz audio plus parabolic interpolation for sub-sample accuracy, then windowed offsets fitted with a Theil-Sen line to estimate clock drift in ppm, then a second fine pass on the drift-corrected render. Confidence comes from fine-pass verification of each coarse candidate (inlier fraction and residual of the drift fit, per-window PHAT peak ratio), not from the coarse peak ratio, which collapses long before the alignment becomes unrecoverable. Correct drift by plain resampling (a 10-50 ppm pitch change is inaudible). Replacing camera audio needs under one frame of accuracy; mixing needs under 0.1 ms or comb filtering appears, and mixing a drifted render requires the ppm correction since 23 ppm alone slips 5.5 ms over 4 minutes.

Measured on this machine with synthetic signals (pink noise, AGC-style compression, extra bass and rumble only in the camera, different EQ and reverb on the render, 23 ppm drift): offset error about 0.02 ms, of which most is the render's EQ phase, down to -10 dB SNR; drift recovered to 0.1 ppm; a repeated song reported as two verified candidates rather than a confident wrong answer; -15 dB SNR reported as no alignment rather than a false positive; 0.7 s total for a 60-minute camera track and 1.1 s for 120 minutes on one core, dominated by the 48 kHz to 8 kHz decimation, which should stream from `AVAudioFile` so the camera audio is never resident. Onset envelopes cannot distinguish two performances with identical rhythm; a chroma feature would rank them. Real footage (crowd, HVAC, speech, codecs) will move the thresholds and has not been tested. vDSP details that matter: the packed real FFT keeps DC and Nyquist together in bin 0 and must be multiplied separately, forward and inverse scaling compound to 4N for a correlation, and normalization needs an energy floor over near-silent stretches. ShazamKit custom catalogs remain a free coarse cross-check via `matchOffset`. Research in 08-audio-alignment.md; reference implementation in `spikes/audio-align`.

## Design documents

- `docs/design/timeline-model.md`: the normative document model, commands, events, invariants, edit modes, undo semantics. Where other documents disagree with it, it wins.
- `docs/design/storage.md`: media library layout, per-project event-sourced SQLite, projections, crash recovery, cache database.
- `docs/design/implementation-plan.md`: shared foundation first, then six parallel modules, then integration.
- `spikes/`: throwaway but inspectable reference implementations (compositor, preview-update, audio-align, mcp-server, speech, event-store), each with a `SPIKE.md` recording exact APIs, measurements, and gotchas. Phase 1 agents should read the one for their module.

## Open questions

Decided 2026-09-08:

- **Blend space is a project setting**, `settings.blendSpace: gamma | linear`, defaulting to `gamma` because it matches what Final Cut and Premiere do to the same footage and what viewers expect from a crossfade. The compositor honours it for every dissolve, opacity, and overlay (Core Image with `workingColorSpace` unset for gamma, the default linear working space otherwise); the agent can set it per project and it is recorded in `ProjectCreated`/`ProjectSettingsChanged`.
- **Import copies** originals into `Library/`; move and reference-in-place stay as options.
- **No bundled ffmpeg in v1.** Homebrew `ffmpeg-full` during development for probing and the odd export; nothing in the render path depends on it.
- **Timeline UI is native AppKit/Metal.** The WKWebView hedge is retired.
- **Embedded agent behind an `AgentRuntime` protocol**, first implementation the Claude Code CLI sidecar (see "What native costs").
- **Alignment thresholds are configurable.** `AlignmentParameters` (bandpass edges, envelope hop, minimum overlap, candidate cutoff, fine window length and count, inlier tolerance, verification fractions, drift floor) is a value type with the spike's defaults, adjustable per call from the tool and per project from settings, so real-footage tuning is data, not code.
- **Caption rendering** is Core Text inside the compositor; libass is an ASS import option only.

Still open, resolved by real footage during Phase 1 and 2: HDR and 10-bit through the custom compositor (flags and formats compile, no HDR media pushed through yet) and alignment thresholds on real recordings (synthetic results hold to -10 dB against pink noise). Still open in AVFoundation: the root cause of the bimodal audio startup cost for new player items; the interactive promise therefore rests on the video-only gesture item, and `readyToPlay` is logged so the slow regime is visible in the field. Worth a follow-up spike: a separate audio-only player slaved to the video player's timebase so structural video edits never pay the audio cost.

## Test footage on this machine

Real clips in `~/Downloads`, probed 2026-09-08. They cover every platform constraint the design has to handle and are the Phase 1 and 2 test inputs (referenced by path in a local, uncommitted config; never copied into the repo).

| File | What it is | Why it matters |
|---|---|---|
| `IMG_1575.MOV` (2.4 GB, 4:00) and `IMG_1581.MOV` (1.6 GB, 2:15) | iPhone 17e, iOS 26.6.1, HEVC 3840x2160 `yuv420p10le`, BT.2020 HLG (`arib-std-b67`), Dolby Vision configuration record, ambient viewing environment metadata, display matrix rotation -90 (portrait), nominal 59.94/60 fps but variable (avg 59.87 fps and 59.99 fps), stereo AAC 48 kHz plus a second 4-channel track ffprobe reports as `unknown` (APAC spatial audio), QuickTime creation date and make/model tags | The HDR compositor test, portrait handling, VFR, explicit audio stream selection, metadata indexing, and long-file alignment reference |
| `Screen Recording 2026-05-20 at 10.48.59 AM.mov` (10.6 MB, 1:23) | macOS Cmd-Shift-5, H.264 1162x1234 (odd width, window capture), BT.709, timebase 600 with variable frame rate (avg 56.7 fps), no audio | Even-dimension scaling, VFR, silent source |
| `1.mov` (35 MB, 0:08) | H.264 3014x1536, 120 fps nominal, variable (avg 55.5 fps), BT.709, no audio | High-rate and odd-dimension source |
| `Trailer-100k.mp4` (36 MB, 0:40) | H.264 1920x1080p24 constant, BT.709, stereo AAC | The plain control clip |

Missing from this set and needed for the DAW scenario: a long camera recording of a performance with a matching DAW render. Until one exists, the synthetic generator in `spikes/audio-align` is the alignment fixture.
