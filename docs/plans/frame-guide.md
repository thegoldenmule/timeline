# The frame guide

Status: implemented, 2026-09-14. Companion to `docs/plans/sequence-format.md`, which made the frame editable
and reportable but left it invisible. Nothing in `TimelineCore`, `Contracts`, `RenderKit`, or the render
path changes: this is one overlay, one toggle, and the arithmetic `ExportFraming` already does.

## 0. Context

`PreviewLayerView` (`Sources/TimelineApp/Views.swift:1143`) hosts RenderKit's `AVPlayerLayer`s on an
`NSView` whose backing layer is painted `NSColor.black`, with `videoGravity = .resizeAspect`. It is
placed in `centreColumn` (`Views.swift:685`) with a `minHeight` and no shape of its own, so the picture
is aspect-fitted into whatever rectangle the panels leave it and **the black around it is the panel's
own background**.

That is pixel-identical to black baked into the frame. The user's complaint is exactly this: with a
correct 2160x3840 portrait project full of correct portrait clips, the preview looks the same as a
landscape project full of pillarboxed portrait clips — which is the state `sequence-format.md` was
written to fix and which the status bar can now describe in words (`2160x3840 · 9:16 — footage fills the
frame`) but nothing on the picture can show.

The fit the preview performs is not a guess. The preview's composition is built at the sequence's own
size — `AVFoundationRenderer.compile` sets `renderSize = CGSize(width: sequence.width, height:
sequence.height)` (`Sources/RenderKit/AVFoundationRenderer.swift:55`) — so `resizeAspect` fits *that*
frame into the layer's bounds, `min(bounds/frame)`, centred. That is `ExportFraming`'s arithmetic with
the viewport as `output` and the frame as `sequence`, which is why this plan reuses it rather than
writing the fit a third time.

The compositor aspect-fits **twice** and never crops: source into the frame
(`Sources/RenderKit/Compositor.swift:222-251`), then frame into the output (`:208-219`). Stage one is
the one the user was originally burnt by, it is already measured per clip by `FormatMismatch`
(`Sources/TimelineUI/SequenceFormatView.swift`), and the preview is where it is happening in front of
them — so the guide draws it too.

## 1. Decisions

1. **The guide is drawn over the preview, fitted the same way the picture is.** One `ExportFraming` over
   `(output: the viewport in points, sequence: the frame in pixels)` gives the scale and the rect, so the
   stroke lands on the edge of the video by construction rather than by a second, hand-rolled fit that
   could drift from `resizeAspect`. Rounding the origin is `ExportFraming`'s, and a whole-point origin is
   what a crisp hairline wants anyway.

2. **The frame reads as a frame in three ways at once, because one is not enough.**
   - A **stroke** on the frame's edge (`Rectangle().strokeBorder`, square corners — a rounded guide would
     misstate where the picture ends).
   - A **scrim** over everything outside it: the surround is washed, so it stops being black and starts
     being chrome. This is the part that actually answers the complaint — black-that-is-the-panel now
     looks different from black-that-is-in-the-frame.
   - A **label** at the frame's top-leading corner, inside it: `2160 × 3840 · 9:16`. The shape is stated
     as well as drawn, in the spelling `ExportFraming.pixels`/`aspectLabel` already use.

3. **The guide also draws the *other* fit, when the footage does not fill the frame.** A dashed warning
   rectangle where the footage actually lands inside the frame, and a second label line — `656 px
   pillarboxed` — from `FormatMismatch.worst`. This is the plan's real payoff: the bars that used to be
   discovered at export time are now on the picture at edit time, drawn on the same overlay as the frame
   that is causing them. The measurement is `FormatMismatch`'s, unchanged; the guide only positions it.

