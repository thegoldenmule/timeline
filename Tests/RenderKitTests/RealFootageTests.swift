import AVFoundation
import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import RenderKit
import Testing
import TimelineCore

/// Milestone 1 (implementation-plan.md, RenderKit row): the real iPhone footage in ~/Downloads renders
/// portrait, HLG-preserved, colour-checked, with the stereo AAC track and not the APAC track.
@Suite struct RealFootageTests {
    static let footage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Downloads/IMG_1575.MOV")
    static var available: Bool { FileManager.default.fileExists(atPath: footage.path) }

    /// A library root whose `IMG_1575.MOV` is a symlink to the real file, so the fixture-style `libraryPath`
    /// resolves without copying 2.6 GB.
    static func library() throws -> ScratchLibrary {
        let lib = try ScratchLibrary(prefix: "RenderKitFootage")
        try FileManager.default.createSymbolicLink(
            at: lib.media.appendingPathComponent("IMG_1575.MOV"), withDestinationURL: footage)
        return lib
    }

    @Test(.enabled(if: available)) func portraitHLGWithStereoAAC() async throws {
        let probe = try await RenderKit.probe(RealFootageTests.footage)
        print("[footage] probe: \(probe)")
        #expect(probe.codec == "hvc1")
        #expect(probe.naturalWidth == 3840 && probe.naturalHeight == 2160)
        #expect(probe.width == 2160 && probe.height == 3840, "display size follows the display matrix")
        #expect(abs(probe.rotation) == 90)
        #expect(probe.isHDR)
        #expect(probe.transferFunction == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String))
        #expect(probe.tracks.contains { $0.kind == "audio" && $0.codec == "apac" }, "the spatial track is present")

        let lib = try RealFootageTests.library()
        let fd = RationalTime(1001, 30000)
        let b = ProjectBuilder()
        try b.createProject(name: "Footage", frameDuration: fd, width: 2160, height: 3840)
        let v = try b.addTracks(.video, count: 1)[0]
        _ = try b.addTracks(.audio, count: 1)[0]
        let asset = try b.importAsset(
            name: "IMG_1575.MOV", duration: probe.duration, hasVideo: true, hasAudio: true, frameDuration: fd)
        try b.addClip(
            track: v, asset: asset, at: .zero, sourceIn: .zero, sourceOut: RationalTime.frames(90, of: fd), link: .auto)
        #expect(b.audioTracks[0].clips.count == 1, "link: .auto created the audio clip")

        let renderer = AVFoundationRenderer(layout: lib.layout)
        let t0 = ContinuousClock.now
        let compiled = try await renderer.compile(b.sequence, assets: b.project.assets, options: .full)
        print("[footage] compile: \(fmt(ms(t0))) ms")
        let payload = try #require(compiled.renderPayload)
        #expect(payload.isHDR, "all sources HLG: the composition is HDR")
        #expect(payload.renderSize == CGSize(width: 2160, height: 3840))
        #expect(payload.videoComposition.colorTransferFunction == AVVideoTransferFunction_ITU_R_2100_HLG)
        #expect(payload.videoComposition.colorPrimaries == AVVideoColorPrimaries_ITU_R_2020)
        #expect(compiled.hasAudio)

        // Audio: the stereo AAC track, never the 4-channel APAC track.
        let source = try #require(payload.source(for: asset))
        #expect(source.audioFormatID == kAudioFormatMPEG4AAC)
        #expect(source.audioChannels == 2)
        let apac = try #require(source.audioCandidates.first { $0.formatID == kAudioFormatAPAC })
        #expect(apac.channels == 4)
        let audioTrack = try #require(payload.audioTracks.first)
        let segment = try #require(audioTrack.segments.first)
        #expect(segment.sourceTrackID == source.audioTrackID)
        #expect(segment.sourceTrackID != apac.trackID)
        let compositionAudio = payload.composition.tracks(withMediaType: .audio)
        #expect(compositionAudio.count == 1)
        if let format = compositionAudio.first?.formatDescriptions.first as! CMFormatDescription?,
            let asbd = format.audioStreamBasicDescription
        {
            #expect(asbd.mFormatID == kAudioFormatMPEG4AAC && asbd.mChannelsPerFrame == 2)
        }

        // Frame: portrait, HLG preserved, plausible colour.
        let t1 = ContinuousClock.now
        let image = try await renderer.frame(compiled, at: RationalTime(1, 1), size: nil)
        print(
            "[footage] frame: \(fmt(ms(t1))) ms, \(image.width)x\(image.height), \(image.bitsPerComponent) bpc, cs=\(image.colorSpace?.name.map { $0 as String } ?? "nil")"
        )
        #expect(image.width == 2160 && image.height == 3840)
        let colorSpaceName = (image.colorSpace?.name).map { $0 as String } ?? ""
        #expect(
            colorSpaceName.contains("2100") || colorSpaceName.contains("HLG"), "HLG colour space, got \(colorSpaceName)"
        )
        let pixels = Pixels(image)
        let mean = pixels.mean(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        print("[footage] mean RGB: \(mean)")
        let luma = (mean.0 * 299 + mean.1 * 587 + mean.2 * 114) / 1000
        #expect(luma > 8, "not black")
        #expect(luma < 248, "not blown out")
        #expect((3...252).contains(mean.0) && (3...252).contains(mean.1) && (3...252).contains(mean.2))

        // A second grab, half a second later, must differ from a solid frame: real content, not a slate.
        let later = Pixels(
            try await renderer.frame(compiled, at: RationalTime(3, 2), size: CGSize(width: 540, height: 960)))
        #expect(later.width == 540 && later.height == 960)
        var distinct = 0
        for y in stride(from: 0, to: later.height, by: 40) {
            for x in stride(from: 0, to: later.width, by: 40) where !near(later.pixel(x, y), mean, tolerance: 6) {
                distinct += 1
            }
        }
        #expect(distinct > 10, "the frame has structure, not a flat slate")
    }

