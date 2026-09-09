import Contracts
import Foundation
import GRDB
import TimelineCore

/// `Cache/cache.sqlite` (storage.md section 11): the index of derived artifacts by content hash, shared
/// across projects, plus FTS5 over transcript words and the alignment results. Deleting the cache loses
/// nothing that cannot be regenerated.
///
/// MediaKit cannot import this module (sibling rule), so the App hands it to MediaKit through the
/// `ArtifactCache` protocol proposed in `docs/design/contracts-proposals/project-store.md`.
public final class CacheDatabase: Sendable {
    /// A `media` row: the identity hint tuple and where the file lives.
    public struct MediaRecord: Hashable, Sendable, Codable, FetchableRecord, PersistableRecord {
        public static let databaseTableName = "media"

        public var contentHash: String
        public var size: Int64
        public var apfsFileId: Int64?
        public var mtime: String?
        public var libraryPath: String?
        public var probe: String?
        public var firstSeen: String

        enum CodingKeys: String, CodingKey {
            case contentHash = "content_hash"
            case size
            case apfsFileId = "apfs_file_id"
            case mtime
            case libraryPath = "library_path"
            case probe
            case firstSeen = "first_seen"
        }
    }

    /// An `artifacts` row.
    public struct ArtifactRecord: Hashable, Sendable, Codable, FetchableRecord, PersistableRecord {
        public static let databaseTableName = "artifacts"

        public var contentHash: String
        public var kind: String
        public var paramsHash: String
        public var path: String
        public var createdAt: String
        public var summary: String?

        enum CodingKeys: String, CodingKey {
            case contentHash = "content_hash"
            case kind
            case paramsHash = "params_hash"
            case path
            case createdAt = "created_at"
            case summary
        }

        public var cacheKey: String { "\(contentHash)/\(kind)/\(paramsHash)" }
    }

    /// An `alignments` row as a value.
    public struct AlignmentRecord: Hashable, Sendable {
        public var referenceHash: String
        public var targetHash: String
        public var paramsHash: String
        public var offset: RationalTime
        public var driftPPM: Double
        public var confidence: Double
        public var status: String
        public var candidates: String?
        public var computedAt: String
    }

    /// One FTS5 hit.
    public struct TranscriptHit: Hashable, Sendable {
        public var contentHash: String
        public var word: String
        public var t0: RationalTime
        public var t1: RationalTime
        public var speaker: String?
    }

    /// A word to index; times are media-relative.
    public struct TranscriptEntry: Hashable, Sendable {
        public var word: String
        public var t0: RationalTime
        public var t1: RationalTime
        public var speaker: String?

        public init(word: String, t0: RationalTime, t1: RationalTime, speaker: String? = nil) {
            self.word = word
            self.t0 = t0
            self.t1 = t1
            self.speaker = speaker
        }
    }

    let writer: any DatabaseWriter
    let clock: any Clock

    /// Opens (or creates) the cache at `path`; `":memory:"` for tests.
    public init(path: String, clock: any Clock = SystemClock()) throws {
        var config = Configuration()
        config.label = "cache"
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous = NORMAL") }
        if path == ":memory:" {
            writer = try DatabaseQueue(path: path, configuration: config)
        } else {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            writer = try DatabasePool(path: path, configuration: config)
        }
        self.clock = clock
        try Self.migrator.migrate(writer)
    }

