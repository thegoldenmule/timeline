import Contracts
import Foundation
import TimelineCore

/// A tolerant parser for `claude -p --output-format stream-json --verbose` lines. The schema is not
/// documented as stable, so everything unrecognised becomes `.raw` and nothing is ever an error:
/// `system/init` records the session id, `assistant` messages yield `turnStarted`, `assistantText`,
/// and `toolCall`, `user` messages yield `toolResult` (plus a synthesised `approvalRequested` when the
/// result is an `approval_required` envelope), and the `result` line yields `finished` or `failed`
/// with the cost. Tested against the recorded transcripts in Tests/AgentKitTests/Transcripts.
public struct StreamJSONParser: Sendable {
    public private(set) var turnIndex = 0
    /// The Claude Code session id from the `init` line, when seen.
    public private(set) var claudeSessionId: String?
    /// The MCP servers the `init` line reported, name to status.
    public private(set) var mcpServers: [String: String] = [:]
    public private(set) var lastCost: CostReport?
    /// The server name whose tool prefix (`mcp__<name>__`) is stripped from tool names; nil keeps them.
    public var serverName: String?
    public var synthesizeApprovalRequests = true

    public init(serverName: String? = nil) { self.serverName = serverName }

    /// Parses one line; blank lines yield nothing, non-JSON lines yield `.raw(.string(line))`.
    public mutating func parse(line: String) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return [.raw(.string(trimmed))]
        }
        return parse(json)
    }

    public mutating func parse(_ json: JSONValue) -> [AgentEvent] {
        switch json["type"]?.stringValue {
        case "system":
            if json["subtype"] == "init" {
                claudeSessionId = json["session_id"]?.stringValue
                for server in json["mcp_servers"]?.arrayValue ?? [] {
                    if let name = server["name"]?.stringValue {
                        mcpServers[name] = server["status"]?.stringValue ?? "?"
                    }
                }
            }
            return [.raw(json)]
        case "assistant":
            return assistant(json)
        case "user":
            return user(json)
        case "result":
            return result(json)
        default:
            return [.raw(json)]
        }
    }

    private mutating func assistant(_ json: JSONValue) -> [AgentEvent] {
        guard let content = json["message"]?["content"]?.arrayValue else { return [.raw(json)] }
        turnIndex += 1
        var events: [AgentEvent] = [.turnStarted(index: turnIndex)]
        for block in content {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty { events.append(.assistantText(text)) }
            case "tool_use":
                events.append(
                    .toolCall(
                        id: block["id"]?.stringValue ?? "", name: toolName(block["name"]?.stringValue ?? ""),
                        input: block["input"] ?? .object([:])))
            default:
                events.append(.raw(block))
            }
        }
        return events
    }

    private func user(_ json: JSONValue) -> [AgentEvent] {
        guard let content = json["message"]?["content"]?.arrayValue else { return [.raw(json)] }
        var events: [AgentEvent] = []
        for block in content where block["type"] == "tool_result" {
            let id = block["tool_use_id"]?.stringValue ?? ""
            let output = StreamJSONParser.output(of: block["content"])
            let isError = block["is_error"]?.boolValue ?? false
            events.append(.toolResult(id: id, output: output, isError: isError))
            if synthesizeApprovalRequests,
                let request = StreamJSONParser.approvalRequest(in: output, sessionId: claudeSessionId)
            {
                events.append(.approvalRequested(request))
            }
        }
        return events.isEmpty ? [.raw(json)] : events
    }

    private mutating func result(_ json: JSONValue) -> [AgentEvent] {
        let cost = StreamJSONParser.cost(from: json)
        lastCost = cost
        let subtype = json["subtype"]?.stringValue ?? ""
        let isError = json["is_error"]?.boolValue ?? subtype.hasPrefix("error")
        if isError {
            let message =
                json["result"]?.stringValue
                ?? json["errors"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "; ") ?? subtype
            return [.failed(AgentFailure(code: subtype.isEmpty ? "error" : subtype, message: message))]
        }
        return [.finished(result: json["result"]?.stringValue, cost: cost)]
    }

    /// `total_cost_usd`, `usage`, `duration_ms`, `num_turns` from the result line.
    public static func cost(from json: JSONValue) -> CostReport {
        let usage = json["usage"]
        return CostReport(
            usd: json["total_cost_usd"]?.numberValue ?? json["cost_usd"]?.numberValue ?? 0,
            inputTokens: usage?["input_tokens"]?.intValue, outputTokens: usage?["output_tokens"]?.intValue,
            durationSeconds: json["duration_ms"]?.numberValue.map { $0 / 1000 }, turns: json["num_turns"]?.intValue)
    }

    /// The tool result content as JSON: a text block that parses as JSON becomes that value, else the
    /// text; several blocks become an array.
    static func output(of content: JSONValue?) -> JSONValue {
        guard let content else { return .null }
        if let text = content.stringValue { return parsedJSON(text) ?? .string(text) }
        guard let blocks = content.arrayValue else { return content }
        let values: [JSONValue] = blocks.map { block in
            if block["type"] == "text", let text = block["text"]?.stringValue {
                return parsedJSON(text) ?? .string(text)
            }
            if block["type"] == "image" {
                return .object([
                    "type": "image", "mimeType": block["source"]?["media_type"] ?? block["mimeType"] ?? .null,
                ])
            }
            return block
        }
        return values.count == 1 ? values[0] : .array(values)
    }

    static func parsedJSON(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
    }

    /// An `ApprovalRequest` rebuilt from an `approval_required` tool result.
    static func approvalRequest(in output: JSONValue, sessionId: String?) -> ApprovalRequest? {
        let envelope =
            output.objectValue != nil
            ? output : (output.arrayValue?.first { $0["status"] == "approval_required" } ?? .null)
        guard envelope["status"] == "approval_required", let token = envelope["approvalToken"]?.stringValue else {
            return nil
        }
        let estimate = (try? envelope["estimate"]?.decoded(as: Estimate.self)) ?? .none
        return ApprovalRequest(
            id: envelope["requestId"]?.stringValue ?? token, token: ApprovalToken(token),
            tool: envelope["tool"]?.stringValue ?? "", inputSummary: envelope["summary"]?.stringValue ?? "",
            estimate: estimate, requestedAt: Date(), actor: .agent(sessionId: sessionId ?? "claude"),
            sessionId: sessionId)
    }

    func toolName(_ raw: String) -> String {
        guard let serverName else { return raw }
        let prefix = "mcp__\(serverName)__"
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }
}
