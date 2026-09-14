import AVFoundation
import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import RenderKit
import Testing
import TimelineCore

/// What a portrait clip actually looks like after each fit, in pixels.
///
/// The compositor fits twice — source into the sequence, sequence into the output — and the two are
/// easy to reason about wrongly. These read the black out of real frames instead.
@Suite struct PortraitFramingTests {
    private static let portrait = CGSize(width: 720, height: 1280)

    /// A solid clip whose media is `size`, regardless of the sequence it will live in.
    private static func clip(_ scene: Scene, _ size: CGSize, name: String) async throws -> TestMedia.Clip {
        try await TestMedia.solidColor(
            .red, size: size, frameDuration: Scene.fps, duration: 2, in: scene.library.media, name: name)
    }

    /// `frame(_:at:size:)` treats `size` as a bounding box and keeps the sequence's aspect, so it can
    /// never show what an export of a different shape does. Only the export path can.
    private static func frame(_ scene: Scene, size: CGSize) async throws -> Pixels {
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .full)
        let image = try await renderer.frame(compiled, at: scene.frames(15), size: size)
        return Pixels(image)
    }

    /// A real export, read back from the file it wrote.
    private static func exportedFrame(_ scene: Scene, preset: ExportPreset, name: String) async throws -> Pixels {
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .full)
        let url = scene.library.media.appendingPathComponent("\(name).\(preset.fileExtension)")
        let outcome = try await FakeJobRunner().submit(renderer.export(compiled, preset: preset, to: url)).wait()
        _ = outcome
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return Pixels(try await generator.image(at: CMTime(scene.frames(15))).image)
    }

    /// Is a vertical strip down one side black? A bar the compositor wrote, rather than picture.
    private static func isBlackColumn(_ pixels: Pixels, x: Int, height: Int) -> Bool {
        let samples = stride(from: height / 8, to: height, by: max(1, height / 8)).map { pixels.pixel(x, $0) }
        return samples.allSatisfy { near($0, (0, 0, 0), tolerance: 12) }
    }

    private static func isBlackRow(_ pixels: Pixels, y: Int, width: Int) -> Bool {
        let samples = stride(from: width / 8, to: width, by: max(1, width / 8)).map { pixels.pixel($0, y) }
        return samples.allSatisfy { near($0, (0, 0, 0), tolerance: 12) }
    }

    /// The fix, in pixels: once the sequence is the footage's own shape, the picture fills the file and
    /// there is no black anywhere. This is what "export my portrait project" has to mean.
    @Test func aPortraitClipInAPortraitSequenceFillsTheFrameWithNoBars() async throws {
        let scene = try Scene(
            "PortraitFill", width: Int(PortraitFramingTests.portrait.width),
            height: Int(PortraitFramingTests.portrait.height))
        let asset = try scene.importClip(
            try await PortraitFramingTests.clip(scene, PortraitFramingTests.portrait, name: "portrait"))
        try scene.add(asset, at: 0, count: 45)

        let pixels = try await PortraitFramingTests.frame(scene, size: PortraitFramingTests.portrait)
        let width = Int(PortraitFramingTests.portrait.width)
        let height = Int(PortraitFramingTests.portrait.height)
        #expect(!PortraitFramingTests.isBlackColumn(pixels, x: 2, height: height), "black down the left edge")
        #expect(
            !PortraitFramingTests.isBlackColumn(pixels, x: width - 3, height: height), "black down the right edge")
        #expect(!PortraitFramingTests.isBlackRow(pixels, y: 2, width: width), "black across the top")
        #expect(!PortraitFramingTests.isBlackRow(pixels, y: height - 3, width: width), "black across the bottom")
    }

    /// The starting state: portrait footage in the 1920x1080 frame every project is created in. The
    /// picture is a strip with black down both sides, and the file is landscape however you export it.
    @Test func aPortraitClipInALandscapeSequenceIsPillarboxed() async throws {
        let scene = try Scene("PortraitInLandscape", width: 1920, height: 1080)
        let asset = try scene.importClip(
            try await PortraitFramingTests.clip(scene, PortraitFramingTests.portrait, name: "portrait"))
        try scene.add(asset, at: 0, count: 45)

        let pixels = try await PortraitFramingTests.frame(scene, size: CGSize(width: 1920, height: 1080))
        #expect(PortraitFramingTests.isBlackColumn(pixels, x: 2, height: 1080), "the left bar is missing")
        #expect(PortraitFramingTests.isBlackColumn(pixels, x: 1917, height: 1080), "the right bar is missing")
        // The middle is the picture, so the bars are bars and not a black frame.
        #expect(!near(pixels.pixel(960, 540), (0, 0, 0), tolerance: 12), "the centre is black too")
    }

    /// The trap the export sheet warns about, proven rather than asserted in prose: exporting that same
    /// landscape sequence at a portrait size boxes it a **second** time, so the picture ends up small
    /// with black on all four sides. Changing the export's size cannot undo the first fit; only changing
    /// the sequence can (`docs/plans/sequence-format.md`).
    @Test func exportingALandscapeSequenceAtAPortraitSizeBoxesItTwice() async throws {
        let scene = try Scene("DoubleBox", width: 1920, height: 1080)
        let asset = try scene.importClip(
            try await PortraitFramingTests.clip(scene, PortraitFramingTests.portrait, name: "portrait"))
        try scene.add(asset, at: 0, count: 45)

        // A 9:16 export of a 16:9 sequence: the reel preset's frame, written and read back.
        let pixels = try await PortraitFramingTests.exportedFrame(
            scene, preset: .reel9x16, name: "double-boxed")
        #expect(pixels.width == 1080 && pixels.height == 1920, "the file is \(pixels.width)x\(pixels.height)")
        #expect(PortraitFramingTests.isBlackRow(pixels, y: 2, width: 1080), "no letterbox above")
        #expect(PortraitFramingTests.isBlackRow(pixels, y: 1917, width: 1080), "no letterbox below")
        #expect(PortraitFramingTests.isBlackColumn(pixels, x: 2, height: 1920), "no pillarbox left")
        #expect(PortraitFramingTests.isBlackColumn(pixels, x: 1077, height: 1920), "no pillarbox right")
        #expect(!near(pixels.pixel(540, 960), (0, 0, 0), tolerance: 12), "the centre is black too")
    }
}
