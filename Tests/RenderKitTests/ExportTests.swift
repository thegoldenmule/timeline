import AVFoundation
import Contracts
import ContractsTestSupport
import Foundation
import RenderKit
import Testing
import TimelineCore

/// Export as a `Job` through `AVAssetExportSession`, verified by `RenderKit.probe`.
@Suite struct ExportTests {
    @Test func fixtureExportPassesProbeAssertions() async throws {
        let lib = try await FixtureLibrary.get()
        let b = try Fixtures.builder("three-clips")
        let renderer = AVFoundationRenderer(layout: lib.layout)
        let compiled = try await renderer.compile(b.sequence, assets: b.project.assets, options: .full)
        let dir = try TestMedia.Directory(prefix: "RenderKitExport")
        let url = dir.file("three-clips.mp4")
        let job = renderer.export(compiled, preset: .h264_1080p, to: url)
        #expect(job.kind == .export && job.memoryClass == .medium)
        let runner = FakeJobRunner()
        let t0 = ContinuousClock.now
        let handle = await runner.submit(job)
        var fractions: [Double] = []
        for await progress in handle.progress {
            if let f = progress.fraction { fractions.append(f) }
        }
        let outcome = try await handle.wait()
        print("[export] three-clips as H.264 1080p: \(fmt(ms(t0))) ms, progress \(fractions.map { fmt($0 * 100) })")
        #expect(outcome.urls == [url])
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted(), "progress never goes backwards")
        let receipt = try #require(try outcome.payload(as: ExportReceipt.self))
        #expect(receipt.preset == .h264_1080p)
        #expect(receipt.sequenceId == b.sequenceId)
        #expect(receipt.outputURL == url)
        #expect(abs(receipt.durationSeconds - 11.25) < 0.001)
        #expect(receipt.finishedAt >= receipt.startedAt)

        let probe = try await RenderKit.probe(url)
        print("[export] probe: \(probe)")
        #expect(probe.codec == "avc1")
        #expect(probe.width == 1920 && probe.height == 1080)
        #expect(probe.colorPrimaries == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String))
        #expect(probe.transferFunction == (kCVImageBufferTransferFunction_ITU_R_709_2 as String))
        #expect(probe.yCbCrMatrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String))
        #expect(!probe.isHDR)
        #expect(probe.hasAudio && probe.audioCodec == "aac ")
        let frame = Fixtures.frameDuration.seconds
        #expect(abs(probe.duration.seconds - 11.25) <= frame, "duration within one frame: \(probe.duration.seconds)")
        #expect(probe.tracks.filter { $0.kind == "video" }.count == 1)

