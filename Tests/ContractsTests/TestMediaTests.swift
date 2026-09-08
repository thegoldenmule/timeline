import AVFoundation
import ContractsTestSupport
import CoreGraphics
import Foundation
import ImageIO
import Testing

// MARK: - Helpers

/// BGRA8 pixel dump of a CGImage for assertions (top-left origin), as in spikes/compositor.
private struct Pixels {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(_ image: CGImage) {
        let w = image.width
        let h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            let ctx = CGContext(
                data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w
        height = h
        data = buf
    }

    func rgb(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(data[i + 2]), Int(data[i + 1]), Int(data[i]))
    }

    /// Mean colour over a rect, sampled every 4 px.
    func mean(_ r: CGRect) -> (r: Int, g: Int, b: Int) {
        var s = (0, 0, 0)
        var n = 0
        for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 4) {
            for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 4) {
                let c = rgb(x: x, y: y)
                s.0 += c.r
                s.1 += c.g
                s.2 += c.b
                n += 1
            }
        }
        return (s.0 / n, s.1 / n, s.2 / n)
    }
}

/// Two one-pole high-pass stages at about 200 Hz (48 kHz), enough to take the camera rumble out of a correlation.
private func highPassed(_ x: [Float]) -> [Float] {
    var y = x
    let a: Float = 0.974  // exp(-2 * pi * 200 / 48000)
    for _ in 0..<2 {
        var prevIn: Float = 0, prevOut: Float = 0
        for i in y.indices {
            let out = a * (prevOut + y[i] - prevIn)
            prevIn = y[i]
            prevOut = out
            y[i] = out
        }
    }
    return y
}

private func close(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int), tolerance: Int) -> Bool {
    abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
}

private func frame(of asset: AVURLAsset, at seconds: Double) async throws -> CGImage {
    // Keep the generator alive for the whole request: a temporary hangs (spikes/compositor gotcha 6).
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
    return result.image
}

private func frame(of asset: AVURLAsset, index: Int, frameDuration: CMTime) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let result = try await generator.image(at: CMTimeMultiply(frameDuration, multiplier: Int32(index)))
    return result.image
}

private func expectVideo(_ clip: TestMedia.Clip, tracks: (video: Int, audio: Int)) async throws -> AVURLAsset {
    #expect(FileManager.default.fileExists(atPath: clip.url.path))
    let asset = AVURLAsset(url: clip.url)
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    #expect(video.count == tracks.video)
    #expect(audio.count == tracks.audio)
    let d = clip.description
    let duration = try await asset.load(.duration).seconds
    let frameSeconds = d.frameDuration?.seconds ?? (1 / (d.sampleRate ?? 1))
    #expect(abs(duration - d.duration) <= frameSeconds, "duration \(duration) vs \(d.duration)")
    if let track = video.first, let size = d.size, let fps = d.fps {
        let natural = try await track.load(.naturalSize)
        #expect(natural == size)
        let rate = try await track.load(.nominalFrameRate)
        #expect(abs(Double(rate) - fps) < 0.05)
    }
    return asset
}

// MARK: - Tests

@Suite struct TestMediaDirectoryTests {
    @Test func directoryIsCreatedAndRemoved() throws {
        let dir = try TestMedia.Directory()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.url.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(dir.url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        try Data([1, 2, 3]).write(to: dir.file("x.bin"))
        dir.cleanup()
        #expect(!FileManager.default.fileExists(atPath: dir.url.path))
    }

    @Test func generatorsUseAFreshDirectoryWhenNoneIsGiven() async throws {
        let clip = try await TestMedia.tone(duration: 0.1)
        #expect(FileManager.default.fileExists(atPath: clip.url.path))
        try? FileManager.default.removeItem(at: clip.url.deletingLastPathComponent())
    }
}

@Suite struct TestMediaVideoTests {
    @Test(arguments: [TestMedia.VideoCodec.h264, .hevc, .proRes422])
    func solidColor(codec: TestMedia.VideoCodec) async throws {
        let dir = try TestMedia.Directory()
        let clip = try await TestMedia.solidColor(.red, duration: 1, codec: codec, in: dir.url)
        let asset = try await expectVideo(clip, tracks: (1, 0))
        #expect(clip.description.frameCount == 30)
        #expect(clip.description.color == .red)
        #expect(clip.description.videoCodec == codec)
        let px = Pixels(try await frame(of: asset, at: 0.5))
        #expect(px.width == 1280 && px.height == 720)
        let c = px.mean(CGRect(x: 100, y: 100, width: 1080, height: 520))
        #expect(close(c, (255, 0, 0), tolerance: 12), "\(c)")
    }

