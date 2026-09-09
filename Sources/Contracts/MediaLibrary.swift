import Foundation
import TimelineCore

/// How an import treats the source file (storage.md section 2). Copy is the default.
public enum ImportMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Copies into `Library/YYYY/YYYY-MM-DD/`, the original stays put.
    case copy
    /// Moves into the library.
    case move
    /// Leaves the file where it is; `libraryPath` is absolute and relink-by-hash finds it if it moves.
    case reference
}

/// The on-disk roots of storage.md section 2. Everything derived lives under `cacheDir`; originals under
/// `libraryDir`; `.tlproj` packages under `projectsDir`.
public struct LibraryLayout: Hashable, Sendable, Codable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public var libraryDir: URL { root.appendingPathComponent("Library", isDirectory: true) }
    public var cacheDir: URL { root.appendingPathComponent("Cache", isDirectory: true) }
    public var projectsDir: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    public var cacheDatabase: URL { cacheDir.appendingPathComponent("cache.sqlite") }
    /// `Exports/`, the default output directory of `render_export` under this root (never the hard-coded
    /// default root, so `TIMELINE_ROOT` is honoured).
    public var exportsDir: URL { root.appendingPathComponent("Exports", isDirectory: true) }

    /// `~/Movies/Timeline`, the user-configurable default.
    public static let `default` = LibraryLayout(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Movies/Timeline", isDirectory: true)
    )

    /// Resolves an asset's `libraryPath` (relative to `libraryDir`, or absolute for referenced files).
    public func url(for asset: Asset) -> URL { url(forLibraryPath: asset.libraryPath) }

    public func url(forLibraryPath path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : libraryDir.appendingPathComponent(path)
    }

    /// `Cache/sha256/ab/cd/<hash>/`, the content-addressed artifact directory.
    public func artifactDir(contentHash: String) -> URL {
        let hex = contentHash.hasPrefix("sha256-") ? String(contentHash.dropFirst(7)) : contentHash
        let a = String(hex.prefix(2))
        let b = String(hex.dropFirst(2).prefix(2))
        return cacheDir.appendingPathComponent("sha256/\(a)/\(b)/\(hex)", isDirectory: true)
    }
}

/// What an import produced: the asset as it should appear in the project and the command the caller
/// issues to record it. The library never applies commands itself; the caller (UI or `media_import`)
/// does, so the project's version counter stays the single write path.
public struct ImportResult: Hashable, Sendable, Codable {
    public var asset: Asset
    public var operation: Command.Operation.ImportAsset
    /// True when a file with the same content hash was already in the library (import was a no-op copy).
    public var alreadyInLibrary: Bool
    public var sourceURL: URL
    public var libraryURL: URL

    public init(
        asset: Asset, operation: Command.Operation.ImportAsset, alreadyInLibrary: Bool, sourceURL: URL, libraryURL: URL
    ) {
        self.asset = asset
        self.operation = operation
        self.alreadyInLibrary = alreadyInLibrary
        self.sourceURL = sourceURL
        self.libraryURL = libraryURL
    }

    public init(asset: Asset, alreadyInLibrary: Bool, sourceURL: URL, libraryURL: URL) {
        self.init(
            asset: asset,
            operation: .init(
                id: asset.id, contentHash: asset.contentHash, libraryPath: asset.libraryPath,
                displayName: asset.displayName, kind: asset.kind, duration: asset.duration, hasVideo: asset.hasVideo,
                hasAudio: asset.hasAudio, sampleRate: asset.sampleRate, frameDuration: asset.frameDuration,
                probe: asset.probe),
            alreadyInLibrary: alreadyInLibrary, sourceURL: sourceURL, libraryURL: libraryURL)
    }
}

public enum MediaError: Error, Hashable, Sendable, Codable {
    case notFound(URL)
    case unreadable(URL, reason: String)
    /// The file at the new location does not hash to the asset's `contentHash`.
    case hashMismatch(expected: String, found: String)
    case unsupported(String)
}

/// Originals in, `Asset`s out (storage.md sections 1, 2, 11). Import is a cancellable job: hash the
/// file (SHA-256, streamed, about 2.3 GB/s), copy into the date folder, write the sidecar, probe, and
/// return the asset; a cancel mid-copy leaves no partial file. A file already in the library (same hash)
/// returns the existing asset with `alreadyInLibrary`; `importAsset` in TimelineCore rejects a duplicate
/// hash, so callers check that flag before issuing the command.
public protocol MediaLibrary: Sendable {
    var layout: LibraryLayout { get }

    /// The import as a job (kind `.import`, class `.small`); the outcome payload is an `ImportResult`.
    func importJob(url: URL, mode: ImportMode) -> Job

    /// Runs the import inline (cancellable through the calling task).
    func importAsset(url: URL, mode: ImportMode) async throws -> ImportResult

    /// The current location of a file with this hash, if the library or cache index knows it.
    func locate(contentHash: String) async -> URL?

    /// Codec, size, fps, colour, rotation, capture date, and QuickTime metadata (`Probe.extra`).
    func probe(url: URL) async throws -> Probe

    /// Verifies `url` hashes to `asset.contentHash` and returns the asset pointing at it (online).
    /// The caller issues `relinkAsset`.
    func relink(_ asset: Asset, to url: URL) async throws -> Asset

    /// Assets whose files are missing.
    func checkOffline(assets: [Asset]) async -> Set<AssetID>
}
