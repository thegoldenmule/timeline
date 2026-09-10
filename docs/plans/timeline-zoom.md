# Timeline zoom: pinch, scroll, and a playhead that stays put

Status: plan, 2026-09-10. Companion to `docs/design/conventions.md` and `docs/plans/cut-tool.md`.
Nothing here reaches `TimelineCore`, `ProjectStore`, `RenderKit`, or the event log: zoom is a view
transform on the timeline and only the timeline.

## 0. Context

Zoom today is six discrete rungs. `ZoomLevel.secondsPerPoint` (`Sources/TimelineUI/TimelineLayout.swift:8`)
is `[4.0, 1.0, 0.25, 0.05, 0.01, 0.002]`, `TimelineViewModel.zoomIndex` (`:88`) indexes into it clamped,
and `setZoom(index:anchorX:)` (`:200`) swaps the rung while keeping the time under `anchorX` where it is.
The keys `+`/`-` step it (`TimelineGestureController.swift:236`), Command+wheel steps it
(`TimelineMetalView.swift:184`), and `magnify(with:)` (`:194`) steps it once past a crude
`magnification > 0.1` threshold. Bare two-finger scroll pans `scrollSeconds`.

Three things are wrong with that under the hands the user actually has:

1. A pinch is a continuous gesture and the ladder makes it a stutter — a 4x or 5x jump per rung, with a
   dead zone either side of the threshold and no way to sit between two rungs.
2. Two-finger scroll does not zoom at all, which is what the user asked for.
3. Every zoom pivots on the pointer, so the playhead — the one thing on screen the eye is actually
   tracking — slides away under a gesture that was supposed to be a magnifying glass.

What is already right and must stay right: zoom writes `zoomIndex` and `scrollSeconds` and nothing else,
and the only thing outside `TimelineUI` that watches the view model is
`ProjectDocument.observeViewModelPlayhead` (`Sources/TimelineApp/ProjectDocument.swift:407`), which tracks
`viewModel.playhead` alone. Compiles and player-item swaps are driven exclusively from `store.changes`
through `handle(_:) → refreshRender()` (`:349`). So "zoom does not touch the video" is structural, not a
promise — and this plan keeps it structural by never letting a zoom path reach `apply`, `setPlayhead`, or
the store.

## 1. Decisions

1. **`secondsPerPoint` becomes continuous, clamped to the ladder's ends; the ladder survives as the
   rungs the `+`/`-` keys step between.** The alternative — keep it discrete and accumulate gesture
   deltas until a rung flips — was rejected: it cannot render an intermediate scale, so a slow pinch
   still shows nothing until it snaps 5x, which is exactly the complaint. The ladder is not deleted,
   because a keyboard zoom wants a repeatable, memorable scale, and because `ZoomLevel.secondsPerPoint`
   is load-bearing in tests and fixtures.

2. **`zoomIndex` stays public API and becomes derived**: the getter answers the nearest rung in *log*
   space, the setter snaps to that rung exactly. `UIFixture.make(zoomIndex:)`
   (`Tests/TimelineUITests/UITestSupport.swift:21`), `setZoom(index:)`, and every existing assertion of
   the form `l.secondsPerPoint == ZoomLevel.secondsPerPoint[i]` keep working unchanged, because a rung
   set through the index path is stored bit-exact rather than recomputed.

3. **The zoom anchor is the playhead when it is on screen, the pointer when it is not, and the left edge
   of the track area when there is neither.** The existing behaviour (always the pointer) and the
   request ("the playhead should stay in the same place") disagree whenever the pointer is not on the
   playhead, and one of them has to win. The playhead wins when it is visible: it is what the user asked
   for, it is the timeline's focus of attention, and it is the only anchor a keyboard zoom or an
   agent-driven zoom could ever have. When the playhead is off screen there is nothing to hold still, so
   the pointer — which is what every editor pivots a pinch on — takes over. `scrollSeconds` still clamps
   at zero, so near the start of the sequence the anchor drifts rather than the view scrolling negative;
   "does its best" is the requirement and this is where the best runs out.

4. **Vertical scroll zooms, horizontal scroll pans, Shift forces a pan, and Command still zooms.**
   Panning is not dropped: it moves to the axis a trackpad already gives for free, which is how Sketch,
   Figma, and Resolve's own trackpad mode resolve the same conflict. `scrollWheel` already reads
   `scrollingDeltaX` and `scrollingDeltaY` separately, so the dominant axis decides. Shift is there for
   a one-wheel mouse, which has no horizontal axis to pan with. Command+wheel keeps zooming, so nobody's
   fingers have to be retrained.

5. **Zoom factors are exponential, never additive.** `factor = exp(delta * rate)` makes a gesture
   reversible to the bit: pinching out by `m` and back by `-m` multiplies by `exp(m) * exp(-m) == 1`,
   where the obvious `1 + m` form leaves `1 - m²` behind and drifts a little further out on every
   wobble. It also makes the gesture scale-free — the same finger travel is the same ratio at every
   zoom, which is what a log-scaled axis should feel like.