    @Test func solidColorHonoursSizeAndFrameDuration() async throws {
        let dir = try TestMedia.Directory()
        let fd = CMTime(value: 1001, timescale: 24000)
        let clip = try await TestMedia.solidColor(
            .green, size: CGSize(width: 640, height: 360), frameDuration: fd, duration: 1.5, in: dir.url)
        _ = try await expectVideo(clip, tracks: (1, 0))
        #expect(clip.description.frameCount == 36)
        #expect(clip.description.frameDuration == fd)
        #expect(abs((clip.description.fps ?? 0) - 23.976) < 0.001)
        #expect(abs(clip.description.duration - 36 * 1001 / 24000) < 1e-9)
    }

    @Test func oddSizesAreRejected() async throws {
        let dir = try TestMedia.Directory()
        await #expect(throws: TestMedia.Error.self) {
            try await TestMedia.solidColor(.red, size: CGSize(width: 641, height: 360), duration: 0.1, in: dir.url)
        }
    }

    /// 10-bit HEVC Main10 in a BT.2020/HLG container. If this machine's encoder rejects the configuration the
    /// test fails at generation time; keep the API and mark this `.disabled` rather than dropping HLG support.
    @Test func hevcHLG10IsTaggedAndDecodesRed() async throws {
        let dir = try TestMedia.Directory()
        let clip = try await TestMedia.solidColor(.red, duration: 1, codec: .hevcHLG10, in: dir.url)
        let asset = try await expectVideo(clip, tracks: (1, 0))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let format = try await track.load(.formatDescriptions)[0]
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        let primaries = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
        let transfer = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix)
        #expect(primaries as? String == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
        #expect(transfer as? String == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        #expect(matrix as? String == kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String)
        // hvcC byte 1: profile_space(2) tier(1) profile_idc(5); Main10 is profile 2.
        let atoms =
            CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        let hvcC = atoms?["hvcC"] as? Data
        #expect(
            hvcC.map { $0[$0.startIndex + 1] & 0x1F } == 2,
            "expected HEVC Main10, got \(String(describing: hvcC?.prefix(2)))")
        let px = Pixels(try await frame(of: asset, at: 0.5))
        let c = px.mean(CGRect(x: 100, y: 100, width: 1080, height: 520))
        #expect(c.r > 150 && c.g < 40 && c.b < 40, "\(c)")
    }

    @Test func colorBars() async throws {
        let dir = try TestMedia.Directory()
        let clip = try await TestMedia.colorBars(duration: 1, in: dir.url)
        let asset = try await expectVideo(clip, tracks: (1, 0))
        #expect(clip.description.bars == TestMedia.colorBarColors)
        let px = Pixels(try await frame(of: asset, at: 0.5))
        let barWidth = 1280 / TestMedia.colorBarColors.count
        for (i, bar) in TestMedia.colorBarColors.enumerated() {
            let c = px.mean(CGRect(x: i * barWidth + 20, y: 100, width: barWidth - 40, height: 520))
            let expected = bar.rgb8
            #expect(close(c, expected, tolerance: 16), "bar \(i): \(c) vs \(expected)")
        }
    }

    @Test func barcodeCounterDecodesFrameIndices() async throws {
        let dir = try TestMedia.Directory()
        let clip = try await TestMedia.barcodeCounter(duration: 2, in: dir.url)
        let asset = try await expectVideo(clip, tracks: (1, 0))
        #expect(clip.description.hasBarcode)
        let fd = clip.description.frameDuration!
        for index in [0, 1, 17, 44, 59] {
            let image = try await frame(of: asset, index: index, frameDuration: fd)
            #expect(TestMedia.decodeFrameIndex(from: image) == index)
        }
        // The background under the strip is still the requested colour.
        let px = Pixels(try await frame(of: asset, index: 3, frameDuration: fd))
        #expect(
            close(px.mean(CGRect(x: 100, y: 200, width: 1080, height: 400)), TestMedia.Color.gray.rgb8, tolerance: 12))
    }

    @Test func barcodeSurvivesScalingAndRejectsBlends() async throws {
        let dir = try TestMedia.Directory()
        let clip = try await TestMedia.barcodeCounter(
            size: CGSize(width: 320, height: 180), duration: 0.5, in: dir.url)
        let asset = try await expectVideo(clip, tracks: (1, 0))
        let fd = clip.description.frameDuration!
        let small = try await frame(of: asset, index: 9, frameDuration: fd)
        #expect(TestMedia.decodeFrameIndex(from: small) == 9)
        // Scale up 4x through a CGContext and decode again.
        let ctx = CGContext(
            data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: 1280, height: 720))
        #expect(TestMedia.decodeFrameIndex(from: ctx.makeImage()!) == 9)
        // A solid frame has no strip.
        let solid = try await TestMedia.solidColor(.gray, duration: 0.2, in: dir.url)
        let solidAsset = AVURLAsset(url: solid.url)
        #expect(TestMedia.decodeFrameIndex(from: try await frame(of: solidAsset, at: 0)) == nil)
    }

    @Test func videoWithToneMuxesBothTracks() async throws {
        let dir = try TestMedia.Directory()
        let clip = try await TestMedia.videoWithAudio(.tone(frequency: 880), duration: 2, in: dir.url)
        let asset = try await expectVideo(clip, tracks: (1, 1))
        #expect(clip.description.hasAudio && clip.description.hasVideo && clip.description.hasBarcode)
        #expect(clip.description.toneFrequency == 880)
        #expect(clip.description.audioCodec == .aac)
        let fd = clip.description.frameDuration!
        for index in [0, 10, 42] {
            let image = try await frame(of: asset, index: index, frameDuration: fd)
            #expect(TestMedia.decodeFrameIndex(from: image) == index)
        }
        let audio = try await TestMedia.readAudio(url: clip.url)
        #expect(audio.sampleRate == 48000)
        #expect(audio.channels == 1)
        #expect(abs(Double(audio.frameCount) / 48000 - 2) < 0.1)
        #expect(audio.rms > 0.2)
        #expect(abs(audio.zeroCrossingFrequency - 880) < 20)
    }

    @Test func videoWithTransientsInPCM() async throws {
        let dir = try TestMedia.Directory()
        let times = [0.25, 0.5, 1.0]
        let clip = try await TestMedia.videoWithAudio(
            .transients(clickTimes: times), duration: 1.5, audioCodec: .pcm, in: dir.url)
        _ = try await expectVideo(clip, tracks: (1, 1))
        #expect(clip.description.clickTimes == times)
        #expect(clip.description.clickSamples == [12000, 24000, 48000])
        let audio = try await TestMedia.readAudio(url: clip.url)
        let x = audio.channel(0)
        for s in clip.description.clickSamples {
            #expect(x[s] > 0.8, "click at \(s): \(x[s])")
            #expect(abs(x[s - 1]) < 0.01)
        }
    }

    @Test func generationIsFast() async throws {
        let dir = try TestMedia.Directory()
        let start = ContinuousClock.now
        _ = try await TestMedia.barcodeCounter(duration: 3, in: dir.url)
        let video = ContinuousClock.now - start
        _ = try await TestMedia.tone(duration: 3, in: dir.url)
        let audio = ContinuousClock.now - start - video
        // "Well under a second" in release; a debug build on a busy CI box gets headroom.
        #expect(video < .seconds(2), "video took \(video)")
        #expect(audio < .seconds(1), "audio took \(audio)")
    }
}

