# The frame, at edit time

Status: plan, 2026-09-14. Corrects `docs/plans/sequence-format.md` (decisions 2 and 6) and
`docs/plans/export-sheet.md` (the file-name formula). Companion to `docs/plans/frame-guide.md`, whose
overlay is untouched. Nothing in `TimelineCore`, `Contracts`, `RenderKit`, or `MediaKit` changes: this
is vocabulary, one control moved, one offer turned into an action, and one string in a file name.

## 0. Context

Three sentences of a user report, each of which is a defect:

> I think that the code has the idea of a 'sequence' but this isn't something a user is thinking about.
> So the button 'match the sequence' doesn't actually make any sense. To a user, they don't know what a
> sequence is and I don't know why they would ever want it to not simply match the video and the frame
> they setup when building it. Basically, the export is not the place to do this work: it should be at
> edit time in the main UI.

1. **The model's word leaked into the product.** `Sequence` is a correct name for a container of tracks
   and a frame; it is what `Command.Operation.setSequenceSettings` writes and what `SequenceID`
   addresses. It is not a thing this app's user has ever been shown, named, created, or chosen between —
   there is exactly one per project and no UI makes a second. Yet it is in a sheet title
   (`SequenceFormatText.title` = "Sequence format"), in a preset name (`ExportText.matchSequence` =
   "Match sequence"), in a status-bar button ("Match sequence to media"), in four export-sheet
   sentences, and — worst — in the name of every exported file.

2. **The file is named after the sequence.** `ExportDraft.defaultURL(sequenceName:presetName:…)` and
   `AgentKit.ExportDestination.url(sequenceName:…)` both build `<sequenceName>-<presetName>.<ext>`, and
   `ProjectDocument.create` hard-codes the sequence's name to "Sequence 1". So a user whose project is
   called `911` exports `Sequence 1-Match sequence.mp4`. Neither half of that name is a word they typed
   or a word they would recognise.

