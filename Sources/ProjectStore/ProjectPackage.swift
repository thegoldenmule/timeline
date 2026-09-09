import Contracts
import Foundation
import GRDB
import TimelineCore

/// `manifest.json` at the top of a `.tlproj` package (storage.md section 2).
public struct ProjectManifest: Hashable, Sendable, Codable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var appVersion: String
    public var projectId: ProjectID
    /// Where the media library was when the project was created, for relinking hints.
    public var libraryRootHint: String?
    public var createdAt: Date

    public init(
        formatVersion: Int = ProjectManifest.currentFormatVersion, appVersion: String = ProjectManifest.thisAppVersion,
        projectId: ProjectID, libraryRootHint: String?, createdAt: Date
    ) {
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.projectId = projectId
        self.libraryRootHint = libraryRootHint
        self.createdAt = createdAt
    }

    public static var thisAppVersion: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

/// The layout of a `.tlproj` package directory.
public struct ProjectPackage: Hashable, Sendable {
    public static let pathExtension = "tlproj"

    public var url: URL

    public init(url: URL) { self.url = url.standardizedFileURL }

    public var manifestURL: URL { url.appendingPathComponent("manifest.json") }
    public var databaseURL: URL { url.appendingPathComponent("project.sqlite") }
    public var rendersURL: URL { url.appendingPathComponent("renders", isDirectory: true) }

    public var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func createDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try fm.createDirectory(at: rendersURL, withIntermediateDirectories: true)
    }

    func writeManifest(_ manifest: ProjectManifest) throws {
        let data = try ProjectCodec.prettyEncoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    public func readManifest() throws -> ProjectManifest {
        do {
            return try ProjectCodec.decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw ProjectStoreError.badPackage(url, "manifest.json: \(error)")
        }
    }

    /// Throws unless the directory, the manifest, and the database are all present.
    func validate() throws {
        let fm = FileManager.default
        guard exists else { throw ProjectStoreError.notFound(url) }
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw ProjectStoreError.badPackage(url, "no manifest.json")
        }
        guard fm.fileExists(atPath: databaseURL.path) else {
            throw ProjectStoreError.badPackage(url, "no project.sqlite")
        }
    }
}

/// Detects locations where SQLite is at risk (storage.md section 2): synced folders get a warning (or the
/// DELETE-journal fallback), network volumes are refused.
public enum LocationCheck {
    public enum Verdict: Hashable, Sendable {
        case local
        /// Inside a sync service's folder; `service` names it.
        case synced(service: String)
        /// On a network volume.
        case network
    }

    /// Path components (case-insensitive) that mark a sync service's folder.
    static let syncedFolderMarkers: [(component: String, service: String)] = [
        ("Mobile Documents", "iCloud Drive"), ("com~apple~CloudDocs", "iCloud Drive"),
        ("CloudStorage", "cloud storage"),
        ("Dropbox", "Dropbox"), ("Google Drive", "Google Drive"), ("GoogleDrive", "Google Drive"),
        ("OneDrive", "OneDrive"), ("Box", "Box"),
    ]

    /// Checks `url` (or its nearest existing ancestor) for sync markers and its volume for locality.
    public static func check(_ url: URL) -> Verdict {
        let standardized = url.standardizedFileURL
        // Volume: walk up to something that exists so a not-yet-created package can be judged.
        var probe = standardized
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        if let values = try? probe.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey]) {
            if values.volumeIsLocal == false { return .network }
            if values.isUbiquitousItem == true { return .synced(service: "iCloud Drive") }
        }
        for component in standardized.pathComponents {
            for marker in syncedFolderMarkers where component.caseInsensitiveCompare(marker.component) == .orderedSame {
                return .synced(service: marker.service)
            }
        }
        // Dropbox marks its root with a hidden file; Drive and OneDrive live under CloudStorage on modern macOS.
        var ancestor = probe
        while ancestor.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".dropbox").path) {
                return .synced(service: "Dropbox")
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
        return .local
    }
}

