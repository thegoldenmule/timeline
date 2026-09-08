// Store: schema (sections 3 to 5), write path (section 6), undo (section 9), rebuild (section 12).
import Foundation
import GRDB
import UUIDV7
import Synchronization

func uuidv7() -> String { UUIDV7().uuidString.lowercased() }
func isoNow() -> String { Date().formatted(.iso8601.year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: true)) }

struct CommandResult: Codable, Sendable, Equatable {
    var txnId: String?
    var firstSeq: Int64?
    var lastSeq: Int64?
    var version: Int64
    var changedIds: [String]
    var status: String                // 'applied' | 'rejected' | 'noop'
    var replayed = false              // true when returned from the idempotency cache
}

enum StoreError: Error {
    case versionConflict(expected: Int64, current: Int64)
}

final class ProjectStore: Sendable {
    let pool: DatabasePool
    let path: String
    /// Section 6 step 2: the Project is "already in memory while open". Loaded once, replaced after each commit.
    private let cache = Mutex<Project?>(nil)

    init(path: String) throws {
        self.path = path
        var config = Configuration()
        config.foreignKeysEnabled = true                   // PRAGMA foreign_keys=ON (GRDB default, made explicit)
        config.busyMode = .timeout(5)                      // PRAGMA busy_timeout=5000
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous=NORMAL") }
        pool = try DatabasePool(path: path, configuration: config)   // DatabasePool implies journal_mode=WAL
        try Self.migrator.migrate(pool)
        try pool.write { db in
            if try Row.fetchOne(db, sql: "SELECT 1 FROM project_state WHERE id = 1") == nil {
                try Self.writeState(db, Project(), lastSeq: 0)
            }
        }
    }

