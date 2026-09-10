import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import Observation
import Testing
import TimelineCore

@testable import TimelineUI

@MainActor
@Suite("Zoom: pinch, scroll, and what stays still")
struct ZoomTests {

    // MARK: The continuous scale and the ladder inside it

    @Test func zoomIsContinuousAndClampsAtBothEndsOfTheLadder() async throws {
        let f = try await UIFixture.make("three-clips")
        let vm = f.viewModel
        vm.secondsPerPoint = 0.037
        #expect(vm.secondsPerPoint == 0.037)
        #expect(!ZoomLevel.secondsPerPoint.contains(vm.secondsPerPoint))
        #expect(vm.layout.secondsPerPoint == 0.037)

        vm.secondsPerPoint = 1_000
        #expect(vm.secondsPerPoint == ZoomLevel.widest)
        vm.secondsPerPoint = 1e-9
        #expect(vm.secondsPerPoint == ZoomLevel.finest)
        // Hardware hands us `magnification` and `scrollingDelta*`; one bad event must not be able to make
        // the layout unrenderable for the rest of the session.
        vm.secondsPerPoint = .nan
        #expect(vm.secondsPerPoint == ZoomLevel.secondsPerPoint[ZoomLevel.defaultIndex])
        vm.zoom(by: 0)
        vm.zoom(by: .infinity)
        #expect(vm.secondsPerPoint == ZoomLevel.secondsPerPoint[ZoomLevel.defaultIndex])
    }

    @Test func theLadderStepsToTheNextRungEvenFromBetweenTwoRungs() async throws {
        let f = try await UIFixture.make("three-clips")
        let vm = f.viewModel
        // Between rung 3 (0.05) and rung 4 (0.01): one press lands on a rung, not on "wherever + one".
        vm.secondsPerPoint = 0.03
        vm.zoomIn()
        #expect(vm.secondsPerPoint == 0.01)
        vm.secondsPerPoint = 0.03
        vm.zoomOut()
        #expect(vm.secondsPerPoint == 0.05)
        // From a rung it is the neighbouring rung, as it always was.
        vm.setZoom(index: 2)
        vm.zoomIn()
        #expect(vm.zoomIndex == 3)
        vm.zoomOut()
        #expect(vm.zoomIndex == 2)
        // And it stops at the ends instead of wrapping or sticking between rungs.
        for _ in 0..<10 { vm.zoomIn() }
        #expect(vm.secondsPerPoint == ZoomLevel.finest)
        for _ in 0..<10 { vm.zoomOut() }
        #expect(vm.secondsPerPoint == ZoomLevel.widest)
    }

    @Test func zoomIndexAnswersTheNearestRungAndSettingItLandsExactlyOnOne() async throws {
        let f = try await UIFixture.make("three-clips")
        let vm = f.viewModel
        for i in 0..<ZoomLevel.count {
            vm.zoomIndex = i
            #expect(vm.secondsPerPoint == ZoomLevel.secondsPerPoint[i])
            #expect(vm.zoomIndex == i)
        }
        // Nearest is measured in log space, because the ladder is geometric: the midpoint of 1.0 and 0.25
        // is 0.5, so 0.6 is the coarser rung's and 0.4 is the finer one's.
        vm.secondsPerPoint = 0.6
        #expect(vm.zoomIndex == 1)
        vm.secondsPerPoint = 0.4
        #expect(vm.zoomIndex == 2)
        #expect(ZoomLevel.nearestIndex(to: 1_000) == 0)
        #expect(ZoomLevel.nearestIndex(to: 1e-9) == ZoomLevel.count - 1)
    }