6. **Media requests are quantized onto a subdivided ladder.** This is the one non-obvious consequence of
   continuous zoom and the reason it is a decision rather than an implementation detail.
   `TimelineSceneBuilder` keys filmstrips and waveforms off `layout.secondsPerPoint`
   (`TimelineScene.swift:514`, `:573`, `:602`), and every distinct key is a real decode:
   `TimelineMediaCache.filmstrip(_:)` starts an `AVAssetImageGenerator` fetch per miss
   (`TimelineMediaCache.swift:48`). A continuous pinch delivers tens of events per second, each minting
   a fresh set of keys — a fetch storm and a cache that never hits. So `TimelineLayout` exposes
   `mediaSecondsPerPoint`, snapped onto a ladder that subdivides the six rungs geometrically, and the
   two media call sites use that instead. Rung values map to themselves exactly, so
   `RenderTests.filmstripsAndWaveformsAreFetchedPerZoomAndDrawn` keeps asserting
   `samplesPerPixel == Int(0.05 * 48000)` unchanged.

7. **Ruler ticks need no new logic.** `majorTickSeconds(minimumSpacing:)` (`TimelineLayout.swift:217`)
   already scans a sorted table for the first interval at least 90 points wide, which is a function of
   `secondsPerPoint` and not of any rung. It was checked at both clamps: at 0.002 s/pt the first
   qualifying interval is 0.25 s (125 pt) and at 4.0 s/pt it is 600 s (150 pt), so a label is always
   chosen and always at least 90 points from its neighbour. A test walks the whole continuous range
   rather than the six rungs.

## 2. Design

### 2.1 `ZoomLevel` owns the zoom's arithmetic

Everything with a number in it lives here, so no gesture handler carries a literal.

```swift
public enum ZoomLevel {
    public static let secondsPerPoint: [Double] = [4.0, 1.0, 0.25, 0.05, 0.01, 0.002]  // unchanged
    public static var widest: Double            // 4.0    — zoomed all the way out
    public static var finest: Double            // 0.002  — zoomed all the way in
    public static func clamp(_ value: Double) -> Double
    public static func nearestIndex(to value: Double) -> Int      // in log space
    public static func zoomedIn(from value: Double) -> Double     // the next rung finer
    public static func zoomedOut(from value: Double) -> Double    // the next rung coarser

    public static let pinchGain: Double                  // magnification -> exponent
    public static let scrollZoomRatePerPoint: Double     // trackpad, per point of travel
    public static let scrollZoomRatePerLine: Double      // wheel, per detent
    public static func pinchFactor(magnification: Double) -> Double
    public static func scrollZoomFactor(delta: Double, precise: Bool) -> Double

    public static let mediaSubdivisions: Int             // rungs between two ladder rungs
    public static func mediaSecondsPerPoint(_ value: Double) -> Double
}
```

`clamp` also swallows NaN and infinity: `magnification` and `scrollingDelta*` come from hardware, and one
bad event must not be able to make the layout unrenderable for the rest of the session.

`zoomedIn(from:)` is `first { $0 < value * (1 - epsilon) }` over the descending ladder, so it is "the next
rung finer than where the pinch left me", not "index + 1" — after a continuous gesture there is no index
to add one to, and `+` must still move.

### 2.2 The scroll gesture is a pure mapping

So it can be tested without an `NSEvent`, which cannot be synthesized meaningfully:

```swift
/// What a scroll wheel or two-finger scroll does. Vertical zooms, horizontal pans, Shift forces the pan
/// (a mouse has one wheel), Command zooms whatever the axis (what Command+wheel did before).
public enum ZoomScrollAction: Hashable, Sendable {
    case zoom(factor: Double)
    case pan(points: Double)
}

extension ZoomLevel {
    public static func scrollAction(
        deltaX: Double, deltaY: Double, precise: Bool, modifiers: EditModifiers) -> ZoomScrollAction
}
```

`TimelineMetalView.scrollWheel` becomes a four-line shell over it: build the action, apply it, `rehover`.

### 2.3 The view model's zoom

```swift
/// Seconds per point: continuous, clamped to `ZoomLevel.widest ... ZoomLevel.finest`.
public var secondsPerPoint: Double { get set }
/// The ladder rung nearest the current zoom; setting it snaps exactly onto that rung.
public var zoomIndex: Int { get set }

/// Zooms to `value` seconds per point, pivoting on `zoomAnchorX(pointerX:)`.
public func setZoom(secondsPerPoint value: Double, anchorX: CGFloat? = nil)
/// Multiplies the zoom by `factor` (> 1 zooms in).
public func zoom(by factor: Double, anchorX: CGFloat? = nil)
public func setZoom(index: Int, anchorX: CGFloat? = nil)   // unchanged signature
public func zoomIn(anchorX: CGFloat? = nil)                // unchanged signature
public func zoomOut(anchorX: CGFloat? = nil)               // unchanged signature
```

