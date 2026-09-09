import Contracts
import ContractsTestSupport
import Foundation
import GRDB
import Testing
import TimelineCore

@testable import ProjectStore

@Suite struct ObservationTests {
    @Test(arguments: Backend.allCases) func changesDeliverOnePerTransactionInOrder(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let clip = try #require(Fixtures.firstVideoClip(in: await t.store.state()))
        let changes = t.store.changes
        let collector = Task { () -> [ProjectChange] in
            var seen: [ProjectChange] = []
            for await c in changes {
                seen.append(c)
                if seen.count == 3 { break }
            }
            return seen
        }
        let a = try await t.apply(Fixtures.opacity(clip, 0.1))
        _ = try await t.apply(.moveClip(.init(clipId: .id(clip.id), to: .init(start: clip.start), mode: .overwrite)))
        let b = try await t.apply(.undo(.init()))
        let c = try await t.apply(.redo)
        let seen = await collector.value
        #expect(seen.map(\.txnId) == [a.txnId, b.txnId, c.txnId])
        #expect(seen.map(\.version) == [a.version, b.version, c.version])
        #expect(seen.map(\.kind) == [.edit, .undo, .redo])
        #expect(seen[1].label == "Undo")
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func valueObservationDeliversAfterApply(_ backend: Backend) async throws {
        let t = try await Stores.fixture(on: backend)
        let state = await t.store.state()
        let sequenceId = try #require(state.activeSequenceId)
        let clip = try #require(Fixtures.firstVideoClip(in: state))
        let clips = t.store.observeClips(sequenceId: sequenceId)
        var iterator = clips.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.count == 4)
        #expect(initial.first { $0.clipId == clip.id.rawValue }?.sourceOut == clip.sourceOut)

        try await t.apply(Fixtures.trimTail(clip, by: 48))
        let next = try #require(await iterator.next())
        #expect(next.first { $0.clipId == clip.id.rawValue }?.sourceOut == clip.sourceIn + Fixtures.frames(48))

        try await t.apply(.removeClip(.init(clipId: .id(clip.id), mode: .overwrite)))
        let removed = try #require(await iterator.next())
        #expect(removed.count == 3)
        #expect(!removed.contains { $0.clipId == clip.id.rawValue })

        let versions = t.store.observeVersion()
        var v = versions.makeAsyncIterator()
        #expect(await v.next() == state.version + 2)
        try await t.apply(.undo(.init()))
        #expect(await v.next() == state.version + 4)
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func stateObservationFollowsTheDebouncedWrite(_ backend: Backend) async throws {
        var options = SQLiteProjectStore.Options()
        options.stateWriteDebounce = .milliseconds(20)
        let t = try await Stores.fixture(on: backend, options: options)
        try await t.store.flush()
        let states = t.store.observeState()
        var iterator = states.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial == (await t.store.state()))
        try await t.apply(.renameProject(.init(name: "Debounced")))
        #expect(await t.store.isStateWritePending)
        let written = try #require(await iterator.next())
        #expect(written.name == "Debounced")
        #expect(!(await t.store.isStateWritePending))
        try await t.store.close()
    }

    @Test func streamsEndWhenTheStoreCloses() async throws {
        let t = try await Stores.fixture(on: .memory)
        let versions = t.store.observeVersion()
        var iterator = versions.makeAsyncIterator()
        _ = await iterator.next()
        try await t.store.close()
        #expect(await iterator.next() == nil)
    }
}
