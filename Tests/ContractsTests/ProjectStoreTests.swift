import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@Suite struct FakeProjectStoreTests {
    private func trim(_ clip: Clip, by frames: Int64 = 48) -> Command.Operation {
        .trimClip(
            .init(clipId: .id(clip.id), edge: .tail, to: clip.start + Fixtures.frames(frames), mode: .overwrite))
    }

    @Test func applyAppendsEventsBumpsVersionAndPublishesAChange() async throws {
        let store: any ProjectStore = try Fixtures.store("three-clips")
        let before = await store.state()
        let clip = try #require(Fixtures.firstVideoClip(in: before))
        let changes = store.changes
        let first = Task { await changes.first { _ in true } }

        let result = try await store.apply(Fixtures.command(trim(clip)))

        #expect(result.status == .applied)
        #expect(result.version == before.version + 1)
        #expect(result.firstSeq == before.version + 1)
        #expect(result.lastSeq == result.version)
        #expect(result.changedIds.contains(clip.id.rawValue))
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
        #expect(events[0].event.txnId == result.txnId)
    }

    @Test func staleExpectedVersionIsRejectedWithChangedSince() async throws {
        let store = try Fixtures.store("three-clips")
        let clip = try #require(Fixtures.firstVideoClip(in: await store.state()))
        let version = await store.version()
        try await store.apply(trim(clip, by: 60))

        let stale = Fixtures.command(
            .setClipOpacity(.init(clipId: .id(clip.id), after: .constant(0.5))), actor: .agent(sessionId: "s"),
            expectedVersion: version)
        let error = await #expect(throws: EditorError.self) { try await store.apply(stale) }
        guard case .staleVersion(let current, let changed) = error else {
            Issue.record("expected staleVersion, got \(String(describing: error))")
            return
        }
        #expect(current == version + 1)
        let diff = try #require(changed)
        #expect(diff.fromVersion == version)
        #expect(diff.toVersion == version + 1)
        #expect(diff.transactions.count == 1)
        #expect(diff.transactions[0].label == "Trim clip")
        #expect(diff.transactions[0].changedIds == [clip.id.rawValue])
        #expect(await store.changedSince(version) == diff)
        // The rejection is recorded: a retry with the same id gets the same rejection.
        await #expect(throws: EditorError.self) { try await store.apply(stale) }
        #expect(await store.receivedCommands.count == 3)
    }

    @Test func duplicateCommandIdReplaysTheStoredResult() async throws {
        let store = try Fixtures.store("three-clips")
        let clip = try #require(Fixtures.firstVideoClip(in: await store.state()))
        let command = Fixtures.command(trim(clip))
        let first = try await store.apply(command)
        let second = try await store.apply(command)
        #expect(second.status == .replayed)
        #expect(second.txnId == first.txnId)
        #expect(second.version == first.version)
        #expect(await store.version() == first.version)
        #expect(await store.storedEvents.count == Int(first.version))
    }

    @Test func noopCommandDoesNotBumpTheVersion() async throws {
        let store = try Fixtures.store("three-clips")
        let clip = try #require(Fixtures.firstVideoClip(in: await store.state()))
        let version = await store.version()
        let result = try await store.apply(
            .moveClip(.init(clipId: .id(clip.id), to: .init(start: clip.start), mode: .overwrite)))
        #expect(result.status == .noop)
        #expect(result.txnId == nil)
        #expect(result.version == version)
        #expect(await store.version() == version)
    }

    @Test func undoAndRedoDriveTheHistoryFold() async throws {
        let store = try Fixtures.store("three-clips")
        let original = await store.state()
        let clip = try #require(Fixtures.firstVideoClip(in: original))
        let trimmed = try await store.apply(trim(clip))
        let afterTrim = await store.state()

        let undone = try await store.apply(.undo(.init()))
        #expect(undone.status == .applied)
        let h1 = await store.history()
        #expect(h1.live.contains(trimmed.txnId!) == false)
        #expect(h1.redoStack == [trimmed.txnId!])
        let restored = await store.state()
        #expect(restored.sequences == original.sequences)

        let redone = try await store.apply(.redo)
        #expect(redone.status == .applied)
        let h2 = await store.history()
        #expect(h2.live.last == trimmed.txnId)
        #expect(h2.redoStack.isEmpty)
        #expect(await store.state().sequences == afterTrim.sequences)

        await #expect(throws: EditorError.nothingToRedo) { try await store.apply(.redo) }
    }

    @Test func historyMatchesCoresFoldOfTheLog() async throws {
        let store = try Fixtures.store("linked-transition-caption-undone")
        let clip = try #require(Fixtures.firstVideoClip(in: await store.state()))
        try await store.apply(.setClipOpacity(.init(clipId: .id(clip.id), after: .constant(0.25))))
        try await store.apply(.undo(.init()))
        let stored = await store.storedEvents
        let history = await store.history()
        let labels = Dictionary(uniqueKeysWithValues: history.transactions.map { ($0.id, $0.label) })
        let folded = History.fold(events: stored.map(\.event), labels: labels)
        #expect(folded.live == history.live)
        #expect(folded.redoStack == history.redoStack)
        #expect(folded.transactions == history.transactions)
        #expect(stored.map(\.seq) == Array(1...Int64(stored.count)))
        let version = await store.version()
        #expect(Int64(stored.count) == version)
        try await store.rebuildProjections()
        #expect(await store.rebuildCount == 1)
    }

    @Test func closedStoreRejectsCommands() async throws {
        let store = try Fixtures.store("empty")
        let changes = store.changes
        try await store.close()
        await #expect(throws: EditorError.self) { try await store.apply(.renameProject(.init(name: "x"))) }
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func openerCreatesAndOpensStores() async throws {
        let opener: any ProjectStoreOpening = FakeProjectStoreOpener()
        let url = URL(fileURLWithPath: "/tmp/Test.tlproj")
        let created = try await opener.create(
            at: url, name: "New", settings: ProjectSettings(),
            sequence: .init(name: "Seq", frameDuration: Fixtures.frameDuration, width: 1920, height: 1080))
        #expect(await created.version() == 1)
        #expect(await created.state().name == "New")
        let opened = try await opener.open(at: url)
        #expect(await opened.projectId == created.projectId)
        await #expect(throws: FakeStoreError.self) { try await opener.open(at: URL(fileURLWithPath: "/tmp/No.tlproj")) }
    }

    @Test func directoryResolvesFrontmostAndById() async throws {
        let a = try Fixtures.store("three-clips")
        // A generated project carries the seed in its ids, so it does not collide with the fixture's.
        let b = FakeProjectStore(builder: try Fixtures.generated(seed: 7))
        let directory = FakeProjectDirectory()
        await directory.add(a, url: URL(fileURLWithPath: "/tmp/A.tlproj"))
        await directory.add(b)
        let projects: any ProjectDirectory = directory
        #expect(await projects.open().count == 2)
        #expect(await projects.frontmost()?.id == a.projectId)
        #expect(await projects.frontmost()?.url?.lastPathComponent == "A.tlproj")
        await directory.setFrontmost(await b.projectId)
        #expect(await projects.frontmost()?.name == "Generated 7")
        #expect(await projects.store(for: a.projectId)?.projectId == a.projectId)
        #expect(await projects.store(for: "nope") == nil)
    }
}
