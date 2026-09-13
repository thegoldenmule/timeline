# The export sheet

Status: plan, 2026-09-13. Companion to `docs/design/ui-style.md` and `docs/design/conventions.md`.
Nothing in `TimelineCore`, `Contracts`, or `RenderKit` changes: `ExportPreset` already models every
choice this sheet offers and `ExportPlan` already honours `.matchSequence`. This is one sheet, one
toolbar button that stops lying, and the fit math written down where a human can see it before the
render happens.

## 0. Context

The toolbar's Export button calls `AppModel.exportReel()` (`Sources/TimelineApp/Views.swift:307`):

```swift
perform { _ = try await tools.call("render_export", input: ToolInput(["preset": "reel9x16"])) }
```

That is the whole feature. Every export from the window is 1080x1920 whatever the sequence is, the file
lands at a path nobody chose, and there is no dimension, preset, or path control anywhere in the UI.

**What that actually produces is the bug.** `TimelineCompositor` maps sequence space into the output
frame by aspect fit, letterboxed on black (`Sources/RenderKit/Compositor.swift:208-219`):

```swift
let scale = min(contextSize.width / sequenceSize.width, contextSize.height / sequenceSize.height)
```

The picture is scaled by the *smaller* ratio, centred with a rounded translation, composited over black,
and cropped to the context rect. `sequenceSize` is the sequence's own `width x height`
(`Compiler.swift:325`); `contextSize` is the export's render size. So a mismatched preset **never
crops** — it pads. A 1920x1080 sequence exported as a reel is a 1080x607 strip in a 1080x1920 black
frame: two thirds of the file is black, and the first time the user learns this is when they open the
file. The user's report — "the currently open project is not those dimensions, it's a portrait, not
landscape video" — is that experience from the other side.

Everything needed to fix it is already built and reachable from the tool layer:

| Piece | Where | State |
|---|---|---|
| `OutputSize.matchSequence` / `.fixed` | `Contracts/Renderer.swift:126` | modelled |
| `FrameRatePolicy.matchSequence` / `.fixed(Rational)` | `Contracts/Renderer.swift:131` | modelled |
| Resolving both against the payload | `RenderKit/Export.swift:77-88` | works, tested |
| `render_export` taking a whole `ExportPreset` object | `AgentKit/Tools/RenderTools.swift:146-155` | works |
| `outputPath` | same, `:161-168` | works |
| The approval round trip | `TimelineApp/Consoles.swift:35-58` | works |

Match-sequence export has worked end to end since the render module landed. It is simply unreachable
from the window.

## 1. Decisions

1. **Make the mismatch visible and trivially avoidable; do not add a crop mode.** This is the scope call
   the task asks for, and it is (a), not (b). The reasons, in order:

   - *The aspect fit is not the export's, it is the compositor's.* The same `compose` is what
     `AVPlayerItem` runs for the preview and what `renderer.frame` runs for a thumbnail. A fill/crop
     mode that applied only on the export path would mean the window shows one framing and the file
     holds another — which is the same class of bug as the one being fixed.
   - *`ExportPreset` has no field for it and `Contracts` is frozen.* `conventions.md` says a change to
     `Contracts` is a separate merged commit that also updates `ContractsTestSupport`'s fakes, after
     which every module rebases. A `fillMode` there is not a small addition; it is a contract change,
     a compositor change, a preview change, and a receipt-format change.
   - *Crop is a lossy answer to a question the user has not asked.* Nobody wants the sides of their
     16:9 interview thrown away to make a reel; they want to know, before they press the button, that
     the reel preset is not what their sequence is. Letterbox, shown honestly, is the safe default.
   - The door stays open. If crop-to-fill is wanted later it is `ExportPreset.fit: .fit | .fill` plus
     `max` instead of `min` in that one line, and `Compositor` already crops to the context rect, so
     the change is real but it belongs in its own plan with its own `RenderKitTests`.

   The schematic in this sheet therefore draws **aspect fit on black and nothing else**. Drawing a crop
   the renderer will not perform would be a worse lie than the one being fixed.

2. **A sheet from the toolbar, not a menu and not a panel.** Export is not a view option, so
   `ui-style.md`'s filter rule puts it nowhere in a panel header; and the answer is five related values
   plus a picture, which is a sheet's shape. The button stays exactly where it is, in the
   Analyze / Align / Export group, and stops being a one-click reel.