4. **The toggle is a button on the preview, top-trailing, and it defaults on.** The preview is what it
   is about, so it lives on the preview: a viewfinder control in the corner, the way every NLE puts its
   overlay controls on the viewer. It is not in the toolbar (which is document-level: New, Open, Fork,
   Rename, Import, Format, Export), not in the status bar (whose format line belongs to the format work
   and is not this plan's to touch), and not in a menu (there is no menu bar). It stays visible when the
   guide is off, which is the only way to get the guide back.

   **No keyboard shortcut.** `ui-style.md` reserves `⌥⌘` for panel toggles, bare keys belong to
   `TimelineMetalView.keyDown`, and a plain `⌘`-letter belongs to a menu bar this app does not have. If
   a menu bar is ever added, this is a View-menu item and the button stays.

5. **The flag is persisted the way panel state is, in a sibling model rather than inside
   `PanelLayoutModel`.** `PreviewGuideModel` reads and writes `UserDefaults` itself, takes the suite by
   injection so tests get a throwaway one, and reads with `object(forKey:)` so a missing key is told
   apart from a stored `false` — the `PanelLayoutModel` pattern, key for key. It is not *in*
   `PanelLayoutModel` because the preview is not a panel: `PanelID` is a closed enum of panels with
   sizes, rails, minimum widths, and `⌥⌘` shortcuts, and a preview overlay flag has none of those. The
   key is `preview.frameGuide`, beside `panel.<id>.collapsed` in the same domain.

6. **The guide never eats a click.** The overlay is `allowsHitTesting(false)`; only the toggle button
   takes the pointer. The preview has no click handling today and this plan does not give it any.

7. **The geometry is a value type in `TimelineUI`, tested there; the view is a thin rendering of it.**
   The house pattern (`ui-style.md`, `PanelLayoutModel`, `ExportFraming`, `FormatMismatch`) is that the
   arithmetic is a `Hashable, Sendable` struct a test can hold, and the `View` only draws it.

## 2. What is added

### `Sources/TimelineUI/FrameGuideView.swift` (new)

```swift
/// Where the frame lands in the preview, and where the footage lands inside it.
public struct FrameGuide: Hashable, Sendable {
    public let viewport: CGSize          // the preview's bounds, in points
    public let frameSize: FrameSize      // the frame, in pixels
    public let media: ExportFraming?     // the worst-fitting clip's fit into the frame, when it misses

    public init(viewport: CGSize, frameSize: FrameSize, media: ExportFraming? = nil)
    public init(viewport: CGSize, mismatch: FormatMismatch)

    public var isVisible: Bool           // a viewport and a frame with area in them
    public var scale: CGFloat            // points per frame pixel: `resizeAspect`'s own min()
    public var rect: CGRect              // the guide, in viewport points
    public var mediaRect: CGRect?        // where the footage lands, in viewport points
    public var fillsViewport: Bool       // no surround to scrim: the shapes agree
    public var label: String             // "2160 × 3840 · 9:16"
    public var mediaLabel: String?       // "656 px pillarboxed"
}

/// Whether the preview draws its frame guide. Persisted like a panel's collapsed flag.
@MainActor @Observable public final class PreviewGuideModel {
    public init(defaults: UserDefaults = .standard)
    public private(set) var showsFrameGuide: Bool   // defaults to true
    public func setShowsFrameGuide(_ value: Bool)
    public func toggleFrameGuide()
}

public enum FrameGuideText { ... }        // the copy and the compact bars badge
public struct FrameGuideOverlay: View     // scrim, media rect, stroke, label
public struct FrameGuideToggle: View      // the viewfinder button
```

`mediaLabel` is the compact form of what the export sheet says at length: `ExportText.letterboxBadge` /
`pillarboxBadge` with the pixel count, so the overlay says `656 px pillarboxed` where the sheet says
`Pillarboxed: 656 px of black to the left and right`. Same words, same number, no new vocabulary.

### `Sources/TimelineUI/PanelTheme.swift`

Three tokens, and `ui-style.md` and `StyleTests` record them:

| Token | Value | Why |
|---|---|---|
| `frameGuideStroke` | `Color.white.opacity(0.85)` | the frame's edge, drawn over picture |
| `frameGuideWidth` | 1.5 | thick enough to read over a busy frame, thin enough not to hide a pixel row |
| `frameGuideSurround` | `Color.white.opacity(0.1)` | the wash outside the frame that stops the panel's black reading as picture |

These are fixed hues rather than semantic ones, for `letterboxFill`'s reason: the preview is a fixed
black surface in both appearances, so the guide over it is fixed too.

### `Sources/TimelineApp/Views.swift`

Confined to `EditorView`: one `@State private var guides = PreviewGuideModel()`, and an `.overlay` on
`PreviewLayerView` inside `centreColumn` holding `FrameGuideOverlay` (when the flag is on and there is a
document to ask) over `FrameGuideToggle` at `topTrailing`. The mismatch comes from
`AppModel.currentMismatch`, which already exists and is already what the status bar and the export sheet
read. `PreviewLayerView` itself does not change.

## 3. Tests

`Tests/TimelineUITests/FrameGuideTests.swift`:

- a portrait frame in a landscape viewport: full height, centred, the width the fit gives, `!fillsViewport`;
- a landscape frame in a portrait viewport: the mirror of it;
- a frame whose shape matches the viewport: `fillsViewport`, the rect is the viewport;
- the guide's scale is `resizeAspect`'s `min`, and the rect never leaves the viewport;
- a degenerate viewport, and a degenerate frame: `!isVisible`, nothing drawn;
- the label for both orientations, including the `9:16` and `16:9` reductions;
- the mismatch case: a 1080x1920 clip in a 1920x1080 frame puts `mediaRect` inside `rect`, pillarboxed by
  the width `FormatMismatch` measures, scaled into points by the same factor as the frame;
- the clean case: `mediaRect` is nil and `mediaLabel` is nil;
- `PreviewGuideModel`: on by default, a stored `false` survives a new model over the same suite, `toggle`
  writes through, and an empty suite is told apart from a stored `false`.

`StyleTests` gains the three tokens.

## 4. The skeleton check

No new step. `make e2e` stays at 19 steps: the guide is a rendering of `FormatMismatch`, whose behaviour
the `format` step already proves end to end against real files, and the check has no window to draw into.

## 5. What landed

All of it, in one pass: `FrameGuideView.swift` (the geometry, the flag, the overlay, the button), three
`PanelTheme` tokens, the `.overlay` in `centreColumn`, `FrameGuideTests` (14) and one `StyleTests` case.
`make e2e` is still 19 steps and no test target moved except `TimelineUITests`, 225 → 240.

Three notes for whoever reads this next:

- The switch is `rectangle.dashed` when the guide is on and `rectangle.slash` when it is off, rather than
  one symbol in two colours. With the guide off there is nothing else on the picture to read the state
  from, so the icon has to carry it.
- The label sits inside the frame's top-leading corner and overflows into the surround on a frame
  narrower than the label. That is the right way round: it is anchored to the frame it names, and the
  surround is the part of the panel with nothing in it.
- Rendered through `ImageRenderer` while building, which is how the wash was settled at 0.1: enough that
  a portrait frame in a landscape panel is unmistakably a portrait frame, little enough that it is not
  competing with the picture.

## 6. Left out

- Safe-area and title-safe guides, a rule-of-thirds grid, and a centre cross. The same overlay is where
  they would go and `FrameGuide.rect` is what they would be drawn against, but each one is its own
  decision about what an editor here needs.
- Any change to the format control: the toolbar's Format button, the format sheet, the status bar's
  format line, and the word "sequence" in user-facing copy are all the next agent's. **Done, 2026-09-14,
  `docs/plans/frame-at-edit-time.md`:** the toolbar button is gone, the frame is now picked from
  `FrameMenu` beside this plan's own switch in `previewOverlay`, and nothing a user reads says
  "sequence". This overlay, its tokens, and its tests are untouched.
- Zoom or pan of the preview, and any click handling on it.
- Drawing the guide over the export sheet's thumbnail. `ExportFramingView` already draws both fits in its
  own schematic.
