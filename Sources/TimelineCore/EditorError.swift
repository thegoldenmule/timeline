import Foundation

/// Every way a command can be rejected. Shared by the core, the store, the tools, and the UI.
public enum EditorError: Error, Hashable, Sendable {
    /// `expectedVersion` did not match. `changedSince` is filled in when the decider had history to
    /// build it from; the store fills it in otherwise.
    case staleVersion(current: Int64, changedSince: ChangedSince?)
    case invalid(reason: String, suggestion: String? = nil)
    case trackLocked(TrackID)
    /// The transition's handles do not exist; `maxDuration` is the largest duration that would fit.
    case transitionHandles(maxDuration: RationalTime)
    case notFound(id: String)
    case alreadyUndone
    case nothingToRedo

    public var code: String {
        switch self {
        case .staleVersion: "staleVersion"
        case .invalid: "invalid"
        case .trackLocked: "trackLocked"
        case .transitionHandles: "transitionHandles"
        case .notFound: "notFound"
        case .alreadyUndone: "alreadyUndone"
        case .nothingToRedo: "nothingToRedo"
        }
    }

    public var message: String {
        switch self {
        case .staleVersion(let current, _): "Project changed; current version is \(current)"
        case .invalid(let reason, let suggestion):
            suggestion.map { "\(reason). \($0)" } ?? reason
        case .trackLocked(let id): "Track \(id) is locked"
        case .transitionHandles(let max): "Not enough media for the transition; the longest that fits is \(max)"
        case .notFound(let id): "No entity with id \(id)"
        case .alreadyUndone: "That transaction is already undone"
        case .nothingToRedo: "Nothing to redo"
        }
    }
}

extension EditorError: LocalizedError {
    public var errorDescription: String? { message }
}

extension EditorError: Codable {
    enum CodingKeys: String, CodingKey {
        case code
        case message
        case current
        case changedSince
        case reason
        case suggestion
        case trackId
        case maxDuration
        case id
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(String.self, forKey: .code)
        switch code {
        case "staleVersion":
            self = .staleVersion(
                current: try c.decode(Int64.self, forKey: .current),
                changedSince: try c.decodeIfPresent(ChangedSince.self, forKey: .changedSince))
        case "invalid":
            self = .invalid(
                reason: try c.decode(String.self, forKey: .reason),
                suggestion: try c.decodeIfPresent(String.self, forKey: .suggestion))
        case "trackLocked": self = .trackLocked(try c.decode(TrackID.self, forKey: .trackId))
        case "transitionHandles":
            self = .transitionHandles(maxDuration: try c.decode(RationalTime.self, forKey: .maxDuration))
        case "notFound": self = .notFound(id: try c.decode(String.self, forKey: .id))
        case "alreadyUndone": self = .alreadyUndone
        case "nothingToRedo": self = .nothingToRedo
        default:
            throw DecodingError.dataCorruptedError(forKey: .code, in: c, debugDescription: "Unknown error code \(code)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(message, forKey: .message)
        switch self {
        case .staleVersion(let current, let changed):
            try c.encode(current, forKey: .current)
            try c.encodeIfPresent(changed, forKey: .changedSince)
        case .invalid(let reason, let suggestion):
            try c.encode(reason, forKey: .reason)
            try c.encodeIfPresent(suggestion, forKey: .suggestion)
        case .trackLocked(let id): try c.encode(id, forKey: .trackId)
        case .transitionHandles(let max): try c.encode(max, forKey: .maxDuration)
        case .notFound(let id): try c.encode(id, forKey: .id)
        case .alreadyUndone, .nothingToRedo: break
        }
    }
}

/// What changed between two versions; returned to an agent whose `expectedVersion` was stale.
public struct ChangedSince: Hashable, Sendable, Codable {
    public struct EventSummary: Hashable, Sendable, Codable {
        public var type: String
        public var ids: [String]
        public var summary: String

        public init(type: String, ids: [String], summary: String) {
            self.type = type
            self.ids = ids
            self.summary = summary
        }
    }

    public struct TransactionSummary: Hashable, Sendable, Codable {
        public var txnId: TransactionID
        public var actor: Actor
        public var label: String
        public var changedIds: [String]
        public var events: [EventSummary]

        public init(txnId: TransactionID, actor: Actor, label: String, changedIds: [String], events: [EventSummary]) {
            self.txnId = txnId
            self.actor = actor
            self.label = label
            self.changedIds = changedIds
            self.events = events
        }
    }

    public var fromVersion: Int64
    public var toVersion: Int64
    public var transactions: [TransactionSummary]

    public init(fromVersion: Int64, toVersion: Int64, transactions: [TransactionSummary]) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.transactions = transactions
    }
}
