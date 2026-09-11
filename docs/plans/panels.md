# Panels: an Assistant column, shared chrome, and a style guide

Status: plan, 2026-09-11. Companion to `docs/design/conventions.md` and `docs/design/ui-style.md`.
Nothing here reaches `TimelineCore`, `ProjectStore`, `RenderKit`, or the event log: this is the window's
layout and the chrome its panels wear.

## 0. Context

The window grew its panels one at a time and they never agreed on anything.

The agent pane is the bottom half of the right sidebar's `VSplitView` (`Sources/TimelineApp/Views.swift`),
sharing that column with the inspector, the approval stack, the job list, the publishes, the history, the
last tool call and the MCP section — all of them in one `ScrollView`. Only the media library can be
hidden (`⌥⌘L`, `@AppStorage("showsLibrary")`); nothing else collapses, no width is ever remembered, and no
two panels look alike: the library has a search field and no title, the inspector is a bare `Form` with no
title, and the agent pane's `AgentStatusBar` is the only thing in the app resembling a panel header. There
is no design system — paddings, radii, fonts and materials are literals across a dozen files.
`TimelineTheme` is the Metal canvas's palette and covers none of it.

What is already right and must stay right: `TimelineViewModel`, `MediaLibraryModel`, `AgentComposer` and
`AgentTranscript` own every piece of panel state and are held outside the view hierarchy, so a panel can
be torn down and rebuilt without losing anything. That is what makes collapsing safe.

## 1. The shape

```
┌──────────┬─────────┬────────────────────┬───────────────┐
│Assistant │ Library │      Preview       │  Inspector    │
│          │         ├────────────────────┤═══════════════│
│          │         │      Timeline      │  Activity     │
│          │         ├────────────────────┤               │
│          │         │     status bar     │               │
└──────────┴─────────┴────────────────────┴───────────────┘
```

Four columns. The right one is a vertical split of **Inspector** over **Activity** (approvals, jobs,
publishes, history, the last tool call, MCP). The agent pane leaves the sidebar and becomes the
**Assistant** column at the leading edge.

Every panel is resizable and collapsible, every panel wears the same header, and every size and collapsed
flag is remembered across launches.

A collapsed horizontal panel becomes a `railWidth` strip with its symbol and rotated title, clickable to
reopen. A collapsed *stacked* panel — Inspector, Activity — collapses to its own header bar instead: a
rotated title inside a full-width 28pt strip would be nonsense. When both stacked panels are collapsed the
right column renders one merged rail.

## 2. Why not `HSplitView`

`HSplitView` owns its divider positions and exposes no way to read or write them: no `autosaveName`, no
`setPosition(_:ofDividerAt:)`, no holding priorities. The only lever is `.frame(width:)` on the child,
which makes the user's drag non-authoritative and turns persistence into a feedback loop — you would have
to observe the post-drag geometry and write it back into the very frame you are imposing. `idealWidth` is
honoured on first layout only, so every structural change re-applies it and discards every other pane's
position; we have exactly one such change today (`showsLibrary`) and it already resets the sidebar.

Pinning a rail with `.frame(width: 28)` does hold the width, but the divider is still installed, still
hit-tests and still shows a resize cursor: dragging it takes width from the neighbour while the rail snaps
back, which reads as a bug. And inserting or removing a child is a structural change that NSSplitView
re-derives from holding priorities — `withAnimation` does not cross into AppKit, so a collapse jumps, and
takes unrelated panes with it.

So the container is a plain `HStack`/`VStack` with an explicit width on every side panel, `maxWidth:
.infinity` on exactly one flexible child, and a `PanelDivider` between them.

That also deletes a hazard rather than working around it. Two comments in the tree today warn that a pane
which sizes to its own content collapses the split view and drags the window with it (`Views.swift`'s
`.frame(maxWidth: .infinity, maxHeight: .infinity)` on the split, and `MediaLibraryView`'s on its two
branches). With explicit widths and one flexible child, a content-sized pane cannot move anything. Both
fills stay — they are still correct — they just stop being load-bearing.

Neither `NSViewRepresentable` is at risk. `TimelineMetalView.layout()` already syncs `bounds.size` into
`viewModel.viewSize` on every window resize; a divider drag is the identical path at the identical rate.
`AgentDropTargetView` pins its hosting view with constraints and registers dragged types on itself, so
AppKit's hit-test-then-walk-up search for a drag destination does not care who computed the ancestor's
frame.

