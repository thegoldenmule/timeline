import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import Testing
import TimelineCore

@testable import MediaKit

@Suite struct ProviderTests {
    /// A still has no video track, so the sprite-sheet path produces nothing for it and the library
    /// panel drew a placeholder symbol where the picture should have been.
    @Test func aStillImageGetsItsOwnPictureBack() async throws {
        let lib = try TestLibrary()
        let still = try TestMedia.still(.blue, size: CGSize(width: 800, height: 400), in: lib.media.url, name: "card")
        let imported = try await lib.library.importAsset(url: still.url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let provider = AVThumbnailProvider(cache: lib.cache, clock: FixedClock())

        let one = try await provider.thumbnail(for: media, at: .zero, height: 36)
        let thumbnail = try #require(one)
        #expect(thumbnail.image.height == 36)
        #expect(thumbnail.image.width == 72, "the still's 2:1 shape survives the scale")

        // A filmstrip over a still is the same picture at each requested time, not an empty array.
        let strip = try await provider.filmstrip(
            for: media, range: RationalTime.zero...RationalTime(2, 1), count: 4, height: 36)
        #expect(strip.count == 4)
        #expect(strip.allSatisfy { $0.image.height == 36 })
        #expect(strip.first?.time == .zero)
        #expect(strip.last?.time == RationalTime(2, 1))
        #expect(provider.statistics.sheetsGenerated == 0, "a still never reaches the sheet path")
    }

    /// A poster is one seek and one small JPEG. It used to be `filmstrip(count: 1)`, which reads a
    /// zero-length range as the ladder's densest rung and renders a whole 4 fps sheet for it.
    @Test func aPosterIsOneSeekAndIsCachedOnItsOwn() async throws {
        let lib = try TestLibrary()
        let clip = try await TestMedia.barcodeCounter(duration: 30, in: lib.media.url, name: "poster")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let provider = AVThumbnailProvider(cache: lib.cache, clock: FixedClock())

        let first = try #require(try await provider.thumbnail(for: media, at: RationalTime(1, 1), height: 128))
        #expect(first.image.height == 128)
        #expect(provider.statistics.postersGenerated == 1)
        #expect(provider.statistics.sheetsGenerated == 0, "no sheet is built for one frame")

        // A second provider over the same cache reads the JPEG back rather than seeking again.
        let again = AVThumbnailProvider(cache: lib.cache, clock: FixedClock())
        let second = try #require(try await again.thumbnail(for: media, at: RationalTime(1, 1), height: 128))
        #expect(second.image.height == 128)
        #expect(again.statistics.postersLoaded == 1)
        #expect(again.statistics.postersGenerated == 0)
        #expect(again.statistics.sheetsGenerated == 0)

        // A different height is a different poster, not a reuse of the first.
        _ = try await again.thumbnail(for: media, at: RationalTime(1, 1), height: 228)
        #expect(again.statistics.postersGenerated == 1)

        // The filmstrip path still builds sheets; the two do not collide in the artifact table.
        _ = try await again.filmstrip(for: media, range: .zero...RationalTime(4, 1), count: 8, height: 128)
        #expect(again.statistics.sheetsGenerated == 1)
    }

    @Test func filmstripCountHeightAndCacheHit() async throws {
        let lib = try TestLibrary()
        let clip = try await TestMedia.barcodeCounter(duration: 4, in: lib.media.url, name: "strip")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let provider = AVThumbnailProvider(cache: lib.cache, clock: FixedClock())
        let range = RationalTime.zero...RationalTime(4, 1)

        let t0 = ContinuousClock.now
        let first = try await provider.filmstrip(for: media, range: range, count: 8, height: 90)
        let firstSeconds = elapsed(t0)
        #expect(first.count == 8)
        #expect(first.allSatisfy { $0.image.height == 90 })
        #expect(first.allSatisfy { $0.image.width == 160 })
        #expect(first.first?.time == .zero)
        #expect(first.last?.time == RationalTime(4, 1))
        #expect(provider.statistics.sheetsGenerated == 1)
        let decoded = first.compactMap { TestMedia.decodeFrameIndex(from: $0.image) }
        #expect(decoded.count >= 2, "thumbnails carry the barcode: \(decoded)")
        #expect(decoded == decoded.sorted())

        // Second request at the same zoom: served from the memoised sheet, no generation.
        let t1 = ContinuousClock.now
        let second = try await provider.filmstrip(for: media, range: range, count: 8, height: 90)
        let secondSeconds = elapsed(t1)
        #expect(second.count == 8)
        #expect(provider.statistics.sheetsGenerated == 1)
        #expect(provider.statistics.sheetsMemoized >= 8)

        // A fresh provider over the same cache loads the sheet from disk.
        let cold = AVThumbnailProvider(cache: lib.cache, clock: FixedClock())
        let t2 = ContinuousClock.now
        let third = try await cold.filmstrip(for: media, range: range, count: 8, height: 90)
        let thirdSeconds = elapsed(t2)
        #expect(third.count == 8)
        #expect(cold.statistics.sheetsGenerated == 0)
        #expect(cold.statistics.sheetsLoaded == 1)
        print(
            "filmstrip 8 frames: generate \(String(format: "%.3f", firstSeconds)) s, memoized "
                + "\(String(format: "%.4f", secondSeconds)) s, from disk \(String(format: "%.3f", thirdSeconds)) s")
        #expect(secondSeconds < firstSeconds)

        // The sheet is a content-addressed artifact under the asset's hash.
        let artifacts = try lib.cache.artifacts(contentHash: imported.asset.contentHash, kind: .thumbnails)
        #expect(artifacts.count == 1)
        let sheetURL = lib.cache.url(for: artifacts[0])
        #expect(sheetURL.path.contains("/sha256/"))
        #expect(sheetURL.lastPathComponent.hasPrefix("sheet-"))
        #expect(FileManager.default.fileExists(atPath: sheetURL.path))

        // A different zoom and a single-frame thumbnail.
        let dense = try await provider.filmstrip(for: media, range: .zero...RationalTime(1, 1), count: 4, height: 64)
        #expect(dense.count == 4 && dense.allSatisfy { $0.image.height == 64 })
        #expect(provider.statistics.sheetsGenerated == 2)
        let single = try await provider.thumbnail(for: media, at: RationalTime(2, 1), height: 128)
        #expect(single?.image.height == 128)
    }

    @Test func peaksAtRequestedZoomAndCacheHit() async throws {
        let lib = try TestLibrary()
        let clip = try await TestMedia.tone(frequency: 440, duration: 2, in: lib.media.url, name: "peaks")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let store = PeaksStore(cache: lib.cache, clock: FixedClock())
        let provider = PeaksWaveformProvider(store: store)
        let range = RationalTime.zero...RationalTime(2, 1)

        let t0 = ContinuousClock.now
        let coarse = try await provider.peaks(for: media, range: range, samplesPerPixel: 8192)
        let firstSeconds = elapsed(t0)
        #expect(coarse.sampleRate == 48000)
        #expect(coarse.hop == 8192)
        #expect(coarse.count == (96000 + 8191) / 8192)
        #expect(coarse.startSample == 0)
        #expect(coarse.max.allSatisfy { $0 > 0.45 && $0 <= 0.5001 }, "tone amplitude 0.5: \(coarse.max)")
        #expect(coarse.min.allSatisfy { $0 < -0.45 })

        let t1 = ContinuousClock.now
        let again = try await provider.peaks(for: media, range: range, samplesPerPixel: 8192)
        let secondSeconds = elapsed(t1)
        #expect(again == coarse)
        print(
            "peaks 2 s tone: compute \(String(format: "%.3f", firstSeconds)) s, cached \(String(format: "%.4f", secondSeconds)) s"
        )
        #expect(secondSeconds < firstSeconds)

        // Non-multiple zoom folds to a multiple of the nearest level; a sub-range starts where asked.
        let mid = try await provider.peaks(
            for: media, range: RationalTime(1, 2)...RationalTime(1, 1), samplesPerPixel: 1000)
        #expect(mid.hop == 512)
        #expect(mid.startSample == (24000 / 512) * 512)
        #expect(mid.count == 48000 / 512 - 24000 / 512 + 1)

        // Finer than the finest level: decoded directly at the requested hop.
        let fine = try await provider.peaks(
            for: media, range: RationalTime(0, 1)...RationalTime(1, 100), samplesPerPixel: 48)
        #expect(fine.hop == 48)
        #expect(fine.count == 10)
        #expect(fine.startSample == 0)

        // peaks.json is one artifact with three levels.
        let artifacts = try lib.cache.artifacts(contentHash: imported.asset.contentHash, kind: .peaks)
        #expect(artifacts.count == 1)
        #expect(artifacts[0].path.hasSuffix("/peaks.json"))
        let file = try JSONDecoder().decode(PeaksFile.self, from: Data(contentsOf: lib.cache.url(for: artifacts[0])))
        #expect(file.levels.map(\.hop) == PeaksStore.defaultHops)
        #expect(file.frames == 96000)

        // The analyzer's whole-file peaks use the same store.
        let analyzer = lib.analyzer()
        let whole = try await analyzer.waveformPeaks(media, samplesPerPixel: 131_072)
        #expect(whole.count == 1)
        #expect(try analyzer.peaksCacheKey(for: media) == artifacts[0].cacheKey)
    }

    @Test func peaksOfVideoWithStereoAudio() async throws {
        let lib = try TestLibrary()
        let clip = try await TestMedia.videoWithAudio(
            .tone(frequency: 220), duration: 1, channels: 2, in: lib.media.url, name: "av")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let peaks = try await PeaksWaveformProvider(cache: lib.cache).peaks(
            for: media, range: .zero...RationalTime(1, 1), samplesPerPixel: 512)
        #expect(peaks.count >= 90)
        #expect(peaks.max.max() ?? 0 > 0.4)
    }
}
