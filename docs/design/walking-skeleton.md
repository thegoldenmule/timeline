# Walking skeleton

Status: done, 2026-09-08. Phase 0.5 of `implementation-plan.md` section 2b: `TimelineApp` wired end to end
against the fakes in `ContractsTestSupport`, before any Phase 1 module exists. `swift run TimelineApp`
opens the window; `swift run TimelineApp --skeleton-check` runs the same flow headlessly and exits 0.

## What is wired

`Sources/TimelineApp`, an SPM `executableTarget` with no Xcode project and no `Info.plist`:

| File | Role |
|---|---|
| `TimelineApp.swift` | `@main` entry. `--skeleton-check` runs `SkeletonCheck` on the main actor under `dispatchMain()` and exits with its verdict; otherwise the SwiftUI `App` starts. The `NSApplicationDelegate` sets `NSApplication.shared.setActivationPolicy(.regular)` and activates, which an unbundled executable needs before a window appears. |
| `AppServices.swift` | The composition root: one `any` existential per service, built by `AppServices.fakes()`. `OpenProjects` is the app-owned `ProjectDirectory` tools resolve `projectId` against. `callTool` is the single registry entry point. |
| `DemoTools.swift` | Three thin tools registered in the `InMemoryToolRegistry`: `project_describe` (read-only summary), `timeline_apply` (one `Command.Operation` through `ProjectStore.apply`, `commandId` defaulting to a hash of the input so a retry replays), `render_export` (gated by the standard `ApprovalPolicy`; with a granted token it compiles the active sequence and runs the renderer's export job through the runner). `DemoAgentScript` is what the fake runtime replays. |
| `ProjectDocument.swift` | `@MainActor @Observable` mirror of one open store: `state()`, `history()`, a subscription to `changes`, the compiled active sequence, and an `AVPlayer` holding `Renderer.playerItem(for:)`. On every change it re-reads state, runs `Renderer.update`, and either calls `Renderer.apply(_:to:)` on the live item (`.instructionsOnly`) or builds a new item, seeks it while detached, and `replaceCurrentItem` (`.structural`). `renderedVersion` says which project version the player reflects. |
| `Consoles.swift` | `JobConsole` (submits a job that calls the fake analyzer and waveform provider and mirrors `JobHandle.progress`), `ToolConsole` (calls a tool as `.human`), `AgentConsole` (streams `AgentEvent`s, executes announced tool calls through the registry, turns `.approvalRequested` into an approval card, grants through the gate). |
| `Views.swift` | The window: an `AVPlayerView` wrapped in `NSViewRepresentable`, a `Canvas` placeholder timeline (tracks as rows, clips as rectangles shaded by opacity, the playhead from a periodic time observer), a status bar showing the last render path and player item generation, a sidebar with the agent transcript and approval card, job progress, the last tool result, and the history fold. Toolbar: Nudge clip (`moveClip`, structural), Fade clip (`setClipOpacity`, instructions-only), Undo, Redo, Run fake job, Call tool, Start agent. |
| `SkeletonCheck.swift` | The headless flow: open the fixture, wait for `readyToPlay`, nudge (assert version bump, change on the stream, structural update, new item ready), `timeline_apply` an opacity change (assert instructions-only, same item), `project_describe`, a job with progress, the scripted agent session including the approval round-trip, undo and redo. |

The headless output on this machine:

```
ok   open: Three clips v10, 3 assets, 2 tracks
ok   compile: structural 89fcaf97 duration 11.25s hasAudio true
ok   playerItem: readyToPlay, seekingWaitsForVideoCompositionRendering=true
ok   moveClip: v11 txn 00002a changed 1 ids; structural update, new player item ready
ok   timeline_apply: v12 via registry; instructions-only update applied to the live item
ok   project_describe: Three clips v12: 3 assets; V1 (3 clips), A1 (1 clips); 2 tracks in structured output
ok   job: Analyze IMG_1575.MOV: 4 progress events, silence 2 shots 3 peaks 301
ok   agent: 13 entries, finished "Exported Reel 9:16." cost $0.03; export gated, granted, retried, wrote Reel 9:16.mp4
ok   undo/redo: v12 -> v14 -> v16, 12 live transactions

Skeleton check passed: 9 steps in 0.59 seconds
```

### How the agent round-trip works

The fake runtime only replays a script; it never calls tools. The app therefore runs the tool calls the
runtime announces (`.toolCall`) through the registry itself, which is the shape a Messages-API runtime
has anyway (the client executes tools). The script's `render_export` call hits the gate without a token,
so the registry answers `approval_required` and the gate publishes an `ApprovalRequest` on `requests`.
When the runtime then emits `.approvalRequested`, the console pairs it with the gate's pending request
for the same tool and shows one card. Approve does three things in order: `ApprovalGate.grant(token)`,
retry the held call with `approvalToken` (the gate consumes the token and the export runs), then
`AgentSession.approve(_:verdict:)` so the script continues to `.finished`. Deny denies the gate request
and answers the session with `.deny`.

With the CLI sidecar the tool calls happen inside the MCP server instead, and the `PreToolUse` hook
forwards the gate's request; the console's `.toolCall` branch then becomes a no-op. See the proposal
below about which `ApprovalRequest` the event should carry.

## Phase 2 swap points

All in `AppServices.fakes()`; each is one line. Nothing outside that function names a concrete type.

| Service | Skeleton | Phase 2 |
|---|---|---|
| `opener: any ProjectStoreOpening` | `FakeProjectStoreOpener` with the `three-clips` fixture registered at `/fixtures/three-clips.tlproj` | ProjectStore's SQLite opener over a real `.tlproj`; `ProjectDocument.open(at:using:)` stays as is |
| `renderer: any Renderer` | `FakeRenderer` (synthetic clip, fingerprint-based `update`) | RenderKit |
| `jobRunner: any JobRunner` | `FakeJobRunner` (unlimited budget, `.concurrent`) | the budgeted runner (`JobBudget.conservative`) |
| `mediaLibrary`, `thumbnails`, `waveforms`, `analyzer` | `FakeMediaLibrary`, `FakeThumbnailProvider`, `FakeWaveformProvider`, `FakeAnalyzer` | MediaKit |
| `aligner: any AudioAligner` | `FakeAudioAligner` | AudioAlign |
| `approvals: any ApprovalGate` | `FakeApprovalGate(policy: .standard)` | AgentKit's gate (same protocol; the UI only uses `grant`, `deny`, `pending`, `requests`) |
| `registry: any ToolRegistry` | `InMemoryToolRegistry` + `DemoTools` | AgentKit's registry with the real tools; `DemoTools` is deleted |
| `agentRuntime: any AgentRuntime` | `FakeAgentRuntime(script:)` | AgentKit's Claude Code sidecar; `ToolAccess` then carries the real MCP endpoint and bearer token |
| `receipts: any ToolReceiptSink` | `FakeToolReceiptSink` | the project's `commands` metadata via ProjectStore |
| `TimelineCanvas` | SwiftUI `Canvas` placeholder | TimelineUI's Metal `NSViewRepresentable`; it takes the same `ProjectDocument` (`project`, `sequence`, `playheadSeconds`) plus the providers |
| `PlayerView` | `AVPlayerView` wrapper | unchanged, or RenderKit's second-player swap for structural edits while playing |

`OpenProjects` and `ProjectDocument` are app code in every phase. `ProjectDocument.refreshRender` is the
place RenderKit's gesture path (video-only compile during a drag, audio on release) plugs in.

## Friction with Contracts

Nothing in `Contracts` blocked the skeleton, and the isolation annotations were right in every case the
app exercised:

- `Renderer.playerItem(for:)` and `apply(_:to:)` being synchronous `@MainActor` is exactly what a
  main-actor document wants: no hop, no `await`, and the `AVPlayerItem` never leaves the actor.
  `compile` and `update` being `nonisolated async` with `Sendable` `Compiled` tokens means the document
  awaits them without any `nonisolated(unsafe)` or `@unchecked`.
- `ProjectStore.changes` as a synchronous `var` was essential: the document subscribes *before* reading
  `state()`, so no transaction can slip between the two. `ProjectChange` not carrying the new state is
  fine; the document re-reads `state()` and `history()` (two actor hops per change, cheap on the fake).
- `JobHandle.progress` buffering unbounded means the UI can start mirroring after `submit` returns and
  still see every event; `AgentSession.events` and `ApprovalGate.requests` behave the same way.
- `ToolServices` optionals and `ToolContext.store(for:)` composed without ceremony; `OpenProjects` is
  30 lines.
- `AgentSession.approve` being `async` in the protocol while the fake is synchronous cost nothing.

Things worth knowing, none of which need a `Contracts` change:

- `Project.version` counts events, not transactions. An undo transaction is the `TransactionUndone`
  marker plus the compensating events, so `undo` advances the version by at least 2. The first version
  of the headless check asserted `+1` and failed; tools and agents must compare versions, never add.
- A `ProjectChange` arrives before the consumer has necessarily refreshed anything derived from it. The
  document exposes `renderedVersion`, set after `Renderer.update` has run, and the headless check waits
  on that rather than on the change itself. TimelineUI should do the same for "the picture reflects
  version N" assertions.
- SwiftUI exports `Transaction`; any view file that names TimelineCore's has to write
  `TimelineCore.Transaction`. `Sequence`, `Clock`, and `Actor` still resolve to TimelineCore's in files
  that import SwiftUI. TimelineUI will hit the same thing.
- The runtime's `.approvalRequested` and the gate's `ApprovalRequest` are two different values with two
  different tokens unless the runtime deliberately forwards the gate's. The app copes by matching on
  tool name, but see `contracts-proposals/app.md` for the doc-comment clarification that would make
  AgentKit forward the gate's request so the card can grant by id.

## Package.swift follow-ups (integration owner, not done here)

- `TimelineApp` should declare `linkerSettings: [.linkedFramework("AVKit"), .linkedFramework("AppKit")]`.
  Today AVKit links only because `Views.swift` references `AVPlayerView` directly. Using the SwiftUI
  overlay's `VideoPlayer` alone links `_AVKit_SwiftUI` but not `AVKit`, and the process aborts at launch
  with `failed to demangle superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC'`. The
  `PlayerView` wrapper stays regardless (it will host the second-player swap), but the explicit link
  removes the trap for the next person who reaches for `VideoPlayer`.
- `swift run TimelineApp --skeleton-check` belongs in `ci.sh` once CI runs on a machine with a window
  server session (AVFoundation playback needs one for `readyToPlay`; `swift test` already has the same
  requirement through `FakeRendererTests.playerItemReachesReadyToPlay`).
