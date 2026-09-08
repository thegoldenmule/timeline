import Contracts
import Foundation
import TimelineCore

/// `swift run TimelineApp --skeleton-check`: the whole walking-skeleton flow without a window. Prints one
/// line per step and a summary; returns false (exit 1) with the reason on the first failure.
@MainActor
enum SkeletonCheck {
    struct Failure: Error, CustomStringConvertible {
        var step: String
        var reason: String
        var description: String { "\(step): \(reason)" }
    }

    static func run() async -> Bool {
        let started = ContinuousClock.now
        var steps: [String] = []
        func ok(_ step: String, _ detail: String) {
            steps.append(step)
            print("ok   \(step): \(detail)")
        }
        func require(_ condition: Bool, _ step: String, _ reason: @autoclosure () -> String) throws {
            if !condition { throw Failure(step: step, reason: reason()) }
        }
        do {
            // 1. Composition root and the fixture project.
            let services = try await AppServices.fakes()
            let document = try await ProjectDocument.open(at: AppServices.fixtureURL, using: services)
            let opened = document.project
            try require(opened.name == "Three clips", "open", "unexpected project \(opened.name)")
            try require(opened.activeSequence != nil, "open", "no active sequence")
            try require(document.compiled != nil, "compile", "no Compiled after open")
            let initialVersion = document.version
            ok(
                "open",
                "\(opened.name) v\(initialVersion), \(opened.assets.count) assets, "
                    + "\(opened.activeSequence?.tracks.count ?? 0) tracks")
            ok(
                "compile",
                "structural \(document.compiled!.structuralFingerprint.prefix(8)) "
                    + "duration \(document.compiled!.duration.seconds)s hasAudio \(document.compiled!.hasAudio)")

            // 2. Player item reaches readyToPlay on the main actor.
            try require(document.playerItem != nil, "playerItem", "no player item attached")
            try await document.waitForReadyToPlay(timeout: .seconds(20))
            try require(document.player.currentItem === document.playerItem, "playerItem", "player holds another item")
            ok(
                "playerItem",
                "readyToPlay, seekingWaitsForVideoCompositionRendering="
                    + "\(document.playerItem!.seekingWaitsForVideoCompositionRendering)")

            // 3. A structural command: version bumps, the change arrives, a new item is attached.
            let generationBefore = document.playerItemGeneration
            let nudge = try await document.nudgeClip()
            try require(nudge.status == .applied, "moveClip", "status \(nudge.status)")
            try require(
                nudge.version > initialVersion, "moveClip",
                "version \(nudge.version) did not advance past \(initialVersion)")
            try await document.waitForVersion(nudge.version)
            try require(document.changes.last?.txnId == nudge.txnId, "changes", "last change is not the nudge")
            try require(
                document.changes.last?.kind == .edit, "changes",
                "kind \(String(describing: document.changes.last?.kind))")
            try require(
                document.lastRenderPath == .structural, "update", "expected structural, got \(document.lastRenderPath)")
            try require(document.playerItemGeneration == generationBefore + 1, "update", "player item was not replaced")
            try await document.waitForReadyToPlay(timeout: .seconds(20))
            ok(
                "moveClip",
                "v\(nudge.version) txn \(nudge.txnId!.rawValue.suffix(6)) changed \(nudge.changedIds.count) ids; "
                    + "structural update, new player item ready")

            // 4. An instructions-only command through the tool registry.
            let tools = ToolConsole(services: services)
            guard let clip = firstVideoClip(document.project) else {
                throw Failure(step: "timeline_apply", reason: "no video clip")
            }
            let op = try JSONValue(
                encoding: Command.Operation.setClipOpacity(.init(clipId: .id(clip.id), after: .constant(0.5))))
            let applied = try await tools.call("timeline_apply", input: ToolInput(["op": op]))
            try require(!applied.isError, "timeline_apply", applied.text ?? "error")
            let appliedVersion = Int64(
                try unwrap(applied.structured?["version"]?.intValue, "timeline_apply", "no version in output"))
            try require(
                appliedVersion > nudge.version, "timeline_apply",
                "version \(appliedVersion) did not advance past \(nudge.version)")
            try await document.waitForVersion(appliedVersion)
            try require(
                document.lastRenderPath == .instructionsOnly, "update",
                "expected instructionsOnly, got \(document.lastRenderPath)")
            try require(
                document.playerItemGeneration == generationBefore + 1, "update",
                "player item was replaced for an instruction edit")
            try require(
                document.changes.last?.actor == .human, "timeline_apply",
                "actor \(String(describing: document.changes.last?.actor))")
            ok("timeline_apply", "v\(appliedVersion) via registry; instructions-only update applied to the live item")

            // 5. A read-only tool.
            let describe = try await tools.describeProject()
            try require(!describe.isError, "project_describe", describe.text ?? "error")
            try require(
                describe.structured?["version"]?.intValue == Int(appliedVersion), "project_describe", "stale version")
            let trackCount = describe.structured?["sequences"]?[0]?["tracks"]?.arrayValue?.count ?? 0
            ok("project_describe", "\(describe.text ?? ""); \(trackCount) tracks in structured output")

            // 6. A job with progress.
            let jobs = JobConsole(services: services)
            let outcome = try await jobs.runDemoJob(project: document.project)
            try require(jobs.progress.count >= 2, "job", "only \(jobs.progress.count) progress events")
            try require(
                jobs.progress.last?.fraction == 1, "job",
                "last fraction \(String(describing: jobs.progress.last?.fraction))")
            let result = try unwrap(try outcome.payload(as: DemoJobResult.self), "job", "no payload")
            ok(
                "job",
                "\(jobs.label): \(jobs.progress.count) progress events, "
                    + "silence \(result.silenceRanges) shots \(result.shots) peaks \(result.peaks)")

            // 7. The scripted agent session with the approval round-trip through the gate.
            let agent = AgentConsole(services: services)
            try await agent.start(goal: "Export a vertical reel of the three clips")
            let deadline = ContinuousClock.now + .seconds(10)
            while agent.pending == nil, agent.finished == nil {
                guard ContinuousClock.now < deadline else {
                    throw Failure(step: "agent", reason: "no approval request")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let pending = try unwrap(agent.pending, "agent", "session finished without asking for approval")
            try require(pending.gate != nil, "agent", "the gate has no pending request for \(pending.scripted.tool)")
            try require(agent.gateRequests.count == 1, "agent", "gate published \(agent.gateRequests.count) requests")
            await agent.approve()
            await agent.runToCompletion()
            guard case .finished(let summary, let cost)? = agent.finished else {
                throw Failure(step: "agent", reason: "ended with \(String(describing: agent.finished))")
            }
            let executions = agent.appToolOutputs
            try require(executions.count == 3, "agent", "\(executions.count) app-side tool executions")
            try require(
                executions[0].name == "project_describe" && !executions[0].output.isError, "agent", "describe failed")
            try require(
                executions[1].output.isApprovalRequired && !executions[1].retried, "agent", "export was not gated")
            try require(
                executions[2].retried && !executions[2].output.isError && !executions[2].output.isApprovalRequired,
                "agent", "retry with token failed: \(executions[2].output.text ?? "")")
            try require(await services.approvals.pending().isEmpty, "agent", "gate still has pending requests")
            let receipt = try executions[2].output.structured?.decoded(as: ExportReceipt.self)
            try require(
                receipt.map { FileManager.default.fileExists(atPath: $0.outputURL.path) } == true, "agent",
                "no export file")
            ok(
                "agent",
                "\(agent.entries.count) entries, finished \"\(summary ?? "")\" cost $\(cost?.usd ?? 0); "
                    + "export gated, granted, retried, wrote \(receipt!.outputURL.lastPathComponent)")

            // 8. Undo and redo through the history fold.
            let beforeUndo = document.version
            try require(document.canUndo, "undo", "canUndo is false")
            let undone = try await document.undo()
            try await document.waitForVersion(undone.version)
            try require(document.history.redoTarget != nil, "undo", "redo stack is empty after undo")
            try require(
                document.changes.last?.kind == .undo, "undo",
                "change kind \(String(describing: document.changes.last?.kind))")
            let redone = try await document.redo()
            try await document.waitForVersion(redone.version)
            try require(
                document.changes.last?.kind == .redo, "redo",
                "change kind \(String(describing: document.changes.last?.kind))")
            try require(document.history.redoTarget == nil, "redo", "redo stack not empty after redo")
            try require(
                redone.version > undone.version && undone.version > beforeUndo, "redo",
                "versions \(beforeUndo) \(undone.version) \(redone.version) are not increasing")
            ok(
                "undo/redo",
                "v\(beforeUndo) -> v\(undone.version) -> v\(redone.version), "
                    + "\(document.history.live.count) live transactions")

            await document.close()
            let elapsed = ContinuousClock.now - started
            print("\nSkeleton check passed: \(steps.count) steps in \(elapsed) -- \(steps.joined(separator: ", "))")
            return true
        } catch {
            print("FAIL \(error)")
            return false
        }
    }

    private static func unwrap<T>(_ value: T?, _ step: String, _ reason: @autoclosure () -> String) throws -> T {
        guard let value else { throw Failure(step: step, reason: reason()) }
        return value
    }

    private static func firstVideoClip(_ project: Project) -> Clip? {
        project.activeSequence?.tracks.first { $0.kind == .video }?.clips.values.min { $0.start < $1.start }
    }
}
