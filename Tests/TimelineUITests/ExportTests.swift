import Contracts
import CoreGraphics
import Foundation
import Testing
import TimelineCore

@testable import TimelineUI

/// The pure half of the export sheet: the fit math it draws, the default it opens on, the badges that
/// flag a preset which would pad, and the preset it hands `render_export`.
@Suite("Export framing and draft")
struct ExportTests {
    static func sequence(_ width: Int, _ height: Int, rate: RationalTime = RationalTime(1, 30), name: String = "Main")
        -> Sequence
    {
        Sequence(
            id: SequenceID("seq-1"), name: name, frameDuration: rate, width: width, height: height)
    }

    static func draft(_ width: Int, _ height: Int, rate: RationalTime = RationalTime(1, 30)) -> ExportDraft {
        ExportDraft(
            sequence: sequence(width, height, rate: rate),
            exportsDirectory: URL(fileURLWithPath: "/tmp/Timeline/Exports"))
    }

    // MARK: The fit

    /// A 16:9 sequence in a 9:16 frame: scaled by the width ratio, black above and below. This is the
    /// export the toolbar used to make without asking.
    @Test func aLandscapeSequenceInAPortraitFrameIsLetterboxed() {
        let framing = ExportFraming(
            output: CGSize(width: 1080, height: 1920), sequence: CGSize(width: 1920, height: 1080))
        #expect(framing.scale == 0.5625)
        #expect(framing.fitted.width == 1080)
        #expect(framing.fitted.height == 607.5)
        #expect(framing.fitted.origin.x == 0)
        #expect(framing.fitted.origin.y == 656)
        #expect(framing.bars == .letterbox(656.25))
        #expect(!framing.isExact)
        #expect(abs(framing.coverage - 0.3164) < 0.001)
        #expect(framing.barsDescription == ExportText.letterboxed(656))
    }

    /// And the other way round: a phone-shaped sequence in a 16:9 frame gets black down both sides.
    @Test func aPortraitSequenceInALandscapeFrameIsPillarboxed() {
        let framing = ExportFraming(
            output: CGSize(width: 1920, height: 1080), sequence: CGSize(width: 1080, height: 1920))
        #expect(framing.fitted.height == 1080)
        #expect(framing.fitted.width == 607.5)
        #expect(framing.fitted.origin.y == 0)
        #expect(framing.bars == .pillarbox(656.25))
        #expect(framing.barsDescription == ExportText.pillarboxed(656))
    }

    @Test func matchingAspectsFillTheFrameAtAnySize() {
        let same = ExportFraming(output: CGSize(width: 1920, height: 1080), sequence: CGSize(width: 1920, height: 1080))
        #expect(same.scale == 1)
        #expect(same.bars == ExportFraming.Bars.none)
        #expect(same.isExact)
        #expect(same.coverage == 1)

        // The same shape, four times the pixels: still no bars, and the picture is scaled up.
        let up = ExportFraming(output: CGSize(width: 3840, height: 2160), sequence: CGSize(width: 1920, height: 1080))
        #expect(up.scale == 2)
        #expect(up.isExact)
        #expect(up.fitted == CGRect(x: 0, y: 0, width: 3840, height: 2160))
    }

    @Test func aSquareSequenceInAWideFrameIsPillarboxed() {
        let framing = ExportFraming(
            output: CGSize(width: 1920, height: 1080), sequence: CGSize(width: 1000, height: 1000))
        #expect(framing.fitted.width == 1080)
        #expect(framing.fitted.height == 1080)
        #expect(framing.bars == .pillarbox(420))
        #expect(abs(framing.coverage - 0.5625) < 0.0001)
    }

    /// The origin is rounded because `TimelineCompositor` rounds its translation; the size is not,
    /// because the compositor does not. An odd bar is where the two would differ.
    @Test func theOriginIsRoundedTheWayTheCompositorRoundsIt() {
        let framing = ExportFraming(output: CGSize(width: 101, height: 50), sequence: CGSize(width: 100, height: 50))
        #expect(framing.scale == 1)
        #expect(framing.fitted.origin.x == 1)  // (101 - 100) / 2 = 0.5, rounded
        #expect(framing.fitted.width == 100)
    }

    /// A bar under half an output pixel is the compositor's own rounding, not letterboxing.
    @Test func aSubPixelBarIsNotABar() {
        let framing = ExportFraming(
            output: CGSize(width: 1920, height: 1081), sequence: CGSize(width: 1920, height: 1080))
        #expect(framing.bars == ExportFraming.Bars.none)
        #expect(framing.isExact)
    }

