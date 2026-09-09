# Track controls: mute, solo, lock, remove

Status: plan, 2026-09-09. Companion to `docs/design/timeline-model.md` sections 2, 5, 6 and 9, and
`docs/design/conventions.md`. The write path does not change: every state change here is exactly one
command through `decide`, and every one of them is undoable.

## 0. Decisions taken before implementation

The brief left four questions open. These are the answers the plan is written against.

1. **Solo is persisted project state, not per-session view state** — a `Track` field, a command, an
   event, undoable like mute. See 2.1 for why, and 2.6 for the export hazard this creates and the
   warning that closes it.
2. **Solo is scoped to the track's kind, additive, and offered on every kind.** Soloing an audio track
   silences the other *audio* tracks and leaves video and captions alone. Several tracks may be soloed
   at once; every non-soloed track of a kind that has a solo is silenced. See 2.2.
3. **An explicit mute beats solo, and the two silences are drawn differently.** A track is silent when
   `muted || (some track of its kind is soloed && !solo)`. One function in `TimelineCore` reports
   *which* of those it is, and both the compiler and the scene builder call it. See 2.3.
4. **Remove asks nothing.** `TrackRemoved` already carries the whole `Track` including its clips, so
   ⌘Z is the confirmation. See 2.4.

A fifth decision the brief did not ask for: **lock gets a button too.** `setTrackLocked` and the "L"
badge have existed since Phase 1 with nothing in the app that can set them, and `decide.removeTrack`
rejects a locked track — so without a lock toggle the new remove button is a dead end on exactly the
tracks a user most wants to protect. It reuses the existing command; it costs one case in an enum.

## 1. Current behaviour

**The model has mute and lock, and no solo.** `Track` (`Sources/TimelineCore/Model.swift:302`) is
`{ id, kind, name, muted, locked, clips, language?, captionStyle? }`. `solo` appears nowhere in
`Sources/`.

**Mute and lock are fully plumbed and completely unreachable.** `Command.Operation.setTrackMuted` /
`setTrackLocked`, `TrackMuteSet` / `TrackLockSet`, their `Decide` cases, `Evolve` cases, `Invert`
pairs, `History` labels, `Projections` invalidation, agent schemas, and
`TimelineViewModel.setTrackMuted(_:_:)` / `setTrackLocked(_:_:)` all exist. **Nothing in `TimelineUI`
or `TimelineApp` calls those two view-model methods.** The only way to mute a track today is the agent
or a hand-written command.

**Mute already reaches playback.** `SequenceCompiler` skips a muted track's video layers
(`Compiler.swift:398`), skips its captions (`:360`), and forces its clips' audio gain to 0
(`:466`, `:476`). So mute is functionally complete; only the control is missing.

**The header is Metal-drawn, not SwiftUI.** `TimelineSceneBuilder.addTrackHeader`
(`Sources/TimelineUI/TimelineScene.swift:325`) draws a background quad, the track name, and two
14×14 "L" and "M" badges right-aligned at `headerWidth - 20`. `TimelineLayout.headerWidth` is 120.
There is no notion of a control rect anywhere.

**Headers hit-test but do nothing.** `HitTarget.header(TrackID)`
(`Sources/TimelineUI/TimelineGestureController.swift:27`) is returned by `hitTest` at `:61` and
`mouseDown` answers it with `state = .idle` (`:90`). No mouse-up path, no command.

**Row and clip dimming already exists but only tracks two flags.** The scene dims a locked row
(`rowColor.scaled(0.8)`, `TimelineScene.swift:293`) and a muted track's clips (`color.scaled(0.7)`,
`:388`). Nothing distinguishes "you muted this" from "something else silenced this", because nothing
else can silence anything yet.

**Keys in use.** `TimelineKey` covers `B` split, `N` snapping, `⌘Z`/`⇧⌘Z`, `+`/`-`, arrows, Escape,
Delete/Backspace (`TimelineMetalView.keyDown`). `M` and `S` are free.

## 2. Design

### 2.1 Why solo is persisted state

The argument for a session-only solo is real: soloing is a monitoring gesture, and a solo that outlives
the session can silently poison an export. The argument that wins anyway is the compiler's signature.

