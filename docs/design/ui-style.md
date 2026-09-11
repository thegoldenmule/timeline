# UI style

Status: normative from 2026-09-11. Companion to `conventions.md`. Covers every SwiftUI view in
`TimelineUI` and `TimelineApp`. It does not cover the Metal timeline, whose palette and metrics are
`TimelineTheme` and `TimelineLayout`.

## The rule

SwiftUI chrome reads its numbers and its fonts from `PanelTheme` (`Sources/TimelineUI/PanelTheme.swift`)
and builds its headers from `PanelChrome` (`Sources/TimelineUI/PanelChrome.swift`). A literal padding,
corner radius, panel width, or `.font(.caption)` in a panel is a review comment. This is
`conventions.md`'s "no magic numbers for tunables" applied to the window.

The exceptions: `Spacer(minLength:)`, `lineLimit`, `scaleEffect`, a frame whose size is already a token,
and anything inside `TimelineMetalView`, `TimelineSceneBuilder`, or `TimelineRenderer`.

`PanelTheme` is `public` and lives in `TimelineUI` because that is the only leaf library both the panels
and the composition root can see (`conventions.md`, package layout). `TimelineApp` imports it like any
other view.

## Two themes, deliberately

| | `TimelineTheme` + `TimelineLayout` | `PanelTheme` + `PanelChrome` |
|---|---|---|
| Medium | Metal; `SceneColor` floats written unmanaged to BGRA8 | SwiftUI; `Color`, `Material`, `Font` |
| Appearance | a fixed dark instrument surface, never follows the system | follows the system appearance and accent |
| Consumers | `TimelineSceneBuilder`, `TimelineRenderer`, `SkeletonCheck` | every panel, bar, sheet, and settings page |
| Tests | assert on the values | assert on the values |

They are not merged, and will not be. `TimelineSceneBuilder` is a pure value type with no view and no
`NSAppearance`, so it cannot resolve a dynamic colour; and the timeline's contrast is tuned against a
fixed `background = 0.11`, which a light appearance would destroy. One palette would have to sacrifice
one side or the other.

They must agree in exactly two places, and `StyleTests` asserts both so they cannot drift:

| Token | Equals | Why |
|---|---|---|
| `PanelTheme.posterRadius` (3) | `TimelineTheme.controlCornerRadius` | the same small plate is drawn by Metal on a track header and by SwiftUI in a chip |
| `PanelTheme.barHeight` (28) | `TimelineLayout.rulerHeight` | a panel header lines up with the ruler across a split |

`PanelTheme.color(_:)` converts a `SceneColor` for chrome that labels something the timeline drew — a
track-kind swatch, a link-group dot. It converts as sRGB, because that is what the unmanaged BGRA8 write
actually shows. It is one-way; nothing converts back.

## Panel anatomy

Every panel in the window is the same three parts.

| Part | What it is | Metrics |
|---|---|---|
| **Header** | One row: the symbol that collapses the panel, its name, `Spacer`, then the panel's own controls. Never wraps, never scrolls, always present. `PanelHeader`. | height `barHeight` 28, horizontal `panelInset` 8, vertical `barInsetV` 5, `barMaterial`, a `Divider` beneath |
| **Body** | The content, scrolling if it must, filling the panel. | `panelInset` 8, `sectionGap` 8 between siblings |
| **Rail** | What a collapsed column shows instead: the symbol over the rotated name, clickable. `PanelRail`. | width `railWidth` 32, title run `railTitleRun` 84 |
| **Empty state** | What a panel with nothing in it shows: symbol, title, and a sentence that wraps. `PanelEmptyState`. | `pageInset` 16, centred, fills the body |

**One gutter.** A header's symbol, a body's content, and a status bar's first item all start
`panelInset` 8 from the panel's leading edge. There is no separate header inset — that is the whole
reason `barInsetH` does not exist. A `List` or a `Form` that draws its own row insets is the exception
and sits edge to edge; everything around it still uses the gutter, so the library's search field lines
up with its header's symbol and the rows below indent themselves.

