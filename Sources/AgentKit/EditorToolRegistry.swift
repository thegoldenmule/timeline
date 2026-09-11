import Contracts
import Foundation
import TimelineCore

/// The editor's `ToolRegistry`: a table of `Tool`s keyed by name. `call` runs the handler, turns
/// `EditorError` and `ToolError` into error outputs the model can read (never thrown), validates the
/// input against the tool's schema first, and records a `ToolReceipt` for every invocation when the
/// context carries a receipt sink (storage.md section 10: mutating and read-only alike, so "what did
/// the agent do" is answerable from the project).
public actor EditorToolRegistry: ToolRegistry {
    public struct Invocation: Sendable {
        public var name: String
        public var input: ToolInput
        public var output: ToolOutput
        public var sessionId: String?
        public var startedAt: Date
        public var finishedAt: Date
    }

    private var tools: [String: Tool] = [:]
    private var order: [String] = []
    private let clock: any Clock
    private let ids: any IDGenerator
    /// Whether `call` rejects inputs that fail the tool's `inputSchema` before running the handler.
    public let validatesInput: Bool
    /// Every call in order, for logs and tests.
    public private(set) var invocations: [Invocation] = []

    public init(
        tools: [Tool] = [], clock: any Clock = SystemClock(), ids: any IDGenerator = UUIDv7Generator(),
        validatesInput: Bool = true
    ) {
        self.clock = clock
        self.ids = ids
        self.validatesInput = validatesInput
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
        let output = await run(tool, input: input, context: context)
        let finished = clock.now()
        invocations.append(
            Invocation(
                name: name, input: input, output: output, sessionId: context.sessionId, startedAt: started,
                finishedAt: finished))
        if let sink = context.services.receipts {
            await sink.record(
                EditorToolRegistry.receipt(
                    id: ids.next(), tool: tool, input: input, output: output, context: context, startedAt: started,
                    finishedAt: finished))
        }
        return output
    }

    private func run(_ tool: Tool, input: ToolInput, context: ToolContext) async -> ToolOutput {
        if validatesInput {
            let violations = JSONSchemaValidator(root: tool.inputSchema).validate(input.json)
            if !violations.isEmpty {
                return .error(
                    code: "invalidInput",
                    message: "Input does not match the \(tool.name) schema: "
                        + violations.prefix(5).map(\.description).joined(separator: "; "),
                    details: ["violations": .array(violations.map { .string($0.description) })])
            }
        }
        do {
            return try await tool.handler(input, context)
        } catch let error as EditorError {
            return .editorError(error)
        } catch let error as ToolError {
            return .error(code: "tool_error", message: error.message)
        } catch is CancellationError {
            return .error(code: "cancelled", message: "The call was cancelled")
        } catch {
            return .error(code: "failed", message: String(describing: error))
        }
    }

    /// The receipt for one call: outcome from the output, version and transaction from the structured result.
    static func receipt(
        id: String, tool: Tool, input: ToolInput, output: ToolOutput, context: ToolContext, startedAt: Date,
        finishedAt: Date
    ) -> ToolReceipt {
        let outcome: ToolReceipt.Outcome
        if output.isError {
            outcome = output.structured?["error"]?.stringValue == "staleVersion" ? .rejected : .error
        } else if output.isApprovalRequired {
            outcome = .approvalRequired
        } else if tool.annotations.readOnly {
            outcome = .readOnly
        } else {
            outcome = .applied
        }
        let projectId =
            input.projectId ?? output.structured?["projectId"]?.stringValue.map { ProjectID($0) }
        return ToolReceipt(
            id: id, toolName: tool.name, argsHash: input.argsHash, projectId: projectId,
            version: output.structured?["version"]?.intValue.map(Int64.init),
            txnId: output.structured?["txnId"]?.stringValue.map { TransactionID($0) }, actor: context.actor,
            sessionId: context.sessionId, startedAt: startedAt, finishedAt: finishedAt, outcome: outcome,
            message: output.text)
    }
}
