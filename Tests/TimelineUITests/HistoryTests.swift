import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import Testing
import TimelineCore

@testable import TimelineUI

@MainActor
@Suite("Undo, redo, and store observation")
struct HistoryTests {
    @Test func moveThenUndoRestoresTheFixtureAndFillsTheRedoStack() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let clip = f.clips(.video)[2]
        let liveBefore = f.viewModel.history.live.count
        #expect(f.viewModel.history.redoStack.isEmpty)

        f.viewModel.beginGesture(.move, clip: clip.id, at: clip.start, modifiers: [])
        f.viewModel.updateGesture(to: clip.start + RationalTime(seconds: 3))
        let moved = await f.viewModel.commit()
        #expect(moved?.status == .applied)
        #expect(f.viewModel.clip(clip.id)!.start != clip.start)
        #expect(f.viewModel.history.live.count == liveBefore + 1)
        #expect(f.viewModel.canUndo)

        let undo = await f.viewModel.undo()
        #expect(undo?.status == .applied)
        #expect(f.viewModel.project.sequences == f.original.sequences)
        #expect(f.viewModel.project.assets == f.original.assets)
        #expect(f.viewModel.history.redoStack.count == 1)
        #expect(f.viewModel.history.live.count == liveBefore)
        #expect(f.viewModel.canRedo)
        let storeHistory = await f.store.history()
        #expect(storeHistory.redoStack == f.viewModel.history.redoStack)

        let redo = await f.viewModel.redo()
        #expect(redo?.status == .applied)
        #expect(f.viewModel.history.redoStack.isEmpty)
        #expect(f.viewModel.clip(clip.id)!.start != clip.start)
        // Undo, undo, redo, redo: three commands went through the view model plus the move.
        #expect(await f.receivedCommands.map(\.operation.typeName) == ["moveClip", "undo", "redo"])
    }

    @Test func undoWithNothingLiveEmitsNothing() async throws {
        let store = FakeProjectStore()
        let vm = TimelineViewModel(store: store)
        await vm.load()
        #expect(!vm.canUndo && !vm.canRedo)
        #expect(await vm.undo() == nil)
        #expect(await vm.redo() == nil)
        #expect(await store.receivedCommands.isEmpty)
    }

    @Test func fixtureWithAnUndoneTransactionStartsWithARedoTarget() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        #expect(f.viewModel.canRedo)
        let rows = f.viewModel.history.rows
        let last = try #require(rows.last)
        #expect(!last.isLive && last.isRedoTarget && last.label == "Trim clip")
        #expect(rows.dropLast().allSatisfy { $0.isLive })
        #expect(rows.filter(\.isUndoTarget).count == 1)
        _ = await f.viewModel.redo()
        #expect(!f.viewModel.canRedo)
        #expect(f.viewModel.history.rows.last?.isLive == true)
    }

    @Test func observesChangesMadeDirectlyOnTheStore() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.startObserving()
        defer { f.viewModel.stopObserving() }
        let clip = f.clips(.video)[0]
        f.viewModel.select(clip.id)
        let version = f.viewModel.project.version
        _ = try await f.store.apply(.removeClip(.init(clipId: .id(clip.id))), actor: .agent(sessionId: "s"))
        #expect(await eventually { f.viewModel.project.version > version })
        #expect(f.viewModel.clip(clip.id) == nil)
        // The selection dropped the removed clip.
        #expect(f.viewModel.selection.isEmpty)
        #expect(f.viewModel.history.live.count == (await f.store.history()).live.count)
    }

    @Test func rejectedCommandsSurfaceAsLastError() async throws {
        let f = try await UIFixture.make("three-clips")
        let result = await f.viewModel.apply(.removeClip(.init(clipId: "missing")))
        #expect(result == nil)
        #expect(f.viewModel.lastError == .notFound(id: "missing"))
        #expect(f.viewModel.commandCount == 0)
        _ = await f.viewModel.setClipOpacity(f.clips(.video)[0].id, 0.5)
        #expect(f.viewModel.lastError == nil)
    }
}
