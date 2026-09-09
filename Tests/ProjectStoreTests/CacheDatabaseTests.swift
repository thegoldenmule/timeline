import Contracts
import ContractsTestSupport
import Foundation
import GRDB
import Testing
import TimelineCore

@testable import ProjectStore

@Suite struct CacheDatabaseTests {
    private func cache(onDisk: Bool = false) throws -> (CacheDatabase, TempDir?) {
        if onDisk {
            let dir = TempDir("cache")
            return (try CacheDatabase(path: dir.file("Cache/cache.sqlite").path, clock: FixedClock(step: 1)), dir)
        }
        return (try CacheDatabase(path: ":memory:", clock: FixedClock(step: 1)), nil)
    }

    @Test(arguments: [false, true]) func mediaIdentityTupleRemembersTheHash(_ onDisk: Bool) throws {
        let (c, dir) = try cache(onDisk: onDisk)
        let mtime = Date(timeIntervalSince1970: 1_788_825_600)
        try c.rememberMedia(
            contentHash: "sha256-aaa", size: 1234, volume: "vol-1", fileId: 42, mtime: mtime,
            libraryPath: "2026/2026-09-08/IMG_1575.MOV", probe: Fixtures.asset().probe)
        #expect(try c.lookupHash(volume: "vol-1", fileId: 42, size: 1234, mtime: mtime) == "sha256-aaa")
        #expect(try c.lookupHash(volume: "vol-2", fileId: 42, size: 1234, mtime: mtime) == nil)
        #expect(try c.lookupHash(volume: "vol-1", fileId: 42, size: 1235, mtime: mtime) == nil)
        // Re-remembering the same hash from a moved file updates the tuple and keeps the path.
        try c.rememberMedia(
            contentHash: "sha256-aaa", size: 1234, volume: "vol-1", fileId: 43, mtime: mtime, libraryPath: nil,
            probe: nil)
        #expect(try c.lookupHash(volume: "vol-1", fileId: 43, size: 1234, mtime: mtime) == "sha256-aaa")
        let record = try #require(try c.media(contentHash: "sha256-aaa"))
        #expect(record.libraryPath == "2026/2026-09-08/IMG_1575.MOV")
        #expect(record.probe?.contains("hvc1") == true)
        try c.close()
        _ = dir
    }

    @Test func artifactsAreKeyedByHashKindAndParams() throws {
        let (c, _) = try cache()
        try c.rememberMedia(
            contentHash: "h1", size: 1, volume: nil, fileId: nil, mtime: nil, libraryPath: nil, probe: nil)
        #expect(try c.artifact(contentHash: "h1", kind: "peaks", paramsHash: "v1-abc") == nil)
        try c.recordArtifact(
            contentHash: "h1", kind: "peaks", paramsHash: "v1-abc", path: "sha256/h1/peaks.json",
            summary: ["levels": 3])
        let found = try #require(try c.artifact(contentHash: "h1", kind: "peaks", paramsHash: "v1-abc"))
        #expect(found.path == "sha256/h1/peaks.json")
        #expect(found.cacheKey == "h1/peaks/v1-abc")
        #expect(found.summary == "{\"levels\":3}")
        // A new parameter hash is a different artifact; the old one stays until the cache is cleared.
        try c.recordArtifact(contentHash: "h1", kind: "peaks", paramsHash: "v2-def", path: "sha256/h1/peaks-v2.json")
        #expect(try c.artifacts(contentHash: "h1").map(\.paramsHash) == ["v1-abc", "v2-def"])
        // Foreign key: an artifact needs its media row.
        #expect(throws: DatabaseError.self) {
            try c.recordArtifact(contentHash: "unknown", kind: "peaks", paramsHash: "v1", path: "x")
        }
        try c.close()
    }

    @Test func transcriptSearchIsFilteredToTheProjectsHashes() throws {
        let (c, _) = try cache()
        let fd = Fixtures.frameDuration
        try c.indexTranscript(
            contentHash: "h1",
            words: [
                .init(word: "hello", t0: .zero, t1: RationalTime.frames(12, of: fd), speaker: "A"),
                .init(word: "there", t0: RationalTime.frames(14, of: fd), t1: RationalTime.frames(30, of: fd)),
            ])
        try c.indexTranscript(
            contentHash: "h2",
            words: [.init(word: "hello", t0: RationalTime(48000, 48000), t1: RationalTime(96000, 48000))])
        let hits = try c.searchTranscript("hello", contentHashes: ["h1", "h2"])
        #expect(hits.map(\.contentHash) == ["h1", "h2"])
        #expect(hits[0].t1 == RationalTime.frames(12, of: fd))
        #expect(hits[0].speaker == "A")
        #expect(hits[1].t0 == RationalTime(48000, 48000))
        #expect(try c.searchTranscript("hello", contentHashes: ["h2"]).count == 1)
        #expect(try c.searchTranscript("hello", contentHashes: []).isEmpty)
        #expect(try c.searchTranscript("there", contentHashes: ["h1", "h2"]).count == 1)
        // Re-indexing replaces.
        try c.indexTranscript(contentHash: "h1", words: [.init(word: "goodbye", t0: .zero, t1: .zero)])
        #expect(try c.searchTranscript("hello", contentHashes: ["h1"]).isEmpty)
        try c.close()
    }

    @Test func alignmentsRoundTrip() throws {
        let (c, _) = try cache()
        let alignment = Fixtures.alignment
        #expect(try c.alignment(referenceHash: "r", targetHash: "t", paramsHash: alignment.parametersHash) == nil)
        try c.recordAlignment(referenceHash: "r", targetHash: "t", alignment)
        let stored = try #require(
            try c.alignment(referenceHash: "r", targetHash: "t", paramsHash: alignment.parametersHash))
        #expect(stored.offset == alignment.offset)
        #expect(stored.driftPPM == alignment.driftPPM)
        #expect(stored.confidence == alignment.confidence)
        #expect(stored.status == alignment.status.rawValue)
        let candidates = try ProjectCodec.decode(
            [AlignmentCandidate].self, from: Data(try #require(stored.candidates).utf8))
        #expect(candidates == alignment.candidates)
        // Recording again replaces.
        var failed = alignment
        failed.status = .failed
        failed.offset = nil
        try c.recordAlignment(referenceHash: "r", targetHash: "t", failed)
        #expect(
            try c.alignment(referenceHash: "r", targetHash: "t", paramsHash: alignment.parametersHash)?.status
                == "failed")
        try c.close()
    }
}
