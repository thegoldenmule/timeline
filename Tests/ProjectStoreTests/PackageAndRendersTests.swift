import Contracts
import ContractsTestSupport
import Foundation
import GRDB
import Testing
import TimelineCore

@testable import ProjectStore

@Suite struct PackageAndRendersTests {
    private func opener() -> SQLiteProjectStoreOpener {
        SQLiteProjectStoreOpener(
            ids: SequentialIDGenerator(start: 1), clock: FixedClock(step: 1), libraryRootHint: "~/Movies/Timeline")
    }

    @Test func createThenOpenAPackage() async throws {
        let dir = TempDir("package")
        let url = dir.file("Band Rehearsal.tlproj")
        let opener: any ProjectStoreOpening = opener()
        let created = try await opener.create(
            at: url, name: "Band Rehearsal", settings: ProjectSettings(),
            sequence: .init(name: "Seq", frameDuration: Fixtures.frameDuration, width: 1920, height: 1080))
        #expect(await created.version() == 1)
        #expect(await created.state().name == "Band Rehearsal")
        let projectId = await created.projectId
        let package = ProjectPackage(url: url)
        #expect(FileManager.default.fileExists(atPath: package.databaseURL.path))
        #expect(FileManager.default.fileExists(atPath: package.rendersURL.path))
        let manifest = try package.readManifest()
        #expect(manifest.projectId == projectId)
        #expect(manifest.formatVersion == ProjectManifest.currentFormatVersion)
        #expect(manifest.libraryRootHint == "~/Movies/Timeline")
        try await created.close()

        let opened = try await opener.open(at: url)
        #expect(await opened.projectId == projectId)
        #expect(await opened.version() == 1)
        #expect((opened as? SQLiteProjectStore)?.url == package.url)
        try await opened.close()

        await #expect(throws: ProjectStoreError.notFound(dir.file("Missing.tlproj"))) {
            _ = try await opener.open(at: dir.file("Missing.tlproj"))
        }
        await #expect(throws: ProjectStoreError.alreadyExists(package.url)) {
            _ = try await opener.create(
                at: url, name: "x", settings: ProjectSettings(),
                sequence: .init(name: "Seq", frameDuration: Fixtures.frameDuration, width: 1920, height: 1080))
        }
    }

    @Test func openRefusesAPackageWhoseManifestDisagrees() async throws {
        let dir = TempDir("package")
        let url = dir.file("A.tlproj")
        let o = opener()
        let store = try await o.createStore(
            at: url, name: "A", settings: ProjectSettings(),
            sequence: .init(name: "Seq", frameDuration: Fixtures.frameDuration, width: 1920, height: 1080))
        try await store.close()
        let package = ProjectPackage(url: url)
        try package.writeManifest(ProjectManifest(projectId: "other", libraryRootHint: nil, createdAt: Date()))
        await #expect(throws: ProjectStoreError.self) { _ = try await o.openStore(at: url) }
        try "not json".write(to: package.manifestURL, atomically: true, encoding: .utf8)
        await #expect(throws: ProjectStoreError.self) { _ = try await o.openStore(at: url) }
    }

    @Test func locationCheckSpotsSyncedFoldersAndLocalDisk() throws {
        let dir = TempDir("location")
        #expect(LocationCheck.check(dir.url) == .local)
        #expect(LocationCheck.check(dir.file("New.tlproj")) == .local)
        let dropbox = dir.url.appendingPathComponent("Dropbox/Projects/X.tlproj")
        #expect(LocationCheck.check(dropbox) == .synced(service: "Dropbox"))
        let icloud = dir.url.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/X.tlproj")
        #expect(LocationCheck.check(icloud) == .synced(service: "iCloud Drive"))
        let drive = dir.url.appendingPathComponent("Library/CloudStorage/GoogleDrive-me/X.tlproj")
        #expect(LocationCheck.check(drive) == .synced(service: "cloud storage"))
        // A `.dropbox` marker file in an ancestor.
        let marked = dir.url.appendingPathComponent("Synced", isDirectory: true)
        try FileManager.default.createDirectory(at: marked, withIntermediateDirectories: true)
        try Data().write(to: marked.appendingPathComponent(".dropbox"))
        #expect(LocationCheck.check(marked.appendingPathComponent("Deep/X.tlproj")) == .synced(service: "Dropbox"))
    }

    @Test func syncedLocationPolicyWarnsRefusesOrFallsBack() async throws {
        let dir = TempDir("synced")
        let url = dir.url.appendingPathComponent("Dropbox/X.tlproj")
        let spec = Command.Operation.SequenceSpec(
            name: "Seq", frameDuration: Fixtures.frameDuration, width: 1920, height: 1080)

        var o = opener()
        o.syncedLocationPolicy = .warn
        let warned = try await o.createStore(at: url, name: "X", settings: ProjectSettings(), sequence: spec)
        #expect(warned.openWarnings.count == 1)
        #expect(warned.openWarnings[0].contains("Dropbox"))
        #expect(try warned.scalar("PRAGMA journal_mode") == "wal")
        try await warned.close()

        o.syncedLocationPolicy = .refuse
        await #expect(throws: ProjectStoreError.syncedLocation(ProjectPackage(url: url).url, "Dropbox")) {
            _ = try await o.openStore(at: url)
        }

        o.syncedLocationPolicy = .useDeleteJournal
        let fallback = try await o.openStore(at: url)
        #expect(fallback.options.journal == .delete)
        #expect(try fallback.scalar("PRAGMA journal_mode") == "delete")
        #expect(try fallback.scalar("PRAGMA synchronous") == 2)
        #expect(fallback.openWarnings[0].contains("DELETE journal"))
        try await fallback.close()
    }

    @Test func saveAsAndBackupProduceOpenableCopies() async throws {
        let t = try await Stores.fixture(on: .disk)
        let dir = try #require(t.dir)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        try await t.apply(Fixtures.opacity(clip, 0.5))
        let expected = await t.store.state()

        let copy = dir.file("Copy.tlproj")
        try await t.store.saveAs(to: copy)
        let duplicate = await #expect(throws: ProjectStoreError.self) { try await t.store.saveAs(to: copy) }
        guard case .alreadyExists(let existing) = duplicate else {
            Issue.record("expected alreadyExists, got \(String(describing: duplicate))")
            return
        }
        #expect(existing.path == copy.path)
        let opened = try await opener().openStore(at: copy)
        #expect(await opened.state() == expected)
        #expect(!opened.recovery.uncleanShutdown)
        #expect(try opened.scalar("SELECT COUNT(*) FROM events") == Int(expected.version))
        try await opened.close()

        let backup = dir.file("nested/backup.sqlite")
        try await t.store.backup(to: backup)
        try await t.apply(Fixtures.opacity(clip, 0.7))
        try await t.store.backup(to: backup)  // replaces atomically
        let queue = try DatabaseQueue(path: backup.path)
        let count = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") }
        #expect(count == Int(expected.version) + 1)
        try queue.close()
        try await t.store.close()
    }

    @Test func closeCheckpointsTheWal() async throws {
        let t = try await Stores.fixture(on: .disk)
        let dir = try #require(t.dir)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        for i in 0..<20 { try await t.apply(Fixtures.opacity(clip, Double(i % 5) / 10)) }
        let wal = dir.file("project.sqlite-wal")
        try await t.store.close()
        let size = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0
        #expect(size == 0)
        let queue = try DatabaseQueue(path: dir.file("project.sqlite").path)
        let session: String? = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT note FROM projection_state WHERE name = 'session'")
        }
        try queue.close()
        #expect(session == "closed")
    }

    @Test(arguments: Backend.allCases) func rendersTableHoldsReceiptsOutsideTheEvents(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let state = await t.store.state()
        let sequenceId = try #require(state.activeSequenceId)
        let version = state.version
        let row = try await t.store.recordRender(sequenceId: sequenceId, preset: .reel9x16)
        #expect(row.status == .queued)
        #expect(row.projectVersion == version)
        #expect(try await t.store.render(row.renderId) == row)
        let running = try await t.store.updateRender(row.renderId, status: .running)
        #expect(running.completedAt == nil)
        let receipt = ExportReceipt(
            preset: .reel9x16, sequenceId: sequenceId, projectVersion: version,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"), durationSeconds: 12, startedAt: Date(), finishedAt: Date(),
            warnings: ["asset offline"])
        let done = try await t.store.updateRender(
            row.renderId, status: .done, outputPath: "renders/out.mp4", outputHash: "sha256-abc", receipt: receipt)
        #expect(done.status == .done)
        #expect(done.completedAt != nil)
        #expect(done.outputPath == "renders/out.mp4")
        let decoded = try ProjectCodec.decode(ExportReceipt.self, from: Data(try #require(done.receipt).utf8))
        #expect(decoded.warnings == ["asset offline"])
        #expect(try ProjectCodec.decode(ExportPreset.self, from: Data(done.preset.utf8)) == .reel9x16)
        #expect(try await t.store.renders().map(\.renderId) == [row.renderId])
        // No event, no version bump: an export never makes an agent stale.
        #expect(await t.store.version() == version)
        await #expect(throws: ProjectStoreError.self) { try await t.store.updateRender("nope", status: .failed) }
        try await t.store.close()
    }
}
