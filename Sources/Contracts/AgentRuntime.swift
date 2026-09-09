import Foundation
import TimelineCore

/// How the runtime reaches the app's tools: the MCP endpoint plus the per-launch bearer token the
/// server checks. The Claude Code sidecar gets this as an inline `--mcp-config` with `headers`.
public struct ToolAccess: Hashable, Sendable, Codable {
    public var serverName: String
    public var endpoint: URL
    public var bearerToken: String
    /// Tool names the session may call (nil: every tool the server lists). Becomes `--allowedTools`.
    public var toolNames: [String]?

    public init(serverName: String = "timeline", endpoint: URL, bearerToken: String, toolNames: [String]? = nil) {
        self.serverName = serverName
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.toolNames = toolNames
    }
}

public struct RuntimePolicy: Hashable, Sendable, Codable {
    /// Model id per pass (nil: the runtime's default).
    public var model: String?
    public var maxBudgetUSD: Double?
    public var maxTurns: Int?
    public var systemPromptAppend: String?
    /// An app-owned directory holding the Skills folder; the sidecar's cwd.
    public var workingDirectory: URL?
    /// Continue an earlier session (`--resume`).
    public var resumeSessionId: String?

    public init(
        model: String? = nil, maxBudgetUSD: Double? = nil, maxTurns: Int? = nil, systemPromptAppend: String? = nil,
        workingDirectory: URL? = nil, resumeSessionId: String? = nil
    ) {
        self.model = model
        self.maxBudgetUSD = maxBudgetUSD
        self.maxTurns = maxTurns
        self.systemPromptAppend = systemPromptAppend
        self.workingDirectory = workingDirectory
        self.resumeSessionId = resumeSessionId
    }
}

/// What `claude --version` and `claude auth status` (or the API key check) say. `installed && loggedIn`
/// is required for the embedded agent; otherwise the app degrades to "MCP only".
public struct RuntimeAvailability: Hashable, Sendable, Codable {
    public var installed: Bool
    public var version: String?
    public var loggedIn: Bool
    public var detail: String?

    public init(installed: Bool, version: String? = nil, loggedIn: Bool, detail: String? = nil) {
        self.installed = installed
        self.version = version
        self.loggedIn = loggedIn
        self.detail = detail
    }

    public var isUsable: Bool { installed && loggedIn }
}

public struct CostReport: Hashable, Sendable, Codable {
    public var usd: Double
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var durationSeconds: Double?
    public var turns: Int?

    public init(
        usd: Double, inputTokens: Int? = nil, outputTokens: Int? = nil, durationSeconds: Double? = nil,
        turns: Int? = nil
    ) {
        self.usd = usd
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.durationSeconds = durationSeconds
        self.turns = turns
    }
}

public struct AgentFailure: Error, Hashable, Sendable, Codable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static let cancelled = AgentFailure(code: "cancelled", message: "The session was cancelled")
    /// The runtime is not installed, not logged in, or not implemented; the app degrades to "MCP only".
    public static let unavailable = AgentFailure(
        code: "unavailable", message: "The agent runtime is not available")
}

/// The session's event stream. The stream-json schema of the sidecar is not documented as stable, so the
/// parser is tolerant: anything it does not recognise arrives as `.raw` and is never an error.
public enum AgentEvent: Hashable, Sendable, Codable {
    case turnStarted(index: Int)
    case assistantText(String)
    case toolCall(id: String, name: String, input: JSONValue)
    case toolResult(id: String, output: JSONValue, isError: Bool)
    /// The gate raised a request for a tool this session called: the same value (`id`, `token`) that
    /// `ApprovalGate.requests` published and that the tool's `approval_required` output carries as
    /// `requestId` / `approvalToken`. The runtime forwards the gate's request, never one of its own, so
    /// the app grants or denies that token on the gate and then calls `approve(_:verdict:)` with this
    /// request so the session continues.
    case approvalRequested(ApprovalRequest)
    case cost(CostReport)
    case finished(result: String?, cost: CostReport?)
    case failed(AgentFailure)
    case raw(JSONValue)

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed: true
        default: false
        }
    }
}

/// One conversation with the agent. `events` is a single stream that ends after `.finished` or `.failed`
/// (or after `send` continues the turn; multi-turn sessions keep the stream open). Approval requests
/// surface as `.approvalRequested`, and `approve` answers them; the server-side gate is still the one
/// that decides whether the tool runs.
public protocol AgentSession: AnyObject, Sendable {
    var id: String { get }
    var events: AsyncStream<AgentEvent> { get }
    /// Answers a `.approvalRequested` event. `request` is the one the event carried; the verdict resumes
    /// the session (or tells the sidecar hook to allow or block the call). Granting the tool is the
    /// gate's `grant`, which the app performs first; implementations may do it on the caller's behalf.
    func approve(_ request: ApprovalRequest, verdict: ApprovalVerdict) async
    /// Continues the conversation with another user message (`--resume` for the sidecar).
    func send(_ userMessage: String) async throws
    func cancel() async
}

/// Starts agent sessions against the app's tools. First implementation: the Claude Code CLI sidecar
/// (`claude -p --output-format stream-json --strict-mcp-config --mcp-config <inline> --permission-mode
/// dontAsk --allowedTools <server-scoped> --max-budget-usd --model --append-system-prompt`, `CLAUDECODE`
/// unset, cwd set to `policy.workingDirectory`); a Messages-API implementation follows behind the same
/// protocol.
public protocol AgentRuntime: Sendable {
    func availability() async -> RuntimeAvailability
    func startSession(goal: String, tools: ToolAccess, policy: RuntimePolicy) async throws -> any AgentSession
}
