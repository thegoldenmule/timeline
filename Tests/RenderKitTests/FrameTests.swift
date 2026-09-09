import AVFoundation
import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import RenderKit
import Testing
import TimelineCore

/// One frame from a player item through `AVPlayerItemVideoOutput`.
@MainActor
func playerFrame(_ renderer: AVFoundationRenderer, _ compiled: Compiled, at time: RationalTime) async -> Pixels? {
    let item = renderer.playerItem(for: compiled)
    let output = bgraOutput()
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    guard await waitUntilReady(item) else { return nil }
    await item.seek(to: CMTime(time), toleranceBefore: .zero, toleranceAfter: .zero)
    guard let buffer = await nextFrame(output, item: item) else { return nil }
    withExtendedLifetime(player) {}
    return Pixels(buffer)
}

/// Pixel assertions through `frame()` (and, for captions, all three consumers).
@Suite struct FrameTests {
    @Test func cutShowsTheRightSourceFrameOnEachSide() async throws {
        let scene = try Scene("RenderKitCut")
        let a = try scene.importClip(try await scene.barcode(.gray, name: "a"))
        let b = try scene.importClip(try await scene.barcode(.blue, name: "b"))
        try scene.add(a, at: 0, sourceIn: 0, count: 30)
        try scene.add(b, at: 30, sourceIn: 10, count: 30)
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .gesture)
        let before = Pixels(try await renderer.frame(compiled, at: scene.frames(29), size: nil))
        let after = Pixels(try await renderer.frame(compiled, at: scene.frames(30), size: nil))
        #expect(before.width == 640 && before.height == 360)
        #expect(before.frameIndex == 29)
        #expect(after.frameIndex == 10)
        #expect(near(before.mean(before.centerRect), (128, 128, 128), tolerance: 3))
        #expect(near(after.mean(after.centerRect), (0, 0, 255), tolerance: 3))
        let last = Pixels(try await renderer.frame(compiled, at: scene.frames(59), size: nil))
        #expect(last.frameIndex == 39)
    }

    @Test(arguments: [BlendSpace.gamma, .linear]) func pureGreenSurvivesUnshifted(blendSpace: BlendSpace) async throws {
        let scene = try Scene("RenderKitGreen-\(blendSpace)")
        let green = try scene.importClip(try await scene.solid(.green, name: "green"))
        try scene.add(green, at: 0, count: 60)
        let renderer = scene.renderer(blendSpace: blendSpace)
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .gesture)
        let px = Pixels(try await renderer.frame(compiled, at: scene.frames(15), size: nil))
        let mean = px.mean(px.centerRect)
        print("[colour] pure green through the compositor (\(blendSpace)): \(mean)")
        #expect(near(mean, (0, 255, 0), tolerance: 2))
        #expect(near(px.pixel(5, 5), (0, 255, 0), tolerance: 2))
        #expect(near(px.pixel(634, 354), (0, 255, 0), tolerance: 2))
    }

    @Test(arguments: [(BlendSpace.gamma, (128, 128, 0)), (.linear, (188, 188, 0))])
    func crossfadeMidpointFollowsTheBlendSpace(blendSpace: BlendSpace, expected: (Int, Int, Int)) async throws {
        let scene = try Scene("RenderKitDissolve-\(blendSpace)")
        let red = try scene.importClip(try await scene.solid(.red, name: "red"))
        let green = try scene.importClip(try await scene.solid(.green, name: "green"))
        let left = try scene.add(red, at: 0, sourceIn: 0, count: 60)
        let right = try scene.add(green, at: 60, sourceIn: 30, count: 60)
        try scene.transition(left, right, kind: "dissolve", frames: 30)
        let renderer = scene.renderer(blendSpace: blendSpace)
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .gesture)
        let mid = Pixels(try await renderer.frame(compiled, at: scene.frames(60), size: nil))
        let mean = mid.mean(mid.centerRect)
        print("[colour] red-green dissolve midpoint (\(blendSpace)): \(mean)")
        #expect(near(mean, expected, tolerance: 3))
        // Either side of the overlap is the plain clip.
        let before = Pixels(try await renderer.frame(compiled, at: scene.frames(40), size: nil))
        #expect(near(before.mean(before.centerRect), (255, 0, 0), tolerance: 2))
        let after = Pixels(try await renderer.frame(compiled, at: scene.frames(80), size: nil))
        #expect(near(after.mean(after.centerRect), (0, 255, 0), tolerance: 2))
        // The override on the options wins over the renderer's default.
        let other: BlendSpace = blendSpace == .gamma ? .linear : .gamma
        let overridden = try await renderer.compile(
            scene.sequence, assets: scene.assets, options: RenderOptions(audio: false, blendSpace: other))
        let otherMid = Pixels(try await renderer.frame(overridden, at: scene.frames(60), size: nil))
        #expect(!near(otherMid.mean(otherMid.centerRect), expected, tolerance: 20))
    }

    @Test func dipToBlackAndWipe() async throws {
        let scene = try Scene("RenderKitTransitions")
        let red = try scene.importClip(try await scene.solid(.red, name: "red"))
        let green = try scene.importClip(try await scene.solid(.green, name: "green"))
        let left = try scene.add(red, at: 0, sourceIn: 0, count: 60)
        let right = try scene.add(green, at: 60, sourceIn: 30, count: 60)
        let id = try scene.transition(left, right, kind: "dipToBlack", frames: 30)
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .gesture)
        let mid = Pixels(try await renderer.frame(compiled, at: scene.frames(60), size: nil))
        #expect(near(mid.mean(mid.centerRect), (0, 0, 0), tolerance: 3), "dip to black is black at the midpoint")
        let quarter = Pixels(try await renderer.frame(compiled, at: scene.frames(52), size: nil))
        let q = quarter.mean(quarter.centerRect)
        #expect(q.0 > 100 && q.0 < 160 && q.1 < 4 && q.2 < 4, "red fading out: \(q)")

        try scene.builder.apply(.updateTransition(.init(transitionId: .id(id), kind: "wipe")))
        let update = try await renderer.update(compiled, to: scene.sequence, assets: scene.assets)
        #expect(!update.isStructural, "transition kind is an instruction change")
        let wipe = Pixels(try await renderer.frame(update.compiled, at: scene.frames(60), size: nil))
        let leftHalf = wipe.mean(CGRect(x: 40, y: 100, width: 240, height: 120))
        let rightHalf = wipe.mean(CGRect(x: 360, y: 100, width: 240, height: 120))
        #expect(near(leftHalf, (0, 255, 0), tolerance: 3), "the incoming clip is revealed from the left: \(leftHalf)")
        #expect(near(rightHalf, (255, 0, 0), tolerance: 3), "the outgoing clip remains on the right: \(rightHalf)")
    }

    @Test func transformOpacityAndEffects() async throws {
        let scene = try Scene("RenderKitTransform")
        let green = try scene.importClip(try await scene.solid(.green, name: "green"))
        let clip = try scene.add(green, at: 0, count: 60)
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .gesture)

        try scene.builder.apply(.setClipTransform(.init(clipId: .id(clip), after: .constant(Transform(scale: 0.5)))))
        let scaled = try await renderer.update(compiled, to: scene.sequence, assets: scene.assets)
        #expect(!scaled.isStructural)
        let half = Pixels(try await renderer.frame(scaled.compiled, at: scene.frames(10), size: nil))
        #expect(near(half.pixel(320, 180), (0, 255, 0), tolerance: 2), "centre still green")
        #expect(near(half.pixel(10, 10), (0, 0, 0), tolerance: 2), "corner is background")
        #expect(near(half.pixel(150, 180), (0, 0, 0), tolerance: 2), "outside the half-size frame")
        #expect(near(half.pixel(170, 180), (0, 255, 0), tolerance: 2), "inside it")

        // Move right by 200 px with the anchor at the left edge: the left 200 px are background.
        try scene.builder.apply(
            .setClipTransform(.init(clipId: .id(clip), after: .constant(Transform(x: 200, y: 0, scale: 1, anchorX: 0))))
        )
        let moved = try await renderer.update(scaled.compiled, to: scene.sequence, assets: scene.assets)
        let shifted = Pixels(try await renderer.frame(moved.compiled, at: scene.frames(10), size: nil))
        #expect(near(shifted.pixel(100, 180), (0, 0, 0), tolerance: 2))
        #expect(near(shifted.pixel(300, 180), (0, 255, 0), tolerance: 2))

        // Rotation by 90 degrees about the centre: the corners of a 640x360 frame become background.
        try scene.builder.apply(.setClipTransform(.init(clipId: .id(clip), after: .constant(Transform(rotation: 90)))))
        let rotated = try await renderer.update(moved.compiled, to: scene.sequence, assets: scene.assets)
        let turned = Pixels(try await renderer.frame(rotated.compiled, at: scene.frames(10), size: nil))
        #expect(near(turned.pixel(320, 180), (0, 255, 0), tolerance: 2))
        #expect(near(turned.pixel(20, 180), (0, 0, 0), tolerance: 2))
        #expect(near(turned.pixel(620, 180), (0, 0, 0), tolerance: 2))

        // Opacity 0.5 over black: half the code value in gamma mode, 188 in linear mode.
        try scene.builder.apply(.setClipTransform(.init(clipId: .id(clip), after: .constant(.identity))))
        try scene.builder.apply(.setClipOpacity(.init(clipId: .id(clip), after: .constant(0.5))))
        let faded = try await renderer.update(rotated.compiled, to: scene.sequence, assets: scene.assets)
        let dim = Pixels(try await renderer.frame(faded.compiled, at: scene.frames(10), size: nil))
        let dimMean = dim.mean(dim.centerRect)
        print("[colour] green at opacity 0.5 (gamma): \(dimMean)")
        #expect(near(dimMean, (0, 128, 0), tolerance: 3))
        let linear = scene.renderer(blendSpace: .linear)
        let linearCompiled = try await linear.compile(scene.sequence, assets: scene.assets, options: .gesture)
        let dimLinear = Pixels(try await linear.frame(linearCompiled, at: scene.frames(10), size: nil))
        print("[colour] green at opacity 0.5 (linear): \(dimLinear.mean(dimLinear.centerRect))")
        #expect(near(dimLinear.mean(dimLinear.centerRect), (0, 188, 0), tolerance: 3))

        // An invert effect turns green into magenta.
        try scene.builder.apply(.setClipOpacity(.init(clipId: .id(clip), after: .constant(1))))
        try scene.builder.apply(.addEffect(.init(clipId: .id(clip), kind: "invert", params: [:])))
        let inverted = try await renderer.update(faded.compiled, to: scene.sequence, assets: scene.assets)
        #expect(!inverted.isStructural)
        let magenta = Pixels(try await renderer.frame(inverted.compiled, at: scene.frames(10), size: nil))
        #expect(near(magenta.mean(magenta.centerRect), (255, 0, 255), tolerance: 2))

        // Frame grabs at a requested size.
        let small = try await renderer.frame(
            inverted.compiled, at: scene.frames(10), size: CGSize(width: 160, height: 90))
        #expect(small.width == 160 && small.height == 90)
    }

    @Test func offlineAssetRendersASlate() async throws {
        let scene = try Scene("RenderKitSlate")
        let green = try scene.importClip(try await scene.solid(.green, name: "green"))
        let missing = try scene.builder.importAsset(
            name: "missing.mov", duration: scene.frames(90), hasVideo: true, hasAudio: false,
            frameDuration: scene.frameDuration)
        try scene.add(green, at: 0, count: 30)
        try scene.add(missing, at: 30, count: 30)
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .gesture)
        #expect(compiled.renderPayload?.offlineAssets.map(\.displayName) == ["missing.mov"])
        let slate = Pixels(try await renderer.frame(compiled, at: scene.frames(45), size: nil))
        let mean = slate.mean(slate.centerRect)
        print("[slate] mean: \(mean)")
        #expect(mean.0 > 15 && mean.0 < 120 && abs(mean.0 - mean.2) < 20, "dark neutral slate, not black or green")
        var bright = 0
        for y in stride(from: 150, to: 210, by: 2) {
            for x in stride(from: 100, to: 540, by: 2) where slate.pixel(x, y).1 > 150 { bright += 1 }
        }
        #expect(bright > 20, "the slate carries legible text")
        let fine = Pixels(try await renderer.frame(compiled, at: scene.frames(10), size: nil))
        #expect(near(fine.mean(fine.centerRect), (0, 255, 0), tolerance: 2))
    }

    @Test func captionRendersInAllThreeConsumers() async throws {
        let scene = try Scene("RenderKitCaption")
        let red = try scene.importClip(try await scene.solid(.red, name: "red"))
        try scene.add(red, at: 0, count: 90)
        try scene.caption(
            "Hello there", at: 10, count: 60, words: [("Hello", 0, 30), ("there", 30, 60)],
            style: CaptionStyle(fontSize: 48, color: "#ffffff", backgroundColor: "#00000080"))
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .full)
        let band = captionBand(scene.size)
        let red255 = (255, 0, 0)

        // 1. frame()
        let grab = Pixels(try await renderer.frame(compiled, at: scene.frames(20), size: nil))
        let grabMean = grab.mean(band)
        print("[caption] frame() band mean: \(grabMean), background \(grab.mean(grab.centerRect))")
        #expect(!near(grabMean, red255, tolerance: 25), "caption pixels in the band")
        #expect(near(grab.mean(grab.centerRect), red255, tolerance: 2), "background untouched")
        let none = Pixels(try await renderer.frame(compiled, at: scene.frames(5), size: nil))
        #expect(near(none.mean(band), red255, tolerance: 2), "no caption before its start")
        // Word timing: the highlighted word moves, so the band differs between the two words.
        let second = Pixels(try await renderer.frame(compiled, at: scene.frames(50), size: nil))
        let firstWord = grab.mean(CGRect(x: 200, y: 288, width: 120, height: 54))
        let secondWord = second.mean(CGRect(x: 200, y: 288, width: 120, height: 54))
        print("[caption] first word region at word 1: \(firstWord), at word 2: \(secondWord)")
        #expect(!near(firstWord, secondWord, tolerance: 4), "the highlight moved off the first word")

        // 2. player item + AVPlayerItemVideoOutput
        let playerPixels = try #require(await playerFrame(renderer, compiled, at: scene.frames(20)))
        print("[caption] player band mean: \(playerPixels.mean(band))")
        #expect(!near(playerPixels.mean(band), red255, tolerance: 25))
        #expect(near(playerPixels.mean(playerPixels.centerRect), red255, tolerance: 3))

        // 3. export, then re-probe and grab from the flat file
        let url = scene.library.directory.file("caption.mov")
        let preset = ExportPreset(name: "test", container: .mov, videoCodec: .h264, videoQuality: .quality(1))
        let handle = await FakeJobRunner().submit(renderer.export(compiled, preset: preset, to: url))
        let outcome = try await handle.wait()
        #expect(outcome.urls == [url])
        let probe = try await RenderKit.probe(url)
        #expect(probe.codec == "avc1" && probe.width == 640 && probe.height == 360)
        let flat = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        flat.requestedTimeToleranceBefore = .zero
        flat.requestedTimeToleranceAfter = .zero
        let exported = Pixels(try await flat.image(at: CMTime(scene.frames(20))).image)
        print("[caption] export band mean: \(exported.mean(band))")
        #expect(!near(exported.mean(band), red255, tolerance: 25))
        #expect(near(exported.mean(exported.centerRect), red255, tolerance: 6))
        withExtendedLifetime(flat) {}
    }

    @Test func hdrSourcesCompileToHLGAndMixedSourcesToSDR() async throws {
        let scene = try Scene("RenderKitHDR")
        let hlg = try scene.importClip(try await scene.solid(.red, name: "hlg", seconds: 2, codec: .hevcHLG10))
        let sdr = try scene.importClip(try await scene.solid(.green, name: "sdr", seconds: 2))
        try scene.add(hlg, at: 0, count: 30)
        let renderer = scene.renderer()
        let hdrCompiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .gesture)
        let payload = try #require(hdrCompiled.renderPayload)
        #expect(payload.isHDR)
        #expect(payload.videoComposition.customVideoCompositorClass == HDRTimelineCompositor.self)
        #expect(payload.videoComposition.colorTransferFunction == AVVideoTransferFunction_ITU_R_2100_HLG)
        let image = try await renderer.frame(hdrCompiled, at: scene.frames(10), size: nil)
        let name = (image.colorSpace?.name).map { $0 as String } ?? ""
        print("[hdr] synthetic HLG frame: \(image.width)x\(image.height) \(image.bitsPerComponent) bpc cs=\(name)")
        #expect(name.contains("2100") || name.contains("HLG"))
        let px = Pixels(image)
        let mean = px.mean(px.centerRect)
        print("[hdr] synthetic HLG red through the compositor, converted to sRGB: \(mean)")
        #expect(mean.0 > 150 && mean.1 < 90 && mean.2 < 90, "red stays red: \(mean)")

        try scene.add(sdr, at: 30, count: 30)
        let mixed = try await renderer.compile(scene.sequence, assets: scene.assets, options: .gesture)
        let mixedPayload = try #require(mixed.renderPayload)
        #expect(!mixedPayload.isHDR, "one SDR source makes the whole composition SDR")
        #expect(mixedPayload.videoComposition.customVideoCompositorClass == TimelineCompositor.self)
        let toneMapped = Pixels(try await renderer.frame(mixed, at: scene.frames(10), size: nil))
        let tm = toneMapped.mean(toneMapped.centerRect)
        print("[hdr] HLG red conformed to SDR by the engine: \(tm)")
        #expect(tm.0 > 120 && tm.1 < 80 && tm.2 < 80)
        let green = Pixels(try await renderer.frame(mixed, at: scene.frames(40), size: nil))
        #expect(near(green.mean(green.centerRect), (0, 255, 0), tolerance: 2))
    }

    @Test func stillImagesAndGeneratedClipsRender() async throws {
        let scene = try Scene("RenderKitStill")
        let still = try TestMedia.still(
            .blue, size: CGSize(width: 320, height: 180), in: scene.library.media, name: "still")
        let image = try scene.builder.importAsset(
            name: "still.png", duration: scene.frames(300), hasVideo: true, hasAudio: false, frameDuration: nil)
        _ = still
        var assets = scene.assets
        assets[image]?.kind = .image
        try scene.add(image, at: 0, count: 30)
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: assets, options: .gesture)
        #expect(compiled.renderPayload?.offlineAssets.isEmpty == true)
        let px = Pixels(try await renderer.frame(compiled, at: scene.frames(10), size: nil))
        #expect(
            near(px.mean(px.centerRect), (0, 0, 255), tolerance: 3),
            "the still is scaled to fill: \(px.mean(px.centerRect))")
    }
}
