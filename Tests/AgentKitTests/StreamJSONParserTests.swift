import Contracts
import Foundation
import Testing
import TimelineCore

@testable import AgentKit

enum Transcripts {
    static func lines(_ name: String) throws -> [String] {
        let url = try #require(
            Bundle.module.url(forResource: "Transcripts/\(name)", withExtension: nil)
                ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Transcripts"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    static func url(_ name: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: "Transcripts/\(name)", withExtension: nil)
                ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Transcripts"))
    }
}

/// The tolerant stream-json parser against the recorded live run and a hand-written turn.
@Suite struct StreamJSONParserTests {
    @Test func parsesTheRecordedLiveRun() throws {
        var parser = StreamJSONParser(serverName: "timeline")
        var events: [AgentEvent] = []
        for line in try Transcripts.lines("live-project-list.stream.jsonl") { events += parser.parse(line: line) }
        #expect(parser.claudeSessionId == "b08388dc-c15d-4cdf-aabe-cdf6839de528")
        #expect(parser.mcpServers == ["timeline": "connected"])
        let shaped = events.map { event -> String in
            switch event {
            case .turnStarted(let i): "turn\(i)"
            case .assistantText: "text"
            case .toolCall(_, let name, _): "call:\(name)"
            case .toolResult(_, _, let isError): isError ? "result:error" : "result"
            case .approvalRequested: "approval"
            case .cost: "cost"
            case .finished: "finished"
            case .failed: "failed"
            case .raw(let json): "raw:\(json["type"]?.stringValue ?? "?")"
            }
        }
        #expect(
            shaped == [
                "raw:system", "raw:rate_limit_event", "turn1", "text", "turn2", "call:ToolSearch", "result",
                "raw:rate_limit_event", "turn3", "call:project_list", "result", "turn4", "text", "finished",
            ], "\(shaped)")
        guard case .toolResult(let id, let output, let isError) = events[10] else {
            Issue.record("expected the project_list result")
            return
        }
        #expect(id == "toolu_01UT1aMuzPTE74eXWP4gUFMU" && !isError)
        #expect(output["count"]?.intValue == 1 && output["projects"]?[0]?["name"] == "Three clips")
        guard case .finished(let result, let cost) = events.last! else {
            Issue.record("expected finished")
            return
        }
        #expect(result?.contains("Three clips") == true)
        #expect(
            cost == CostReport(usd: 0.18651275, inputTokens: 66, outputTokens: 176, durationSeconds: 6.061, turns: 3))
        #expect(parser.lastCost == cost)
    }

    @Test func synthesisesApprovalsAndToleratesUnknownLines() throws {
        var parser = StreamJSONParser(serverName: "timeline")
        var events: [AgentEvent] = []
        for line in try Transcripts.lines("fake-turn1.stream.jsonl") { events += parser.parse(line: line) }
        let approvals = events.compactMap { event -> ApprovalRequest? in
            if case .approvalRequested(let r) = event { return r }
            return nil
        }
        #expect(approvals.count == 1)
        #expect(approvals.first?.token == "tok-fake-1" && approvals.first?.tool == "render_export")
        #expect(approvals.first?.estimate == Estimate(seconds: 30, bytes: 1000))
        #expect(approvals.first?.sessionId == "fake-session")
        #expect(events.contains(.toolCall(id: "toolu_export", name: "render_export", input: ["preset": "reel9x16"])))
        // Image blocks become a small descriptor, several blocks an array.
        guard
            case .toolResult(_, let look, _)? = events.first(where: {
                if case .toolResult(let id, _, _) = $0 { id == "toolu_look" } else { false }
            })
        else {
            Issue.record("expected look_at result")
            return
        }
        #expect(look[0] == "1 frame" && look[1]?["type"] == "image" && look[1]?["mimeType"] == "image/png")
        #expect(events.contains(.toolResult(id: "toolu_bad", output: "Input does not match the schema", isError: true)))
        #expect(events.contains(.raw(["type": "mystery_event", "payload": ["answer": 42]])))
        #expect(events.contains(.raw("not json at all")))
        #expect(
            events.last
                == .finished(
                    result: "Waiting for your approval to export.",
                    cost: CostReport(usd: 0.0123, inputTokens: 100, outputTokens: 50, durationSeconds: 1.234, turns: 3))
        )
        #expect(parser.parse(line: "   ").isEmpty)

        var second = StreamJSONParser(serverName: "timeline")
        var failed: [AgentEvent] = []
        for line in try Transcripts.lines("fake-turn2.stream.jsonl") { failed += second.parse(line: line) }
        #expect(failed.last == .failed(AgentFailure(code: "error_max_turns", message: "Reached max turns")))
        #expect(second.lastCost?.usd == 0.001)

        var unprefixed = StreamJSONParser()
        let raw = unprefixed.parse([
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": "x", "name": "mcp__timeline__undo", "input": [:]]]],
        ])
        #expect(raw.contains(.toolCall(id: "x", name: "mcp__timeline__undo", input: [:])))
    }
}
