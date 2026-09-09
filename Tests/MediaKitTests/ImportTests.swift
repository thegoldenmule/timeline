import Contracts
import ContractsTestSupport
import Foundation
import Synchronization
import Testing
import TimelineCore

@testable import MediaKit

@Suite struct ImportTests {
    @Test func copyImportPlacesFileWritesSidecarAndIsIdempotent() async throws {
        let lib = try TestLibrary()
        let clip = try await TestMedia.videoWithAudio(duration: 1, in: lib.media.url, name: "clip")
        let first = try await lib.library.importAsset(url: clip.url, mode: .copy)

        #expect(!first.alreadyInLibrary)
        #expect(first.asset.hasVideo && first.asset.hasAudio)
        #expect(first.asset.kind == .video)
        #expect(first.asset.displayName == "clip.mov")
        #expect(first.asset.contentHash.hasPrefix("sha256-"))
        #expect(first.asset.contentHash.count == 7 + 64)
        #expect(first.asset.libraryPath.hasSuffix("/clip.mov"))
        #expect(!first.asset.libraryPath.hasPrefix("/"))
        #expect(first.asset.sampleRate == 48000)
        #expect(first.asset.frameDuration == RationalTime(1, 30))
        #expect(first.asset.probe.width == 1280 && first.asset.probe.height == 720)
        #expect(first.operation.contentHash == first.asset.contentHash)
        #expect(first.operation.id == first.asset.id)
        let expected = try await ContentHash.sha256(of: clip.url)
        #expect(first.asset.contentHash == expected)

        // Date folder from the QuickTime creation date, falling back to mtime.
        let components = first.asset.libraryPath.split(separator: "/")
        #expect(components.count == 3)
        #expect(components[0].count == 4)
        #expect(components[1].hasPrefix(components[0] + "-"))
        #expect(FileManager.default.fileExists(atPath: first.libraryURL.path))
        #expect(FileManager.default.fileExists(atPath: clip.url.path), "copy leaves the source in place")

        let sidecar = try #require(try lib.library.sidecar(for: first.libraryURL))
        #expect(sidecar.contentHash == first.asset.contentHash)
        #expect(sidecar.source.path == clip.url.standardizedFileURL.path)
        #expect(sidecar.mode == .copy)
        #expect(sidecar.asset == first.asset)
        #expect(lib.libraryFiles() == [first.asset.libraryPath, first.asset.libraryPath + ".json"])

        // Same file again: no second copy, same asset, flagged.
        let again = try await lib.library.importAsset(url: clip.url, mode: .copy)
        #expect(again.alreadyInLibrary)
        #expect(again.asset == first.asset)
        #expect(again.libraryURL == first.libraryURL)
        #expect(lib.libraryFiles().count == 2)

        // A byte-identical copy under another name: idempotent by hash, not by path.
        let twin = lib.media.url.appendingPathComponent("twin.mov")
        try FileManager.default.copyItem(at: clip.url, to: twin)
        let viaTwin = try await lib.library.importAsset(url: twin, mode: .copy)
        #expect(viaTwin.alreadyInLibrary)
        #expect(viaTwin.asset.id == first.asset.id)
        #expect(lib.libraryFiles().count == 2)

        // The cache index knows the file and the identity hint.
        let record = try #require(try lib.cache.media(contentHash: first.asset.contentHash))
        #expect(record.libraryPath == first.asset.libraryPath)
        #expect(record.asset == first.asset)
        let identity = try FileIdentity(of: clip.url)
        #expect(try lib.cache.contentHash(matching: identity) == first.asset.contentHash)
        let located = await lib.library.locate(contentHash: first.asset.contentHash)
        #expect(located == first.libraryURL)
    }

    @Test func collisionGetsNumericSuffix() async throws {
        let lib = try TestLibrary()
        let a = try await TestMedia.tone(frequency: 440, duration: 1, in: lib.media.url, name: "tone")
        let b = try await TestMedia.tone(frequency: 880, duration: 1, in: lib.media.url, name: "other")
        let renamed = lib.media.url.appendingPathComponent("sub").appendingPathComponent("tone.caf")
        try FileManager.default.createDirectory(
            at: renamed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: b.url, to: renamed)
        let first = try await lib.library.importAsset(url: a.url, mode: .copy)
        let second = try await lib.library.importAsset(url: renamed, mode: .copy)
        #expect(first.libraryURL.lastPathComponent == "tone.caf")
        #expect(second.libraryURL.lastPathComponent == "tone-2.caf")
        #expect(first.asset.kind == .audio && !first.asset.hasVideo && first.asset.hasAudio)
    }

