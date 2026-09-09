import Contracts
import Foundation
import Observation
import SwiftUI
import TimelineCore

/// A finished publish job's payload: "View on YouTube", "Open in Studio", the privacy YouTube reported
/// (and the one requested when it differs, D6), the audience reminder (D9), and the receipt's warnings.
public struct PublishOutcomeView: View {
    public let outcome: JobOutcome
    public let receipt: PublishReceipt?

    public init(outcome: JobOutcome) {
        self.outcome = outcome
        self.receipt = PublishOutcomeView.receipt(in: outcome)
    }

    public static func receipt(in outcome: JobOutcome) -> PublishReceipt? {
        try? outcome.payload(as: PublishReceipt.self)
    }

    /// "Uploaded as private" or "Uploaded as private (public was requested)".
    public static func privacyText(_ receipt: PublishReceipt) -> String {
        var s = "Uploaded as \(receipt.privacy.rawValue)"
        if receipt.privacy != receipt.requestedPrivacy { s += " (\(receipt.requestedPrivacy.rawValue) was requested)" }
        return s
    }

    public static let audienceReminder = "Set the audience (made for kids) in YouTube Studio"

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let receipt {
                HStack(spacing: 12) {
                    Link("View on YouTube", destination: receipt.remoteURL)
                    if let studio = receipt.studioURL { Link("Open in Studio", destination: studio) }
                }
                .font(.caption)
                HStack(spacing: 8) {
                    Text(PublishOutcomeView.privacyText(receipt))
                    if let channel = receipt.channelTitle { Text("on \(channel)") }
                    if let publishAt = receipt.publishAt {
                        Text("scheduled for \(publishAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if receipt.madeForKids == nil {
                    Label(PublishOutcomeView.audienceReminder, systemImage: "person.2").font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(Array(Set(receipt.warnings + outcome.warnings)).sorted(), id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            } else {
                ForEach(outcome.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text("Published (no receipt)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("publish-outcome")
    }
}

/// The `publishes` ledger for the history list. `load()` reads it newest first; `resumable` are the
/// `failed` and `cancelled` rows that still hold a session.
@MainActor @Observable
public final class PublishHistoryModel {
    public let ledger: any PublishLedger
    public private(set) var records: [PublishRecord] = []
    public private(set) var error: String?

    public init(ledger: any PublishLedger) {
        self.ledger = ledger
    }

    public func load() async {
        do {
            records = try await ledger.publishes()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    public var resumable: [PublishRecord] { records.filter(\.isResumable) }

    public func canResume(_ record: PublishRecord) -> Bool { record.isResumable }
}

/// Rows of past and current publishes: status, privacy, channel, the YouTube link, and Resume for
/// rows that can continue their upload.
public struct PublishHistoryView: View {
    public let model: PublishHistoryModel
    public let onResume: (String) -> Void

    public init(model: PublishHistoryModel, onResume: @escaping (String) -> Void) {
        self.model = model
        self.onResume = onResume
    }

    public init(ledger: any PublishLedger, onResume: @escaping (String) -> Void) {
        self.init(model: PublishHistoryModel(ledger: ledger), onResume: onResume)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Publishes").font(.headline)
            if model.records.isEmpty {
                Text("No publishes yet").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            ForEach(model.records) { record in
                PublishHistoryRow(record: record, canResume: model.canResume(record)) { onResume(record.id) }
            }
        }
        .padding(8)
        .task { await model.load() }
    }
}

public struct PublishHistoryRow: View {
    public let record: PublishRecord
    public let canResume: Bool
    public let onResume: () -> Void

    public init(record: PublishRecord, canResume: Bool, onResume: @escaping () -> Void) {
        self.record = record
        self.canResume = canResume
        self.onResume = onResume
    }

    /// "done · private · Skeleton Channel".
    public static func detailText(_ record: PublishRecord) -> String {
        var parts = [record.status.rawValue, (record.receipt?.privacy ?? record.request.privacy).rawValue]
        if let channel = record.receipt?.channelTitle { parts.append(channel) }
        if let sent = record.bytesSent, let total = record.bytesTotal, total > 0, !record.status.isTerminal {
            parts.append(String(format: "%.0f%%", Double(sent) / Double(total) * 100))
        }
        return parts.joined(separator: " · ")
    }

    public var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.request.title).font(.subheadline).lineLimit(1)
                Text(PublishHistoryRow.detailText(record)).font(.caption).foregroundStyle(.secondary)
                if let error = record.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                if let url = record.remoteURL { Link("View on YouTube", destination: url).font(.caption) }
            }
            Spacer()
            if canResume {
                Button("Resume", action: onResume).font(.caption)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("publish-\(record.id)")
    }
}
