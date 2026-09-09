import Contracts
import Foundation
import GRDB
import Synchronization
import TimelineCore

/// The SQLite `ProjectStore` of storage.md: one actor per open project over one GRDB connection
/// (`DatabasePool` for `.tlproj` packages, `DatabaseQueue(":memory:")` for tests).
///
/// The authoritative `Project` and its `History` live in memory while the project is open; `apply`
/// runs the write path of storage.md section 6 in one SQLite transaction and only then updates the
/// in-memory copies, so a failed commit leaves them untouched. `project_state` is written on a
/// debounce (section 5), on `flush()`, and on `close()`; `open` folds any newer events on top.
public actor SQLiteProjectStore: ProjectStore {
    /// Tunables of the store. Defaults are the numbers in storage.md.
    public struct Options: Sendable {
        /// How long after the last command the full-state row is written (storage.md section 5).
        public var stateWriteDebounce: Duration = .milliseconds(250)
        /// `commands` rows older than this are pruned on open (section 6).
        public var commandRetention: TimeInterval = 30 * 86400
        /// WAL by default; DELETE for synced folders (section 2).
        public var journal: JournalMode = .wal

        public init() {}
    }

    /// How the journal is kept. WAL is the default; DELETE is the fallback for synced folders
    /// (storage.md section 2), where one file is safer than three.
    public enum JournalMode: String, Sendable {
        case wal
        case delete
    }

    /// What the open-time checks of storage.md section 12 found and did.
    public struct RecoveryReport: Hashable, Sendable {
        /// The previous session did not close cleanly.
        public var uncleanShutdown = false
        /// `PRAGMA integrity_check` ran (and answered `ok`, or open would have failed).
        public var integrityChecked = false
        /// Events folded onto the stored `project_state` because it lagged the log.
        public var stateEventsFolded = 0
        /// Query tables or history lagged the log and were rebuilt.
        public var projectionsRebuilt = false
        /// `commands` rows pruned by the retention policy.
        public var commandsPruned = 0
        /// Milliseconds spent opening (migrate, checks, load).
        public var openMilliseconds: Double = 0

        public init() {}
    }

    nonisolated let writer: any DatabaseWriter
    /// The `.tlproj` package, nil for an in-memory store.
    public nonisolated let url: URL?
    public nonisolated let options: Options
    nonisolated let ids: any IDGenerator
    nonisolated let clock: any Clock
    private let broadcaster = Broadcaster<ProjectChange>()
    /// How to end each live observation stream when the store closes.
    private let observers = Mutex<[UUID: @Sendable () -> Void]>([:])

    private var project: Project
    private var fold: History
    /// `MAX(seq)` of the log, what every projection reflects.
    private var lastSeq: Int64
    /// True while `project_state` lags the in-memory state.
    private var stateDirty = false
    private var pendingFlush: Task<Void, Never>?
    public private(set) var isClosed = false
    /// What open found (integrity check, folded events, rebuilds).
    public nonisolated let recovery: RecoveryReport
    /// Non-fatal findings of the opener (synced location, and so on).
    public nonisolated let openWarnings: [String]

    // MARK: Construction

    /// Opens (migrating and recovering) the database at `path`. Use `SQLiteProjectStoreOpener` for
    /// packages; this is the raw form.
    public init(
        databaseAt path: String, url: URL? = nil, ids: any IDGenerator = UUIDv7Generator(),
        clock: any Clock = SystemClock(), options: Options = Options(), warnings: [String] = []
    ) throws {
        let config = Schema.configuration(journal: options.journal, label: "project:\(url?.lastPathComponent ?? path)")
        // A DELETE journal has no concurrent readers, so it is one connection (a pool's readers would
        // fight the writer over the journal mode).
        let writer: any DatabaseWriter =
            switch options.journal {
            case .wal: try DatabasePool(path: path, configuration: config)
            case .delete: try DatabaseQueue(path: path, configuration: config)
            }
        try self.init(writer: writer, url: url, ids: ids, clock: clock, options: options, warnings: warnings)
    }

    /// An in-memory store (a `DatabaseQueue` at `:memory:`): the same schema, write path, and projections,
    /// no file. Starts blank; `createProject` is its first command.
    public static func inMemory(
        ids: any IDGenerator = UUIDv7Generator(), clock: any Clock = SystemClock(), options: Options = Options()
    ) throws -> SQLiteProjectStore {
        let queue = try DatabaseQueue(
            path: ":memory:", configuration: Schema.configuration(journal: .wal, label: "memory"))
        return try SQLiteProjectStore(writer: queue, url: nil, ids: ids, clock: clock, options: options)
    }

    init(
        writer: any DatabaseWriter, url: URL?, ids: any IDGenerator, clock: any Clock, options: Options,
        warnings: [String] = []
    ) throws {
        let started = ContinuousClock.now
        self.writer = writer
        self.url = url
        self.ids = ids
        self.clock = MillisecondClock(clock)
        self.options = options
        try Recovery.migrate(writer, url: url)
        var loaded = try writer.write { db in
            try Recovery.open(db, url: url, retention: options.commandRetention, now: clock.now())
        }
        loaded.report.openMilliseconds = Self.milliseconds(since: started)
        project = loaded.state
        fold = loaded.history
        lastSeq = loaded.lastSeq
        recovery = loaded.report
        openWarnings = warnings
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    // MARK: ProjectStore

    public var projectId: ProjectID { project.id }

    public func state() -> Project { project }
    public func version() -> Int64 { project.version }
    public func history() -> History { fold }

    public nonisolated var changes: AsyncStream<ProjectChange> { broadcaster.subscribe() }

    public func apply(_ command: Command) throws(EditorError) -> CommandResult {
        if isClosed { throw .invalid(reason: "The store is closed") }
        let outcome: WritePath.Outcome
        do {
            let input = WritePath.Input(command: command, state: project, history: fold, ids: ids, clock: clock)
            outcome = try writer.write { db in try WritePath.apply(db, input) }
        } catch {
            throw .invalid(reason: "Storage error: \(error)")
        }
        switch outcome {
        case .replayed(let result):
            return result
        case .rejected(let error):
            throw error
        case .noop(let result):
            return result
        case .applied(let result, let state, let transaction, let seq):
            project = state
            fold.append(transaction)
            lastSeq = seq
            stateDirty = true
            scheduleFlush()
            broadcaster.send(ProjectChange(transaction: transaction, version: state.version))
            return result
        }
    }

    public func events(since version: Int64) throws -> [StoredEvent] {
        if isClosed { throw ProjectStoreError.closed }
        return try writer.read { db in try EventRows.fetch(db, since: version) }
    }

    public func changedSince(_ version: Int64) -> ChangedSince {
        let from = max(0, min(version, project.version))
        return ChangedSince.build(
            from: Array(fold.allEvents.dropFirst(Int(from))), fromVersion: from, labels: labels)
    }

    private var labels: [TransactionID: String] {
        Dictionary(uniqueKeysWithValues: fold.transactions.map { ($0.id, $0.label) })
    }

    /// Truncates every projection and folds the whole log again (storage.md section 12): `project_state`
    /// and the query tables are written from the final state, `history` per transaction. Labels are carried
    /// over from the `history` rows (falling back to the `commands` table, then to the default label).
    public func rebuildProjections() throws {
        if isClosed { throw ProjectStoreError.closed }
        pendingFlush?.cancel()
        pendingFlush = nil
        let rebuilt = try writer.write { db in
            let events = try EventRows.fetch(db, afterSeq: 0)
            return try Rebuild.run(db, events: events)
        }
        project = rebuilt.state
        fold = rebuilt.history
        lastSeq = rebuilt.lastSeq
        stateDirty = false
    }

    /// Checkpoints, writes the debounced state row, marks the session closed. The store is unusable after.
    public func close() throws {
        if isClosed { return }
        pendingFlush?.cancel()
        pendingFlush = nil
        let state = project
        let seq = lastSeq
        let dirty = stateDirty
        try writer.write { db in
            if dirty { try Projections.writeState(db, state, lastSeq: seq) }
            try Projections.setProjectionState(db, Schema.Projection.session, lastSeq: seq, note: "closed")
        }
        stateDirty = false
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA optimize")
            _ = try? db.checkpoint(.truncate)
        }
        isClosed = true
        finishStreams()
        try writer.close()
    }

    /// Ends the `changes` stream and every observation stream.
    private func finishStreams() {
        broadcaster.finish()
        let finishers = observers.withLock { s in
            let all = Array(s.values)
            s.removeAll()
            return all
        }
        for finish in finishers { finish() }
    }

    // MARK: State row

    /// Writes `project_state` now if it lags, cancelling the pending debounced write.
    public func flush() throws {
        pendingFlush?.cancel()
        pendingFlush = nil
        try writeStateIfDirty()
    }

    private func writeStateIfDirty() throws {
        guard stateDirty, !isClosed else { return }
        let state = project
        let seq = lastSeq
        try writer.write { db in try Projections.writeState(db, state, lastSeq: seq) }
        stateDirty = false
    }

    private func scheduleFlush() {
        pendingFlush?.cancel()
        let delay = options.stateWriteDebounce
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.debouncedFlush()
        }
    }

    private func debouncedFlush() {
        guard !isClosed else { return }
        try? writeStateIfDirty()
        // The idle moment: let SQLite fold the WAL and refresh its statistics (storage.md section 3).
        try? writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA optimize")
            _ = try? db.checkpoint(.passive)
        }
    }

    /// True while a debounced `project_state` write is pending (the row lags the state).
    public var isStateWritePending: Bool { stateDirty }

    // MARK: Import

    /// Appends an existing log (a fixture, a migration) as if each transaction had been applied here:
    /// events keep their ids and `txnId`, projections are maintained incrementally per transaction,
    /// no `commands` rows are written, one `ProjectChange` is published per transaction. The store
    /// must be at the version the events continue from (usually blank).
    @discardableResult
    public func importEvents(_ events: [DomainEvent], labels: [TransactionID: String] = [:]) throws
        -> [CommandResult]
    {
        if isClosed { throw ProjectStoreError.closed }
        guard !events.isEmpty else { return [] }
        let transactions = Transaction.group(events, labels: labels)
        let input = (state: project, history: fold)
        let imported = try writer.write { db in
            try WritePath.importTransactions(db, transactions, state: input.state, history: input.history)
        }
        project = imported.state
        fold = imported.history
        lastSeq = imported.lastSeq
        stateDirty = true
        scheduleFlush()
        for (t, r) in zip(transactions, imported.results) {
            broadcaster.send(ProjectChange(transaction: t, version: r.version))
        }
        return imported.results
    }

    // MARK: Maintenance

    /// Copies the database to `url` with `VACUUM INTO` (a temp file, then an atomic rename), never by
    /// copying the live file. The WAL is folded in first so the copy is complete.
    public func backup(to url: URL) throws {
        if isClosed { throw ProjectStoreError.closed }
        try writeStateIfDirty()
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).vacuum-\(UUID().uuidString)")
        try? fm.removeItem(at: temp)
        try writer.vacuum(into: temp.path)
        // The copy is complete and consistent: mark its session closed so opening it skips recovery.
        let copy = try DatabaseQueue(path: temp.path)
        try copy.write { db in
            try Projections.setProjectionState(db, Schema.Projection.session, lastSeq: lastSeq, note: "closed")
        }
        try copy.close()
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }

    /// Save As: a new `.tlproj` package at `packageURL` holding a `VACUUM INTO` copy of the database, a
    /// fresh manifest, and an empty `renders/` folder (exports are not copied). The current store keeps
    /// pointing at its own package; open the new one with the opener.
    public func saveAs(to packageURL: URL) throws {
        if isClosed { throw ProjectStoreError.closed }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: packageURL.path) else { throw ProjectStoreError.alreadyExists(packageURL) }
        let package = ProjectPackage(url: packageURL)
        try package.createDirectories()
        try backup(to: package.databaseURL)
        try package.writeManifest(ProjectManifest(projectId: project.id, libraryRootHint: nil, createdAt: clock.now()))
    }

    /// `PRAGMA integrity_check`; `ok` when the file is sound.
    public func integrityCheck() throws -> String {
        if isClosed { throw ProjectStoreError.closed }
        return try writer.read { db in try Recovery.integrityCheck(db) }
    }

    /// `wal_checkpoint(TRUNCATE)` now.
    public func checkpoint() throws {
        if isClosed { throw ProjectStoreError.closed }
        _ = try writer.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
    }

    /// Ends the session without flushing the state row or marking it closed: what a crash looks like.
    /// The next open runs the recovery path of storage.md section 12. For tests.
    func terminateAbruptly() throws {
        pendingFlush?.cancel()
        pendingFlush = nil
        isClosed = true
        finishStreams()
        try writer.close()
    }

    // MARK: Renders

    /// Records an export request in `renders` (storage.md section 5). Receipts live here, not in events, so
    /// a finished export never bumps the project version.
    @discardableResult
    public func recordRender(
        id: String? = nil, sequenceId: SequenceID, preset: ExportPreset, projectVersion: Int64? = nil,
        status: RenderRow.Status = .queued
    ) throws -> RenderRow {
        if isClosed { throw ProjectStoreError.closed }
        let row = RenderRow(
            renderId: id ?? ids.next(), requestedAt: Schema.timestamp(clock.now()), completedAt: nil,
            sequenceId: sequenceId.rawValue, preset: String(decoding: try ProjectCodec.encode(preset), as: UTF8.self),
            outputPath: nil, outputHash: nil, projectVersion: projectVersion ?? project.version, status: status,
            receipt: nil)
        try writer.write { db in try row.insert(db) }
        return row
    }

    /// Updates a render's status and, when it finished, its output and receipt. `completedAt` defaults to
    /// now for `done`, `failed`, and `cancelled`.
    @discardableResult
    public func updateRender(
        _ id: String, status: RenderRow.Status, outputPath: String? = nil, outputHash: String? = nil,
        receipt: ExportReceipt? = nil, completedAt: Date? = nil
    ) throws -> RenderRow {
        if isClosed { throw ProjectStoreError.closed }
        let receiptJSON = try receipt.map { String(decoding: try ProjectCodec.encode($0), as: UTF8.self) }
        let finished: Date? =
            completedAt ?? ([.done, .failed, .cancelled].contains(status) ? clock.now() : nil)
        return try writer.write { db in
            guard var row = try RenderRow.fetchOne(db, key: id) else {
                throw ProjectStoreError.storage("No render with id \(id)")
            }
            row.status = status
            if let outputPath { row.outputPath = outputPath }
            if let outputHash { row.outputHash = outputHash }
            if let receiptJSON { row.receipt = receiptJSON }
            if let finished { row.completedAt = Schema.timestamp(finished) }
            try row.update(db)
            return row
        }
    }

    /// Every render, newest first.
    public func renders() throws -> [RenderRow] {
        if isClosed { throw ProjectStoreError.closed }
        return try writer.read { db in
            try RenderRow.fetchAll(db, sql: "SELECT * FROM renders ORDER BY requested_at DESC, render_id DESC")
        }
    }

    public func render(_ id: String) throws -> RenderRow? {
        if isClosed { throw ProjectStoreError.closed }
        return try writer.read { db in try RenderRow.fetchOne(db, key: id) }
    }

    // MARK: Observation

    /// The `clips` rows of a sequence, re-delivered after every commit that changes them (GRDB
    /// `ValueObservation`). The first element is the current value.
    public nonisolated func observeClips(sequenceId: SequenceID) -> AsyncStream<[ClipRow]> {
        let id = sequenceId.rawValue
        return stream(
            ValueObservation.tracking { db in
                try ClipRow.fetchAll(
                    db, sql: "SELECT * FROM clips WHERE sequence_id = ? ORDER BY track_id, start_v, clip_id",
                    arguments: [id])
            })
    }

    /// The stored `project_state` document, re-delivered after every debounced or explicit write.
    public nonisolated func observeState() -> AsyncStream<Project> {
        stream(
            ValueObservation.tracking { db in try Projections.readState(db)?.state }
        ).compacted()
    }

    /// The stream version, re-delivered after every commit.
    public nonisolated func observeVersion() -> AsyncStream<Int64> {
        stream(ValueObservation.tracking { db in try EventRows.maxVersion(db) })
    }

    private nonisolated func stream<T: Sendable>(_ observation: ValueObservation<ValueReducers.Fetch<T>>)
        -> AsyncStream<T>
    {
        let writer = self.writer
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: writer) { continuation.yield(value) }
                } catch {}
                continuation.finish()
            }
            let id = UUID()
            self.observers.withLock { $0[id] = { continuation.finish() } }
            continuation.onTermination = { _ in
                task.cancel()
                self.observers.withLock { _ = $0.removeValue(forKey: id) }
            }
        }
    }
}

extension AsyncStream {
    fileprivate func compacted<T: Sendable>() -> AsyncStream<T> where Element == T? {
        AsyncStream<T> { continuation in
            let task = Task {
                for await value in self {
                    if let value { continuation.yield(value) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Rounds a clock to milliseconds so an event's `occurredAt` survives the ISO-8601 round trip unchanged.
struct MillisecondClock: Clock {
    let base: any Clock
    init(_ base: any Clock) { self.base = base }
    func now() -> Date {
        let ms = (base.now().timeIntervalSince1970 * 1000).rounded()
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

extension SQLiteProjectStore: ProjectStoreCopying {}
