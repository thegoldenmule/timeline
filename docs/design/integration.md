# Integration

Status: Phase 2 integration done, 2026-09-08. Supersedes the Phase 0.5 walking-skeleton note: `TimelineApp`
is wired to every real module end to end, RenderKit included. `swift run TimelineApp` opens the window;
`swift run TimelineApp --skeleton-check` (`make e2e`) runs the end-to-end check headlessly against a
temporary library root and exits 0.

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
| Fork | toolbar button | `ProjectDocument.fork(to:name:)`: `ProjectStoreCopying.saveAs` copies the whole stream and projections into a new package, the window switches to the copy, and a `renameProject` transaction labelled "Fork of <name>" is the fork's first divergence; the original is untouched and both share the library |
| `mcpHost` | `AgentKit.MCPServerHost` | started at launch on 127.0.0.1 with a per-launch bearer token; `claude mcp add` line shown in the window's MCP section and logged; proxy config written |
| `agentRuntime` | `AgentKit.ClaudeCodeRuntime`, else `ToolLoopRuntime` over `FakeAgentRuntime` | `availability()` is probed at boot; when `claude` is missing or logged out the scripted fallback runs its tool calls through the registry itself (the client-side loop a Messages-API runtime has) |
| `receipts` | `ReceiptLog` (`Sources/TimelineApp/Services/`) | in memory plus `<root>/Cache/receipts.jsonl`; ProjectStore does not expose the project's `commands` metadata yet |
| `renderer` | `RenderKit.AVFoundationRenderer` | compile, update, frame grabs, and export for the tools; built over the app's `LibraryLayout` |
| Preview | `RenderKit.PreviewPlayer` | owned by `ProjectDocument`: instruction-only edits update the live item, structural edits are compiled and swapped in on the second player; the window hosts its two `AVPlayerLayer`s (`PreviewLayerView`) |
| Timeline, inspector, approvals, jobs, agent, history | `TimelineUI` | `TimelineView(viewModel:)`, `InspectorView`, `ApprovalStackView`, `JobList`, `AgentPanelView`, `HistoryView` replace every placeholder view |

### The preview path

