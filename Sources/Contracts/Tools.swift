import Foundation
import TimelineCore

// MARK: - Input and output

/// The arguments of one tool call, always a JSON object. `projectId` and `approvalToken` are the two
/// conventional keys every tool understands.
public struct ToolInput: Hashable, Sendable, Codable {
    public var arguments: [String: JSONValue]

    public init(_ arguments: [String: JSONValue] = [:]) { self.arguments = arguments }

    public init<T: Encodable>(encoding value: T) throws {
        guard case .object(let o) = try JSONValue(encoding: value) else {
            throw ToolError.invalidInput("Tool input must encode as a JSON object")
        }
        arguments = o
    }

    public subscript(key: String) -> JSONValue? { arguments[key] }

    public var projectId: ProjectID? { arguments["projectId"]?.stringValue.map { ProjectID($0) } }
    public var approvalToken: ApprovalToken? { arguments["approvalToken"]?.stringValue.map { ApprovalToken($0) } }

    public var json: JSONValue { .object(arguments) }

    /// Decodes the whole input as `type` through the project codec.
    public func decode<T: Decodable>(as type: T.Type) throws -> T { try json.decoded(as: type) }

    /// The input without the conventional envelope keys, for hashing and receipts.
    public var argsHash: String {
        var stripped = arguments
        stripped.removeValue(forKey: "approvalToken")
        return (try? StableHash.fnv1a(encoding: JSONValue.object(stripped))) ?? ""
    }
}

public struct ToolImage: Hashable, Sendable, Codable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String = "image/png") {
        self.data = data
        self.mimeType = mimeType
    }
}

/// What a tool returns: `structured` maps to MCP `structuredContent` (validated by `outputSchema`),
/// `text` is the human-readable rendering, `images` become image content blocks. Errors are results
/// with `isError`, never thrown, so the model can read them.
public struct ToolOutput: Hashable, Sendable, Codable {
    public var structured: JSONValue?
    public var text: String?
    public var images: [ToolImage]
    public var isError: Bool

    public init(structured: JSONValue? = nil, text: String? = nil, images: [ToolImage] = [], isError: Bool = false) {
        self.structured = structured
        self.text = text
        self.images = images
        self.isError = isError
    }

    public init<T: Encodable>(encoding value: T, text: String? = nil, images: [ToolImage] = []) throws {
        self.init(structured: try JSONValue(encoding: value), text: text, images: images)
    }

    public static func text(_ text: String) -> ToolOutput { ToolOutput(text: text) }

    /// `{ "error": code, "message": message, ...details }` with `isError`.
    public static func error(code: String, message: String, details: [String: JSONValue] = [:]) -> ToolOutput {
        var o = details
        o["error"] = .string(code)
        o["message"] = .string(message)
        return ToolOutput(structured: .object(o), text: message, isError: true)
    }

    /// The canonical rejection of an `EditorError`: `{ "error": code, "message", ...fields }`, with the
    /// `ChangedSince` diff inline for `staleVersion` and the hint to retry with a new `commandId`.
    public static func editorError(_ error: EditorError) -> ToolOutput {
        var o = (try? JSONValue(encoding: error))?.objectValue ?? [:]
        o["error"] = .string(error.code)
        o["message"] = .string(error.message)
        if case .staleVersion = error {
            o["hint"] = .string(
                "Re-read the project, recompute against the current version, retry with a new commandId.")
        }
        return ToolOutput(structured: .object(o), text: error.message, isError: true)
    }

    /// The canonical `approval_required` result: `{ "status": "approval_required", "approvalToken",
    /// "estimate", "requestId", "tool", "summary" }`. Not an error: the agent waits for the approval
    /// card and retries the same call with `approvalToken` added to its input.
    public static func approvalRequired(_ request: ApprovalRequest) -> ToolOutput {
        let estimate = (try? JSONValue(encoding: request.estimate)) ?? .object([:])
        return ToolOutput(
            structured: .object([
                "status": .string("approval_required"),
                "approvalToken": .string(request.token.rawValue),
                "estimate": estimate,
                "requestId": .string(request.id),
                "tool": .string(request.tool),
                "summary": .string(request.inputSummary),
            ]),
            text: "Approval required: \(request.inputSummary). Retry with approvalToken once granted.")
    }

    public var isApprovalRequired: Bool { structured?["status"]?.stringValue == "approval_required" }
}

public enum ToolError: Error, Hashable, Sendable, Codable {
    case unknownTool(String)
    case invalidInput(String)
    case noProject
    case projectNotFound(ProjectID)
    case serviceUnavailable(String)

    public var message: String {
        switch self {
        case .unknownTool(let name): "No tool named \(name)"
        case .invalidInput(let reason): reason
        case .noProject: "No project is open; pass projectId or open one"
        case .projectNotFound(let id): "No open project with id \(id)"
        case .serviceUnavailable(let name): "\(name) is not available"
        }
    }
}