**Nothing may set its own ideal width.** A panel's width comes from `PanelLayoutModel`, and content that
reports a larger ideal is clipped on both edges rather than wrapped. Two things in the tree did:
`ContentUnavailableView` (hence `PanelEmptyState`, whose message is
`.fixedSize(horizontal: false, vertical: true)` so it takes the width it is offered and only the height
it needs), and `AssistantDropHost`'s `NSHostingView` (hence `sizingOptions = []` and a `sizeThatFits`
that returns the proposal). A long `TextField` placeholder does the same, so placeholders are short.

The header is the only bold row in a panel and the only place a panel names itself; a body never repeats
the name. `PanelChrome` picks between the three, so no caller writes a frame.

A panel **stacked inside a column** — the inspector, the activity panel — collapses to its own header bar
rather than a rail: a rotated title inside a full-width 28pt strip would be nonsense. When both stacked
panels are shut, the column renders one merged rail for the pair.

The seam between two panels is a `PanelDivider`: a hairline in a `dividerThickness` 8 hit area, with a
column- or row-resize pointer. It reports drag translation in the **global** coordinate space against a
base captured when the drag starts — a local gesture would recompute against a frame the drag itself is
moving, and run away. Every bound lives in `PanelLayoutModel.setSize`.

## Panel sizes

`PanelID` carries them, and `PanelLayoutModel` clamps against the window so no panel can squeeze the
timeline out. Widths and collapsed flags persist under `panel.<id>.size` and `panel.<id>.collapsed`.

| Panel | default | min | max |
|---|---|---|---|
| Assistant | 340 | 280 | 620 |
| Library | 280 | 220 | 480 |
| the right column | 400 | 320 | 700 |
| Inspector (height) | 260 | 140 | flexible |
| Activity (height) | — | 160 | takes the remainder |

`centreMinimum` 480 is what the preview-and-timeline column is never squeezed below. The window's own
minimum follows the panels (`PanelLayoutModel.minimumWindowWidth`), so collapsing one lets the window get
narrower rather than just freeing space inside it.

## Keyboard

A panel toggle is always `[.command, .option]`: Assistant `⌥⌘A`, Library `⌥⌘L`, Inspector `⌥⌘I`,
Activity `⌥⌘J`. Never a bare key and never a plain `⌘`-letter, which belongs to a menu.

The reason is specific. SwiftUI installs `.keyboardShortcut` as an AppKit key equivalent, which is
dispatched before `keyDown` reaches the first responder — so a bare letter would fire while the
assistant composer has focus, and every timeline key (`b`, `n`, `c`, `v`, `m`, `s`, `+`, `-`) lives in
`TimelineMetalView.keyDown` for exactly that reason. A `⌥⌘` combination cannot be produced by typing.

The toolbar hosts the toggles in a `ControlGroup`, not a `Menu`: a menu's content is not built until it
opens, so its key equivalents may never be installed.

## Spacing

| Token | pt | Use |
|---|---|---|
| `hairGap` | 2 | a disclosure body under its label; a scroll view clear of its indicator. Nothing smaller exists |
| `rowGap` | 4 | between the lines inside one row, card, or chip |
| `controlGap` | 6 | between controls in a strip; between a symbol and its label |
| `sectionGap` | 8 | between sibling sections in a panel body |
| `panelInset` | 8 | from a panel's edge to its content |
| `cardInset` | 12 | inside a card that floats on its own background |
| `pageInset` | 16 | inside a settings page or a sheet |
| `barInsetV` | 5 | a header's or status bar's vertical padding; horizontally a bar uses `panelInset` |

If a layout seems to want a number that is not here, it wants a different token.

## Corner radii

| Token | pt | Use |
|---|---|---|
| `posterRadius` | 3 | posters, thumbnails, small plates |
| `chipRadius` | 6 | attachment chips, token-sized controls |
| `bubbleRadius` | 8 | message bubbles, the composer field, the drag overlay |
| `cardRadius` | 10 | a card floating over a panel |

## Type roles

Roles, not sizes. A view names the role; only `PanelTheme` names the font.