@Suite struct TestMediaAudioTests {
    @Test func pcmToneIsAWaveWithTheRightFrequency() async throws {
        let dir = try TestMedia.Directory()
        let clip = try await TestMedia.tone(frequency: 440, duration: 2, in: dir.url)
        #expect(clip.url.pathExtension == "caf")
        _ = try await expectVideo(clip, tracks: (0, 1))
        #expect(clip.description.duration == 2)
        #expect(clip.description.sampleRate == 48000)
        #expect(clip.description.channels == 1)
        let audio = try await TestMedia.readAudio(url: clip.url)
        #expect(audio.sampleRate == 48000)
        #expect(audio.frameCount == 96000)
        #expect(abs(audio.rms - TestMedia.toneAmplitude / Float(2).squareRoot()) < 0.005)
        #expect(abs(audio.zeroCrossingFrequency - 440) < 1)
        // Float PCM round-trips exactly.
        #expect(audio.samples[0] == 0)
        #expect(abs(Double(audio.samples[1]) - Double(TestMedia.toneAmplitude) * sin(2 * .pi * 440 / 48000)) < 1e-6)
    }

    @Test func pcm16ToneIsAWav() async throws {
        let dir = try TestMedia.Directory()
        let clip = try await TestMedia.tone(frequency: 440, duration: 1, codec: .pcm16, in: dir.url)
        #expect(clip.url.pathExtension == "wav")
        _ = try await expectVideo(clip, tracks: (0, 1))
        let audio = try await TestMedia.readAudio(url: clip.url)
        #expect(audio.frameCount == 48000)
        #expect(abs(audio.rms - TestMedia.toneAmplitude / Float(2).squareRoot()) < 0.005)
        #expect(abs(audio.zeroCrossingFrequency - 440) < 1)
    }