    @Test func aPinchOfManySmallStepsZoomsSmoothlyAndReturnsExactlyWhereItStarted() async throws {
        let f = try await UIFixture.make("three-clips")
        let vm = f.viewModel
        vm.setPlayhead(RationalTime(seconds: 5))
        vm.scrollSeconds = 2
        let startZoom = vm.secondsPerPoint
        let startScroll = vm.scrollSeconds
        let anchorX = vm.layout.x(for: vm.playhead)

        var previous = startZoom
        var steps: [Double] = []
        for _ in 0..<40 {
            vm.zoom(by: ZoomLevel.pinchFactor(magnification: 0.01), anchorX: anchorX)
            // Smooth: every step moves, and no step jumps a whole ladder rung.
            #expect(vm.secondsPerPoint < previous)
            #expect(previous / vm.secondsPerPoint < 1.05)
            steps.append(vm.secondsPerPoint)
            previous = vm.secondsPerPoint
        }
        // Continuous, not the six rungs: 40 steps produce 40 distinct scales.
        #expect(Set(steps).count == 40)
        #expect(vm.secondsPerPoint < startZoom * 0.7)

        for _ in 0..<40 {
            vm.zoom(by: ZoomLevel.pinchFactor(magnification: -0.01), anchorX: anchorX)
        }
        #expect(abs(vm.secondsPerPoint - startZoom) < 1e-12)
        #expect(abs(vm.scrollSeconds - startScroll) < 1e-9)
    }

    // MARK: What the zoom pivots on

    @Test func zoomKeepsTheVisiblePlayheadUnderTheSamePixel() async throws {
        let f = try await UIFixture.make("three-clips")
        let vm = f.viewModel
        vm.setPlayhead(RationalTime(seconds: 10))
        vm.scrollSeconds = 8
        let before = vm.layout.x(for: vm.playhead)
        #expect(before > vm.layout.trackAreaMinX)

        // Even with the pointer somewhere else entirely: the playhead is what the eye is on.
        vm.zoom(by: 3.7, anchorX: 900)
        #expect(abs(vm.layout.x(for: vm.playhead) - before) < 1e-6)
        vm.zoom(by: 1 / 3.7, anchorX: 200)
        #expect(abs(vm.layout.x(for: vm.playhead) - before) < 1e-6)
        // The keys have no pointer at all and hold it just as still.
        vm.zoomIn()
        #expect(abs(vm.layout.x(for: vm.playhead) - before) < 1e-6)
        vm.setZoom(index: 2)
        #expect(abs(vm.layout.x(for: vm.playhead) - before) < 1e-6)

        // The one thing that beats the playhead is the start of the sequence: zooming out far enough that
        // holding it would put time before zero on screen clamps the scroll and lets the playhead drift.
        vm.setZoom(index: 0)
        #expect(vm.scrollSeconds == 0)
        #expect(vm.layout.x(for: vm.playhead) != before)
    }

    @Test func zoomFallsBackToThePointerWhenThePlayheadIsOffScreen() async throws {
        let f = try await UIFixture.make("three-clips")
        let vm = f.viewModel
        vm.scrollSeconds = 20
        #expect(vm.layout.x(for: vm.playhead) < vm.layout.trackAreaMinX)
        let anchorX: CGFloat = 700
        let anchored = vm.layout.seconds(atX: anchorX)
        vm.zoom(by: 2.5, anchorX: anchorX)
        #expect(abs(vm.layout.seconds(atX: anchorX) - anchored) < 1e-9)
        // With neither playhead nor pointer, the left edge holds: the visible start does not move.
        let start = vm.layout.visibleStartSeconds
        vm.zoom(by: 1.6)
        #expect(abs(vm.layout.visibleStartSeconds - start) < 1e-9)
        // A pointer over the track headers is not a meaningful anchor either.
        vm.zoom(by: 1.6, anchorX: 20)
        #expect(abs(vm.layout.visibleStartSeconds - start) < 1e-9)
    }

    @Test func zoomNeverScrollsBeforeTheStartOfTheSequence() async throws {
        let f = try await UIFixture.make("three-clips")
        let vm = f.viewModel
        vm.setPlayhead(RationalTime(seconds: 1))
        vm.scrollSeconds = 0.5
        for _ in 0..<20 { vm.zoom(by: 0.8, anchorX: 1_100) }
        #expect(vm.scrollSeconds >= 0)
        #expect(vm.layout.visibleStartSeconds >= 0)
        #expect(vm.secondsPerPoint == ZoomLevel.widest)
        for _ in 0..<40 { vm.zoom(by: 1.25, anchorX: 1_100) }
        #expect(vm.scrollSeconds >= 0)
        #expect(vm.secondsPerPoint == ZoomLevel.finest)
    }

    // MARK: Zoom is a view transform and nothing else

