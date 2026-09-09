import Foundation
import GRDB
import TimelineCore

/// The projections of storage.md section 5 and their maintenance (section 6 steps 7 and 8, section 12).
///
/// Rule that makes incremental and bulk writes agree: every query-table row is a pure function of the
/// entity in the state after the transaction, and the set of rows a transaction touches is a pure
/// function of its events. Tables hold live rows only.
enum Projections {
    // MARK: project_state

    static func writeState(_ db: Database, _ state: Project, lastSeq: Int64) throws {
        let json = String(decoding: try state.canonicalJSON(), as: UTF8.self)
        try db.cachedStatement(
            sql: """
                INSERT INTO project_state (id, version, last_seq, state) VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET version = excluded.version, last_seq = excluded.last_seq,
                  state = excluded.state
                """
        ).execute(arguments: [state.version, lastSeq, json])
        try setProjectionState(db, Schema.Projection.projectState, lastSeq: lastSeq)
    }

    /// The stored state row, if any: the project and the `seq` it reflects.
    static func readState(_ db: Database) throws -> (state: Project, lastSeq: Int64)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT state, last_seq FROM project_state WHERE id = 1") else {
            return nil
        }
        let text: String = row["state"]
        return (try Project.fromJSON(Data(text.utf8)), row["last_seq"])
    }

    static func setProjectionState(_ db: Database, _ name: String, lastSeq: Int64, note: String? = nil) throws {
        try db.cachedStatement(
            sql: """
                INSERT INTO projection_state (name, last_seq, note) VALUES (?, ?, ?)
                ON CONFLICT(name) DO UPDATE SET last_seq = excluded.last_seq, note = excluded.note
                """
        ).execute(arguments: [name, lastSeq, note])
    }

    static func projectionState(_ db: Database, _ name: String) throws -> (lastSeq: Int64, note: String?)? {
        guard
            let row = try Row.fetchOne(
                db, sql: "SELECT last_seq, note FROM projection_state WHERE name = ?", arguments: [name])
        else { return nil }
        return (row["last_seq"], row["note"])
    }

    // MARK: Touched rows

    /// The rows a transaction's events touch, per table. Ids not present in the final state are deleted,
    /// the rest upserted from the state. Track-structure events resync every track of their sequence
    /// because `position` is an index.
    struct Touched {
        var assets: Set<AssetID> = []
        var sequences: Set<SequenceID> = []
        var tracks: Set<TrackID> = []
        var trackSequences: Set<SequenceID> = []
        var clips: Set<ClipID> = []
        var transitions: Set<TransitionID> = []
        var markers: Set<MarkerID> = []

        init(_ events: [DomainEvent]) {
            for e in events { add(e.payload) }
        }

        mutating func add(_ p: EventPayload) {
            switch p {
            case .projectCreated(let x):
                sequences.insert(x.sequence.id)
            case .projectSettingsChanged, .projectRenamed, .activeSequenceChanged, .transactionUndone,
                .transactionRedone:
                break
            case .sequenceAdded(let x): sequences.insert(x.sequenceId)
            case .sequenceSettingsChanged(let x): sequences.insert(x.sequenceId)
            case .assetImported(let x): assets.insert(x.assetId)
            case .assetRelinked(let x): assets.insert(x.assetId)
            case .assetRemoved(let x): assets.insert(x.assetId)
            case .assetRestored(let x): assets.insert(x.assetId)
            case .assetAnalysisRecorded(let x): assets.insert(x.assetId)
            case .trackAdded(let x):
                tracks.insert(x.trackId)
                trackSequences.insert(x.sequenceId)
            case .trackRemoved(let x):
                tracks.insert(x.trackId)
                trackSequences.insert(x.sequenceId)
                clips.formUnion(x.snapshot.clips.keys)
            case .trackRestored(let x):
                tracks.insert(x.trackId)
                trackSequences.insert(x.sequenceId)
                clips.formUnion(x.snapshot.clips.keys)
            case .trackReordered(let x):
                tracks.insert(x.trackId)
                trackSequences.insert(x.sequenceId)
            case .trackRenamed(let x): tracks.insert(x.trackId)
            case .trackMuteSet(let x): tracks.insert(x.trackId)
            case .trackLockSet(let x): tracks.insert(x.trackId)
            case .clipAdded(let x): clips.insert(x.clipId)
            case .clipRemoved(let x): clips.insert(x.clipId)
            case .clipMoved(let x): clips.insert(x.clipId)
            case .clipTrimmed(let x): clips.insert(x.clipId)
            case .clipSplit(let x):
                clips.insert(x.clipId)
                clips.insert(x.newClipId)
            case .clipsJoined(let x):
                clips.insert(x.keptClipId)
                clips.insert(x.removedClipId)
            case .clipSpeedSet(let x): clips.insert(x.clipId)
            case .clipTransformSet(let x): clips.insert(x.clipId)
            case .clipOpacitySet(let x): clips.insert(x.clipId)
            case .clipAudioSet(let x): clips.insert(x.clipId)
            case .clipEffectAdded(let x): clips.insert(x.clipId)
            case .clipEffectChanged(let x): clips.insert(x.clipId)
            case .clipEffectRemoved(let x): clips.insert(x.clipId)
            case .clipsLinked(let x): clips.formUnion(x.clipIds)
            case .clipsUnlinked(let x): clips.formUnion(x.clipIds)
            case .transitionAdded(let x): transitions.insert(x.transitionId)
            case .transitionChanged(let x): transitions.insert(x.transitionId)
            case .transitionRemoved(let x): transitions.insert(x.transitionId)
            case .captionTrackAdded(let x):
                tracks.insert(x.trackId)
                trackSequences.insert(x.sequenceId)
            case .captionsReplaced(let x):
                clips.formUnion(x.before.map(\.id))
                clips.formUnion(x.after.map(\.id))
            case .captionEdited(let x): clips.insert(x.clipId)
            case .captionStyleSet(let x):
                if let c = x.clipId { clips.insert(c) } else { tracks.insert(x.trackId) }
            case .markerAdded(let x): markers.insert(x.markerId)
            case .markerMoved(let x): markers.insert(x.markerId)
            case .markerRemoved(let x): markers.insert(x.markerId)
            }
        }
    }

    // MARK: Incremental query tables

    /// Writes the rows `events` touch from `state` (the state after the transaction). Deletes run before
    /// upserts, children before parents, so foreign keys hold at every step.
    static func projectIncremental(_ db: Database, state: Project, events: [DomainEvent]) throws {
        let touched = Touched(events)
        let index = StateIndex(state)

        // Deletes: transitions, markers, clips, tracks, sequences, assets.
        for id in touched.transitions.sorted() where index.transitions[id] == nil {
            _ = try TransitionRow.deleteOne(db, key: id.rawValue)
        }
        for id in touched.markers.sorted() where index.markers[id] == nil {
            _ = try MarkerRow.deleteOne(db, key: id.rawValue)
        }
        for id in touched.clips.sorted() where index.clips[id] == nil {
            _ = try ClipRow.deleteOne(db, key: id.rawValue)
        }
        for id in touched.tracks.sorted() where index.tracks[id] == nil {
            _ = try TrackRow.deleteOne(db, key: id.rawValue)
        }
        for id in touched.sequences.sorted() where state.sequences[id] == nil {
            _ = try SequenceRow.deleteOne(db, key: id.rawValue)
        }
        for id in touched.assets.sorted() where state.assets[id] == nil {
            _ = try AssetRow.deleteOne(db, key: id.rawValue)
        }

        // Upserts: sequences, assets, tracks, clips, transitions, markers.
        for id in touched.sequences.sorted() {
            if let s = state.sequences[id] { try SequenceRow(s).upsert(db) }
        }
        for id in touched.assets.sorted() {
            if let a = state.assets[id] { try AssetRow(a).upsert(db) }
        }
        var trackIds = touched.tracks
        for sid in touched.trackSequences {
            if let s = state.sequences[sid] { trackIds.formUnion(s.tracks.map(\.id)) }
        }
        for id in trackIds.sorted() {
            if let (sid, position, track) = index.tracks[id] {
                try TrackRow(track, sequenceId: sid, position: position).upsert(db)
            }
        }
        for id in touched.clips.sorted() {
            if let (sid, clip) = index.clips[id] { try ClipRow(clip, sequenceId: sid).upsert(db) }
        }
        for id in touched.transitions.sorted() {
            if let (sid, t) = index.transitions[id] { try TransitionRow(t, sequenceId: sid).upsert(db) }
        }
        for id in touched.markers.sorted() {
            if let (sid, m) = index.markers[id] { try MarkerRow(m, sequenceId: sid).upsert(db) }
        }
    }

    /// Every entity of the state by id, with the sequence it belongs to.
    struct StateIndex {
        var tracks: [TrackID: (SequenceID, Int, Track)] = [:]
        var clips: [ClipID: (SequenceID, Clip)] = [:]
        var transitions: [TransitionID: (SequenceID, Transition)] = [:]
        var markers: [MarkerID: (SequenceID, Marker)] = [:]

        init(_ state: Project) {
            for s in state.sequences.values {
                for (i, t) in s.tracks.enumerated() {
                    tracks[t.id] = (s.id, i, t)
                    for c in t.clips.values { clips[c.id] = (s.id, c) }
                }
                for t in s.transitions.values { transitions[t.id] = (s.id, t) }
                for m in s.markers.values { markers[m.id] = (s.id, m) }
            }
        }
    }

    // MARK: Bulk query tables

    /// Truncates the query tables and writes every row from `state`.
    static func projectBulk(_ db: Database, state: Project) throws {
        for table in Schema.queryTablesInDeleteOrder { try db.execute(sql: "DELETE FROM \(table)") }
        for id in state.sequences.keys.sorted() { try SequenceRow(state.sequences[id]!).upsert(db) }
        for id in state.assets.keys.sorted() { try AssetRow(state.assets[id]!).upsert(db) }
        let index = StateIndex(state)
        for id in index.tracks.keys.sorted() {
            let (sid, position, track) = index.tracks[id]!
            try TrackRow(track, sequenceId: sid, position: position).upsert(db)
        }
        for id in index.clips.keys.sorted() {
            let (sid, clip) = index.clips[id]!
            try ClipRow(clip, sequenceId: sid).upsert(db)
        }
        for id in index.transitions.keys.sorted() {
            let (sid, t) = index.transitions[id]!
            try TransitionRow(t, sequenceId: sid).upsert(db)
        }
        for id in index.markers.keys.sorted() {
            let (sid, m) = index.markers[id]!
            try MarkerRow(m, sequenceId: sid).upsert(db)
        }
    }

    // MARK: History

    /// Inserts the row for `transaction` and recomputes `live` of the transaction it targets from `fold`.
    static func projectHistory(
        _ db: Database, transaction: Transaction, firstSeq: Int64, lastSeq: Int64, fold: History
    ) throws {
        try HistoryRow(
            txnId: transaction.id.rawValue, firstSeq: firstSeq, lastSeq: lastSeq, actor: transaction.actor.description,
            label: transaction.label, kind: transaction.kind.rawValue, targetTxn: transaction.target?.rawValue,
            live: transaction.kind == .edit ? fold.isLive(transaction.id) : true
        ).insert(db)
        if let target = transaction.target {
            try db.cachedStatement(sql: "UPDATE history SET live = ? WHERE txn_id = ?")
                .execute(arguments: [fold.isLive(target), target.rawValue])
        }
    }

    /// The labels stored in `history`, keyed by transaction; what rebuild carries across a truncation.
    static func historyLabels(_ db: Database) throws -> [TransactionID: String] {
        var labels: [TransactionID: String] = [:]
        let cursor = try Row.fetchCursor(db, sql: "SELECT txn_id, label FROM history")
        while let row = try cursor.next() { labels[TransactionID(row["txn_id"])] = row["label"] }
        return labels
    }

    /// Labels recoverable from the `commands` table (`args` holds the command, whose `label` is optional).
    static func commandLabels(_ db: Database) throws -> [CommandID: String] {
        var labels: [CommandID: String] = [:]
        let cursor = try Row.fetchCursor(db, sql: "SELECT command_id, args FROM commands WHERE status = 'applied'")
        while let row = try cursor.next() {
            let args: String = row["args"]
            if let command = try? ProjectCodec.decode(Command.self, from: Data(args.utf8)) {
                labels[CommandID(row["command_id"])] = command.effectiveLabel
            }
        }
        return labels
    }
}