## 3. The pieces

Three new files in `TimelineUI`, which is the only leaf library both the panels and the composition root
can see (`conventions.md`, package layout).

| File | Holds |
|---|---|
| `PanelTheme.swift` | Tokens only: spacing, radii, panel metrics, type roles, semantic fills. No views. |
| `PanelLayout.swift` | `PanelID`, `PanelLayoutModel`: collapsed flags, sizes, clamping, persistence. No views. |
| `PanelChrome.swift` | `PanelHeader`, `PanelRail`, `PanelDivider`, `PanelChrome`. |

`PanelTheme` and `TimelineTheme` stay separate, and `docs/design/ui-style.md` says why at length. The
short version: `TimelineTheme` is a fixed dark `SceneColor` palette written unmanaged to BGRA8, consumed
by a pure value type with no `NSAppearance` to resolve a dynamic colour against, and tuned for contrast
against `background = 0.11`. The chrome must follow the system appearance. One palette cannot do both.
They must agree in exactly two places and `StyleTests` asserts both.

### `PanelLayoutModel`

`@AppStorage` is a `DynamicProperty` and only works inside a `View`, so the model reads `UserDefaults`
directly — which is also what makes it testable: inject a throwaway suite.

Keys are `panel.<id>.collapsed` and `panel.<id>.size`. `showsLibrary` migrates on first read, using
`object(forKey:)` rather than `bool(forKey:)` — the latter cannot tell missing from false.

`setSize` clamps into `[minSize, upperBound]`, where `upperBound` is whatever leaves `centreMinimum` for
the middle after every other column's rendered width and its divider. The available width arrives through
`onGeometryChange` on the outer `HStack`; `windowWidthChanged` stores it and re-clamps every column, so
shrinking the window pulls the panels in rather than squeezing the timeline out. Widths round to whole
points.

`ContentView` takes a *dynamic* minimum width from the model instead of the current fixed `1100`, so
collapsing panels actually lets the window get smaller — which is the behaviour you want and the thing
`HSplitView` cannot give you.

### Divider drag

The gesture uses the **global** coordinate space and a base size captured on first change, never
incremental deltas. The divider moves as the panel resizes, so a `.local` gesture recomputes its
translation against a moving frame and runs away. All the arithmetic lives in `setSize`; the view holds
none.

### Keyboard

Every panel toggle is `⌥⌘`-modified: Assistant `⌥⌘A`, Library `⌥⌘L`, Inspector `⌥⌘I`, Activity `⌥⌘J`.
`Views.swift` already records why the tool picker carries no key equivalent — SwiftUI installs those as
key equivalents, which AppKit dispatches before `keyDown` reaches the first responder, so a bare letter
would fire while the composer has focus. That hazard is specific to *bare* keys colliding with
`TimelineMetalView.keyDown`; a `⌥⌘` combination cannot be produced by typing, which is why the existing
`⌥⌘L` is already allowed. The rule for the future: a panel toggle is always `[.command, .option]`, never
a bare key and never a plain `⌘`-letter, which belongs to a menu.

The toolbar hosts them in a `ControlGroup`, not a `Menu`: a menu's content is not instantiated until it
opens, so its shortcuts may never install.

## 4. Agent → Assistant

The pane is renamed in the window. The boundary is `Contracts.AgentRuntime`: above it the name is
Assistant, at and below it the name is Agent. That is a rule a reviewer can grep rather than argue symbol
by symbol, and it keeps `AgentKit`, `FakeAgentRuntime`, `ToolLoopRuntime`, `AppServices.agentRuntime` /
`AgentMode`, the on-disk `<root>/Agent/` sidecar directory (renaming it is a data migration) and
`SkeletonCheck`'s `"agent"` step label — which `integration.md` quotes — exactly as they are.

The half-measure of renaming only the strings is worse than either extreme: a file called
`AgentPanelView.swift` rendering a pane labelled "Assistant" makes every future reader re-derive which
"Agent" is which. This is one package with no external consumers, so `public` is not a compatibility
surface and the compiler will list every call site.