3. **The sheet dismisses before the tool is called, and the export stays a background job.** This is
   not cosmetic. `render_export` always returns `approval_required` first, and `ToolConsole.call` raises
   that card on the **approval stack in the right-hand column** — which a modal sheet covers. A sheet
   that waited on its own export would deadlock against its own approval card. So Export closes the
   sheet and hands the draft to `perform { tools.call(...) }`, which is what the button does today:
   same gate round trip, same job in the Jobs panel, same `publish?.refresh()` afterwards, same render
   ledger row. The sheet's callback is `(ExportDraft) -> Void`, not `async -> String?`; errors land in
   the status bar like every other failed action, because that is where the user is looking once the
   sheet is gone.

4. **One preset picker with five rows, and the size follows it unless the user overrides it.** The rows
   are `Match sequence` and the four built-ins. A built-in row carries its own dimensions *and* a badge
   saying what it would do to this sequence — "letterboxed", "pillarboxed" — so the mismatch is visible
   at the moment of choosing, not only in the picture below. A separate Size control has two positions,
   `Preset` and `Custom`; Custom reveals width and height fields seeded from whatever was resolved a
   moment ago, so the custom path starts from something real rather than from zero.

5. **The default follows the sequence, always.** `ExportDraft.init(sequence:...)` selects the
   `Match sequence` preset and the `Match sequence` frame rate, whatever shape the sequence is — so
   the default export is the one frame that cannot letterbox, and a portrait sequence cannot default
   to a landscape frame any more than a landscape one can default to a reel. Tests assert it in both
   directions.

   The alternative — defaulting to whichever built-in's *aspect* agrees with the sequence — was
   rejected: it is right only for sequences that happen to be exactly 16:9 or 9:16, and it silently
   letterboxes a 4:5 or 2.35:1 sequence, which is the bug. Orientation matching lives in the badges
   instead (decision 4), where it warns rather than chooses.

6. **`Match sequence` is a real `ExportPreset`, not a UI flag.** It is H.264/AAC in MP4 at 12 Mb/s,
   tone-mapped to SDR — `h264_1080p`'s codec choices — with `size: .matchSequence` and
   `frameRate: .matchSequence`. It goes down the wire as a preset object like any other, is recorded in
   the render ledger row and the receipt like any other, and names the output file like any other. There
   is no new tool parameter and no new branch in `render_export`.

7. **Custom dimensions rename the preset.** A 720x1280 export whose receipt says "H.264 1080p" is a
   receipt that lies, and the ledger row is what `publish_youtube` reads back. So custom sizing sets the
   preset's name to `Custom 720x1280`, which is also what the default file name then says.

8. **The file name formula is duplicated, once, on purpose, and pinned by the skeleton check.**
   `render_export` builds `<library root>/Exports/<sequence>-<preset>.<ext>` itself
   (`RenderTools.swift:164-168`); the sheet has to show that same path *before* calling the tool, and
   `TimelineUI` may not import `AgentKit` (`conventions.md`, package layout: a library never imports a
   sibling). Rather than leave two silently drifting copies, the formula is extracted into a public
   `ExportDestination.url(...)` in `AgentKit`, `render_export` calls it, `TimelineUI` keeps its own
   copy in `ExportDraft`, and the skeleton check — which imports both — asserts the two produce the
   identical URL. One assertion holds the duplication honest.

9. **The picture is a schematic, with a real frame in it when one is cheap.** The frame at the playhead
   comes from `renderer.frame(compiled, at:size:)`, which the window already calls, so the app hands the
   sheet a `() async -> CGImage?`; the sheet asks once, in a `.task`, and draws the schematic unchanged
   if it gets nothing or if there is no renderer to ask (tests, no document, a failing decode). The
   frame is drawn **inside the fitted rect** and the black frame around it is drawn at the output's
   aspect, so the letterboxing story is the same whether the picture arrived or not.

