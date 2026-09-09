import Foundation

/// The events of one command, the unit of undo.
public struct Transaction: Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case edit
        case undo
        case redo
    }

    public var id: TransactionID
    public var actor: Actor
    public var label: String
    public var kind: Kind
    /// For undo and redo transactions: the transaction acted on.
    public var target: TransactionID?
    public var events: [DomainEvent]

    public init(
        id: TransactionID, actor: Actor, label: String, kind: Kind, target: TransactionID? = nil, events: [DomainEvent]
    ) {
        self.id = id
        self.actor = actor
        self.label = label
        self.kind = kind
        self.target = target
        self.events = events
    }

    /// Derives id, actor, kind, and target from a non-empty run of events sharing one `txnId`.
    public init(events: [DomainEvent], label: String? = nil) {
        precondition(!events.isEmpty, "A transaction has at least one event")
        let first = events[0]
        var kind = Kind.edit
        var target: TransactionID?
        switch first.payload {
        case .transactionUndone(let p):
            kind = .undo
            target = p.targetTxnId
        case .transactionRedone(let p):
            kind = .redo
            target = p.targetTxnId
        default:
            break
        }
        self.init(
            id: first.txnId, actor: first.actor, label: label ?? Transaction.defaultLabel(for: events), kind: kind,
            target: target, events: events)
    }

    /// Groups a raw event log into transactions by consecutive `txnId`.
    public static func group(_ events: [DomainEvent], labels: [TransactionID: String] = [:]) -> [Transaction] {
        var result: [Transaction] = []
        var run: [DomainEvent] = []
        for e in events {
            if let last = run.last, last.txnId != e.txnId {
                result.append(Transaction(events: run, label: labels[last.txnId]))
                run = []
            }
            run.append(e)
        }
        if let last = run.last { result.append(Transaction(events: run, label: labels[last.txnId])) }
        return result
    }

    /// A label derived from the events when the command's label is unknown.
    public static func defaultLabel(for events: [DomainEvent]) -> String {
        guard let first = events.first else { return "Edit" }
        switch first.payload {
        case .transactionUndone: return "Undo"
        case .transactionRedone: return "Redo"
        default: break
        }
        let edits = events.filter { !$0.payload.isHistoryMarker }
        let types = Set(edits.map(\.payload.typeName))
        if types.count == 1, let type = types.first { return TimelineCore.label(forEventType: type) }
        if types.count > 1 { return "\(edits.count) edits" }
        return "Edit"
    }
}

/// A short label for a single event type, e.g. "ClipTrimmed" -> "Trim clip".
public func label(forEventType type: String) -> String {
    switch type {
    case "ProjectCreated": "Create project"
    case "ProjectSettingsChanged": "Change project settings"
    case "ProjectRenamed": "Rename project"
    case "SequenceAdded": "Add sequence"
    case "SequenceSettingsChanged": "Change sequence settings"
    case "ActiveSequenceChanged": "Switch sequence"
    case "AssetImported": "Import asset"
    case "AssetRelinked": "Relink asset"
    case "AssetRemoved": "Remove asset"
    case "AssetRestored": "Restore asset"
    case "AssetAnalysisRecorded": "Record analysis"
    case "TrackAdded": "Add track"
    case "TrackRemoved": "Remove track"
    case "TrackRestored": "Restore track"
    case "TrackReordered": "Reorder track"
    case "TrackRenamed": "Rename track"
    case "TrackMuteSet": "Mute track"
    case "TrackLockSet": "Lock track"
    case "TrackSoloSet": "Solo track"
    case "ClipAdded": "Add clip"
    case "ClipRemoved": "Remove clip"
    case "ClipMoved": "Move clip"
    case "ClipTrimmed": "Trim clip"
    case "ClipSplit": "Split clip"
    case "ClipsJoined": "Join clips"
    case "ClipSpeedSet": "Change speed"
    case "ClipTransformSet": "Transform clip"
    case "ClipOpacitySet": "Change opacity"
    case "ClipAudioSet": "Change clip audio"
    case "ClipEffectAdded": "Add effect"
    case "ClipEffectChanged": "Change effect"
    case "ClipEffectRemoved": "Remove effect"
    case "ClipsLinked": "Link clips"
    case "ClipsUnlinked": "Unlink clips"
    case "TransitionAdded": "Add transition"
    case "TransitionChanged": "Change transition"
    case "TransitionRemoved": "Remove transition"
    case "CaptionTrackAdded": "Add caption track"
    case "CaptionsReplaced": "Replace captions"
    case "CaptionEdited": "Edit caption"
    case "CaptionStyleSet": "Change caption style"
    case "MarkerAdded": "Add marker"
    case "MarkerMoved": "Move marker"
    case "MarkerRemoved": "Remove marker"
    case "TransactionUndone": "Undo"
    case "TransactionRedone": "Redo"
    default: type
    }
}

/// The fold of `docs/design/timeline-model.md` section 7 over a transaction sequence. Undo is linear
/// across actors: a transaction is live unless the most recent marker targeting it is an undo; the
/// redo stack holds undone transactions not yet orphaned by a newer edit.
public struct History: Hashable, Sendable {
    public private(set) var transactions: [Transaction] = []
    /// Live edit transactions in log order; the last one is the undo target.
    public private(set) var live: [TransactionID] = []
    /// Undone transactions that can still be redone; the last one is the redo target.
    public private(set) var redoStack: [TransactionID] = []
    private var index: [TransactionID: Int] = [:]

    public init() {}

    public init(transactions: [Transaction]) {
        for t in transactions { append(t) }
    }

    /// Folds a transaction sequence.
    public static func fold(transactions: [Transaction]) -> History { History(transactions: transactions) }

    /// Folds a raw event log.
    public static func fold(events: [DomainEvent], labels: [TransactionID: String] = [:]) -> History {
        History(transactions: Transaction.group(events, labels: labels))
    }

    public subscript(id: TransactionID) -> Transaction? {
        guard let i = index[id] else { return nil }
        return transactions[i]
    }

    /// Every edit transaction that is not live, including ones no longer reachable by redo.
    public var undone: Set<TransactionID> {
        let liveSet = Set(live)
        return Set(transactions.filter { $0.kind == .edit && !liveSet.contains($0.id) }.map(\.id))
    }

    public var latestLive: Transaction? { live.last.flatMap { self[$0] } }
    public var redoTarget: Transaction? { redoStack.last.flatMap { self[$0] } }

    public func isLive(_ id: TransactionID) -> Bool { live.contains(id) }

    /// Number of events across all transactions (the version the history reflects).
    public var eventCount: Int { transactions.reduce(0) { $0 + $1.events.count } }

    public var allEvents: [DomainEvent] { transactions.flatMap(\.events) }

    /// Appends one transaction and updates the fold incrementally.
    public mutating func append(_ transaction: Transaction) {
        index[transaction.id] = transactions.count
        transactions.append(transaction)
        switch transaction.kind {
        case .edit:
            live.append(transaction.id)
            redoStack.removeAll()
        case .undo:
            guard let target = transaction.target else { return }
            live.removeAll { $0 == target }
            redoStack.removeAll { $0 == target }
            redoStack.append(target)
        case .redo:
            guard let target = transaction.target else { return }
            redoStack.removeAll { $0 == target }
            live.removeAll { $0 == target }
            live.append(target)
        }
    }

    /// The history with `transaction` appended.
    public func appending(_ transaction: Transaction) -> History {
        var h = self
        h.append(transaction)
        return h
    }
}