One string cannot be fixed by renaming anything. `Actor.description` is `"agent:<sessionId>"` and is
printed on every history row and every approval card. It is the JSON wire format, `Actor.init(_:)` parses
the prefix back, and `TimelineCore` is frozen. So `ActorLabel` in `TimelineUI` is what the window shows
("You", "Assistant", "System", with the session id demoted to a `.help`), and a test asserts both halves
so nobody later unifies them.

## 5. Ordered steps

Each of these builds and passes `make format && make lint && make test`.

1. This plan.
2. `PanelTheme` + `StyleTests` — pure addition.
3. `PanelLayout` + `PanelLayoutTests` — pure addition.
4. `PanelChrome` and friends + smoke tests — still unused by the app.
5. The assistant's user-visible strings and doc comments.
6. The `TimelineUI` type rename (with `Views.swift`, `Consoles.swift` and `PanelTests.swift` in the same
   commit — the API is cross-module and cannot be split without breaking the build).
7. `AssistantConsole`, `AssistantSection`, `AppModel.assistant`.
8. `ActorLabel` + its test.
9. Lay the editor out with the panel model instead of `HSplitView` — **same three columns, no new
   chrome**. This is the only step that can regress the window, and keeping it visually inert makes it
   easy to judge.
10. Panel headers for the library and the inspector.
11. Split the sidebar into an Inspector panel and an Activity panel.
12. Move the Assistant to its own leading column.
13. Toolbar `ControlGroup`, the three new shortcuts, the window sizes.
14. Token adoption, one panel per commit, in ascending risk.
15. Docs.

## 6. Test plan

There is no app test target and no XCUITest, and `swift-snapshot-testing` is declared but unused — so the
layout arithmetic all lives in `TimelineUI`, where it can be tested, and nothing tries to assert on
rendering.

`Tests/TimelineUITests/PanelLayoutTests.swift`, over a throwaway `UserDefaults(suiteName:)` and never
`.standard`: the defaults; a persistence round-trip through a second model; clamping to min and to max;
clamping against the window, so a pane cannot eat it; shrinking the window re-clamping every column;
`.rightColumn`'s container semantics; the flexibility handoff to the inspector when the activity panel
collapses; `renderedWidth` being exactly `railWidth` when collapsed; `minimumWindowWidth` falling by
`minSize - railWidth` per collapsed panel; and the `showsLibrary` migration, including that the new key
wins when both are present.

`StyleTests.swift` asserts the token values — the same contract `TimelineTheme` already carries — and the
two crossings between the two themes.

Two `ImageRenderer` smoke checks in the existing `PanelTests.swift` idiom, for `PanelChrome` and a merged
`PanelRail`.

## 7. Verification by hand

`swift run TimelineApp`: four columns in order; drag each seam and watch the centre absorb the slack;
collapse each panel and confirm the rail — or, for the stacked pair, the bare header — appears and
reopens; quit and relaunch and confirm the sizes and flags came back; collapse everything and confirm the
window can now shrink; drag a library row onto the Assistant column and confirm it still *stages* as an
attachment rather than importing; confirm the timeline still zooms, pans and redraws during a drag, and
that typing `c` in the composer does not arm the razor.

`make e2e` still passes but is not coverage for any of this: `SkeletonCheck` touches no SwiftUI. It does
read `TimelineTheme`, so it would notice the two palettes being merged.

## 8. Risks

- **Timeline redraw during a drag.** `TimelineMetalView.layout()` writes `viewModel.viewSize` on every
  bounds change, so dragging a left divider re-renders the timeline per frame. A window resize already
  does exactly this, so it should be fine — but it is the first thing to look at if a drag feels heavy.
  Rounding widths to whole points is cheap and worth doing regardless.
- **`onGeometryChange` feedback.** `windowWidthChanged` mutates observed state from a geometry callback.
  Clamping is idempotent so it converges after one pass; guard on `width != stored` anyway.
- **A dynamic root `minWidth` reaching `NSWindow.contentMinSize`.** Verify by hand that collapsing lets
  the window shrink; if SwiftUI does not propagate a changing root minimum, fall back to a static
  minimum computed with every panel open and record that here.
- **`ControlGroup` + `ForEach` + `.keyboardShortcut`.** If the shortcuts do not register, unroll to four
  literal buttons.
