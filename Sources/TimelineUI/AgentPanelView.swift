import Contracts
import Foundation
import Observation
import SwiftUI
import TimelineCore

/// The transcript of one `AgentSession`: events folded into display items (tool calls paired with
/// their results, approvals with their verdicts), the running cost, and `send`.
@MainActor @Observable
public final class AgentTranscript {
    public enum Item: Identifiable, Sendable, Hashable {
        case turn(index: Int)
        case text(id: Int, String)
        case toolCall(id: String, name: String, input: JSONValue, output: JSONValue?, isError: Bool)
        case approval(ApprovalRequest, verdict: ApprovalVerdict?)
        case cost(id: Int, CostReport)
        case finished(id: Int, result: String?, cost: CostReport?)
        case failed(id: Int, AgentFailure)
        case raw(id: Int, JSONValue)

        public var id: String {
            switch self {
            case .turn(let i): "turn-\(i)"
            case .text(let i, _): "text-\(i)"
            case .toolCall(let id, _, _, _, _): "tool-\(id)"
            case .approval(let r, _): "approval-\(r.id)"
            case .cost(let i, _): "cost-\(i)"
            case .finished(let i, _, _): "finished-\(i)"
            case .failed(let i, _): "failed-\(i)"
            case .raw(let i, _): "raw-\(i)"
            }
        }
    }

    public let session: any AgentSession
    public private(set) var items: [Item] = []
    public private(set) var events: [AgentEvent] = []
    public private(set) var totalCostUSD: Double = 0
    public private(set) var isFinished = false
    public private(set) var failure: AgentFailure?
    public private(set) var sentMessages: [String] = []
    /// Approval cards raised by the session also go here when set, so the app's stack shows them.
    public var approvalCenter: ApprovalCenter?
    private var counter = 0
    private var subscription: Task<Void, Never>?

    public init(session: any AgentSession, approvalCenter: ApprovalCenter? = nil) {
        self.session = session
        self.approvalCenter = approvalCenter
    }

    public var pendingApprovals: [ApprovalRequest] {
        items.compactMap {
            if case .approval(let r, nil) = $0 { return r }
            return nil
        }
    }

    /// Follows the session's events until the stream ends.
    public func start() {
        guard subscription == nil else { return }
        let stream = session.events
        subscription = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
            self?.isFinished = true
        }
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
    }

    /// Waits for the stream to end (tests).
    public func waitUntilFinished() async {
        await subscription?.value
    }

    public func handle(_ event: AgentEvent) {
        events.append(event)
        counter += 1
        switch event {
        case .turnStarted(let index):
            items.append(.turn(index: index))
        case .assistantText(let text):
            items.append(.text(id: counter, text))
        case .toolCall(let id, let name, let input):
            items.append(.toolCall(id: id, name: name, input: input, output: nil, isError: false))
        case .toolResult(let id, let output, let isError):
            if let i = items.firstIndex(where: { $0.id == "tool-\(id)" }),
                case .toolCall(_, let name, let input, _, _) = items[i]
            {
                items[i] = .toolCall(id: id, name: name, input: input, output: output, isError: isError)
            } else {
                items.append(.toolCall(id: id, name: "?", input: .null, output: output, isError: isError))
            }
        case .approvalRequested(let request):
            items.append(.approval(request, verdict: nil))
            approvalCenter?.add(request)
        case .cost(let report):
            totalCostUSD += report.usd
            items.append(.cost(id: counter, report))
        case .finished(let result, let cost):
            if let cost { totalCostUSD += cost.usd }
            items.append(.finished(id: counter, result: result, cost: cost))
            isFinished = true
        case .failed(let failure):
            self.failure = failure
            items.append(.failed(id: counter, failure))
            isFinished = true
        case .raw(let value):
            items.append(.raw(id: counter, value))
        }
    }

    public func send(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sentMessages.append(trimmed)
        try await session.send(trimmed)
    }

    /// Answers an inline approval card: the session hears the verdict and the gate is told too when a
    /// centre is wired.
    public func approve(_ request: ApprovalRequest, verdict: ApprovalVerdict) async {
        if let i = items.firstIndex(where: { $0.id == "approval-\(request.id)" }) {
            items[i] = .approval(request, verdict: verdict)
        }
        if let center = approvalCenter {
            switch verdict {
            case .approve: await center.approve(request)
            case .deny(let reason): await center.deny(request, reason: reason)
            }
        }
        await session.approve(request, verdict: verdict)
    }

    public func cancel() async {
        await session.cancel()
    }
}

