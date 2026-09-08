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
- `AudioAligner`: `align(reference: AudioSource, target: AudioSource) -> Alignment`.
- `Tool` and `ToolRegistry`: name, description, JSON Schema for input and output, annotations, handler; `ToolContext` giving access to the store and services.
- DTOs shared across modules (`Alignment`, `Transcript`, `ShotList`, `Probe`, `CommandResult`, `ProjectChange`).
- `ContractsTestSupport`: fakes for every protocol; `TestMedia` generator.

Exit criteria: all `TimelineCore` tests green; every protocol has a fake and a compile-checked usage example; the six module directories exist with an empty test target each.

## 3. Phase 1: parallel modules (one agent each)

| Module | Owns | Depends on | Tests against | Definition of done |
|---|---|---|---|---|
| `ProjectStore` | `storage.md` sections 3 to 12: GRDB 7 schema, migrations, event append with optimistic concurrency, idempotent commands, projections, history, rebuild, cache.sqlite | Core, Contracts | in-memory SQLite | Stale version rejected; duplicate command returns stored result; rebuild reproduces state byte-for-byte; golden fixture replays |
| `RenderKit` | Project to `AVMutableComposition` compiler; one `AVVideoCompositing` Metal compositor (cuts, crossfade, transforms, opacity, captions via Core Text); player item; frame grab; export via async `AVAssetExportSession`; HDR pixel formats | Core, Contracts, TestMedia | synthetic media | Composition structure asserted for fixture projects; frame snapshots for a cut, a crossfade, a caption; export of a fixture passes probe assertions |
| `MediaKit` | Library import (hash, sidecar, date folders), relink, probe, proxies, thumbnails sprite sheets, waveform peaks, onset envelope, SpeechAnalyzer transcription, silence, shots; cache index | Core, Contracts, TestMedia | synthetic media, real sample clips locally | Import is idempotent by hash; every artifact is content-addressed; transcript of the synthetic speech fixture matches |
| `AudioAlign` | Coarse onset-envelope FFT correlation, GCC-PHAT refinement, parabolic interpolation, windowed drift fit, confidence, candidate list, proof image data | Core (RationalTime), Accelerate | synthetic signals with known offset and drift | Recovers offset within 0.1 ms and drift within 2 ppm on synthetic tests; degrades to `ambiguous` on repeated material |
| `AgentKit` | `ToolRegistry` implementation, MCP server over Streamable HTTP (swift-sdk), the initial tool set, JSON Schema generation and contract tests, Skills folder, tool receipts | Core, Contracts (fakes) | fakes | Every tool has strict schema and example payload; `timeline_apply` round-trips through a fake store; Claude Code can list and call tools against fakes |
| `TimelineUI` | SwiftUI shell; timeline `NSViewRepresentable` Metal view (ruler, tracks, clips, filmstrips, waveforms, playhead, trim/move/split gestures, snapping); inspector; approval cards | Core, Contracts (fakes) | fakes + snapshot tests | Renders fixture projects; gestures emit `Command`s to the fake store; undo/redo drives history from the fake |

Interface changes during Phase 1 follow one rule: propose the `Contracts` change in a small PR, the integration owner merges it, every agent rebases. Fakes are updated in the same PR.

## 4. Phase 2: integration (one agent, the integration owner)

1. `App` composition root wires real `ProjectStore`, `RenderKit`, `MediaKit`, `AudioAlign`, `AgentKit`, `TimelineUI`.
2. The three-clip scenario from the research brief: import two iPhone HDR clips and a screen recording, cut, crossfade, animated caption, play, export HEVC, and drive it from Claude Code over MCP.
3. The DAW scenario: import a long camera recording and a short DAW render, run `align_audio`, apply, A/B preview.
4. End-to-end tests on fixture media in CI; manual test on real footage.

## 5. Phase 3 and beyond (parallel again)

Senses pipeline depth (faces, OCR, beats, VLM descriptions, moments), Providers (memes, b-roll, TTS, music), embedded agent and Skills, export presets, FCPXML export. Each is a new leaf module or an extension inside an existing one, following the same rules.

## 6. Does this accommodate parallel agents?

Yes, once Phase 0 is done. The shared surface is two packages and a test-support target. Six modules then proceed independently against fakes, and the only coordination point is a `Contracts` change. The risk is Phase 0 freezing interfaces too early; mitigate by having the Phase 1 agents each write a short "how I will use Contracts" note at kickoff, and folding disagreements back into `Contracts` before they start coding.
