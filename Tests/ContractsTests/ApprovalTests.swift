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

    @Test func presentationRidesOnTheRequestAndTheOutput() async throws {
        let fake = FakeApprovalGate(policy: .standard)
        let gate: any ApprovalGate = fake
        let presentation = Fixtures.publishPresentation
        let input = ToolInput(["title": "Band rehearsal", "privacy": "private"])
        let decision = await gate.check(
            tool: "publish_youtube", input: input, estimate: Estimate(bytes: 5 << 20), presentation: presentation,
            actor: .agent(sessionId: "s"), sessionId: "s")
        guard case .required(let request) = decision else {
            Issue.record("expected .required")
            return
        }
        #expect(request.presentation == presentation)
        #expect(request.inputSummary == presentation.summary)
        #expect(await fake.checks.last?.presentation == presentation)
        #expect(await gate.pending() == [request])

        let output = ToolOutput.approvalRequired(request)
        #expect(output.structured?["summary"] == "Publish \"Band rehearsal\" to YouTube as Private")
        #expect(output.structured?["details"]?[0]?["label"] == "Channel")
        #expect(output.structured?["details"]?[0]?["value"] == "Skeleton Channel (@skeleton)")
        #expect(output.structured?["details"]?[2]?["label"] == "Certification")
        #expect(output.structured?["details"]?.arrayValue?.count == 3)
        #expect(output.structured?["warnings"] == .array([]))
        #expect(output.text?.contains(presentation.summary) == true)
        var warned = presentation
        warned.warnings = ["Privacy: public"]
        let warnedOutput = ToolOutput.approvalRequired(Fixtures.approvalRequest(tool: "publish_youtube").with(warned))
        #expect(warnedOutput.structured?["warnings"] == ["Privacy: public"])

        // The request round-trips with and without a presentation; an old transcript decodes nil.
        let data = try ProjectCodec.encode(request)
        #expect(try ProjectCodec.decode(ApprovalRequest.self, from: data) == request)
        var json = try JSONValue(encoding: request).objectValue ?? [:]
        json.removeValue(forKey: "presentation")
        let legacy = try JSONValue.object(json).decoded(as: ApprovalRequest.self)
        #expect(legacy.presentation == nil && legacy.inputSummary == request.inputSummary)
        let plain = ToolOutput.approvalRequired(Fixtures.approvalRequest())
        #expect(plain.structured?["summary"] == "render_export(preset=reel9x16)")
        #expect(plain.structured?["details"] == .array([]) && plain.structured?["warnings"] == .array([]))

        // The token still grants the retry.
        await gate.grant(request.token)
        var retry = input
        retry.arguments["approvalToken"] = .string(request.token.rawValue)
        #expect(
            await gate.check(
                tool: "publish_youtube", input: retry, estimate: .none, presentation: presentation, actor: .human,
                sessionId: nil) == .granted)
    }

    @Test func fiveArgumentCheckStillForwards() async throws {
        let legacy: any ApprovalGate = LegacyGate()
        let decision = await legacy.check(
            tool: "publish_youtube", input: ToolInput(), estimate: .none, presentation: Fixtures.publishPresentation,
            actor: .human, sessionId: nil)
        guard case .required(let request) = decision else {
            Issue.record("expected .required")
            return
        }
        #expect(request.presentation == nil && request.inputSummary == "legacy")
        #expect(await legacy.status(of: request.token) == .unknown)

        // The fake's five-argument form forwards to the six-argument one with no presentation.
        let fake: any ApprovalGate = FakeApprovalGate()
        guard
            case .required(let plain) = await fake.check(
                tool: "publish_youtube", input: ToolInput(["title": "x"]), estimate: .none, actor: .human,
                sessionId: nil)
        else {
            Issue.record("expected .required")
            return
        }
        #expect(plain.presentation == nil && plain.inputSummary == "publish_youtube(title=x)")

        // ToolContext forwards the presentation.
        let services = try await TestServices.make()
        let context = services.toolContext()
        let viaContext = await context.checkApproval(
            tool: "publish_youtube", input: ToolInput(), estimate: .none, presentation: Fixtures.publishPresentation)
        guard case .required(let carried) = viaContext else {
            Issue.record("expected .required")
            return
        }
        #expect(carried.presentation == Fixtures.publishPresentation && carried.sessionId == "session-1")
    }

    @Test func standardPolicyGatesPublishYouTube() {
        #expect(ApprovalPolicy.standard.rule(for: "publish_youtube") == .always)
        #expect(ApprovalPolicy.standard.rule(for: "publish_status") == .never)
        #expect(ApprovalPolicy.standard.rule(for: "account_status") == .never)
        #expect(ApprovalPolicy.standard.requiresApproval(tool: "publish_youtube", estimate: .none))
        #expect(!ApprovalPolicy.standard.requiresApproval(tool: "publish_status", estimate: Estimate(usd: 100)))
    }
}

/// A gate that implements only the five-argument `check`, the shape of gates written before presentations.
private actor LegacyGate: ApprovalGate {
    let policy = ApprovalPolicy.standard
    private var counter = 0

    func check(tool: String, input: ToolInput, estimate: Estimate, actor: Actor, sessionId: String?)
        -> ApprovalDecision
    {
        counter += 1
        return .required(
            ApprovalRequest(
                id: "legacy-\(counter)", token: ApprovalToken("legacy-tok-\(counter)"), tool: tool,
                inputSummary: "legacy", estimate: estimate, requestedAt: Date(), actor: actor, sessionId: sessionId))
    }

    func grant(_ token: ApprovalToken) {}
    func deny(_ token: ApprovalToken, reason: String?) {}
    func consume(_ token: ApprovalToken) -> Bool { false }
    func pending() -> [ApprovalRequest] { [] }
    nonisolated var requests: AsyncStream<ApprovalRequest> { AsyncStream { $0.finish() } }
}

extension ApprovalRequest {
    fileprivate func with(_ presentation: ApprovalPresentation) -> ApprovalRequest {
        var copy = self
        copy.presentation = presentation
        return copy
    }
}
