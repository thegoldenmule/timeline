import Contracts
import Foundation
import GRDB
import TimelineCore

/// The write path of storage.md section 6, run inside one `DatabaseWriter.write` transaction. Pure
/// with respect to the actor: it takes the current state and history as values and returns what the
/// actor should adopt once the transaction has committed.
enum WritePath {
    struct Input {
        var command: Command
        var state: Project
        var history: History
        var ids: any IDGenerator
        var clock: any Clock
    }

    enum Outcome {
        /// A stored result for a duplicate `commandId`.
        case replayed(CommandResult)
        /// A rejection, freshly decided or stored.
        case rejected(EditorError)
        /// Valid, changed nothing.
        case noop(CommandResult)
        /// Events were appended: the result, the new state, the transaction, and `MAX(seq)`.
        case applied(CommandResult, Project, Transaction, Int64)
    }

    static func apply(_ db: Database, _ input: Input) throws -> Outcome {
        let command = input.command
        let receivedAt = Schema.timestamp(input.clock.now())

        // 1. Idempotent retry, before the version check.
        if let stored = try storedOutcome(db, command.commandId) { return stored }

        // 2 to 5. `$ref` resolution, the version check, decide, and the invariants are TimelineCore's.
        let events: [DomainEvent]
        do {
            events = try decide(input.state, command, ids: input.ids, clock: input.clock, history: input.history)
        } catch {
            var error = error
            if case .staleVersion(let current, _) = error, let expected = command.expectedVersion {
                // Fill the diff from the log with the stored labels (decide's copy has default labels only).
                let from = max(0, min(expected, current))
                let labels = Dictionary(uniqueKeysWithValues: input.history.transactions.map { ($0.id, $0.label) })
                let changed = ChangedSince.build(
                    from: Array(input.history.allEvents.dropFirst(Int(from))), fromVersion: from, labels: labels)
                error = .staleVersion(current: current, changedSince: changed)
            }
            try recordRejection(db, command, error, receivedAt: receivedAt)
            return .rejected(error)
        }

        guard !events.isEmpty else {
            let result = CommandResult(commandId: command.commandId, status: .noop, version: input.state.version)
            try recordResult(db, command, result, status: "noop", receivedAt: receivedAt)
            return .noop(result)
        }

        // 5. The store's own invariant check, a second line of defence behind decide's.
        var state = input.state
        evolve(&state, events)
        do {
            try Invariants.check(state)
        } catch {
            try recordRejection(db, command, error, receivedAt: receivedAt)
            return .rejected(error)
        }

        // 6 to 9. Append, project, record.
        let transaction = Transaction(events: events, label: command.effectiveLabel)
        let (result, lastSeq) = try appendTransaction(
            db, transaction, fromVersion: input.state.version, state: state, history: input.history)
        try recordResult(db, command, result, status: "applied", receivedAt: receivedAt)
        return .applied(result, state, transaction, lastSeq)
    }

    /// Appends one transaction's events and maintains the query tables and history from them.
    static func appendTransaction(
        _ db: Database, _ transaction: Transaction, fromVersion: Int64, state: Project, history: History
    ) throws -> (CommandResult, Int64) {
        let seqs = try EventRows.append(db, transaction.events, fromVersion: fromVersion)
        guard let first = seqs.first, let last = seqs.last else {
            throw ProjectStoreError.storage("append returned no rows")
        }
        try Projections.projectIncremental(db, state: state, events: transaction.events)
        try Projections.projectHistory(
            db, transaction: transaction, firstSeq: first, lastSeq: last, fold: history.appending(transaction))
        try Projections.setProjectionState(db, Schema.Projection.queryTables, lastSeq: last)
        try Projections.setProjectionState(db, Schema.Projection.history, lastSeq: last)
        let result = CommandResult(
            commandId: transaction.events[0].commandId, txnId: transaction.id, status: .applied,
            version: state.version, firstSeq: first, lastSeq: last, changedIds: changedIds(of: transaction.events))
        return (result, last)
    }

