import Contracts
import Foundation
import TimelineCore

/// The app's `ApprovalGate`: one per app, shared by every session and the MCP host. Tokens are
/// random and single-use; requests are published on `requests` for the approval stack.
actor StandardApprovalGate: ApprovalGate {
    private enum Entry {
        case pending(ApprovalRequest)
        case granted
        case denied(reason: String?)
        case consumed
    }

    let policy: ApprovalPolicy
    private var entries: [ApprovalToken: Entry] = [:]
    private var counter = 0
    private let clock: any Clock
    private let broadcaster = Broadcaster<ApprovalRequest>()

    init(policy: ApprovalPolicy = .standard, clock: any Clock = SystemClock()) {
        self.policy = policy
        self.clock = clock
    }

    func check(tool: String, input: ToolInput, estimate: Estimate, actor: Actor, sessionId: String?)
        -> ApprovalDecision
    {
        check(tool: tool, input: input, estimate: estimate, presentation: nil, actor: actor, sessionId: sessionId)
    }

    /// The six-argument form: the tool's card content rides on the request, and its summary is what
    /// the card's first line shows (`publish_youtube` hands over channel, privacy, and the certification).
    func check(
        tool: String, input: ToolInput, estimate: Estimate, presentation: ApprovalPresentation?, actor: Actor,
        sessionId: String?
    ) -> ApprovalDecision {
        guard policy.requiresApproval(tool: tool, estimate: estimate) else { return .granted }
        if let token = input.approvalToken, consume(token) { return .granted }
        counter += 1
        let token = ApprovalToken(StandardApprovalGate.mintToken())
        let request = ApprovalRequest(
            id: "approval-\(counter)", token: token, tool: tool,
            inputSummary: presentation?.summary ?? StandardApprovalGate.summary(tool, input),
            estimate: estimate, requestedAt: clock.now(), actor: actor, sessionId: sessionId,
            presentation: presentation)
        entries[token] = .pending(request)
        broadcaster.send(request)
        return .required(request)
    }

    func grant(_ token: ApprovalToken) {
        guard case .pending? = entries[token] else { return }
        entries[token] = .granted
    }

    func deny(_ token: ApprovalToken, reason: String?) {
        guard case .pending? = entries[token] else { return }
        entries[token] = .denied(reason: reason)
    }

    func consume(_ token: ApprovalToken) -> Bool {
        guard case .granted? = entries[token] else { return false }
        entries[token] = .consumed
        return true
    }

    func status(of token: ApprovalToken) -> ApprovalTokenStatus {
        switch entries[token] {
        case .pending?: .pending
        case .granted?: .granted
        case .denied(let reason)?: .denied(reason: reason)
        case .consumed?: .consumed
        case nil: .unknown
        }
    }

    func pending() -> [ApprovalRequest] {
        entries.values.compactMap {
            if case .pending(let request) = $0 { return request }
            return nil
        }.sorted { $0.requestedAt < $1.requestedAt }
    }

    nonisolated var requests: AsyncStream<ApprovalRequest> { broadcaster.subscribe() }

    private static func mintToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return "tok-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `tool(key=value, ...)` without the token, what the approval card shows.
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

/// Keeps every tool receipt in memory for the window and appends it to `receipts.jsonl` under the
/// library root, so "what did the agent do" survives the session. ProjectStore does not expose the
/// project's `commands` metadata yet; see docs/design/integration.md.
actor ReceiptLog: ToolReceiptSink {
    private(set) var receipts: [ToolReceipt] = []
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    func record(_ receipt: ToolReceipt) {
        receipts.append(receipt)
        guard let fileURL, let data = try? ProjectCodec.encoder.encode(receipt) else { return }
        let line = data + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: fileURL)
        }
    }
}
