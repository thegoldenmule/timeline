# The sequence format

Status: plan, 2026-09-13. Companion to `docs/plans/export-sheet.md`, which this one corrects.
`TimelineCore`, `ProjectStore` and `RenderKit` change in one place only: a rotation-aware display size
derived from a probe. The write path, the event, its inverse and its projection all exist already.

## 0. Context

A project is created 1920x1080 at 30 fps and stays that way forever. `ProjectDocument.create`
(`Sources/TimelineApp/ProjectDocument.swift:94`) hard-codes
`.init(name: "Sequence 1", frameDuration: RationalTime(1, 30), width: 1920, height: 1080)`, and nothing
in the window, the tools, or the skills has ever changed a sequence's size. A project holding nothing
but portrait video is a landscape project with portrait clips inside it.

That produces black bars **twice**, at two different stages, and only one of them is visible anywhere:

1. **Media into sequence.** `TimelineCompositor.layer` aspect-fits each source into the sequence frame
   (`Sources/RenderKit/Compositor.swift:222-251`). A 1080x1920 clip in a 1920x1080 sequence is a
   607-pixel-wide strip with 656 pixels of black down each side.
2. **Sequence into output.** `TimelineCompositor` fits the sequence into the render context,
   letterboxed on black (`Compositor.swift:208-219`).

The export sheet that just landed draws stage 2 and only stage 2 (`ExportFramingView`,
`Sources/TimelineUI/ExportSheetView.swift`). With `Match sequence` selected — its default — stage 2 is
the identity, so the sheet correctly reports no letterboxing while the file is mostly black. The bars
come from stage 1, which nothing in the app draws, measures, or mentions. That is the defect this plan
fixes; the export sheet is not wrong, it is looking one stage too late.

### The write path already exists

`Command.Operation.SetSequenceSettings` (`Sources/TimelineCore/Command.swift:223`) carries a complete
`SequenceSettings` — `name`, `frameDuration`, `width`, `height` (`Command.swift:883`). It reaches
`decide` at `Decide.swift:164` and is validated at `Decide.swift:290-305`:

- a settings value equal to the current one emits nothing (`:293`) — the same no-op shape as
  `renameProject`;
- width and height must be positive (`:295`);
- a **frame-rate** change is refused when any frame-aligned track holds clips (`:296-302`), with the
  suggestion "Remove the clips first";
- **size is unrestricted**, at any time, with clips present.

It emits `sequenceSettingsChanged(before:after:)` (`Event.swift:147`), which inverts and projects like
every other event. Resizing is therefore non-destructive and undoable by construction: the compositor
recomputes both fits per frame from the sequence's current size, and clip transforms are stored
relative (`transform.anchorX/anchorY/scale`, `Compositor.swift:254-264`), so no clip is rewritten.

The earlier claim that a resize was impossible because `resizeSequence` does not exist
(`docs/plans/export-sheet.md`, "Left out") was a search for the wrong name. Correct it there when this
lands.

### The rotation trap

**This is the part that will silently reintroduce the bug if it is not handled first.**

`Probe.width` and `Probe.height` are the track's `naturalSize`, the *encoded* dimensions
(`Sources/MediaKit/Probe.swift:130-136`). The display matrix is stored separately as `Probe.rotation`,
in degrees, ffmpeg convention (`Probe.swift:145`, `rotationDegrees` at `:186`). The project's own
fixture pins it: `ProbeTests.iphonePortraitHLGProbe` asserts `rotation == -90` **and**
`width == 3840 && height == 2160` for a clip shot in portrait on an iPhone
(`Tests/MediaKitTests/ProbeTests.swift:53,59`).

So a portrait iPhone clip probes as *landscape 3840x2160*. Any code that reads `probe.width/height` to
decide orientation — a "match the media" button, a mismatch badge, an agent reading a tool result —
gets the answer exactly backwards and would resize a portrait project to 4K landscape. Every consumer
must go through one shared display size that swaps the axes when `|rotation| == 90`.

### The MCP path is misinformed, not missing

`setSequenceSettings` is **already** exposed to the assistant and to MCP: `OperationSchemas.swift:211`
declares it ("Changes a sequence's name, frame duration or size") with the `sequenceSettings` ref at
`:157`, so `timeline_apply` can resize a sequence today. No write tool is missing.

What is missing is any way for an agent to know it should. `project_describe` reports each asset's size
as `"\(w)x\(h)"` straight from the probe with **no rotation** (`ProjectTools.swift:142`) and each
sequence's `width`/`height` (`:154`). An agent asked to export the user's project reads "asset
3840x2160, sequence 1920x1080", concludes everything is landscape and consistent, and exports the
bars. The read side actively misleads it.

