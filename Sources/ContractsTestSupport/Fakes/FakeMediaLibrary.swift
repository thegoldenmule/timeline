import AVFoundation
import Contracts
import CoreGraphics
import Foundation
import ImageIO
import TimelineCore

/// An in-memory `MediaLibrary` over a temporary `LibraryLayout`. Probing uses `AVURLAsset` on the real
/// file; the content hash is a fake (FNV-1a over the file size and its first MiB, no CryptoKit) that is
/// nonetheless content-derived, so relink-by-hash behaves: a moved file still hashes the same.
public actor FakeMediaLibrary: MediaLibrary {
    public nonisolated let layout: LibraryLayout
    private let directory: TestMedia.Directory?
    private let ids: any IDGenerator
    private var byHash: [String: (asset: Asset, url: URL)] = [:]
    public private(set) var imports: [ImportResult] = []
    public private(set) var probes: [URL] = []
    public private(set) var relinks: [(asset: Asset, url: URL)] = []

    /// A library under a fresh temporary root (removed when the fake is released).
    public init(ids: any IDGenerator = SequentialIDGenerator(start: 5000)) throws {
        let dir = try TestMedia.Directory(prefix: "FakeLibrary")
        directory = dir
        layout = LibraryLayout(root: dir.url)
        self.ids = ids
        try FakeMediaLibrary.createDirectories(layout)
    }

    public init(layout: LibraryLayout, ids: any IDGenerator = SequentialIDGenerator(start: 5000)) throws {
        directory = nil
        self.layout = layout
        self.ids = ids
        try FakeMediaLibrary.createDirectories(layout)
    }

    private static func createDirectories(_ layout: LibraryLayout) throws {
        for dir in [layout.libraryDir, layout.cacheDir, layout.projectsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// The fake content hash: `fake-<fnv1a of size + first MiB>`.
    public static func fakeHash(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw MediaError.notFound(url) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1 << 20)) ?? Data()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var data = Data()
        withUnsafeBytes(of: Int64(size).littleEndian) { data.append(contentsOf: $0) }
        data.append(head)
        return "fake-" + StableHash.fnv1a(data)
    }

    /// Pre-seeds an asset at `url` without importing (for tests that build assets by hand).
    public func register(_ asset: Asset, at url: URL) {
        byHash[asset.contentHash] = (asset, url)
    }

    public var assets: [Asset] { byHash.values.map(\.asset).sorted { $0.id < $1.id } }

    // MARK: MediaLibrary

    public nonisolated func importJob(url: URL, mode: ImportMode) -> Job {
        Job(kind: .import, memoryClass: .small, label: "Import \(url.lastPathComponent)") { context in
            context.report(JobProgress(fraction: 0, stage: "hash"))
            let result = try await self.importAsset(url: url, mode: mode)
            context.report(.done)
            return try JobOutcome(urls: [result.libraryURL], encoding: result)
        }
    }

    public func importAsset(url: URL, mode: ImportMode) async throws -> ImportResult {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.notFound(url) }
        try Task.checkCancellation()
        let hash = try FakeMediaLibrary.fakeHash(of: url)
        if let existing = byHash[hash] {
            let result = ImportResult(
                asset: existing.asset, alreadyInLibrary: true, sourceURL: url, libraryURL: existing.url)
            imports.append(result)
            return result
        }
        let info = try await FakeMediaLibrary.inspect(url)
        try Task.checkCancellation()
        let (libraryURL, libraryPath) = try place(url, mode: mode)
        let asset = Asset(
            id: AssetID(minting: ids), contentHash: hash, libraryPath: libraryPath, displayName: url.lastPathComponent,
            kind: info.kind, duration: info.duration, hasVideo: info.hasVideo, hasAudio: info.hasAudio,
            sampleRate: info.sampleRate, frameDuration: info.frameDuration, probe: info.probe)
        byHash[hash] = (asset, libraryURL)
        let result = ImportResult(asset: asset, alreadyInLibrary: false, sourceURL: url, libraryURL: libraryURL)
        imports.append(result)
        return result
    }

    public func locate(contentHash: String) -> URL? {
        guard let entry = byHash[contentHash], FileManager.default.fileExists(atPath: entry.url.path) else {
            return nil
        }
        return entry.url
    }

    public func probe(url: URL) async throws -> Probe {
        probes.append(url)
        return try await FakeMediaLibrary.inspect(url).probe
    }

    public func relink(_ asset: Asset, to url: URL) async throws -> Asset {
        relinks.append((asset, url))
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.notFound(url) }
        let hash = try FakeMediaLibrary.fakeHash(of: url)
        guard hash == asset.contentHash else {
            throw MediaError.hashMismatch(expected: asset.contentHash, found: hash)
        }
        var relinked = asset
        relinked.libraryPath = FakeMediaLibrary.libraryPath(for: url, in: layout)
        relinked.offline = false
        byHash[asset.contentHash] = (relinked, url)
        return relinked
    }

    public func checkOffline(assets: [Asset]) -> Set<AssetID> {
        Set(assets.filter { !FileManager.default.fileExists(atPath: layout.url(for: $0).path) }.map(\.id))
    }

    // MARK: Helpers

    static func libraryPath(for url: URL, in layout: LibraryLayout) -> String {
        let root = layout.libraryDir.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    private func place(_ url: URL, mode: ImportMode) throws -> (URL, String) {
        if mode == .reference { return (url, url.standardizedFileURL.path) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let date = (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date) ?? Date()
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let folder = String(
            format: "%04d/%04d-%02d-%02d", components.year ?? 0, components.year ?? 0, components.month ?? 0,
            components.day ?? 0)
        let dir = layout.libraryDir.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var destination = dir.appendingPathComponent(url.lastPathComponent)
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            suffix += 1
            destination = dir.appendingPathComponent(
                "\(url.deletingPathExtension().lastPathComponent)-\(suffix)"
            ).appendingPathExtension(url.pathExtension)
        }
        switch mode {
        case .copy: try FileManager.default.copyItem(at: url, to: destination)
        case .move: try FileManager.default.moveItem(at: url, to: destination)
        case .reference: break
        }
        return (destination, FakeMediaLibrary.libraryPath(for: destination, in: layout))
    }

    struct Inspection {
        var kind: AssetKind
        var duration: RationalTime
        var hasVideo: Bool
        var hasAudio: Bool
        var sampleRate: Int?
        var frameDuration: RationalTime?
        var probe: Probe
    }

    static func inspect(_ url: URL) async throws -> Inspection {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let capturedAt = attributes?[.creationDate] as? Date
        let imageTypes: Set<String> = ["public.png", "public.jpeg", "public.heic", "public.tiff", "com.compuserve.gif"]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
            let type = CGImageSourceGetType(source) as String?, imageTypes.contains(type)
        {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            return Inspection(
                kind: .image, duration: RationalTime(10, 1), hasVideo: false, hasAudio: false,
                probe: Probe(
                    codec: type, width: props?[kCGImagePropertyPixelWidth] as? Int,
                    height: props?[kCGImagePropertyPixelHeight] as? Int, capturedAt: capturedAt))
        }
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw MediaError.unreadable(url, reason: error.localizedDescription)
        }
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard !video.isEmpty || !audio.isEmpty else {
            throw MediaError.unreadable(url, reason: "no audio or video tracks")
        }
        var probe = Probe(capturedAt: capturedAt)
        var frameDuration: RationalTime?
        var sampleRate: Int?
        if let track = video.first {
            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            let minFrame = try await track.load(.minFrameDuration)
            probe.width = Int(size.width)
            probe.height = Int(size.height)
            probe.fps = Rational(Int64((Double(fps) * 1000).rounded()), 1000)
            if minFrame.isNumeric, minFrame.value > 0 {
                frameDuration = RationalTime(minFrame.value, minFrame.timescale)
            }
            if let format = try await track.load(.formatDescriptions).first {
                probe.codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
                probe.colorPrimaries =
                    CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
                    as? String
                probe.transfer =
                    CMFormatDescriptionGetExtension(
                        format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
                    as? String
            }
        }
        if let track = audio.first, let format = try await track.load(.formatDescriptions).first {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                sampleRate = Int(asbd.pointee.mSampleRate)
                probe.extra["channels"] = .number(Double(asbd.pointee.mChannelsPerFrame))
            }
            if probe.codec == nil { probe.codec = fourCC(CMFormatDescriptionGetMediaSubType(format)) }
        }
        return Inspection(
            kind: video.isEmpty ? .audio : .video, duration: RationalTime(duration.value, duration.timescale),
            hasVideo: !video.isEmpty, hasAudio: !audio.isEmpty, sampleRate: sampleRate, frameDuration: frameDuration,
            probe: probe)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