    /// Appends already-decided transactions (an imported log).
    static func importTransactions(
        _ db: Database, _ transactions: [Transaction], state: Project, history: History
    ) throws -> (state: Project, history: History, lastSeq: Int64, results: [CommandResult]) {
        var state = state
        var history = history
        var lastSeq = try EventRows.maxSeq(db)
        var results: [CommandResult] = []
        for t in transactions {
            let from = state.version
            evolve(&state, t.events)
            let (result, seq) = try appendTransaction(db, t, fromVersion: from, state: state, history: history)
            history.append(t)
            lastSeq = seq
            results.append(result)
        }
        return (state, history, lastSeq, results)
    }

    // MARK: commands table

    private struct StoredCommand: FetchableRecord {
        var status: String
        var result: String
        init(row: Row) {
            status = row["status"]
            result = row["result"]
        }
    }

    static func storedOutcome(_ db: Database, _ id: CommandID) throws -> Outcome? {
        guard
            let stored = try StoredCommand.fetchOne(
                db, sql: "SELECT status, result FROM commands WHERE command_id = ?", arguments: [id.rawValue])
        else { return nil }
        let data = Data(stored.result.utf8)
        switch stored.status {
        case "applied", "noop":
            return .replayed(try ProjectCodec.decode(CommandResult.self, from: data).replayed)
        default:
            return .rejected(try ProjectCodec.decode(EditorError.self, from: data))
        }
    }

    static func recordResult(
        _ db: Database, _ command: Command, _ result: CommandResult, status: String, receivedAt: String
    )
        throws
    {
        try insertCommand(
            db, command, resultJSON: try ProjectCodec.encode(result), status: status, receivedAt: receivedAt)
    }

    static func recordRejection(_ db: Database, _ command: Command, _ error: EditorError, receivedAt: String) throws {
        let status = if case .staleVersion = error { "stale" } else { "invalid" }
        try insertCommand(
            db, command, resultJSON: try ProjectCodec.encode(error), status: status, receivedAt: receivedAt)
    }