        // The exported picture is the composition: green screen-recording clip at frame 100 (4.17 s).
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let px = Pixels(try await generator.image(at: CMTime(Fixtures.frames(100))).image)
        #expect(near(px.mean(px.centerRect), (0, 255, 0), tolerance: 8), "\(px.mean(px.centerRect))")
        withExtendedLifetime(generator) {}
    }

    @Test func hlgSourcesExportAsHEVCHLGOrToneMapped() async throws {
        let scene = try Scene("RenderKitExportHDR")
        let hlg = try scene.importClip(try await scene.solid(.red, name: "hlg", seconds: 2, codec: .hevcHLG10))
        try scene.add(hlg, at: 0, count: 45)
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .full)
        #expect(compiled.renderPayload?.isHDR == true)

        let hdrPreset = ExportPreset(
            name: "HEVC HLG", container: .mov, videoCodec: .hevcHLG10, videoQuality: .quality(1), hdr: .preserve)
        let hdrURL = scene.library.directory.file("hlg.mov")
        let t0 = ContinuousClock.now
        let outcome = try await FakeJobRunner().submit(renderer.export(compiled, preset: hdrPreset, to: hdrURL)).wait()
        let probe = try await RenderKit.probe(hdrURL)
        print(
            "[export] HLG export: \(fmt(ms(t0))) ms; probe codec=\(probe.codec ?? "") transfer=\(probe.transferFunction ?? "") primaries=\(probe.colorPrimaries ?? "") bits=\(probe.bitDepth ?? 0) warnings=\(outcome.warnings)"
        )
        #expect(probe.codec == "hvc1")
        #expect(probe.isHDR)
        #expect(probe.transferFunction == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String))
        #expect(probe.colorPrimaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String))
        #expect(probe.bitDepth == 10)
        #expect(probe.width == 640 && probe.height == 360)
        #expect(abs(probe.duration.seconds - 1.5) <= 1.0 / 30)

        let sdrPreset = ExportPreset(
            name: "HEVC SDR", container: .mp4, videoCodec: .hevc, size: .fixed(width: 320, height: 180),
            videoQuality: .quality(1), hdr: .toneMapToSDR)
        let sdrURL = scene.library.directory.file("sdr.mp4")
        _ = try await FakeJobRunner().submit(renderer.export(compiled, preset: sdrPreset, to: sdrURL)).wait()
        let sdr = try await RenderKit.probe(sdrURL)
        print(
            "[export] tone-mapped export probe: codec=\(sdr.codec ?? "") transfer=\(sdr.transferFunction ?? "") \(sdr.width ?? 0)x\(sdr.height ?? 0)"
        )
        #expect(sdr.codec == "hvc1" && !sdr.isHDR)
        #expect(sdr.transferFunction == (kCVImageBufferTransferFunction_ITU_R_709_2 as String))
        #expect(sdr.width == 320 && sdr.height == 180)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sdrURL))
        let px = Pixels(try await generator.image(at: CMTime(value: 1, timescale: 2)).image)
        let mean = px.mean(px.centerRect)
        print("[export] tone-mapped red: \(mean)")
        #expect(mean.0 > 120 && mean.1 < 90 && mean.2 < 90)
        withExtendedLifetime(generator) {}
    }

    @Test func proResWritesLPCMAndReportsUnhonouredFields() async throws {
        let scene = try Scene("RenderKitExportProRes")
        let av = try scene.importClip(try await scene.barcodeWithAudio(.blue, name: "av", seconds: 2))
        try scene.add(av, at: 0, count: 30, link: .auto)
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .full)
        #expect(compiled.hasAudio)
        var preset = ExportPreset.proRes
        preset.container = .mp4  // not valid for ProRes: expect a warning and a .mov file type
        preset.loudnessTargetLUFS = -14
        let url = scene.library.directory.file("prores.mov")
        let outcome = try await FakeJobRunner().submit(renderer.export(compiled, preset: preset, to: url)).wait()
        let probe = try await RenderKit.probe(url)
        print(
            "[export] ProRes probe codec=\(probe.codec ?? "") audio=\(probe.audioCodec ?? "") warnings=\(outcome.warnings)"
        )
        #expect(probe.codec == "apcn")
        #expect(probe.hasAudio && probe.audioCodec == "lpcm")
        #expect(outcome.warnings.contains { $0.contains("QuickTime container") })
        #expect(outcome.warnings.contains { $0.contains("Loudness") })
        let settings = ExportSettings.resolve(preset, for: try #require(compiled.renderPayload))
        #expect(settings.presetName == AVAssetExportPresetAppleProRes422LPCM && settings.fileType == .mov)
        let h264 = ExportSettings.resolve(.reel9x16, for: try #require(compiled.renderPayload))
        #expect(h264.presetName == AVAssetExportPresetHighestQuality && h264.fileType == .mp4)
        #expect(h264.renderSize == CGSize(width: 1080, height: 1920) && !h264.hdr)
        #expect(h264.warnings.contains { $0.contains("Bitrate") })
    }

    @Test func offlineAssetsWarnAndCancellationStops() async throws {
        let lib = try await FixtureLibrary.get()
        let b = try Fixtures.builder("three-clips")
        var assets = b.project.assets
        let screen = try #require(assets.values.first { $0.displayName == "Screen Recording.mov" })
        assets[screen.id]?.offline = true
        let renderer = AVFoundationRenderer(layout: lib.layout)
        let compiled = try await renderer.compile(b.sequence, assets: assets, options: .full)
        let dir = try TestMedia.Directory(prefix: "RenderKitExportCancel")

        let slow = dir.file("slate.mov")
        let outcome = try await FakeJobRunner().submit(renderer.export(compiled, preset: .proRes, to: slow)).wait()
        #expect(outcome.warnings.contains { $0.contains("Offline asset") && $0.contains("Screen Recording.mov") })
        let receipt = try #require(try outcome.payload(as: ExportReceipt.self))
        #expect(receipt.warnings == outcome.warnings)

        let url = dir.file("cancelled.mov")
        let handle = await FakeJobRunner().submit(renderer.export(compiled, preset: .proRes, to: url))
        try await Task.sleep(for: .milliseconds(150))
        handle.cancel()
        await #expect(throws: CancellationError.self) { try await handle.wait() }
        try await Task.sleep(for: .milliseconds(200))
        let exists = FileManager.default.fileExists(atPath: url.path)
        print("[export] cancelled export left a file: \(exists)")
        if exists {
            let probe = try await RenderKit.probe(url)
            #expect(probe.duration.seconds < 11, "a cancelled export never completes")
        }
    }
}
