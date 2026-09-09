import Contracts
import Foundation
import GRDB
import TimelineCore

/// The cross-project media index of `docs/plans/media-library.md` section 2.4: every `.tlproj` package
/// under the projects directory, plus every package `register(packageAt:)` was told about, scanned into
/// `Cache/projects.sqlite` so the library panel can list media the open project has never seen.
///
/// Foreign packages are opened **read-only**, with no migrator and no recovery: browsing another
/// project must never disturb it, and a package whose database refuses a read-only open (a hot WAL,
/// corruption) is marked unreadable with the reason rather than repaired. Like everything else under
/// `Cache/`, this database is disposable; a rescan rebuilds it (registrations of out-of-root packages
/// come back the next time the app opens them).
public actor SQLiteMediaCatalog: MediaCatalog {
    /// `Cache/projects.sqlite`. Deliberately not `cache.sqlite`: two GRDB migrators over one file
    /// collide, and MediaKit's `CacheIndex` owns that one (contracts-notes.md).
    public static func databaseURL(in layout: LibraryLayout) -> URL {
        layout.cacheDir.appendingPathComponent("projects.sqlite")
    }

    public nonisolated let layout: LibraryLayout
    private let writer: any DatabaseWriter
    private let clock: any Clock

    /// Opens (creating and migrating as needed) the index for `layout`.
    public init(layout: LibraryLayout, clock: any Clock = SystemClock()) throws {
        try FileManager.default.createDirectory(at: layout.cacheDir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous = NORMAL") }
        let pool = try DatabasePool(path: Self.databaseURL(in: layout).path, configuration: config)
        self.layout = layout
        self.clock = clock
        writer = pool
        try SQLiteMediaCatalog.migrator.migrate(pool)
    }

    /// An in-memory index over `layout`, for tests. The packages it scans are still real.
    public init(inMemoryFor layout: LibraryLayout, clock: any Clock = SystemClock()) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        self.layout = layout
        self.clock = clock
        writer = queue
        try SQLiteMediaCatalog.migrator.migrate(queue)
    }

    private static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE projects (
                      project_id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
                      library_root TEXT, db_size INTEGER NOT NULL, db_mtime TEXT NOT NULL,
                      scanned_at TEXT NOT NULL, readable INTEGER NOT NULL DEFAULT 1, unreadable_reason TEXT
                    ) STRICT;
                    CREATE TABLE project_assets (
                      project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
                      asset_id TEXT NOT NULL, content_hash TEXT NOT NULL, display_name TEXT NOT NULL,
                      kind TEXT NOT NULL, library_path TEXT NOT NULL,
                      duration_v INTEGER NOT NULL, duration_ts INTEGER NOT NULL CHECK (duration_ts > 0),
                      has_video INTEGER NOT NULL, has_audio INTEGER NOT NULL, offline INTEGER NOT NULL, probe TEXT,
                      PRIMARY KEY (project_id, asset_id)
                    ) STRICT;
                    CREATE INDEX project_assets_hash_idx ON project_assets(content_hash);
                    -- Packages outside the projects directory, remembered so they stay browsable when closed.
                    CREATE TABLE registered_packages (
                      path TEXT PRIMARY KEY, registered_at TEXT NOT NULL
                    ) STRICT;
                    PRAGMA user_version = 1;
                    """)
        }
        return m
    }()

    // MARK: Reading

    public func projects() async throws -> [CatalogProject] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM projects ORDER BY db_mtime DESC, name")
                .map(SQLiteMediaCatalog.catalogProject)
        }
    }

    public func items(excluding: Set<ProjectID>) async throws -> [CatalogItem] {
        let rows = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT a.*, p.name AS project_name, p.library_root AS project_library_root
                    FROM project_assets a JOIN projects p USING (project_id)
                    WHERE p.readable = 1
                    ORDER BY p.db_mtime DESC, a.display_name, a.asset_id
                    """)
        }
        return try rows.compactMap { row in
            let projectId = ProjectID(row["project_id"] as String)
            guard !excluding.contains(projectId) else { return nil }
            return CatalogItem(
                asset: try AssetRow(row: row).asset(), projectId: projectId,
                projectName: row["project_name"],
                libraryRoot: (row["project_library_root"] as String?).map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                })
        }
    }

    // MARK: Scanning

    public func register(packageAt url: URL) async {
        let path = ProjectPackage(url: url).url.path
        try? await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO registered_packages (path, registered_at) VALUES (?, ?)
                    ON CONFLICT(path) DO UPDATE SET registered_at = excluded.registered_at
                    """,
                arguments: [path, Schema.timestamp(clock.now())])
        }
    }

    /// Re-reads the packages whose `project.sqlite` changed size or mtime since the last scan, marks the
    /// ones that vanished or refuse a read-only open unreadable, and returns how many it re-read.
    @discardableResult
    public func refresh() async throws -> Int {
        let paths = try discoveredPackages()
        let known = try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT path, db_size, db_mtime, readable FROM projects")
        }
        var stored: [String: (size: Int64, mtime: String, readable: Bool)] = [:]
        for row in known { stored[row["path"]] = (row["db_size"], row["db_mtime"], row["readable"]) }

        var rescanned = 0
        for path in paths {
            let package = ProjectPackage(url: URL(fileURLWithPath: path, isDirectory: true))
            guard let stamp = Self.databaseStamp(of: package) else {
                markUnreadable(path: path, reason: "the package is gone")
                continue
            }
            if let previous = stored[path], previous.readable, previous.size == stamp.size,
                previous.mtime == stamp.mtime
            {
                continue
            }
            rescanned += 1
            do {
                try scan(package, stamp: stamp)
            } catch {
                markUnreadable(path: path, reason: "\(error)")
            }
        }
        // A package that is no longer discovered at all (unregistered, or moved out of the directory).
        let gone = Set(stored.keys).subtracting(paths)
        for path in gone { markUnreadable(path: path, reason: "the package is gone") }
        return rescanned
    }

    /// Every `.tlproj` directly under the projects directory, plus every registered package. Neither a
    /// recursive walk nor a Spotlight hunt: a package the user keeps elsewhere is remembered the first
    /// time the app opens it.
    private func discoveredPackages() throws -> Set<String> {
        var paths = Set<String>()
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: layout.projectsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in contents where url.pathExtension == ProjectPackage.pathExtension {
            paths.insert(ProjectPackage(url: url).url.path)
        }
        let registered = try writer.read { db in try String.fetchAll(db, sql: "SELECT path FROM registered_packages") }
        paths.formUnion(registered)
        return paths
    }

    /// The `(size, mtime)` pair that short-circuits a rescan, or nil when the package is not usable.
    private static func databaseStamp(of package: ProjectPackage) -> (size: Int64, mtime: String)? {
        guard (try? package.validate()) != nil,
            let values = try? package.databaseURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        return (Int64(size), Schema.timestamp(modified))
    }

    /// Reads one package's manifest, name, and assets through a read-only connection and replaces its rows.
    private func scan(_ package: ProjectPackage, stamp: (size: Int64, mtime: String)) throws {
        let manifest = try package.readManifest()
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(1)
        let queue = try DatabaseQueue(path: package.databaseURL.path, configuration: config)
        defer { try? queue.close() }
        let (name, rows) = try queue.read { db in
            // json_extract keeps the 1.5 MB state document out of memory just to read the project name.
            let name =
                try String.fetchOne(db, sql: "SELECT json_extract(state, '$.name') FROM project_state WHERE id = 1")
                ?? package.url.deletingPathExtension().lastPathComponent
            return (name, try AssetRow.fetchAll(db))
        }
        let now = Schema.timestamp(clock.now())
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO projects
                      (project_id, path, name, library_root, db_size, db_mtime, scanned_at, readable, unreadable_reason)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1, NULL)
                    ON CONFLICT(project_id) DO UPDATE SET
                      path = excluded.path, name = excluded.name, library_root = excluded.library_root,
                      db_size = excluded.db_size, db_mtime = excluded.db_mtime, scanned_at = excluded.scanned_at,
                      readable = 1, unreadable_reason = NULL
                    """,
                arguments: [
                    manifest.projectId.rawValue, package.url.path, name, manifest.libraryRootHint, stamp.size,
                    stamp.mtime, now,
                ])
            try db.execute(
                sql: "DELETE FROM project_assets WHERE project_id = ?", arguments: [manifest.projectId.rawValue])
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO project_assets
                          (project_id, asset_id, content_hash, display_name, kind, library_path,
                           duration_v, duration_ts, has_video, has_audio, offline, probe)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        manifest.projectId.rawValue, row.assetId, row.contentHash, row.displayName, row.kind,
                        row.libraryPath, row.durationV, row.durationTs, row.hasVideo, row.hasAudio, row.offline,
                        row.probe,
                    ])
            }
        }
    }

    /// Keeps the project row (so the panel can say why it is greyed out) and drops it out of `items`.
    private func markUnreadable(path: String, reason: String) {
        try? writer.write { db in
            try db.execute(
                sql: "UPDATE projects SET readable = 0, unreadable_reason = ?, scanned_at = ? WHERE path = ?",
                arguments: [reason, Schema.timestamp(clock.now()), path])
        }
    }

    // MARK: Row decoding

    private static func catalogProject(_ row: Row) -> CatalogProject {
        CatalogProject(
            id: ProjectID(row["project_id"] as String), name: row["name"],
            url: URL(fileURLWithPath: row["path"], isDirectory: true),
            modifiedAt: try? Schema.date(row["db_mtime"]), isReadable: row["readable"],
            unreadableReason: row["unreadable_reason"])
    }
}
