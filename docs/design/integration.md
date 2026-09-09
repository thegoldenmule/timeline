# Integration

Status: Phase 2 integration done 2026-09-08; publishing (publish-plan.md 4.5) integrated 2026-09-09.
Supersedes the Phase 0.5 walking-skeleton note: `TimelineApp` is wired to every real module end to end,
RenderKit and PublishKit included. `swift run TimelineApp` opens the window;
`swift run TimelineApp --skeleton-check` (`make e2e`) runs the end-to-end check headlessly against a
temporary library root and exits 0; `swift run TimelineApp --connect-google` connects a Google account
without the window.

## What is real, what is fake

| Service | Implementation | Notes |
|---|---|---|
| `opener: any ProjectStoreOpening` | `ProjectStore.SQLiteProjectStoreOpener` | `.tlproj` packages under `<root>/Projects/`; `libraryRootHint` set to the root; the store also answers `RenderLedger` and `PublishLedger` (`ProjectDocument.renderLedger` / `.publishLedger` are the downcasts) |
| `mediaLibrary` | `MediaKit.FileMediaLibrary` | copy into `Library/YYYY/YYYY-MM-DD/`, SHA-256, sidecar, `cache.sqlite` row |
| `cache` | `MediaKit.CacheIndex` | one index for the library, the analyzer, and both providers |
| `catalog` | `CompositeMediaCatalog` (`Sources/TimelineApp/MediaCatalog.swift`) | `ProjectStore.SQLiteMediaCatalog` over `Cache/projects.sqlite` (every `.tlproj` on this machine, read-only) merged with `CacheIndex.allMedia` for originals no project references; read-only by contract, and the source of `addedAt` |
| `thumbnails`, `waveforms` | `AVThumbnailProvider`, `PeaksWaveformProvider` | over the same `CacheIndex`; TimelineUI draws filmstrips and peaks from them |
| `analyzer` | `MediaKit.AppleMediaAnalyzer` | silence, shots, peaks, onset envelope, SpeechAnalyzer transcription |
| `aligner` | `AudioAlign.OnsetAligner` | reads every tunable from `AlignmentParameters` (see contracts-notes.md) |
| `jobRunner` | `BudgetedJobRunner` (`Sources/TimelineApp/Services/`) | FIFO admission against `JobBudget.conservative`: bytes per memory class and `maxConcurrent` per class; cancellation before admission dequeues; `handle(for:)` re-opens a handle over a job a tool submitted |
| `approvals` | `StandardApprovalGate` (`Sources/TimelineApp/Services/`) | random single-use tokens, `status(of:)` implemented, the six-argument `check` keeps the tool's presentation on the request; one gate shared by the tools, the MCP host, and the approval stack |
| `registry` | `AgentKit.EditorTools.standard(context:)` | the 18 real tools when publishing is configured (15 editor tools plus `publish_youtube`, `publish_status`, `account_status`); without a Google client only `account_status` of the three is registered |
| Fork | toolbar button | `ProjectDocument.fork(to:name:)`: `ProjectStoreCopying.saveAs` copies the whole stream and projections into a new package, the window switches to the copy, and a `renameProject` transaction labelled "Fork of <name>" is the fork's first divergence; the original is untouched and both share the library |
| `mcpHost` | `AgentKit.MCPServerHost` | started at launch on 127.0.0.1 with a per-launch bearer token; `claude mcp add` line shown in Settings and the window's MCP section and logged; proxy config written |
| `agentRuntime` | `AgentKit.ClaudeCodeRuntime`, else `ToolLoopRuntime` over `FakeAgentRuntime` | `availability()` is probed at boot; when `claude` is missing or logged out the scripted fallback runs its tool calls through the registry itself (the client-side loop a Messages-API runtime has); its cards carry the tool's `details` and `warnings` |
| `receipts` | `ReceiptLog` (`Sources/TimelineApp/Services/`) | in memory plus `<root>/Cache/receipts.jsonl`; renders and publishes have their own ledgers in `project.sqlite` now, the per-command receipt metadata still does not |
| `renderer` | `RenderKit.AVFoundationRenderer` | compile, update, frame grabs, and export for the tools; built over the app's `LibraryLayout` |
| Preview | `RenderKit.PreviewPlayer` | owned by `ProjectDocument`: instruction-only edits update the live item, structural edits are compiled and swapped in on the second player; the window hosts its two `AVPlayerLayer`s (`PreviewLayerView`) |
| Publishing: `accounts[.google]` | `PublishKit.GoogleAccountProvider` | `PublishingServices` (`Sources/TimelineApp/Services/`): the OAuth client from `GoogleClientConfiguration.load` (D3 lookup order), the token store from `TokenStoreSelection.resolve` (the 0600 file `google-tokens.json` for the unsigned binary, the Keychain from an `.app`), `accounts.json` next to it, the browser opened by `WorkspaceAuthorizationPresenter` (`NSWorkspace.shared.open`; AppKit stays in the app), PublishKit's loopback listener taking the redirect. Without a client the provider is registered unconfigured, so Settings shows the setup hint and `account_status` answers `configured: false` |
| Publishing: `publishers[.youtube]` | `PublishKit.YouTubePublisher` | only when a client is configured (or under the fake): `QuotaMeter` at `<root>/Cache/publish-quota.json`, `audited` from the client file (false: uploads forced private, the sheet and the card say so). `TIMELINE_PUBLISHING=fake` boots the same two classes over `FakeYouTubeServer` with `FakeAuthorizationPresenter` (what the check uses); `TIMELINE_PUBLISHING=off` registers neither |
| Timeline, inspector, approvals, jobs, agent, history, accounts, publish | `TimelineUI` | `TimelineView(viewModel:)`, `InspectorView`, `ApprovalStackView`, `JobList` (publish rows embed `PublishOutcomeView`), `AgentPanelView`, `HistoryView`, `AccountView` (Settings), `PublishSheetView`, `PublishHistoryView` |

