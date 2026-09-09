import AVFoundation
import Contracts
import Foundation
import TimelineCore

/// `<name>.json` next to every copied or moved original (storage.md section 2): content hash, provenance,
/// import time, the probe, and the asset as it was handed to the project. Referenced files keep theirs in the
/// content-addressed cache directory as `import.json`, so the referenced folder is never written to.
public struct Sidecar: Hashable, Sendable, Codable {
    public struct Source: Hashable, Sendable, Codable {
        public var path: String
        public var size: Int64
        public var modified: Date?
        public var created: Date?
    }

    public var version: Int
    public var contentHash: String
    public var source: Source
    public var importedAt: Date
    public var mode: ImportMode
    public var probe: Probe
    public var asset: Asset

    public static let currentVersion = 1
}

/// The on-disk `MediaLibrary` (storage.md sections 1, 2, 11). Import hashes the file (SHA-256, streamed), returns
/// the existing asset when the hash is known, otherwise probes, copies or moves it into `Library/YYYY/YYYY-MM-DD/`
/// (QuickTime creation date, falling back to the file's modification time; numeric suffix on collision) through a
/// temporary name in the same directory and one atomic rename, writes the sidecar, and indexes it in
/// `cache.sqlite`. A cancellation mid-copy removes the temporary file and leaves nothing behind.
///
/// The actor guards only the destination-name reservation and the cache writes; hashing, copying, and probing run
/// as `nonisolated` work so several imports proceed concurrently.
public actor FileMediaLibrary: MediaLibrary {
    public nonisolated let layout: LibraryLayout
    public nonisolated let cache: CacheIndex
    private let ids: any IDGenerator
    private let clock: any Clock
    /// Destinations claimed by in-flight imports, so two concurrent imports never pick the same name.
    private var claimed: Set<String> = []
    /// Test hook: awaited before every copied chunk with the chunk index.
    nonisolated(unsafe) var beforeCopyChunk: (@Sendable (Int) async throws -> Void)?

    public init(
        layout: LibraryLayout, cache: CacheIndex? = nil, ids: any IDGenerator = UUIDv7Generator(),
        clock: any Clock = SystemClock()
    ) throws {
        self.layout = layout
        self.cache = try cache ?? CacheIndex(layout: layout)
        self.ids = ids
        self.clock = clock
        for dir in [layout.libraryDir, layout.cacheDir, layout.projectsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: MediaLibrary

    public nonisolated func importJob(url: URL, mode: ImportMode) -> Job {
        Job(
            kind: .import, memoryClass: .small, label: "Import \(url.lastPathComponent)",
            estimatedBytes: Int64(ContentHash.chunkSize * 2)
        ) { context in
            let result = try await self.performImport(url: url, mode: mode) { context.report($0) }
            context.report(.done)
            return try JobOutcome(urls: [result.libraryURL], encoding: result)
        }
    }

    public func importAsset(url: URL, mode: ImportMode) async throws -> ImportResult {
        try await performImport(url: url, mode: mode, progress: nil)
    }

    public func locate(contentHash: String) async -> URL? {
        if let record = try? cache.media(contentHash: contentHash), let path = record.libraryPath {
            let url = layout.url(forLibraryPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        for path in (try? cache.knownPaths(contentHash: contentHash)) ?? [] {
            let url = URL(fileURLWithPath: path)
            guard let identity = try? FileIdentity(of: url),
                (try? cache.contentHash(matching: identity)) == contentHash
            else { continue }
            return url
        }
        return nil
    }

    public nonisolated func probe(url: URL) async throws -> Probe {
        try await MediaProbe.inspect(url).probe
    }

    public func relink(_ asset: Asset, to url: URL) async throws -> Asset {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.notFound(url) }
        let hash = try await ContentHash.sha256(of: url)
        guard hash == asset.contentHash else {
            throw MediaError.hashMismatch(expected: asset.contentHash, found: hash)
        }
        var relinked = asset
        relinked.libraryPath = libraryPath(for: url)
        relinked.offline = false
        let now = clock.now()
        if let identity = try? FileIdentity(of: url) {
            try? cache.rememberIdentity(identity, contentHash: hash, path: url.standardizedFileURL.path, now: now)
        }
        try cache.ensureMedia(contentHash: hash, url: url, now: now)
        try cache.setLibraryPath(contentHash: hash, libraryPath: relinked.libraryPath, asset: relinked)
        return relinked
    }

    public nonisolated func checkOffline(assets: [Asset]) async -> Set<AssetID> {
        Set(assets.filter { !FileManager.default.fileExists(atPath: layout.url(for: $0).path) }.map(\.id))
    }

    // MARK: Import

    /// Progress stages: `hash` (0...0.5), `probe`, `copy` (0.5...1), `index`.
    nonisolated func performImport(
        url: URL, mode: ImportMode, progress: (@Sendable (JobProgress) -> Void)?
    ) async throws -> ImportResult {
        let source = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else { throw MediaError.notFound(url) }
        let identity = try FileIdentity(of: source)
        let now = clock.now()

        // 1. Hash: the identity hint first, the streamed SHA-256 otherwise.
        progress?(JobProgress(fraction: 0, stage: "hash"))
        let hash: String
        if let hinted = try cache.contentHash(matching: identity) {
            hash = hinted
        } else {
            let size = max(identity.size, 1)
            hash = try await ContentHash.sha256(of: source) { done in
                progress?(JobProgress(fraction: 0.5 * Double(done) / Double(size), stage: "hash"))
            }
            try cache.rememberIdentity(identity, contentHash: hash, path: source.path, now: now)
        }
        try Task.checkCancellation()

        // 2. Idempotent by hash: a file the library knows returns its asset; a known file whose copy went
        //    missing is relinked to this one.
        if let existing = try cache.media(contentHash: hash), let asset = existing.asset {
            if let path = existing.libraryPath,
                FileManager.default.fileExists(atPath: layout.url(forLibraryPath: path).path)
            {
                progress?(.done)
                return ImportResult(
                    asset: asset, alreadyInLibrary: true, sourceURL: source,
                    libraryURL: layout.url(forLibraryPath: path))
            }
            let relinked = try await relink(asset, to: source)
            progress?(.done)
            return ImportResult(asset: relinked, alreadyInLibrary: true, sourceURL: source, libraryURL: source)
        }

        // 3. Probe.
        progress?(JobProgress(fraction: 0.5, stage: "probe"))
        let inspection = try await MediaProbe.inspect(source)
        try Task.checkCancellation()

        // 4. Place.
        let destination: URL
        switch mode {
        case .reference:
            destination = source
        case .copy, .move:
            let date = inspection.capturedAt ?? identity.modified
            let dir = layout.libraryDir.appendingPathComponent(
                FileMediaLibrary.dateFolder(for: date), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            destination = await claimDestination(in: dir, name: source.lastPathComponent)
            do {
                progress?(JobProgress(fraction: 0.5, stage: "copy"))
                try await place(source, at: destination, mode: mode, size: identity.size, progress: progress)
            } catch {
                await release(destination)
                FileMediaLibrary.removeIfEmpty(dir)
                throw error
            }
        }

        // 5. Describe, index, sidecar.
        progress?(JobProgress(fraction: 0.95, stage: "index"))
        let libraryPath = self.libraryPath(for: destination)
        let asset = Asset(
            id: AssetID(minting: ids), contentHash: hash, libraryPath: libraryPath,
            displayName: source.lastPathComponent, kind: inspection.kind, duration: inspection.duration,
            hasVideo: inspection.hasVideo, hasAudio: inspection.hasAudio, sampleRate: inspection.sampleRate,
            frameDuration: inspection.frameDuration, probe: inspection.probe)
        let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let sidecar = Sidecar(
            version: Sidecar.currentVersion, contentHash: hash,
            source: Sidecar.Source(
                path: source.path, size: identity.size, modified: identity.modified,
                created: sourceAttributes?[.creationDate] as? Date),
            importedAt: now, mode: mode, probe: inspection.probe, asset: asset)
        do {
            try writeSidecar(sidecar, for: destination, mode: mode, contentHash: hash)
            try cache.upsertMedia(
                contentHash: hash, size: identity.size, identity: identity, libraryPath: libraryPath,
                probe: inspection.probe, asset: asset, now: now)
            if mode != .reference, let placed = try? FileIdentity(of: destination) {
                try cache.rememberIdentity(placed, contentHash: hash, path: destination.path, now: now)
            }
        } catch {
            if mode == .copy { try? FileManager.default.removeItem(at: destination) }
            await release(destination)
            throw error
        }
        await release(destination)
        progress?(.done)
        return ImportResult(asset: asset, alreadyInLibrary: false, sourceURL: source, libraryURL: destination)
    }

    /// Removes a date folder an aborted import left empty (and its year folder when that is empty too).
    private static func removeIfEmpty(_ dir: URL) {
        var current = dir
        for _ in 0..<2 {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: current.path), entries.isEmpty
            else { return }
            try? FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    /// `YYYY/YYYY-MM-DD` in the user's calendar and time zone.
    static func dateFolder(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%04d-%02d-%02d", c.year ?? 0, c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The first free `name`, `name-2`, `name-3`, ... in `dir`, counting both files on disk and in-flight imports.
    private func claimDestination(in dir: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var suffix = 1
        while claimed.contains(candidate.path) || FileManager.default.fileExists(atPath: candidate.path)
            || FileManager.default.fileExists(atPath: candidate.path + ".json")
        {
            suffix += 1
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)")
        }
        claimed.insert(candidate.path)
        return candidate
    }

    private func release(_ destination: URL) { claimed.remove(destination.path) }

    /// Copies or moves `source` to `destination`. A copy (and a cross-volume move) streams through a temporary
    /// name in the destination directory and renames at the end; cancellation removes the temporary file.
    private nonisolated func place(
        _ source: URL, at destination: URL, mode: ImportMode, size: Int64,
        progress: (@Sendable (JobProgress) -> Void)?
    ) async throws {
        if mode == .move {
            let sameVolume =
                (try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier)?.isEqual(
                    try? destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey])
                        .volumeIdentifier) ?? false
            if sameVolume {
                try FileManager.default.moveItem(at: source, to: destination)
                return
            }
        }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tlimport-\(UUID().uuidString.prefix(8))")
        do {
            try await copyChunked(source, to: temp, size: size, progress: progress)
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) {
            var keep: [FileAttributeKey: Any] = [:]
            if let m = attributes[.modificationDate] { keep[.modificationDate] = m }
            if let c = attributes[.creationDate] { keep[.creationDate] = c }
            try? FileManager.default.setAttributes(keep, ofItemAtPath: destination.path)
        }
        if mode == .move { try FileManager.default.removeItem(at: source) }
    }

    private nonisolated func copyChunked(
        _ source: URL, to temp: URL, size: Int64, progress: (@Sendable (JobProgress) -> Void)?
    ) async throws {
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw MediaError.unreadable(temp, reason: "could not create temporary file")
        }
        guard let input = try? FileHandle(forReadingFrom: source) else { throw MediaError.notFound(source) }
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        var copied: Int64 = 0
        var chunk = 0
        while true {
            try Task.checkCancellation()
            try await beforeCopyChunk?(chunk)
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: ContentHash.chunkSize), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            copied += Int64(data.count)
            chunk += 1
            progress?(JobProgress(fraction: 0.5 + 0.45 * Double(copied) / Double(max(size, 1)), stage: "copy"))
            await Task.yield()
        }
        try output.synchronize()
    }

    private nonisolated func writeSidecar(
        _ sidecar: Sidecar, for destination: URL, mode: ImportMode, contentHash: String
    )
        throws
    {
        let url: URL
        if mode == .reference {
            let dir = layout.artifactDir(contentHash: contentHash)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("import.json")
        } else {
            url = destination.appendingPathExtension("json")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sidecar).write(to: url, options: .atomic)
    }

    /// Reads the sidecar of a library file, if present.
    public nonisolated func sidecar(for libraryURL: URL) throws -> Sidecar? {
        let url = libraryURL.appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Sidecar.self, from: Data(contentsOf: url))
    }

    /// Relative to `Library/` when inside it, absolute otherwise.
    nonisolated func libraryPath(for url: URL) -> String {
        let root = layout.libraryDir.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
}