| Role | Resolves to | Use |
|---|---|---|
| `panelTitle` | `.caption.weight(.semibold)` | a panel header's name |
| `sectionTitle` | `.headline` | a named group inside a body. `Form`'s `Section` headers stay SwiftUI's |
| `rowTitle` | `.subheadline` | a list row's first line |
| `bodyText` | `.body` | prose read at length: a transcript message, an approval summary |
| `caption` | `.caption` | hints, empty states, one-line errors |
| `detail` | `.caption2` | badges, counts, "running", a cost |
| `mono` | `.system(.caption, design: .monospaced)` | a tool name, a path, a shell command |
| `monoSmall` | `.system(.caption2, design: .monospaced)` | a JSON blob or a transcript dump |
| `monoDigit` | `.caption2.monospacedDigit()` | a number that must not jitter as it counts |

## Colour and material

Semantic only. A view never names a hue.

| Token | Use |
|---|---|
| `barMaterial` (`.bar`) | headers and status bars |
| `cardMaterial` (`.regularMaterial`) | a card floating over a panel |
| `fieldFill` | a text field or composer plate |
| `bubbleFill` / `ownBubbleFill` | what the assistant said / what the human said |
| `chipFill`, `posterFill` | a chip; the placeholder behind a poster that has not landed |
| `borderIdle` + `borderWidth` | a resting border |
| `borderActive` + `borderWidthActive` | a border that is saying something: a drop is over this target |
| `warning` | attention, nothing failed: a missing file, an unaudited client |
| `danger` | something failed |
| `.secondary` / `.tertiary` | supporting and incidental text — use the hierarchy, not an opacity |

The accent colour fills exactly one thing, `ownBubbleFill`, and strokes exactly one, `borderActive`.

## Assistant, and Agent

The panel is the **Assistant**. The protocol it runs on is still `AgentRuntime`, its module is still
`AgentKit`, and the sidecar's working directory is still `<root>/Agent/`. The boundary is
`Contracts.AgentRuntime`: above it the name is Assistant, at and below it the name is Agent. That is a
rule a reviewer can grep rather than argue symbol by symbol.

`TimelineCore.Actor.agent` stays too — `Actor.description` is the wire format (`"agent:<sessionId>"`) and
`Actor.init(_:)` parses that prefix back. `ActorLabel` is what the window shows.

## Pictures

A thumbnail is asked for through `PosterGeometry.pixelHeight(box:aspect:displayScale:)`, never by the
box's height. Two things go wrong otherwise, and they compound:

- **Points are not pixels.** A 36 pt poster row is 72 px of screen on a Retina Mac, so a picture fetched
  at 36 px is stretched to twice its size. The height comes from `@Environment(\.displayScale)`, and the
  same scale goes to `Image(decorative:scale:)`.
- **`.fill` magnifies whatever does not already cover the box.** It scales a picture until it covers
  *both* sides, so for anything narrower than the box the binding side is the **width**. A 9:16 phone
  clip scaled to a 64x36 box's height is 20 pt wide — under a third of the box — and gets blown up more
  than three times. `PosterGeometry` asks for `box.width / aspect` instead, using
  `Asset.displayAspectRatio` (which accounts for `probe.rotation`, since the generator upends the frame
  for us) and falling back to 9:16 when the shape is unknown.

A poster goes through `ThumbnailProvider.thumbnail(for:at:height:)`, which is one seek and one small
cached JPEG. It is not `filmstrip(count: 1)`: a zero-length range carries no frame rate to infer, so
the ladder returns its densest rung and the sheet path renders every tile of it — about a thousand
frame extractions to draw one row.

## Filter controls

A filter that changes *what is listed* belongs in the panel body. A filter that changes *where the panel
looks* is a view option and belongs in the header's controls slot, as a menu. Segmented controls are
sized to their content and pinned to the gutter, not stretched across the panel: a stretched one gives
its segments room they do not need, and a centred one reads as having been dropped there. Two stacked
full-width segmented controls in one panel is the thing this rule exists to prevent.

## The inspector's form

`InspectorView` uses `.formStyle(.columns)` inside a `ScrollView`, not `.formStyle(.grouped)`. Grouped is
the System Settings look: its inset cards sit a good deal further from the edge than every other panel's
content, which is exactly the mismatch this document exists to prevent. Grouped also scrolls itself,
which `.columns` does not — hence the `ScrollView`.

## Adoption

`PanelTheme` and `PanelChrome` landed as pure additions, and the rule above applies to new and edited
chrome from that commit. Existing panels convert one commit per panel; the panels still on literals at
any moment are the ones nobody has touched since.
