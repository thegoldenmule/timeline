# Implementation plan

Status: draft, 2026-09-08. Goal: a module layout and phase order that lets several coding agents work in parallel, each in its own module and worktree, without stepping on each other. Shared code is built first; modules then depend only on that shared code, never on each other; integration comes last.

## 1. Dependency graph

```
                    ┌──────────────┐
                    │ TimelineCore │  pure Swift, Foundation only
                    └──────┬───────┘
                           │
                    ┌──────┴───────┐
                    │  Contracts   │  protocols + DTOs + in-memory fakes
                    └──────┬───────┘
      ┌──────────┬─────────┼──────────┬───────────┬───────────┐
      ▼          ▼         ▼          ▼           ▼           ▼
 ProjectStore  RenderKit  MediaKit  AudioAlign  AgentKit   TimelineUI
 (SQLite)      (AVF)      (+Analysis) (vDSP)    (MCP/tools) (SwiftUI/Metal)
      └──────────┴─────────┴──────────┴───────────┴───────────┘
                                   │
                                   ▼
                                  App   (composition root; wires real implementations)
```

Rules that make parallel work safe:

1. **Leaf modules import only `TimelineCore` and `Contracts`.** Never a sibling. If module B needs something from module C, it goes through a protocol in `Contracts`, and that change lands first as its own small PR.
2. **`Contracts` ships fakes.** Every protocol has an in-memory fake in `ContractsTestSupport` (fake store, fake renderer that records calls, fake analyzer returning fixture data). Modules test against fakes, so `TimelineUI` can be built before `RenderKit` exists.
3. **Shared test media is generated, not checked in.** `TestMedia` writes short synthetic clips with `AVAssetWriter` (color bars, tone, a clip with a known transient pattern) into a temp dir. Every module's tests that need media use it.
4. **One package, one test target, one owner per module.** `swift test --filter <Module>` must pass in isolation, with no App target built.
5. **One worktree per agent.** Branch names `module/<name>`. Only the integration owner touches `App` and `Contracts` during Phase 1.

## 2. Phase 0: shared foundation (sequential, one agent)

This phase is the bottleneck by design; everything after it depends on its shapes being stable. Definition of done is "the interfaces are frozen enough that a change is a deliberate, reviewed event."

**Repo scaffold**
- Swift package at repo root with targets listed above; `Package.swift` with strict concurrency on.
- `make test`, `make lint` (swift-format), CI script that runs both.
- `docs/design/conventions.md`: module ownership, branch and PR rules, how to change `Contracts`.

