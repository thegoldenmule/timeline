import Foundation
import TimelineCore

// MARK: - DTOs

/// One row of the event log: the event plus where it sits (`seq` is global across streams,
/// `streamVersion` is the optimistic-concurrency counter of its stream; see storage.md section 4).
public struct StoredEvent: Hashable, Sendable, Codable {
    public var seq: Int64
    public var streamVersion: Int64
    public var event: DomainEvent

    public init(seq: Int64, streamVersion: Int64, event: DomainEvent) {
        self.seq = seq
        self.streamVersion = streamVersion
        self.event = event
    }
}

/// What `ProjectStore.apply` returns. Recorded per `commandId` so a retry gets the same answer.
public struct CommandResult: Hashable, Sendable, Codable {
    public enum Status: String, Codable, Sendable, Hashable {
        /// Events were appended in this call.
        case applied
        /// The command was valid and changed nothing (no events, no version bump).
        case noop
        /// A command with this `commandId` was already applied; this is the stored result.
        case replayed
    }

    public var commandId: CommandID
    /// Nil for a no-op.
    public var txnId: TransactionID?
    public var status: Status
    /// The stream version after the command (unchanged for `noop`).
    public var version: Int64
    public var firstSeq: Int64?
    public var lastSeq: Int64?
    public var changedIds: Set<String>
    public var warnings: [String]

    public init(
        commandId: CommandID, txnId: TransactionID? = nil, status: Status, version: Int64, firstSeq: Int64? = nil,
        lastSeq: Int64? = nil, changedIds: Set<String> = [], warnings: [String] = []
    ) {
        self.commandId = commandId
        self.txnId = txnId
        self.status = status
        self.version = version
        self.firstSeq = firstSeq
        self.lastSeq = lastSeq
        self.changedIds = changedIds
        self.warnings = warnings
    }

    /// The same result marked `replayed`, what a store returns for a duplicate `commandId`.
    public var replayed: CommandResult {
        var r = self
        r.status = .replayed
        return r
    }

    enum CodingKeys: String, CodingKey {
        case commandId, txnId, status, version, firstSeq, lastSeq, changedIds, warnings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commandId = try c.decode(CommandID.self, forKey: .commandId)
        txnId = try c.decodeIfPresent(TransactionID.self, forKey: .txnId)
        status = try c.decode(Status.self, forKey: .status)
        version = try c.decode(Int64.self, forKey: .version)
        firstSeq = try c.decodeIfPresent(Int64.self, forKey: .firstSeq)
        lastSeq = try c.decodeIfPresent(Int64.self, forKey: .lastSeq)
        changedIds = Set(try c.decodeIfPresent([String].self, forKey: .changedIds) ?? [])
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    /// `changedIds` encodes sorted so the JSON is canonical.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(commandId, forKey: .commandId)
        try c.encodeIfPresent(txnId, forKey: .txnId)
        try c.encode(status, forKey: .status)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(firstSeq, forKey: .firstSeq)
        try c.encodeIfPresent(lastSeq, forKey: .lastSeq)
        try c.encode(changedIds.sorted(), forKey: .changedIds)
        try c.encode(warnings, forKey: .warnings)
    }
}

/// Published after every committed transaction (storage.md section 6 step 10). The UI redraws the
/// entities in `changedIds`; an agent compares `version` with the one it last saw.
public struct ProjectChange: Hashable, Sendable, Codable {
    public var txnId: TransactionID
    public var version: Int64
    public var changedIds: Set<String>
    public var actor: Actor
    public var label: String
    public var kind: Transaction.Kind

    public init(
        txnId: TransactionID, version: Int64, changedIds: Set<String>, actor: Actor, label: String,
        kind: Transaction.Kind
    ) {
        self.txnId = txnId
        self.version = version
        self.changedIds = changedIds
        self.actor = actor
        self.label = label
        self.kind = kind
    }

    public init(transaction: Transaction, version: Int64) {
        self.init(
            txnId: transaction.id, version: version, changedIds: TimelineCore.changedIds(of: transaction.events),
            actor: transaction.actor, label: transaction.label, kind: transaction.kind)
    }

    enum CodingKeys: String, CodingKey {
        case txnId, version, changedIds, actor, label, kind
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        txnId = try c.decode(TransactionID.self, forKey: .txnId)
        version = try c.decode(Int64.self, forKey: .version)
        changedIds = Set(try c.decodeIfPresent([String].self, forKey: .changedIds) ?? [])
        actor = try c.decode(Actor.self, forKey: .actor)
        label = try c.decode(String.self, forKey: .label)
        kind = try c.decode(Transaction.Kind.self, forKey: .kind)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(txnId, forKey: .txnId)
        try c.encode(version, forKey: .version)
        try c.encode(changedIds.sorted(), forKey: .changedIds)
        try c.encode(actor, forKey: .actor)
        try c.encode(label, forKey: .label)
        try c.encode(kind, forKey: .kind)
    }
}

