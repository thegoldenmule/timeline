import Contracts
import ContractsTestSupport
import Foundation
import GRDB
import Testing
import TimelineCore

@testable import ProjectStore

/// The 10,000-event fixture, built once per test run: a `ProjectBuilder` log imported into an on-disk
/// package through the incremental projection path, then closed.
enum LargeFixture {
    struct Built: Sendable {
        let dir: TempDir
        let events: [DomainEvent]
        let labels: [TransactionID: String]
        let project: Project
        let ids: SequentialIDGenerator
        let importMilliseconds: Double
        var databasePath: String { dir.file("project.sqlite").path }
    }

    /// Built once per test run, off the cooperative pool's critical path (a semaphore here would deadlock
    /// parallel tests waiting on the same static).
    private static let building = Task<Built, any Error> {
        let builder = try LargeLog.build()
        let labels = Stores.labels(of: builder.history)
        let dir = TempDir("large")
        let store = try SQLiteProjectStore(
            databaseAt: dir.file("project.sqlite").path, ids: builder.ids, clock: builder.clock)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await store.importEvents(builder.events, labels: labels)
        }
        try await store.close()
        return Built(
            dir: dir, events: builder.events, labels: labels, project: builder.project,
            ids: builder.ids as! SequentialIDGenerator, importMilliseconds: milliseconds(elapsed))
    }

    static func shared() async throws -> Built { try await building.value }

    /// A private copy of the fixture package for one test.
    static func copy() async throws -> (TempDir, String) {
        let dir = TempDir("large-copy")
        let path = dir.file("project.sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: try await shared().databasePath), to: path)
        return (dir, path.path)
    }
}