- **`AssistantDropHost`** wraps the panel in an `NSHostingView`. Inside a fixed-width column its content
  needs to fill, or the column will look empty. Check it first when the Assistant moves.
- **Rotated rail titles** report their unrotated bounds, so the run length is reserved by hand. A title
  longer than "Assistant" truncates rather than overlapping.

## 9. What the implementation did differently

**The tokens are one file, not two.** The plan floated splitting the panel *metrics* out of the theme so
the layout model could read `railWidth` without depending on the chrome. It turned out there was nothing
to decouple: `PanelTheme` holds no views, so `PanelLayoutModel` imports it freely. One file, three
consumers.

**`PanelID.activity` stores no size.** It is always the flexible panel while it is open, so there is
nothing to clamp or remember. Without a `storesSize` flag the re-clamp pass wrote a meaningless height
into `panel.activity.size` every time anything moved.

**The available height is a second geometry reading, not a derived one.** The plan had one
`onGeometryChange` on the outer row. The stacked panels need their own, because the right column's height
is the window's minus nothing the row knows about. So `PanelLayoutModel` takes `availableWidthChanged`
and `availableHeightChanged` separately, and `upperBound` switches on the panel's axis.

**The container swap shipped without the sidebar's split.** Step 9 was meant to be visually inert, and
converting the sidebar's `VSplitView` in the same commit would have meant pointing the new divider at
`.inspector` while the panel underneath it was still the assistant — a persisted number that would mean
something different one commit later. The vertical split waited until it was two real panels.

**`AssistantStatusBar` kept its name and its `public init`.** It lost its `Label("Agent")`, its padding
and its `.background(.bar)` — those are `PanelHeader`'s now — and it lost its internal `Spacer`, because
the header already has one and two greedy spacers split the slack instead of pushing the controls to the
trailing edge. Keeping the type meant `PanelTests` kept compiling through the whole rename.

**`Actor.description` was the string nobody had listed.** It renders "agent:<uuid>" on every history row
and approval card, it is the JSON wire format, and `TimelineCore` is frozen — so `ActorLabel` in
`TimelineUI` is what the window shows, and a test asserts both halves so the two cannot be "helpfully"
unified later.

**One rename regex over-reached twice**, both caught by the compiler and a diff read: `\bagent\b` in
`SkeletonCheck` hit the `AppServices.boot(agent:)` argument label and the `"agent"` step labels that
`integration.md` quotes verbatim, and in `Views.swift` it turned "which agent runtime the window got"
into "assistant runtime" — which is wrong, because it *is* the `AgentRuntime`. Renaming by type name is
safe; renaming a bare English word across a file is not.

**Not done, and deliberately:** the optional divider between the preview and the timeline (step 9 of §5)
was left out. It is free to add now — a `PanelID` case and one `PanelDivider` — but it is a different
panel from the four this plan is about, and nobody asked for it yet.

**The overflow the first pass shipped, and what caused it.** The assistant panel drew wider than its
column: the empty state's sentence was clipped on both edges and the composer's plate ran past the panel.
Three separate things were reporting an ideal width and none of them could honour a 280pt column.

1. `AssistantDropTargetView.intrinsicContentSize` forwarded its `NSHostingView`'s, and the hosting view
   installs its own min/ideal/max constraints by default. So the representable told SwiftUI the panel
   wanted to be as wide as its widest content. Fixed by `sizingOptions = []`, dropping the
   `intrinsicContentSize` override, and a `sizeThatFits` that returns the proposal — the panel's width
   comes from `PanelLayoutModel` and nothing below it gets a vote.
2. `ContentUnavailableView` has an ideal width and a floor it will not go under, so its description came
   out clipped rather than wrapped. Replaced by `PanelEmptyState`, whose message is
   `.fixedSize(horizontal: false, vertical: true)`.
3. The composer's placeholder was a whole sentence. It is "Message the assistant" in both states now;
   the hint about dropping clips is in the empty state, which has room to wrap it.

**`barInsetH` is gone.** A header's symbol was 10pt from the edge and the content under it 8, which read
as two different gutters because it *was* two different gutters. Bars now use `panelInset` horizontally
and keep `barInsetV` for the vertical, so there is exactly one horizontal gutter in the window.

