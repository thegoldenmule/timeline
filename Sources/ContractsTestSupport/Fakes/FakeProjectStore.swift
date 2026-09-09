import Contracts
import Foundation
import TimelineCore

public enum FakeStoreError: Error, Hashable, Sendable {
    case closed
    case notFound(URL)
    case alreadyExists(URL)
    /// `rebuildProjections` refolded the log and got a different state or history.
    case rebuildMismatch(String)
    /// A render or publish ledger row that does not exist.
    case unknownRecord(String)
}

/// An in-memory `ProjectStore` over TimelineCore's `decide` / `evolve` / `History`. It behaves like the
/// SQLite store in every way a client can observe: a version counter, command idempotency (stored
/// results and stored rejections), `expectedVersion` stale rejection with `ChangedSince`, undo and redo
/// through the history fold, a `seq`-numbered log, and one `ProjectChange` per committed transaction.
public actor FakeProjectStore: ProjectStore {
    public private(set) var project: Project
    public private(set) var fold: History
    private var log: [StoredEvent] = []
    private var results: [CommandID: Result<CommandResult, EditorError>] = [:]
    private let ids: any IDGenerator
    private let clock: any Clock
    private let broadcaster = Broadcaster<ProjectChange>()
    /// Every command handed to `apply`, in order, including replays and rejections.
    public private(set) var receivedCommands: [Command] = []
    public private(set) var isClosed = false
    public private(set) var rebuildCount = 0
    public var url: URL?
    private var renderRows: [String: RenderRecord] = [:]
    private var publishRows: [String: PublishRecord] = [:]

    public init(
        project: Project = .blank, history: History = History(),
        ids: any IDGenerator = SequentialIDGenerator(start: 1000),
        clock: any Clock = FixedClock(step: 1)
    ) {
        precondition(Int64(history.eventCount) == project.version, "history must cover exactly the project's version")
        self.project = project
        self.fold = history
        self.ids = ids
        self.clock = clock
        for (i, event) in history.allEvents.enumerated() {
            log.append(StoredEvent(seq: Int64(i + 1), streamVersion: Int64(i + 1), event: event))
        }
    }

    /// Wraps a `ProjectBuilder`'s state and log, continuing its id generator and clock.
    public init(builder: ProjectBuilder) {
        self.init(project: builder.project, history: builder.history, ids: builder.ids, clock: builder.clock)
    }

    public var projectId: ProjectID { project.id }

    public func apply(_ command: Command) throws(EditorError) -> CommandResult {
        receivedCommands.append(command)
        if isClosed { throw .invalid(reason: "The store is closed") }
        if let stored = results[command.commandId] {
            switch stored {
            case .success(let result): return result.replayed
            case .failure(let error): throw error
            }
        }
        let events: [DomainEvent]
        do {
            events = try decide(project, command, ids: ids, clock: clock, history: fold)
        } catch {
            results[command.commandId] = .failure(error)
            throw error
        }
        guard !events.isEmpty else {
            let result = CommandResult(commandId: command.commandId, status: .noop, version: project.version)
            results[command.commandId] = .success(result)
            return result
        }
        evolve(&project, events)
        let transaction = Transaction(events: events, label: command.effectiveLabel)
        fold.append(transaction)
        let firstSeq = Int64(log.count + 1)
        for (i, event) in events.enumerated() {
            let seq = firstSeq + Int64(i)
            log.append(StoredEvent(seq: seq, streamVersion: seq, event: event))
        }
        let result = CommandResult(
            commandId: command.commandId, txnId: transaction.id, status: .applied, version: project.version,
            firstSeq: firstSeq, lastSeq: Int64(log.count), changedIds: changedIds(of: events))
        results[command.commandId] = .success(result)
        broadcaster.send(ProjectChange(transaction: transaction, version: project.version))
        return result
    }

    public func state() -> Project { project }
    public func version() -> Int64 { project.version }

    public func events(since version: Int64) throws -> [StoredEvent] {
        if isClosed { throw FakeStoreError.closed }
        return log.filter { $0.streamVersion > version }
    }

    public func history() -> History { fold }

    public func changedSince(_ version: Int64) -> ChangedSince {
        let from = max(0, min(version, project.version))
        let labels = Dictionary(uniqueKeysWithValues: fold.transactions.map { ($0.id, $0.label) })
        return ChangedSince.build(
            from: log.filter { $0.streamVersion > from }.map(\.event), fromVersion: from, labels: labels)
    }

    /// Refolds the log from `Project.blank` and checks it reproduces the in-memory state and history.
    public func rebuildProjections() throws {
        if isClosed { throw FakeStoreError.closed }
        rebuildCount += 1
        var rebuilt = Project.blank
        evolve(&rebuilt, log.map(\.event))
        guard rebuilt == project else { throw FakeStoreError.rebuildMismatch("state") }
        let labels = Dictionary(uniqueKeysWithValues: fold.transactions.map { ($0.id, $0.label) })
        let refold = History.fold(events: log.map(\.event), labels: labels)
        guard refold.live == fold.live, refold.redoStack == fold.redoStack else {
            throw FakeStoreError.rebuildMismatch("history")
        }
    }

    public nonisolated var changes: AsyncStream<ProjectChange> { broadcaster.subscribe() }

    public func close() throws {
        isClosed = true
        broadcaster.finish()
    }

    // MARK: Test conveniences

    /// The raw log.
    public var storedEvents: [StoredEvent] { log }

    /// The stored outcome for a command id, if any.
    public func storedResult(for id: CommandID) -> Result<CommandResult, EditorError>? { results[id] }

    /// A command envelope minted from this store's generator, for tests that do not care about ids.
    public nonisolated func command(
        _ operation: Command.Operation, actor: Actor = .human, expectedVersion: Int64? = nil, label: String? = nil
    ) -> Command {
        Command(
            commandId: CommandID(minting: ids), actor: actor, expectedVersion: expectedVersion, label: label,
            operation: operation)
    }

    /// `apply` for an operation, with an envelope minted here.
    @discardableResult
    public func apply(
        _ operation: Command.Operation, actor: Actor = .human, expectedVersion: Int64? = nil, label: String? = nil
    ) throws(EditorError) -> CommandResult {
        try apply(command(operation, actor: actor, expectedVersion: expectedVersion, label: label))
    }
}