@Suite struct RebuildAndPerfTests {
    @Test func largeFixtureHasTenThousandEventsAndOpensToItsBuilderState() async throws {
        let built = try await LargeFixture.shared()
        #expect(built.events.count >= 10_000)
        let kinds = Set(built.events.map(\.type))
        #expect(
            kinds.isSuperset(of: [
                "ClipAdded", "ClipTrimmed", "ClipMoved", "ClipSplit", "ClipRemoved", "TransitionAdded", "MarkerAdded",
                "TransactionUndone", "TransactionRedone", "ClipOpacitySet",
            ]))
        print("large fixture: \(built.events.count) events, imported incrementally in \(built.importMilliseconds) ms")
        let (dir, path) = try await LargeFixture.copy()
        let store = try SQLiteProjectStore(databaseAt: path, ids: built.ids, clock: FixedClock())
        #expect(!store.recovery.uncleanShutdown)
        #expect(await store.state() == built.project)
        #expect(await store.version() == Int64(built.events.count))
        #expect(await store.history().transactions.count == Transaction.group(built.events).count)
        print("open + load of the large fixture: \(store.recovery.openMilliseconds) ms")
        try await store.close()
        _ = dir
    }

    @Test func rebuildReproducesEveryProjectionByteForByte() async throws {
        let built = try await LargeFixture.shared()
        let (dir, path) = try await LargeFixture.copy()
        let store = try SQLiteProjectStore(databaseAt: path, ids: built.ids, clock: FixedClock())
        let incremental = try store.projectionSnapshot()
        #expect(incremental.state == String(decoding: try built.project.canonicalJSON(), as: UTF8.self))
        #expect(!incremental.clips.isEmpty)
        #expect(!incremental.history.isEmpty)
        #expect(!incremental.transitions.isEmpty || built.events.allSatisfy { $0.type != "TransitionAdded" })

        let clock = ContinuousClock()
        let elapsed = try await clock.measure { try await store.rebuildProjections() }
        print("rebuildProjections on \(built.events.count) events: \(milliseconds(elapsed)) ms")

        let rebuilt = try store.projectionSnapshot()
        #expect(rebuilt.state == incremental.state)
        #expect(rebuilt.assets == incremental.assets)
        #expect(rebuilt.sequences == incremental.sequences)
        #expect(rebuilt.tracks == incremental.tracks)
        #expect(rebuilt.clips == incremental.clips)
        #expect(rebuilt.transitions == incremental.transitions)
        #expect(rebuilt.markers == incremental.markers)
        #expect(rebuilt.history == incremental.history)
        #expect(rebuilt == incremental)
        #expect(await store.state() == built.project)
        let history = await store.history()
        let refold = History.fold(events: built.events, labels: built.labels)
        #expect(history.live == refold.live)
        #expect(history.redoStack == refold.redoStack)
        #expect(history.transactions == refold.transactions)
        try await store.close()
        _ = dir
    }

    @Test func rebuildAfterFurtherEditsStillMatches() async throws {
        let built = try await LargeFixture.shared()
        let (dir, path) = try await LargeFixture.copy()
        let store = try SQLiteProjectStore(databaseAt: path, ids: built.ids, clock: FixedClock())
        let t = TestStore(store: store, dir: dir, ids: built.ids, clock: FixedClock())
        let clip = try #require(Fixtures.firstVideoClip(in: await store.state()))
        try await t.apply(Fixtures.opacity(clip, 0.42), label: "Agent: fade the opener")
        try await t.apply(.undo(.init()))
        try await t.apply(.redo)
        try await t.apply(.renameProject(.init(name: "Rebuilt")))
        try await store.flush()
        let incremental = try store.projectionSnapshot()
        try await store.rebuildProjections()
        let rebuilt = try store.projectionSnapshot()
        #expect(rebuilt == incremental)
        #expect(rebuilt.history.contains { $0["label"] == "Agent: fade the opener" })
        try await store.close()
    }

    @Test func tenThousandEventFoldIsFast() async throws {
        let built = try await LargeFixture.shared()
        let (dir, path) = try await LargeFixture.copy()
        let store = try SQLiteProjectStore(databaseAt: path, ids: built.ids, clock: FixedClock())
        let clock = ContinuousClock()
        var decoded: [StoredEvent] = []
        let decodeTime = try await clock.measure { decoded = try await store.events(since: 0) }
        var state = Project.blank
        let foldTime = clock.measure { evolve(&state, decoded.map(\.event)) }
        print(
            "decode \(decoded.count) events from SQLite: \(milliseconds(decodeTime)) ms; pure fold: \(milliseconds(foldTime)) ms"
        )
        #expect(decoded.count == built.events.count)
        #expect(state == built.project)
        #expect(decoded.map(\.event) == built.events)
        #if DEBUG
            #expect(milliseconds(foldTime) < 2000)
        #else
            #expect(milliseconds(foldTime) < 100)
            #expect(milliseconds(decodeTime) + milliseconds(foldTime) < 400)
        #endif
        try await store.close()
        _ = dir
    }

    @Test(arguments: Backend.allCases) func commandCostOnASmallProject(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        let before = await t.store.version()
        let count = 1000
        let commands = (0..<count).map { i in t.command(Fixtures.opacity(clip, Double(i % 2 == 0 ? 25 : 75) / 100)) }
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            for c in commands { _ = try await t.store.apply(c) }
        }
        let perCommand = milliseconds(elapsed) / Double(count)
        print("\(backend): \(count) commands in \(milliseconds(elapsed)) ms, \(perCommand) ms per command")
        #expect(await t.store.version() == before + Int64(count))
        #if DEBUG
            #expect(perCommand < 5)
        #else
            #expect(perCommand < 0.5)
        #endif
        let flush = try await clock.measure { try await t.store.flush() }
        print("\(backend): state flush after \(count) commands: \(milliseconds(flush)) ms")
        try await t.store.close()
    }

    @Test func openOfTheLargeFixtureIsCheap() async throws {
        let built = try await LargeFixture.shared()
        let (dir, path) = try await LargeFixture.copy()
        let clock = ContinuousClock()
        var store: SQLiteProjectStore?
        let elapsed = try clock.measure {
            store = try SQLiteProjectStore(databaseAt: path, ids: built.ids, clock: FixedClock())
        }
        let s = try #require(store)
        print("open of the large fixture (clean close): \(milliseconds(elapsed)) ms")
        let integrity = try await clock.measure { _ = try await s.integrityCheck() }
        print("integrity_check: \(milliseconds(integrity)) ms")
        let backup = dir.file("backup.sqlite")
        let vacuum = try await clock.measure { try await s.backup(to: backup) }
        print("VACUUM INTO: \(milliseconds(vacuum)) ms")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let copy = try DatabaseQueue(path: backup.path)
        let count = try await copy.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") }
        #expect(count == built.events.count)
        try copy.close()
        try await s.close()
    }
}
