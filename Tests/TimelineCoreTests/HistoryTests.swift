import Foundation
import Testing
import TimelineCore

@Suite struct HistoryTests {
    @Test func undoRedoUndoRestoresStates() throws {
        let s = try Scene()
        let c = try s.video(at: 0, length: 48)
        let v1 = s.b.project
        try s.b.apply(.trimClip(.init(clipId: .id(c), edge: .tail, to: frames(24))))
        let v2 = s.b.project
        let trimTxn = s.b.history.latestLive!.id

        let undo = try s.b.apply(.undo(.init()))
        #expect(undo.first?.type == "TransactionUndone")
        #expect(undo.last?.causationId != nil)
        #expect(s.b.project == v1.withVersion(s.b.project.version))
        #expect(s.b.history.live.last != trimTxn)
        #expect(s.b.history.undone == [trimTxn])
        #expect(s.b.history.redoTarget?.id == trimTxn)

        #expect(s.b.rejection(.undo(.init(txnId: trimTxn))) == .alreadyUndone)

        let redo = try s.b.apply(.redo)
        #expect(redo.first?.type == "TransactionRedone")
        #expect(s.b.project == v2.withVersion(s.b.project.version))
        #expect(s.b.history.latestLive?.id == trimTxn)
        #expect(s.b.history.redoStack.isEmpty)
        #expect(s.b.rejection(.redo) == .nothingToRedo)

        try s.b.apply(.undo(.init(txnId: trimTxn)))
        #expect(s.b.project == v1.withVersion(s.b.project.version))
        #expect(s.b.history.redoTarget?.id == trimTxn)
    }

    @Test func newTransactionAfterUndoEmptiesRedo() throws {
        let s = try Scene()
        let c = try s.video(at: 0, length: 48)
        try s.b.apply(.trimClip(.init(clipId: .id(c), edge: .tail, to: frames(24))))
        let trimTxn = s.b.history.latestLive!.id
        try s.b.apply(.undo(.init()))
        #expect(s.b.history.redoTarget?.id == trimTxn)
        try s.b.apply(.renameProject(.init(name: "New")))
        #expect(s.b.history.redoStack.isEmpty)
        #expect(s.b.rejection(.redo) == .nothingToRedo)
        #expect(s.b.history.undone.contains(trimTxn), "orphaned transactions stay undone")
        // Undo the rename: the redo stack holds only the rename, never the orphaned trim.
        try s.b.apply(.undo(.init()))
        #expect(s.b.history.redoStack.count == 1)
        #expect(s.b.history.redoTarget?.label == "Rename project")
        try s.b.apply(.redo)
        #expect(s.b.project.name == "New")
    }

    @Test func onlyLatestLiveCanBeUndone() throws {
        let s = try Scene()
        let c = try s.video(at: 0, length: 48)
        let addTxn = s.b.history.latestLive!.id
        try s.b.apply(.trimClip(.init(clipId: .id(c), edge: .tail, to: frames(24))))
        #expect(s.b.rejection(.undo(.init(txnId: addTxn))) != nil)
        #expect(s.b.rejection(.undo(.init(txnId: "missing"))) == .notFound(id: "missing"))
        let fresh = ProjectBuilder()
        try fresh.createProject()
        #expect(fresh.rejection(.undo(.init())) != nil, "project creation is not undoable")
    }

    @Test func undoRestoresRemovedTransitionAndLinks() throws {
        let s = try Scene()
        let a = try s.linked(at: 0, length: 24, sourceIn: 24)
        let b = try s.linked(at: 24, length: 24, sourceIn: 100)
        try s.b.apply(
            .addTransition(.init(leftClipId: .id(a), rightClipId: .id(b), kind: "dissolve", duration: frames(4))))
        let before = s.b.project
        try s.b.apply(.removeClip(.init(clipId: .id(b), mode: .ripple)))
        #expect(s.b.sequence.transitions.isEmpty)
        try s.b.apply(.undo(.init()))
        #expect(s.b.project == before.withVersion(s.b.project.version))
        try s.b.apply(.unlinkClips(.init(clipIds: [.id(a)])))
        try s.b.apply(.undo(.init()))
        #expect(s.b.clip(a)?.linkGroupId != nil)
    }