    private static func insertCommand(
        _ db: Database, _ command: Command, resultJSON: Data, status: String, receivedAt: String
    ) throws {
        try db.cachedStatement(
            sql: """
                INSERT INTO commands (command_id, received_at, actor, name, args, result, status)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
        ).execute(arguments: [
            command.commandId.rawValue, receivedAt, command.actor.description, command.operation.typeName,
            String(decoding: try ProjectCodec.encode(command), as: UTF8.self),
            String(decoding: resultJSON, as: UTF8.self), status,
        ])
    }
}

/// storage.md section 12: truncate every projection and fold the log again.
enum Rebuild {
    struct Result {
        var state: Project
        var history: History
        var lastSeq: Int64
    }

    /// Rebuilds from `events` (the whole log in `seq` order). Query tables are bulk-written from the
    /// final state; `history` is derived per transaction; `project_state` is written once at the end.
    static func run(_ db: Database, events: [StoredEvent]) throws -> Result {
        let storedLabels = try Projections.historyLabels(db)
        let commandLabels = storedLabels.isEmpty ? try Projections.commandLabels(db) : [:]

        try db.execute(sql: "DELETE FROM project_state")
        try db.execute(sql: "DELETE FROM history")
        for table in Schema.queryTablesInDeleteOrder { try db.execute(sql: "DELETE FROM \(table)") }
        try db.execute(
            sql: "DELETE FROM projection_state WHERE name IN (?, ?, ?)",
            arguments: [Schema.Projection.projectState, Schema.Projection.queryTables, Schema.Projection.history])

        var state = Project.blank
        var history = History()
        var lastSeq: Int64 = 0
        var run: [StoredEvent] = []

        func flush() throws {
            guard let first = run.first, let last = run.last else { return }
            let events = run.map(\.event)
            let label = storedLabels[first.event.txnId] ?? commandLabels[first.event.commandId]
            let transaction = Transaction(events: events, label: label)
            history.append(transaction)
            try Projections.projectHistory(
                db, transaction: transaction, firstSeq: first.seq, lastSeq: last.seq, fold: history)
            run.removeAll(keepingCapacity: true)
        }

        for stored in events {
            if let last = run.last, last.event.txnId != stored.event.txnId { try flush() }
            run.append(stored)
            evolve(&state, stored.event)
            state.version = stored.streamVersion
            lastSeq = stored.seq
        }
        try flush()

        try Projections.projectBulk(db, state: state)
        try Projections.writeState(db, state, lastSeq: lastSeq)
        try Projections.setProjectionState(db, Schema.Projection.queryTables, lastSeq: lastSeq)
        try Projections.setProjectionState(db, Schema.Projection.history, lastSeq: lastSeq)
        return Result(state: state, history: history, lastSeq: lastSeq)
    }
}

/// The open path: migrate, then the checks of storage.md section 12.
enum Recovery {
    struct Loaded {
        var state: Project
        var history: History
        var lastSeq: Int64
        var report: SQLiteProjectStore.RecoveryReport
    }

    /// Runs the migrator; an existing, unmigrated database is backed up with `VACUUM INTO` first.
    static func migrate(_ writer: any DatabaseWriter, url: URL?) throws {
        let needsBackup = try writer.read { db in
            try db.tableExists("events") && !Schema.migrator.hasCompletedMigrations(db)
        }
        if needsBackup, let url {
            let package = ProjectPackage(url: url)
            let stamp = Schema.timestamp(Date()).replacingOccurrences(of: ":", with: "-")
            try writer.vacuum(into: package.databaseURL.appendingPathExtension("pre-migration-\(stamp).bak").path)
        }
        try Schema.migrator.migrate(writer)
    }

    static func integrityCheck(_ db: Database) throws -> String {
        let rows = try String.fetchAll(db, sql: "PRAGMA integrity_check")
        return rows.joined(separator: "\n")
    }

    static func open(_ db: Database, url: URL?, retention: TimeInterval, now: Date) throws -> Loaded {
        var report = SQLiteProjectStore.RecoveryReport()

        // Unclean shutdown: check the file before trusting it.
        let session = try Projections.projectionState(db, Schema.Projection.session)
        if session?.note == "open" {
            report.uncleanShutdown = true
            report.integrityChecked = true
            let verdict = try integrityCheck(db)
            guard verdict == "ok" else { throw ProjectStoreError.corrupt(url, verdict) }
        }

        // The whole log is needed for the in-memory history; the state folds from its stored row.
        let maxSeq = try EventRows.maxSeq(db)
        let all = try EventRows.fetch(db, afterSeq: 0)
        let labels = try Projections.historyLabels(db)
        var history = History.fold(events: all.map(\.event), labels: labels)

        var state: Project
        var lastSeq: Int64
        if let stored = try Projections.readState(db), stored.lastSeq <= maxSeq {
            state = stored.state
            lastSeq = stored.lastSeq
        } else {
            state = .blank
            lastSeq = 0
        }
        let tail = all.filter { $0.seq > lastSeq }
        if !tail.isEmpty {
            for e in tail {
                evolve(&state, e.event)
                state.version = e.streamVersion
            }
            lastSeq = maxSeq
            report.stateEventsFolded = tail.count
            try Projections.writeState(db, state, lastSeq: lastSeq)
        }

        // Projections that lag the log are rebuilt; so is a state whose version disagrees with the log.
        let queryTables = try Projections.projectionState(db, Schema.Projection.queryTables)?.lastSeq ?? 0
        let historySeq = try Projections.projectionState(db, Schema.Projection.history)?.lastSeq ?? 0
        let expectedVersion = try EventRows.maxVersion(db)
        if maxSeq > 0, queryTables != maxSeq || historySeq != maxSeq || state.version != expectedVersion {
            let rebuilt = try Rebuild.run(db, events: all)
            state = rebuilt.state
            history = rebuilt.history
            lastSeq = rebuilt.lastSeq
            report.projectionsRebuilt = true
        }

        try Projections.setProjectionState(db, Schema.Projection.session, lastSeq: maxSeq, note: "open")

        // Idempotency needs only a short window (storage.md section 6).
        let cutoff = Schema.timestamp(now.addingTimeInterval(-retention))
        try db.execute(sql: "DELETE FROM commands WHERE received_at < ?", arguments: [cutoff])
        report.commandsPruned = db.changesCount

        return Loaded(state: state, history: history, lastSeq: lastSeq, report: report)
    }
}
