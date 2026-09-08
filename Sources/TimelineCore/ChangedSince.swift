import Foundation

/// Every entity id touched by `events`.
public func changedIds(of events: [DomainEvent]) -> Set<String> {
    Set(events.flatMap(\.payload.touchedIds))
}

extension ChangedSince {
    /// Summarises `transactions` for an agent whose view is at `fromVersion`.
    public init(fromVersion: Int64, toVersion: Int64, transactions: [Transaction]) {
        self.init(
            fromVersion: fromVersion, toVersion: toVersion,
            transactions: transactions.map { t in
                TransactionSummary(
                    txnId: t.id, actor: t.actor, label: t.label, changedIds: changedIds(of: t.events).sorted(),
                    events: t.events.map {
                        EventSummary(type: $0.type, ids: $0.payload.touchedIds, summary: $0.payload.summary)
                    })
            })
    }

    /// Builds from the slice of the event log after `fromVersion`; `toVersion` is `fromVersion + events.count`.
    public static func build(from events: [DomainEvent], fromVersion: Int64, labels: [TransactionID: String] = [:])
        -> ChangedSince
    {
        ChangedSince(
            fromVersion: fromVersion, toVersion: fromVersion + Int64(events.count),
            transactions: Transaction.group(events, labels: labels))
    }
}
