import Contracts
import ContractsTestSupport
import Foundation
import GRDB
import Testing
import TimelineCore

@testable import ProjectStore

/// The `UNIQUE (stream_id, stream_version)` guard and the open-time recovery of storage.md section 12.
@Suite struct ConcurrencyAndRecoveryTests {
    private func forgedEvent(_ t: TestStore) -> DomainEvent {
        DomainEvent(
            eventId: EventID(minting: t.ids), txnId: TransactionID(minting: t.ids), commandId: "race", actor: .system,
            occurredAt: t.clock.now(), payload: .projectRenamed(.init(before: "a", after: "b")))
    }

    @Test(arguments: Backend.allCases) func forcedConflictingInsertIsRolledBackByTheUniqueConstraint(
        _ backend: Backend
    ) async throws {
        let t = try await Stores.fixture(on: backend)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        let version = await t.store.version()
        try await t.apply(Fixtures.opacity(clip, 0.5))
        let events: Int? = try t.store.scalar("SELECT COUNT(*) FROM events")

        // A second writer that also read `version` tries to append at version + 1.
        let forged = forgedEvent(t)
        let error = #expect(throws: DatabaseError.self) {
            try t.store.writer.write { db in
                _ = try EventRows.append(db, [forged], fromVersion: version)
            }
        }
        #expect(error?.resultCode == .SQLITE_CONSTRAINT)
        #expect(error?.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE)
        #expect(try t.store.scalar("SELECT COUNT(*) FROM events") == events)
        #expect(await t.store.version() == version + 1)
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func applyAgainstAForgedRowRollsBackAtomically(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        let version = await t.store.version()
        let before = await t.store.state()
        let forged = forgedEvent(t)
        try await t.store.writer.write { db in _ = try EventRows.append(db, [forged], fromVersion: version) }

        let command = t.command(Fixtures.opacity(clip, 0.5))
        let error = await #expect(throws: EditorError.self) { try await t.store.apply(command) }
        guard case .invalid(let reason, _) = error else {
            Issue.record("expected a storage rejection, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("UNIQUE constraint failed: events.stream_id, events.stream_version"))
        // Nothing of the failed transaction survived: no commands row, no history row, state untouched.
        #expect(
            try t.store.scalar("SELECT COUNT(*) FROM commands WHERE command_id = ?", [command.commandId.rawValue]) == 0)
        #expect(try t.store.scalar("SELECT COUNT(*) FROM history") == Int(await t.store.history().transactions.count))
        #expect(await t.store.state() == before)
        #expect(await t.store.version() == version)

        // Once the forged row is gone the same command applies.
        try await t.store.writer.write { db in
            try db.execute(sql: "DELETE FROM events WHERE event_id = ?", arguments: [forged.eventId.rawValue])
        }
        let result = try await t.store.apply(command)
        #expect(result.status == .applied)
        #expect(result.version == version + 1)
        try await t.store.close()
    }

    @Test func crashBetweenCommitAndDebouncedStateWriteReopensToThePureFold() async throws {
        var options = SQLiteProjectStore.Options()
        options.stateWriteDebounce = .seconds(60)
        let t = try await Stores.fixture(on: .disk, options: options)
        let dir = try #require(t.dir)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        let sequenceId = try #require(await t.store.state().activeSequenceId)
        try await t.store.flush()
        let storedVersion: Int64? = try t.store.scalar("SELECT version FROM project_state WHERE id = 1")
        try await t.apply(Fixtures.trimTail(clip, by: 60))
        try await t.apply(Fixtures.opacity(clip, 0.25))
        try await t.apply(.undo(.init()))
        try await t.apply(.addMarker(.init(sequenceId: .id(sequenceId), at: .zero, label: "m")))
        let expected = await t.store.state()
        let expectedHistory = await t.store.history()
        #expect(await t.store.isStateWritePending)
        #expect(try t.store.scalar("SELECT version FROM project_state WHERE id = 1") == storedVersion)
        try await t.store.terminateAbruptly()

        let reopened = try SQLiteProjectStore(
            databaseAt: dir.file("project.sqlite").path, ids: t.ids, clock: t.clock, options: options)
        #expect(reopened.recovery.uncleanShutdown)
        #expect(reopened.recovery.integrityChecked)
        #expect(reopened.recovery.stateEventsFolded == Int(expected.version - storedVersion!))
        #expect(!reopened.recovery.projectionsRebuilt)
        #expect(await reopened.state() == expected)
        #expect(await reopened.history().transactions == expectedHistory.transactions)
        #expect(await reopened.history().live == expectedHistory.live)
        #expect(await reopened.history().redoStack == expectedHistory.redoStack)
        // The stored row now agrees with the log, and the pure fold from blank agrees with both.
        let stored = try #require(try reopened.storedStateJSON())
        #expect(stored == String(decoding: try expected.canonicalJSON(), as: UTF8.self))
        var pure = Project.blank
        evolve(&pure, try await reopened.events(since: 0).map(\.event))
        #expect(pure == expected)
        // A clean close marks the session; the next open skips the integrity check.
        try await reopened.close()
        let third = try SQLiteProjectStore(databaseAt: dir.file("project.sqlite").path, ids: t.ids, clock: t.clock)
        #expect(!third.recovery.uncleanShutdown)
        #expect(third.recovery.stateEventsFolded == 0)
        #expect(await third.state() == expected)
        try await third.close()
    }

    @Test func laggingProjectionsAreRebuiltOnOpen() async throws {
        let t = try await Stores.fixture("linked-transition-caption-undone", on: .disk)
        let dir = try #require(t.dir)
        let expected = await t.store.state()
        try await t.store.flush()
        let snapshot = try t.store.projectionSnapshot()
        try await t.store.close()
        // Simulate a projection bug: query tables and history lag the log.
        let queue = try DatabaseQueue(path: dir.file("project.sqlite").path)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM transitions; DELETE FROM clips; DELETE FROM history")
            try db.execute(sql: "UPDATE projection_state SET last_seq = 1 WHERE name IN ('query_tables', 'history')")
        }
        try queue.close()
        let reopened = try SQLiteProjectStore(databaseAt: dir.file("project.sqlite").path, ids: t.ids, clock: t.clock)
        #expect(reopened.recovery.projectionsRebuilt)
        #expect(await reopened.state() == expected)
        let rebuilt = try reopened.projectionSnapshot()
        #expect(rebuilt.clips == snapshot.clips)
        #expect(rebuilt.history == snapshot.history)
        #expect(rebuilt.state == snapshot.state)
        try await reopened.close()
    }

