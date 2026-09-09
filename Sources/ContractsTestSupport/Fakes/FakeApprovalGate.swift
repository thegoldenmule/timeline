import Contracts
import Foundation
import TimelineCore

/// An `ApprovalGate` that records every check and lets the test grant or deny. Tokens are `tok-<n>`,
/// request ids `approval-<n>`, in order of creation.
public actor FakeApprovalGate: ApprovalGate {
    public struct Check: Sendable, Hashable {
        public var tool: String
        public var input: ToolInput
        public var estimate: Estimate
        public var decision: Decision
        public var presentation: ApprovalPresentation?

        public enum Decision: Sendable, Hashable {
            case granted
            case grantedByToken(ApprovalToken)
            case required(ApprovalToken)
        }
    }

    public private(set) var policy: ApprovalPolicy
    public private(set) var checks: [Check] = []
    private var pendingRequests: [ApprovalToken: ApprovalRequest] = [:]
    private var granted: Set<ApprovalToken> = []
    public private(set) var denied: [ApprovalToken: String?] = [:]
    public private(set) var consumed: [ApprovalToken] = []
    private var counter = 0
    private let clock: any Clock
    private let broadcaster = Broadcaster<ApprovalRequest>()

    public init(policy: ApprovalPolicy = .standard, clock: any Clock = FixedClock(step: 1)) {
        self.policy = policy
        self.clock = clock
    }

    public func setPolicy(_ policy: ApprovalPolicy) { self.policy = policy }

    public func check(tool: String, input: ToolInput, estimate: Estimate, actor: Actor, sessionId: String?)
        -> ApprovalDecision
    {
        check(tool: tool, input: input, estimate: estimate, presentation: nil, actor: actor, sessionId: sessionId)
    }

    /// The presentation rides on the request and its summary becomes `inputSummary`.
    public func check(
        tool: String, input: ToolInput, estimate: Estimate, presentation: ApprovalPresentation?, actor: Actor,
        sessionId: String?
    ) -> ApprovalDecision {
        guard policy.requiresApproval(tool: tool, estimate: estimate) else {
            checks.append(
                Check(tool: tool, input: input, estimate: estimate, decision: .granted, presentation: presentation))
            return .granted
        }
        if let token = input.approvalToken, consume(token) {
            checks.append(
                Check(
                    tool: tool, input: input, estimate: estimate, decision: .grantedByToken(token),
                    presentation: presentation))
            return .granted
        }
        counter += 1
        let token = ApprovalToken("tok-\(counter)")
        let request = ApprovalRequest(
            id: "approval-\(counter)", token: token, tool: tool,
            inputSummary: presentation?.summary ?? FakeApprovalGate.summary(tool, input), estimate: estimate,
            requestedAt: clock.now(), actor: actor, sessionId: sessionId, presentation: presentation)
        pendingRequests[token] = request
        checks.append(
            Check(tool: tool, input: input, estimate: estimate, decision: .required(token), presentation: presentation))
        broadcaster.send(request)
        return .required(request)
    }

    public func grant(_ token: ApprovalToken) {
        guard pendingRequests.removeValue(forKey: token) != nil else { return }
        granted.insert(token)
    }

    public func deny(_ token: ApprovalToken, reason: String?) {
        guard pendingRequests.removeValue(forKey: token) != nil else { return }
        denied[token] = reason
    }

    public func consume(_ token: ApprovalToken) -> Bool {
        guard granted.remove(token) != nil else { return false }
        consumed.append(token)
        return true
    }

    public func status(of token: ApprovalToken) -> ApprovalTokenStatus {
        if pendingRequests[token] != nil { return .pending }
        if granted.contains(token) { return .granted }
        if let reason = denied[token] { return .denied(reason: reason) }
        if consumed.contains(token) { return .consumed }
        return .unknown
    }

    public func pending() -> [ApprovalRequest] { pendingRequests.values.sorted { $0.id < $1.id } }

    public nonisolated var requests: AsyncStream<ApprovalRequest> { broadcaster.subscribe() }

    /// The most recent request, for tests that grant "whatever was just asked".
    public var lastRequest: ApprovalRequest? { pending().last }

    static func summary(_ tool: String, _ input: ToolInput) -> String {
        let args = input.arguments.keys.sorted().filter { $0 != "approvalToken" }.map { key in
            "\(key)=\(input.arguments[key].map(describe) ?? "")"
        }
        return "\(tool)(\(args.joined(separator: ", ")))"
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): s
        case .number(let n): n == n.rounded() ? String(Int64(n)) : String(n)
        case .bool(let b): String(b)
        case .null: "null"
        case .array(let a): "[\(a.count)]"
        case .object(let o): "{\(o.count)}"
        }
    }
}

/// Records receipts in order.
public actor FakeToolReceiptSink: ToolReceiptSink {
    public private(set) var receipts: [ToolReceipt] = []
    public init() {}
    public func record(_ receipt: ToolReceipt) { receipts.append(receipt) }
}