`Contracts.Renderer.compile(_ sequence: Sequence, assets:, options:)` takes a `Sequence` and nothing
else. A session-only solo would have to reach the compiler as a fourth argument — a `Contracts`
protocol change rippling through `AVFoundationRenderer`, `FakeRenderer`, `PreviewPlayer`'s three
compile sites, `RenderTools`, and `PublishTools` — or else the view model would have to hand the
renderer a doctored copy of the sequence, which is a second, invisible definition of the project that
the history view, the agent, and the inspector would all disagree with. Persisting `solo` on `Track`
costs one `Bool` and reaches the compiler for free, exactly the way `muted` already does.

Everything else follows: undo/redo works with no new code, `timeline_apply` can solo, the MCP surface
stays uniform with `setTrackMuted`, and reopening a project shows what you left.

**It is not a schema version bump.** `Track` gets a hand-written `init(from:)` that reads `solo` with
`decodeIfPresent(_:) ?? false`, the pattern `AlignmentSettings` already uses in the same file
("Older documents lack the fields added after Phase 1; they decode with the defaults above",
`Model.swift:134`). Old `project_state` rows and old `TrackRemoved` / `TrackRestored` snapshots in the
event log decode unchanged, so no `Upcaster` step and no `currentSchemaVersion` bump is needed —
`Upcaster` steps exist for payloads that must be *rewritten* (a renamed key), and this is a purely
additive field with a default. `Upcaster.standardEmbedded` already lists the two track-snapshot
locations; they keep working untouched.

The `tracks` SQL projection gets a `solo` column in a new `v3` migration
(`ALTER TABLE tracks ADD COLUMN solo INTEGER NOT NULL DEFAULT 0`), matching `muted`.

### 2.2 Solo semantics

**Per kind.** A solo silences only tracks of the same `TrackKind`. Soloing A2 must not black out the
video — that is what a cross-kind solo would do, and no editor behaves that way. The rule is stated
once, in terms of the kind: *if any track of kind K is soloed, every track of kind K that is not
soloed is silent.*

**Additive.** Any number of tracks may be soloed. Soloing a second track adds it to what you hear
rather than replacing the first. There is no exclusive/radio solo in this pass; option-click for
exclusive solo is an obvious follow-up and is deliberately not built now.

**Offered on all three kinds.** Solo on a video track means "show me only this layer", on a caption
track "show me only this language". Both are useful, both are the same rule, and a header whose
buttons change per kind is harder to learn than one that does not. A kind with a single track can
still be soloed; it just changes nothing, which is the honest outcome of the rule rather than a
special case.

### 2.3 Mute versus solo, in one function

Mute wins. A track that is both muted and soloed stays silent: mute is the user's own statement about
that track, solo is a filter over whatever is left. This also makes the predicate composable and
total:

```swift
/// Why a track contributes nothing to the compiled output. `.muted` is the user's own statement about
/// the track; `.solo` is a consequence of another track of the same kind being soloed and vanishes
/// when that one does. The UI must not draw them the same way, so it must not have to recompute them.
public enum TrackSilence: String, Hashable, Sendable, Codable {
    case muted
    case solo
}

extension Sequence {
    /// True when some track of `kind` is soloed, so its peers are silenced.
    public func hasSolo(_ kind: TrackKind) -> Bool

    /// Nil when the track plays; otherwise why it does not.
    public func silence(of track: Track) -> TrackSilence?

    /// Shorthand for `silence(of:) == nil`.
    public func isActive(_ track: Track) -> Bool
}
```

This lives in `TimelineCore` beside the model, which is the only place both `RenderKit` and
`TimelineUI` can see. **`SequenceCompiler` stops reading `track.muted` at all four sites** and reads
`sequence.isActive(track)` instead; the scene builder reads `sequence.silence(of: track)`. One rule,
two consumers, no chance of the picture and the sound disagreeing.

### 2.4 Remove

`decide.removeTrack` already does the right thing: it rejects a locked track with `trackLocked`,
emits a `TransitionRemoved` for every transition on the track, and emits `TrackRemoved` carrying the
full `Track` snapshot with all of its clips. `invert` turns that into `TrackRestored` at the same
index. So removing a track with forty clips on it is one ⌘Z away from coming back, clips, transitions,
mute state, and position included.