    @Test func aspectsAreNamedInWholeNumbersWhenTheyCanBe() {
        #expect(ExportFraming.aspectLabel(CGSize(width: 1920, height: 1080)) == "16:9")
        #expect(ExportFraming.aspectLabel(CGSize(width: 1080, height: 1920)) == "9:16")
        #expect(ExportFraming.aspectLabel(CGSize(width: 3840, height: 2160)) == "16:9")
        #expect(ExportFraming.aspectLabel(CGSize(width: 1080, height: 1350)) == "4:5")
        #expect(ExportFraming.aspectLabel(CGSize(width: 1000, height: 1000)) == "1:1")
        // 256:109 is not a name anyone reads; the decimal is.
        #expect(ExportFraming.aspectLabel(CGSize(width: 2560, height: 1090)) == "2.35:1")
        #expect(ExportFraming.pixels(CGSize(width: 1920, height: 1080)) == "1920 × 1080")
    }

    // MARK: The default

    @Test func theDefaultIsTheSequenceItselfWhicheverWayUpItIs() {
        for size in [(1920, 1080), (1080, 1920), (1080, 1350), (2560, 1090)] {
            let draft = ExportTests.draft(size.0, size.1)
            #expect(draft.presetName == ExportText.matchSequence)
            #expect(draft.sizing == .preset)
            #expect(draft.rate == .matchSequence)
            #expect(draft.outputSize == CGSize(width: size.0, height: size.1))
            #expect(draft.framing.isExact, "the default letterboxed a \(size.0)x\(size.1) sequence")
            #expect(draft.preset.size == .matchSequence)
            #expect(draft.preset.frameRate == .matchSequence)
            #expect(draft.canExport)
        }
    }

    @Test func theDefaultRateIsTheSequenceRate() {
        #expect(ExportTests.draft(1920, 1080, rate: RationalTime(1001, 30000)).outputRate == Rational(30000, 1001))
        #expect(ExportText.fps(Rational(30000, 1001)) == "29.97 fps")
        #expect(ExportText.fps(Rational(24000, 1001)) == "23.976 fps")
        #expect(ExportText.fps(Rational(30, 1)) == "30 fps")

        var draft = ExportTests.draft(1920, 1080)
        draft.rate = .fixed(Rational(24, 1))
        #expect(draft.outputRate == Rational(24, 1))
        #expect(draft.preset.frameRate == .fixed(Rational(24, 1)))
    }

    // MARK: The badges

    @Test func aPresetThatWouldPadSaysSoBeforeItIsChosen() {
        let landscape = ExportTests.draft(1920, 1080)
        #expect(landscape.badge(forPresetNamed: ExportText.matchSequence) == nil)
        #expect(landscape.badge(forPresetNamed: ExportPreset.h264_1080p.name) == nil)
        #expect(landscape.badge(forPresetNamed: ExportPreset.hevcHLG4K.name) == nil)
        #expect(landscape.badge(forPresetNamed: ExportPreset.reel9x16.name) == ExportText.letterboxBadge)
        #expect(landscape.label(forPresetNamed: ExportPreset.reel9x16.name) == "Reel 9:16 — 1080 × 1920, letterboxed")

        let portrait = ExportTests.draft(1080, 1920)
        #expect(portrait.badge(forPresetNamed: ExportText.matchSequence) == nil)
        #expect(portrait.badge(forPresetNamed: ExportPreset.reel9x16.name) == nil)
        #expect(portrait.badge(forPresetNamed: ExportPreset.h264_1080p.name) == ExportText.pillarboxBadge)
        #expect(portrait.label(forPresetNamed: ExportText.matchSequence) == "Match sequence — 1080 × 1920")

        // ProRes matches the sequence too, so it never pads whatever shape the sequence is.
        #expect(ExportTests.draft(1080, 1350).badge(forPresetNamed: ExportPreset.proRes.name) == nil)
        #expect(ExportTests.draft(1080, 1350).badge(forPresetNamed: ExportPreset.reel9x16.name) != nil)
    }

    @Test func choosingAPresetChangesTheFrameTheSheetDraws() {
        var draft = ExportTests.draft(1920, 1080)
        draft.presetName = ExportPreset.reel9x16.name
        #expect(draft.outputSize == CGSize(width: 1080, height: 1920))
        #expect(draft.framing.bars == .letterbox(656.25))
        #expect(draft.preset.size == .fixed(width: 1080, height: 1920))
        #expect(draft.preset.loudnessTargetLUFS == -14)
    }

    // MARK: Custom dimensions

