import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import TimelineUI

/// The panel's poster frames: one fetch per file, oldest evicted first, and nothing asked of the
/// provider for media with no picture.
@MainActor
@Suite("Library thumbnails")
struct LibraryThumbnailCacheTests {
    private func media(_ hash: String = "sha256-cam") -> MediaReference {
        MediaReference(url: URL(fileURLWithPath: "/tmp/Library/\(hash).mov"), contentHash: hash)
    }

    private let duration = Fixtures.frames(240)

    @Test func aMissStartsOneFetchAndCallsBackWhenItLands() async throws {
        let provider = FakeThumbnailProvider()
        let cache = LibraryThumbnailCache(thumbnails: provider)
        var updates = 0
        cache.onUpdate = { updates += 1 }

        #expect(cache.poster(for: media(), kind: .video, duration: duration) == nil)
        #expect(cache.fetchCount == 1)
        await cache.drain()
        #expect(updates == 1)
        #expect(cache.poster(for: media(), kind: .video, duration: duration) != nil)
        #expect(cache.fetchCount == 1, "a hit starts nothing")
        // The poster is the midpoint, capped at a second in, so the key is stable across launches.
        let call = try #require(provider.calls.first)
        #expect(call.range.lowerBound == LibraryThumbnailCache.posterTime(for: duration))
        #expect(call.range.lowerBound == RationalTime(1, 1), "a ten-second clip is capped at a second in")
        let short = Fixtures.frames(24)
        #expect(LibraryThumbnailCache.posterTime(for: short) == short / 2, "a short clip posters at its midpoint")
        #expect(LibraryThumbnailCache.posterTime(for: .zero) == .zero)
        #expect(call.count == 1)
    }

    /// A fetch that comes back empty is remembered. Without that the row starts a fresh one on every
    /// redraw, for as long as it is on screen.
    @Test func aFetchThatFindsNothingIsNotTriedAgain() async throws {
        let provider = FakeThumbnailProvider(findsNothing: true)
        let cache = LibraryThumbnailCache(thumbnails: provider)

        #expect(cache.poster(for: media(), kind: .image, duration: duration) == nil)
        #expect(cache.fetchCount == 1)
        await cache.drain()
        #expect(cache.failedCount == 1)

        for _ in 0..<5 { #expect(cache.poster(for: media(), kind: .image, duration: duration) == nil) }
        #expect(cache.fetchCount == 1, "the empty answer is remembered")

        // Clearing forgets it, so a rescan can try again.
        cache.clear()
        #expect(cache.poster(for: media(), kind: .image, duration: duration) == nil)
        #expect(cache.fetchCount == 2)
    }

    /// A poster asked for at its point height is half the resolution the screen draws it at, so every
    /// row came out soft on a Retina display. The request is in pixels.
    @Test func aPosterIsAskedForInPixelsNotPoints() async throws {
        #expect(MediaLibraryRow.posterPixelHeight(1) == Int(PanelTheme.posterSize.height))
        #expect(MediaLibraryRow.posterPixelHeight(2) == Int(PanelTheme.posterSize.height) * 2)
        #expect(MediaLibraryRow.posterPixelHeight(3) == Int(PanelTheme.posterSize.height) * 3)
        #expect(AssistantAttachmentChip.posterPixelHeight(2) == Int(PanelTheme.chipPosterSize.height) * 2)

        // And the request reaches the provider at that height, so the cache keys two screens apart.
        let provider = FakeThumbnailProvider()
        let cache = LibraryThumbnailCache(thumbnails: provider)
        let retina = MediaLibraryRow.posterPixelHeight(2)
        _ = cache.poster(for: media(), kind: .video, duration: duration, height: retina)
        await cache.drain()
        #expect(provider.calls.first?.height == retina)
        let image = try #require(cache.poster(for: media(), kind: .video, duration: duration, height: retina))
        #expect(image.height == retina, "72 px of picture for a 36 pt row")
    }

    @Test func twoRequestsForTheSameItemShareOneFetch() async throws {
        let provider = FakeThumbnailProvider(delayPerFrame: .milliseconds(20))
        let cache = LibraryThumbnailCache(thumbnails: provider)

        #expect(cache.poster(for: media(), kind: .video, duration: duration) == nil)
        #expect(cache.poster(for: media(), kind: .video, duration: duration) == nil)
        #expect(cache.fetchCount == 1)
        #expect(cache.pendingCount == 1)
        await cache.drain()
        #expect(provider.calls.count == 1)
        // A different height is a different poster, so it is fetched on its own.
        #expect(cache.poster(for: media(), kind: .video, duration: duration, height: 72) == nil)
        await cache.drain()
        #expect(provider.calls.count == 2)
        #expect(cache.count == 2)
    }

    @Test func theCacheEvictsOldestFirstPastItsCapacity() async throws {
        let provider = FakeThumbnailProvider()
        let cache = LibraryThumbnailCache(thumbnails: provider, capacity: 2)
        for i in 0..<3 {
            #expect(cache.poster(for: media("sha256-\(i)"), kind: .video, duration: duration) == nil)
            await cache.drain()
        }
        #expect(cache.count == 2)
        // The first one is gone and has to be fetched again; the newest two are still hits.
        #expect(cache.poster(for: media("sha256-1"), kind: .video, duration: duration) != nil)
        #expect(cache.poster(for: media("sha256-2"), kind: .video, duration: duration) != nil)
        #expect(cache.fetchCount == 3)
        #expect(cache.poster(for: media("sha256-0"), kind: .video, duration: duration) == nil)
        #expect(cache.fetchCount == 4)
    }

    @Test func audioItemsNeverHitTheThumbnailProvider() async throws {
        let provider = FakeThumbnailProvider()
        let cache = LibraryThumbnailCache(thumbnails: provider)
        #expect(cache.poster(for: media("sha256-band"), kind: .audio, duration: duration) == nil)
        #expect(cache.fetchCount == 0)
        #expect(cache.pendingCount == 0)
        await cache.drain()
        #expect(provider.calls.isEmpty)
        // Images and video do.
        #expect(cache.poster(for: media("sha256-still"), kind: .image, duration: duration) == nil)
        await cache.drain()
        #expect(provider.calls.count == 1)
    }
}
