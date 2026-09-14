import CoreGraphics
import Foundation
import Testing
import TimelineCore

@testable import TimelineUI

/// The geometry behind the preview's frame guide: where the frame lands in a viewport of a given shape,
/// where the footage lands inside the frame, and what the corner says about both.
///
/// The view is not tested; the value type it draws is. The fit itself belongs to `ExportFraming` and is
/// tested there — what is asserted here is that the guide reads it with the viewport as the output, so
/// the stroke lands exactly where `videoGravity = .resizeAspect` puts the picture.
@MainActor
@Suite("Frame guide")
struct FrameGuideTests {
    private static func guide(_ viewport: CGSize, _ width: Int, _ height: Int) -> FrameGuide {
        FrameGuide(viewport: viewport, frameSize: FrameSize(width: width, height: height))
    }

    // MARK: Where the frame lands

    /// The user's own project: a 9:16 frame in a preview panel that is wider than it is tall. The guide
    /// is the full height, a third of the width, and centred — which is exactly the black the panel was
    /// painting on its own, now drawn as a frame.
    @Test func aPortraitFrameInALandscapeViewportIsFullHeightAndCentred() {
        let guide = FrameGuideTests.guide(CGSize(width: 800, height: 600), 2160, 3840)
        #expect(guide.isVisible)
        #expect(guide.scale == CGFloat(600) / CGFloat(3840))
        #expect(guide.rect.width == 337.5)
        #expect(guide.rect.height == 600)
        #expect(guide.rect.minX == 231)
        #expect(guide.rect.minY == 0)
        #expect(!guide.fillsViewport)
    }

    @Test func aLandscapeFrameInAPortraitViewportIsFullWidthAndCentred() {
        let guide = FrameGuideTests.guide(CGSize(width: 600, height: 800), 1920, 1080)
        #expect(guide.scale == CGFloat(600) / CGFloat(1920))
        #expect(guide.rect.width == 600)
        #expect(guide.rect.height == 337.5)
        #expect(guide.rect.minX == 0)
        #expect(guide.rect.minY == 231)
        #expect(!guide.fillsViewport)
    }

    /// A viewport the frame's own shape: nothing to wash, and the stroke sits on the panel's edge.
    @Test func aFrameTheViewportsOwnShapeFillsIt() {
        let guide = FrameGuideTests.guide(CGSize(width: 1920, height: 1080), 3840, 2160)
        #expect(guide.scale == 0.5)
        #expect(guide.rect == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(guide.fillsViewport)
    }

    /// `resizeAspect` never crops, so the guide is the smaller of the two ratios and never leaves the
    /// viewport, whichever way the panel is dragged.
    @Test func theGuideIsAlwaysTheAspectFitAndAlwaysInside() {
        for viewport in [
            CGSize(width: 480, height: 240), CGSize(width: 240, height: 900), CGSize(width: 640, height: 640),
        ] {
            for frame in [(1920, 1080), (1080, 1920), (1080, 1080), (2160, 3840)] {
                let guide = FrameGuideTests.guide(viewport, frame.0, frame.1)
                #expect(guide.scale == min(viewport.width / CGFloat(frame.0), viewport.height / CGFloat(frame.1)))
                #expect(guide.rect.minX >= 0)
                #expect(guide.rect.minY >= 0)
                #expect(guide.rect.maxX <= viewport.width + ExportFraming.barTolerance)
                #expect(guide.rect.maxY <= viewport.height + ExportFraming.barTolerance)
            }
        }
    }

    /// Nothing to draw into, or nothing to draw: the overlay asks this before it draws anything, so a
    /// panel mid-animation or a frame that has not loaded cannot put a stroke in the corner.
    @Test func aDegenerateViewportOrFrameIsNotVisible() {
        #expect(!FrameGuideTests.guide(.zero, 1920, 1080).isVisible)
        #expect(!FrameGuideTests.guide(CGSize(width: 800, height: 0.5), 1920, 1080).isVisible)
        #expect(!FrameGuideTests.guide(CGSize(width: 800, height: 600), 0, 0).isVisible)
    }

    // MARK: What the corner says

    @Test func theLabelIsThePixelsAndTheAspect() {
        #expect(FrameGuideTests.guide(CGSize(width: 800, height: 600), 2160, 3840).label == "2160 × 3840 · 9:16")
        #expect(FrameGuideTests.guide(CGSize(width: 800, height: 600), 1920, 1080).label == "1920 × 1080 · 16:9")
        #expect(FrameGuideTests.guide(CGSize(width: 800, height: 600), 1080, 1080).label == "1080 × 1080 · 1:1")
    }

    // MARK: Where the footage lands

