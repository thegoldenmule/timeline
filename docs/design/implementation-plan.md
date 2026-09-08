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
2. **`Contracts` ships fakes.** Every protocol has an in-memory fake in `ContractsTestSupport` (fake store, fake renderer that records calls and returns a real `AVPlayerItem` over a synthetic flat file, fake analyzer returning fixture data, fake thumbnail and waveform providers returning synthetic images). Modules test against fakes, so `TimelineUI` can be built before `RenderKit` exists.
3. **Shared test media is generated, not checked in.** `TestMedia` writes short synthetic clips with `AVAssetWriter` (color bars, tone, a clip with a known transient pattern, a barcode frame counter) into a temp dir. Every module's tests that need media use it.
4. **One package, one test target, one owner per module.** `swift test --filter <Module>` must pass in isolation, with no App target built. `Package.swift` declares every target, product, and external dependency (GRDB, swift-uuidv7, MCP swift-sdk, swift-nio, swift-snapshot-testing, DSWaveformImage) in Phase 0, so no module agent edits it.
5. **One worktree per agent.** Branch names `module/<name>`. Only the integration owner touches `App` and `Contracts` during Phase 1. `TimelineUI` is a library of views; `App` is the executable that composes them.
6. **Isolation is declared, not guessed.** `Contracts` may import AVFoundation and CoreGraphics. Every protocol method states its isolation: `@MainActor` for anything touching `AVPlayer`/`AVPlayerItem` or views, `nonisolated async` for pure work (frames, compile, analysis), actors for stateful services. Opaque handles such as `Compiled` are `Sendable` tokens whose contents live inside the owning module.
7. **Zero Swift 6 warnings** in every module is part of every definition of done.

## 2. Phase 0: shared foundation (sequential, one agent)

This phase is the bottleneck by design; everything after it depends on its shapes being stable. Definition of done is "the interfaces are frozen enough that a change is a deliberate, reviewed event."

**Repo scaffold**
- Swift package at repo root with targets listed above; `Package.swift` with strict concurrency on.
- `make test`, `make lint` (swift-format), CI script that runs both.
- `docs/design/conventions.md`: module ownership, branch and PR rules, how to change `Contracts`.

**`TimelineCore`** (implements `docs/design/timeline-model.md`, the normative model)
- `RationalTime { value: Int64, timescale: Int32 }` with exact rescale, 128-bit comparison, arithmetic; conversion to and from `CMTime` lives in `RenderKit`, not here.
- IDs: `UUIDv7`-based typed IDs (`ClipID`, `TrackID`, `AssetID`, `SequenceID`, `TransitionID`, `LinkGroupID`, ...), minted through an injectable `IDGenerator` so tests are deterministic; likewise an injectable `Clock`.
- `Project` value type and `Codable` JSON matching the model doc section 1: sequences, tracks, clips with link groups, transitions as entities, `Animatable` values (constant only in v1), caption items, markers.
- `Command` enum (model doc section 5) including edit modes, `unlinked`, client-supplied ids and `$ref` resolution for batches, `undo`/`redo`; `DomainEvent` enum (section 6) with `sequenceId` on every timeline event, `schemaVersion`, recursive upcasters for embedded snapshots.
- `decide(state, command) throws -> [DomainEvent]` (validation, ripple, link-group fan-out, transition handle checks), `evolve(state, event) -> state` plus the `inout` form used by the store and replay, `invert(event) -> [DomainEvent]`, `Invariants.check(state)`, the history fold (live/undone, redo stack), and `EditorError`.
- Fixture projects as JSON in `Fixtures/` (including one with linked clips, a transition, a caption track, and an undone transaction) plus a generator for random valid projects.
- Tests: property tests on invariants and inversion (including ripple keeping cross-track sync and link groups staying aligned), round-trip codec tests, upcaster tests, undo-redo-undo history folds.