`ProjectDocument.refreshRender` hands every store change to `PreviewPlayer.update(sequence, assets:)` and
records whether it was instructions-only or a structural swap (`lastRenderPath`, `playerItemGeneration`
= the preview's swap count). An empty sequence (`RenderError.sequenceEmpty`) leaves the preview unloaded
until the first clip lands. The gesture path (`beginGesture` / `endGesture`, video-only compiles during a
drag) is not driven yet: TimelineUI previews a drag on a scratch copy and emits its one command on
release, so there is no structural edit to compile mid-gesture. Both players carry a periodic time
observer; the active one drives the timeline playhead while playing, the timeline drives `seek` while paused.

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

The window: the preview on top (Play in the status bar or the space bar), TimelineUI's Metal timeline
below (drag to move, trim handles, B splits at the playhead, Delete removes, Cmd-Z / Shift-Cmd-Z,
Cmd-scroll zooms, N toggles snapping), a status bar; the
sidebar holds the inspector, the approval stack, the job list, the history, the last tool result, the MCP
section, and the agent panel. Toolbar: New, Open, Import (library import as a job, then the asset is
appended to the timeline, video auto-linking its audio; files can also be dropped, see below), Split, Delete, Undo, Redo, Analyze (silence,
onset envelope, shots on the selected clip's asset through `media_analyze`), Align (two selected clips:
`align_audio` with the first as reference, then `moveClip` on the second), Export (`render_export`, gated by
the approval stack). The player drives the playhead while playing; the timeline drives the player while paused.

### Drag and drop

Media files (anything whose `UTType` conforms to movie, audio, or image: `MediaFileTypes` in TimelineUI)
can be dropped anywhere in the window. `TimelineMetalView` registers for `.fileURL` drags and is the
precise target: while a drag is over it the scene tints the row under the pointer and draws a line at the
drop time, snapped to clip edges, markers, the playhead, and zero like a gesture when snapping is on.
The location is `TimelineViewModel.dropTarget(at:) -> TimelineDropTarget { trackId?, at }` (nil track on the
ruler, the header column, or below the last track), so it is tested with view points and no
`NSDraggingInfo`; the drop calls `viewModel.onDropMedia(urls, target)`. The whole editor view is a SwiftUI
`dropDestination(for: URL.self)` fallback: a drop on the preview, sidebar, or status bar lands at the playhead.

Both go through `MediaImporter` (`Sources/TimelineApp/MediaImporter.swift`), the same path as the Import
button: every file is submitted to the library as a job up front (progress in the job list), then in the
order dropped its asset is recorded with `importAsset` (or the project's existing asset with that content
hash is reused) and `ProjectDocument.insertClip(for:at:)` adds it with `link: .auto`, so a file with video
and audio lands as a linked pair. Placement rules: the clip goes on the target track when that track
exists, is unlocked, and matches the asset (video for video and images, audio for audio), else on the
first matching track (created when there is none); the mode is `ripple` (default `addClip`), so a drop
between clips pushes what follows along, a drop inside a clip splits it around the insert, and a drop past
the end simply appends. Several files land back to back from the drop time, each starting where the
previous one ended. Non-media files are skipped with a note in the status bar's error line. The headless
check drops the av file at 3 s on V1 and asserts the linked clips land at 3 s.

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
ok   boot: root TimelineSkeleton-C7EE96E4, MCP http://127.0.0.1:60077/mcp, 15 tools, agent fallback
ok   create: Skeleton v3 at Skeleton.tlproj; empty sequence, nothing to preview yet
ok   import: 4 assets copied into Library/ with sidecars and cache rows; av 2.0s 1280x720, tone 3.0s @48000 Hz; drop at 3 s on V1 -> 2 linked clips at 3.0 s, notes.txt ignored
ok   edit: linked clips v12, split via TimelineViewModel v14, dissolve v15; scene draws 7 clips, 1 transition
ok   render: compiled 6.00s, item readyToPlay, frame at 0.5 s 320x180 not blank, h264_1080p export 6.00s in 0.3s to skeleton-1080p.mp4
ok   analyze: silence + onset-8k on av-tone.mov: 122 envelope frames, 2 artifacts under Cache/, recorded at v17
ok   align: offset 7.3447 s (truth 7.345, error 0.255 ms), drift 0.0 ppm (truth 23), confidence 0.81
ok   tools: project_describe v18 with 4 assets; timeline_apply v18 instructions-only; stale expectedVersion rejected with changedSince
ok   mcp: 401 without token; initialize -> timeline session F627DC6B; tools/list 15 tools; project_list over HTTP sees 1 project
ok   agent: 8 items, finished "Exported Reel 9:16."; export gated, approved on the stack, retried, wrote Reel 9x16.mp4
ok   undo/redo: v18 -> v20 -> v22, 11 live transactions
ok   reopen: v22 after close and reopen, state and history equal; 9 tool receipts logged

Skeleton check passed: 12 steps in 5.43 seconds
```

Step by step: `SQLiteProjectStoreOpener.create` plus V1/A1; `TestMedia.videoWithAudio` (2 s: the generator
can stall past a couple of seconds), `tone`, and `alignmentPair` (60 s camera, 20 s render: the default
parameters want 10 s fine windows and 10 s of overlap) imported through `FileMediaLibrary.importJob` on the
budgeted runner, with the library path, sidecar, `sha256-` hash, and cache row asserted before
`importAsset` is applied, then the av file dropped at 3 s on V1 through `MediaImporter` lands as two linked clips
at 3 s (removed again so the edit starts empty); two auto-linked clips and a tone clip, a split through
`TimelineViewModel.splitAtPlayhead` (the linked audio splits too), a dissolve, and a `TimelineSceneBuilder`
scene; RenderKit compiles the sequence over the imported clips, the preview item reaches `readyToPlay`,
`frame(_:at:size:)` at 0.5 s is not a flat colour, and `export` with `ExportPreset.h264_1080p` through the
job runner writes a file whose `AVURLAsset` duration is positive; `media_analyze` for silence and the onset envelope, with the artifacts
checked in `cache.sqlite` and on disk; `align_audio` on the real aligner, offset within 1 ms of the
generator's truth; `project_describe` and `timeline_apply` (instructions-only path, then a stale
`expectedVersion` rejected); the MCP host over HTTP (401 without the token, `initialize`, `tools/list`,
`tools/call project_list`); the scripted agent's `render_export` gated by the real gate, approved on the
`ApprovalCenter`, retried with the token; undo and redo through the view model; close, reopen from the
package, canonical state and history equal.

## Known issues

- `swift test` over the whole package (every target in one parallel process) stalls on this machine:
  sampling the helper shows 16 threads blocked in `-[AVAssetReaderOutput copyNextSampleBuffer]` on a
  CoreMedia semaphore, and before that `AVAssetWriter` pausing its video input for good while dozens of
  reader, writer, and export sessions are alive at once. `TestMedia.writeVideo` now feeds whichever input
  is ready, finishes the audio input as soon as its last sample is in, and throws after 30 s without
  progress instead of hanging. `make test` therefore runs the test targets one at a time (each target's
  tests still run in parallel), which passes; `make test-parallel` is the one-process run for anyone
  who wants to chase the CoreMedia interaction.
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
