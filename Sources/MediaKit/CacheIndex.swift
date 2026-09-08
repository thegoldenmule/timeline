import Contracts
import Foundation
import GRDB
import TimelineCore

/// A row of `media`: one per content hash the library has seen.
public struct MediaRecord: Hashable, Sendable {
    public var contentHash: String
    public var size: Int64
    public var apfsFileID: Int64?
    public var modified: String?
    /// Relative to `LibraryLayout.libraryDir`, or absolute for referenced files.
    public var libraryPath: String?
    public var probe: Probe?
    public var firstSeen: Date
    /// The asset as imported, so an idempotent re-import returns the same id and description.
    public var asset: Asset?
}

/// A row of `artifacts`: one content-addressed derived file, keyed by `(contentHash, kind, paramsHash)`.
public struct ArtifactRecord: Hashable, Sendable {
    public var contentHash: String
    public var kind: AnalysisKind
    public var paramsHash: String
    /// Relative to `LibraryLayout.cacheDir`.
    public var path: String
    public var createdAt: Date
    public var summary: JSONValue?

    public var cacheKey: String { AnalysisCacheKey.make(contentHash: contentHash, kind: kind, paramsHash: paramsHash) }
}

/// One FTS5 hit from `transcript_words`.
public struct TranscriptHit: Hashable, Sendable {
    public var contentHash: String
    public var word: String
    public var t0: RationalTime
    public var t1: RationalTime
    public var speaker: String?
}

/// A row of `alignments`.
public struct AlignmentRecord: Hashable, Sendable {
    public var referenceHash: String
    public var targetHash: String
    public var paramsHash: String
    public var alignment: Alignment
    public var computedAt: Date
}

/// `Cache/cache.sqlite` (storage.md section 11): the index of every derived artifact, the file-identity hint that
/// skips re-hashing, FTS5 over transcript words, and alignment results. Shared across projects; deleting the
/// whole `Cache/` directory loses nothing that cannot be regenerated.
///
/// The schema follows the design document with two additions: `media.asset` (the imported `Asset` as JSON, so a
/// re-import by hash returns the same id) and `file_hints`, the `(volume, file id, size, mtime) -> hash` table
/// the document describes in prose.
public final class CacheIndex: Sendable {
    public let layout: LibraryLayout
    private let writer: any DatabaseWriter