    @Test func customDimensionsAreSeededFromTheSequenceAndValidated() {
        var draft = ExportTests.draft(1920, 1080)
        draft.sizing = .custom
        #expect(draft.customWidth == 1920)
        #expect(draft.customHeight == 1080)
        #expect(draft.canExport)
        #expect(draft.framing.isExact)

        draft.customWidth = 1079
        #expect(draft.validationError == ExportText.evenDimensions)
        #expect(!draft.canExport)

        draft.customWidth = 8
        #expect(
            draft.validationError
                == ExportText.dimensionRange(ExportDraft.minimumDimension, ExportDraft.maximumDimension))
        draft.customWidth = 9000
        #expect(
            draft.validationError
                == ExportText.dimensionRange(ExportDraft.minimumDimension, ExportDraft.maximumDimension))
        draft.customWidth = 0
        #expect(!draft.canExport)
        draft.customWidth = -1080
        #expect(!draft.canExport)

        draft.customWidth = ExportDraft.maximumDimension
        draft.customHeight = ExportDraft.minimumDimension
        #expect(draft.canExport)
    }

    /// An odd sequence would otherwise seed an invalid custom size before anything is typed.
    @Test func anOddSequenceSeedsAnEvenCustomSize() {
        var draft = ExportTests.draft(1921, 1081)
        draft.sizing = .custom
        #expect(draft.customWidth == 1920)
        #expect(draft.customHeight == 1080)
        #expect(draft.canExport)
    }

    /// A receipt that says "H.264 1080p" over a 720x1280 file is a receipt that lies, and the render
    /// ledger row is what `publish_youtube` reads back.
    @Test func aCustomSizeRenamesThePresetAndTheFile() {
        var draft = ExportTests.draft(1920, 1080)
        draft.presetName = ExportPreset.h264_1080p.name
        draft.sizing = .custom
        draft.customWidth = 720
        draft.customHeight = 1280
        #expect(draft.preset.name == "Custom 720x1280")
        #expect(draft.preset.size == .fixed(width: 720, height: 1280))
        #expect(draft.preset.videoCodec == .h264)
        #expect(draft.outputURL.lastPathComponent == "Main-Custom 720x1280.mp4")
        #expect(draft.framing.bars == .letterbox(437.5))
    }

    // MARK: The destination

    @Test func theDestinationFollowsThePresetUntilTheUserChoosesOne() {
        var draft = ExportTests.draft(1920, 1080)
        #expect(draft.outputURL.path == "/tmp/Timeline/Exports/Main-Match sequence.mp4")

        draft.presetName = ExportPreset.proRes.name
        #expect(draft.outputURL.lastPathComponent == "Main-ProRes 422.mov")

        // A chosen path keeps its name but not its extension: the container is the preset's business.
        draft.chose(URL(fileURLWithPath: "/Users/me/Movies/cut.mp4"))
        #expect(draft.outputURL.path == "/Users/me/Movies/cut.mov")
        draft.presetName = ExportPreset.h264_1080p.name
        #expect(draft.outputURL.path == "/Users/me/Movies/cut.mp4")
        #expect(draft.canExport)
    }

    /// The default path is the same formula `render_export` uses when no `outputPath` is given. The two
    /// copies are pinned to each other by the skeleton check, which can see both modules.
    @Test func theDefaultPathIsTheToolsDefaultPath() {
        let draft = ExportTests.draft(1920, 1080)
        let expected = ExportDraft.defaultURL(
            sequenceName: "Main", presetName: ExportText.matchSequence, fileExtension: "mp4",
            in: URL(fileURLWithPath: "/tmp/Timeline/Exports"))
        #expect(draft.outputURL == expected)

        // A sequence name with a path separator in it cannot make a subdirectory.
        let odd = ExportDraft(
            sequence: ExportTests.sequence(1920, 1080, name: "A/B"),
            exportsDirectory: URL(fileURLWithPath: "/tmp/Timeline/Exports"))
        #expect(odd.outputURL.lastPathComponent == "A-B-Match sequence.mp4")
    }

    // MARK: The wire

    /// What the sheet hands `render_export` is a whole `ExportPreset` object, decoded on the other side
    /// by `ToolSupport.require(input, "preset", as: ExportPreset.self)`. This is that round trip.
    @Test func thePresetSurvivesTheJSONItIsSentAs() throws {
        var draft = ExportTests.draft(1080, 1920, rate: RationalTime(1001, 30000))
        for name in ExportDraft.presets.map(\.name) {
            draft.presetName = name
            let sent = draft.preset
            let json = try JSONValue(encoding: sent)
            #expect(try json.decoded(as: ExportPreset.self) == sent)
        }

        draft.sizing = .custom
        draft.customWidth = 720
        draft.customHeight = 1280
        draft.rate = .fixed(Rational(24000, 1001))
        let custom = draft.preset
        let json = try JSONValue(encoding: custom)
        let back = try json.decoded(as: ExportPreset.self)
        #expect(back == custom)
        #expect(back.size == .fixed(width: 720, height: 1280))
        #expect(back.frameRate == .fixed(Rational(24000, 1001)))
    }
}