    @Test(.enabled(if: available)) @MainActor func playerItemPlaysPortraitHLG() async throws {
        let probe = try await RenderKit.probe(RealFootageTests.footage)
        let lib = try RealFootageTests.library()
        let fd = RationalTime(1001, 30000)
        let b = ProjectBuilder()
        try b.createProject(name: "Footage", frameDuration: fd, width: 2160, height: 3840)
        let v = try b.addTracks(.video, count: 1)[0]
        _ = try b.addTracks(.audio, count: 1)
        let asset = try b.importAsset(name: "IMG_1575.MOV", duration: probe.duration, frameDuration: fd)
        try b.addClip(
            track: v, asset: asset, at: .zero, sourceIn: .zero, sourceOut: RationalTime.frames(60, of: fd), link: .auto)
        let renderer = AVFoundationRenderer(layout: lib.layout)
        let compiled = try await renderer.compile(b.sequence, assets: b.project.assets, options: .full)
        let item = renderer.playerItem(for: compiled)
        #expect(item.seekingWaitsForVideoCompositionRendering)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        // A second output in the compositor's native 10-bit format proves the HLG buffers are 10-bit end to end.
        let tenBit = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ])
        item.add(tenBit)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let t0 = ContinuousClock.now
        #expect(await waitUntilReady(item), "status \(item.status.rawValue) \(String(describing: item.error))")
        print("[footage] readyToPlay: \(fmt(ms(t0))) ms")
        await item.seek(to: CMTime(value: 1, timescale: 2), toleranceBefore: .zero, toleranceAfter: .zero)
        var buffer: CVPixelBuffer?
        let deadline = ContinuousClock.now + .seconds(10)
        while buffer == nil, ContinuousClock.now < deadline {
            let now = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: now) {
                buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil)
            } else {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let pb = try #require(buffer)
        let hdrBuffer = try #require(tenBit.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil))
        #expect(CVPixelBufferGetPixelFormatType(hdrBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let transfer = CVBufferCopyAttachment(hdrBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let primaries = CVBufferCopyAttachment(hdrBuffer, kCVImageBufferColorPrimariesKey, nil) as? String
        print(
            "[footage] player 10-bit buffer: \(RenderKit.fourCC(CVPixelBufferGetPixelFormatType(hdrBuffer))) transfer=\(transfer ?? "nil") primaries=\(primaries ?? "nil")"
        )
        #expect(transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String))
        #expect(primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String))
        #expect(CVPixelBufferGetWidth(pb) == 2160 && CVPixelBufferGetHeight(pb) == 3840)
        let px = Pixels(pb)
        let mean = px.mean(CGRect(x: 0, y: 0, width: px.width, height: px.height))
        print("[footage] player frame mean RGB: \(mean)")
        #expect(mean.0 + mean.1 + mean.2 > 30, "not black")
    }
}

func ms(_ start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
