import Contracts
import ContractsTestSupport
import Foundation
import GRDB
import Testing
import TimelineCore

@testable import ProjectStore

/// The protocol semantics of `Contracts.ProjectStore`, run against the in-memory and on-disk backends and
/// compared with `FakeProjectStore` where the two can be lined up.
@Suite struct StoreBehaviourTests {
    @Test(arguments: Backend.allCases) func fixtureLoadsToTheSameStateAsTheFake(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let fake = try Stores.fake()
        #expect(await t.store.state() == fake.state())
        #expect(await t.store.version() == fake.version())
        #expect(await t.store.history().transactions == fake.history().transactions)
        #expect(try await t.store.events(since: 0) == fake.storedEvents)
        #expect(await t.store.projectId == fake.projectId)
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func applyAppendsBumpsVersionAndPublishes(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let store: any ProjectStore = t.store
        let before = await store.state()
        let clip = try #require(Fixtures.firstVideoClip(in: before))
        let changes = store.changes
        let first = Task { await firstValue(of: changes) }

        let result = try await store.apply(t.command(Fixtures.trimTail(clip)))

        #expect(result.status == .applied)
        #expect(result.version == before.version + 1)
        #expect(result.firstSeq == before.version + 1)
        #expect(result.lastSeq == result.version)
        #expect(result.changedIds == [clip.id.rawValue])
        #expect(await store.version() == result.version)
        let after = await store.state()
        #expect(after.activeSequence?.clip(clip.id)?.sourceOut == clip.sourceIn + Fixtures.frames(48))
        let change = try #require(await first.value)
        #expect(change.txnId == result.txnId)
        #expect(change.version == result.version)
        #expect(change.changedIds == result.changedIds)
        #expect(change.kind == .edit)
        #expect(change.label == "Trim clip")
        let events = try await store.events(since: before.version)
        #expect(events.count == 1)
        #expect(events[0].seq == result.firstSeq)
        #expect(events[0].streamVersion == result.version)
        #expect(events[0].event.txnId == result.txnId)
        // The commands row records the outcome.
        let status: String? = try t.store.scalar(
            "SELECT status FROM commands WHERE command_id = ?", [result.commandId.rawValue])
        #expect(status == "applied")
        try await store.close()
    }

    @Test(arguments: Backend.allCases) func sameScenarioMatchesTheFakeExactly(_ backend: Backend) async throws {
        // Both stores continue the fixture's SequentialIDGenerator and FixedClock, so txn and event ids agree.
        let t = try await Stores.fixture(on: backend)
        let fake = try Stores.fake()
        let clip = try #require(Fixtures.firstVideoClip(in: await fake.state()))
        let sequenceId = try #require(await fake.state().activeSequenceId)
        let commands: [Command] = [
            t.command(Fixtures.trimTail(clip, by: 60), label: "Trim to 60"),
            t.command(Fixtures.opacity(clip, 0.5), actor: .agent(sessionId: "s")),
            t.command(.moveClip(.init(clipId: .id(clip.id), to: .init(start: clip.start), mode: .overwrite))),
            t.command(.undo(.init())),
            t.command(.redo),
            t.command(.undo(.init())),
            t.command(.addMarker(.init(sequenceId: .id(sequenceId), at: .zero, label: "x"))),
            t.command(.redo),
        ]
        for command in commands {
            let a = await outcome(of: fake, command)
            let b = await outcome(of: t.store, command)
            switch (a, b) {
            case (.success(let x), .success(let y)): #expect(x == y)
            case (.failure(let x), .failure(let y)): #expect(x == y)
            default: Issue.record("outcomes differ for \(command.operation.typeName): \(a) vs \(b)")
            }
        }
        #expect(await t.store.state() == fake.state())
        #expect(await t.store.history().live == fake.history().live)
        #expect(await t.store.history().redoStack == fake.history().redoStack)
        // The store reads the injected clock once per command for `commands.received_at`, so timestamps
        // drift by one tick per command against the fake; everything else is identical.
        #expect(
            await t.store.history().transactions.map(\.withoutTimestamps)
                == fake.history().transactions.map(\.withoutTimestamps))
        #expect(
            try await t.store.events(since: 0).map(\.withoutTimestamps) == fake.storedEvents.map(\.withoutTimestamps))
        #expect(await t.store.changedSince(3) == fake.changedSince(3))
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func staleVersionIsRejectedWithChangedSince(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        let version = await t.store.version()
        try await t.apply(Fixtures.trimTail(clip, by: 60), label: "Custom trim label")

        let stale = t.command(Fixtures.opacity(clip, 0.5), actor: .agent(sessionId: "s"), expectedVersion: version)
        let error = await #expect(throws: EditorError.self) { try await t.store.apply(stale) }
        guard case .staleVersion(let current, let changed) = error else {
            Issue.record("expected staleVersion, got \(String(describing: error))")
            return
        }
        #expect(current == version + 1)
        let diff = try #require(changed)
        #expect(diff.fromVersion == version)
        #expect(diff.toVersion == version + 1)
        #expect(diff.transactions.count == 1)
        #expect(diff.transactions[0].label == "Custom trim label")
        #expect(diff.transactions[0].changedIds == [clip.id.rawValue])
        #expect(diff.transactions[0].events[0].type == "ClipTrimmed")
        #expect(await t.store.changedSince(version) == diff)
        // Recorded as stale; a retry with the same id replays the rejection without re-deciding.
        let status: String? = try t.store.scalar(
            "SELECT status FROM commands WHERE command_id = ?", [stale.commandId.rawValue])
        #expect(status == "stale")
        let again = await #expect(throws: EditorError.self) { try await t.store.apply(stale) }
        #expect(again == error)
        #expect(await t.store.version() == version + 1)
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func duplicateCommandIdReplaysTheStoredResult(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        let command = t.command(Fixtures.trimTail(clip))
        let first = try await t.store.apply(command)
        let second = try await t.store.apply(command)
        #expect(second.status == .replayed)
        #expect(second.txnId == first.txnId)
        #expect(second.version == first.version)
        #expect(second.firstSeq == first.firstSeq)
        #expect(second.changedIds == first.changedIds)
        #expect(await t.store.version() == first.version)
        let count: Int? = try t.store.scalar("SELECT COUNT(*) FROM events")
        #expect(count == Int(first.version))
        let commands: Int? = try t.store.scalar("SELECT COUNT(*) FROM commands")
        #expect(commands == 1)
        // A replay is not misreported as stale even when the version moved on.
        try await t.apply(Fixtures.opacity(clip, 0.3))
        let third = try await t.store.apply(command)
        #expect(third.status == .replayed)
        #expect(third.version == first.version)
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func invalidCommandsAreRecordedAndReplayed(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let version = await t.store.version()
        let bad = t.command(.removeClip(.init(clipId: "nope")))
        let error = await #expect(throws: EditorError.self) { try await t.store.apply(bad) }
        #expect(error == .notFound(id: "nope"))
        let status: String? = try t.store.scalar(
            "SELECT status FROM commands WHERE command_id = ?", [bad.commandId.rawValue])
        #expect(status == "invalid")
        let again = await #expect(throws: EditorError.self) { try await t.store.apply(bad) }
        #expect(again == error)
        #expect(await t.store.version() == version)
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func noopCommandDoesNotBumpTheVersion(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        let version = await t.store.version()
        let result = try await t.apply(
            .moveClip(.init(clipId: .id(clip.id), to: .init(start: clip.start), mode: .overwrite)))
        #expect(result.status == .noop)
        #expect(result.txnId == nil)
        #expect(result.version == version)
        #expect(await t.store.version() == version)
        let status: String? = try t.store.scalar(
            "SELECT status FROM commands WHERE command_id = ?", [result.commandId.rawValue])
        #expect(status == "noop")
        #expect(
            try t.store.rows("history", orderBy: "first_seq").count == Int(await t.store.history().transactions.count))
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func undoRedoUndoAndNewEditFoldTheHistory(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let original = await t.store.state()
        let clip = try #require(Fixtures.firstVideoClip(in: original))
        let trimmed = try await t.apply(Fixtures.trimTail(clip))
        let trimId = try #require(trimmed.txnId)
        let afterTrim = await t.store.state()

        let undone = try await t.apply(.undo(.init()))
        #expect(undone.status == .applied)
        var h = await t.store.history()
        #expect(!h.live.contains(trimId))
        #expect(h.redoStack == [trimId])
        #expect(await t.store.state().sequences == original.sequences)
        var live: Bool? = try t.store.scalar("SELECT live FROM history WHERE txn_id = ?", [trimId.rawValue])
        #expect(live == false)

        let redone = try await t.apply(.redo)
        #expect(redone.status == .applied)
        h = await t.store.history()
        #expect(h.live.last == trimId)
        #expect(h.redoStack.isEmpty)
        #expect(await t.store.state().sequences == afterTrim.sequences)
        live = try t.store.scalar("SELECT live FROM history WHERE txn_id = ?", [trimId.rawValue])
        #expect(live == true)

        try await t.apply(.undo(.init()))
        h = await t.store.history()
        #expect(h.redoStack == [trimId])
        #expect(await t.store.state().sequences == original.sequences)

        // A new edit after an undo empties the redo stack; the undone transaction stays in the log.
        let opacity = try await t.apply(Fixtures.opacity(clip, 0.5))
        h = await t.store.history()
        #expect(h.redoStack.isEmpty)
        #expect(h.live.last == opacity.txnId)
        #expect(h.undone.contains(trimId))
        await #expect(throws: EditorError.nothingToRedo) { try await t.store.apply(t.command(.redo)) }

        // The stored history rows agree with Core's fold of the stored log.
        let stored = try await t.store.events(since: 0)
        let folded = History.fold(events: stored.map(\.event), labels: Stores.labels(of: h))
        #expect(folded.live == h.live)
        #expect(folded.redoStack == h.redoStack)
        #expect(folded.transactions == h.transactions)
        let rows = try t.store.rows("history", orderBy: "first_seq")
        #expect(rows.count == h.transactions.count)
        for (row, txn) in zip(rows, h.transactions) {
            #expect(row["txn_id"] == txn.id.rawValue)
            #expect(row["kind"] == txn.kind.rawValue)
            #expect(row["label"] == txn.label)
            #expect(row["target_txn"] == txn.target?.rawValue)
            #expect((row["live"] as Bool) == (txn.kind == .edit ? h.isLive(txn.id) : true))
        }
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func batchWithRefsIsOneTransaction(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        let result = try await t.apply(
            .batch([
                .splitClip(.init(clipId: .id(clip.id), at: clip.start + Fixtures.frames(48))),
                .addTransition(
                    .init(
                        leftClipId: .id(clip.id), rightClipId: .ref(0), kind: "dissolve", duration: Fixtures.frames(8))),
            ]))
        #expect(result.status == .applied)
        let events = try await t.store.events(since: result.firstSeq! - 1)
        #expect(events.map(\.event.type) == ["ClipSplit", "TransitionAdded"])
        #expect(Set(events.map(\.event.txnId)).count == 1)
        #expect(await t.store.history().transactions.last?.label == "2 edits")
        let transitions = try t.store.rows("transitions", orderBy: "transition_id")
        #expect(transitions.count == 1)
        #expect(transitions[0]["left_clip_id"] == clip.id.rawValue)
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func closedStoreRejectsEverything(_ backend: Backend) async throws {
        let t = try await Stores.fixture("empty", on: backend)
        let changes = t.store.changes
        try await t.store.close()
        #expect(await t.store.isClosed)
        await #expect(throws: EditorError.self) { try await t.store.apply(t.command(.renameProject(.init(name: "x")))) }
        await #expect(throws: ProjectStoreError.closed) { try await t.store.events(since: 0) }
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        try await t.store.close()  // idempotent
    }

    @Test(arguments: Backend.allCases) func queryTablesFollowEveryKindOfEvent(_ backend: Backend) async throws {
        let t = try await Stores.fixture("linked-transition-caption-undone", on: backend)
        let state = await t.store.state()
        let seq = try #require(state.activeSequence)
        let clipCount = seq.tracks.reduce(0) { $0 + $1.clips.count }
        #expect(try t.store.rows("clips", orderBy: "clip_id").count == clipCount)
        #expect(try t.store.rows("tracks", orderBy: "track_id").count == seq.tracks.count)
        #expect(try t.store.rows("transitions", orderBy: "transition_id").count == seq.transitions.count)
        #expect(try t.store.rows("markers", orderBy: "marker_id").count == seq.markers.count)
        #expect(try t.store.rows("assets", orderBy: "asset_id").count == state.assets.count)
        let positions = try t.store.rows("tracks", orderBy: "position").map { $0["track_id"] as String }
        #expect(positions == seq.tracks.map(\.id.rawValue))

        // Remove a track, reorder, remove a clip with its transition, replace captions: rows follow.
        let audio = try #require(seq.tracks.first { $0.kind == .audio })
        try await t.apply(.removeTrack(.init(trackId: .id(audio.id))))
        #expect(try t.store.rows("tracks", orderBy: "track_id").count == seq.tracks.count - 1)
        let after = try #require(await t.store.state().activeSequence)
        let positionsAfter = try t.store.rows("tracks", orderBy: "position").map { $0["track_id"] as String }
        #expect(positionsAfter == after.tracks.map(\.id.rawValue))
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        try await t.apply(.removeClip(.init(clipId: .id(clip.id), mode: .overwrite)))
        #expect(try t.store.rows("transitions", orderBy: "transition_id").isEmpty)
        #expect(try t.store.scalar("SELECT COUNT(*) FROM clips WHERE clip_id = ?", [clip.id.rawValue]) == 0)
        let captions = try #require(after.tracks.first { $0.kind == .caption })
        try await t.apply(.replaceCaptions(.init(trackId: .id(captions.id), items: [])))
        #expect(try t.store.scalar("SELECT COUNT(*) FROM clips WHERE track_id = ?", [captions.id.rawValue]) == 0)
        try await t.apply(.undo(.init()))
        #expect(
            try t.store.scalar("SELECT COUNT(*) FROM clips WHERE track_id = ?", [captions.id.rawValue])
                == captions.clips.count)
        // Everything the incremental path wrote is what a rebuild writes.
        let before = try t.store.projectionSnapshot()
        try await t.store.flush()
        let flushed = try t.store.projectionSnapshot()
        try await t.store.rebuildProjections()
        let rebuilt = try t.store.projectionSnapshot()
        #expect(before.clips == rebuilt.clips)
        #expect(flushed == rebuilt)
        try await t.store.close()
    }

    @Test func clipRowRoundTripsTheModelClip() async throws {
        let t = try await Stores.fixture("linked-transition-caption-undone", on: .memory)
        let state = await t.store.state()
        let rows = try await t.store.writer.read { db in try ClipRow.fetchAll(db, sql: "SELECT * FROM clips") }
        for row in rows {
            let clip = try row.clip()
            #expect(state.activeSequence?.clip(clip.id) == clip)
        }
        try await t.store.close()
    }
}

extension DomainEvent {
    var withoutTimestamp: DomainEvent {
        var e = self
        e.occurredAt = Date(timeIntervalSince1970: 0)
        return e
    }
}

extension StoredEvent {
    var withoutTimestamps: StoredEvent {
        StoredEvent(seq: seq, streamVersion: streamVersion, event: event.withoutTimestamp)
    }
}

extension Transaction {
    var withoutTimestamps: Transaction {
        var t = self
        t.events = events.map(\.withoutTimestamp)
        return t
    }
}

func outcome(of store: any ProjectStore, _ command: Command) async -> Result<CommandResult, EditorError> {
    do {
        return .success(try await store.apply(command))
    } catch {
        return .failure(error)
    }
}