// MARK: Ledgers

/// The render and publish ledgers in memory, with the rules of `RenderLedger` and `PublishLedger`:
/// unknown ids throw `FakeStoreError.unknownRecord`, terminal states set `completedAt`, recording never
/// touches the event log, the version, or `changes`; lists are newest first by `requestedAt` then id.
extension FakeProjectStore: RenderLedger, PublishLedger {
    public func recordRender(id: String?, sequenceId: SequenceID, preset: ExportPreset, projectVersion: Int64?) throws
        -> RenderRecord
    {
        if isClosed { throw FakeStoreError.closed }
        let record = RenderRecord(
            id: id ?? ids.next(), sequenceId: sequenceId, preset: preset,
            projectVersion: projectVersion ?? project.version, status: .queued, requestedAt: clock.now())
        renderRows[record.id] = record
        return record
    }

    public func updateRender(
        _ id: String, status: RenderStatus, outputURL: URL?, outputHash: String?, receipt: ExportReceipt?
    ) throws -> RenderRecord {
        if isClosed { throw FakeStoreError.closed }
        guard var record = renderRows[id] else { throw FakeStoreError.unknownRecord(id) }
        record.status = status
        if let outputURL { record.outputURL = outputURL }
        if let outputHash { record.outputHash = outputHash }
        if let receipt { record.receipt = receipt }
        if status.isTerminal { record.completedAt = clock.now() }
        renderRows[id] = record
        return record
    }

    public func renders() throws -> [RenderRecord] {
        if isClosed { throw FakeStoreError.closed }
        return renderRows.values.sorted { a, b in
            a.requestedAt != b.requestedAt ? a.requestedAt > b.requestedAt : a.id > b.id
        }
    }

    public func render(_ id: String) throws -> RenderRecord? {
        if isClosed { throw FakeStoreError.closed }
        return renderRows[id]
    }

    public func recordPublish(id: String?, request: PublishRequest, projectVersion: Int64?) throws -> PublishRecord {
        if isClosed { throw FakeStoreError.closed }
        guard let render = renderRows[request.renderId] else { throw FakeStoreError.unknownRecord(request.renderId) }
        let size = (try? FileManager.default.attributesOfItem(atPath: request.fileURL.path))?[.size] as? NSNumber
        let record = PublishRecord(
            id: id ?? ids.next(), renderId: request.renderId, destination: request.destination,
            accountId: request.accountId, status: .queued, request: request, bytesTotal: size?.int64Value,
            projectVersion: projectVersion ?? render.projectVersion, requestedAt: clock.now())
        publishRows[record.id] = record
        return record
    }

