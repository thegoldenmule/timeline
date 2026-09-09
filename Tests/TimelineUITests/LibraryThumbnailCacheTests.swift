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