    /// Opens (creating and migrating as needed) `layout.cacheDatabase`.
    public init(layout: LibraryLayout) throws {
        self.layout = layout
        try FileManager.default.createDirectory(at: layout.cacheDir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous = NORMAL") }
        let pool = try DatabasePool(path: layout.cacheDatabase.path, configuration: config)
        writer = pool
        try CacheIndex.migrator.migrate(pool)
    }

    /// An in-memory index over `layout` (artifact files still land under `layout.cacheDir`), for tests.
    public init(inMemoryFor layout: LibraryLayout) throws {
        self.layout = layout
        try FileManager.default.createDirectory(at: layout.cacheDir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        writer = queue
        try CacheIndex.migrator.migrate(queue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE media (
                      content_hash TEXT PRIMARY KEY, size INTEGER NOT NULL, apfs_file_id INTEGER, mtime TEXT,
                      library_path TEXT, probe TEXT, first_seen TEXT NOT NULL, asset TEXT
                    ) STRICT;
                    CREATE TABLE file_hints (
                      volume_uuid TEXT NOT NULL, file_id INTEGER NOT NULL, size INTEGER NOT NULL, mtime TEXT NOT NULL,
                      content_hash TEXT NOT NULL, path TEXT NOT NULL, seen_at TEXT NOT NULL,
                      PRIMARY KEY (volume_uuid, file_id, size, mtime)
                    ) STRICT;
                    CREATE INDEX file_hints_hash_idx ON file_hints(content_hash);
                    CREATE TABLE artifacts (
                      content_hash TEXT NOT NULL REFERENCES media(content_hash),
                      kind TEXT NOT NULL,
                      params_hash TEXT NOT NULL,
                      path TEXT NOT NULL, created_at TEXT NOT NULL, summary TEXT,
                      PRIMARY KEY (content_hash, kind, params_hash)
                    ) STRICT;
                    CREATE VIRTUAL TABLE transcript_words USING fts5(
                      content_hash UNINDEXED, t0 UNINDEXED, t1 UNINDEXED, speaker UNINDEXED, word
                    );
                    CREATE TABLE alignments (
                      reference_hash TEXT NOT NULL, target_hash TEXT NOT NULL, params_hash TEXT NOT NULL,
                      offset_v INTEGER NOT NULL, offset_ts INTEGER NOT NULL CHECK (offset_ts > 0),
                      drift_ppm REAL NOT NULL, confidence REAL NOT NULL, status TEXT NOT NULL,
                      candidates TEXT, computed_at TEXT NOT NULL,
                      PRIMARY KEY (reference_hash, target_hash, params_hash)
                    ) STRICT;
                    PRAGMA user_version = 1;
                    """)
        }
        return migrator
    }

    // MARK: Media

    public func media(contentHash: String) throws -> MediaRecord? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM media WHERE content_hash = ?", arguments: [contentHash])
                .map(CacheIndex.mediaRecord)
        }
    }

    /// Inserts or updates the media row. `asset` and `probe` are replaced when given and kept otherwise.
    public func upsertMedia(
        contentHash: String, size: Int64, identity: FileIdentity?, libraryPath: String?, probe: Probe?,
        asset: Asset?, now: Date
    ) throws {
        let probeJSON = try probe.map { String(decoding: try ProjectCodec.encoder.encode($0), as: UTF8.self) }
        let assetJSON = try asset.map { String(decoding: try ProjectCodec.encoder.encode($0), as: UTF8.self) }
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO media (content_hash, size, apfs_file_id, mtime, library_path, probe, first_seen, asset)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(content_hash) DO UPDATE SET
                      size = excluded.size,
                      apfs_file_id = COALESCE(excluded.apfs_file_id, media.apfs_file_id),
                      mtime = COALESCE(excluded.mtime, media.mtime),
                      library_path = COALESCE(excluded.library_path, media.library_path),
                      probe = COALESCE(excluded.probe, media.probe),
                      asset = COALESCE(excluded.asset, media.asset)
                    """,
                arguments: [
                    contentHash, size, identity?.fileID, identity?.modifiedKey, libraryPath, probeJSON,
                    Timestamps.string(now), assetJSON,
                ])
        }
    }

    /// Ensures a media row exists so artifacts can reference it (analysis of a file that was never imported).
    func ensureMedia(contentHash: String, url: URL, now: Date) throws {
        if try media(contentHash: contentHash) != nil { return }
        let identity = try? FileIdentity(of: url)
        try upsertMedia(
            contentHash: contentHash, size: identity?.size ?? 0, identity: identity, libraryPath: nil, probe: nil,
            asset: nil, now: now)
    }

    public func setLibraryPath(contentHash: String, libraryPath: String, asset: Asset?) throws {
        let assetJSON = try asset.map { String(decoding: try ProjectCodec.encoder.encode($0), as: UTF8.self) }
        try writer.write { db in
            try db.execute(
                sql: "UPDATE media SET library_path = ?, asset = COALESCE(?, asset) WHERE content_hash = ?",
                arguments: [libraryPath, assetJSON, contentHash])
        }
    }

    private static func mediaRecord(_ row: Row) -> MediaRecord {
        let decoder = ProjectCodec.decoder
        let probe = (row["probe"] as String?).flatMap { try? decoder.decode(Probe.self, from: Data($0.utf8)) }
        let asset = (row["asset"] as String?).flatMap { try? decoder.decode(Asset.self, from: Data($0.utf8)) }
        return MediaRecord(
            contentHash: row["content_hash"], size: row["size"], apfsFileID: row["apfs_file_id"],
            modified: row["mtime"], libraryPath: row["library_path"], probe: probe,
            firstSeen: Timestamps.date(row["first_seen"]) ?? Date(timeIntervalSince1970: 0), asset: asset)
    }

    // MARK: File identity hints

    /// The hash last recorded for a file with this identity, if any.
    public func contentHash(matching identity: FileIdentity) throws -> String? {
        try writer.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT content_hash FROM file_hints
                    WHERE volume_uuid = ? AND file_id = ? AND size = ? AND mtime = ?
                    """,
                arguments: [identity.volumeUUID, identity.fileID, identity.size, identity.modifiedKey])
        }
    }

    public func rememberIdentity(_ identity: FileIdentity, contentHash: String, path: String, now: Date) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO file_hints (volume_uuid, file_id, size, mtime, content_hash, path, seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(volume_uuid, file_id, size, mtime) DO UPDATE SET
                      content_hash = excluded.content_hash, path = excluded.path, seen_at = excluded.seen_at
                    """,
                arguments: [
                    identity.volumeUUID, identity.fileID, identity.size, identity.modifiedKey, contentHash, path,
                    Timestamps.string(now),
                ])
        }
    }

    /// Paths where files with this hash were last seen, most recent first.
    public func knownPaths(contentHash: String) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(
                db, sql: "SELECT path FROM file_hints WHERE content_hash = ? ORDER BY seen_at DESC",
                arguments: [contentHash])
        }
    }

    // MARK: Artifacts

    public func artifact(contentHash: String, kind: AnalysisKind, paramsHash: String) throws -> ArtifactRecord? {
        try writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM artifacts WHERE content_hash = ? AND kind = ? AND params_hash = ?",
                arguments: [contentHash, kind.rawValue, paramsHash]
            ).map(CacheIndex.artifactRecord)
        }
    }

    public func artifacts(contentHash: String, kind: AnalysisKind? = nil) throws -> [ArtifactRecord] {
        try writer.read { db in
            let rows: [Row]
            if let kind {
                rows = try Row.fetchAll(
                    db, sql: "SELECT * FROM artifacts WHERE content_hash = ? AND kind = ? ORDER BY created_at",
                    arguments: [contentHash, kind.rawValue])
            } else {
                rows = try Row.fetchAll(
                    db, sql: "SELECT * FROM artifacts WHERE content_hash = ? ORDER BY created_at",
                    arguments: [contentHash])
            }
            return rows.map(CacheIndex.artifactRecord)
        }
    }

    /// Records (or replaces) an artifact row. `path` is relative to `layout.cacheDir`.
    @discardableResult
    public func recordArtifact(
        contentHash: String, kind: AnalysisKind, paramsHash: String, path: String, summary: JSONValue?, now: Date
    ) throws -> ArtifactRecord {
        let summaryJSON = try summary.map { String(decoding: try ProjectCodec.encoder.encode($0), as: UTF8.self) }
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO artifacts (content_hash, kind, params_hash, path, created_at, summary)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(content_hash, kind, params_hash) DO UPDATE SET
                      path = excluded.path, created_at = excluded.created_at, summary = excluded.summary
                    """,
                arguments: [contentHash, kind.rawValue, paramsHash, path, Timestamps.string(now), summaryJSON])
        }
        return ArtifactRecord(
            contentHash: contentHash, kind: kind, paramsHash: paramsHash, path: path, createdAt: now, summary: summary)
    }

    public func removeArtifact(contentHash: String, kind: AnalysisKind, paramsHash: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM artifacts WHERE content_hash = ? AND kind = ? AND params_hash = ?",
                arguments: [contentHash, kind.rawValue, paramsHash])
        }
    }

    /// The absolute location of an artifact.
    public func url(for artifact: ArtifactRecord) -> URL {
        layout.cacheDir.appendingPathComponent(artifact.path)
    }

    /// Relative artifact path `sha256/ab/cd/<hash>/<name>`.
    public func artifactPath(contentHash: String, name: String) -> String {
        let dir = layout.artifactDir(contentHash: contentHash).path
        let root = layout.cacheDir.path
        let relative = dir.hasPrefix(root) ? String(dir.dropFirst(root.count)) : dir
        return relative.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + name
    }

    private static func artifactRecord(_ row: Row) -> ArtifactRecord {
        let summary = (row["summary"] as String?).flatMap {
            try? ProjectCodec.decoder.decode(JSONValue.self, from: Data($0.utf8))
        }
        return ArtifactRecord(
            contentHash: row["content_hash"], kind: AnalysisKind(rawValue: row["kind"]) ?? .probe,
            paramsHash: row["params_hash"], path: row["path"],
            createdAt: Timestamps.date(row["created_at"]) ?? Date(timeIntervalSince1970: 0), summary: summary)
    }

    // MARK: Transcript words (FTS5)

    /// Replaces the indexed words of one media file.
    public func replaceTranscriptWords(contentHash: String, words: [TranscriptWord]) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM transcript_words WHERE content_hash = ?", arguments: [contentHash])
            let statement = try db.makeStatement(
                sql: "INSERT INTO transcript_words (content_hash, t0, t1, speaker, word) VALUES (?, ?, ?, ?, ?)")
            for word in words {
                try statement.execute(arguments: [
                    contentHash, word.t0.description, word.t1.description, word.speaker, word.text,
                ])
            }
        }
    }

    /// FTS5 search. Each whitespace-separated token of `query` is matched as a quoted term (implicit AND); a
    /// trailing `*` on a token keeps prefix matching. `contentHashes` restricts to the given files (nil: all).
    public func searchTranscript(_ query: String, contentHashes: [String]? = nil, limit: Int = 200) throws
        -> [TranscriptHit]
    {
        let match = CacheIndex.ftsQuery(query)
        guard !match.isEmpty else { return [] }
        return try writer.read { db in
            var sql = "SELECT content_hash, t0, t1, speaker, word FROM transcript_words WHERE transcript_words MATCH ?"
            var arguments: [any DatabaseValueConvertible] = [match]
            if let contentHashes {
                guard !contentHashes.isEmpty else { return [] }
                sql +=
                    " AND content_hash IN (" + Array(repeating: "?", count: contentHashes.count).joined(separator: ",")
                    + ")"
                arguments.append(contentsOf: contentHashes)
            }
            sql += " ORDER BY content_hash, rowid LIMIT ?"
            arguments.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).compactMap { row in
                guard let t0 = RationalTime(parsing: row["t0"]), let t1 = RationalTime(parsing: row["t1"]) else {
                    return nil
                }
                return TranscriptHit(
                    contentHash: row["content_hash"], word: row["word"], t0: t0, t1: t1, speaker: row["speaker"])
            }
        }
    }

    static func ftsQuery(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).map { token -> String in
            var term = String(token)
            let prefix = term.hasSuffix("*")
            if prefix { term.removeLast() }
            let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
            return escaped.isEmpty ? "" : "\"\(escaped)\"" + (prefix ? "*" : "")
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Alignments

    public func recordAlignment(
        referenceHash: String, targetHash: String, paramsHash: String, alignment: Alignment, now: Date
    ) throws {
        let json = String(decoding: try ProjectCodec.encoder.encode(alignment), as: UTF8.self)
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
                    referenceHash, targetHash, paramsHash, offset.value, max(1, offset.timescale), alignment.driftPPM,
                    alignment.confidence, alignment.status.rawValue, json, Timestamps.string(now),
                ])
        }
    }

    public func alignment(referenceHash: String, targetHash: String, paramsHash: String) throws -> AlignmentRecord? {
        try writer.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM alignments WHERE reference_hash = ? AND target_hash = ? AND params_hash = ?",
                    arguments: [referenceHash, targetHash, paramsHash]),
                let json = row["candidates"] as String?,
                let alignment = try? ProjectCodec.decoder.decode(Alignment.self, from: Data(json.utf8))
            else { return nil }
            return AlignmentRecord(
                referenceHash: referenceHash, targetHash: targetHash, paramsHash: paramsHash, alignment: alignment,
                computedAt: Timestamps.date(row["computed_at"]) ?? Date(timeIntervalSince1970: 0))
        }
    }

    // MARK: Maintenance

    /// `wal_checkpoint(TRUNCATE)` and `PRAGMA optimize`, for idle and close.
    public func optimize() throws {
        try writer.write { db in
            try db.execute(sql: "PRAGMA optimize")
        }
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}

extension RationalTime {
    /// Parses the `value/timescale` form of `description`.
    init?(parsing string: String) {
        let parts = string.split(separator: "/")
        guard parts.count == 2, let v = Int64(parts[0]), let ts = Int32(parts[1]), ts > 0 else { return nil }
        self.init(value: v, timescale: ts)
    }
}
