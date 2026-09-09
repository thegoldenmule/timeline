import Foundation
import TimelineCore

/// A rough cost of a tool call, what a policy thresholds on and an approval card shows.
public struct Estimate: Hashable, Sendable, Codable {
    public var seconds: Double?
    public var usd: Double?
    public var bytes: Int64?

    public init(seconds: Double? = nil, usd: Double? = nil, bytes: Int64? = nil) {
        self.seconds = seconds
        self.usd = usd
        self.bytes = bytes
    }

    public static let none = Estimate()

    /// True when any dimension of `self` exceeds the same dimension of `threshold`.
    public func exceeds(_ threshold: Estimate) -> Bool {
        if let t = threshold.seconds, let s = seconds, s > t { return true }
        if let t = threshold.usd, let u = usd, u > t { return true }
        if let t = threshold.bytes, let b = bytes, b > t { return true }
        return false
    }
}

public enum ApprovalRule: Hashable, Sendable, Codable {
    case always
    case never
    case whenEstimate(above: Estimate)

    public func requiresApproval(estimate: Estimate) -> Bool {
        switch self {
        case .always: true
        case .never: false
        case .whenEstimate(let threshold): estimate.exceeds(threshold)
        }
    }
}

/// Which tool calls need a human before they run. This is the authoritative gate: it lives inside the
/// tool handlers, so it holds for every client (the embedded runtime, Claude Code over MCP, a script).
/// Runtime-side hooks are UX on top.
public struct ApprovalPolicy: Hashable, Sendable, Codable {
    public var rules: [String: ApprovalRule]
    public var defaultRule: ApprovalRule

    public init(rules: [String: ApprovalRule] = [:], defaultRule: ApprovalRule = .never) {
        self.rules = rules
        self.defaultRule = defaultRule
    }

    public func rule(for tool: String) -> ApprovalRule { rules[tool] ?? defaultRule }

    public func requiresApproval(tool: String, estimate: Estimate) -> Bool {
        rule(for: tool).requiresApproval(estimate: estimate)
    }

    /// Exports and cloud generation always ask; everything else runs.
    public static let standard = ApprovalPolicy(rules: [
        "render_export": .always,
        "generate_tts": .whenEstimate(above: Estimate(usd: 0)),
        "find_broll": .never,
        "find_meme": .never,
    ])

    public static let approveNothing = ApprovalPolicy()
    public static let approveEverything = ApprovalPolicy(defaultRule: .always)
}

/// An opaque one-time token. Issued with an `ApprovalRequest`, granted by the approval card, consumed
/// by the tool call that carries it back as `approvalToken`.
public struct ApprovalToken: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct ApprovalRequest: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var token: ApprovalToken
    public var tool: String
    /// One line for the card, e.g. "Export Reel 9:16 (1080x1920 H.264) to ~/Movies/reel.mp4".
    public var inputSummary: String
    public var estimate: Estimate
    public var requestedAt: Date
    public var actor: Actor
    public var sessionId: String?

    public init(
        id: String, token: ApprovalToken, tool: String, inputSummary: String, estimate: Estimate, requestedAt: Date,
        actor: Actor, sessionId: String? = nil
    ) {
        self.id = id
        self.token = token
        self.tool = tool
        self.inputSummary = inputSummary
        self.estimate = estimate
        self.requestedAt = requestedAt
        self.actor = actor
        self.sessionId = sessionId
    }
}

/// What `ApprovalGate.check` answers.
public enum ApprovalDecision: Hashable, Sendable {
    /// Run the tool now.
    case granted
    /// Return `ToolOutput.approvalRequired(request)`; the caller retries with the token once granted.
    case required(ApprovalRequest)
}

/// The human's answer to a request.
public enum ApprovalVerdict: Hashable, Sendable, Codable {
    case approve
    case deny(reason: String?)
}

/// What a gate knows about a token, read without spending it (the sidecar's `PreToolUse` hook waits on
/// `pending` and answers from `granted` / `denied` while the server-side gate still consumes the token).
public enum ApprovalTokenStatus: Hashable, Sendable, Codable {
    case pending
    /// Granted and not yet consumed.
    case granted
    case denied(reason: String?)
    case consumed
    /// Never issued by this gate.
    case unknown
}

/// The server-side approval gate every expensive tool consults. One per app, shared by every session.
/// Flow: `check` returns `.granted` when the policy does not require approval or when `input` carries a
/// granted, unconsumed token (which `check` consumes); otherwise it mints a request and returns
/// `.required`. The app's approval card calls `grant` or `deny`; `requests` publishes new requests to
/// the UI. A token is single-use: `consume` returns true once.
public protocol ApprovalGate: Sendable {
    var policy: ApprovalPolicy { get async }
    func check(tool: String, input: ToolInput, estimate: Estimate, actor: Actor, sessionId: String?) async
        -> ApprovalDecision
    func grant(_ token: ApprovalToken) async
    func deny(_ token: ApprovalToken, reason: String?) async
    /// True once for a granted token; false for unknown, denied, pending, or already consumed tokens.
    func consume(_ token: ApprovalToken) async -> Bool
    /// The current state of a token, without consuming it. Default: `.unknown`.
    func status(of token: ApprovalToken) async -> ApprovalTokenStatus
    func pending() async -> [ApprovalRequest]
    /// A fresh stream per access of requests raised after the access.
    var requests: AsyncStream<ApprovalRequest> { get }
}

extension ApprovalGate {
    public func status(of token: ApprovalToken) async -> ApprovalTokenStatus { .unknown }
}

/// One line per tool invocation, recorded whatever the outcome, so "what did the agent do and why" is
/// answerable from the project alone (storage.md section 10).
public struct ToolReceipt: Hashable, Sendable, Codable, Identifiable {
    public enum Outcome: String, Codable, Sendable, Hashable {
        case applied
        case readOnly
        case rejected
        case approvalRequired
        case error
    }

    public var id: String
    public var toolName: String
    /// Fingerprint of the input arguments (`StableHash` of the canonical JSON).
    public var argsHash: String
    public var projectId: ProjectID?
    /// Project version after the call.
    public var version: Int64?
    public var txnId: TransactionID?
    public var actor: Actor
    public var sessionId: String?
    public var startedAt: Date
    public var finishedAt: Date
    public var outcome: Outcome
    public var message: String?

    public init(
        id: String, toolName: String, argsHash: String, projectId: ProjectID? = nil, version: Int64? = nil,
        txnId: TransactionID? = nil, actor: Actor, sessionId: String? = nil, startedAt: Date, finishedAt: Date,
        outcome: Outcome, message: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.argsHash = argsHash
        self.projectId = projectId
        self.version = version
        self.txnId = txnId
        self.actor = actor
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.message = message
    }
}

/// Where receipts go (the project's `commands` metadata, a log, or a test recorder).
public protocol ToolReceiptSink: Sendable {
    func record(_ receipt: ToolReceipt) async
}