    @Test func noZoomChangesThePlayheadTimeOrSendsACommand() async throws {
        let f = try await UIFixture.make("three-clips")
        let vm = f.viewModel
        vm.setPlayhead(RationalTime(seconds: 7.25))
        let playhead = vm.playhead
        let version = vm.project.version

        vm.zoom(by: ZoomLevel.pinchFactor(magnification: 0.4), anchorX: 500)
        vm.zoom(by: ZoomLevel.scrollZoomFactor(delta: -30, precise: true), anchorX: 500)
        vm.zoomIn()
        vm.zoomOut()
        vm.setZoom(index: 0)
        vm.setZoom(secondsPerPoint: 0.02, anchorX: 300)

        #expect(vm.playhead == playhead)
        #expect(vm.commandCount == 0)
        #expect(vm.project.version == version)
        #expect(await f.receivedCommands.isEmpty)
        #expect(vm.pending == nil && vm.preview == nil)
    }

    /// The only thing outside `TimelineUI` that watches the view model is `ProjectDocument`, and it
    /// watches exactly one property: `playhead`, whose changes seek the preview player and, through the
    /// store, recompile. This is that observer, so a zoom that woke it would be a zoom that touched the
    /// video.
    @Test func zoomingDoesNotWakeThePlayheadObserverThePlayerSeeksFrom() async throws {
        let f = try await UIFixture.make("three-clips")
        let vm = f.viewModel
        let woke = ObservationFlag()
        withObservationTracking {
            _ = vm.playhead
        } onChange: {
            woke.value = true
        }
        vm.zoom(by: 2, anchorX: 400)
        vm.scrollSeconds += 3
        vm.zoomIn()
        #expect(!woke.value)
        // The observer is live: moving the playhead really does wake it.
        vm.setPlayhead(RationalTime(seconds: 2))
        #expect(woke.value)
    }

    // MARK: The scroll gesture

    @Test func verticalScrollZoomsAndHorizontalScrollPans() async throws {
        // Vertical: positive zooms in, negative zooms out — the direction Command+wheel always had.
        #expect(ZoomLevel.scrollAction(deltaX: 0, deltaY: 12, precise: true, modifiers: []) == .zoom(factor: exp(0.12)))
        guard case .zoom(let out) = ZoomLevel.scrollAction(deltaX: 0, deltaY: -12, precise: true, modifiers: [])
        else { Issue.record("a vertical scroll must zoom"); return }
        #expect(out < 1)
        // Horizontal: a pan, in points, the sign `scrollWheel` already subtracted.
        #expect(ZoomLevel.scrollAction(deltaX: 18, deltaY: 0, precise: true, modifiers: []) == .pan(points: 18))
        // A two-finger swipe is never purely one axis, so the dominant one decides.
        #expect(ZoomLevel.scrollAction(deltaX: 20, deltaY: 3, precise: true, modifiers: []) == .pan(points: 20))
        #expect(ZoomLevel.scrollAction(deltaX: 3, deltaY: 20, precise: true, modifiers: []) == .zoom(factor: exp(0.2)))
        // A dead event does nothing at all.
        #expect(ZoomLevel.scrollAction(deltaX: 0, deltaY: 0, precise: true, modifiers: []) == .pan(points: 0))
        #expect(ZoomLevel.scrollAction(deltaX: .nan, deltaY: .nan, precise: true, modifiers: []) == .pan(points: 0))
    }