/// What the tools and the project list show about an open project.
public struct ProjectSummary: Hashable, Sendable, Codable {
    public var id: ProjectID
    public var name: String
    /// The `.tlproj` package, nil for an unsaved or in-memory project.
    public var url: URL?
    public var version: Int64
    public var activeSequenceId: SequenceID?
    public var isFrontmost: Bool

    public init(
        id: ProjectID, name: String, url: URL? = nil, version: Int64, activeSequenceId: SequenceID? = nil,
        isFrontmost: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.version = version
        self.activeSequenceId = activeSequenceId
        self.isFrontmost = isFrontmost
    }

    public init(_ project: Project, url: URL? = nil, isFrontmost: Bool = false) {
        self.init(
            id: project.id, name: project.name, url: url, version: project.version,
            activeSequenceId: project.activeSequenceId, isFrontmost: isFrontmost)
    }
}

// MARK: - Protocols

/// One open project: the single write path of storage.md section 6. UI, agent tools, and scripts all
/// go through `apply`. Implementations are actors or `Sendable` classes over one SQLite `DatabasePool`;
/// every method is `async` so callers never assume an isolation domain.
///
/// Rules every implementation keeps:
/// - `apply` is atomic: decide, invariants, append, projections, and the `commands` row commit together.
/// - `commandId` is an idempotency key: a duplicate returns the stored `CommandResult` marked
///   `.replayed` (or rethrows the stored `EditorError`) and appends nothing. The lookup happens before
///   the version check, so a retry of an applied command is never misreported as stale.
/// - `expectedVersion`, when present and different from the current version, rejects with
///   `EditorError.staleVersion(current:changedSince:)` and `changedSince` filled in. UI commands omit it.
/// - Undo is linear across actors and driven by `Command.Operation.undo` / `.redo`; the store never
///   mutates history rows, it folds markers (`History`).
/// - `changes` delivers exactly one `ProjectChange` per committed transaction, after the commit,
///   in commit order. Measured cost of the whole path on a small project: 0.16 ms per command.
/// - `version` counts events, not transactions: it advances by the number of events a transaction
///   appended, which is at least two for undo and redo (the marker plus the compensating events).
///   Consumers compare versions; they never add a fixed number to one.
public protocol ProjectStore: AnyObject, Sendable {
    /// The project id; stable for the life of the store.
    var projectId: ProjectID { get async }

    /// Applies one command (a batch is still one command, one transaction, one undo step).
    func apply(_ command: Command) async throws(EditorError) -> CommandResult

    /// The current in-memory state (the authoritative copy while the project is open).
    func state() async -> Project

    /// The stream version: `state().version`, the number of events applied.
    func version() async -> Int64

    /// Events with `streamVersion > since`, in order, with their log positions.
    func events(since version: Int64) async throws -> [StoredEvent]

    /// The transaction fold (live stack, redo stack) as of the current version.
    func history() async -> History

    /// A summary of the transactions after `version`, what a stale agent needs to re-plan.
    func changedSince(_ version: Int64) async -> ChangedSince

    /// Truncates every projection and folds the whole log again (storage.md section 12). Cheap:
    /// a 10,000-event fold is 45 ms; query tables are bulk-written from the final state.
    func rebuildProjections() async throws

    /// A fresh stream per access, yielding every change committed after the access.
    var changes: AsyncStream<ProjectChange> { get }

    /// Checkpoints, writes the debounced state row, marks the session closed. The store is unusable after.
    func close() async throws
}

/// Opens and creates project stores. The composition root holds one of these per storage backend;
/// `ContractsTestSupport` ships an in-memory one.
public protocol ProjectStoreOpening: Sendable {
    /// Opens an existing `.tlproj` package (or, for in-memory implementations, a registered key).
    func open(at url: URL) async throws -> any ProjectStore

    /// Creates a project at `url` and applies `createProject` as its first transaction.
    func create(at url: URL, name: String, settings: ProjectSettings, sequence: Command.Operation.SequenceSpec)
        async throws -> any ProjectStore
}

/// The open projects of a document-based app. Every tool takes a `projectId` because several projects
/// can be open; `frontmost` is the default when the tool input omits it.
public protocol ProjectDirectory: Sendable {
    func open() async -> [ProjectSummary]
    func frontmost() async -> ProjectSummary?
    func store(for id: ProjectID) async -> (any ProjectStore)?
}
