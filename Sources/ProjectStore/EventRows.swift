import Contracts
import Foundation
import GRDB
import TimelineCore

/// Reading and writing `events` rows (storage.md section 4).
enum EventRows {
    static let selectColumns = """
        seq, event_id, stream_version, type, schema_version, payload, occurred_at, actor, txn_id, command_id,
        causation_id, metadata
        """

    /// Appends `events` at `stream_version = fromVersion + 1...` under their own `txn_id`, returning the
    /// `seq` of every row. A conflicting `stream_version` raises `SQLITE_CONSTRAINT_UNIQUE` and rolls the
    /// enclosing transaction back.
    static func append(_ db: Database, _ events: [DomainEvent], fromVersion: Int64) throws -> [Int64] {
        let statement = try db.cachedStatement(
            sql: """
                INSERT INTO events (event_id, stream_id, stream_version, type, schema_version, payload, occurred_at,
                  actor, txn_id, command_id, causation_id, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING seq
                """)
        var seqs: [Int64] = []
        seqs.reserveCapacity(events.count)
        for (i, e) in events.enumerated() {
            let payload = String(decoding: try e.payload.fieldsJSON(), as: UTF8.self)
            let metadata = try e.metadata.map { String(decoding: try ProjectCodec.encode($0), as: UTF8.self) }
            let arguments: StatementArguments = [
                e.eventId.rawValue, Schema.streamId, fromVersion + Int64(i) + 1, e.type, e.schemaVersion, payload,
                Schema.timestamp(e.occurredAt), e.actor.description, e.txnId.rawValue, e.commandId.rawValue,
                e.causationId?.rawValue, metadata,
            ]
            guard let seq = try Int64.fetchOne(statement, arguments: arguments) else {
                throw ProjectStoreError.storage("INSERT ... RETURNING seq returned nothing")
            }
            seqs.append(seq)
        }
        return seqs
    }

    /// Decodes one `events` row. Rows at the current schema take a single-pass decode; older rows (or
    /// embedded snapshots at an older clip schema) go through `Upcaster`.
    static func stored(_ row: Row) throws -> StoredEvent {
        let type: String = row["type"]
        let schemaVersion: Int = row["schema_version"]
        let payloadText: String = row["payload"]
        let payload = try decodePayload(type: type, schemaVersion: schemaVersion, fields: payloadText)
        let actorText: String = row["actor"]
        let metadataText: String? = row["metadata"]
        let metadata = try metadataText.map {
            try ProjectCodec.decode([String: JSONValue].self, from: Data($0.utf8))
        }
        let event = DomainEvent(
            eventId: EventID(row["event_id"]), txnId: TransactionID(row["txn_id"]),
            commandId: CommandID(row["command_id"]), actor: Actor(actorText) ?? .system,
            occurredAt: try Schema.date(row["occurred_at"]), schemaVersion: Upcaster.currentSchemaVersion,
            causationId: (row["causation_id"] as String?).map { EventID($0) }, metadata: metadata, payload: payload)
        return StoredEvent(seq: row["seq"], streamVersion: row["stream_version"], event: event)
    }

    static func decodePayload(type: String, schemaVersion: Int, fields: String) throws -> EventPayload {
        if schemaVersion == Upcaster.currentSchemaVersion, let fast = try? fastDecode(type: type, fields: fields),
            (fast.embeddedClipSchema ?? Upcaster.currentClipSchema) >= Upcaster.currentClipSchema
        {
            return fast
        }
        return try EventPayload.decode(type: type, schemaVersion: schemaVersion, fieldsJSON: Data(fields.utf8))
    }

    /// Splices `"type"` into the stored fields object so `EventPayload`'s own decoder can dispatch in one pass.
    private static func fastDecode(type: String, fields: String) throws -> EventPayload {
        let body = fields.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("{"), body.hasSuffix("}") else {
            throw ProjectStoreError.storage("payload is not a JSON object")
        }
        let inner = body.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        let text = inner.isEmpty ? "{\"type\":\"\(type)\"}" : "{\"type\":\"\(type)\",\(inner)}"
        return try ProjectCodec.decode(EventPayload.self, from: Data(text.utf8))
    }

    /// Every stored event with `stream_version > since`, in `seq` order.
    static func fetch(_ db: Database, since version: Int64) throws -> [StoredEvent] {
        let cursor = try Row.fetchCursor(
            db, sql: "SELECT \(selectColumns) FROM events WHERE stream_version > ? ORDER BY seq", arguments: [version])
        var result: [StoredEvent] = []
        while let row = try cursor.next() { result.append(try stored(row)) }
        return result
    }

    /// Every stored event with `seq > seq`, in `seq` order.
    static func fetch(_ db: Database, afterSeq seq: Int64) throws -> [StoredEvent] {
        let cursor = try Row.fetchCursor(
            db, sql: "SELECT \(selectColumns) FROM events WHERE seq > ? ORDER BY seq", arguments: [seq])
        var result: [StoredEvent] = []
        while let row = try cursor.next() { result.append(try stored(row)) }
        return result
    }

    static func maxSeq(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM events") ?? 0
    }

    static func maxVersion(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(
            db, sql: "SELECT COALESCE(MAX(stream_version), 0) FROM events WHERE stream_id = ?",
            arguments: [Schema.streamId]) ?? 0
    }
}

extension EventPayload {
    /// The `clipSchema` of an embedded snapshot, for the event types that carry one.
    var embeddedClipSchema: Int? {
        switch self {
        case .clipAdded(let p): p.clipSchema
        case .clipRemoved(let p): p.clipSchema
        case .clipSplit(let p): p.clipSchema
        case .clipsJoined(let p): p.clipSchema
        case .captionsReplaced(let p): p.clipSchema
        case .trackRemoved(let p): p.clipSchema
        case .trackRestored(let p): p.clipSchema
        default: nil
        }
    }
}
