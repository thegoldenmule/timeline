# The razor: cutting clips by hand and by agent

Status: plan, 2026-09-10. Companion to `docs/design/timeline-model.md` sections 4 and 5, and
`docs/design/conventions.md`. The write path does not change: every cut is exactly one command through
`decide`, and every one of them is undoable.

## 0. Context

The editor can already split a clip, but only at the playhead: `B`, the toolbar's Split button, and
`TimelineViewModel.splitAtPlayhead` (`Sources/TimelineUI/TimelineViewModel.swift:486`). That is the
"add edit" gesture, not the razor. What is missing is the modal blade: press `C`, the cursor becomes a
blade, click a clip and it cuts *there*, press `V` and you are back to dragging. Cutting where you are
looking — rather than parking the playhead first — is how a montage actually gets assembled, and
snapping to clip boundaries across every track is what makes the cut land on the frame you meant
instead of one frame off.

The agent side is thinner than it looks. `Command.Operation.splitClip` exists and already reaches the
agent through `timeline_apply`, but only if the agent already knows which clip id straddles the time it
cares about, on every track, having deduped link groups, skipped locked tracks, and reproduced
`decide`'s per-track frame snap itself. That resolution is exactly what the razor does in the UI, and
doing it once means the human and the agent cut the same way.

Nothing in `TimelineCore`, `ProjectStore`, or `RenderKit` changes. `splitClip`, its event, its inverse,
its projections, and its schema all exist and are tested. This is a UI feature plus one tool.

## 1. Decisions taken before implementation

The first three were answered by the user before this plan was written.

1. **A plain razor click cuts the clip under the pointer on that track; Shift-click cuts every unlocked
   track at that time.** Linked clips still split together unless Option is held, matching the existing
   `B` rule.
2. **The razor is sticky.** `C` arms it, it stays armed for repeated cuts, `V` returns to selection,
   and so does Escape (see 2.5 for the precedence ladder, which the phrase "and so does Escape" leaves
   ambiguous).
3. **The agent gets a cut tool but never the cursor.** `timeline_cut` cuts at a time; which tool the
   human's pointer is in stays a human gesture and is not on the agent's surface.

Four more this plan takes on its own:

4. **A cut changes nothing about the selection and never moves the playhead.** The brief says "then you
   can select either new clip", so the razor must not pre-empt that choice; and the existing empty-area
   click scrubs, which would fight the tool.
5. **The blade's clip list is computed from the *snapped* time, not the raw one.** This is what makes
   "a razor click never sends a command the core will reject" structural rather than a matter of
   getting an exclusion set right. See 2.3.
6. **`splitAtPlayhead`'s locked-track filter moves into the shared helper**, which fixes a latent bug:
   today the filter only runs on the *unselected* branch (`TimelineViewModel.swift:492`), so selecting
   a clip on a locked track and pressing `B` sends a command `decide` rejects. No test covers it.
7. **A link group that crosses a locked track is skipped, not attempted.** See 2.4 — this one is the
   difference between a working all-tracks razor and one that fails whole-batch on any project with a
   locked track.

## 2. Design

### 2.1 The tool is view state, not project state

`TimelineTool` lives in `TimelineUI` and never reaches `TimelineCore`, the store, or the event log.
Which tool the pointer is in is not a fact about the project, it is not undoable, and two windows on
one project would disagree about it — the opposite of `Track.solo`, which `docs/plans/track-controls.md`
section 2.1 persisted precisely because the *compiler* had to see it. Nothing outside the view needs to
see the active tool.

```swift
/// Which pointer tool the timeline is in. View state: not persisted, not undoable, never in an event.
public enum TimelineTool: String, Hashable, Sendable, CaseIterable {
    case selection   // V
    case razor       // C
}
```

New file `Sources/TimelineUI/TimelineRazor.swift` holds the enum, `RazorTarget`, `TimelineCursor`, and
the view-model extension that resolves and commits a cut — mirroring how `TimelineDrop.swift` holds the
drop's vocabulary and behaviour while the state itself lives on `TimelineViewModel`. It imports AppKit
for the `NSCursor`, which `TimelineDrop.swift` already does for `NSPasteboard`; `TimelineLayout.swift`
stays AppKit-free.

### 2.2 The two rules `decide` enforces that the UI must mirror

Both were verified in the source and both are easy to get wrong.

