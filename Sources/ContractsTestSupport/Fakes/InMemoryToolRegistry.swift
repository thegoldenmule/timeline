import Contracts
import Foundation
import TimelineCore

/// A `ToolRegistry` over a dictionary. `call` runs the handler, converts `EditorError` and `ToolError`
/// into error outputs (never throws for those), and records a `ToolReceipt` when the context has a sink.
public actor InMemoryToolRegistry: ToolRegistry {
    public struct Invocation: Sendable {
        public var name: String
        public var input: ToolInput
        public var output: ToolOutput
    }

    private var tools: [String: Tool] = [:]
    private var order: [String] = []
    public private(set) var invocations: [Invocation] = []
    private let clock: any Clock

    public init(tools: [Tool] = [], clock: any Clock = SystemClock()) {
        self.clock = clock
        for tool in tools {
            self.tools[tool.name] = tool
            order.append(tool.name)
        }
    }

    public func register(_ tool: Tool) {
        if tools[tool.name] == nil { order.append(tool.name) }
        tools[tool.name] = tool
    }

    public func unregister(_ name: String) {
        guard tools.removeValue(forKey: name) != nil else { return }
        order.removeAll { $0 == name }
    }

    public func tool(named name: String) -> Tool? { tools[name] }

    public func list() -> [Tool] { order.compactMap { tools[$0] } }

    public func call(_ name: String, input: ToolInput, context: ToolContext) async throws -> ToolOutput {
        guard let tool = tools[name] else { throw ToolError.unknownTool(name) }
        let started = clock.now()
        let output: ToolOutput
        do {
            output = try await tool.handler(input, context)
        } catch let error as EditorError {
            output = .editorError(error)
        } catch let error as ToolError {
            output = .error(code: "tool_error", message: error.message)
        }
        invocations.append(Invocation(name: name, input: input, output: output))
        if let sink = context.services.receipts {
            let outcome: ToolReceipt.Outcome =
                output.isError
                ? .error
                : output.isApprovalRequired ? .approvalRequired : tool.annotations.readOnly ? .readOnly : .applied
            await sink.record(
                ToolReceipt(
                    id: UUIDv7Generator().next(), toolName: name, argsHash: input.argsHash, projectId: input.projectId,
                    version: output.structured?["version"]?.intValue.map(Int64.init),
                    txnId: output.structured?["txnId"]?.stringValue.map { TransactionID($0) }, actor: context.actor,
                    sessionId: context.sessionId, startedAt: started, finishedAt: clock.now(), outcome: outcome,
                    message: output.text))
        }
        return output
    }
}