### The preview path

`ProjectDocument.refreshRender` hands every store change to `PreviewPlayer.update(sequence, assets:)` and
records whether it was instructions-only or a structural swap (`lastRenderPath`, `playerItemGeneration`
= the preview's swap count). An empty sequence (`RenderError.sequenceEmpty`) leaves the preview unloaded
until the first clip lands. The gesture path (`beginGesture` / `endGesture`, video-only compiles during a
drag) is not driven yet: TimelineUI previews a drag on a scratch copy and emits its one command on
release, so there is no structural edit to compile mid-gesture. Both players carry a periodic time
observer; the active one drives the timeline playhead while playing, the timeline drives `seek` while paused.

### The publish path

Toolbar Publish (enabled once the project has a done render row and a Google account is connected; the
tooltip says which is missing) presents `PublishSheetView` over `PublishSheetModel` (newest done render,
connected accounts, the sequence's caption tracks, the publisher's capabilities and quota, live
`validate`, the thumbnail preview grabbed through `Renderer.frame`). Upload hands the `PublishDraft` to
`PublishConsole`, which turns it into `publish_youtube` input (`waitSeconds: 0`) and calls it through
`ToolConsole`: the tool answers `approval_required`, the card lands on the approval stack with the tool's
rows (Channel, Account, Privacy, File, Render, Thumbnail, Captions, AI disclosure, Made for kids,
Certification) and an "Upload" button, and the console retries with the token. The tool records the
`publishes` row, submits the job, and answers with the `jobId`; the console finds the job through
`jobRunner.handle(for:)` and tracks it in the `JobCenter`, so the job list shows the stages and, when done,
`PublishOutcomeView` (View on YouTube, Open in Studio, the privacy reported, the audience reminder). The
sidebar's Publishes section lists the project's rows newest first with Resume for a `failed` or `cancelled`
row that still holds a session (the same tool with the row's `publishId`, D10). Export first: the Export
button records a render row through `render_export`, which is what the sheet publishes.

Settings (Cmd-, or the Accounts toolbar button) hosts `AccountView` with the two notices (unverified app,
7-day Testing expiry), the publishing state (client id and the forced-private notice, or the setup hint,
or the fake), where the refresh tokens live, and the MCP section with the `claude mcp add` line.

## Layout on disk

Everything lives under one `LibraryLayout` root: `~/Movies/Timeline` by default, or `TIMELINE_ROOT` when
set (tests and the headless check use a temporary root). `Library/`, `Cache/` (with `cache.sqlite`,
`projects.sqlite` (the cross-project media catalog, storage.md section 11a), `receipts.jsonl`, `publish-quota.json`, `publish/<publishId>-thumbnail.jpg`, and the content-addressed
artifacts), `Projects/`, `Exports/` (the default `render_export` destination), `Agent/` (the sidecar's
working directories with the installed Skills), and `mcp.json` when `TIMELINE_ROOT` is set (otherwise the
proxy config goes to `~/Library/Application Support/Timeline/mcp.json`).

Per user, outside the root unless `TIMELINE_ROOT` is set: `~/Library/Application Support/Timeline/`
holds `google-oauth-client.json` (the OAuth client, never in the repo), `google-tokens.json` (the file
token store, 0600), and `accounts.json` (the non-secret account records). Under `TIMELINE_ROOT` all
three sit in the root.

The window opens (or creates) `<root>/Projects/Untitled.tlproj`; New and Open in the toolbar switch projects.

## How to run

```
swift run TimelineApp                         # the window over ~/Movies/Timeline
TIMELINE_ROOT=/tmp/tl swift run TimelineApp   # the window over another root
TIMELINE_PUBLISHING=fake swift run TimelineApp  # the window with the in-process fake YouTube
swift run TimelineApp --connect-google        # connect a Google account from the terminal
make e2e                                      # swift run TimelineApp --skeleton-check
make bench                                    # the opt-in scale tests, in release
./ci.sh                                       # lint, swift test, e2e
```

Environment: `TIMELINE_ROOT` (the library root); `TIMELINE_GOOGLE_CLIENT_ID` and
`TIMELINE_GOOGLE_CLIENT_SECRET`, or `TIMELINE_GOOGLE_CLIENT_JSON` (a path), else the client JSON at
`<TIMELINE_ROOT>/google-oauth-client.json` or `~/Library/Application Support/Timeline/google-oauth-client.json`
(docs/design/publish-setup.md); `TIMELINE_GOOGLE_AUDITED=1` once the compliance audit passed;
`TIMELINE_TOKEN_STORE=file|keychain` (default: file unbundled, Keychain from an `.app`);
`TIMELINE_PUBLISHING=auto|fake|off`; `TIMELINE_LIVE_YOUTUBE=1` and `TIMELINE_KEYCHAIN_TESTS=1` for the
opt-in PublishKit tests (never run by the agents).

Test environment: the scale tests are off unless their variable is set, because each one sets the wall
clock of its whole target on its own. `AUDIOALIGN_BENCH=1` runs `AudioAlignTests.LongRecordingTests` (the
two-hour camera track against a five-minute render, ~45 s); `MEDIAKIT_BENCH=1` runs
`MediaKitTests.BenchmarkTests` (streamed analyses over `MEDIAKIT_BENCH` minutes of audio, default 10);
`TIMELINE_LIVE_CLAUDE=1` runs the one headless run against the real `claude` CLI. `make bench` sets the
first two and runs them in release (`make bench MEDIAKIT_BENCH=30` for a longer one). Everything else
runs in `make test`.

The window: the media library pane on the left (⌥⌘L, remembered in `showsLibrary`), the preview on top
(Play in the status bar or the space bar), TimelineUI's Metal timeline
below (drag to move, trim handles, B splits at the playhead, Delete removes, Cmd-Z / Shift-Cmd-Z,
Cmd-scroll zooms, N toggles snapping, M and S mute and solo the selected clips' tracks; every track
header carries mute / solo / lock / remove buttons, one command per click), a status bar; the
sidebar holds the inspector, the approval stack, the job list, the publishes, the history, the last tool
result, the MCP section, and the agent panel. Toolbar: New, Open, Fork, Import (library import as a job;
the files land in the library and nowhere else, see below), Library (the pane), Split, Delete, Undo, Redo,
Analyze (silence, onset envelope, shots on the selected clip's asset through `media_analyze`), Align (two
selected clips: `align_audio` with the first as reference, then `moveClip` on the second), Export
(`render_export`, gated by the approval stack, recorded in the render ledger), Publish (the sheet, then
`publish_youtube` gated by the approval stack), Accounts (Settings). The player drives the playhead while
playing; the timeline drives the player while paused.

### The media library

The pane on the leading edge of the window lists everything importable on this machine: the open
project's assets, read live from the document, plus every other project's media and every original in
`Library/` that no project references, read from `services.catalog` (`MediaCatalog` in `Contracts`).
`MediaLibraryModel` (TimelineUI) holds the state: a search field scored by `FuzzyMatch` over the display
name, the owning project's name, and the library folder; a kind filter (All / Video / Audio / Images); a
scope filter (This project / All projects); Refresh; and Import…. Rows are ordered by score, then
recency, then name, then content hash — a total order, so two loads list the same way. A row is badged
"in project" when the open project already holds that content hash, and "offline" when its file is not
where the catalog says; an offline row cannot be dragged. Poster frames come from `LibraryThumbnailCache`
over the timeline's own `ThumbnailProvider`, so media the timeline has already drawn costs nothing.

Adding one of those rows to the project is not a new mechanism. Because originals are content-addressed
and shared (storage.md section 1), "duplicate another project's asset into mine" is the ordinary import
job keyed by hash — which recognizes the file already in `Library/` and copies nothing — followed by
exactly one `importAsset` on this project's own write path. `MediaImporter.insert(_:at:)` does it in
order: reuse the project's asset if it already has that hash; else locate the file
(`MediaLibrary.locate(contentHash:)` first, then where the catalog last saw it); else import it as a job
and record it; then add the clip. The headless check duplicates a second package's asset and asserts one
`importAsset`, no second copy under `Library/`, and one clip.

### Drag and drop

**Import means the library. Only a drop on the timeline creates clips.** The Import button and a drop on
the preview, the sidebar, or the status bar (the window-wide `dropDestination(for: URL.self)`) run
`MediaImporter.importFiles(_:)`: each file goes through the library as a job (progress in the job list)
and its asset is recorded with `importAsset` unless the project already holds that content hash. The
status bar says "Imported 3 files into the library"; the new rows appear in the panel, which reads the
live document. Non-media files are skipped with a note in the status bar's error line. `media_import`
already behaved this way and is unchanged.

`TimelineMetalView` is the precise target. It registers for two pasteboard types — `.fileURL` and
`LibraryDragPayload.pasteboardType` (`com.thegoldenmule.timeline.library-item`, declared with
`UTType(exportedAs:)` because an SPM executable has no Info.plist to declare it in) — and while a drag is
over it the scene tints the row under the pointer and draws a line at the drop time, snapped to clip
edges, markers, the playhead, and zero like a gesture when snapping is on. The location is
`TimelineViewModel.dropTarget(at:) -> TimelineDropTarget { trackId?, at }` (nil track on the ruler, the
header column, or below the last track), so it is tested with view points and no `NSDraggingInfo`. A drag
carrying both types is treated as a library drag: a row may also offer a file URL so it can be dragged to
Finder, and only the library branch knows which project the media came from. The drop calls
`onDropMedia(urls, target)` or `onDropLibraryItems(items, target)`; the indicator is identical either way.

Files dropped on the timeline go through `MediaImporter.importFiles(_:at:)` — the library import above,
then `ProjectDocument.insertClip(for:at:)` with `link: .auto`, so a file with video and audio lands as a
linked pair. Library rows go through `MediaImporter.insert(_:at:)`, which duplicates a foreign asset
first (see above) and then inserts the same way; double-click, Return, and "Insert at playhead" take the
same path with the playhead as the target. Placement rules are unchanged: the clip goes on the target
track when that track exists, is unlocked, and matches the asset (video for video and images, audio for
audio), else on the first matching track (created when there is none); the mode is `ripple` (default
`addClip`), so a drop between clips pushes what follows along, a drop inside a clip splits it around the
insert, and a drop past the end simply appends. Several files land back to back from the drop time, each
starting where the previous one ended. The headless check drops the av file at 3 s on V1 and asserts the
linked clips land at 3 s.

### Connecting Claude Code

The MCP section shows both forms with this launch's token:

```
claude mcp add --transport http timeline http://127.0.0.1:<port>/mcp --header "Authorization: Bearer <token>"
claude mcp add timeline -- timeline-mcp          # the stdio proxy reads mcp.json
```

The port and token change per launch; the log line `MCP: claude mcp add ...` is printed to stderr at boot.
The embedded agent uses the same endpoint through `ClaudeCodeRuntime` when `claude --version` and
`claude auth status` say it is usable. The `publish-to-youtube` Skill is installed with the others.

## The end-to-end check

`--skeleton-check` boots the composition root over a temporary root with the scripted agent and the fake
YouTube (`PublishingMode.fake`), then:

```
ok   boot: root TimelineSkeleton-C15298A7, MCP http://127.0.0.1:56964/mcp, 18 tools, agent fallback, publishing fake
ok   create: Skeleton v3 at Skeleton.tlproj; empty sequence, nothing to preview yet
ok   import: 4 assets copied into Library/ with sidecars and cache rows; av 2.0s 1280x720, tone 3.0s @48000 Hz; drop at 3 s on V1 -> 2 linked clips at 3.0 s, notes.txt ignored
ok   library: 2 packages scanned, 5 items; Second/second-project.caf duplicated into Skeleton with one importAsset (no second copy under Library/), inserted again with none; Import button left the tracks empty
ok   edit: linked clips v21, split via TimelineViewModel v23, dissolve v24; scene draws 7 clips, 1 transition
ok   render: compiled 6.00s, item readyToPlay, frame at 0.5 s 320x180 not blank, h264_1080p export 6.00s in 0.5s to skeleton-1080p.mp4
ok   analyze: silence + onset-8k on av-tone.mov: 122 envelope frames, 2 artifacts under Cache/, recorded at v26
ok   align: offset 7.3447 s (truth 7.345, error 0.255 ms), drift 0.0 ppm (truth 23), confidence 0.81
ok   tools: project_describe v27 with 5 assets; timeline_apply v27 instructions-only; stale expectedVersion rejected with changedSince
ok   mcp: 401 without token; initialize -> timeline session D28B6128; tools/list 18 tools; project_list over HTTP sees 1 project
ok   agent: 8 items, finished "Exported Reel 9:16."; export gated, approved on the stack, retried, wrote Reel 9x16.mp4
ok   undo/redo: v27 -> v29 -> v31, 18 live transactions
ok   fork: Skeleton fork.tlproj at v32 with 19 live transactions; original still v31
ok   publish: connected sub-1 (Skeleton Channel @skeleton); render 01a08746… done (h264_1080p, v33, sha256-1064ff26…); publish_youtube -> approval_required (Channel, Account, Privacy, File, Render, Thumbnail, Captions, AI disclosure, Made for kids, Certification); approved on the stack, retried; 0.2 MiB in 256 KiB chunks, dropped after 0.12 MiB, resumed 1; done fake-video-1 https://youtu.be/fake-video-1 private, 1 caption, thumbnail set; row done, no session; publish_status over MCP lists it; account_status shows @skeleton
ok   reopen: v33 after close and reopen, state and history equal, publish row done; 15 tool receipts logged

Skeleton check passed: 15 steps in 8.93 seconds
```

Step by step: `SQLiteProjectStoreOpener.create` plus V1/A1; `TestMedia.videoWithAudio` (2 s: the generator
can stall past a couple of seconds), `tone`, and `alignmentPair` (60 s camera, 20 s render: the default
parameters want 10 s fine windows and 10 s of overlap) imported through `FileMediaLibrary.importJob` on the
budgeted runner, with the library path, sidecar, `sha256-` hash, and cache row asserted before
`importAsset` is applied, then the av file dropped at 3 s on V1 through `MediaImporter` lands as two linked clips
at 3 s (removed again so the edit starts empty); a second package created and closed, `SQLiteMediaCatalog`
scanning both, and its asset duplicated into Skeleton through `MediaImporter.insert` — one `importAsset`
(version +2 with the clip), no second copy under `Library/`, a second insert reusing the asset, and the
Import-button path leaving every track empty; two auto-linked clips and a tone clip, a split through
`TimelineViewModel.splitAtPlayhead` (the linked audio splits too), a dissolve, and a `TimelineSceneBuilder`
scene; RenderKit compiles the sequence over the imported clips, the preview item reaches `readyToPlay`,
`frame(_:at:size:)` at 0.5 s is not a flat colour, and `export` with `ExportPreset.h264_1080p` through the
job runner writes a file whose `AVURLAsset` duration is positive; `media_analyze` for silence and the onset envelope, with the artifacts
checked in `cache.sqlite` and on disk; `align_audio` on the real aligner, offset within 1 ms of the
generator's truth; `project_describe` and `timeline_apply` (instructions-only path, then a stale
`expectedVersion` rejected); the MCP host over HTTP (401 without the token, `initialize`, `tools/list`,
`tools/call project_list`); the scripted agent's `render_export` gated by the real gate, approved on the
`ApprovalCenter`, retried with the token; undo and redo through the view model; fork.

The publish step: `GoogleAccountProvider.connect` through PublishKit's real loopback listener, the fake
presenter performing the callback and the fake server exchanging the code (the token file appears under
the root); a caption track with two cues; `render_export` (h264_1080p) through `ToolConsole` with the
card approved on the stack, the render row `done` with `outputHash == FileHash.sha256(of: file)`;
`publish_youtube` as the human with `renderId`, `captionTrackIds`, `thumbnailAt`, `waitSeconds: 60`:
the first call answers `approval_required` with the ten rows above and no warnings, the card reaches the
`ApprovalCenter` with the same rows and token, `dropConnection(afterBytes: half the file)` is armed, the
retry with the token and the same `publishId` answers `done` with a receipt (`fake-video-1`,
`https://youtu.be/fake-video-1`, private requested and reported, `resumedCount >= 1`, every byte and the
file's hash, one caption id, thumbnail set, `madeForKids` nil) and no `upload/youtube` or token in the
output; the fake saw one status query, no overlapping chunk ranges, one dropped chunk, one SRT caption
body with the cue text, and a private video; the `publishes` row is `done` with the receipt and no
session, and the project version did not move; `publish_status` over the MCP probe lists the row without
its session; `account_status` shows `@skeleton` on "Skeleton Channel"; the gate has nothing pending. After
close and reopen the publish row is still `done` without a session and the render row `done`.

## Known issues

- `swift test` over the whole package (every target in one parallel process) stalls on this machine:
  sampling the helper shows 16 threads blocked in `-[AVAssetReaderOutput copyNextSampleBuffer]` on a
  CoreMedia semaphore, and before that `AVAssetWriter` pausing its video input for good while dozens of
  reader, writer, and export sessions are alive at once. `TestMedia.writeVideo` now feeds whichever input
  is ready, finishes the audio input as soon as its last sample is in, and throws after 30 s without
  progress instead of hanging. `make test` therefore runs the test targets one at a time (each target's
  tests still run in parallel), which passes; `make test-parallel` is the one-process run for anyone
  who wants to chase the CoreMedia interaction.
- Tool receipts are logged to `Cache/receipts.jsonl`, not to the project's `commands` metadata: ProjectStore
  has no public receipt API. Renders and publishes now have their own tables (`renders`, `publishes`) in
  `project.sqlite`, written by `render_export` and `publish_youtube`.
- `MCPServerHost`'s `PreToolUse` hook only sees denials issued through its own `RecordingApprovalGate`; a
  denial from the approval stack (the app's gate) makes the hook answer `allow`, after which the server-side
  gate refuses the consumed-or-denied token. `ApprovalGate.status(of:)` now exists so AgentKit can answer
  from the gate itself.
- Boot probes `claude --version` and `claude auth status` (a second or two) before the window opens. The
  headless check skips the probe (`AgentMode.fallback`).
- The aligner reports drift 0 on the check's 20 s render (23 ppm is under what 20 s of fine windows can
  resolve at the default tolerances); the offset is what the check asserts.
- Module fixes needed for the check are recorded in contracts-notes.md: `AlignmentCandidate` fields are
  always finite, MediaKit's `Probe.capturedAt` is whole seconds, and PublishKit's default `Sleeper` is
  formed in the init body rather than as a default argument (the default-argument async closure aborted
  the task allocator on the first real publish; see "Publishing integration").
- The Publish sheet's "Made for kids" toggle and playlist field are not sent: `publish_youtube` has no
  `madeForKids` property (publish-plan.md D9, the agent must never set it) and no `playlistId`. The card,
  the tool output, and `PublishOutcomeView` say to set the audience in YouTube Studio after the upload.
  Open for the AgentKit owner if the human path should declare it (contracts-notes.md).
- The scripted fallback agent still exports only; it does not call `publish_youtube` (the plan's optional
  `DemoAgentScript.events(exportPath:publish:)`), so the window's demo agent never uploads on its own. The
  fallback loop's card does carry a tool's presentation when one is supplied.
- No live Google traffic has been exercised (publish-plan.md section 7): the real `GoogleAccountProvider`
  and `YouTubePublisher` have run only against `FakeYouTubeServer`, in `make e2e` and PublishKit's tests.
  The first real connect is publish-setup.md step 6; `LiveYouTubeTests` stays opt-in.
- Uploads outlive the sheet but not the project: closing the project mid-upload lets the job finish while
  the ledger row's terminal update fails (logged); the window does not yet hold a document open for a
  running publish (publish-plan.md 6.9).
- Filmstrips and peaks appear in the timeline as the providers finish (TimelineUI's media cache); the
  headless check builds the scene without a Metal device and does not assert them.