10. **Quality, codec, container, HDR, and loudness are not exposed.** They are what a preset *is*. Five
    controls plus a picture is already the most a sheet in this window asks; a codec matrix would turn
    it into the wall of controls `ui-style.md` exists to prevent, and every one of those fields already
    reaches the agent path through the full-object form of `preset`. What the built-ins do not cover,
    the assistant can be asked for. The container is still honoured in the UI in one direction: it owns
    the output file's extension, which is retargeted when the preset changes.

## 2. What is added

`PanelTheme` gains four tokens (`ui-style.md` and `StyleTests` record all three):

| Token | Value | Why |
|---|---|---|
| `formSheetWidth` | 520 | A sheet that asks several related questions and draws something. `sheetWidth` 420 is the one-value sheet; this is its sibling, not a literal frame in new chrome. |
| `framePreviewHeight` | 180 | The box the export schematic is fitted into. Tall enough that a 9:16 frame is legible, short enough that the sheet stays one screen. |
| `numberFieldWidth` | 72 | A field holding a pixel count, sized so four digits fit and it does not stretch across its row. |
| `letterboxFill` | `Color.black` | The black an export composites on. Semantic, not a hue: it is what `Compositor` literally writes where the picture does not reach. |

The fitted picture's placeholder reuses `posterFill` — "the placeholder behind a poster that has not
landed" is exactly what it is.

### `Sources/TimelineUI/ExportSheetView.swift`

```swift
/// The pure fit math, mirroring Compositor.swift:208-219 exactly: min(), centred, rounded, on black.
public struct ExportFraming: Hashable, Sendable {
    public enum Bars: Hashable, Sendable {
        case none                       // the aspects agree
        case letterbox(CGFloat)         // black above and below; the height of one bar
        case pillarbox(CGFloat)         // black left and right; the width of one bar
    }
    public let output: CGSize
    public let sequence: CGSize
    public var scale: CGFloat           // min(out.w/seq.w, out.h/seq.h)
    public var fitted: CGRect           // the picture inside the frame, rounded as the compositor rounds
    public var bars: Bars
    public var coverage: Double         // fitted area / output area
    public var summary: String          // "1080 x 1920 - 9:16 - 16:9 sequence fits 31% of the frame"
    public static func aspectLabel(_ size: CGSize) -> String   // "16:9", "9:16", else "2.35:1"
}

/// What the sheet edits. Every value is derived; nothing is stored twice.
public struct ExportDraft: Hashable, Sendable {
    public enum Sizing: Hashable, Sendable { case preset, custom }
    public enum Rate: Hashable, Sendable { case matchSequence, fixed(Rational) }

    public static let matchSequence: ExportPreset   // decision 6
    public static let presets: [ExportPreset]       // matchSequence + ExportPreset.builtIn
    public static let rates: [Rational]             // 23.976 24 25 29.97 30 50 59.94 60
    public static let minimumDimension = 16
    public static let maximumDimension = 8192

    public init(sequence: Sequence, exportsDirectory: URL)   // decision 5

    public var presetName: String { didSet { retarget() } }  // decisions 4, 7, 8
    public var sizing: Sizing
    public var customWidth: Int
    public var customHeight: Int
    public var rate: Rate
    public private(set) var outputURL: URL
    public mutating func chose(_ url: URL)                   // the save panel's answer; stops retargeting the name

    public var preset: ExportPreset      // what goes down the wire
    public var outputSize: CGSize
    public var framing: ExportFraming
    public var validationError: String?
    public var canExport: Bool
    public func badge(forPresetNamed: String) -> String?     // "letterboxed" / "pillarboxed" / nil
}

public struct ExportSheetView: View { ... }      // the controls, the schematic, Cancel / Export
public struct ExportFramingView: View { ... }    // the black frame, the fitted rect, the bars, the caption
```

The sheet's form is `.formStyle(.columns)`, not `.grouped`: `ui-style.md` calls grouped the System
Settings look whose inset cards sit further from the edge than everything else, and this sheet's picture
and its Save-to row live outside the form at the page gutter — two different insets in one 520pt sheet
would be exactly the mismatch that rule is about.

Validation is the sheet's, not the core's, as with the rename sheet: custom dimensions must be even
(H.264 and HEVC encode in macroblocks; an odd render size is a failure at the encoder rather than a
warning) and within 16...8192.

### `Sources/AgentKit/Tools/RenderTools.swift`

