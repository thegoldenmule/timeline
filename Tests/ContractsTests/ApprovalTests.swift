import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@Suite struct ApprovalGateTests {
    @Test func checkGrantConsumeOnce() async throws {
        let fake = FakeApprovalGate(policy: .standard)
        let gate: any ApprovalGate = fake
        let requests = gate.requests
        let firstRequest = Task { await requests.first { _ in true } }
        let input = ToolInput(["preset": "reel9x16", "projectId": "project-1"])

        let decision = await gate.check(
            tool: "render_export", input: input, estimate: Estimate(seconds: 30), actor: .agent(sessionId: "s"),
            sessionId: "s")
        guard case .required(let request) = decision else {
            Issue.record("expected .required")
            return
        }
        #expect(request.tool == "render_export")
        #expect(request.token == "tok-1")
        #expect(request.inputSummary == "render_export(preset=reel9x16, projectId=project-1)")
        #expect(await firstRequest.value == request)
        #expect(await gate.pending() == [request])
        #expect(await gate.consume(request.token) == false)

        await gate.grant(request.token)
        #expect(await gate.pending().isEmpty)
        #expect(await gate.consume(request.token) == true)
        #expect(await gate.consume(request.token) == false)
    }

    @Test func tokenInInputIsConsumedByCheck() async throws {
        let gate: any ApprovalGate = FakeApprovalGate(policy: .standard)
        let input = ToolInput(["preset": "proRes"])
        guard
            case .required(let request) = await gate.check(
                tool: "render_export", input: input, estimate: .none, actor: .human, sessionId: nil)
        else {
            Issue.record("expected .required")
            return
        }
        await gate.grant(request.token)
        var retry = input
        retry.arguments["approvalToken"] = .string(request.token.rawValue)
        #expect(
            await gate.check(tool: "render_export", input: retry, estimate: .none, actor: .human, sessionId: nil)
                == .granted)
        // The token is single-use: the same retry asks again.
        guard
            case .required(let again) = await gate.check(
                tool: "render_export", input: retry, estimate: .none, actor: .human, sessionId: nil)
        else {
            Issue.record("expected a new request")
            return
        }
        #expect(again.token != request.token)
    }

    @Test func policyDecidesWhoAsks() async throws {
        let gate: any ApprovalGate = FakeApprovalGate(policy: .standard)
        #expect(
            await gate.check(
                tool: "project_describe", input: ToolInput(), estimate: .none, actor: .human, sessionId: nil)
                == .granted)
        #expect(
            await gate.check(
                tool: "generate_tts", input: ToolInput(), estimate: Estimate(usd: 0), actor: .human, sessionId: nil)
                == .granted)
        let paid = await gate.check(
            tool: "generate_tts", input: ToolInput(), estimate: Estimate(usd: 0.5), actor: .human, sessionId: nil)
        #expect(paid != .granted)
        let strict: any ApprovalGate = FakeApprovalGate(policy: .approveEverything)
        #expect(
            await strict.check(
                tool: "project_describe", input: ToolInput(), estimate: .none, actor: .human, sessionId: nil)
                != .granted)
    }

    @Test func denyLeavesTokenUnusable() async throws {
        let fake = FakeApprovalGate()
        guard
            case .required(let request) = await fake.check(
                tool: "render_export", input: ToolInput(), estimate: .none, actor: .human, sessionId: nil)
        else {
            Issue.record("expected .required")
            return
        }
        await fake.deny(request.token, reason: "not now")
        #expect(await fake.consume(request.token) == false)
        #expect(await fake.denied[request.token] == "not now")
        #expect(await fake.pending().isEmpty)
    }

    @Test func rulesAndEstimates() {
        #expect(Estimate(seconds: 10).exceeds(Estimate(seconds: 5)))
        #expect(!Estimate(seconds: 10).exceeds(Estimate(usd: 5)))
        #expect(ApprovalRule.whenEstimate(above: Estimate(bytes: 100)).requiresApproval(estimate: Estimate(bytes: 101)))
        #expect(!ApprovalRule.never.requiresApproval(estimate: Estimate(usd: 1000)))
        #expect(ApprovalPolicy.standard.rule(for: "render_export") == .always)
        #expect(ApprovalPolicy.standard.rule(for: "unknown") == .never)
    }
}