All five funnel into one place, which is where decision 3 is written down as a comment and as
`zoomAnchorX(pointerX:)`. The body is the existing three lines: read the anchored time, change the scale,
solve `scrollSeconds` for "that time is still under that x". `scrollSeconds`'s own setter does the clamp
at zero.

`touchRenderInputs()` reads `secondsPerPoint` where it read `zoomIndex`, so an intra-rung pinch step
redraws.

### 2.4 What deliberately does not change

`playhead` is never written by any of it; no zoom path calls `apply`, `commit`, or anything on `store`.
`revealPlayhead()` keeps its meaning (scroll only, never zoom). The `+`/`-` keys keep landing on
`viewModel.zoomIn()` / `zoomOut()` with no anchor, which now means "pivot on the playhead if you can see
it" instead of "pivot on the left edge" — strictly closer to what the key is for.

## 3. Ordered steps

Each step builds, lints, passes `swift test --filter TimelineUITests`, and is one commit.

1. **This plan.**
2. **`ZoomLevel`**: the ladder helpers, the gesture factors, `ZoomScrollAction`, and
   `mediaSecondsPerPoint`; `TimelineLayout.mediaSecondsPerPoint`. Tests: `LayoutTests`.
3. **`TimelineViewModel`**: continuous storage, derived `zoomIndex`, `zoomAnchorX`, the five entry
   points, `touchRenderInputs`. Tests: `LayoutTests`, and a new `ZoomTests`.
4. **`TimelineScene`**: the two media call sites move to `layout.mediaSecondsPerPoint`. Tests:
   `RenderTests` unchanged, plus a quantization test in `ZoomTests`.
5. **`TimelineMetalView`**: `magnify` and `scrollWheel` over the pure mapping. Only the mapping is
   asserted; the feel is a human check.

## 4. Test plan

Swift Testing, sentence-shaped names, `UIFixture` from `Tests/TimelineUITests/UITestSupport.swift`.

**`Tests/TimelineUITests/ZoomTests.swift`** (new, `@Suite("Zoom")`)
- `zoomIsContinuousAndClampsAtBothEndsOfTheLadder`
- `theLadderStepsToTheNextRungEvenFromBetweenTwoRungs`
- `zoomIndexAnswersTheNearestRungAndSettingItLandsExactlyOnOne`
- `aPinchOfManySmallStepsZoomsSmoothlyAndReturnsExactlyWhereItStarted`
- `zoomKeepsTheVisiblePlayheadUnderTheSamePixel`
- `zoomFallsBackToThePointerWhenThePlayheadIsOffScreen`
- `zoomNeverScrollsBeforeTheStartOfTheSequence`
- `noZoomChangesThePlayheadTimeOrSendsACommand`
- `verticalScrollZoomsAndHorizontalScrollPans`
- `shiftForcesAPanAndCommandForcesAZoom`
- `aWheelDetentZoomsLessThanAnInchOfTrackpadTravel`
- `mediaKeysAreQuantizedSoASmallZoomDoesNotRefetchEveryThumbnail`
- `rulerTicksStayLegibleAtEveryContinuousZoom`

**`Tests/TimelineUITests/LayoutTests.swift`** — the two existing zoom tests must pass untouched; that is
the compatibility proof for decision 2.

**`Tests/TimelineUITests/BenchmarkTests.swift`** — unchanged, and its printed per-zoom budget is compared
before and after.

## 5. Verification

1. `./ci.sh` — lint clean, all nine test targets green, `--skeleton-check` passes.
2. The benchmark line for each of the five zoom levels is no slower than it was.
3. **By hand** (`swift run TimelineApp`), which is the only thing that can answer whether it *feels*
   right: pinch in and out on a trackpad and watch the ruler labels change smoothly; two-finger scroll
   up and down to zoom; two-finger swipe sideways to pan; Shift-scroll to pan on a mouse; check the
   playhead sits still while zooming and that the preview picture never flickers, stalls, or re-seeks.

## 6. Risks

- **Feel is not testable.** Rates and gains (`pinchGain`, the two scroll rates) are guesses until they
  are under real fingers. They are three named constants in one enum precisely so that tuning them is a
  one-line change.
- **Momentum.** A flicked trackpad scroll keeps delivering events after the fingers lift, so the zoom
  coasts. That is probably desirable, and it is the same behaviour panning already had; if it is not, the
  fix is to ignore `event.momentumPhase != []`.
- **Media quantization is a visible trade.** Between two quantized rungs a filmstrip tile is drawn
  slightly wider or narrower than the frame it holds. `mediaSubdivisions` sets the worst case; six rungs
  per ladder step keeps it under about 15%, which is invisible on a 40-point-tall thumbnail and cheap
  enough in cache entries.
- **Continuous zoom widens the space of layouts the scene builder sees**, so any latent assumption that
  `secondsPerPoint` is one of six values is now reachable. The whole module was grepped for
  `secondsPerPoint`; the only consumers are the layout's own arithmetic, the two media call sites, the
  snap tolerance, and the trim handle width, all of which are already continuous functions of it.