Given that, **no confirmation sheet.** A modal that guards a fully reversible action trains people to
dismiss modals. Two things stand in for it:

- The button is the last of four in the strip and does nothing on a **locked** track (the command
  would be rejected; the UI does not send a command it knows will fail — see 2.5). Locking is the
  deliberate protection, which is what lock is for.
- The history view already names it: `History.label(for:)` maps `TrackRemoved` to "Remove track", so
  the undo stack reads correctly without any new string.

Clips on the removed track go with it, inside the snapshot. They are not moved, orphaned, or promoted
to another track.

### 2.5 The header

**Width goes from 120 to 148.** Four 18×18 buttons with 3pt gaps are 81pt wide; at 120 they would
leave 25pt for the name.

**Two layouts, one function.** Row heights differ by kind (video 64, audio 44, caption 28), and 28pt
cannot hold a name above a button strip. So:

- `row.height >= 40` (video, audio): the name occupies the first line at full header width; the
  strip sits on the second line, left-aligned at x = 8.
- `row.height < 40` (caption): the strip is right-aligned on the row's centre line, and the name
  truncates into the 51pt that remain.

Both cases come out of **one pure function in `TimelineLayout`**, so the scene builder and the hit test
cannot drift apart:

```swift
public enum TrackControl: String, Hashable, Sendable, CaseIterable {
    case mute, solo, lock, remove
}

extension TimelineLayout {
    public static let controlSize: CGFloat = 18
    public static let controlGap: CGFloat = 3
    /// The four buttons in draw order, with their rects in view space.
    public func controls(in row: TrackRow) -> [(control: TrackControl, rect: CGRect)]
    /// The button under `point`, if any.
    public func control(atPoint point: CGPoint, in row: TrackRow) -> TrackControl?
    /// Where the name goes and how wide it may be, given the strip.
    public func nameRect(in row: TrackRow) -> CGRect
}
```

**Glyphs are single ASCII capitals: M, S, L, X.** `LabelCache` renders arbitrary text through CoreText
so a "✕" would draw, but the scene builder positions glyphs with hand-tuned offsets (as the current
badges do at `+3` and `+2`) and has no metrics; four capitals of similar width keep that honest. X for
remove is unambiguous next to M, S and L.

**States.** Every button is a rounded quad (radius 3) plus one centred glyph.

| Button | State | Fill | Glyph |
|---|---|---|---|
| M | plays | `controlOff` | `dimText` |
| M | **muted** (explicit) | `mutedBadge`, solid | white |
| M | **silenced by another track's solo** | `controlOff` with a 1.5pt `mutedBadge` **ring** | `mutedBadge` |
| S | not soloed | `controlOff` | `dimText` |
| S | **soloed** | `soloBadge`, solid | black |
| L | unlocked | `controlOff` | `dimText` |
| L | **locked** | `lockedBadge`, solid | black |
| X | normal | `controlOff` | `dimText` |
| X | locked track (inert) | `controlOff` at 0.4 alpha | `dimText` at 0.4 alpha |

The mute button carries decision 3's distinction, and it carries it in one place: **filled means you
did it, a ring means something else did.** Both are red, because both mean no sound; the fill says
who. The ring is two quads — the badge colour, then the button's own fill inset by 1.5pt — since
`SceneQuad` has no stroke.

**New theme colours.** `soloBadge = SceneColor(0.35, 0.65, 0.95)` and
`controlOff = SceneColor(0.24, 0.24, 0.27)`. Solo is blue, not the conventional yellow, because
`TimelineTheme.selection` is already `(1.0, 0.80, 0.20)`; blue is also the pairing with red that
survives red-green colour blindness, and the M/S glyphs mean the state is never colour-only anyway.

**In the lane, not just the header** — reading the timeline from ten feet away must work:

- A **silenced** track (either cause) dims: row background `scaled(0.75)`, clips keep the existing
  `scaled(0.7)`. This generalizes what mute already did; the cause lives in the header.
- A **soloed** track brightens: row background `scaled(1.12)`, plus a 2pt `soloBadge` accent bar down
  the left edge of the lane at `trackAreaMinX`. The soloed row pops while its peers recede, which is
  the whole point of solo.
- Locked keeps its existing `scaled(0.8)`; a track that is both locked and silenced takes the darker.