    /// The case the user was burnt by, drawn at edit time instead of discovered at export time: portrait
    /// footage in the landscape frame every project is created in. The inner rectangle is where the
    /// picture actually is, and the 656 px is `FormatMismatch`'s own measurement — the same number
    /// `SequenceFormatTests` and `AgentKitTests.OrientationToolTests` assert.
    @Test func portraitFootageInALandscapeFrameIsDrawnPillarboxedInsideIt() {
        let mismatch = FormatMismatch(
            sequenceSize: FrameSize(width: 1920, height: 1080),
            clips: [
                FormatMismatch.ClipSize(
                    clipId: "clip-1", assetName: "IMG.MOV", size: FrameSize(width: 1080, height: 1920))
            ])
        let guide = FrameGuide(viewport: CGSize(width: 1920, height: 1080), mismatch: mismatch)
        let media = try? #require(guide.mediaRect)
        #expect(media == CGRect(x: 656, y: 0, width: 607.5, height: 1080))
        #expect(guide.mediaLabel == "656 px \(ExportText.pillarboxBadge)")
        #expect(guide.rect.contains(media ?? .infinite))
    }

    /// The footage reaches the screen through both fits — into the frame in pixels, then into the
    /// viewport in points — so a half-size viewport halves the inner rectangle too.
    @Test func theFootageRectangleFollowsBothFits() {
        let mismatch = FormatMismatch(
            sequenceSize: FrameSize(width: 1920, height: 1080),
            clips: [
                FormatMismatch.ClipSize(
                    clipId: "clip-1", assetName: "IMG.MOV", size: FrameSize(width: 1080, height: 1920))
            ])
        let guide = FrameGuide(viewport: CGSize(width: 960, height: 540), mismatch: mismatch)
        #expect(guide.scale == 0.5)
        #expect(guide.mediaRect == CGRect(x: 328, y: 0, width: 303.75, height: 540))
    }

    /// Letterboxing is the other way round, and reads the other badge.
    @Test func landscapeFootageInAPortraitFrameIsDrawnLetterboxed() {
        let mismatch = FormatMismatch(
            sequenceSize: FrameSize(width: 1080, height: 1920),
            clips: [
                FormatMismatch.ClipSize(
                    clipId: "clip-1", assetName: "wide.mov", size: FrameSize(width: 1920, height: 1080))
            ])
        let guide = FrameGuide(viewport: CGSize(width: 1080, height: 1920), mismatch: mismatch)
        #expect(guide.mediaRect == CGRect(x: 0, y: 656, width: 1080, height: 607.5))
        #expect(guide.mediaLabel == "656 px \(ExportText.letterboxBadge)")
    }

    /// Footage that fills the frame draws no inner rectangle and says nothing about bars: the guide is
    /// then only the frame, which is the state this whole feature is trying to make recognisable.
    @Test func footageThatFillsTheFrameDrawsNoInnerRectangle() {
        let mismatch = FormatMismatch(
            sequenceSize: FrameSize(width: 2160, height: 3840),
            clips: [
                FormatMismatch.ClipSize(
                    clipId: "clip-1", assetName: "IMG.MOV", size: FrameSize(width: 1080, height: 1920))
            ])
        #expect(mismatch.isClean)
        let guide = FrameGuide(viewport: CGSize(width: 800, height: 600), mismatch: mismatch)
        #expect(guide.mediaRect == nil)
        #expect(guide.mediaLabel == nil)
        #expect(guide.label == "2160 × 3840 · 9:16")
    }

    /// An empty sequence still has a frame, and the guide still states it.
    @Test func anEmptySequenceStillDrawsItsFrame() {
        let mismatch = FormatMismatch(sequenceSize: FrameSize(width: 1080, height: 1920), clips: [])
        let guide = FrameGuide(viewport: CGSize(width: 800, height: 600), mismatch: mismatch)
        #expect(guide.isVisible)
        #expect(guide.mediaRect == nil)
        #expect(guide.label == "1080 × 1920 · 9:16")
    }

    // MARK: The flag

    @Test func theGuideIsOnUntilItIsTurnedOff() {
        withPanelDefaults { defaults in
            let model = PreviewGuideModel(defaults: defaults)
            #expect(model.showsFrameGuide)
            model.toggleFrameGuide()
            #expect(!model.showsFrameGuide)
            #expect(defaults.object(forKey: PreviewGuideModel.frameGuideKey) as? Bool == false)
        }
    }

    /// Stored the way a panel's collapsed flag is, and read back the same way: `object(forKey:)`, so a
    /// stored `false` is not mistaken for a key that was never written.
    @Test func theFlagSurvivesANewModelOverTheSameDefaults() {
        withPanelDefaults { defaults in
            PreviewGuideModel(defaults: defaults).setShowsFrameGuide(false)
            #expect(!PreviewGuideModel(defaults: defaults).showsFrameGuide)

            PreviewGuideModel(defaults: defaults).setShowsFrameGuide(true)
            #expect(PreviewGuideModel(defaults: defaults).showsFrameGuide)
        }
    }

    @Test func aFreshSuiteIsTheDefaultRatherThanAStoredFalse() {
        withPanelDefaults { defaults in
            #expect(defaults.object(forKey: PreviewGuideModel.frameGuideKey) == nil)
            #expect(PreviewGuideModel(defaults: defaults).showsFrameGuide)
        }
    }
}