**`TimelineCore`** (the storage design's pure core lives here)
- `RationalTime { value: Int64, timescale: Int32 }` with exact rescale, comparison, arithmetic; conversion to and from `CMTime` lives in `RenderKit`, not here.
- IDs: `UUIDv7`-based typed IDs (`ClipID`, `TrackID`, `AssetID`, ...).
- `Project` value type and `Codable` JSON matching `docs/design/storage.md` section 8.
- `Command` enum (what callers ask for) and `DomainEvent` enum (what happened), with the event catalog from `storage.md` section 7, `schemaVersion`, and upcasters.
- `decide(state, command) throws -> [DomainEvent]`, `evolve(state, event) -> state`, `invert(event) -> [DomainEvent]`, and `Invariants.check(state)`.
- Fixture projects as JSON in `Fixtures/` plus a generator for random valid projects (for property tests).
- Tests: property tests on invariants and inversion, round-trip codec tests, upcaster tests.

**`Contracts`**
- `ProjectStore`: open/create, `apply(Command, expectedVersion, commandID, actor) -> CommandResult`, `state()`, `events(since:)`, `history()`, `rebuildProjections()`, change notifications (`AsyncStream<ProjectChange>`).
- `Renderer`: `compile(Project) -> Compiled`, `playerItem(Compiled)`, `frame(Compiled, at: RationalTime) -> CGImage`, `export(Compiled, preset, to:) -> AsyncStream<Progress>`.
- `MediaLibrary`: `import(url) -> Asset`, `locate(contentHash)`, `probe(url)`.
- `Analyzer` family: `transcribe`, `detectSilence`, `detectShots`, `waveformPeaks`, `onsetEnvelope`, each returning typed results and a cache key.
- `AudioAligner`: `align(reference: AudioSource, target: AudioSource, parameters: AlignmentParameters) -> Alignment`, with `AlignmentParameters` a value type carrying the spike's defaults.
- `AgentRuntime`: `startSession(goal, tools, policy) -> AsyncStream<AgentEvent>` (turns, tool calls, approvals requested, cost), `approve(_:)`, `cancel()`; first implementation is the Claude Code CLI sidecar (`claude -p --output-format stream-json --mcp-config` against the app's MCP server); a Messages-API implementation can follow behind the same protocol.
- `Tool` and `ToolRegistry`: name, description, JSON Schema for input and output, annotations, handler; `ToolContext` giving access to the store and services.
- DTOs shared across modules (`Alignment`, `Transcript`, `ShotList`, `Probe`, `CommandResult`, `ProjectChange`).
- `ContractsTestSupport`: fakes for every protocol; `TestMedia` generator.

Exit criteria: all `TimelineCore` tests green; every protocol has a fake and a compile-checked usage example; the six module directories exist with an empty test target each.

## 3. Phase 1: parallel modules (one agent each)

| Module | Owns | Depends on | Tests against | Definition of done |
|---|---|---|---|---|
| `ProjectStore` | `storage.md` sections 3 to 12: GRDB 7.11 schema and migrations, event append with optimistic concurrency, idempotent commands with recorded outcomes, debounced full-state projection, bulk-written query tables, history and undo, rebuild, `commands` pruning, cache.sqlite | Core, Contracts | in-memory and on-disk SQLite | Stale version rejected and forced UNIQUE race rolled back; duplicate command returns stored result; rebuild reproduces state, clips, and history byte-for-byte on a 10,000-event fixture; under 0.5 ms per command on a small project; 10,000-event fold under 100 ms; `ValueObservation` delivers a change after `apply` |
| `RenderKit` | Project to `AVMutableComposition` compiler using `AVVideoComposition.Configuration` (the mutable classes are deprecated in macOS 26); one `AVVideoCompositing` Core Image/Metal compositor (cuts, crossfade, transforms, opacity, captions via Core Text) honouring `settings.blendSpace` (default gamma; linear optional) and requesting native YUV source frames or tagging colour explicitly; player item with `seekingWaitsForVideoCompositionRendering`; frame grab; export via async `export(to:as:)`; HDR pixel formats and `perFrameHDRDisplayMetadataPolicy` | Core, Contracts, TestMedia | synthetic media (barcode-per-frame clips, as in `spikes/compositor`) | Composition structure asserted for fixture projects; frame snapshots for a cut, a crossfade, a caption in all three consumers; pure green survives the compositor unshifted; a red-to-green dissolve midpoint reads (128,128,0) in gamma mode and (188,188,0) in linear mode; export of a fixture passes probe assertions; `IMG_1575.MOV` from the test footage renders portrait, HLG-preserved, with the stereo AAC track and not the APAC track |
| `MediaKit` | Library import (hash, sidecar, date folders), relink, probe, proxies, thumbnails sprite sheets, waveform peaks, streaming 8 kHz onset envelope, SpeechAnalyzer transcription (results consumed concurrently, volatile ranges ignored, locale reservations managed within the 5-slot limit), silence, shots; cache index | Core, Contracts, TestMedia | synthetic media, `say`-generated speech, real sample clips locally | Import is idempotent by hash; every artifact is content-addressed; transcript of the synthetic speech fixture has per-word ranges and confidence and a word error rate under 10% |
| `AudioAlign` | Coarse onset-envelope FFT correlation, GCC-PHAT refinement with parabolic interpolation, Theil-Sen drift fit, drift-corrected second pass, per-candidate fine verification as the confidence signal, candidate list, proof image data; every threshold in `AlignmentParameters`, no magic numbers in code; envelopes consumed as streams so the long recording is never resident | Core (RationalTime), Accelerate | synthetic signals with known offset and drift (generator from `spikes/audio-align`) | Offset within 0.1 ms and drift within 1 ppm down to -10 dB SNR; repeated material yields two verified candidates marked ambiguous; -15 dB yields no alignment rather than a wrong one; under 2 s for a 2-hour recording |
| `AgentKit` | `ToolRegistry` implementation; `AgentRuntime` with the Claude Code CLI sidecar implementation (spawn, stream-json parsing, approval round-trip, cost accounting); MCP server on swift-sdk 0.12.1 (pinned exact) over both stdio and Streamable HTTP, with a swift-nio listener on 127.0.0.1, the SDK's default Origin/Host validation, an idle-session sweep, and one `Server` per HTTP session over shared editor state; the initial tool set with annotations, `structuredContent`, `outputSchema`, and image blocks; JSON Schema generation from `Codable` types and contract tests; Skills folder; tool receipts | Core, Contracts (fakes) | fakes, curl JSON-RPC transcript, `claude -p` headless run | Every tool has strict schema and example payload; `timeline_apply` round-trips through a fake store with stale-version rejection and idempotent retry; `claude mcp list` shows connected and a headless run invokes the tools, verified in the server log |
| `TimelineUI` | SwiftUI shell; timeline `NSViewRepresentable` Metal view (ruler, tracks, clips, filmstrips, waveforms, playhead, trim/move/split gestures, snapping); inspector; approval cards | Core, Contracts (fakes) | fakes + snapshot tests | Renders fixture projects; gestures emit `Command`s to the fake store; undo/redo drives history from the fake |

Interface changes during Phase 1 follow one rule: propose the `Contracts` change in a small PR, the integration owner merges it, every agent rebases. Fakes are updated in the same PR.

### Spike code as a starting point

`spikes/compositor`, `spikes/audio-align`, `spikes/mcp-server`, `spikes/speech`, and `spikes/event-store` are working references for RenderKit, AudioAlign, AgentKit, MediaKit, and ProjectStore respectively. Each `SPIKE.md` lists the exact APIs, measured numbers, and gotchas. Module agents may lift code, but the spikes are not the modules: they skip `Contracts`, use deprecated AVFoundation classes in one case, and have no tests beyond assertions.

## 4. Phase 2: integration (one agent, the integration owner)

1. `App` composition root wires real `ProjectStore`, `RenderKit`, `MediaKit`, `AudioAlign`, `AgentKit`, `TimelineUI`.
2. The three-clip scenario with the real footage listed in `docs/research/README.md`: import `IMG_1575.MOV`, `IMG_1581.MOV`, and the screen recording from `~/Downloads`, cut, crossfade in gamma space, animated caption, play, export HEVC HLG, and drive it from Claude Code over MCP and from the embedded `AgentRuntime`.
3. The DAW scenario: import a long camera recording and a short DAW render (synthetic from `spikes/audio-align` until a real pair exists), run `align_audio`, apply, A/B preview.
4. End-to-end tests on fixture media in CI; manual test on real footage.

## 5. Phase 3 and beyond (parallel again)

Senses pipeline depth (faces, OCR, beats, VLM descriptions, moments), Providers (memes, b-roll, TTS, music), embedded agent and Skills, export presets, FCPXML export. Each is a new leaf module or an extension inside an existing one, following the same rules.

## 6. Does this accommodate parallel agents?

Yes, once Phase 0 is done. The shared surface is two packages and a test-support target. Six modules then proceed independently against fakes, and the only coordination point is a `Contracts` change. The risk is Phase 0 freezing interfaces too early; mitigate by having the Phase 1 agents each write a short "how I will use Contracts" note at kickoff, and folding disagreements back into `Contracts` before they start coding.