    @Test func undoPreconditionDetectsDrift() throws {
        let s = try Scene()
        let c = try s.video(at: 0, length: 48)
        try s.b.apply(.trimClip(.init(clipId: .id(c), edge: .tail, to: frames(24))))
        // Simulate a drifted state: change the clip behind history's back.
        var drifted = s.b.project
        drifted.sequences[s.b.sequenceId]!.tracks[0].clips[c]!.sourceOut = frames(30)
        #expect {
            try decide(drifted, s.b.command(.undo(.init())), ids: s.b.ids, clock: s.b.clock, history: s.b.history)
        } throws: { error in
            if case .invalid = error as? EditorError { return true }
            return false
        }
    }

    @Test func foldFromEventLogMatchesIncremental() throws {
        let s = try Scene()
        let c = try s.video(at: 0, length: 48)
        try s.b.apply(.trimClip(.init(clipId: .id(c), edge: .tail, to: frames(24))), label: "Trim")
        try s.b.apply(.undo(.init()))
        try s.b.apply(.redo)
        try s.b.apply(.undo(.init()))
        try s.b.apply(.renameProject(.init(name: "x")))
        let folded = History.fold(
            events: s.b.events,
            labels: Dictionary(uniqueKeysWithValues: s.b.history.transactions.map { ($0.id, $0.label) }))
        #expect(folded == s.b.history)
        #expect(
            folded.transactions.map(\.kind) == [.edit, .edit, .edit, .edit, .edit, .edit, .undo, .redo, .undo, .edit])
        #expect(folded.transactions[6].target == folded.transactions[5].id)
        #expect(Transaction.defaultLabel(for: folded.transactions[5].events) == "Trim clip")
        #expect(Transaction.defaultLabel(for: folded.transactions[6].events) == "Undo")
        let replayed = evolve(Project.blank, s.b.events)
        #expect(replayed == s.b.project)
    }

    @Test func changedSinceSummarises() throws {
        let s = try Scene()
        let c = try s.video(at: 0, length: 48)
        let from = s.b.project.version
        try s.b.apply(.trimClip(.init(clipId: .id(c), edge: .tail, to: frames(24))), label: "Trim it")
        let cs = ChangedSince.build(
            from: Array(s.b.events.dropFirst(Int(from))), fromVersion: from,
            labels: [s.b.history.latestLive!.id: "Trim it"])
        #expect(cs.toVersion == s.b.project.version)
        #expect(cs.transactions.count == 1)
        #expect(cs.transactions[0].label == "Trim it")
        #expect(cs.transactions[0].changedIds == [c.rawValue])
        #expect(cs.transactions[0].events[0].type == "ClipTrimmed")
        #expect(changedIds(of: s.b.events).contains(s.asset.rawValue))
        let data = try ProjectCodec.encode(cs)
        #expect(try ProjectCodec.decode(ChangedSince.self, from: data) == cs)
    }

    @Test func editorErrorCodable() throws {
        let errors: [EditorError] = [
            .staleVersion(current: 3, changedSince: nil), .invalid(reason: "r", suggestion: "s"), .trackLocked("t"),
            .transitionHandles(maxDuration: frames(3)), .notFound(id: "x"), .alreadyUndone, .nothingToRedo,
        ]
        for e in errors {
            let data = try ProjectCodec.encode(e)
            #expect(try ProjectCodec.decode(EditorError.self, from: data) == e)
            #expect(String(decoding: data, as: UTF8.self).contains("\"code\":\"\(e.code)\""))
        }
    }
}

extension Project {
    func withVersion(_ v: Int64) -> Project {
        var p = self
        p.version = v
        return p
    }
}