    @Test func moveAndReferenceModes() async throws {
        let lib = try TestLibrary()
        let moved = try await TestMedia.tone(duration: 1, in: lib.media.url, name: "moved")
        let result = try await lib.library.importAsset(url: moved.url, mode: .move)
        #expect(!FileManager.default.fileExists(atPath: moved.url.path))
        #expect(FileManager.default.fileExists(atPath: result.libraryURL.path))
        #expect(!result.asset.libraryPath.hasPrefix("/"))

        let referenced = try await TestMedia.tone(frequency: 660, duration: 1, in: lib.media.url, name: "referenced")
        let ref = try await lib.library.importAsset(url: referenced.url, mode: .reference)
        #expect(ref.asset.libraryPath == referenced.url.standardizedFileURL.path)
        #expect(ref.libraryURL == referenced.url.standardizedFileURL)
        #expect(lib.libraryFiles().count == 2, "reference mode writes nothing into Library/")
        let sidecar = lib.layout.artifactDir(contentHash: ref.asset.contentHash).appendingPathComponent("import.json")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(lib.layout.url(for: ref.asset) == referenced.url.standardizedFileURL)
    }

    @Test func stillImageImports() async throws {
        let lib = try TestLibrary()
        let still = try TestMedia.still(.blue, in: lib.media.url, name: "still")
        let result = try await lib.library.importAsset(url: still.url, mode: .copy)
        #expect(result.asset.kind == .image)
        #expect(!result.asset.hasVideo && !result.asset.hasAudio)
        #expect(result.asset.duration == MediaProbe.stillImageDuration)
        #expect(result.asset.probe.width == 640 && result.asset.probe.height == 480)
    }