**`splitClip` frame-snaps `at` before it validates.** `DecideClips.swift:398` computes
`let at = snap(o.at, l.track, in: seq)`, and `Decide.swift:145-147` rounds to `seq.frameDuration` on
frame-aligned tracks (`TrackKind.isFrameAligned` is `self != .audio`, `Model.swift:300`), halves up.
So a razor time within half a frame of a clip edge on a video track passes a naive `clip.start < at`
test and is still rejected. Every straddle test in this plan therefore uses the **per-track snapped**
time:

```swift
let t = track.kind.isFrameAligned ? at.snapped(to: seq.frameDuration) : at
guard clip.start < t, t < seq.end(of: clip) else { /* skip this clip */ }
```

**A cut on a boundary is a hard error, not a no-op.** `DecideClips.swift:399-401` throws
`.invalid(reason: "Split point … is not inside clip …")`, and `Decide.swift:25-33` has no per-op
recovery inside a `.batch` — one bad op kills the whole command. This is why both the razor and
`timeline_cut` filter candidates themselves rather than letting the core sort it out.

### 2.3 What a razor click resolves to

```swift
/// Where a razor cut would land: the time under the pointer, snapped like a drop, and the clips it
/// would split. Empty `clipIds` means the click is inert — no command, and the blade draws dimmed.
public struct RazorTarget: Hashable, Sendable {
    public var at: RationalTime
    public var snappedTo: RationalTime?
    /// The row under the pointer; nil on the ruler, the header column, or below the last track.
    public var trackId: TrackID?
    /// True when Shift was held: every unlocked track, not just `trackId`.
    public var allTracks: Bool
    /// The clips that would be split, ordered by (start, id) so two runs cut identically.
    public var clipIds: [ClipID]
}
```

On `TimelineViewModel`, mirroring `dropTarget(at:)` (`TimelineDrop.swift:113`):

```swift
public func razorTarget(at point: CGPoint, modifiers: EditModifiers) -> RazorTarget
public func updateRazor(at point: CGPoint, modifiers: EditModifiers)   // hover; sets `razorTarget`
public func endRazor()                                                  // clears it
public func commitRazor() async -> CommandResult?                       // the click
```

`commitRazor()` rather than `cut(_:)`: it parallels the existing `commit()` (`:298`), it reads
`razorTarget` the way `commit()` reads `pending`, and `cut` is a word the app will want for the
clipboard.

The order inside `razorTarget(at:modifiers:)`:

1. `raw = layout.time(atX: point.x)`; `trackId = layout.isInRuler(point) ? nil : layout.row(atY:)?.trackId`.
2. Find the *anchor*: the clip on that row (unlocked tracks only) with `start <= raw <= end`.
3. Snap: `snapEdge(raw, excluding: anchorGroupIds)` in single mode, `snapEdge(raw)` in all-tracks mode.
   `anchorGroupIds` is the anchor **plus every member of its link group**, reusing the shape of
   `movingClipIds(for:)` (`TimelineViewModel.swift:342-347`) — a linked audio partner has identical
   start and end times, so excluding only the hovered clip leaves its coincident twin in the target
   list and you snap onto a no-op cut anyway.
4. Candidates: single mode is the anchor alone; all-tracks mode is every clip on every unlocked track.
5. **Filter with the snapped `at`, per 2.2** — this is what makes the exclusion in step 3 an
   ergonomic nicety rather than a correctness requirement. An unrelated clip on another track whose end
   coincides with the anchor's start would still snap us onto a degenerate cut; filtering after the
   snap turns that into an empty `clipIds`, an inert click, and a dimmed blade, instead of a rejection
   in `lastError`.
6. Drop groups that cross a locked track (2.4), dedupe link groups unless Option, sort by `(start, id)`.

Note that `snapTargets` always contributes `.zero`, the playhead, and every marker regardless of
`excluding` (`:421`, `:428`), which is exactly what the brief asked for.

### 2.4 A link group crossing a locked track

`group(of:unlinked:)` (`DecideClips.swift:207-217`) calls `requireUnlocked` on the addressed clip **and
on every member of its link group**. So an unlocked V1 clip whose partner sits on a locked A1 throws
`trackLocked`, and inside a `.batch` that kills every other cut with it. A shift-click razor across a
project with one locked track would therefore fail entirely rather than cutting the tracks it can.

