import Contracts
import Foundation
import Synchronization
import TimelineCore

/// The fallback when Claude Code is not installed or not logged in: a runtime whose sessions announce
/// tool calls without running them (`FakeAgentRuntime` replaying `DemoAgentScript`) wrapped in the
/// client-side tool loop a Messages-API runtime has. Each `.toolCall` the script announces runs through
/// the registry for real; an `approval_required` answer becomes an `.approvalRequested` event carrying
/// the gate's request, the loop waits for the token's verdict on the gate (answered from the approval
/// stack, the transcript card, or `approve`), and a grant retries the call with the token.
struct ToolLoopRuntime: AgentRuntime {
    typealias Call = @Sendable (String, ToolInput, String) async throws -> ToolOutput

    let base: any AgentRuntime
    let gate: any ApprovalGate
    let call: Call

    func availability() async -> RuntimeAvailability { await base.availability() }

    func startSession(goal: String, tools: ToolAccess, policy: RuntimePolicy) async throws -> any AgentSession {
        let session = try await base.startSession(goal: goal, tools: tools, policy: policy)
        return ToolLoopSession(base: session, gate: gate, call: call)
    }
}

/// Forwards the base session's events, executing tool calls in order and pausing on approvals.
final class ToolLoopSession: AgentSession, Sendable {
    let id: String
    let events: AsyncStream<AgentEvent>

    private let base: any AgentSession
    private let gate: any ApprovalGate
    private let call: ToolLoopRuntime.Call
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let forwarding = Mutex<Task<Void, Never>?>(nil)

    init(base: any AgentSession, gate: any ApprovalGate, call: @escaping ToolLoopRuntime.Call) {
        self.base = base
        self.gate = gate
        self.call = call
        id = base.id
        (events, continuation) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        let task = Task { [self] in await self.forward() }
        forwarding.withLock { $0 = task }
    }

    private func forward() async {
        for await event in base.events {
            continuation.yield(event)
            guard case .toolCall(let callId, let name, let input) = event else { continue }
            await execute(callId: callId, name: name, input: ToolInput(input.objectValue ?? [:]))
        }
        continuation.finish()
    }

    private func execute(callId: String, name: String, input: ToolInput) async {
        let output: ToolOutput
        do {
            output = try await call(name, input, id)
        } catch {
            continuation.yield(.toolResult(id: callId, output: .string("\(error)"), isError: true))
            return
        }
        guard output.isApprovalRequired, let request = ToolLoopSession.request(from: output) else {
            continuation.yield(.toolResult(id: callId, output: output.structured ?? .null, isError: output.isError))
            return
        }
        continuation.yield(.approvalRequested(request))
        switch await ApprovalWait.verdict(for: request.token, on: gate) {
        case .approve:
            var retry = input
            retry.arguments["approvalToken"] = .string(request.token.rawValue)
            do {
                let granted = try await call(name, retry, id)
                continuation.yield(
                    .toolResult(id: callId, output: granted.structured ?? .null, isError: granted.isError))
            } catch {
                continuation.yield(.toolResult(id: callId, output: .string("\(error)"), isError: true))
            }
        case .deny(let reason):
            continuation.yield(
                .toolResult(
                    id: callId, output: .object(["error": "denied", "message": .string(reason ?? "Denied")]),
                    isError: true))
        }
    }

    /// The gate's request as the `approval_required` output carries it: the token is what `grant`
    /// needs, the summary and estimate are what the card shows.
    static func request(from output: ToolOutput) -> ApprovalRequest? {
        guard let s = output.structured, let id = s["requestId"]?.stringValue,
            let token = s["approvalToken"]?.stringValue, let tool = s["tool"]?.stringValue
        else { return nil }
        let estimate = (try? s["estimate"]?.decoded(as: Estimate.self)) ?? .none
        return ApprovalRequest(
            id: id, token: ApprovalToken(token), tool: tool, inputSummary: s["summary"]?.stringValue ?? tool,
            estimate: estimate, requestedAt: Date(), actor: .agent(sessionId: "fallback"), sessionId: nil)
    }

    /// Grants or denies the token on the gate; the loop observes the verdict and continues. The base
    /// session is told too, for scripts that pause on their own `.approvalRequested`.
    func approve(_ request: ApprovalRequest, verdict: ApprovalVerdict) async {
        switch verdict {
        case .approve: await gate.grant(request.token)
        case .deny(let reason): await gate.deny(request.token, reason: reason)
        }
        await base.approve(request, verdict: verdict)
    }

    func send(_ userMessage: String) async throws { try await base.send(userMessage) }

    func cancel() async {
        forwarding.withLock { $0?.cancel() }
        await base.cancel()
    }
}

/// What the fallback runtime replays: one turn that reads the project, then asks to export, which the
/// gate holds for approval. The tool loop above runs the calls, so the approval is a real round trip.
enum DemoAgentScript {
    static func events(exportPath: String) -> [AgentEvent] {
        [
            .turnStarted(index: 1),
            .assistantText("Looking at the project before exporting."),
            .toolCall(id: "call-describe", name: "project_describe", input: ["level": "summary"]),
            .assistantText("Exporting a vertical reel of the active sequence."),
            .toolCall(
                id: "call-export", name: "render_export",
                input: ["preset": "reel9x16", "outputPath": .string(exportPath)]
            ),
            .assistantText("Exported the reel."),
            .finished(
                result: "Exported Reel 9:16.",
                cost: CostReport(usd: 0.03, inputTokens: 1200, outputTokens: 180, turns: 1)),
        ]
    }
}