## 1. Decisions

1. **One display size, defined once, used by everything.** A computed `displaySize` on `Probe` (or a
   free function over it) in `TimelineCore`, swapping width and height when `|rotation| == 90`, plus an
   `orientation` derived from it. This is additive to a type `Contracts`-adjacent conventions freeze,
   so it is an extension with no stored property and no codable change. The UI, the tools and the
   skeleton check all read it; nothing else is allowed to touch `probe.width` for orientation.

2. **The format is edited in a sheet, reachable from two places.** A `Format` sheet, shaped like
   `ProjectRenameSheet`, opened from a toolbar button in the document group **and** from a
   "Change the sequence format" affordance inside the export sheet's mismatch warning. Two entry
   points, one sheet: the toolbar is where you go deliberately, the export sheet is where the problem is
   actually discovered. The inspector stays clip-scoped, for the reason `project-rename.md` gives.

3. **The sheet offers presets, custom dimensions, and Match media.**
   Landscape 1920x1080, Portrait 1080x1920, Square 1080x1080, UHD 3840x2160, UHD portrait 2160x3840,
   custom width and height, and **Match media** — computed from the rotation-aware display size of the
   video assets actually placed in the sequence, offered as a single row when they agree on an
   orientation, and naming the clip it followed. Match media is the recommended row when the current
   format disagrees with the footage.

4. **Frame rate lives in the same sheet and surfaces the core's own rule.** The field is disabled with
   `decide`'s reason when a frame-aligned track holds clips (`Decide.swift:296-302`). The rule is not
   restated or re-implemented in the UI — it is read from the same condition and shown.

5. **The indicator is drawn where the bars are, at both stages.** `ExportFramingView` is extended from
   one nested rectangle to two: source media inside the sequence frame, sequence frame inside the
   output frame, each labelled with its own bar measurement. A sequence whose clips do not fill it is
   reported even when `Match sequence` makes stage 2 clean. The same one-line summary
   ("portrait media, landscape sequence: 656 px of pillarbox") appears in the status bar beside the
   format, so it is visible without opening a sheet.

6. **New projects keep the 1920x1080 default, and the first import that disagrees offers to fix it.**
   Changing the New flow means replacing a bare `NSSavePanel` with a configuration sheet, which is a
   larger change than this one and is left out (section 5). Instead: when media lands in a sequence
   that is still at the untouched default and whose display orientation disagrees, the status bar shows
   a one-click "Match sequence to media" affordance — the standard NLE offer, non-modal, dismissible,
   and never automatic. Resizing behind the user's back is not on the table.

7. **No new write tool for MCP.** `timeline_apply` + `setSequenceSettings` is the write path and it
   works. The work on the agent side is all read-side truth (decision 8) plus discoverability.

8. **The tools stop misreporting orientation.** `project_describe` gains, per asset, a rotation-aware
   `displaySize` and `orientation` alongside the existing encoded `size` (which stays, renamed in its
   description to say it is encoded); per sequence, an `orientation` and an `aspect`; and, at summary
   level, a `formatMismatch` note naming the clips that do not fill the frame. `timeline_query` gets the
   same asset fields. The `setSequenceSettings` op description gains a sentence pointing at the display
   size, so an agent that reads the schema learns the rotation rule.

9. **The vertical skills say so.** `tiktok-captions` and any other vertical-format skill get a step:
   check the sequence orientation before captioning or exporting, and resize with `setSequenceSettings`
   if it disagrees with the footage. This is where an agent learns the workflow, not from the op schema.

## 2. What is added

### `Sources/TimelineCore/Model.swift` (or a new `Orientation.swift`)

```swift
extension Probe {
    /// Encoded size with the display matrix applied: axes swapped at ±90°.
    public var displaySize: (width: Int, height: Int)?
    public var orientation: Orientation?      // .portrait, .landscape, .square
}

public enum Orientation: String, Sendable, Hashable, Codable { case portrait, landscape, square }
```

`Sequence` gets the same `orientation` and an `aspect` for symmetry. No stored properties, no codable
change, no migration.

### `Sources/TimelineUI/SequenceFormatView.swift` (new)

`SequenceFormatText` (copy), `SequenceFormatPreset` (the five presets plus custom), `SequenceFormat`
(the draft: current settings, chosen preset, custom width and height, validation, `matchMedia(from:)`,
and an `operation` that is `nil` when invalid or unchanged, mirroring `ProjectRename`),
`SequenceFormatSheet`, and `FormatMismatch` — the pure calculation behind the indicator: given a
sequence size and the display sizes of its video clips, the orientation verdict and the bar widths in
pixels.