    static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE events (
              seq            INTEGER PRIMARY KEY,
              event_id       TEXT    NOT NULL UNIQUE,
              stream_id      TEXT    NOT NULL,
              stream_version INTEGER NOT NULL,
              type           TEXT    NOT NULL,
              schema_version INTEGER NOT NULL DEFAULT 1,
              payload        TEXT    NOT NULL,
              occurred_at    TEXT    NOT NULL,
              actor          TEXT    NOT NULL,
              txn_id         TEXT    NOT NULL,
              command_id     TEXT    NOT NULL,
              causation_id   TEXT,
              metadata       TEXT,
              clip_id        TEXT AS (json_extract(payload, '$.clipId')) VIRTUAL,
              UNIQUE (stream_id, stream_version)
            ) STRICT;
            CREATE INDEX events_clip_idx ON events(clip_id) WHERE clip_id IS NOT NULL;
            CREATE INDEX events_type_idx ON events(type);
            CREATE INDEX events_txn_idx  ON events(txn_id);
            CREATE TABLE commands (
              command_id TEXT PRIMARY KEY, received_at TEXT NOT NULL, actor TEXT NOT NULL,
              name TEXT NOT NULL, args TEXT NOT NULL, result TEXT NOT NULL,
              status TEXT NOT NULL CHECK (status IN ('applied','rejected','noop'))
            ) STRICT;
            CREATE TABLE project_state (
              id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL,
              last_seq INTEGER NOT NULL, state TEXT NOT NULL
            ) STRICT;
            CREATE TABLE clips (
              clip_id TEXT PRIMARY KEY, track_id TEXT NOT NULL, asset_id TEXT,
              start_v INTEGER NOT NULL, start_ts INTEGER NOT NULL,
              in_v INTEGER NOT NULL, in_ts INTEGER NOT NULL,
              out_v INTEGER NOT NULL, out_ts INTEGER NOT NULL,
              removed INTEGER NOT NULL DEFAULT 0
            ) STRICT;
            CREATE INDEX clips_track_start_idx ON clips(track_id, start_v) WHERE removed = 0;
            CREATE TABLE history (
              txn_id TEXT PRIMARY KEY, first_seq INTEGER NOT NULL, last_seq INTEGER NOT NULL,
              actor TEXT NOT NULL, label TEXT NOT NULL,
              undone_by TEXT REFERENCES history(txn_id), undoes TEXT REFERENCES history(txn_id)
            ) STRICT;
            CREATE TABLE projection_state (name TEXT PRIMARY KEY, last_seq INTEGER NOT NULL) STRICT;
            """)
        }
        return m
    }()

    // MARK: - Write path (section 6)

    func apply(_ command: Command, expectedVersion: Int64, commandId: String, actor: String) throws -> CommandResult {
        let cached = cache.withLock { $0 }
        let (result, newState): (CommandResult, Project?) = try pool.write { db in
            // 1. idempotent retry
            if let stored = try String.fetchOne(db, sql: "SELECT result FROM commands WHERE command_id = ?", arguments: [commandId]) {
                var r = try JSONDecoder().decode(CommandResult.self, from: Data(stored.utf8)); r.replayed = true; return (r, nil)
            }
            // 2. load state (from memory if we have it)
            var state = try cached ?? Self.loadState(db).0
            // 3. optimistic concurrency
            if expectedVersion != state.version {
                let r = CommandResult(version: state.version, changedIds: [], status: "rejected")
                try Self.insertCommand(db, commandId, actor, command, r)
                return (r, nil)
            }
            // 4/5. validate + decide (pure)
            var undoTarget: [Event]? = nil
            if case .undo(let txnId) = command {
                guard let row = try Row.fetchOne(db, sql: "SELECT undone_by FROM history WHERE txn_id = ?", arguments: [txnId])
                else { throw CoreError.noSuchTxn(txnId) }
                if let by: String = row["undone_by"] { throw CoreError.alreadyUndone("\(txnId) already undone by \(by)") }
                undoTarget = try Row.fetchAll(db, sql: "SELECT type, payload FROM events WHERE txn_id = ? ORDER BY seq", arguments: [txnId])
                    .map { try Event.decode(type: $0["type"], payload: $0["payload"]) }
            }
            let events = try decide(state, command, undoTarget: undoTarget)
            if events.isEmpty {
                let r = CommandResult(version: state.version, changedIds: [], status: "noop")
                try Self.insertCommand(db, commandId, actor, command, r)
                return (r, nil)
            }
            // 6. append events; 7. fold; 8. projections; 9. commands row
            let txnId = uuidv7()
            let seqs = try Self.append(db, events, fromVersion: state.version, txnId: txnId, commandId: commandId, actor: actor)
            for e in events { evolve(&state, e) }
            state.version += Int64(events.count)
            try Self.writeState(db, state, lastSeq: seqs.last!)
            let changed = Self.projectClips(db, state, events)
            try Self.projectHistory(db, txnId: txnId, events: events, seqs: seqs, actor: actor)
            let r = CommandResult(txnId: txnId, firstSeq: seqs.first, lastSeq: seqs.last, version: state.version, changedIds: changed, status: "applied")
            try Self.insertCommand(db, commandId, actor, command, r)
            return (r, state)
        }
        if let s = newState { cache.withLock { $0 = s } }   // only after commit
        return result
    }

    /// Simulates a racing writer that read the same version: inserts at `fromVersion + 1` regardless of current state.
    func forceConflictingAppend(fromVersion: Int64) throws {
        try pool.write { db in
            _ = try Self.append(db, [.transactionUndone(.init(targetTxnId: "race"))], fromVersion: fromVersion,
                                txnId: uuidv7(), commandId: uuidv7(), actor: "test")
        }
    }

    static func append(_ db: Database, _ events: [Event], fromVersion: Int64, txnId: String, commandId: String, actor: String) throws -> [Int64] {
        let stmt = try db.cachedStatement(sql: """
            INSERT INTO events (event_id, stream_id, stream_version, type, schema_version, payload, occurred_at, actor, txn_id, command_id)
            VALUES (?, 'project', ?, ?, 1, ?, ?, ?, ?, ?) RETURNING seq
            """)
        let now = isoNow()
        return try events.enumerated().map { i, e in
            try Int64.fetchOne(stmt, arguments: [uuidv7(), fromVersion + Int64(i) + 1, e.type, e.payloadJSON(), now, actor, txnId, commandId])!
        }
    }

    static func loadState(_ db: Database) throws -> (Project, Int64) {
        let row = try Row.fetchOne(db, sql: "SELECT state, last_seq FROM project_state WHERE id = 1")!
        return (try JSONDecoder().decode(Project.self, from: Data((row["state"] as String).utf8)), row["last_seq"])
    }

    static func writeState(_ db: Database, _ state: Project, lastSeq: Int64) throws {
        try db.execute(sql: """
            INSERT INTO project_state (id, version, last_seq, state) VALUES (1, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET version = excluded.version, last_seq = excluded.last_seq, state = excluded.state
            """, arguments: [state.version, lastSeq, try canonicalJSON(state)])
        try db.execute(sql: "INSERT INTO projection_state (name, last_seq) VALUES ('project_state', ?), ('clips', ?), ('history', ?) ON CONFLICT(name) DO UPDATE SET last_seq = excluded.last_seq",
                       arguments: [lastSeq, lastSeq, lastSeq])
    }

    /// Query-table projection derived from the folded state: upsert changed clips, soft-delete missing ones.
    @discardableResult
    static func projectClips(_ db: Database, _ state: Project, _ events: [Event]) -> [String] {
        let ids = Array(Set(events.compactMap(\.clipId))).sorted()
        for id in ids {
            if let c = state.clips[id] {
                try? db.cachedStatement(sql: """
                    INSERT INTO clips (clip_id, track_id, asset_id, start_v, start_ts, in_v, in_ts, out_v, out_ts, removed)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                    ON CONFLICT(clip_id) DO UPDATE SET track_id = excluded.track_id, asset_id = excluded.asset_id,
                      start_v = excluded.start_v, start_ts = excluded.start_ts, in_v = excluded.in_v, in_ts = excluded.in_ts,
                      out_v = excluded.out_v, out_ts = excluded.out_ts, removed = 0
                    """).execute(arguments: [c.clipId, c.trackId, c.assetId, c.start.v, c.start.ts, c.in.v, c.in.ts, c.out.v, c.out.ts])
            } else {
                try? db.cachedStatement(sql: "UPDATE clips SET removed = 1 WHERE clip_id = ?").execute(arguments: [id])
            }
        }
        return ids
    }

    static func projectHistory(_ db: Database, txnId: String, events: [Event], seqs: [Int64], actor: String) throws {
        var undoes: String? = nil
        if case .transactionUndone(let p) = events[0] { undoes = p.targetTxnId }
        try db.cachedStatement(sql: "INSERT INTO history (txn_id, first_seq, last_seq, actor, label, undoes) VALUES (?, ?, ?, ?, ?, ?)")
            .execute(arguments: [txnId, seqs.first!, seqs.last!, actor, events[0].type, undoes])
        if let t = undoes { try db.execute(sql: "UPDATE history SET undone_by = ? WHERE txn_id = ?", arguments: [txnId, t]) }
    }

    static func insertCommand(_ db: Database, _ id: String, _ actor: String, _ c: Command, _ r: CommandResult) throws {
        try db.cachedStatement(sql: "INSERT INTO commands (command_id, received_at, actor, name, args, result, status) VALUES (?, ?, ?, ?, ?, ?, ?)")
            .execute(arguments: [id, isoNow(), actor, c.name, c.args, try canonicalJSON(r), r.status])
    }

    // MARK: - Rebuild (section 12)

    struct RebuildReport { var stateEqual: Bool; var clipsEqual: Bool; var historyEqual: Bool; var events: Int; var seconds: Double }

    func rebuildProjections() throws -> RebuildReport {
        try pool.write { db in
            let before = try String.fetchOne(db, sql: "SELECT state FROM project_state WHERE id = 1")!
            let clipsBefore = try Row.fetchAll(db, sql: "SELECT * FROM clips ORDER BY clip_id")
            let histBefore = try Row.fetchAll(db, sql: "SELECT * FROM history ORDER BY first_seq")
            let t0 = ContinuousClock.now
            try db.execute(sql: "DELETE FROM project_state; DELETE FROM clips; DELETE FROM history; DELETE FROM projection_state")
            var state = Project(), lastSeq: Int64 = 0, n = 0
            var txn: (id: String, actor: String, events: [Event], seqs: [Int64])? = nil
            func flush() throws {
                guard let t = txn else { return }
                try Self.projectHistory(db, txnId: t.id, events: t.events, seqs: t.seqs, actor: t.actor)
                Self.projectClips(db, state, t.events)
            }
            let cursor = try Row.fetchCursor(db, sql: "SELECT seq, stream_version, type, payload, txn_id, actor FROM events ORDER BY seq")
            while let row = try cursor.next() {
                let e = try Event.decode(type: row["type"], payload: row["payload"])
                let txnId: String = row["txn_id"]
                if txn?.id != txnId { try flush(); txn = (txnId, row["actor"], [], []) }
                txn!.events.append(e); txn!.seqs.append(row["seq"])
                evolve(&state, e); state.version = row["stream_version"]; lastSeq = row["seq"]; n += 1
            }
            try flush()
            try Self.writeState(db, state, lastSeq: lastSeq)
            let secs = Double((ContinuousClock.now - t0).components.attoseconds) / 1e18 + Double((ContinuousClock.now - t0).components.seconds)
            let after = try String.fetchOne(db, sql: "SELECT state FROM project_state WHERE id = 1")!
            let clipsAfter = try Row.fetchAll(db, sql: "SELECT * FROM clips ORDER BY clip_id")
            let histAfter = try Row.fetchAll(db, sql: "SELECT * FROM history ORDER BY first_seq")
            cache.withLock { $0 = state }
            return RebuildReport(stateEqual: before == after, clipsEqual: clipsBefore == clipsAfter, historyEqual: histBefore == histAfter, events: n, seconds: secs)
        }
    }

    func currentState() throws -> Project { try pool.read { try Self.loadState($0).0 } }

    /// Design: wal_checkpoint(TRUNCATE) + PRAGMA optimize on close.
    func close() throws {
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA optimize")
            try db.checkpoint(.truncate)
        }
        try pool.close()
    }
}
