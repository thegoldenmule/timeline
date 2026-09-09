import Contracts
import ContractsTestSupport
import Foundation
import SwiftUI
import Testing
import TimelineCore

@testable import TimelineUI

@MainActor
@Suite("Approval cards")
struct ApprovalTests {
    @Test func approvalRoundTripGrantsAConsumableToken() async throws {
        let gate = FakeApprovalGate(policy: .standard)
        let center = ApprovalCenter(gate: gate)
        await center.start()
        defer { center.stop() }

        // A tool hits the gate and is told to ask.
        let decision = await gate.check(
            tool: "render_export", input: ToolInput(["preset": "reel9x16"]), estimate: Estimate(seconds: 42),
            actor: .agent(sessionId: "s1"), sessionId: "s1")
        guard case .required(let request) = decision else {
            Issue.record("expected approval_required")
            return
        }
        #expect(await eventually { center.requests.contains { $0.id == request.id } })
        #expect(center.requests.count == 1)

        // The card's approve action grants the token; the tool can now consume it exactly once.
        let card = ApprovalCardView(request: request, onApprove: {}, onDeny: {})
        #expect(card.request.token == request.token)
        #expect(ApprovalCardView.estimateText(request.estimate) == "42 s")
        await center.approve(request)
        #expect(center.requests.isEmpty)
        #expect(center.answered.count == 1)
        #expect(await gate.pending().isEmpty)
        #expect(await gate.consume(request.token) == true)
        #expect(await gate.consume(request.token) == false)

        // A second request, approved through the card, lets the retry carrying the token pass the gate.
        guard
            case .required(let second) = await gate.check(
                tool: "render_export", input: ToolInput(["preset": "reel9x16"]), estimate: Estimate(seconds: 42),
                actor: .agent(sessionId: "s1"), sessionId: "s1")
        else {
            Issue.record("expected approval_required")
            return
        }
        #expect(await eventually { center.requests.contains { $0.id == second.id } })
        await center.approve(second)
        let retry = await gate.check(
            tool: "render_export",
            input: ToolInput(["preset": "reel9x16", "approvalToken": .string(second.token.rawValue)]),
            estimate: Estimate(seconds: 42), actor: .agent(sessionId: "s1"), sessionId: "s1")
        #expect(retry == .granted)
        #expect(await gate.consume(second.token) == false)
        #expect(await gate.consumed == [request.token, second.token])
    }

    @Test func denyLeavesTheTokenUnusable() async throws {
        let gate = FakeApprovalGate(policy: .standard)
        let center = ApprovalCenter(gate: gate)
        await center.start()
        defer { center.stop() }
        guard
            case .required(let request) = await gate.check(
                tool: "render_export", input: ToolInput(), estimate: .none, actor: .human, sessionId: nil)
        else {
            Issue.record("expected approval_required")
            return
        }
        #expect(await eventually { !center.requests.isEmpty })
        await center.deny(request, reason: "not now")
        #expect(await gate.consume(request.token) == false)
        #expect(await gate.denied[request.token] == "not now")
        #expect(center.requests.isEmpty)
    }

    @Test func pendingRequestsLoadOnStartAndTheStackRenders() async throws {
        let gate = FakeApprovalGate(policy: .approveEverything)
        _ = await gate.check(
            tool: "generate_tts", input: ToolInput(), estimate: Estimate(usd: 0.5), actor: .human, sessionId: nil)
        let center = ApprovalCenter(gate: gate)
        await center.start()
        defer { center.stop() }
        #expect(center.requests.count == 1)
        #expect(ApprovalCardView.estimateText(center.requests[0].estimate) == "$0.50")
        let renderer = ImageRenderer(content: ApprovalStackView(center: center).frame(width: 320))
        #expect(renderer.cgImage != nil)
    }
}