### `Sources/TimelineUI/ExportSheetView.swift`

`ExportFramingView` draws two nested frames instead of one; `ExportDraft` carries the stage-1 mismatch
so the sheet can warn and offer the Format sheet. The fit math itself is unchanged — it already mirrors
`Compositor.swift:208-219` and stage 1 uses the same `min` scale.

### `Sources/TimelineApp/Views.swift`

`formatting: SequenceFormat?`, `presentFormatSheet()`, `commitFormat(_:)` (the `commitRename` shape:
applies through `document.apply`, sets `lastCommandError`, returns the message so the sheet survives a
failure), one toolbar button, one `.sheet`, the status-bar format summary, and the first-import offer.

### `Sources/AgentKit`

`ProjectTools.assetSummary` and `sequenceSummary` gain the fields in decision 8; `OperationSchemas`
gains the sentence in decision 8; `Skills/tiktok-captions/SKILL.md` gains the step in decision 9.

## 3. Tests

`Tests/TimelineCoreTests` — `displaySize` and `orientation` across rotation 0, ±90, 180, and a missing
rotation; the ProbeTests fixture's own numbers (3840x2160 at -90) reading as portrait 2160x3840.

`Tests/TimelineUITests/SequenceFormatTests.swift` — preset round trips; custom dimension validation
(zero, negative, absurd); `matchMedia` picking the right size from rotated probes and declining when
clips disagree; `operation` nil when unchanged or invalid; applying through `viewModel.apply` resizing
the sequence, filing one transaction, and undo restoring the old size; the frame-rate field disabled
exactly when `decide` would refuse; `FormatMismatch` bar arithmetic for portrait-in-landscape,
landscape-in-portrait, and a matching pair.

`Tests/AgentKitTests` — `project_describe` reporting a rotated asset as portrait, and the mismatch note
appearing for a portrait clip in a landscape sequence.

`Tests/RenderKitTests` — a resized sequence exports at the new size and the clip fills it, proving the
resize reaches the compositor with no clip edits.

## 4. The skeleton check

A step after the export step, which is where the user's problem lives. Against a synthetic portrait
source: assert the default sequence is 1920x1080 and reports the mismatch with the expected bar width;
apply the format change through a real `SequenceFormat`; assert one transaction, the new size, and that
undo restores it; re-run the mismatch calculation and assert it is clean; then export `Match sequence`
and assert the written file is portrait and its frame at mid-duration is not black at the edges. The
last clause is the whole point: today that file is 1920x1080 with black down both sides.

## 5. Resolved risks

Both questions this plan opened have since been checked in the code. Recorded here so the
implementation does not re-litigate them.

- **The preview does rebuild on a resize — verified.** `RenderFingerprint.Structure` carries
  `frameDuration`, `width` and `height` (`Sources/RenderKit/Fingerprint.swift:37-40`, combined at
  `:56`), so a size change changes the structural fingerprint and `PreviewPlayer.update` takes the full
  recompile branch rather than `.instructionsOnly` (`Sources/RenderKit/PreviewPlayer.swift:85-98`). No
  explicit rebuild is needed and no change to the preview path is in scope.
- **Caption geometry is already relative — verified, with one caveat.** `Captions` derives everything
  from `sequenceSize`: the font is `height * 0.05` (`Sources/RenderKit/Captions.swift:24`), the
  positions are fractions of width and height (`:39-44`), and the plate is the sequence size (`:51-52`).
  A resize reflows captions correctly. The one exception is an explicitly set `spec.style.fontSize`
  (`:24`), which is absolute and will not rescale with the frame — worth a line in the format sheet's
  copy if captions exist, and nothing more.
- The fork/project-id catalog collision noted in `project-rename.md` section 4 is still open and still
  unrelated.

## 6. Left out

- A format picker in the New flow (decision 6). It replaces an `NSSavePanel` with a configuration
  sheet and deserves its own plan.
- Per-clip fit controls — crop, fill, "scale to fill frame" on a single clip. That is the other half of
  the framing story and is genuinely a `Contracts` change (`ExportPreset.fit` or a clip-level fit mode);
  `export-sheet.md` decision 5 records the shape it would take.
- Multiple sequences with different formats in one project, beyond what `setSequenceSettings` already
  does per sequence.
- Changing the frame rate of a sequence that already holds clips. The core refuses it and this plan
  does not argue with the core.