extension ToolError: LocalizedError {
    public var errorDescription: String? { message }
}

// MARK: - Tool

/// MCP tool annotations (`Tool.Annotations` in swift-sdk 0.12.1), which Claude Code shows and uses for
/// its own permission heuristics.
public struct ToolAnnotations: Hashable, Sendable, Codable {
    public var title: String?
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool
    public var openWorld: Bool

    public init(
        title: String? = nil, readOnly: Bool = false, destructive: Bool = false, idempotent: Bool = false,
        openWorld: Bool = false
    ) {
        self.title = title
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.openWorld = openWorld
    }

    public static func readOnly(title: String? = nil) -> ToolAnnotations {
        ToolAnnotations(title: title, readOnly: true, idempotent: true)
    }
}

/// One tool: its MCP description and its handler. Schemas are hand-maintained JSON Schema (as
/// `JSONValue`), with `examples` that a contract test validates against the schema. Every tool takes a
/// `projectId` (default: frontmost); mutating tools return `{ version, changedIds, warnings }`.
public struct Tool: Sendable, Identifiable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    public var annotations: ToolAnnotations
    /// Example inputs that validate against `inputSchema`.
    public var examples: [JSONValue]
    public var handler: @Sendable (ToolInput, ToolContext) async throws -> ToolOutput

    public var id: String { name }

    public init(
        name: String, description: String, inputSchema: JSONValue, outputSchema: JSONValue? = nil,
        annotations: ToolAnnotations = ToolAnnotations(), examples: [JSONValue] = [],
        handler: @escaping @Sendable (ToolInput, ToolContext) async throws -> ToolOutput
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.examples = examples
        self.handler = handler
    }
}

/// The services a tool handler may reach. Optionals: a headless or partially wired app (the walking
/// skeleton, a test) leaves out what it does not have and the tool answers `serviceUnavailable`.
public struct ToolServices: Sendable {
    public var renderer: (any Renderer)?
    public var mediaLibrary: (any MediaLibrary)?
    public var analyzer: (any MediaAnalyzer)?
    public var aligner: (any AudioAligner)?
    public var jobRunner: (any JobRunner)?
    public var thumbnails: (any ThumbnailProvider)?
    public var waveforms: (any WaveformProvider)?
    public var receipts: (any ToolReceiptSink)?

    public init(
        renderer: (any Renderer)? = nil, mediaLibrary: (any MediaLibrary)? = nil, analyzer: (any MediaAnalyzer)? = nil,
        aligner: (any AudioAligner)? = nil, jobRunner: (any JobRunner)? = nil,
        thumbnails: (any ThumbnailProvider)? = nil, waveforms: (any WaveformProvider)? = nil,
        receipts: (any ToolReceiptSink)? = nil
    ) {
        self.renderer = renderer
        self.mediaLibrary = mediaLibrary
        self.analyzer = analyzer
        self.aligner = aligner
        self.jobRunner = jobRunner
        self.thumbnails = thumbnails
        self.waveforms = waveforms
        self.receipts = receipts
    }
}

/// Everything a handler needs besides its input: the open projects, the services, the approval gate,
/// and who is calling. Built once per session by the MCP server or the embedded runtime.
public struct ToolContext: Sendable {
    public var projects: any ProjectDirectory
    public var services: ToolServices
    public var approvals: any ApprovalGate
    public var actor: Actor
    public var sessionId: String?

    public init(
        projects: any ProjectDirectory, services: ToolServices, approvals: any ApprovalGate, actor: Actor,
        sessionId: String? = nil
    ) {
        self.projects = projects
        self.services = services
        self.approvals = approvals
        self.actor = actor
        self.sessionId = sessionId
    }

    /// The store the input addresses: `projectId` when given, else the frontmost project.
    public func store(for input: ToolInput) async throws -> any ProjectStore {
        if let id = input.projectId {
            guard let store = await projects.store(for: id) else { throw ToolError.projectNotFound(id) }
            return store
        }
        guard let front = await projects.frontmost(), let store = await projects.store(for: front.id) else {
            throw ToolError.noProject
        }
        return store
    }

    /// The gate check for this call, with the context's actor and session filled in.
    public func checkApproval(tool: String, input: ToolInput, estimate: Estimate) async -> ApprovalDecision {
        await approvals.check(tool: tool, input: input, estimate: estimate, actor: actor, sessionId: sessionId)
    }
}

/// The tool table the MCP server and the embedded runtime expose. `call` runs the handler, turns
/// `ToolError` and `EditorError` into error outputs, and records a receipt when a sink is configured.
public protocol ToolRegistry: Sendable {
    func register(_ tool: Tool) async
    func tool(named name: String) async -> Tool?
    func list() async -> [Tool]
    func call(_ name: String, input: ToolInput, context: ToolContext) async throws -> ToolOutput
}