    @Test func shiftForcesAPanAndCommandForcesAZoom() async throws {
        // A mouse has one wheel and no horizontal axis, so Shift is how it pans.
        #expect(ZoomLevel.scrollAction(deltaX: 0, deltaY: 9, precise: false, modifiers: [.shift]) == .pan(points: 9))
        #expect(ZoomLevel.scrollAction(deltaX: 9, deltaY: 2, precise: false, modifiers: [.shift]) == .pan(points: 9))
        // Command kept zooming whatever the axis, so nobody's fingers have to be retrained.
        #expect(
            ZoomLevel.scrollAction(deltaX: 40, deltaY: 2, precise: true, modifiers: [.command])
                == .zoom(factor: exp(0.02)))
    }

    @Test func aWheelDetentZoomsLessThanAnInchOfTrackpadTravel() async throws {
        let detent = ZoomLevel.scrollZoomFactor(delta: 1, precise: false)
        let inch = ZoomLevel.scrollZoomFactor(delta: 72, precise: true)
        #expect(detent > 1 && detent < 1.5)
        #expect(inch > detent)
        #expect(inch < ZoomLevel.widest / ZoomLevel.finest)
        // Precise deltas arrive in points and one point must barely move the scale.
        #expect(ZoomLevel.scrollZoomFactor(delta: 1, precise: true) < 1.02)
        #expect(
            abs(
                ZoomLevel.scrollZoomFactor(delta: 5, precise: true)
                    * ZoomLevel.scrollZoomFactor(delta: -5, precise: true) - 1) < 1e-12)
    }

    // MARK: Media requests and the ruler at continuous zooms

    @Test func mediaKeysAreQuantizedSoASmallZoomDoesNotRefetchEveryThumbnail() async throws {
        for rung in ZoomLevel.secondsPerPoint {
            #expect(ZoomLevel.mediaSecondsPerPoint(rung) == rung)
        }
        let f = try await UIFixture.make("three-clips", media: true, zoomIndex: 4)
        let vm = f.viewModel
        let before = TimelineSceneBuilder.build(from: vm)
        let beforeStrips = Set(before.filmstrips.map(\.key))
        let beforeWaves = Set(before.waveforms.map(\.key))
        #expect(!beforeStrips.isEmpty && !beforeWaves.isEmpty)

        // A 2% pinch step: the scale really changed, the media ladder did not, so the keys already in the
        // cache are still the keys asked for. Zooming in narrows the visible range, so the new key set is
        // a subset rather than merely an overlap.
        let quantized = vm.layout.mediaSecondsPerPoint
        vm.zoom(by: 1.02)
        #expect(vm.secondsPerPoint != ZoomLevel.secondsPerPoint[4])
        #expect(vm.layout.mediaSecondsPerPoint == quantized)
        let after = TimelineSceneBuilder.build(from: vm)
        #expect(!after.filmstrips.isEmpty)
        #expect(Set(after.filmstrips.map(\.key)).isSubset(of: beforeStrips))
        #expect(Set(after.waveforms.map(\.key)).isSubset(of: beforeWaves))

        // A real zoom still asks for new media: quantization coarsens the ladder, it does not freeze it.
        vm.setZoom(index: 3)
        let far = TimelineSceneBuilder.build(from: vm)
        #expect(vm.layout.mediaSecondsPerPoint != quantized)
        #expect(Set(far.waveforms.map(\.key)).isDisjoint(with: beforeWaves))
    }

    @Test func theMediaLadderStaysCloseToTheZoomItStandsIn() async throws {
        var value = ZoomLevel.widest
        var seen: Set<Double> = []
        while value > ZoomLevel.finest {
            let quantized = ZoomLevel.mediaSecondsPerPoint(value)
            seen.insert(quantized)
            // Never outside the clamps, and never far enough off to stretch a thumbnail visibly.
            #expect(quantized <= ZoomLevel.widest && quantized >= ZoomLevel.finest)
            #expect(max(quantized / value, value / quantized) < 1.16)
            value *= 0.97
        }
        // Coarse enough to be worth having: a whole ladder's worth of zoom is a few dozen key sets, not
        // one per pinch event.
        #expect(seen.count < 40)
        #expect(seen.isSuperset(of: ZoomLevel.secondsPerPoint))
    }

    @Test func rulerTicksStayLegibleAtEveryContinuousZoom() async throws {
        let f = try await UIFixture.make("three-clips")
        let vm = f.viewModel
        var value = ZoomLevel.widest
        while value >= ZoomLevel.finest {
            vm.secondsPerPoint = value
            let l = vm.layout
            let major = l.majorTickSeconds()
            #expect(TimelineLayout.tickIntervals.contains(major))
            #expect(CGFloat(major / l.secondsPerPoint) >= 90)
            #expect(!Timecode.label(seconds: 61.5, interval: major, frameDuration: vm.frameDuration).isEmpty)
            value *= 0.93
        }
    }
}

/// `withObservationTracking`'s `onChange` is a `@Sendable` closure that runs before the change lands, so
/// the flag it sets cannot be a captured `var`.
private final class ObservationFlag: @unchecked Sendable {
    var value = false
}