    @Test func missingAndUnreadableFiles() async throws {
        let lib = try TestLibrary()
        await #expect(throws: MediaError.notFound(lib.media.url.appendingPathComponent("nope.mov"))) {
            try await lib.library.importAsset(url: lib.media.url.appendingPathComponent("nope.mov"), mode: .copy)
        }
        let junk = lib.media.url.appendingPathComponent("junk.mov")
        try Data(repeating: 7, count: 4096).write(to: junk)
        await #expect(throws: (any Error).self) { try await lib.library.importAsset(url: junk, mode: .copy) }
        #expect(lib.libraryFiles().isEmpty, "a failed import leaves nothing in Library/")
    }

    @Test func cancellationMidCopyLeavesNoPartialFile() async throws {
        let lib = try TestLibrary()
        let big = try await LargeFile.write(in: lib.media.url)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: big.path)[.size] as? Int)
        #expect(size > 45 << 20, "about 50 MB: \(size)")
        let handleBox = Mutex<JobHandle?>(nil)
        let chunksSeen = Mutex<[Int]>([])
        lib.library.beforeCopyChunk = { chunk in
            chunksSeen.withLock { $0.append(chunk) }
            if chunk == 2 { handleBox.withLock { $0?.cancel() } }
        }
        let runner = FakeJobRunner(mode: .concurrent)
        let job = lib.library.importJob(url: big, mode: .copy)
        #expect(job.kind == .import && job.memoryClass == .small)
        let started = ContinuousClock.now
        let handle = await runner.submit(job)
        handleBox.withLock { $0 = handle }
        var progress: [JobProgress] = []
        for await p in handle.progress { progress.append(p) }
        await #expect(throws: CancellationError.self) { try await handle.wait() }
        print(
            "import cancelled after \(String(format: "%.3f", elapsed(started))) s, chunks copied: \(chunksSeen.withLock { $0 })"
        )

        #expect(chunksSeen.withLock { $0 } == [0, 1, 2], "the copy stopped at the cancelled chunk")
        #expect(progress.contains { $0.stage == "hash" })
        #expect(progress.contains { $0.stage == "copy" })
        #expect(lib.libraryFiles().isEmpty, "no partial or temporary file in Library/: \(lib.libraryFiles())")
        let entries = try FileManager.default.contentsOfDirectory(atPath: lib.layout.libraryDir.path)
        #expect(entries.isEmpty, "the empty date folder is removed too: \(entries)")
        #expect(TestLibrary.files(under: lib.media.url) == ["big.caf"], "nothing stray next to the source")
        let bigHash = try await ContentHash.sha256(of: big)
        #expect(try lib.cache.media(contentHash: bigHash) == nil)

        // The hash was recorded as a hint, so a retry skips re-hashing and completes the import.
        lib.library.beforeCopyChunk = nil
        let identity = try FileIdentity(of: big)
        #expect(try lib.cache.contentHash(matching: identity) == bigHash)
        let retried = try await lib.library.importAsset(url: big, mode: .copy)
        #expect(!retried.alreadyInLibrary)
        #expect(retried.asset.contentHash == bigHash)
        #expect(lib.libraryFiles().count == 2)
    }

    @Test func importJobProducesImportResultOutcome() async throws {
        let lib = try TestLibrary()
        let clip = try await TestMedia.videoWithAudio(duration: 1, in: lib.media.url, name: "job")
        let runner = FakeJobRunner(mode: .concurrent)
        let handle = await runner.submit(lib.library.importJob(url: clip.url, mode: .copy))
        let outcome = try await handle.wait()
        let result = try #require(try outcome.payload(as: ImportResult.self))
        #expect(outcome.urls == [result.libraryURL])
        #expect(result.asset.hasVideo && result.asset.hasAudio)
        if case .importAsset(let op) = Command.Operation.importAsset(result.operation) {
            #expect(op.libraryPath == result.asset.libraryPath)
        }
    }

    @Test func movedFileResolvesByHashAndRelinks() async throws {
        let lib = try TestLibrary()
        let clip = try await TestMedia.videoWithAudio(duration: 1, in: lib.media.url, name: "wander")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .reference)
        let asset = imported.asset
        #expect(await lib.library.checkOffline(assets: [asset]).isEmpty)

        // Move the referenced original somewhere else: the asset is offline until relinked.
        let elsewhere = lib.media.url.appendingPathComponent("elsewhere").appendingPathComponent("renamed.mov")
        try FileManager.default.createDirectory(
            at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: clip.url, to: elsewhere)
        #expect(await lib.library.checkOffline(assets: [asset]) == [asset.id])

        // Re-importing the moved file resolves by hash and relinks instead of creating a second asset.
        let again = try await lib.library.importAsset(url: elsewhere, mode: .reference)
        #expect(again.alreadyInLibrary)
        #expect(again.asset.id == asset.id)
        #expect(again.asset.libraryPath == elsewhere.standardizedFileURL.path)
        #expect(!again.asset.offline)
        #expect(await lib.library.locate(contentHash: asset.contentHash) == elsewhere.standardizedFileURL)
        #expect(await lib.library.checkOffline(assets: [again.asset]).isEmpty)

        // Explicit relink verifies the hash.
        var offline = asset
        offline.offline = true
        let relinked = try await lib.library.relink(offline, to: elsewhere)
        #expect(relinked.libraryPath == elsewhere.standardizedFileURL.path)
        #expect(!relinked.offline)
        let other = try await TestMedia.tone(duration: 1, in: lib.media.url, name: "other")
        await #expect(throws: MediaError.self) { try await lib.library.relink(asset, to: other.url) }
        do {
            _ = try await lib.library.relink(asset, to: other.url)
        } catch MediaError.hashMismatch(let expected, let found) {
            #expect(expected == asset.contentHash)
            #expect(found != expected)
        }

        // Deleted: offline again, and locate finds nothing.
        try FileManager.default.removeItem(at: elsewhere)
        #expect(await lib.library.checkOffline(assets: [relinked]) == [asset.id])
        #expect(await lib.library.locate(contentHash: asset.contentHash) == nil)
    }

    @Test func copiedLibraryFileMovedWithinLibraryIsStillFoundByHash() async throws {
        let lib = try TestLibrary()
        let clip = try await TestMedia.tone(duration: 1, in: lib.media.url, name: "lib")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .copy)
        let moved = lib.layout.libraryDir.appendingPathComponent("moved.caf")
        try FileManager.default.moveItem(at: imported.libraryURL, to: moved)
        #expect(await lib.library.checkOffline(assets: [imported.asset]) == [imported.asset.id])
        let result = try await lib.library.importAsset(url: moved, mode: .copy)
        #expect(result.alreadyInLibrary)
        #expect(result.asset.id == imported.asset.id)
        #expect(result.asset.libraryPath == "moved.caf")
        #expect(lib.libraryFiles().count == 2, "no second copy was made")
    }

    @Test func concurrentImportsOfDistinctFilesDoNotCollide() async throws {
        let lib = try TestLibrary()
        var urls: [URL] = []
        for i in 0..<4 {
            let clip = try await TestMedia.tone(
                frequency: 300 + Double(i) * 50, duration: 0.5, in: lib.media.url, name: "c\(i)")
            let same = lib.media.url.appendingPathComponent("dir\(i)").appendingPathComponent("same.caf")
            try FileManager.default.createDirectory(
                at: same.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: clip.url, to: same)
            urls.append(same)
        }
        let results = try await withThrowingTaskGroup(of: ImportResult.self) { group in
            for url in urls { group.addTask { try await lib.library.importAsset(url: url, mode: .copy) } }
            var out: [ImportResult] = []
            for try await r in group { out.append(r) }
            return out
        }
        let names = Set(results.map(\.libraryURL.lastPathComponent))
        #expect(names.count == 4, "\(names)")
        #expect(lib.libraryFiles().count == 8)
    }

    @Test func analysisOperationHelper() throws {
        let asset = Fixtures.asset()
        let op = MediaKit.analysisOperation(
            for: asset, kind: .transcript, cacheKey: "\(asset.contentHash)/transcript/v1-abc", summary: ["words": 3])
        guard case .recordAssetAnalysis(let record) = op else {
            Issue.record("expected recordAssetAnalysis")
            return
        }
        #expect(record.assetId == .id(asset.id))
        #expect(record.kind == "transcript")
        #expect(record.cacheKey.hasSuffix("/transcript/v1-abc"))
        #expect(record.summary?["words"]?.intValue == 3)

        // The operation is accepted by the core against a project holding the asset.
        var project = try Fixtures.project()
        project.assets[asset.id] = asset
        let events = try decide(
            project, Fixtures.command(op), ids: SequentialIDGenerator(start: 1), clock: FixedClock())
        #expect(events.count == 1)
    }
}
