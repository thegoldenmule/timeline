import Contracts
import Foundation
import Observation
import SwiftUI
import TimelineCore

/// Collects `ApprovalRequest`s from an `ApprovalGate` (its pending list plus the live stream) and
/// answers them. One per app; the cards stack in the order the requests arrived.
@MainActor @Observable
public final class ApprovalCenter {
    public let gate: any ApprovalGate
    public private(set) var requests: [ApprovalRequest] = []
    public private(set) var answered: [(request: ApprovalRequest, verdict: ApprovalVerdict)] = []
    private var subscription: Task<Void, Never>?

    public init(gate: any ApprovalGate) {
        self.gate = gate
    }

    /// Loads the pending requests and follows the gate's stream.
    public func start() async {
        guard subscription == nil else { return }
        let stream = gate.requests
        subscription = Task { [weak self] in
            for await request in stream {
                guard let self else { return }
                self.add(request)
            }
        }
        for request in await gate.pending() { add(request) }
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
    }

    /// Adds a request directly (agent transcripts hand over `.approvalRequested` events this way).
    public func add(_ request: ApprovalRequest) {
        guard !requests.contains(where: { $0.id == request.id }) else { return }
        requests.append(request)
    }

    public func approve(_ request: ApprovalRequest) async {
        await gate.grant(request.token)
        finish(request, .approve)
    }

    public func deny(_ request: ApprovalRequest, reason: String? = nil) async {
        await gate.deny(request.token, reason: reason)
        finish(request, .deny(reason: reason))
    }

    private func finish(_ request: ApprovalRequest, _ verdict: ApprovalVerdict) {
        requests.removeAll { $0.id == request.id }
        answered.append((request, verdict))
    }
}

/// One approval request: tool, the tool's summary (else the gate's input summary), the presentation's
/// label/value details and warnings, the estimate, Deny, and Approve.
public struct ApprovalCardView: View {
    public let request: ApprovalRequest
    public let onApprove: () -> Void
    public let onDeny: () -> Void

    public init(request: ApprovalRequest, onApprove: @escaping () -> Void, onDeny: @escaping () -> Void) {
        self.request = request
        self.onApprove = onApprove
        self.onDeny = onDeny
    }

    public static let publishTool = "publish_youtube"

    /// The card's headline: the presentation's summary when the tool supplied one.
    public static func summary(for request: ApprovalRequest) -> String {
        request.presentation?.summary ?? request.inputSummary
    }

    /// "Upload" for `publish_youtube` (the click that certifies, D12), "Approve" otherwise.
    public static func approveTitle(for tool: String) -> String { tool == publishTool ? "Upload" : "Approve" }

    public var summary: String { ApprovalCardView.summary(for: request) }
    public var details: [ApprovalDetail] { request.presentation?.details ?? [] }
    public var warnings: [String] { request.presentation?.warnings ?? [] }
    public var approveTitle: String { ApprovalCardView.approveTitle(for: request.tool) }

    public static func estimateText(_ e: Estimate) -> String {
        var parts: [String] = []
        if let s = e.seconds { parts.append(s < 90 ? String(format: "%.0f s", s) : String(format: "%.1f min", s / 60)) }
        if let u = e.usd { parts.append(String(format: "$%.2f", u)) }
        if let b = e.bytes { parts.append(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)) }
        return parts.isEmpty ? "no estimate" : parts.joined(separator: " · ")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(request.tool).font(.headline)
                Spacer()
                Text(request.actor.description).font(.caption).foregroundStyle(.secondary)
            }
            Text(summary).font(.body).textSelection(.enabled)
            if !details.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                        GridRow(alignment: .top) {
                            Text(detail.label).font(.caption).foregroundStyle(.secondary)
                            Text(detail.value).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Text("Estimate: \(ApprovalCardView.estimateText(request.estimate))")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Deny", role: .cancel, action: onDeny).keyboardShortcut(.cancelAction)
                Button(approveTitle, action: onApprove).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("approval-card-\(request.id)")
    }
}

/// The stack of outstanding approval cards.
public struct ApprovalStackView: View {
    public let center: ApprovalCenter

    public init(center: ApprovalCenter) {
        self.center = center
    }

    public var body: some View {
        VStack(spacing: 8) {
            ForEach(center.requests) { request in
                ApprovalCardView(
                    request: request,
                    onApprove: { Task { await center.approve(request) } },
                    onDeny: { Task { await center.deny(request) } })
            }
            if center.requests.isEmpty {
                Text("No approvals pending").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await center.start() }
    }
}