@MainActor
@Suite("Jobs")
struct JobTests {
    @Test func tracksProgressAndCompletion() async throws {
        let runner = FakeJobRunner()
        let center = JobCenter()
        let job = Job(kind: .export, memoryClass: .medium, label: "Export reel") { ctx in
            ctx.report(JobProgress(fraction: 0.5, stage: "encoding"))
            return JobOutcome(urls: [URL(fileURLWithPath: "/tmp/reel.mp4")])
        }
        let handle = await center.submit(job, to: runner)
        #expect(center.entries.count == 1)
        await center.drain()
        let entry = try #require(center.entry(handle.id))
        #expect(entry.state == .finished)
        #expect(entry.progress.fraction == 1)
        #expect(entry.outcome?.urls.count == 1)
        #expect(entry.label == "Export reel" && entry.kind == .export)
        let view = JobProgressView(entry: entry, onCancel: {})
        #expect(ImageRenderer(content: view.frame(width: 300)).cgImage != nil)
        #expect(ImageRenderer(content: JobList(center: center).frame(width: 300)).cgImage != nil)
        center.clearFinished()
        #expect(center.entries.isEmpty)
    }

    @Test func cancelStopsARunningJob() async throws {
        let runner = FakeJobRunner()
        let center = JobCenter()
        // Runs until cancelled, so a slow test host cannot let it finish first.
        let job = Job(kind: .transcription, memoryClass: .medium, label: "Transcribe") { ctx in
            var i = 0
            while true {
                try ctx.checkCancellation()
                i += 1
                ctx.report(JobProgress(fraction: min(0.99, Double(i) / 200)))
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let handle = await center.submit(job, to: runner)
        #expect(await eventually { center.entry(handle.id)?.progress.fraction ?? 0 > 0 })
        center.cancel(handle.id)
        #expect(handle.task.isCancelled)
        await center.drain()
        #expect(center.entry(handle.id)?.state == .cancelled)
        #expect(center.running.isEmpty)
    }

    @Test func failuresAreReported() async throws {
        let runner = FakeJobRunner()
        let center = JobCenter()
        let job = Job(kind: .hashing, memoryClass: .small, label: "Hash") { _ in
            throw JobError.failed(code: "io", message: "disk full")
        }
        let handle = await center.submit(job, to: runner)
        await center.drain()
        #expect(center.entry(handle.id)?.state == .failed("disk full"))
    }
}

@MainActor
@Suite("Agent panel")
struct AgentPanelTests {
    @Test func transcriptFoldsEventsAndAnswersApprovals() async throws {
        let request = Fixtures.approvalRequest()
        let script: [AgentEvent] = [
            .turnStarted(index: 1),
            .assistantText("Exporting."),
            .toolCall(id: "c1", name: "render_export", input: ["preset": "reel9x16"]),
            .approvalRequested(request),
            .toolResult(id: "c1", output: ["status": "ok"], isError: false),
            .cost(CostReport(usd: 0.02)),
            .finished(result: "Exported.", cost: CostReport(usd: 0.03, turns: 1)),
        ]
        let runtime = FakeAgentRuntime(
            script: script, followUps: [[.assistantText("Follow-up."), .finished(result: nil, cost: nil)]])
        let session = try await runtime.startSession(
            goal: "export", tools: Fixtures.toolAccess, policy: Fixtures.runtimePolicy)
        let gate = FakeApprovalGate(policy: .standard)
        let center = ApprovalCenter(gate: gate)
        let transcript = AgentTranscript(session: session, approvalCenter: center)
        transcript.start()

        #expect(await eventually { !transcript.pendingApprovals.isEmpty })
        #expect(center.requests.map(\.id) == [request.id])
        // The tool call is shown collapsed without its result yet.
        guard
            case .toolCall(_, let name, _, let output, _) = try #require(transcript.items.first { $0.id == "tool-c1" })
        else {
            Issue.record("expected tool call")
            return
        }
        #expect(name == "render_export" && output == nil)

        await transcript.approve(request, verdict: .approve)
        #expect(await eventually { transcript.isFinished })
        #expect(transcript.pendingApprovals.isEmpty)
        #expect(center.requests.isEmpty)
        let fake = try #require(session as? FakeAgentSession)
        #expect(fake.verdicts.map(\.verdict) == [.approve])
        guard
            case .toolCall(_, _, _, let result, let isError) = try #require(
                transcript.items.first { $0.id == "tool-c1" })
        else {
            Issue.record("expected tool call")
            return
        }
        #expect(result == ["status": "ok"] && !isError)
        #expect(abs(transcript.totalCostUSD - 0.05) < 1e-9)
        #expect(
            transcript.items.contains {
                if case .finished(_, "Exported.", _) = $0 { return true } else { return false }
            })

        // Sending continues the session with the follow-up script.
        try await transcript.send("  thanks ")
        #expect(fake.userMessages == ["thanks"])
        #expect(
            await eventually {
                transcript.items.contains { if case .text(_, "Follow-up.") = $0 { return true } else { return false } }
            })
        await transcript.waitUntilFinished()
        let panel = AgentPanelView(transcript: transcript)
        #expect(ImageRenderer(content: panel.frame(width: 400, height: 500)).cgImage != nil)
    }

    @Test func cancelledSessionsShowTheFailure() async throws {
        let runtime = FakeAgentRuntime(script: [.turnStarted(index: 1), .approvalRequested(Fixtures.approvalRequest())])
        let session = try await runtime.startSession(
            goal: "x", tools: Fixtures.toolAccess, policy: Fixtures.runtimePolicy)
        let transcript = AgentTranscript(session: session)
        transcript.start()
        #expect(await eventually { !transcript.pendingApprovals.isEmpty })
        await transcript.cancel()
        #expect(await eventually { transcript.isFinished })
        #expect(transcript.failure == .cancelled)
    }
}