/// Opens and creates `.tlproj` packages (storage.md section 2) as `SQLiteProjectStore`s.
public struct SQLiteProjectStoreOpener: ProjectStoreOpening {
    /// What to do when a package sits in a synced folder.
    public enum SyncedLocationPolicy: Sendable {
        /// Open normally and record a warning on the store.
        case warn
        /// Refuse with `ProjectStoreError.syncedLocation`.
        case refuse
        /// Open with `journal_mode=DELETE` and `synchronous=FULL` so there is one file to sync, plus a warning.
        case useDeleteJournal
    }

    public var ids: any IDGenerator
    public var clock: any Clock
    public var options: SQLiteProjectStore.Options
    public var syncedLocationPolicy: SyncedLocationPolicy
    /// Recorded in new manifests.
    public var libraryRootHint: String?

    public init(
        ids: any IDGenerator = UUIDv7Generator(), clock: any Clock = SystemClock(),
        options: SQLiteProjectStore.Options = .init(), syncedLocationPolicy: SyncedLocationPolicy = .warn,
        libraryRootHint: String? = nil
    ) {
        self.ids = ids
        self.clock = clock
        self.options = options
        self.syncedLocationPolicy = syncedLocationPolicy
        self.libraryRootHint = libraryRootHint
    }

    public func open(at url: URL) async throws -> any ProjectStore {
        try await openStore(at: url)
    }

    public func create(at url: URL, name: String, settings: ProjectSettings, sequence: Command.Operation.SequenceSpec)
        async throws -> any ProjectStore
    {
        try await createStore(at: url, name: name, settings: settings, sequence: sequence)
    }

    /// `open(at:)` with the concrete type (renders, observation, backup).
    public func openStore(at url: URL) async throws -> SQLiteProjectStore {
        let package = ProjectPackage(url: url)
        try package.validate()
        let manifest = try package.readManifest()
        let (options, warnings) = try resolveLocation(package)
        let store = try SQLiteProjectStore(
            databaseAt: package.databaseURL.path, url: package.url, ids: ids, clock: clock, options: options,
            warnings: warnings)
        let projectId = await store.projectId
        if await store.version() > 0, projectId != manifest.projectId {
            try await store.close()
            throw ProjectStoreError.projectMismatch(expected: manifest.projectId.rawValue, found: projectId.rawValue)
        }
        return store
    }

    /// Creates the package and applies `createProject` as its first transaction (actor `system`).
    public func createStore(
        at url: URL, name: String, settings: ProjectSettings, sequence: Command.Operation.SequenceSpec
    ) async throws -> SQLiteProjectStore {
        let package = ProjectPackage(url: url)
        guard !package.exists else { throw ProjectStoreError.alreadyExists(package.url) }
        let (options, warnings) = try resolveLocation(package)
        try package.createDirectories()
        let store = try SQLiteProjectStore(
            databaseAt: package.databaseURL.path, url: package.url, ids: ids, clock: clock, options: options,
            warnings: warnings)
        let command = Command(
            commandId: CommandID(minting: ids), actor: .system,
            operation: .createProject(.init(name: name, settings: settings, sequence: sequence)))
        _ = try await store.apply(command)
        try package.writeManifest(
            ProjectManifest(projectId: await store.projectId, libraryRootHint: libraryRootHint, createdAt: clock.now()))
        try await store.flush()
        return store
    }

    private func resolveLocation(_ package: ProjectPackage) throws -> (SQLiteProjectStore.Options, [String]) {
        var options = self.options
        switch LocationCheck.check(package.url) {
        case .local:
            return (options, [])
        case .network:
            throw ProjectStoreError.networkVolume(package.url)
        case .synced(let service):
            let warning =
                "\(package.url.lastPathComponent) is inside a \(service) folder; sync can corrupt an open project"
            switch syncedLocationPolicy {
            case .warn:
                return (options, [warning])
            case .refuse:
                throw ProjectStoreError.syncedLocation(package.url, service)
            case .useDeleteJournal:
                options.journal = .delete
                return (options, [warning + " (opened with a DELETE journal)"])
            }
        }
    }
}
