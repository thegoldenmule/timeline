# Integration

Status: Phase 2 in progress, 2026-09-08. Supersedes the Phase 0.5 walking-skeleton note: `TimelineApp` is
now wired to the real modules end to end, with one fake left (the renderer, until RenderKit merges).
`swift run TimelineApp` opens the window; `swift run TimelineApp --skeleton-check` (`make e2e`) runs the
end-to-end check headlessly against a temporary library root and exits 0.

## What is real, what is fake

| Service | Implementation | Notes |
|---|---|---|
| `opener: any ProjectStoreOpening` | `ProjectStore.SQLiteProjectStoreOpener` | `.tlproj` packages under `<root>/Projects/`; `libraryRootHint` set to the root |
| `mediaLibrary` | `MediaKit.FileMediaLibrary` | copy into `Library/YYYY/YYYY-MM-DD/`, SHA-256, sidecar, `cache.sqlite` row |
| `cache` | `MediaKit.CacheIndex` | one index for the library, the analyzer, and both providers |
| `thumbnails`, `waveforms` | `AVThumbnailProvider`, `PeaksWaveformProvider` | over the same `CacheIndex`; TimelineUI draws filmstrips and peaks from them |
| `analyzer` | `MediaKit.AppleMediaAnalyzer` | silence, shots, peaks, onset envelope, SpeechAnalyzer transcription |
| `aligner` | `AudioAlign.OnsetAligner` | reads every tunable from `AlignmentParameters` (see contracts-notes.md) |
| `jobRunner` | `BudgetedJobRunner` (`Sources/TimelineApp/Services/`) | FIFO admission against `JobBudget.conservative`: bytes per memory class and `maxConcurrent` per class; cancellation before admission dequeues |
| `approvals` | `StandardApprovalGate` (`Sources/TimelineApp/Services/`) | random single-use tokens, `status(of:)` implemented, one gate shared by the tools, the MCP host, and the approval stack |
| `registry` | `AgentKit.EditorTools.standard(context:)` | the 15 real tools; `DemoTools` is gone |
| `mcpHost` | `AgentKit.MCPServerHost` | started at launch on 127.0.0.1 with a per-launch bearer token; `claude mcp add` line shown in the window's MCP section and logged; proxy config written |
| `agentRuntime` | `AgentKit.ClaudeCodeRuntime`, else `ToolLoopRuntime` over `FakeAgentRuntime` | `availability()` is probed at boot; when `claude` is missing or logged out the scripted fallback runs its tool calls through the registry itself (the client-side loop a Messages-API runtime has) |
| `receipts` | `ReceiptLog` (`Sources/TimelineApp/Services/`) | in memory plus `<root>/Cache/receipts.jsonl`; ProjectStore does not expose the project's `commands` metadata yet |
| `renderer` | **`FakeRenderer`** | the RenderKit swap point; see below |
| Timeline, inspector, approvals, jobs, agent, history | `TimelineUI` | `TimelineView(viewModel:)`, `InspectorView`, `ApprovalStackView`, `JobList`, `AgentPanelView`, `HistoryView` replace every placeholder view |

### The RenderKit swap point

`AppServices.boot` builds `let renderer = FakeRenderer()`; that line and the `renderer` field's doc comment
are the only places that name it. `ProjectDocument.refreshRender` runs `Renderer.update` on every change and
either applies instructions to the live `AVPlayerItem` or swaps in a new item (seeking it while detached);
RenderKit's gesture path (video-only compile during a drag, audio on release) and its second-player swap
for structural edits while playing plug in there. The `render_export` and `render_preview` tools already go
through `ToolServices.renderer`, so they switch with the same line. Until then exports are the fake's
half-second synthetic clip plus a real `ExportReceipt`.

## Layout on disk

Everything lives under one `LibraryLayout` root: `~/Movies/Timeline` by default, or `TIMELINE_ROOT` when
set (tests and the headless check use a temporary root). `Library/`, `Cache/` (with `cache.sqlite`,
`receipts.jsonl`, and the content-addressed artifacts), `Projects/`, `Exports/`, `Agent/` (the sidecar's
working directories with the installed Skills), and `mcp.json` when `TIMELINE_ROOT` is set (otherwise the
proxy config goes to `~/Library/Application Support/Timeline/mcp.json`).

The window opens (or creates) `<root>/Projects/Untitled.tlproj`; New and Open in the toolbar switch projects.

## How to run

```
swift run TimelineApp                       # the window over ~/Movies/Timeline
TIMELINE_ROOT=/tmp/tl swift run TimelineApp # the window over another root
make e2e                                    # swift run TimelineApp --skeleton-check
./ci.sh                                     # lint, swift test, e2e
```

The window: player on top, TimelineUI's Metal timeline below (drag to move, trim handles, B splits at the
playhead, Delete removes, Cmd-Z / Shift-Cmd-Z, Cmd-scroll zooms, N toggles snapping), a status bar; the
sidebar holds the inspector, the approval stack, the job list, the history, the last tool result, the MCP
section, and the agent panel. Toolbar: New, Open, Import (library import as a job, then the asset is
appended to the timeline, video auto-linking its audio), Split, Delete, Undo, Redo, Analyze (silence,
onset envelope, shots on the selected clip's asset through `media_analyze`), Align (two selected clips:
`align_audio` with the first as reference, then `moveClip` on the second), Export (`render_export`, gated by
the approval stack). The player drives the playhead while playing; the timeline drives the player while paused.