    @Test func corruptFileIsRefusedAfterUncleanShutdown() async throws {
        let t = try await Stores.fixture(on: .disk)
        let dir = try #require(t.dir)
        try await t.store.terminateAbruptly()
        // Fold the WAL into the main file first, or SQLite would repair the damage from the WAL frames.
        let path = dir.file("project.sqlite")
        let folder = try DatabaseQueue(path: path.path)
        _ = try await folder.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        try folder.close()
        try? FileManager.default.removeItem(at: dir.file("project.sqlite-wal"))
        try? FileManager.default.removeItem(at: dir.file("project.sqlite-shm"))
        // Overwrite the pages after the header with garbage.
        let handle = try FileHandle(forWritingTo: path)
        try handle.seek(toOffset: 4096 + 64)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 4096 * 4))
        try handle.close()
        let error = #expect(throws: (any Error).self) {
            _ = try SQLiteProjectStore(databaseAt: path.path, ids: t.ids, clock: t.clock)
        }
        #expect(error != nil)
    }

    @Test func commandsOlderThanThirtyDaysArePrunedOnOpen() async throws {
        let start = Date(timeIntervalSince1970: 1_788_825_600)
        let t = try await Stores.fixture(on: .disk, options: .init())
        let dir = try #require(t.dir)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        let old = t.command(Fixtures.opacity(clip, 0.1))
        _ = try await t.store.apply(old)
        try await t.store.close()
        // The fixture clock is at `start`; reopen 31 days later.
        let later = FixedClock(start.addingTimeInterval(31 * 86400), step: 1)
        let reopened = try SQLiteProjectStore(databaseAt: dir.file("project.sqlite").path, ids: t.ids, clock: later)
        #expect(reopened.recovery.commandsPruned == 1)
        #expect(try reopened.scalar("SELECT COUNT(*) FROM commands") == 0)
        // Outside the idempotency window the same command id is evaluated afresh.
        let again = try await reopened.apply(old)
        #expect(again.status == .noop)
        try await reopened.close()
    }

    @Test(arguments: Backend.allCases) func schemaIsStrictAndVersioned(_ backend: Backend) async throws {
        let t = try Stores.blank(backend)
        let userVersion: Int? = try t.store.scalar("PRAGMA user_version")
        #expect(userVersion == Schema.currentUserVersion)
        let migrations: [String] = try await t.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(migrations == ["v1", "v2", "v3"])
        let strict = #expect(throws: DatabaseError.self) {
            try t.store.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO project_state (id, version, last_seq, state) VALUES (1, 'x', 0, '{}')")
            }
        }
        #expect(strict?.extendedResultCode == .SQLITE_CONSTRAINT_DATATYPE)
        let generated: [Row] = try t.store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT name, hidden FROM pragma_table_xinfo('events') WHERE name = 'clip_id'")
        }
        #expect(generated.first?["hidden"] == 2)
        let plan: [String] = try await t.store.writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT seq FROM events WHERE clip_id = 'c'")
                .map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("events_clip_idx") })
        try await t.store.close()
    }

    @Test func journalModeFollowsTheOptions() async throws {
        var options = SQLiteProjectStore.Options()
        let wal = try Stores.blank(.disk, options: options)
        #expect(try wal.store.scalar("PRAGMA journal_mode") == "wal")
        #expect(try wal.store.scalar("PRAGMA synchronous") == 1)
        #expect(try wal.store.scalar("PRAGMA foreign_keys") == 1)
        // GRDB installs a busy handler (5 s writer, 10 s readers); the pragma reports the reader's.
        #expect(try wal.store.scalar("PRAGMA busy_timeout") == 10000)
        try await wal.store.close()
        options.journal = .delete
        let delete = try Stores.blank(.disk, options: options)
        #expect(try delete.store.scalar("PRAGMA journal_mode") == "delete")
        #expect(try delete.store.scalar("PRAGMA synchronous") == 2)
        try await delete.store.close()
    }
}