    public func updatePublish(_ id: String, _ update: PublishUpdate) throws -> PublishRecord {
        if isClosed { throw FakeStoreError.closed }
        guard var record = publishRows[id] else { throw FakeStoreError.unknownRecord(id) }
        if let status = update.status {
            record.status = status
            if status.isTerminal { record.completedAt = clock.now() }
        }
        if let session = update.session { record.session = session }
        if update.clearsSession { record.session = nil }
        if let bytesSent = update.bytesSent { record.bytesSent = bytesSent }
        if let remoteId = update.remoteId { record.remoteId = remoteId }
        if let remoteURL = update.remoteURL { record.remoteURL = remoteURL }
        if let receipt = update.receipt { record.receipt = receipt }
        if let error = update.error { record.error = error }
        publishRows[id] = record
        return record
    }

    public func publishes() throws -> [PublishRecord] {
        if isClosed { throw FakeStoreError.closed }
        return publishRows.values.sorted { a, b in
            a.requestedAt != b.requestedAt ? a.requestedAt > b.requestedAt : a.id > b.id
        }
    }

    public func publish(_ id: String) throws -> PublishRecord? {
        if isClosed { throw FakeStoreError.closed }
        return publishRows[id]
    }

    public func publishes(forRender renderId: String) throws -> [PublishRecord] {
        try publishes().filter { $0.renderId == renderId }
    }
}

/// In-memory `ProjectStoreOpening`: stores are keyed by URL, `create` runs `createProject` as the first
/// transaction, `open` returns what was registered or created.
public actor FakeProjectStoreOpener: ProjectStoreOpening {
    private var stores: [URL: FakeProjectStore] = [:]
    private let ids: any IDGenerator
    private let clock: any Clock

    public init(ids: any IDGenerator = UUIDv7Generator(), clock: any Clock = SystemClock()) {
        self.ids = ids
        self.clock = clock
    }

    public func register(_ store: FakeProjectStore, at url: URL) async {
        stores[url.standardizedFileURL] = store
        await store.setURL(url)
    }

    public func open(at url: URL) async throws -> any ProjectStore {
        guard let store = stores[url.standardizedFileURL] else { throw FakeStoreError.notFound(url) }
        return store
    }

    public func create(at url: URL, name: String, settings: ProjectSettings, sequence: Command.Operation.SequenceSpec)
        async throws -> any ProjectStore
    {
        let key = url.standardizedFileURL
        guard stores[key] == nil else { throw FakeStoreError.alreadyExists(url) }
        let store = FakeProjectStore(ids: ids, clock: clock)
        await store.setURL(url)
        _ = try await store.apply(
            .createProject(.init(name: name, settings: settings, sequence: sequence)), actor: .system)
        stores[key] = store
        return store
    }

    public var openStores: [URL: FakeProjectStore] { stores }
}

extension FakeProjectStore {
    fileprivate func setURL(_ url: URL) { self.url = url }
}

/// The open projects of a fake app. The first store added is frontmost until `setFrontmost`.
public actor FakeProjectDirectory: ProjectDirectory {
    private var entries: [(id: ProjectID, store: any ProjectStore, url: URL?)] = []
    private var frontmostId: ProjectID?

    public init() {}

    public init(stores: [any ProjectStore]) async {
        for store in stores { await add(store) }
    }

    public func add(_ store: any ProjectStore, url: URL? = nil, frontmost: Bool = false) async {
        let id = await store.projectId
        entries.removeAll { $0.id == id }
        entries.append((id, store, url))
        if frontmost || frontmostId == nil { frontmostId = id }
    }

    public func remove(_ id: ProjectID) {
        entries.removeAll { $0.id == id }
        if frontmostId == id { frontmostId = entries.first?.id }
    }

    public func setFrontmost(_ id: ProjectID) { frontmostId = id }

    public func open() async -> [ProjectSummary] {
        var result: [ProjectSummary] = []
        for e in entries {
            result.append(ProjectSummary(await e.store.state(), url: e.url, isFrontmost: e.id == frontmostId))
        }
        return result
    }

    public func frontmost() async -> ProjectSummary? {
        guard let id = frontmostId, let e = entries.first(where: { $0.id == id }) else { return nil }
        return ProjectSummary(await e.store.state(), url: e.url, isFrontmost: true)
    }

    public func store(for id: ProjectID) -> (any ProjectStore)? { entries.first { $0.id == id }?.store }
}