**The inspector's form moved from `.grouped` to `.columns`** inside a `ScrollView`. Grouped is the System
Settings look and its inset cards sat much further from the edge than any other panel's content — the
single biggest reason the library and the inspector looked unrelated. `.columns` does not scroll itself,
which grouped did, hence the `ScrollView`.

**Verification is a window capture, not `ImageRenderer`.** `ImageRenderer` draws a placeholder glyph for
every AppKit-backed control — `List`, `TextField`, `Picker`, `Button`, and any `NSViewRepresentable` —
so it can smoke-test that a view builds but cannot show what a panel looks like. What works:
`CGWindowListCopyWindowInfo` to find the running app's window id, then
`screencapture -x -o -l<id>`, which captures that window alone. Collapsed states can be staged ahead of
launch with `defaults write TimelineApp panel.<id>.collapsed -bool true`.

**The library panel's second pass.** Three things, all visible the moment it had real rows in it:

- **The first row was clipped along its top edge.** A `List` sitting flush under other content in a
  `VStack` cuts its first row; `.contentMargins(.top, rowGap, for: .scrollContent)` is the fix.
- **Two stacked full-width segmented controls read as two loud accent blocks** in a 280pt column. Scope
  is a view option, so it moved into the panel header as a filter menu (filled when it is not the
  default), and the kind filter became one compact symbols-only segmented control sized to its content
  and pinned to the gutter. Two rows of filters instead of three, one accent block instead of two.
- **Every row named its project.** `foreignProjectName` returned the name whenever `item.projectId` was
  set, and `openProjectItems` sets it to the open project — so all six rows ended in "· Untitled". The
  existing tests covered foreign and library-only media but never the open project's own, which is how
  it survived. `Row` now carries `openProjectId`, and the test does too.

**Three more the second pass turned up, all in the library's rows:**

- **A symbols-only segmented control needs a tooltip per segment, and SwiftUI cannot give it one.**
  `.help` on a `Picker(.segmented)` item is dropped. AppKit has `setToolTip(_:forSegment:)`, so
  `SymbolSegmentedPicker` is the thin `NSViewRepresentable` that reaches it.
- **Stills had no thumbnail.** `AVThumbnailProvider` builds sprite sheets with
  `AVAssetImageGenerator`, and a PNG has no video track, so every image drew a placeholder symbol —
  the wrong one, too, since the fallback picked `film` for anything that was not audio. The provider
  now decodes a still with `CGImageSource` and skips the sheet path entirely.
- **A thumbnail fetch that came back empty was retried on every redraw**, forever, for as long as the
  row was on screen: `LibraryThumbnailCache` stored images and in-flight tasks but had nowhere to put
  "there is nothing here". It remembers failures now, and `clear()` forgets them so a rescan retries.

**Every thumbnail was drawn at a fraction of its resolution, for two compounding reasons.** The first
was points-versus-pixels (below). The second, and much the larger, was that `.fill` scales a picture
until it covers *both* sides of its box — so for a portrait clip the binding side is the width, not the
height. A 9:16 frame asked for at a 64x36 box's height comes back **20x36** and is then magnified 3.2x.
That is why the rows stayed soft on a 1x display too, where the points/pixels bug does not exist at all.
`PosterGeometry.pixelHeight(box:aspect:displayScale:)` now asks for `box.width / aspect`, from
`Asset.displayAspectRatio` (rotation-aware — `AVAssetImageGenerator` upends the frame for us).

**And it was drawn at half resolution on top of that.** A poster was asked for at its *point* height — 36 —
and drawn into a 36 pt box, which is 72 px on a Retina screen. So the picture was stretched to twice its
size, in the library rows and the composer's attachment chips alike. The height now comes from
`@Environment(\.displayScale)`, which also picks a 128 px tile off `AVThumbnailProvider`'s ladder
instead of a 64 px one. Worth knowing: this machine's main display is a 1x ultrawide and the built-in is
2x, so the bug is invisible on the ultrawide and obvious on the laptop screen.

**Still to check by hand** (§7): every item there is real. `SkeletonCheck` touches no SwiftUI, so nothing
automated has drawn the four-column window; the layout arithmetic is covered by `PanelLayoutTests` and
the chrome only by `ImageRenderer` smoke checks.