    @Test func aacStereoTone() async throws {
        let dir = try TestMedia.Directory()
        let clip = try await TestMedia.tone(
            frequency: 1000, sampleRate: 44100, duration: 1, channels: 2, codec: .aac, in: dir.url)
        #expect(clip.url.pathExtension == "m4a")
        _ = try await expectVideo(clip, tracks: (0, 1))
        let audio = try await TestMedia.readAudio(url: clip.url)
        #expect(audio.sampleRate == 44100)
        #expect(audio.channels == 2)
        #expect(audio.rms > 0.25)
        #expect(abs(audio.zeroCrossingFrequency - 1000) < 30)
    }

    @Test func transientsLandOnTheirSamples() async throws {
        let dir = try TestMedia.Directory()
        let times = [0.1, 0.33333, 0.75, 1.9]
        let clip = try await TestMedia.transients(clickTimes: times, duration: 2, in: dir.url)
        _ = try await expectVideo(clip, tracks: (0, 1))
        #expect(clip.description.clickTimes == times)
        #expect(clip.description.clickSamples == times.map { Int(($0 * 48000).rounded()) })
        let x = try await TestMedia.readAudio(url: clip.url).channel(0)
        // Onsets: a sample above half scale preceded by near silence. Exactly the ground truth, nothing else.
        var onsets: [Int] = []
        for i in 1..<x.count where abs(x[i]) > 0.5 && abs(x[i - 1]) < 0.05 { onsets.append(i) }
        #expect(onsets == clip.description.clickSamples)
        for s in clip.description.clickSamples { #expect(abs(x[s] - TestMedia.clickAmplitude) < 1e-6) }
        // Silence elsewhere: 10 ms after a click the burst is gone.
        #expect(abs(x[clip.description.clickSamples[0] + 480]) < 1e-3)
    }

    @Test func alignmentPairCarriesGroundTruth() async throws {
        let dir = try TestMedia.Directory()
        let pair = try await TestMedia.alignmentPair(
            seed: 3, cameraDuration: 12, renderDuration: 3, offsetSeconds: 4.5, driftPPM: 23, snrDB: 20,
            in: dir.url)
        _ = try await expectVideo(pair.camera, tracks: (0, 1))
        _ = try await expectVideo(pair.render, tracks: (0, 1))
        #expect(pair.truth.offsetSeconds == 4.5)
        #expect(pair.truth.offsetSamples == 4.5 * 48000)
        #expect(pair.truth.driftPPM == 23)
        #expect(pair.truth.snrDB == 20)
        #expect(pair.truth.seed == 3)
        #expect(pair.camera.description.alignment == pair.truth)
        #expect(pair.render.description.alignment == pair.truth)
        #expect(pair.camera.description.sampleRate == 48000)
        #expect(pair.render.description.sampleRate == 44100)
        #expect(abs(pair.camera.description.duration - 12) < 1e-6)
        // The render carries a 0.1 s reverb tail and was synthesised on a clock 23 ppm fast.
        #expect(abs(pair.render.description.duration - 3.1) < 0.001)

        let camera = try await TestMedia.readAudio(url: pair.camera.url)
        let render = try await TestMedia.readAudio(url: pair.render.url)
        #expect(camera.frameCount == 12 * 48000)
        #expect(abs(Double(render.rms) - 0.1) < 0.01)
        #expect(camera.rms > 0.01)
    }

    /// With no drift and matched sample rates, the render correlates with the camera at exactly the ground-truth
    /// lag and nowhere nearby (the reverb, EQ, bass, rumble, and compressor only dampen the peak).
    @Test func alignmentPairPerformanceSitsAtTheOffset() async throws {
        let dir = try TestMedia.Directory()
        let pair = try await TestMedia.alignmentPair(
            seed: 5, cameraDuration: 10, renderDuration: 3, offsetSeconds: 4.25, driftPPM: 0, snrDB: 10,
            renderSampleRate: 48000, in: dir.url)
        let camera = highPassed(try await TestMedia.readAudio(url: pair.camera.url).channel(0))
        let render = highPassed(try await TestMedia.readAudio(url: pair.render.url).channel(0))
        let n = 3 * 48000
        func ncc(lag: Int) -> Double {
            var dot = 0.0, ea = 0.0, eb = 0.0
            for i in 0..<n {
                let a = Double(camera[lag + i]), b = Double(render[i])
                dot += a * b
                ea += a * a
                eb += b * b
            }
            return dot / (ea * eb).squareRoot()
        }
        let truth = Int(pair.truth.offsetSamples)
        let atTruth = ncc(lag: truth)
        let near = [-480, -48, -3, 3, 48, 480].map { ncc(lag: truth + $0) }
        let far = [-24000, -4800, -1200, 1200, 4800, 24000].map { ncc(lag: truth + $0) }
        #expect(atTruth > 0.3, "\(atTruth)")
        // The true lag is the local maximum, and far from it the correlation collapses.
        #expect(near.allSatisfy { $0 < atTruth }, "at truth \(atTruth), near \(near)")
        #expect(far.allSatisfy { $0 < atTruth / 3 }, "at truth \(atTruth), far \(far)")
    }

    @Test func alignmentPairIsDeterministic() async throws {
        let dir = try TestMedia.Directory()
        let a = try await TestMedia.alignmentPair(
            seed: 9, cameraDuration: 4, renderDuration: 1, offsetSeconds: 1, in: dir.url)
        let b = try await TestMedia.alignmentPair(
            seed: 9, cameraDuration: 4, renderDuration: 1, offsetSeconds: 1, in: dir.url)
        let ra = try await TestMedia.readAudio(url: a.render.url).samples
        let rb = try await TestMedia.readAudio(url: b.render.url).samples
        #expect(ra == rb)
    }

    @Test func alignmentPairRejectsARenderOutsideTheCamera() async throws {
        await #expect(throws: TestMedia.Error.self) {
            try await TestMedia.alignmentPair(cameraDuration: 3, renderDuration: 2, offsetSeconds: 2)
        }
    }
}

@Suite struct TestMediaStillTests {
    @Test func stillIsASolidPNG() throws {
        let dir = try TestMedia.Directory()
        let clip = try TestMedia.still(.blue, size: CGSize(width: 64, height: 32), in: dir.url)
        #expect(clip.url.pathExtension == "png")
        #expect(clip.description.size == CGSize(width: 64, height: 32))
        #expect(clip.description.color == .blue)
        #expect(!clip.description.hasVideo && !clip.description.hasAudio)
        let source = try #require(CGImageSourceCreateWithURL(clip.url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as? String == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64 && image.height == 32)
        let px = Pixels(image)
        #expect(px.rgb(x: 5, y: 5) == (0, 0, 255))
        #expect(px.rgb(x: 60, y: 30) == (0, 0, 255))
    }
}
