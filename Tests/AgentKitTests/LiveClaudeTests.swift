import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import AgentKit

/// The one headless run against the real `claude` CLI: starts the host, launches the sidecar with the
/// goal "call project_list and report the result", and asserts the tool call arrived. Opt in with
/// `TIMELINE_LIVE_CLAUDE=1` (it spends real tokens, budget capped at $0.50). Set
/// `TIMELINE_LIVE_TRANSCRIPT_OUT=<path>` to record the raw stream-json for the parser fixtures.
@Suite struct LiveClaudeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TIMELINE_LIVE_CLAUDE"] == "1"), .timeLimit(.minutes(5)))
    func headlessRunInvokesProjectList() async throws {
        let services = try await TestServices.make()
        let context = services.toolContext(actor: .human, sessionId: nil)
        let registry = await EditorTools.standard(context: context)
        var configuration = MCPServerHost.Configuration()
        configuration.log = { print($0) }
        let host = MCPServerHost(registry: registry, context: context, configuration: configuration)
        let info = try await host.start()
        defer { Task { await host.stop() } }

        let runtime = ClaudeCodeRuntime(
            configuration: .init(approvals: host.approvalGate, multiTurn: false, log: { print("[runtime] \($0)") }))
        let availability = await runtime.availability()
        print("availability: \(availability)")
        #expect(availability.isUsable, "\(availability)")

        let session = try await runtime.startSession(
            goal: "Call the project_list tool and report the result (project name, id and version) in one sentence.",
            tools: info.toolAccess, policy: RuntimePolicy(maxBudgetUSD: 0.5, maxTurns: 6))
        var events: [AgentEvent] = []
        for await event in session.events {
            events.append(event)
            if case .raw = event { continue }
            print("[event] \(event)")
        }
        let claudeSession = try #require(session as? ClaudeCodeSession)
        if let out = ProcessInfo.processInfo.environment["TIMELINE_LIVE_TRANSCRIPT_OUT"] {
            try Data((claudeSession.transcript.joined(separator: "\n") + "\n").utf8).write(
                to: URL(fileURLWithPath: out))
        }
        print("stderr: \(claudeSession.standardError)")

        let calls = events.compactMap { event -> String? in
            if case .toolCall(_, let name, _) = event { return name }
            return nil
        }
        #expect(calls.contains("project_list"), "events: \(events)")
        #expect(
            events.contains {
                if case .toolResult(_, let output, let isError) = $0 {
                    return !isError && output["count"]?.intValue == 1
                } else {
                    return false
                }
            })
        guard case .finished(let result, let cost)? = events.last else {
            Issue.record("expected finished, got \(String(describing: events.last))")
            return
        }
        #expect(result?.isEmpty == false && (cost?.usd ?? 0) > 0 && (cost?.turns ?? 0) >= 1)
        #expect(claudeSession.claudeSessionId == session.id)
        #expect(await host.calls.map(\.tool).contains("project_list"))
        #expect(await services.receipts.receipts.map(\.toolName).contains("project_list"))
    }
}