/// Transcript, cost, approval cards inline, and the input field.
public struct AgentPanelView: View {
    public let transcript: AgentTranscript
    @State private var draft = ""
    @State private var sendError: String?

    public init(transcript: AgentTranscript) {
        self.transcript = transcript
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(transcript.items) { item in
                            AgentItemView(item: item, transcript: transcript).id(item.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: transcript.items.count) { _, _ in
                    if let last = transcript.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Text(String(format: "$%.3f", transcript.totalCostUSD)).font(.caption).foregroundStyle(.secondary)
                if transcript.isFinished {
                    Text(transcript.failure.map { "Failed: \($0.message)" } ?? "Finished")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !transcript.isFinished {
                    Button("Cancel") { Task { await transcript.cancel() } }.font(.caption)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            HStack {
                TextField("Message the agent", text: $draft).textFieldStyle(.roundedBorder).onSubmit(send)
                Button("Send", action: send).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.red).padding(.horizontal, 10)
            }
        }
        .task { transcript.start() }
    }

    private func send() {
        let text = draft
        draft = ""
        Task {
            do {
                try await transcript.send(text)
                sendError = nil
            } catch {
                sendError = error.localizedDescription
            }
        }
    }
}

struct AgentItemView: View {
    let item: AgentTranscript.Item
    let transcript: AgentTranscript
    @State private var expanded = false

    var body: some View {
        switch item {
        case .turn(let index):
            Text("Turn \(index)").font(.caption).foregroundStyle(.secondary)
        case .text(_, let text):
            Text(text).textSelection(.enabled)
        case .toolCall(_, let name, let input, let output, let isError):
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input").font(.caption).foregroundStyle(.secondary)
                    Text(AgentItemView.pretty(input)).font(.system(.caption, design: .monospaced)).textSelection(
                        .enabled)
                    if let output {
                        Text(isError ? "Error" : "Result").font(.caption).foregroundStyle(isError ? .red : .secondary)
                        Text(AgentItemView.pretty(output)).font(.system(.caption, design: .monospaced)).textSelection(
                            .enabled)
                    }
                }
            } label: {
                HStack {
                    Image(
                        systemName: output == nil ? "hourglass" : (isError ? "xmark.octagon" : "wrench.and.screwdriver")
                    )
                    Text(name).font(.system(.body, design: .monospaced))
                }
            }
        case .approval(let request, let verdict):
            if let verdict {
                HStack {
                    Image(systemName: "hand.raised")
                    Text("\(request.tool): \(AgentItemView.verdictText(verdict))").font(.caption)
                }
            } else {
                ApprovalCardView(
                    request: request,
                    onApprove: { Task { await transcript.approve(request, verdict: .approve) } },
                    onDeny: { Task { await transcript.approve(request, verdict: .deny(reason: nil)) } })
            }
        case .cost(_, let report):
            Text(String(format: "Cost so far $%.3f", report.usd)).font(.caption).foregroundStyle(.secondary)
        case .finished(_, let result, let cost):
            VStack(alignment: .leading) {
                if let result { Text(result) }
                if let cost {
                    Text(String(format: "Finished · $%.3f · %d turns", cost.usd, cost.turns ?? 0))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed(_, let failure):
            Text("Failed: \(failure.message)").foregroundStyle(.red)
        case .raw(_, let value):
            Text(AgentItemView.pretty(value)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    static func verdictText(_ v: ApprovalVerdict) -> String {
        switch v {
        case .approve: "approved"
        case .deny(let reason): reason.map { "denied (\($0))" } ?? "denied"
        }
    }

    static func pretty(_ value: JSONValue) -> String {
        guard let data = try? ProjectCodec.encoder.encode(value), let s = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return s
    }
}