### Connecting Claude Code

The MCP section shows both forms with this launch's token:

```
claude mcp add --transport http timeline http://127.0.0.1:<port>/mcp --header "Authorization: Bearer <token>"
claude mcp add timeline -- timeline-mcp          # the stdio proxy reads mcp.json
```

The port and token change per launch; the log line `MCP: claude mcp add ...` is printed to stderr at boot.
The embedded agent uses the same endpoint through `ClaudeCodeRuntime` when `claude --version` and
`claude auth status` say it is usable.

## The end-to-end check

`--skeleton-check` boots the composition root over a temporary root with the scripted agent, then:

```
ok   boot: root TimelineSkeleton-46B555EA, MCP http://127.0.0.1:55957/mcp, 15 tools, agent fallback
ok   create: Skeleton v3 at Skeleton.tlproj; player item readyToPlay (fake renderer)
ok   import: 4 assets copied into Library/ with sidecars and cache rows; av 4.0s 1280x720, tone 3.0s @48000 Hz
ok   edit: linked clips v12, split via TimelineViewModel v14, dissolve v15; scene draws 7 clips, 1 transition
ok   analyze: silence + onset-8k on av-tone.mov: 247 envelope frames, 2 artifacts under Cache/, recorded at v17
ok   align: offset 7.3447 s (truth 7.345, error 0.255 ms), drift 0.0 ppm (truth 23), confidence 0.81
ok   tools: project_describe v18 with 4 assets; timeline_apply v18 instructions-only; stale expectedVersion rejected with changedSince
ok   mcp: 401 without token; initialize -> timeline session 83C85B2B; tools/list 15 tools; project_list over HTTP sees 1 project
ok   agent: 8 items, finished "Exported Reel 9:16."; export gated, approved on the stack, retried, wrote Reel 9x16.mp4
ok   undo/redo: v18 -> v20 -> v22, 11 live transactions
ok   reopen: v22 after close and reopen, state and history equal; 9 tool receipts logged

Skeleton check passed: 11 steps in 5.66 seconds
```

Step by step: `SQLiteProjectStoreOpener.create` plus V1/A1; `TestMedia.videoWithAudio`, `tone`, and
`alignmentPair` (60 s camera, 20 s render: the default parameters want 10 s fine windows and 10 s of
overlap) imported through `FileMediaLibrary.importJob` on the budgeted runner, with the library path,
sidecar, `sha256-` hash, and cache row asserted before `importAsset` is applied; two auto-linked clips and a
tone clip, a split through `TimelineViewModel.splitAtPlayhead` (the linked audio splits too), a dissolve, and
a `TimelineSceneBuilder` scene; `media_analyze` for silence and the onset envelope, with the artifacts
checked in `cache.sqlite` and on disk; `align_audio` on the real aligner, offset within 1 ms of the
generator's truth; `project_describe` and `timeline_apply` (instructions-only path, then a stale
`expectedVersion` rejected); the MCP host over HTTP (401 without the token, `initialize`, `tools/list`,
`tools/call project_list`); the scripted agent's `render_export` gated by the real gate, approved on the
`ApprovalCenter`, retried with the token; undo and redo through the view model; close, reopen from the
package, canonical state and history equal.

## Known issues

- The renderer is `FakeRenderer`: playback shows a synthetic clip, `render_preview` returns hue frames,
  exports are half-second clips. RenderKit replaces it at the swap point above.
- `render_export` without `outputPath` writes to `LibraryLayout.default.root/Exports`, not the app's root
  (AgentKit uses the default layout for that path). The fallback script passes `outputPath`; the toolbar
  Export button does not yet, so under `TIMELINE_ROOT` its file lands in `~/Movies/Timeline/Exports`.
- Tool receipts are logged to `Cache/receipts.jsonl`, not to the project's `commands` metadata: ProjectStore
  has no public receipt API. Open question for the ProjectStore owner.
- `MCPServerHost`'s `PreToolUse` hook only sees denials issued through its own `RecordingApprovalGate`; a
  denial from the approval stack (the app's gate) makes the hook answer `allow`, after which the server-side
  gate refuses the consumed-or-denied token. `ApprovalGate.status(of:)` now exists so AgentKit can answer
  from the gate itself.
- Boot probes `claude --version` and `claude auth status` (a second or two) before the window opens. The
  headless check skips the probe (`AgentMode.fallback`).
- The aligner reports drift 0 on the check's 20 s render (23 ppm is under what 20 s of fine windows can
  resolve at the default tolerances); the offset is what the check asserts.
- Two module fixes were needed for the check and are recorded in contracts-notes.md: `AlignmentCandidate`
  fields are now always finite (a candidate with no residuals produced `NaN`, which JSON cannot encode) and
  MediaKit's `Probe.capturedAt` is whole seconds (file dates carry nanoseconds; the event log stores
  milliseconds, so the in-memory state differed from the reloaded one).
- Filmstrips and peaks appear in the timeline as the providers finish (TimelineUI's media cache); the
  headless check builds the scene without a Metal device and does not assert them.