### 2.6 The export hazard, and the warning that closes it

Persisting solo means a project can be exported while soloed. `RenderKit.Export` already has the
mechanism for exactly this class of "we did what you said, and you should know": `ExportSettings`
accumulates `warnings`, and the run loop appends one per offline asset before writing them into the
`ExportReceipt` and the `JobOutcome` (`Export.swift:101-103`, `:149-150`).

So `RenderPayload` gains `silencedTracks: [String]` (track names, filled in by `SequenceCompiler`
where it already computes per-track activity), and export appends
`"Track \(name) is silenced (mute or solo)"` for each. One field, one loop, no new machinery, and the
receipt now records why the export is quiet.

### 2.7 Input

**A new hit target, not a payload on the old one.** `HitTarget` gains

```swift
case control(TrackID, TrackControl)
```

beside the existing `.header(TrackID)`, which keeps meaning "header background". `hitTest` checks
`layout.control(atPoint:in:)` first and falls through to `.header` — so every existing test that
matches `.header` still matches, and the header background stays available for a future rename or
drag-to-reorder.

**Press and release, like a button.** `mouseDown` on `.control` records
`armedControl = (trackId, control)` and stays `.idle` (no scrub, no selection change). `mouseUp` fires
only if the pointer is still over the *same* control of the *same* track, so dragging off cancels;
`mouseUp` is already `async` and already returns `CommandResult?`, which is where the one command goes.

**One command per click**, built by the view model from the track's current state:

| Button | Command |
|---|---|
| M | `.setTrackMuted(trackId:, muted: !track.muted)` |
| S | `.setTrackSolo(trackId:, solo: !track.solo)` |
| L | `.setTrackLocked(trackId:, locked: !track.locked)` |
| X | `.removeTrack(trackId:)`, or nothing at all when the track is locked |

```swift
extension TimelineViewModel {
    @discardableResult public func setTrackSolo(_ id: TrackID, _ solo: Bool) async -> CommandResult?
    /// Exactly one command, or nil when the control is inert (remove on a locked track).
    @discardableResult public func toggle(_ control: TrackControl, on id: TrackID) async -> CommandResult?
}
```

**Keys: `M` and `S`, on the tracks of the selected clips.** Both letters are free, and both are the
universal binding. There is no track-selection concept in the view model and this plan does not invent
one: `M` and `S` act on every track that holds a selected clip, and do nothing when the selection is
empty. Toggle direction is "if any is off, turn them all on, else turn them all off", and more than one
track is one `.batch`, keeping the one-command-per-gesture rule. No key for remove — Delete already
means "remove the selected clips", and overloading it to delete a whole track is how people lose work.

## 3. Ordered steps

Each step builds, lints, passes its target's tests, and is one commit with a one-line message.

1. **This plan.** `docs/plans/track-controls.md`.
2. **`TimelineCore`: the model field and the silence rule.** `Model.swift` (`Track.solo`, tolerant
   `Track.init(from:)`, `TrackSilence`, `Sequence.hasSolo/silence/isActive`).
   Tests: `Tests/TimelineCoreTests/DecideTests.swift` (silence rule), `CodableRoundTripTests.swift`
   (a track JSON without `solo` decodes).
3. **`TimelineCore`: the command, the event, and the whole write path.** `Command.swift`
   (`SetTrackSolo`, case, `typeName`, `allTypeNames`, `label`, decode/encode), `Event.swift`
   (`TrackSoloSet`, case, `typeName`, `allTypeNames`, `sequenceId`, `entityIds`), `Decide.swift`
   (op case + drift check), `Evolve.swift`, `Invert.swift`, `History.swift`,
   `Sources/ProjectStore/Projections.swift`, `Examples.swift`, and the regenerated
   `Fixtures/events/TrackSoloSet.json` plus the four fixtures whose tracks now carry `"solo": false`
   (`TIMELINE_WRITE_FIXTURES`).
   Tests: `DecideTests`, `CodableRoundTripTests`, `FixtureTests`, `HistoryTests`.
4. **`ProjectStore`: the `solo` column.** `Schema.swift` (`v3`, `currentUserVersion = 3`),
   `QueryRows.swift` (`TrackRow.solo`). Tests: `Tests/ProjectStoreTests`.
