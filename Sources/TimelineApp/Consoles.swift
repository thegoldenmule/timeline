import Contracts
import Foundation
import Observation
import TimelineCore
import TimelineUI

/// Pretty JSON for the window and the headless summary.
enum PrettyJSON {
    static func string(_ value: JSONValue?) -> String {
        guard let value else { return "null" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "<unencodable>" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Tools

/// Calls registry tools as the human and shows the structured result. A tool that answers
/// `approval_required` raises a card on the approval stack; the console waits for the verdict and
/// retries with the token, so the human path is the same gate round trip an agent takes.
@MainActor @Observable
final class ToolConsole {
    let services: AppServices
    private(set) var lastTool = ""
    private(set) var lastOutput: ToolOutput?
    private(set) var error: String?
    private(set) var isCalling = false

    init(services: AppServices) { self.services = services }

    var structuredText: String { PrettyJSON.string(lastOutput?.structured) }

    @discardableResult
    func call(_ name: String, input: ToolInput = ToolInput()) async throws -> ToolOutput {
        lastTool = name
        error = nil
        isCalling = true
        defer { isCalling = false }
        do {
            var output = try await services.callTool(name, input: input, actor: .human)
            if output.isApprovalRequired, let request = ToolLoopSession.request(from: output) {
                lastOutput = output
                if case .approve = await ApprovalWait.verdict(for: request.token, on: services.approvals) {
                    var retry = input
                    retry.arguments["approvalToken"] = .string(request.token.rawValue)
                    output = try await services.callTool(name, input: retry, actor: .human)
                } else {
                    output = .error(code: "denied", message: "\(name) was denied")
                }
            }
            lastOutput = output
            return output
        } catch {
            self.error = "\(error)"
            throw error
        }
    }

    func describeProject() async throws -> ToolOutput {
        try await call("project_describe", input: ToolInput(["level": "summary"]))
    }
}

// MARK: - Agent

/// Runs one embedded agent session at a time: TimelineUI's `AgentTranscript` folds the events and
/// hands approvals to the shared `ApprovalCenter`; the runtime is the Claude Code sidecar (which calls
/// the tools over MCP itself) or the scripted fallback with its client-side tool loop.
@MainActor @Observable
final class AgentConsole {
    let services: AppServices
    let approvals: ApprovalCenter
    private(set) var transcript: AgentTranscript?
    private(set) var error: String?
    private(set) var isStarting = false

    init(services: AppServices, approvals: ApprovalCenter) {
        self.services = services
        self.approvals = approvals
    }

    var isRunning: Bool { transcript.map { !$0.isFinished } ?? false }

    /// Starts a session and returns once it is streaming.
    func start(goal: String) async throws {
        error = nil
        isStarting = true
        defer { isStarting = false }
        do {
            let session = try await services.agentRuntime.startSession(
                goal: goal, tools: services.mcp.toolAccess, policy: services.runtimePolicy)
            let transcript = AgentTranscript(session: session, approvalCenter: approvals)
            transcript.start()
            self.transcript = transcript
        } catch {
            self.error = "\(error)"
            throw error
        }
    }

    func runToCompletion() async {
        await transcript?.waitUntilFinished()
    }

    func cancel() async {
        await transcript?.cancel()
    }
}