The shared helper drops such a clip:

```swift
if !unlinked, let g = clip.linkGroupId,
    seq.members(of: g).contains(where: { seq.track($0.trackId)?.locked == true }) { continue }
```

This is a real behaviour improvement for `B` as well, which inherits the same hazard today.

### 2.5 One split helper, two callers

```swift
/// One split command over `clips` at `at`: locked tracks dropped, link groups that cross a locked
/// track dropped, one op per group unless `unlinked`, and clips the *frame-snapped* point does not
/// fall strictly inside skipped. Ordered by (start, id) so the batch is deterministic. Nil when
/// nothing is cuttable — a gesture that cannot do anything sends nothing rather than collecting a
/// rejection, the rule `deleteSelection` (:525) and `toggle(_:on:)` (:591) already follow.
@discardableResult
public func split(at: RationalTime, clips: [Clip], unlinked: Bool) async -> CommandResult?
```

`splitAtPlayhead` keeps its signature and its "selection, else every clip" candidate rule and hands off
to the helper; the locked filter it used to apply only to the unselected branch now applies to both
(decision 6). Op order is preserved — `selectedClips` is already sorted `(start, id)` (`:179`) and the
unselected branch sorted the same way (`:493`) — so `GestureTests.splitAtPlayheadEmitsOneSplitCommand`
and `splitWithNothingSelectedCutsUnderThePlayheadOncePerLinkGroup` keep passing unchanged. Both callers
keep the label "Split clip", so `History` reads the same for either gesture and no new string is needed.

### 2.6 The gesture

`TimelineGestureController` gains a fourth state and one new entry point:

```swift
private enum State { case idle, scrubbing, dragging, razor }
/// Pointer moved with no button down: drives the razor's hover indicator.
public func mouseMoved(to point: CGPoint, modifiers: EditModifiers = [])
```

- **No new `HitTarget` case.** `HitTarget` answers "what is the pointer physically over" and is
  tool-independent; adding a `.razor` case would conflate tool with geometry and break the one
  exhaustive switch at `TimelineGestureController.swift:98`. `mouseDown` branches on
  `viewModel.activeTool` above the existing switch instead.