5. **`AgentKit`: the operation schema.** `OperationSchemas.swift` — `setTrackSolo`, worded like
   `setTrackMuted` and naming the per-kind rule. Tests: `Tests/AgentKitTests/SchemaContractTests.swift`
   (already exhaustive over `allTypeNames`).
6. **`RenderKit`: solo affects playback.** `Compiler.swift` (four `track.muted` sites become
   `sequence.isActive(track)`; collect `silencedTracks`), `Payload.swift`, `Export.swift` (the
   warning). Tests: `Tests/RenderKitTests/UnitTests.swift` + `UpdateTests.swift`.
7. **`TimelineUI`: control geometry.** `TimelineLayout.swift` (`TrackControl`, `controls(in:)`,
   `control(atPoint:in:)`, `nameRect(in:)`, `headerWidth` 120 → 148).
   Tests: `Tests/TimelineUITests/LayoutTests.swift`.
8. **`TimelineUI`: drawing the controls and the lane states.** `TimelineScene.swift`
   (`soloBadge`, `controlOff`, `addTrackHeader` rewritten over `layout.controls(in:)`, row brightening
   and the accent bar, clip dimming keyed on `silence(of:)`).
   Tests: `Tests/TimelineUITests/LayoutTests.swift` (scene assertions) and `RenderTests.swift`.
9. **`TimelineUI`: clicking and the keys.** `TimelineGestureController.swift` (`.control` hit target,
   armed press/release, `M`/`S` keys), `TimelineViewModel.swift` (`setTrackSolo`, `toggle(_:on:)`,
   the selection-derived key handlers).
   Tests: `Tests/TimelineUITests/GestureTests.swift`.
10. **Docs.** `docs/design/timeline-model.md`: `Track` gains `solo`; `setTrackSolo` in the command
    table; `TrackSoloSet` in the event table; a "Solo" paragraph in section 4 next to "Locked tracks",
    stating the per-kind, additive, mute-wins rule.

## 4. Test plan

Swift Testing throughout, `@Suite` / `@Test` / `#expect` / `#require`, sentence-shaped names,
`UIFixture.make` and `eventually` from `Tests/TimelineUITests/UITestSupport.swift`, `Scene` from
`Tests/TimelineCoreTests/Support.swift`.

**`Tests/TimelineCoreTests/DecideTests.swift`** (appended)
- `soloingATrackEmitsOneEventAndSettingItAgainEmitsNone`
- `soloSilencesTheOtherTracksOfItsKindAndLeavesOtherKindsAlone`
- `anExplicitMuteOutranksItsOwnSolo`
- `severalTracksMaySoloAtOnce`
- `soloOnTheOnlyTrackOfItsKindSilencesNothing`
- `removingATrackTakesItsClipsAndTransitionsAndUndoBringsThemBack`
- `aLockedTrackCannotBeRemoved`

**`Tests/TimelineCoreTests/CodableRoundTripTests.swift`** (appended)
- `aTrackWrittenBeforeSoloDecodesUnsoloed`
- the existing `allTypeNames` exhaustiveness tests cover the new command and event by construction.

**`Tests/TimelineCoreTests/HistoryTests.swift`** (appended)
- `trackSoloSetInvertsToItself` (before/after swapped, applying both restores the state)
- `removingATrackAndUndoingItRestoresThePosition`

**`Tests/RenderKitTests/UnitTests.swift`** (appended) — `@Suite("Track solo")`
- `aSoloedAudioTrackKeepsItsGainWhileItsPeersAreSilenced` (the compiled `AVAudioMix` parameters)
- `soloingAnAudioTrackDoesNotDropTheVideoLayers`
- `aSoloedVideoTrackIsTheOnlyLayerInTheInstructions`
- `aMutedSoloedTrackIsStillSilent`
- `exportWarnsWhenTracksAreSilenced`

**`Tests/TimelineUITests/LayoutTests.swift`** (appended) — `@Suite("Track header controls")`
- `everyRowGivesFourControlsInMuteSoloLockRemoveOrder`
- `tallRowsPutTheStripBelowTheNameAndShortRowsPutItBeside`
- `controlRectsNeverLeaveTheHeaderAndNeverOverlap`
- `controlAtPointFindsExactlyTheButtonUnderIt`
- `theSceneDrawsAFilledMuteBadgeForAMutedTrack`
- `theSceneDrawsARingRatherThanAFillForATrackSilencedByAnotherTracksSolo`
- `theSoloedRowBrightensAndGetsAnAccentBarWhileItsPeersDim`
- `theRemoveButtonDimsOnALockedTrack`

