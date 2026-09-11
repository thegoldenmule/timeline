import Contracts
import Foundation
import Observation
import SwiftUI
import TimelineCore

/// The transcript of one `AgentSession`: events folded into display items (tool calls paired with
/// their results, approvals with their verdicts), the running cost, and `send`.
@MainActor @Observable
public final class AssistantTranscript {
    public enum Item: Identifiable, Sendable, Hashable {
        case turn(index: Int)
        /// What the human sent, echoed so the panel reads as the conversation it is.
        case user(id: Int, String)
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
            case .user(let i, _): "user-\(i)"
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

    /// Still an `AgentSession`: the boundary is `Contracts.AgentRuntime`, and above it the name is
    /// Assistant while at and below it the name is Agent (`docs/design/ui-style.md`).
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
        appendUserMessage(trimmed)
        try await session.send(trimmed)
    }

    /// Echoes a message into the transcript without sending it — the goal a session started with, which
    /// the runtime received before there was a transcript to put it in.
    public func appendUserMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        counter += 1
        items.append(.user(id: counter, trimmed))
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

/// The transcript of one session: the folded items, approval cards inline, and a status line naming the
/// cost and whether the assistant is working. The input is `AssistantComposerView`, which the app owns so that a
/// message can be composed — and files staged — before any session exists.
public struct AssistantPanelView: View {
    public let transcript: AssistantTranscript

    public init(transcript: AssistantTranscript) {
        self.transcript = transcript
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(transcript.items) { item in
                            AssistantItemView(item: item, transcript: transcript)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .onChange(of: transcript.items.count) { _, _ in
                    guard let last = transcript.items.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { transcript.start() }
    }
}

/// The one-line state of a session: working or done, what it cost, and Stop while it runs.
public struct AssistantStatusBar: View {
    public let transcript: AssistantTranscript?
    public var isStarting: Bool
    public var onStop: () -> Void
    public var onClear: (() -> Void)?

    public init(
        transcript: AssistantTranscript?, isStarting: Bool = false, onStop: @escaping () -> Void,
        onClear: (() -> Void)? = nil
    ) {
        self.transcript = transcript
        self.isStarting = isStarting
        self.onStop = onStop
        self.onClear = onClear
    }

    private var isWorking: Bool { isStarting || (transcript.map { !$0.isFinished } ?? false) }

    public var body: some View {
        HStack(spacing: 6) {
            Label("Assistant", systemImage: "sparkles").font(.caption.weight(.semibold)).labelStyle(.titleAndIcon)
            if isWorking {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                Text(isStarting ? "Starting" : "Working").font(.caption2).foregroundStyle(.secondary)
            } else if let transcript {
                if let failure = transcript.failure {
                    Label(failure.message, systemImage: "exclamationmark.triangle").font(.caption2)
                        .foregroundStyle(.orange).lineLimit(1)
                } else {
                    Label("Done", systemImage: "checkmark.circle").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let transcript, transcript.totalCostUSD > 0 {
                Text(String(format: "$%.3f", transcript.totalCostUSD)).font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary).help("What this session has cost so far")
            }
            if isWorking, transcript != nil {
                Button("Stop", systemImage: "stop.circle") { onStop() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Cancel the session")
            }
            if let onClear, let transcript, transcript.isFinished {
                Button("New session", systemImage: "square.and.pencil") { onClear() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Clear the transcript and start fresh")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

struct AssistantItemView: View {
    let item: AssistantTranscript.Item
    let transcript: AssistantTranscript
    @State private var expanded = false

    var body: some View {
        switch item {
        case .turn(let index):
            HStack(spacing: 6) {
                Text("Turn \(index)").font(.caption2).foregroundStyle(.tertiary)
                VStack { Divider() }
            }
            .padding(.top, 2)
        case .user(_, let text):
            Text(text)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14)))
        case .text(_, let text):
            Text(text)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quinary))
        case .toolCall(_, let name, let input, let output, let isError):
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input").font(.caption2).foregroundStyle(.secondary)
                    Text(AssistantItemView.pretty(input)).font(.system(.caption2, design: .monospaced)).textSelection(
                        .enabled)
                    if let output {
                        Text(isError ? "Error" : "Result").font(.caption2).foregroundStyle(isError ? .red : .secondary)
                        Text(AssistantItemView.pretty(output)).font(.system(.caption2, design: .monospaced))
                            .textSelection(
                                .enabled)
                    }
                }
                .padding(.top, 2)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: AssistantItemView.toolSymbol(output: output, isError: isError))
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                    Text(name).font(.system(.caption, design: .monospaced))
                    if output == nil { Text("running").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            .font(.caption)
        case .approval(let request, let verdict):
            if let verdict {
                Label(
                    "\(request.tool): \(AssistantItemView.verdictText(verdict))",
                    systemImage: AssistantItemView.isApproved(verdict) ? "hand.thumbsup" : "hand.raised"
                )
                .font(.caption2).foregroundStyle(.secondary)
            } else {
                ApprovalCardView(
                    request: request,
                    onApprove: { Task { await transcript.approve(request, verdict: .approve) } },
                    onDeny: { Task { await transcript.approve(request, verdict: .deny(reason: nil)) } })
            }
        case .cost:
            // The running total lives in the status bar; a line per report would only repeat it.
            EmptyView()
        case .finished(_, let result, let cost):
            VStack(alignment: .leading, spacing: 4) {
                if let result, !result.isEmpty {
                    Text(result).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quinary))
                }
                if let cost {
                    Text(String(format: "Finished · $%.3f · %d turns", cost.usd, cost.turns ?? 0))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        case .failed(_, let failure):
            Label(failure.message, systemImage: "exclamationmark.octagon")
                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
        case .raw(_, let value):
            Text(AssistantItemView.pretty(value)).font(.system(.caption2, design: .monospaced)).foregroundStyle(
                .tertiary
            )
            .lineLimit(3)
        }
    }

    static func toolSymbol(output: JSONValue?, isError: Bool) -> String {
        if output == nil { return "hourglass" }
        return isError ? "xmark.octagon" : "wrench.and.screwdriver"
    }

    static func isApproved(_ v: ApprovalVerdict) -> Bool {
        if case .approve = v { return true }
        return false
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
