import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import MediaKit

@Suite struct ProviderTests {
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
