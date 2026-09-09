// ProjectStore: the SQLite event store of docs/design/storage.md sections 3 to 12, built on GRDB.
//
// - `SQLiteProjectStore` is the `Contracts.ProjectStore` implementation (one actor per open project).
// - `SQLiteProjectStoreOpener` handles the `.tlproj` package (`manifest.json`, `project.sqlite`, `renders/`).
// - `Schema` holds the migrator; `Projections` the query tables and history; `Recovery` the open-time checks.
// - `CacheDatabase` is the shared `Cache/cache.sqlite` index (section 11).
import Foundation

/// Errors of the storage layer that are not `EditorError`s (those come out of `apply`).
public enum ProjectStoreError: Error, Hashable, Sendable {
    /// The store was closed; nothing can be read or written any more.
    case closed
    /// No `.tlproj` package at the URL.
    case notFound(URL)
    /// `create` was asked to overwrite an existing package.
    case alreadyExists(URL)
    /// The package exists but is missing a part, or its manifest does not parse.
    case badPackage(URL, String)
    /// `PRAGMA integrity_check` did not answer `ok` after an unclean shutdown.
    case corrupt(URL?, String)
    /// The package sits on a network volume; storage.md section 2 refuses those.
    case networkVolume(URL)
    /// The package sits in a synced folder and the open options say to refuse.
    case syncedLocation(URL, String)
    /// The manifest's project id does not match the database.
    case projectMismatch(expected: String, found: String)
    /// A storage error surfaced while reading.
    case storage(String)
}

extension ProjectStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .closed: "The project store is closed"
        case .notFound(let url): "No project at \(url.path)"
        case .alreadyExists(let url): "A project already exists at \(url.path)"
        case .badPackage(let url, let why): "Not a usable project package at \(url.path): \(why)"
        case .corrupt(let url, let why): "Project database \(url?.path ?? "") failed its integrity check: \(why)"
        case .networkVolume(let url): "\(url.path) is on a network volume; projects must live on local disk"
        case .syncedLocation(let url, let service): "\(url.path) is inside a \(service) folder"
        case .projectMismatch(let expected, let found):
            "manifest.json names project \(expected) but the database holds \(found)"
        case .storage(let why): "Storage error: \(why)"
        }
    }
}