**`Contracts`**
- `ProjectStore`: open/create, `apply(Command) -> CommandResult` (the command carries `commandId`, `actor`, optional `expectedVersion`), `state()`, `events(since:)`, `history()`, `rebuildProjections()`, change notifications (`AsyncStream<ProjectChange>`); `ChangedSince` DTO as defined in the model doc.
- `Renderer`: `compile(Sequence, assets, options: { audio: Bool }) -> Compiled`, `update(Compiled, to: Sequence) -> Update` where `Update` is either `.instructionsOnly(Compiled)` (segments unchanged: the caller sets `videoComposition` and `audioMix` on the live player item) or `.structural(Compiled)` (a new player item is required), `@MainActor playerItem(Compiled) -> AVPlayerItem`, `frame(Compiled, at: RationalTime) -> CGImage`, `export(Compiled, ExportPreset, to: URL) -> Job`. `Compiled` carries a structural fingerprint of track segments separate from the instruction and audio-mix payload so `update` can diff. A composition handed to a player is frozen; nothing ever mutates it in place. `ExportPreset` is a Codable value here so render receipts are stable.
- `JobRunner`: `submit(Job) -> JobHandle` with `AsyncStream<Progress>`, `cancel()`, and a declared memory class per job; export, transcription, alignment, hashing, and import copying all run through it, and the runner enforces the memory budget from the platform decisions.
- `MediaLibrary`: `import(url, mode: copy|move|reference) -> Asset` (as a job), `locate(contentHash)`, `probe(url)`, `relink(assetId, url)`.
- `ThumbnailProvider` and `WaveformProvider`: filmstrip frames and peaks by asset and time range at a zoom level, what the timeline draws; the fakes return synthetic images and peaks.
- `Analyzer` family: `transcribe`, `detectSilence`, `detectShots`, `waveformPeaks`, `onsetEnvelope`, each returning typed results and a cache key, each cancellable.
- `AudioAligner`: `align(reference: AudioSource, target: AudioSource, parameters: AlignmentParameters) -> Alignment`, with `AlignmentParameters` a value type carrying the spike's defaults.
- `AgentRuntime`: `startSession(goal, tools, policy) -> AsyncStream<AgentEvent>` (turns, tool calls, approvals requested, cost), `approve(_:)`, `cancel()`; first implementation is the Claude Code CLI sidecar (`claude -p --output-format stream-json --mcp-config` against the app's MCP server); a Messages-API implementation can follow behind the same protocol.
- `Tool` and `ToolRegistry`: name, description, JSON Schema for input and output, annotations, handler; `ToolContext` giving access to the open projects, the store, and services. Tools take a `projectId` (default: frontmost) because a document-based app has several projects open.
- `ApprovalPolicy` and `ToolReceipt`: the policy decides per tool call whether it needs approval (by tool, by estimated cost or duration); expensive tools return `{ status: "approval_required", approvalToken, estimate }` until the app's approval card grants the token, regardless of which agent runtime is calling. This is the authoritative gate; runtime-side hooks are UX integration on top of it.
- `EditorError` taxonomy shared by store, tools, and UI.
- DTOs shared across modules (`Alignment`, `AlignmentParameters`, `Transcript`, `ShotList`, `Probe`, `CommandResult`, `ProjectChange`, `ChangedSince`, `ExportPreset`, `Progress`).
- `ContractsTestSupport`: fakes for every protocol; `TestMedia` generator.

Exit criteria: all `TimelineCore` tests green; every protocol has a fake and a compile-checked usage example; `Package.swift` declares every target and dependency; the six module directories exist with an empty test target each.

## 2b. Phase 0.5: walking skeleton (one afternoon, the integration owner)

Before the module agents start, wire `App` to every fake end to end: open a fixture project from the fake store, show it in a placeholder timeline, play the fake renderer's player item, call one fake tool through the registry, run one fake job with progress. This proves the `Contracts` shapes compose and their isolation annotations are right while changing them is still cheap, and it means integration starts on day one rather than in Phase 2. Each Phase 1 agent also writes a short "how I will use Contracts" note at kickoff; disagreements are folded into `Contracts` before coding.

## 3. Phase 1: parallel modules (one agent each)

| Module | Owns | Depends on | Tests against | Definition of done |
|---|---|---|---|---|
| `ProjectStore` | `storage.md` sections 3 to 12: GRDB 7.11 schema and migrations, event append with optimistic concurrency, idempotent commands with recorded outcomes, debounced full-state projection, bulk-written query tables, history and undo, rebuild, `commands` pruning, cache.sqlite | Core, Contracts | in-memory and on-disk SQLite | Stale version rejected and forced UNIQUE race rolled back; duplicate command returns stored result; rebuild reproduces state, clips, and history byte-for-byte on a 10,000-event fixture; under 0.5 ms per command on a small project; 10,000-event fold under 100 ms; `ValueObservation` delivers a change after `apply` |
| `RenderKit` | Sequence to `AVMutableComposition` compiler using `AVVideoComposition.Configuration` (the mutable classes are deprecated in macOS 26), realizing transitions as overlaps on alternating tracks, `speed` via `scaleTimeRange`, slates for offline assets; one `AVVideoCompositing` Core Image/Metal compositor (cuts, crossfade, transforms, opacity, captions via Core Text) honouring `settings.blendSpace` (default gamma; linear optional), requesting native YUV source frames or tagging colour explicitly, with instruction lookup by time that is not O(n) per frame; `update` that diffs the segment fingerprint and returns an instructions-only payload (set `videoComposition`/`audioMix` on the live item: measured 2 ms paused, one frame playing) or a new item for structural edits, built video-only during gestures (10 ms paused, about 50 ms playing) and with audio on gesture end, seeked while detached and swapped with a second `AVPlayer` and layer so the picture never freezes; never mutates a live composition (measured: silently ignored while paused, a 0.4 to 1.6 s stall while playing); player item with `seekingWaitsForVideoCompositionRendering`; frame grab; export as a `Job` via async `export(to:as:)`; HDR pixel formats and `perFrameHDRDisplayMetadataPolicy` | Core, Contracts, TestMedia | synthetic media (barcode-per-frame clips, as in `spikes/compositor`) and the real footage in `~/Downloads` | **Milestone 1, before any transition or caption:** `IMG_1575.MOV` renders portrait, HLG-preserved, colour-checked, with the stereo AAC track and not the APAC track. Then: composition structure asserted for fixture projects including a transition with handles; frame snapshots for a cut, a crossfade, a caption in all three consumers; pure green survives the compositor unshifted; a red-to-green dissolve midpoint reads (128,128,0) in gamma mode and (188,188,0) in linear mode; edit-to-first-updated-frame latency on a 200-clip sequence, median of 5, of at most 10 ms paused and 40 ms playing for instruction-only edits, at most 50 ms paused for structural edits on the video-only item, at most 150 ms for the audio-bearing swap, and never a frozen picture while playing; scrubbing at 30 seeks per second with `cancelAllPendingVideoCompositionRequests` does not grow memory; export of a fixture passes probe assertions |
| `MediaKit` | Library import as a cancellable job (copy by default, hash, sidecar, date folders, linked video+audio asset description), relink by hash, offline detection, probe, proxies, thumbnail sprite sheets and the `ThumbnailProvider`, peaks and the `WaveformProvider`, streaming 8 kHz onset envelope, SpeechAnalyzer transcription (results consumed concurrently, volatile ranges ignored, locale reservations released within the 5-slot limit), silence, shots; cache index | Core, Contracts, TestMedia | synthetic media, `say`-generated speech, real sample clips locally | Import is idempotent by hash and cancellable mid-copy without leaving partial files; re-import of a moved file resolves by hash and relinks; every artifact is content-addressed and invalidated by `params_hash`; transcript of the synthetic speech fixture has per-word ranges and confidence and a word error rate under 10%; locale reservation is released after use |
| `AudioAlign` | Coarse onset-envelope FFT correlation, GCC-PHAT refinement with parabolic interpolation, Theil-Sen drift fit, drift-corrected second pass, per-candidate fine verification as the confidence signal, candidate list, proof image data; every threshold in `AlignmentParameters`, no magic numbers in code; envelopes consumed as streams so the long recording is never resident | Core (RationalTime), Accelerate | synthetic signals with known offset and drift (generator from `spikes/audio-align`) | Offset within 0.1 ms and drift within 1 ppm down to -10 dB SNR; repeated material yields two verified candidates marked ambiguous; -15 dB yields no alignment rather than a wrong one; under 2 s for a 2-hour recording |
| `AgentKit` | `ToolRegistry` implementation with `projectId` on every tool and `project_list`; `ApprovalPolicy` enforcement inside tool handlers (`approval_required` + token); `AgentRuntime` with the Claude Code CLI sidecar (spawn with `--strict-mcp-config`, inline `--mcp-config` carrying a per-launch bearer token, `--permission-mode dontAsk`, `--allowedTools` scoped to this server, `--max-budget-usd`, `--model` per pass, `--append-system-prompt`, cwd set to an app-owned directory holding the Skills folder; stream-json parsed tolerantly with recorded transcripts as fixtures; `--resume` for multi-turn; a `PreToolUse` hook that forwards approval requests to the app's approval card as UX on top of the server-side gate; detection of `claude` presence and login state with graceful "MCP only" degradation; cost accounting from the result event); MCP server on swift-sdk 0.12.1 (pinned exact) over Streamable HTTP with a swift-nio listener on 127.0.0.1, bearer-token check plus the SDK's Origin/Host validation, an idle-session sweep, one `Server` per HTTP session over shared editor state, and a stdio proxy binary that forwards to the running app; the initial tool set with annotations, `structuredContent`, `outputSchema`, and image blocks; hand-maintained JSON Schemas with a contract test that every fixture `Command` validates against its schema's example; Skills folder; tool receipts | Core, Contracts (fakes) | fakes, curl JSON-RPC transcript, recorded `claude -p` transcripts, one live headless run | Every tool has strict schema and example payload; `timeline_apply` round-trips through a fake store with stale-version rejection, `$ref` resolution, and idempotent retry; `render_export` without an approval token returns `approval_required` and with a granted token proceeds; the approval round-trip works through the hook; a request without the bearer token is refused; `claude mcp list` shows connected and a headless run invokes the tools, verified in the server log; a second `AgentRuntime` stub (Messages API) compiles against the protocol |
| `TimelineUI` | Library of views: timeline `NSViewRepresentable` Metal view (ruler, tracks, clips with link-group and transition rendering, filmstrips via `ThumbnailProvider`, waveforms via `WaveformProvider`, playhead, trim/move/split gestures with local preview and one command on release, snapping, ripple/overwrite modifier); inspector; approval cards; job progress | Core, Contracts (fakes) | fakes + snapshot tests | Renders fixture projects including linked clips and a transition; each gesture emits exactly one `Command` to the fake store on release; undo/redo drives history from the fake; 60 fps at 1,000 clips across 5 zoom levels; the approval card round-trips an `approval_required` result |

Interface changes during Phase 1 follow one rule: propose the `Contracts` change in a small PR, the integration owner merges it, every agent rebases. Fakes are updated in the same PR.

### Spike code as a starting point

`spikes/compositor` and `spikes/preview-update`, `spikes/audio-align`, `spikes/mcp-server`, `spikes/speech`, and `spikes/event-store` are working references for RenderKit, AudioAlign, AgentKit, MediaKit, and ProjectStore respectively. Each `SPIKE.md` lists the exact APIs, measured numbers, and gotchas. Module agents may lift code, but the spikes are not the modules: they skip `Contracts`, use deprecated AVFoundation classes in one case, and have no tests beyond assertions.

## 4. Phase 2: integration (one agent, the integration owner)

1. `App` composition root replaces the walking skeleton's fakes with real `ProjectStore`, `RenderKit`, `MediaKit`, `AudioAlign`, `AgentKit`, `TimelineUI`, one module at a time.
2. The three-clip scenario with the real footage listed in `docs/research/README.md`: import `IMG_1575.MOV`, `IMG_1581.MOV`, and the screen recording from `~/Downloads`, cut, crossfade in gamma space, animated caption, play, export HEVC HLG, and drive it from Claude Code over MCP and from the embedded `AgentRuntime`.
3. The DAW scenario: import a long camera recording and a short DAW render (synthetic from `spikes/audio-align` until a real pair exists), run `align_audio`, apply, A/B preview.
4. End-to-end tests on fixture media in CI; manual test on real footage.

## 5. Phase 3 and beyond (parallel again)

Senses pipeline depth (faces, OCR, beats, VLM descriptions, moments), Providers (memes, b-roll, TTS, music), embedded agent and Skills, export presets, FCPXML export. Each is a new leaf module or an extension inside an existing one, following the same rules.

## 6. Does this accommodate parallel agents?

Yes, once Phase 0 and the walking skeleton are done. The shared surface is two packages and a test-support target, with every dependency pre-declared and every protocol's isolation written down. Six modules then proceed independently against fakes, and the only coordination point is a `Contracts` change. The residual risk is Phase 0 freezing interfaces too early; the kickoff notes and the walking skeleton exist to surface that before it costs anything.
