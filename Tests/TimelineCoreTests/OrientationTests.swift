import Foundation
import Testing
import TimelineCore

/// The one rotation-aware display size everything else reads (docs/plans/sequence-format.md, decision 1).
@Suite("Display size and orientation") struct OrientationTests {
    func probe(_ width: Int?, _ height: Int?, rotation: Int? = nil) -> Probe {
        Probe(width: width, height: height, rotation: rotation)
    }

    @Test func anUprightProbeDisplaysAtItsEncodedSize() {
        #expect(probe(1920, 1080).displaySize == FrameSize(width: 1920, height: 1080))
        #expect(probe(1920, 1080, rotation: 0).displaySize == FrameSize(width: 1920, height: 1080))
        #expect(probe(1920, 1080, rotation: 0).orientation == .landscape)
        #expect(probe(1080, 1920, rotation: 0).orientation == .portrait)
        #expect(probe(1080, 1080, rotation: 0).orientation == .square)
    }

    @Test func aQuarterTurnSwapsTheAxesInBothDirections() {
        for rotation in [90, -90, 270, -270] {
            #expect(
                probe(3840, 2160, rotation: rotation).displaySize == FrameSize(width: 2160, height: 3840),
                "rotation \(rotation)")
            #expect(probe(3840, 2160, rotation: rotation).orientation == .portrait, "rotation \(rotation)")
        }
    }

    @Test func aHalfTurnLeavesTheAxesAlone() {
        for rotation in [180, -180] {
            #expect(
                probe(3840, 2160, rotation: rotation).displaySize == FrameSize(width: 3840, height: 2160),
                "rotation \(rotation)")
            #expect(probe(3840, 2160, rotation: rotation).orientation == .landscape, "rotation \(rotation)")
        }
    }

    @Test func aMissingOrUnusableSizeHasNoDisplaySize() {
        #expect(probe(nil, nil).displaySize == nil)
        #expect(probe(1920, nil).displaySize == nil)
        #expect(probe(nil, 1080, rotation: 90).displaySize == nil)
        #expect(probe(0, 1080).displaySize == nil)
        #expect(probe(1920, 0).displaySize == nil)
        #expect(probe(nil, nil).orientation == nil)
    }

    /// The real-world case `MediaKitTests.ProbeTests.iphonePortraitHLGProbe` pins: a clip shot in
    /// portrait on an iPhone probes as landscape 3840x2160 with rotation -90.
    @Test func theIPhonePortraitFixtureReadsAsPortrait() {
        let iphone = Probe(
            codec: "hvc1", width: 3840, height: 2160, colorPrimaries: "bt2020", transfer: "arib-std-b67",
            rotation: -90)
        #expect(iphone.encodedSize == FrameSize(width: 3840, height: 2160))
        #expect(iphone.swapsDisplayAxes)
        #expect(iphone.displaySize == FrameSize(width: 2160, height: 3840))
        #expect(iphone.orientation == .portrait)
        #expect(iphone.displaySize?.aspectLabel == "9:16")
        #expect(iphone.displaySize?.description == "2160x3840")
    }

    @Test func anUnrecognisedRotationIsTreatedAsUpright() {
        #expect(!probe(1920, 1080, rotation: 45).swapsDisplayAxes)
        #expect(probe(1920, 1080, rotation: 45).displaySize == FrameSize(width: 1920, height: 1080))
    }

    @Test func anAssetWithoutVideoHasNoDisplaySize() {
        let audio = Asset(
            id: "a", contentHash: "sha256-0", libraryPath: "mix.wav", displayName: "mix.wav", kind: .audio,
            duration: RationalTime(1, 1), hasVideo: false, hasAudio: true)
        #expect(audio.displaySize == nil)
        #expect(audio.orientation == nil)

        let video = Asset(
            id: "v", contentHash: "sha256-1", libraryPath: "IMG.MOV", displayName: "IMG.MOV", kind: .video,
            duration: RationalTime(1, 1), hasVideo: true, hasAudio: true,
            probe: Probe(width: 3840, height: 2160, rotation: -90))
        #expect(video.displaySize == FrameSize(width: 2160, height: 3840))
        #expect(video.orientation == .portrait)
    }

    @Test func aSequenceReportsItsOwnFrameWithNoRotation() {
        let landscape = Sequence(id: "s", name: "S", frameDuration: fd24, width: 1920, height: 1080)
        #expect(landscape.frameSize == FrameSize(width: 1920, height: 1080))
        #expect(landscape.orientation == .landscape)
        #expect(landscape.aspectLabel == "16:9")

        let portrait = Sequence(id: "s", name: "S", frameDuration: fd24, width: 1080, height: 1920)
        #expect(portrait.orientation == .portrait)
        #expect(portrait.aspectLabel == "9:16")

        let square = Sequence(id: "s", name: "S", frameDuration: fd24, width: 1080, height: 1080)
        #expect(square.orientation == .square)
        #expect(square.aspectLabel == "1:1")
    }

    @Test func fillsComparesShapeNotSize() {
        let hd = FrameSize(width: 1920, height: 1080)
        #expect(hd.fills(FrameSize(width: 3840, height: 2160)))
        #expect(FrameSize(width: 3840, height: 2160).fills(hd))
        #expect(!hd.fills(FrameSize(width: 1080, height: 1920)))
        #expect(!hd.fills(FrameSize(width: 1080, height: 1080)))
        #expect(!hd.fills(FrameSize(width: 0, height: 0)))
    }

    @Test func aspectRatioAndLabelSurviveOddSizes() {
        #expect(FrameSize(width: 1998, height: 1080).aspectLabel == "37:20")
        #expect(FrameSize(width: 1920, height: 1080).aspectRatio == 1920.0 / 1080.0)
        #expect(FrameSize(width: 1920, height: 0).aspectRatio == 0)
        #expect(FrameSize(width: 1080, height: 1920).transposed == FrameSize(width: 1920, height: 1080))
    }
}