**`Tests/TimelineUITests/GestureTests.swift`** (appended)
- `clickingTheMuteButtonEmitsExactlyOneSetTrackMutedCommand`
- `clickingSoloEmitsExactlyOneSetTrackSoloCommand`
- `clickingRemoveEmitsExactlyOneRemoveTrackCommand`
- `clickingRemoveOnALockedTrackEmitsNothing`
- `releasingOffTheButtonCancelsTheClick`
- `pressingAControlNeitherScrubsNorChangesTheSelection`
- `mAndSToggleTheTracksOfTheSelectedClipsInOneCommand`
- `mAndSDoNothingWithAnEmptySelection`

**`Tests/TimelineUITests/RenderTests.swift`** (appended)
- `theMuteAndSoloButtonsRasterizeInTheirBadgeColours` (pixel probes, the existing idiom)

Existing suites that must stay green and will need touching for the width change: `LayoutTests`
(`headerWidth` assertions), `RenderTests` (`x: 60` header probe still lands in the header),
`DropTests`, `MediaLibraryTests`, `BenchmarkTests`.

`make test` and `make e2e` both pass before each commit.

## 5. Risks

- **`headerWidth` 120 → 148** moves every x coordinate in the track area. Every layout, render, drop,
  and gesture test that hardcodes a pixel is a candidate breakage. Mitigation: nothing in the sources
  hardcodes 120 — `TimelineLayout` is the only definition and everything derives from
  `trackAreaMinX` — so the fallout is test-side and mechanical.
- **Fixture churn.** `Track` gaining an encoded field rewrites `three-clips.json`, `empty.json`,
  `linked-transition-caption-undone.json`, and the `TrackRemoved` / `TrackRestored` event examples.
  `FixtureTests` compares bytes, so they are regenerated with `TIMELINE_WRITE_FIXTURES` in the same
  commit and the diff is reviewed as `"solo": false` lines only.
- **A stale solo poisoning an export** is the price of decision 1. Mitigated by loud visual state
  (2.5) and the export warning (2.6), not eliminated. If it proves to bite in practice, the follow-up
  is a solo indicator in the export sheet, not a change of persistence model.
- **18pt hit targets are on the small side** for a mouse and unusable for a trackpad tap at speed. The
  strip is placed on its own line for video and audio rows precisely so the buttons are not crowded
  against the name. If they still feel small, `controlSize` is one constant.
- **Only a human can confirm the appearance.** The scene builder is pure and asserted; the pixels are
  asserted for a few probe points through `renderOffscreen`. Whether the header reads well at a glance,
  on a real display, at the real row heights, is not something this test suite can answer.

## 6. What the implementation did differently

Three departures from the steps above, all smaller than what was planned:

1. **No `silencedTracks` field on `RenderPayload`.** The payload already carries the `sequence`, so
   `Export` computes the warnings from `payload.sequence.silence(of:)` directly. Section 2.6's warning
   ships; the field it proposed does not exist.
2. **The RenderKit tests live in their own `Tests/RenderKitTests/SoloTests.swift`** rather than being
   appended to `UnitTests.swift`, because they need a `Stage` fixture (V1/V2 + A1/A2 over synthetic
   media) that nothing else uses. Likewise `Tests/TimelineCoreTests/TrackTests.swift` holds the pure
   silence-rule tests; only the command and undo tests went into `DecideTests`.
3. **The headless check gained a track-control assertion** inside its existing `edit` step (no new
   step): `TimelineViewModel.toggle(.solo, on:)` — the same call a click makes — emits one command,
   reaches SQLite, comes back in the scene as the accent bar, leaves V1 audible, and toggles off again.

Two test-side fixes the header width forced, both mechanical: `GestureTests`'s ruler scrub derives its
x from `layout.x(forSeconds:)` instead of hardcoding 320, and `PublishesTests`'s fake v1 database
borrows and then drops the `solo` column so today's projection writer can populate a file that is
genuinely still at schema v1.
