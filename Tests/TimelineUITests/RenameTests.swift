import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import TimelineUI

@MainActor
@Suite("Project rename")
struct RenameTests {
    @Test func aNameIsTrimmedAndBlankIsRefused() {
        var rename = ProjectRename(current: "Untitled")
        #expect(rename.isUnchanged)
        #expect(rename.validationError == nil)
        #expect(rename.operation == nil)

        rename.name = "  Reel  "
        #expect(rename.trimmed == "Reel")
        #expect(!rename.isUnchanged)
        #expect(rename.canSubmit)

        rename.name = ""
        #expect(rename.validationError == ProjectRenameText.emptyError)
        #expect(!rename.canSubmit)
        #expect(rename.operation == nil)

        rename.name = "   \n\t "
        #expect(rename.validationError == ProjectRenameText.emptyError)
        #expect(rename.operation == nil)
    }

    /// Whitespace around the current name is not a rename: the trimmed form is what would be stored.
    @Test func paddingTheCurrentNameIsStillUnchanged() {
        var rename = ProjectRename(current: "Untitled")
        rename.name = "  Untitled\n"
        #expect(rename.isUnchanged)
        #expect(rename.canSubmit)
        #expect(rename.operation == nil)
    }

    @Test func theCapIsAHundredAndTwentyCharacters() {
        var rename = ProjectRename(current: "Untitled")
        rename.name = String(repeating: "a", count: ProjectRename.maximumLength)
        #expect(rename.validationError == nil)
        #expect(rename.remaining == 0)
        #expect(rename.operation != nil)

        rename.name = String(repeating: "a", count: ProjectRename.maximumLength + 1)
        #expect(rename.validationError == ProjectRenameText.tooLongError(ProjectRename.maximumLength))
        #expect(rename.remaining == -1)
        #expect(rename.operation == nil)

        // The surrounding whitespace is not part of the length either.
        rename.name = " " + String(repeating: "a", count: ProjectRename.maximumLength) + " "
        #expect(rename.validationError == nil)
    }

    @Test func theOperationCarriesTheTrimmedName() throws {
        var rename = ProjectRename(current: "Untitled")
        rename.name = "  Band rehearsal  "
        let operation = try #require(rename.operation)
        guard case .renameProject(let payload) = operation else {
            Issue.record("expected renameProject, got \(operation.typeName)")
            return
        }
        #expect(payload.name == "Band rehearsal")
    }

    @Test func renamingGoesThroughTheStoreAndIsUndoable() async throws {
        let f = try await UIFixture.make("three-clips")
        let before = f.viewModel.project.name
        var rename = ProjectRename(current: before)
        rename.name = "Band rehearsal"
        let operation = try #require(rename.operation)

        let result = await f.viewModel.apply(operation)
        #expect(result?.status == .applied)
        #expect(f.viewModel.project.name == "Band rehearsal")
        // The history names it from the event type; no command label is needed.
        #expect(f.viewModel.history.latestLive?.label == "Rename project")
        #expect(f.viewModel.lastError == nil)

        #expect(await f.viewModel.undo()?.status == .applied)
        #expect(f.viewModel.project.name == before)
        #expect(await f.viewModel.redo()?.status == .applied)
        #expect(f.viewModel.project.name == "Band rehearsal")
        #expect(await f.receivedCommands.map(\.operation.typeName) == ["renameProject", "undo", "redo"])
    }

    /// The sheet never sends this — `operation` is nil for an unchanged name — but the core agrees:
    /// the same name is a no-op that files no transaction.
    @Test func theSameNameIsANoOpAtTheStoreToo() async throws {
        let f = try await UIFixture.make("three-clips")
        let live = f.viewModel.history.live.count
        let result = await f.viewModel.apply(.renameProject(.init(name: f.viewModel.project.name)))
        #expect(result?.status == .noop)
        #expect(f.viewModel.history.live.count == live)
        #expect(f.viewModel.lastError == nil)
    }

    @Test func aRefusedRenameLeavesTheNameAloneAndReportsTheError() async throws {
        let f = try await UIFixture.make("three-clips")
        let before = f.viewModel.project.name
        try await f.store.close()

        var rename = ProjectRename(current: before)
        rename.name = "Band rehearsal"
        #expect(await f.viewModel.apply(try #require(rename.operation)) == nil)
        #expect(f.viewModel.lastError != nil)
        #expect(f.viewModel.project.name == before)
    }
}
