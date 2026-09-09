import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import MediaKit

/// The cache index as a listing, not a lookup: what the library panel reads to show media on this
/// machine that no project references.
@Suite("Cache index listing")
struct CatalogTests {
    @Test func allMediaListsEveryImportedFileWithItsAsset() async throws {
        let lib = try TestLibrary(inMemoryCache: true)
        let clip = try await TestMedia.videoWithAudio(duration: 1, in: lib.media.url, name: "clip")
        let tone = try await TestMedia.tone(duration: 1, in: lib.media.url, name: "tone")
        let imported = [
            try await lib.library.importAsset(url: clip.url, mode: .copy),
            try await lib.library.importAsset(url: tone.url, mode: .copy),
        ]

        let rows = try lib.cache.allMedia()
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.contentHash)) == Set(imported.map(\.asset.contentHash)))
        // The asset as imported rides on the row, so a panel row needs no second lookup.
        for result in imported {
            let row = try #require(rows.first { $0.contentHash == result.asset.contentHash })
            #expect(row.asset == result.asset)
            #expect(row.libraryPath == result.asset.libraryPath)
            #expect(row.probe == result.asset.probe)
            #expect(row.size > 0)
        }
    }

    @Test func allMediaHonoursTheLimitAndOrdersNewestFirst() throws {
        let lib = try TestLibrary(inMemoryCache: true)
        let start = Date(timeIntervalSince1970: 1_788_825_600)
        for i in 0..<5 {
            try lib.cache.upsertMedia(
                contentHash: "sha256-\(i)", size: Int64(i + 1), identity: nil, libraryPath: "2026/2026-09-08/\(i).mov",
                probe: nil, asset: nil, now: start.addingTimeInterval(Double(i)))
        }

        #expect(
            try lib.cache.allMedia().map(\.contentHash) == ["sha256-4", "sha256-3", "sha256-2", "sha256-1", "sha256-0"])
        #expect(try lib.cache.allMedia(limit: 2).map(\.contentHash) == ["sha256-4", "sha256-3"])
        #expect(try lib.cache.allMedia(limit: 0).isEmpty)
    }
}