    static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE media (
                      content_hash TEXT PRIMARY KEY, size INTEGER NOT NULL, apfs_file_id INTEGER, mtime TEXT,
                      library_path TEXT, probe TEXT, first_seen TEXT NOT NULL
                    ) STRICT;
                    CREATE INDEX media_identity_idx ON media(apfs_file_id, size, mtime);
                    CREATE TABLE artifacts (
                      content_hash TEXT NOT NULL REFERENCES media(content_hash),
                      kind TEXT NOT NULL,
                      params_hash TEXT NOT NULL,
                      path TEXT NOT NULL, created_at TEXT NOT NULL, summary TEXT,
                      PRIMARY KEY (content_hash, kind, params_hash)
                    ) STRICT;
                    CREATE VIRTUAL TABLE transcript_words USING fts5(
                      content_hash UNINDEXED, t0 UNINDEXED, t1 UNINDEXED, speaker UNINDEXED, word);
                    CREATE TABLE alignments (
                      reference_hash TEXT NOT NULL, target_hash TEXT NOT NULL, params_hash TEXT NOT NULL,
                      offset_v INTEGER NOT NULL, offset_ts INTEGER NOT NULL CHECK (offset_ts > 0),
                      drift_ppm REAL NOT NULL, confidence REAL NOT NULL, status TEXT NOT NULL,
                      candidates TEXT, computed_at TEXT NOT NULL,
                      PRIMARY KEY (reference_hash, target_hash, params_hash)
                    ) STRICT;
                    """)
            try db.execute(sql: "PRAGMA user_version = 1")
        }
        return m
    }()

    public func close() throws { try writer.close() }

    // MARK: Media

    /// Remembers that a file with this identity tuple hashes to `contentHash`. The tuple is a hint, never an
    /// identity across volumes (storage.md section 2); `volume` is folded into the stored file id.
    public func rememberMedia(
        contentHash: String, size: Int64, volume: String?, fileId: Int64?, mtime: Date?, libraryPath: String?,
        probe: Probe?
    ) throws {
        let probeJSON = try probe.map { String(decoding: try ProjectCodec.encode($0), as: UTF8.self) }
        let record = MediaRecord(
            contentHash: contentHash, size: size, apfsFileId: Self.identity(volume: volume, fileId: fileId),
            mtime: mtime.map(Schema.timestamp), libraryPath: libraryPath, probe: probeJSON,
            firstSeen: Schema.timestamp(clock.now()))
        try writer.write { db in
            if var existing = try MediaRecord.fetchOne(db, key: contentHash) {
                existing.size = record.size
                existing.apfsFileId = record.apfsFileId
                existing.mtime = record.mtime
                if let p = record.libraryPath { existing.libraryPath = p }
                if let p = record.probe { existing.probe = p }
                try existing.update(db)
            } else {
                try record.insert(db)
            }
        }
    }

    /// The content hash of an already-indexed file, found by its `(volume, file id, size, mtime)` tuple.
    public func lookupHash(volume: String?, fileId: Int64, size: Int64, mtime: Date) throws -> String? {
        try writer.read { db in
            try String.fetchOne(
                db, sql: "SELECT content_hash FROM media WHERE apfs_file_id = ? AND size = ? AND mtime = ?",
                arguments: [Self.identity(volume: volume, fileId: fileId), size, Schema.timestamp(mtime)])
        }
    }

    public func media(contentHash: String) throws -> MediaRecord? {
        try writer.read { db in try MediaRecord.fetchOne(db, key: contentHash) }
    }

    /// Folds the volume UUID into the file id so two volumes with equal APFS ids never collide.
    static func identity(volume: String?, fileId: Int64?) -> Int64? {
        guard let fileId else { return nil }
        guard let volume, !volume.isEmpty else { return fileId }
        let hash = StableHash.fnv1a(volume)
        let salt = Int64(bitPattern: UInt64(hash.prefix(15), radix: 16) ?? 0)
        return fileId ^ salt
    }

    // MARK: Artifacts

    public func artifact(contentHash: String, kind: String, paramsHash: String) throws -> ArtifactRecord? {
        try writer.read { db in
            try ArtifactRecord.fetchOne(
                db, sql: "SELECT * FROM artifacts WHERE content_hash = ? AND kind = ? AND params_hash = ?",
                arguments: [contentHash, kind, paramsHash])
        }
    }

    /// Records an artifact; the media row must exist (`rememberMedia` first).
    public func recordArtifact(
        contentHash: String, kind: String, paramsHash: String, path: String, summary: JSONValue? = nil
    ) throws {
        let summaryJSON = try summary.map { String(decoding: try ProjectCodec.encode($0), as: UTF8.self) }
        let record = ArtifactRecord(
            contentHash: contentHash, kind: kind, paramsHash: paramsHash, path: path,
            createdAt: Schema.timestamp(clock.now()), summary: summaryJSON)
        try writer.write { db in try record.upsert(db) }
    }

    public func artifacts(contentHash: String) throws -> [ArtifactRecord] {
        try writer.read { db in
            try ArtifactRecord.fetchAll(
                db, sql: "SELECT * FROM artifacts WHERE content_hash = ? ORDER BY kind, params_hash",
                arguments: [contentHash])
        }
    }

    // MARK: Transcripts

    /// Replaces the indexed words of `contentHash`.
    public func indexTranscript(contentHash: String, words: [TranscriptEntry]) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM transcript_words WHERE content_hash = ?", arguments: [contentHash])
            let statement = try db.cachedStatement(
                sql: "INSERT INTO transcript_words (content_hash, t0, t1, speaker, word) VALUES (?, ?, ?, ?, ?)")
            for w in words {
                try statement.execute(arguments: [
                    contentHash, Self.time(w.t0), Self.time(w.t1), w.speaker, w.word,
                ])
            }
        }
    }

    /// FTS5 `MATCH` over the words of the given content hashes (`transcript_search`), in time order.
    public func searchTranscript(_ query: String, contentHashes: [String], limit: Int = 200) throws -> [TranscriptHit] {
        guard !contentHashes.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: contentHashes.count).joined(separator: ", ")
        var arguments: [any DatabaseValueConvertible] = [query]
        arguments.append(contentsOf: contentHashes)
        arguments.append(limit)
        return try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT content_hash, word, t0, t1, speaker FROM transcript_words
                    WHERE transcript_words MATCH ? AND content_hash IN (\(placeholders))
                    ORDER BY content_hash, t0 LIMIT ?
                    """,
                arguments: StatementArguments(arguments))
            return try rows.map { row in
                TranscriptHit(
                    contentHash: row["content_hash"], word: row["word"], t0: try Self.time(row["t0"]),
                    t1: try Self.time(row["t1"]), speaker: row["speaker"])
            }
        }
    }

    // MARK: Alignments

    public func alignment(referenceHash: String, targetHash: String, paramsHash: String) throws -> AlignmentRecord? {
        try writer.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM alignments WHERE reference_hash = ? AND target_hash = ? AND params_hash = ?",
                    arguments: [referenceHash, targetHash, paramsHash])
            else { return nil }
            return AlignmentRecord(
                referenceHash: row["reference_hash"], targetHash: row["target_hash"], paramsHash: row["params_hash"],
                offset: RationalTime(row["offset_v"], row["offset_ts"]), driftPPM: row["drift_ppm"],
                confidence: row["confidence"], status: row["status"], candidates: row["candidates"],
                computedAt: row["computed_at"])
        }
    }

    /// Records an `Alignment` result under the two content hashes and its parameter hash. A failed alignment
    /// (no offset) is stored with a zero offset and its status, so it is not recomputed.
    public func recordAlignment(referenceHash: String, targetHash: String, _ alignment: Alignment) throws {
        let candidates = String(decoding: try ProjectCodec.encode(alignment.candidates), as: UTF8.self)
        let offset = alignment.offset ?? .zero
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO alignments (reference_hash, target_hash, params_hash, offset_v, offset_ts, drift_ppm,
                      confidence, status, candidates, computed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(reference_hash, target_hash, params_hash) DO UPDATE SET
                      offset_v = excluded.offset_v, offset_ts = excluded.offset_ts, drift_ppm = excluded.drift_ppm,
                      confidence = excluded.confidence, status = excluded.status, candidates = excluded.candidates,
                      computed_at = excluded.computed_at
                    """,
                arguments: [
                    referenceHash, targetHash, alignment.parametersHash, offset.value, max(offset.timescale, 1),
                    alignment.driftPPM, alignment.confidence, alignment.status.rawValue, candidates,
                    Schema.timestamp(clock.now()),
                ])
        }
    }

    // MARK: Helpers

    static func time(_ t: RationalTime) -> String { "\(t.value)/\(t.timescale)" }

    static func time(_ s: String) throws -> RationalTime {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let v = Int64(parts[0]), let ts = Int32(parts[1]) else {
            throw ProjectStoreError.storage("Bad time \(s)")
        }
        return RationalTime(v, ts)
    }
}