One extraction, no behaviour change: the default output path becomes

```swift
public enum ExportDestination {
    /// `<exports>/<sequence>-<preset>.<ext>`, with "/" out of the name. The window's export sheet shows
    /// this path before the tool is called and cannot import AgentKit to share it, so `ExportDraft`
    /// keeps a copy and the skeleton check asserts the two agree.
    public static func url(sequenceName: String, presetName: String, fileExtension: String, in exports: URL) -> URL
}
```

### `Sources/TimelineApp/Views.swift`

- `AppModel.exporting: ExportDraft?` — non-nil while the sheet is up, the same shape as `renaming`.
- `presentExportSheet()` seeds it from the open sequence and `services.layout.exportsDir`.
- `chooseExportPath(_:)` runs the `NSSavePanel` (AppKit stays in the app, out of the view, exactly as
  the New/Open/Fork panels do) seeded with the draft's directory, file name, and container type.
- `exportFrame(_:)` grabs the playhead frame for the schematic, or nil.
- `commitExport(_:)` dismisses the sheet, then `perform { tools.call("render_export", ...) }` with
  `preset` as the draft's full `ExportPreset` object, `outputPath`, and `sequenceId` (decision 3).
- `exportReel()` is deleted; the Export button opens the sheet.

## 3. Tests

`Tests/TimelineUITests/ExportTests.swift`:

- the fit math against hand-computed numbers in all four directions — 16:9 into 9:16 (letterbox), 9:16
  into 16:9 (pillarbox), equal aspects (no bars, scale 1), a square into 16:9 — plus the rounded,
  centred offset agreeing with `Compositor`'s formula at a size where the halves are fractional;
- coverage and the aspect labels, including one that does not reduce to small integers;
- the default draft over a landscape sequence and over a portrait one: `Match sequence` selected, no
  bars, the named preset matching the sequence's orientation in each case;
- the badges: `Reel 9:16` flagged over a landscape sequence, `H.264 1080p` flagged over a portrait one,
  nothing flagged when the aspects agree;
- custom dimensions: odd, zero, negative, over the cap, and the valid boundary; the preset renaming to
  `Custom WxH`; the draft refusing to export while invalid;
- the output URL following the preset's name and container until the user chooses a path, and the
  extension being retargeted afterwards;
- `ExportPreset` round-tripping through `JSONValue` unchanged, which is the wire format `render_export`
  decodes — the sheet's whole contract with the tool in one assertion.

`Tests/TimelineUITests/StyleTests.swift` gains the three tokens.

No `RenderKitTests` change: the render path is untouched (decision 1).

## 4. The skeleton check

A sub-step **11c**, after the rename, on the reopened original whose sequence is 1920x1080 at 30 —
the exact shape that made the old button wrong. It:

- builds an `ExportDraft` over the real sequence and asserts the default is `Match sequence` with no
  bars, and that the default path equals `ExportDestination.url(...)` from `AgentKit` (decision 8);
- asserts a draft switched to `Reel 9:16` reports 1080x1920 with letterboxing, which is precisely what
  the toolbar used to do silently;
- calls `render_export` through `ToolConsole` with the default draft's preset **object** and its
  `outputPath`, through the real approval gate, and asserts the approval was raised, the file exists,
  the render ledger row carries the preset, and — the assertion this whole feature exists for — the
  written video track is **1920x1080**, the sequence's own size, not 1080x1920.

## 5. Left out

- No crop / fill mode (decision 1). Explicitly out of scope, with the shape it would take written down.
- No codec, container, bitrate, HDR, or loudness controls (decision 10). The agent path already reaches
  all of them through the object form of `preset`.
- No export-preset persistence: the sheet opens fresh each time from the sequence. Remembering the last
  choice means a store for it, and a remembered reel preset is how you get back to silently
  letterboxing a sequence that has since changed shape.
- No sequence-dimension editing. "This should be configurable" is answered here for the *export*; the
  sequence's own `width`/`height` are set at creation and changing them is a `resizeSequence` command
  that does not exist in `TimelineCore` yet.
- No multi-sequence export and no queue: one sheet exports the active sequence.
- No keyboard shortcut, for the reason the rename plan gives — a plain command-letter belongs to a menu
  and this window has none.