3. **Framing is being asked about, not done.** `AppModel.noteFormatAfterImport` raises a dismissible
   offer in the status bar when footage lands in a project still at the 1920x1080 creation default.
   `sequence-format.md` decision 6 argued for the offer ("Resizing behind the user's back is not on the
   table"). The user has overruled it: *"I don't know why they would ever want it to not simply match
   the video"*. They are right, and the caution was mine, not theirs.

4. **Framing is export-time work.** It is not only that the export sheet has a fix-it button
   (`AppModel.matchFormatAndExport`). It is that the export sheet is the *best* place in the app to
   discover the problem, because it is the only place that draws both fits and says what the bars are.
   Edit time has a toolbar button labelled "Format", a status-bar line, and — since yesterday — a frame
   drawn on the preview. What it does not have is a way to *change* the frame without opening a modal
   sheet from the document toolbar.

## 1. The vocabulary

One word, chosen because a video person already owns it and because it is already what this codebase's
own copy reaches for when it is being careful: **frame**.

| Not this | This | Where |
|---|---|---|
| "Sequence format" | **Project frame** | the sheet's title, the menu's label |
| "Match sequence" (the preset) | **Project frame** | the export preset, the file name |
| "Match sequence" (the rate row) | **Project frame rate** | the export sheet's rate picker |
| "Match media" / "Match sequence to media" | **Match footage** | the frame menu's first row, the status note |
| "the sequence fills the frame" | "the project's frame fills it" | `ExportFraming.summary` |
| "the sequence's own frame is what to change" | "change the project's frame, above the timeline" | the export warning |
| "The sequence has no caption tracks" | "The project has no caption tracks" | the publish sheet |
| "No sequence" | "Nothing to edit yet" | the empty timeline |
| "The project has no active sequence" | "The project has nothing to edit yet" | `DocumentError` |
| "Change sequence format" | **Change frame** | the history row's label |

Four nouns carry the whole feature and no fifth is introduced: **project**, **frame** (its size and its
rate), **footage** (what the clips are), **aspect**. The existing copy already says "footage fills the
frame" and "656 px pillarboxed"; this plan makes the rest of it agree with that sentence rather than
with the model.

**What does not change.** `Sequence`, `SequenceID`, `SequenceSettings`, `setSequenceSettings`,
`sequenceSettingsChanged`, `OutputSize.matchSequence`, `FrameRatePolicy.matchSequence`,
`ExportDraft.Rate.matchSequence`, the `sequenceId` tool parameter, `project_describe`'s sequence
reporting, and the type names `SequenceFormat` / `SequenceFormatSheet` / `SequenceFormatText` /
`SequenceFormatView.swift`. Those are the model's vocabulary and the wire's, and renaming them would be
a large diff that changes nothing anybody reads. The rule a reviewer can apply is the one `ui-style.md`
already uses for Assistant/Agent: **above a string literal the user sees, the word is "frame"; at and
below the type system, the word is "sequence".**

`ProjectDocument.create` keeps naming the sequence "Sequence 1". After section 3 nothing displays it,
and changing it would be a migration for a string that is now invisible.

## 2. Where frame editing lives

**Decision: on the preview, beside the frame guide's switch, as a menu; with the status bar's frame
line as the same menu; and the modal sheet demoted to what it is actually for — a custom size and the
frame rate.**

The reasoning, in the order it was argued:

- *The frame is a property of the picture, and the picture is the preview.* Since `frame-guide.md`
  landed, the frame is **drawn** on the preview, stroked on its own edge, with `2160 × 3840 · 9:16` in
  its corner and the footage's own rectangle dashed inside it when it misses. The one thing a user
  cannot do from there is change it. A control that changes what an overlay is drawing belongs next to
  that overlay's switch — which is exactly the rule `frame-guide.md` decision 4 used to put the switch
  there ("a viewfinder control in the corner, the way every NLE puts its overlay controls on the
  viewer").
- *The toolbar is document-level and the frame is not a document-level act.* New, Open, Fork, Rename,
  Import, Export: every other toolbar item makes, opens, copies, names, fills, or emits the **file**.
  The frame is an edit — it goes in the history, it undoes, it changes every rendered pixel. It was in
  the toolbar because the sheet was written before the preview could draw a frame. **The "Format"
  toolbar button is removed.** (Its `.help` modifier is also currently misattached: the string
  "Rename this project; the .tlproj package keeps its file name" is hung on the Format button, so
  Rename has no tooltip at all. Removing Format puts that help back where it belongs.)
- *A menu, not a sheet, because the answer is one row nine times out of ten.* "Match footage",
  five presets, and "Custom frame…". Picking a row applies one `setSequenceSettings` transaction
  immediately; there is nothing to confirm, because ⌘Z is the confirmation and the preview redraws
  under the pointer. A modal sheet to answer "portrait or landscape" is three interactions for one bit.
- *The sheet survives, reachable from the menu's last row, because two things still need a form:* a
  custom width and height, and the frame rate (with `decide`'s own locking rule shown). Those are
  genuinely a sheet's shape, and they are rare. Its title becomes "Project frame".
- *The status bar's frame line becomes the same menu.* It already shows the size, the aspect, and the
  bars, and it is the only always-labelled place the frame is named; making it open the menu rather
  than the sheet costs one line and gives the icon-only viewfinder control a labelled twin. The
  status-bar line is what carries the numbers; the preview control is icon-only (`aspectratio`, tinted
  `warning` with `exclamationmark.triangle` when the footage does not fill the frame), because the
  guide's own label is already drawing those numbers three inches away and a second copy on the same
  picture is noise.

The inspector stays clip-scoped, for the reason `project-rename.md` gives and `sequence-format.md`
repeats.

### The rows, as a value type

The house pattern (`ui-style.md`; `PanelLayoutModel`, `ExportFraming`, `FormatMismatch`, `FrameGuide`)
is that the decision is a `Hashable, Sendable` struct a test can hold and the `View` only renders it.
So the menu's contents are `FrameChoices`, built from a `FormatMismatch`:

```swift
public struct FrameChoices: Hashable, Sendable {
    public struct Row: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable { case matchFootage, preset, custom }
        public let kind: Kind
        public let title: String          // "Match footage — 1080x1920, from IMG_1575.MOV"
        public let size: FrameSize?       // nil for Custom
        public let isCurrent: Bool        // the frame the project is in now
        public let isRecommended: Bool    // match-footage, when the footage does not fit
    }
    public init(mismatch: FormatMismatch)
    public let current: FrameSize
    public let rows: [Row]
    public var label: String              // "1080 × 1920 · 9:16"
    public var hasMismatch: Bool
    public var help: String               // the tooltip, which carries the numbers the icon cannot
}
```

## 3. The file name

`<projectName>-<presetName>.<ext>`, in both copies of the formula.

- `ExportDraft` takes a `projectName` and drops `sequenceName`; `defaultURL` takes `projectName:`.
- `AgentKit.ExportDestination.url` takes `projectName:`; `render_export` passes `resolved.project.name`
  (it already has it) instead of `sequence.name`, and its `outputPath` schema description is corrected
  to say `<project>-<preset>.<ext>`.
- The skeleton check's existing assertion that the two produce the identical URL is kept, and gains a
  second one: the default name **starts with the project's own name**, which is the user's complaint
  stated as a test.

Consequences, handled deliberately:

- **The preset's `name` changes with it.** `ExportDraft.matchSequence` keeps its Swift identifier
  (it mirrors `OutputSize.matchSequence`, which is `Contracts` and frozen) and its `name` becomes
  "Project frame". That name travels: into the render ledger row's `preset`, into the `ExportReceipt`,
  and into `publish_youtube`'s approval card (`PublishTools.swift`, `ApprovalDetail("Render", …)`) and
  the publish sheet's render picker (`PublishSheet.swift`). **Nothing looks a preset up by that name.**
  `publish_youtube` finds a render by `renderId`, and `RenderTools.preset(named:)` resolves only
  `hevcHLG4K`, `h264_1080p`, `reel9x16`, `proRes` and `ExportPreset.builtIn` — none of which this
  preset is a member of, because it is `TimelineUI`'s. So the change is display-only everywhere it
  travels, and the display is better everywhere. Old ledger rows keep the old string, which is correct:
  they record what was actually used.
- **`911-Project frame.mp4`, not `911.mp4`.** The preset half of the formula stays, because it is what
  keeps two exports of one project from overwriting each other, and because the sheet lets the user
  choose the path anyway.

## 4. Stop asking, start doing

`formatOffer`, `formatOfferDismissed`, `acceptFormatOffer`, `dismissFormatOffer` and the status bar's
two-button offer strip are **deleted**. `noteFormatAfterImport` keeps its name and applies the change.

The rule, exactly:

> When a video import lands in a project whose frame is **still at the creation default**, whose
> history contains **no frame change of any kind**, and whose footage **agrees on a single shape** that
> disagrees with that frame — set the frame to the footage's own, as one ordinary transaction, and say
> so in the status bar.

Each clause earns its place:

- **Still at the creation default** — `SequenceFormat.creationFrameSize` (1920x1080, moved out of
  `AppModel` so the skeleton check and the tests can see it). A project already at some other frame is
  one somebody framed.
- **No frame change in the history** — `history.allEvents` contains no `sequenceSettingsChanged`. This
  is the "the user has never set a frame themselves" clause, and reading it from the event log rather
  than from a flag on `AppModel` makes it **durable across launches** and, more importantly, makes it
  **survive an undo**: the auto-match writes such an event, so undoing it leaves the event in the log,
  and the next import does not re-apply what the user has just rejected. A boolean on the model would
  have re-fired on the next launch and turned a deliberate undo into a fight.
- **Footage agrees on a single shape** — `FormatMismatch.suggestedSize`, unchanged. Mixed shapes have
  no single right answer, so nothing is done and the frame menu is where the user chooses.
- **One ordinary transaction** — `document.apply(operation, label: "Match frame to footage")`. ⌘Z
  undoes it (the timeline's `keyDown`), so does the toolbar's Undo, and the history row names it.
- **Say so** — `lastStatusNote` = `Frame set to 1080x1920 to match IMG_1575.MOV. Undo restores
  1920x1080.` It names the new frame, names the clip it followed, and names what undo gives back. An
  import that already produced a note (the library-only path) keeps it; the two are joined with " · ".

The decision itself is a pure function in `TimelineUI` so the skeleton check can prove it on real media
without an `AppModel`:

```swift
extension SequenceFormat {
    public static let creationFrameSize = FrameSize(width: 1920, height: 1080)
    /// The frame change to make when footage first lands in a project nobody has framed. Nil whenever
    /// the user's own choice — including a choice expressed by undoing this one — must stand.
    public static func autoMatch(sequence: Sequence, assets: [AssetID: Asset], history: History)
        -> SequenceFormat?
}
```

`AppModel.noteFormatAfterImport` becomes: build it, apply its `operation`, write the note.

## 5. What the export sheet becomes

**The fix-it button and the "Change the sequence format…" link are removed**, along with
`AppModel.matchFormatAndExport`, `ExportSheetView.onMatchAndExport`, `ExportSheetView.onChangeFormat`,
and `ExportText.matchAndExport`.

**The warning stays**, read-only. This is the part worth arguing, because "the export is not the place
to do this work" could be read as "the export should say nothing".

It should still say it, and the reason is the same one that put the warning there in the first place:
the compositor fits twice and never crops, so an export from a badly framed project is a file with
black in it, and the export sheet is the last moment before that file exists. Removing the sentence
would make the app quiet at exactly the moment it has the most certain thing to say. What it must not
do is *offer to fix it there* — that is the work being put back at edit time, and a button that resizes
the project from inside an export sheet is the confusion the user is complaining about, not a
convenience.

So the warning keeps both of its true sentences (one fit missed, or both), loses the word "sequence",
and ends by naming where the fix is: **"Change the project's frame, above the timeline."** With
section 4 in place this state is now rare — it takes a project somebody framed by hand, or footage of
two different shapes — which is the other half of why a button there is not needed.

## 6. What is added and changed

### `Sources/TimelineUI/SequenceFormatView.swift`

- `FormatMismatch.advice` — "Matching the frame to the footage makes it 2160x3840."
- `SequenceFormatText`: `title` → "Project frame"; `matchMedia` → "Match footage"; `matchOffer` and
  `dismiss` deleted; `change` → "Custom frame…"; new `matchedNote(_:source:restoring:)` for the status
  bar, `frameMenu`, and `frameHelp`.
- `FrameChoices` (section 2) and `FrameMenu` (the `View`: a `Menu` whose label is an icon for the
  preview and a labelled row for the status bar, driven by one `style` parameter).
- `SequenceFormat.creationFrameSize` and `SequenceFormat.autoMatch(sequence:assets:history:)`
  (section 4).
- `SequenceFormat.Selection.matchMedia` keeps its Swift name; the copy it renders says "footage".

### `Sources/TimelineUI/ExportSheetView.swift`

- `ExportText`: `matchSequence` → `projectFrame` ("Project frame"), new `projectRate`
  ("Project frame rate"), `fitNote` / `boxedTwice` / `sequenceMismatch` (→ `frameMismatch`) reworded,
  `matchAndExport` deleted.
- `ExportFraming.summary` reworded.
- `ExportDraft`: `sequenceName` → `projectName`; `init(sequence:projectName:exportsDirectory:)`;
  `defaultURL(projectName:…)`.
- `ExportSheetView`: `onMatchAndExport` and `onChangeFormat` removed; the warning block keeps its
  `Label` and loses its two buttons.

### `Sources/TimelineUI/PublishSheet.swift`, `TimelineScene.swift`

One string each.

### `Sources/AgentKit/Tools/RenderTools.swift`

`ExportDestination.url(projectName:…)`, the call site, and the `outputPath` schema description.

### `Sources/TimelineApp/Views.swift`

- `formatOffer` / `formatOfferDismissed` / `acceptFormatOffer` / `dismissFormatOffer` /
  `matchFormatAndExport` / `AppModel.creationFrameSize` deleted.
- `noteFormatAfterImport` applies (section 4); `setFrame(_:)` is the menu's commit path.
- `presentExportSheet` passes the project's name; the save panel's message names the project.
- The toolbar's Format button is removed and Rename's `.help` is restored.
- `previewOverlay` gains `FrameMenu(style: .viewfinder)` beside `FrameGuideToggle`; the status bar's
  frame button becomes `FrameMenu(style: .status)`; the offer strip is gone.
- The transaction label is "Change frame" (menu and sheet) / "Match frame to footage" (automatic).

### `Sources/TimelineApp/ProjectDocument.swift`, `Services/ToolLoopRuntime.swift`

One string each.

## 7. Tests

`Tests/TimelineUITests/SequenceFormatTests.swift`

- `FrameChoices` over a portrait-in-landscape mismatch: match-footage first and recommended, the
  current preset marked, custom last, the right sizes;
- `FrameChoices` over a clean project: no match row, nothing recommended;
- `autoMatch` returns the footage's frame for a default-framed project holding one portrait clip;
- `autoMatch` is nil when the frame is not the creation default, when the history already holds a
  `sequenceSettingsChanged` (the undo case), when the footage is mixed, and when the footage already
  fits;
- the copy sweep: every public string in `SequenceFormatText`, `ExportText`, `FrameGuideText` and the
  `FrameChoices` rows, asserted not to contain "sequence" in any case.

`Tests/TimelineUITests/ExportTests.swift` — the preset's new name; the default path following the
**project** name; `A/B` still not making a subdirectory; the draft's existing assertions retargeted.

`Tests/AgentKitTests` — `ExportDestination.url` under its new label, if a case names it.

No `RenderKitTests`, `TimelineCoreTests`, `ContractsTests`, `ProjectStoreTests`, `PublishKitTests` or
`AudioAlignTests` change: nothing below `TimelineUI` moves.

## 8. The skeleton check

Still 19 steps; two of them change, because they assert copy and behaviour this plan changes.

**`export`** — the preset name assertion becomes `ExportText.projectFrame`; the path assertion passes
`projectName:` on both sides, so it keeps pinning `ExportDraft.defaultURL` to
`AgentKit.ExportDestination.url`; and one new line asserts the default file name begins with the
project's own name and contains no "Sequence".

**`format`** — rewritten around the automatic path, which is now the behaviour:

1. a new project holding one 720x1280 clip is 1920x1080 and pillarboxes it by 656 px, which the export
   sheet's own framing still calls exact (kept: it is the proof that the export sheet looks one stage
   too late);
2. `SequenceFormat.autoMatch` offers 720x1280, naming the clip;
3. applying it is **one** transaction, keeps every clip, and leaves the mismatch clean;
4. the export sheet over the result defaults to 720x1280 and to a file named after the **project**;
5. the real render writes a 720x1280 file;
6. undo restores 1920x1080 — **and `autoMatch` now returns nil**, because the history holds the change.
   That is the constraint in section 4 proved end to end: the app does the work once and never argues
   with the user about it.

## 9. Documentation

`docs/design/ui-style.md`'s "The preview" section gains the frame control beside the guide's switch and
a line naming the vocabulary rule. `docs/plans/sequence-format.md` decisions 2 and 6 and
`docs/plans/export-sheet.md`'s file-name note are marked corrected, pointing here.

## 10. Left out

- Renaming `Sequence`, `SequenceID`, `SequenceSettings`, `setSequenceSettings`, or the file
  `SequenceFormatView.swift`. Section 1 says why.
- A frame picker in the New flow. Still `sequence-format.md`'s "left out", and section 4 now makes it
  much less necessary: the first import frames the project.
- Per-clip fit — crop, fill, scale-to-fill. Unchanged from `export-sheet.md` decision 5: a `Contracts`
  change with its own plan.
- Mixed-shape footage. `autoMatch` declines and the menu is where the user picks; there is no
  "which of these two shapes did you mean" prompt, and inventing one is a different feature.
- Safe-area guides, thirds, a centre cross. Still `frame-guide.md`'s list.