@MainActor
@Suite("Inspector")
struct InspectorTests {
    @Test func eachCommittedGroupIsOneCommand() async throws {
        let f = try await UIFixture.make("three-clips")
        let clip = f.clips(.video)[0]
        f.viewModel.select(clip.id)
        var draft = InspectorDraft(clip)
        #expect(draft.operations(against: clip).isEmpty)

        // Typing changes the draft only; nothing reaches the store until commit.
        draft.opacity = 0.4
        draft.opacity = 0.5
        draft.transform.x = 10
        draft.transform.scale = 1.5
        #expect(draft.changedGroups(against: clip) == [.transform, .opacity])
        #expect(await f.receivedCommands.isEmpty)

        let opacity = await f.viewModel.commit(.opacity, from: draft)
        #expect(opacity?.status == .applied)
        var commands = await f.receivedCommands
        #expect(commands.count == 1)
        guard case .setClipOpacity(let op) = commands[0].operation else {
            Issue.record("expected setClipOpacity")
            return
        }
        #expect(op.after == .constant(0.5))
        #expect(f.viewModel.clip(clip.id)?.opacity == .constant(0.5))

        // Committing the same group again with no further change emits nothing.
        let again = await f.viewModel.commit(.opacity, from: draft)
        #expect(again == nil)
        #expect(await f.receivedCommands.count == 1)

        _ = await f.viewModel.commit(.transform, from: draft)
        commands = await f.receivedCommands
        #expect(commands.count == 2)
        guard case .setClipTransform(let t) = commands[1].operation else {
            Issue.record("expected setClipTransform")
            return
        }
        #expect(t.after == .constant(Transform(x: 10, scale: 1.5)))

        draft = InspectorDraft(f.viewModel.clip(clip.id)!)
        draft.muted = true
        draft.gain = 0.8
        _ = await f.viewModel.commit(.audio, from: draft)
        draft.speedPercent = 200
        _ = await f.viewModel.commit(.speed, from: draft)
        commands = await f.receivedCommands
        #expect(
            commands.map(\.operation.typeName) == [
                "setClipOpacity", "setClipTransform", "setClipAudio", "setClipSpeed",
            ])
        let updated = try #require(f.viewModel.clip(clip.id))
        #expect(updated.audio == ClipAudio(gain: .constant(0.8), muted: true, pitchCorrected: true))
        #expect(updated.speed == Rational(2, 1))
        #expect(f.viewModel.history.live.count == (await f.store.history()).live.count)
    }

    @Test func inspectorViewRendersForASelectionAndAnEmptySelection() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let empty = ImageRenderer(content: InspectorView(viewModel: f.viewModel).frame(width: 300, height: 400))
        #expect(empty.cgImage != nil)
        f.viewModel.select(f.clips(.video)[0].id)
        let selected = ImageRenderer(content: InspectorView(viewModel: f.viewModel).frame(width: 300, height: 600))
        #expect(selected.cgImage != nil)
        let history = ImageRenderer(content: HistoryView(viewModel: f.viewModel).frame(width: 300, height: 400))
        #expect(history.cgImage != nil)
    }
}