- **The razor branch applies only over the track lanes.** A razor click on the ruler still scrubs and a
  click on a header button still arms that button — otherwise the mute/solo/**lock** buttons become
  unreachable while the razor is armed, which is perverse when "locked tracks are never cut" is a razor
  rule and locking is how you opt a track out.
- `mouseDown` in the razor branch sets `state = .razor` and `updateRazor(at:modifiers:)`. It touches
  neither the selection nor the playhead.
- `mouseDragged` in `.razor` re-runs `updateRazor`, so the blade tracks live and the cut can be nudged
  before release.
- `mouseUp` in `.razor` commits `await viewModel.commitRazor()` — one command — and clears the state,
  leaving the tool armed (decision 2).
- `flagsChanged` re-runs `updateRazor` at the last pointer point when the razor is armed, so Shift
  redraws the blade full-height without moving the mouse. One stored `CGPoint?` on the controller.
- `TimelineKey` gains `case tool(TimelineTool)` — one new arm in the `key(_:)` switch (`:180`), and
  `TimelineTool` is already `Hashable, Sendable` so the conformances come free.
- **The Escape ladder**, spelled out because decision 2 and "Escape returns to selection" collide:
  1. a razor press in flight → cancel it, **keep the razor armed**;
  2. else a pending drag → `cancelGesture()` (unchanged);
  3. else `activeTool != .selection` → `selectTool(.selection)`;
  4. else `select(nil)` (unchanged).

  One Escape should not both abort the cut and disarm the tool.

### 2.7 The cursor

The decision is a pure function so it is tested; the `NSCursor` is a thin shell that is not:

```swift
public enum TimelineCursorKind: Hashable, Sendable { case arrow, razor }

public enum TimelineCursor {
    /// Arrow over the ruler and the header column; the blade only over the track lanes.
    public static func kind(for tool: TimelineTool, at point: CGPoint, layout: TimelineLayout)
        -> TimelineCursorKind
    public static func nsCursor(_ kind: TimelineCursorKind) -> NSCursor
}
```

`TimelineMetalView` adds one `NSTrackingArea` in `updateTrackingAreas()` with
`[.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate]` — one area
serves both the hover and the cursor. `mouseMoved` forwards to the gesture controller; `mouseExited`
calls `viewModel.endRazor()` (the counterpart of `draggingExited → endDrop()` at
`TimelineMetalView.swift:188`, without which the blade sticks at the last hovered x); `cursorUpdate`
sets the cursor and does **not** call `super`, whose default implementation applies cursor *rects* and
would fight it.

`resetCursorRects` is the wrong tool here: the answer depends on sub-regions of a layout that changes
with zoom, scroll, and track count, so it would mean rebuilding rects on every layout change.
`cursorUpdate` keeps the decision a pure function of the point.

**A tool change with the pointer already inside the view needs an explicit push.** AppKit only
generates cursor-update events on movement or entry, and `invalidateCursorRects` only drives the
cursor-*rect* path. `requestRedraw()` (`:69-72`) already runs on the main actor after every tracked
model change, so a small `applyCursor()` called from there — guarded on `window.isKeyWindow` and
`bounds.contains(point)` — makes `C` from the keyboard or the toolbar land without a mouse jiggle.

**The blade image.** `NSImage(systemSymbolName:)` returns a *template*, which `NSCursor` renders as
flat black — invisible on `TimelineTheme.background` (0.11, 0.11, 0.12). So the cursor is drawn into a
non-template `NSImage`: a full-height white hairline with a dark halo marking where the cut lands, and
the `scissors` glyph offset to its right so it never covers the line. Hot spot on the line.

Two footguns to record so nobody "fixes" them later: `image.isTemplate = false` is load-bearing; and
`NSImage(size:flipped: false)` draws bottom-up while `NSCursor.hotSpot` is measured **top-down** — the
mismatch is harmless only because the blade is a full-height line, so only its x coordinate matters.

`scissors` is also what the existing Split button uses (`Views.swift:416`), so the toolbar, the picker,
and the cursor all carry one glyph for one meaning.

### 2.8 Drawing the blade

`TimelineSceneBuilder.Input` gains `razorTarget: RazorTarget?` (a defaulted parameter on the memberwise
init at `:251`, which nothing outside `TimelineScene.swift` constructs). A new `addRazorIndicator`
mirrors `addDropIndicator` (`:690`):

- the snap band (`snapGuide` at 0.25 alpha, 6 pt) when `snappedTo != nil`, the same as a drop;
- a 2 pt blade line in a new `TimelineTheme.razorIndicator`, spanning **the hovered row only** in
  single mode and **the whole track area** in all-tracks mode, so the two gestures never look alike;
- a triangle at the top edge of the span, the playhead and drop idiom;
- at 0.35 alpha throughout, and no triangle, when `clipIds.isEmpty` — an inert click looks inert
  before you make it.

New colour: `razorIndicator = SceneColor(1.0, 0.35, 0.75)`. Not red (playhead), not cyan (drop), not
yellow (selection), not blue (solo), not orange (`lockedBadge` is `(0.95, 0.60, 0.15)`).

`touchRenderInputs()` (`:622`) gains exactly two lines, `_ = activeTool` and `_ = razorTarget` — the
whole target, not a field, following the `dropTarget` precedent at `:633`. Without them nothing reaches
the screen.

**`updateRazor` must diff before it assigns.** Observation fires on every set, even to an equal value,
and `mouseMoved` arrives at pointer rate — so `if razorTarget != next { razorTarget = next }`. The drop
path gets away without this only because drag updates are slower.

**Hover goes stale on scroll and zoom.** `scrollWheel` (`:136`) and `magnify` (`:146`) change the
layout without a `mouseMoved`, so the blade drifts off the pointer until the next move. Both handlers
re-run `updateRazor` at the event point; one line each.

### 2.9 The toolbar

A segmented picker in the group that already holds Split (`Views.swift:415-431`). `EditorView` holds
`let document: ProjectDocument`, not `@Bindable`, and `toolbarContent` is a `@ToolbarContentBuilder`
computed property, so the binding is built by hand exactly as `publishSheetPresented` is (`:369-371`):

```swift
private var activeTool: Binding<TimelineTool> {
    Binding(get: { document.viewModel.activeTool }, set: { document.viewModel.selectTool($0) })
}
```

`.help("Select (V) or Razor (C) — the keys work when the timeline has focus")` is where the keys are
named, because the picker deliberately carries no `.keyboardShortcut`: SwiftUI installs those as key
equivalents, which `NSApplication` dispatches *before* `keyDown` reaches the first responder, so a bare
`"c"` would arm the razor while the user was typing in the agent composer. Every timeline editing key —
`B`, `N`, `M`, `S`, the arrows, Escape — lives only in `TimelineMetalView.keyDown` (`:206-232`) for
that reason. (The bare space bar at `Views.swift:458` is a pre-existing instance of the hazard; this
plan does not extend it.)

`keyDown` switches on `charactersIgnoringModifiers`, so `"c"` also matches ⌘C and `"v"` matches ⌘V.
Both need the guard `m` and `s` already use at `:219-220`:

```swift
case "c": key = m.contains(.command) ? nil : .tool(.razor)
case "v": key = m.contains(.command) ? nil : .tool(.selection)
```

Known and accepted: clicking the picker makes the toolbar item key, so the next keystroke goes nowhere
until the timeline is clicked again. `mouseDown` already restores first responder (`:118`).

### 2.10 `timeline_cut`

**Why it earns a place on a deliberately small tool surface.** `timeline_apply` already carries
`splitClip`, so this is not a new capability — it is the resolution the razor does, moved server-side.
Without it, "cut everything at 12.5 s" costs the agent a `project_describe`, a per-track scan, a
link-group dedupe, a locked-partner check, and a reimplementation of `decide`'s per-track frame snap
(2.2), all re-derived from schema prose. Every one of those is a place to be silently wrong: split the
wrong clip and you get a valid project that is not the one that was asked for.

```
timeline_cut {
  projectId?, sequenceId?, expectedVersion, commandId?, label?,
  at?:       <$defs/time>,   // the sequence time to cut at
  atFrames?: integer,        // the same, in sequence frames; exactly one of the two
  trackIds?: [String],       // cut whatever straddles the time on these tracks
  clipIds?:  [String],       // cut exactly these clips
  unlinked?: Bool            // default false
}
```

- **`sequenceId` is declared**, unlike the other apply-side tools, because this tool resolves clips
  across tracks and `additionalProperties: false` plus registry-side validation would otherwise reject
  anyone who passed it. `ToolSupport.sequence` already implements the default.
- **`at` / `atFrames` follow `transition_add`'s `duration` / `durationFrames` pair**
  (`ApplyTools.swift:84-85`, handler `:110-116`). There is no playhead anywhere outside `TimelineUI`,
  so the time cannot be defaulted; exactly one of the two is required, checked in the handler.
- **`trackIds` and `clipIds` are mutually exclusive, enforced in the handler**, not the schema:
  `Schema` has no `not` or `dependentSchemas`, and a root-level `oneOf` would fight both
  `additionalProperties: false` and the contract test's every-property-has-a-description walk. Both
  descriptions say so.
- With neither, every unlocked track.

The handler resolves candidates against `store.state()` using 2.2's snapped straddle test and 2.3's
steps 4–6, then emits **one** command — a single `splitClip` or a `.batch` — through
`ToolSupport.command(..., requireExpectedVersion: true)` + `ToolSupport.apply`, so it is one
transaction, one undo step, and idempotent under `commandId` replay like every other mutating tool.
`ToolAnnotations(title: "Cut clips at a time", idempotent: true)`, not destructive.

**Nothing to cut is a `noop`, not an error and not an empty batch.** An empty `.batch([])` would apply
as a zero-event transaction; the handler short-circuits with a `.noop` result and `cutCount: 0`,
mirroring the UI's `guard !ops.isEmpty else { return nil }` (`:503`).

**Exactly one id is pre-minted per addressed clip** — `newIds: [ClipID(minting: UUIDv7Generator())]`,
the idiom `transition_add` (`ApplyTools.swift:119`) and `caption_add` (`:254`) already use. `decide`
consumes supplied ids positionally and mints the rest (`DecideClips.swift:415-418`), and `members[0]`
is always the addressed clip (`:409-413`), so index 0 is exactly "name the right-hand part of the clip
I addressed" with no need to replicate the source-time member filter or the `(trackIndex, clipId)`
sort. Pre-minting is worth doing at all because `CommandResult.changedIds` is an unordered
`Set<String>` (`ProjectStore.swift:39`) built from `[clipId, newClipId]` per split
(`Event.swift:923`) — the agent cannot pair old to new from the result alone.

Response, through `extra:` (which overrides the standard keys, `ToolSupport.swift:127-142`):

```
cuts:     [{ clipId, newClipId, trackId, at }]   // `at` is the per-track SNAPPED time, via timeJSON
cutCount: <int>
skipped:  [{ clipId, trackId, reason }]          // "boundary" | "outside" | "lockedPartner" | "linkedDuplicate"
```

Reporting the snapped `at` rather than the requested one matters: otherwise the response lies about
where the cut landed.

Two things to say in the tool's own description, so the model does not have to discover them:
caption tracks are cut too (the razor cuts them, `:491-492`, and `splitSingle` partitions caption words
by `t0`, `DecideClips.swift:190`); and `timeline_cut` issues its own command, so it **cannot** appear
inside a `timeline_apply` batch.

**The `jump-cut-talking-head` skill is deliberately left alone.** Its step 3
(`Sources/AgentKit/Skills/jump-cut-talking-head/SKILL.md:15-17`) chains two `splitClip`s and a ripple
`removeClip` in **one** `timeline_apply` batch, using `{"$ref": 0}` to address the clip the first split
created. That has to stay one transaction to be one undo step, and `timeline_cut` cannot participate.
One line is added under its `## Notes` pointing at `timeline_cut` for a plain cut with no removal;
the recipe itself does not change.

### 2.11 What is reused rather than written

| Need | Existing thing to call | Where |
|---|---|---|
| Pointer x to sequence time | `TimelineLayout.time(atX:)` | `TimelineLayout.swift:108` |
| Pointer y to track row | `row(atY:)`, `isInRuler`, `isInHeader` | `TimelineLayout.swift:116-120` |
| Snap across all tracks | `snapEdge(_:excluding:)` over `snapTargets(excluding:)` | `TimelineViewModel.swift:419,435` |
| The link-group id set to exclude | the shape of `movingClipIds(for:)` | `TimelineViewModel.swift:342-347` |
| A snapped, pointer-derived target | `TimelineDropTarget` + `dropTarget(at:)` | `TimelineDrop.swift:12,113` |
| Drawing a snapped vertical indicator | `addDropIndicator` | `TimelineScene.swift:690` |
| Emitting one command | `TimelineViewModel.apply(_:label:)` | `TimelineViewModel.swift:470` |
| Clip end with frame-rounded duration | `Sequence.end(of:)` | `Evolve.swift:26-33` |
| A hand-built toolbar `Binding` | `publishSheetPresented` | `Views.swift:369-371` |
| Mutating-tool envelope | `ToolSupport.inputProperties`, `.command`, `.apply(_:to:extra:)` | `ToolSupport.swift:161,98,113` |
| Time in a response | `ToolSupport.timeJSON(_:)` | `ToolSupport.swift:182` |
| Referencing a shared `$def` | `Schema.withDefs` + `Schema.ref("time", …)` | `ApplyTools.swift:75-90` |
| Minting an id in a handler | `TransitionID(minting: UUIDv7Generator())` | `ApplyTools.swift:119,254` |

Two things confirmed safe: the only exhaustive switches over `HitTarget` and `TimelineKey` are
`TimelineGestureController.swift:98` and `:180`, so adding a `TimelineKey` case touches one site and
adding no `HitTarget` case touches none; and `SkeletonCheck.swift:48` prints its tool count from
`registry.list().count`, so no source string carries the literal 18.

## 3. Ordered steps

Each step builds, lints, passes its target's tests, and is one commit with a one-line message.

1. **This plan.** `docs/plans/cut-tool.md`.
2. **`TimelineUI`: the split helper.** `TimelineViewModel.swift` — `split(at:clips:unlinked:)` with the
   snapped straddle test (2.2), the locked-track and locked-partner filters (2.4), and
   `splitAtPlayhead` refactored onto it. Tests: `GestureTests` (the two existing split tests must pass
   untouched, plus the two new locked cases).
3. **`TimelineUI`: the tool and the target.** New `Sources/TimelineUI/TimelineRazor.swift`
   (`TimelineTool`, `RazorTarget`, `TimelineCursorKind`, `TimelineCursor`, the razor extension);
   `TimelineViewModel.swift` gains `activeTool`, `razorTarget`, `selectTool`, and the two
   `touchRenderInputs()` lines. Tests: `RazorTests` (new file), `LayoutTests` for the cursor.
4. **`TimelineUI`: drawing the blade.** `TimelineScene.swift` — `razorIndicator`, `Input.razorTarget`,
   `addRazorIndicator`. Tests: `RazorTests`, `RenderTests`.
5. **`TimelineUI`: the gesture and the keys.** `TimelineGestureController.swift` — the `.razor` state,
   `mouseMoved`, the last-point memory, `TimelineKey.tool`, the Escape ladder. Tests: `GestureTests`.
6. **`TimelineUI`: the AppKit shell.** `TimelineMetalView.swift` — the tracking area, `mouseMoved`,
   `mouseEntered`/`mouseExited`, `cursorUpdate`, `applyCursor`, the scroll/zoom refresh, `"c"`/`"v"`.
   Only the pure parts are asserted; the pixels on screen are a human check.
7. **`TimelineApp`: the toolbar and the headless check.** `Views.swift` (the picker and its binding);
   `SkeletonCheck.swift` — a razor assertion inside the existing `edit` step, no new step, the way
   `track-controls` added one.
8. **`AgentKit`: `timeline_cut`.** `Tools/ApplyTools.swift` (after `captionAdd`, before `undo`),
   registered in `EditorTools.all`; no `requiredService` entry, it needs only the store. Tests:
   `ToolTests`; counts to 19 in `SchemaContractTests.swift:61` and `AgentKitTests.swift:7`.
9. **Docs.** `docs/design/integration.md`: the window paragraph gains the razor and its keys, the
   toolbar list gains the tool picker, `:23` "the 18 real tools … (15 editor tools plus" becomes 19 and
   16, and the two recorded sample lines that say `18 tools` (`:231`, `:240`) become 19.
   `docs/design/timeline-model.md` section 4 "Gestures" gains one sentence that a razor click is one
   `splitClip` like any other gesture.

## 4. Test plan

Swift Testing throughout, sentence-shaped names, `UIFixture.make` and `eventually` from
`Tests/TimelineUITests/UITestSupport.swift`, `Harness` and `h.call(name, jsonLiteral)` from
`Tests/AgentKitTests/ToolTests.swift`. Scene assertions follow `DropTests.swift:86-115` — find a quad
by colour with `try #require(scene.overlayQuads.first { $0.color == … })`, assert rect fields exactly
against `layout` and time-derived x within 1.5, and bracket with a "nothing before / nothing after"
pair. Pixel probes follow `RenderTests.swift:13-48`.

**`Tests/TimelineUITests/GestureTests.swift`** (appended)
- `theRazorCutsTheClipUnderThePointerInOneCommand`
- `aRazorClickNeitherScrubsNorChangesTheSelection`
- `shiftClickWithTheRazorCutsEveryUnlockedTrackAtThatTime`
- `optionWithTheRazorCutsOneMemberOfALinkGroup`
- `aRazorClickOnEmptyTrackAreaEmitsNothing`
- `aRazorClickOnTheRulerStillScrubsAndOnAHeaderButtonStillTogglesIt`
- `cAndVSwitchToolsAndTheRazorStaysArmedAfterACut`
- `escapeCancelsARazorPressBeforeItDisarmsTheTool`
- `draggingTheRazorBeforeReleaseMovesTheCutAndStillEmitsOneCommand`
- `splittingASelectedClipOnALockedTrackEmitsNothing` (decision 6's fix)
- `aLinkGroupCrossingALockedTrackIsSkippedInsteadOfFailingTheBatch` (decision 7)

**`Tests/TimelineUITests/RazorTests.swift`** (new)
- `hoveringAClipNamesThatClipAndItsTrack`
- `hoveringAGapNamesNoClipAndTheBladeDrawsInert`
- `shiftNamesEveryUnlockedTracksClipAndOmitsTheLockedOne`
- `theCutSnapsToAnotherTracksEdgeButNeverToItsOwnLinkGroups`
- `aSnapOntoAClipBoundaryYieldsAnInertTargetRatherThanARejection`
- `aTimeWithinHalfAFrameOfAnEdgeIsFilteredOutOnVideoTracks` (2.2)
- `theSceneDrawsTheBladeOverOneRowForASingleCutAndFullHeightForAll`
- `theRazorDrawsTheSnapBandWhenItSnappedAndEndRazorClearsEverything`
- `updateRazorDoesNotReassignAnUnchangedTarget`

**`Tests/TimelineUITests/LayoutTests.swift`** (appended)
- `theCursorIsABladeOverTheLanesAndAnArrowOverTheRulerAndHeader`

**`Tests/TimelineUITests/RenderTests.swift`** (appended)
- `theRazorIndicatorRasterizesInItsOwnColour`

**`Tests/AgentKitTests/ToolTests.swift`** (appended) — `@Suite("timeline_cut")`
- `cuttingAtATimeSplitsEveryUnlockedTrackInOneTransaction`
- `clipIdsCutsExactlyThoseClipsAndTrackIdsCutsThoseTracks`
- `passingBothClipIdsAndTrackIdsIsRejected`
- `passingNeitherAtNorAtFramesIsRejectedAndPassingBothIsToo`
- `aTimeOnAClipBoundaryIsSkippedWhileOtherTracksStillCut` (the `three-clips` fixture cuts V1 on a
  boundary at frame 96 and straddles A1's music clip — exactly one cut)
- `nothingToCutIsANoopNotAnError`
- `theResponseNamesEachCutsNewClipAndReportsTheSnappedTime`
- `aStaleExpectedVersionIsRejectedWithChangedSince`
- `replayingTheSameCommandIdIsIdempotent`
- `unlinkedCutsOneMemberOfALinkGroup`
- `aLinkGroupCrossingALockedTrackIsReportedInSkipped`

**`Tests/AgentKitTests/SchemaContractTests.swift`** — count to 19; its exhaustive checks (strict
schema, `projectId`, validating examples, a description on every property) cover the new tool by
construction. `Tests/AgentKitTests/AgentKitTests.swift:7` likewise.

`make test` and `make e2e` pass before each commit.

## 5. Verification

1. `make lint && make test` — every target green, zero Swift 6 warnings.
2. `make e2e` — the `boot` and `mcp` lines say **19 tools**, and the `edit` line carries the razor
   assertion.
3. **By hand** (`swift run TimelineApp`), the only thing that can answer whether the blade reads well:
   drop a file on V1 so a linked V/A pair lands; press `C` (blade over the lanes, arrow over the
   headers and the ruler, and it changes without moving the mouse); hover across a clip and watch the
   blade snap onto the other track's clip edge; click (one cut, the linked audio splits too, the
   selection is untouched, the playhead has not moved); Shift-click elsewhere (full-height blade, every
   track cut); `⌘Z` once undoes the whole cut; press `V` and drag one of the new halves away, then
   Delete it. Also: lock A1 and confirm a shift-click still cuts V1 rather than failing.
4. **Through MCP**, with the app running and `timeline-mcp` on `PATH`
   (`swift build && cp .build/debug/timeline-mcp /usr/local/bin/` — this session's `timeline (ENOENT)`
   is exactly that binary being absent): `claude mcp add timeline -- timeline-mcp`, then ask for "cut
   every track at 4 seconds and delete what follows on V1". Expect one `timeline_cut` naming each cut,
   then one `timeline_apply` with `removeClip`, two undo steps, both in the History pane.

## 6. Risks

- **`mouseMoved` fires at pointer rate and each event rebuilds `razorTarget`,** which in all-tracks
  mode walks every clip on every track. The diff in 2.8 stops the redraw churn but not the walk.
  `BenchmarkTests` already runs a 1,000-clip store; measure the hover path there rather than assuming.
  If it bites, resolve candidates only on press and draw the hover line from the snapped time alone.
- **Tracking areas and cursors are the least testable code in the module.** The pure `kind(for:at:)` is
  asserted; whether the blade appears, and survives a window resize or a scroll, is a human check.
- **A modal tool is a mode, and modes strand people.** Mitigated by the picker, the cursor, and two
  ways out. If it still strands, the follow-up is a spring-loaded razor (hold `C`), not a redesign.
- **`timeline_cut` takes the surface to 19**, against `docs/design/publish-plan.md`'s wish to stay near
  15. Section 2.10 is the argument that it pays for itself.
- **The blade cursor's hot spot and the symbol's offset are guesses** until they are on screen. Two
  constants.
