import AVFoundation
import Contracts
import CoreGraphics
import CoreImage
import Foundation
import Synchronization
import TimelineCore

/// Filmstrip frames from content-addressed sprite sheets. A request picks a frame rate from `fpsLadder` (the
/// smallest at or above the requested density) and a tile height from `tileHeights`; the sheet for that
/// `(fps, height)` and time chunk is generated once (`thumbs/sheet-<fps>fps-h<height>-<chunk>.jpg`, recorded as a
/// `thumbnails` artifact) and sliced for every later request, with decoded sheets memoised in memory. The
/// `AVAssetImageGenerator` per file stays alive across requests because creating one is the expensive part.
public final class AVThumbnailProvider: ThumbnailProvider, Sendable {
    public struct Configuration: Hashable, Sendable, Codable {
        /// Tiles per second of media, ascending.
        public var fpsLadder: [Double]
        /// Tile heights in pixels, ascending.
        public var tileHeights: [Int]
        public var tilesPerSheet: Int
        public var columns: Int
        public var jpegQuality: Double

        public init(
            fpsLadder: [Double] = [0.1, 1, 4], tileHeights: [Int] = [64, 128, 256], tilesPerSheet: Int = 256,
            columns: Int = 16, jpegQuality: Double = 0.8
        ) {
            self.fpsLadder = fpsLadder.sorted()
            self.tileHeights = tileHeights.sorted()
            self.tilesPerSheet = tilesPerSheet
            self.columns = columns
            self.jpegQuality = jpegQuality
        }
    }

    /// Sheet metadata written next to each JPEG and stored as the artifact summary.
    struct SheetInfo: Hashable, Sendable, Codable {
        var fps: Double
        var tileHeight: Int
        var tileWidth: Int
        var chunk: Int
        var firstTile: Int
        var count: Int
        var columns: Int
    }

    struct SheetParameters: Hashable, Sendable, Codable {
        var fps: Double
        var tileHeight: Int
        var tilesPerSheet: Int
        var columns: Int
        var jpegQuality: Double
        var chunk: Int
    }

    public static let version = 1

    public let cache: CacheIndex
    public let configuration: Configuration
    private let clock: any Clock
    private let generators = GeneratorPool()
    private let sheets = Mutex<[String: Sheet]>([:])
    private let sheetLimit = 24
    private let stats = Mutex<Stats>(Stats())

    public struct Stats: Sendable, Hashable {
        public var sheetsGenerated = 0
        public var sheetsLoaded = 0
        public var sheetsMemoized = 0
    }

    struct Sheet: Sendable {
        var info: SheetInfo
        var image: CGImage
    }

    public init(cache: CacheIndex, configuration: Configuration = Configuration(), clock: any Clock = SystemClock()) {
        self.cache = cache
        self.configuration = configuration
        self.clock = clock
    }

    /// Cache hit and generation counters, for tests and telemetry.
    public var statistics: Stats { stats.withLock { $0 } }

    // MARK: ThumbnailProvider

    public func filmstrip(for media: MediaReference, range: ClosedRange<RationalTime>, count: Int, height: Int)
        async throws -> [Thumbnail]
    {
        guard count > 0 else { return [] }
        let span = range.upperBound - range.lowerBound
        let times: [RationalTime] = (0..<count).map { i in
            count > 1 ? range.lowerBound + span * Int64(i) / Int64(count - 1) : range.lowerBound
        }
        let requestedFps = span.isPositive ? Double(count) / span.seconds : configuration.fpsLadder.last ?? 1
        let fps = configuration.fpsLadder.first { $0 >= requestedFps } ?? configuration.fpsLadder.last ?? 1
        let tileHeight = configuration.tileHeights.first { $0 >= height } ?? configuration.tileHeights.last ?? height

        var result: [Thumbnail] = []
        result.reserveCapacity(count)
        for time in times {
            try Task.checkCancellation()
            let tile = Int((time.seconds * fps).rounded(.down))
            let chunk = tile / configuration.tilesPerSheet
            let sheet = try await self.sheet(for: media, fps: fps, tileHeight: tileHeight, chunk: chunk)
            let local = min(max(tile - sheet.info.firstTile, 0), sheet.info.count - 1)
            guard local >= 0, sheet.info.count > 0 else { continue }
            let column = local % sheet.info.columns
            let row = local / sheet.info.columns
            let rect = CGRect(
                x: column * sheet.info.tileWidth, y: row * sheet.info.tileHeight, width: sheet.info.tileWidth,
                height: sheet.info.tileHeight)
            guard let cropped = sheet.image.cropping(to: rect) else { continue }
            let image =
                height == sheet.info.tileHeight ? cropped : AVThumbnailProvider.scaled(cropped, toHeight: height)
            result.append(Thumbnail(time: time, image: image))
        }
        return result
    }

    // MARK: Sheets

    private func sheetName(fps: Double, tileHeight: Int, chunk: Int) -> String {
        let fpsText = fps == fps.rounded() ? String(Int(fps)) : String(fps)
        return "thumbs/sheet-\(fpsText)fps-h\(tileHeight)-\(String(format: "%03d", chunk))"
    }

    private func sheet(for media: MediaReference, fps: Double, tileHeight: Int, chunk: Int) async throws -> Sheet {
        let name = sheetName(fps: fps, tileHeight: tileHeight, chunk: chunk)
        let memoKey = media.contentHash + "/" + name
        if let cached = sheets.withLock({ $0[memoKey] }) {
            stats.withLock { $0.sheetsMemoized += 1 }
            return cached
        }
        let parameters = SheetParameters(
            fps: fps, tileHeight: tileHeight, tilesPerSheet: configuration.tilesPerSheet,
            columns: configuration.columns,
            jpegQuality: configuration.jpegQuality, chunk: chunk)
        let paramsHash = try MediaKit.paramsHash(version: AVThumbnailProvider.version, parameters: parameters)
        if let record = try cache.artifact(contentHash: media.contentHash, kind: .thumbnails, paramsHash: paramsHash),
            let loaded = try? load(record)
        {
            stats.withLock { $0.sheetsLoaded += 1 }
            remember(memoKey, loaded)
            return loaded
        }
        let generated = try await generate(
            media, fps: fps, tileHeight: tileHeight, chunk: chunk, name: name, paramsHash: paramsHash)
        stats.withLock { $0.sheetsGenerated += 1 }
        remember(memoKey, generated)
        return generated
    }

    private func remember(_ key: String, _ sheet: Sheet) {
        sheets.withLock { memo in
            if memo.count >= sheetLimit, let victim = memo.keys.first { memo.removeValue(forKey: victim) }
            memo[key] = sheet
        }
    }

    private func load(_ record: ArtifactRecord) throws -> Sheet? {
        let url = cache.url(for: record)
        let infoURL = url.deletingPathExtension().appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: infoURL.path)
        else { return nil }
        let info = try JSONDecoder().decode(SheetInfo.self, from: Data(contentsOf: infoURL))
        guard let ci = CIImage(contentsOf: url),
            let image = AVThumbnailProvider.context.createCGImage(ci, from: ci.extent)
        else { return nil }
        return Sheet(info: info, image: image)
    }

    private func generate(
        _ media: MediaReference, fps: Double, tileHeight: Int, chunk: Int, name: String, paramsHash: String
    ) async throws -> Sheet {
        let asset = AVURLAsset(url: media.url)
        let duration = try await asset.load(.duration)
        let totalTiles = max(1, Int((duration.seconds * fps).rounded(.up)))
        let firstTile = chunk * configuration.tilesPerSheet
        let count = min(configuration.tilesPerSheet, totalTiles - firstTile)
        guard count > 0 else { throw AnalysisError.failed("time beyond the end of the media") }
        let times = (0..<count).map { i -> CMTime in
            let seconds = Double(firstTile + i) / fps
            return CMTime(seconds: min(seconds, max(0, duration.seconds - 0.001)), preferredTimescale: 600)
        }
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        let frames = try await generators.frames(
            for: media.url, times: times, maxHeight: tileHeight, tolerance: tolerance)
        try Task.checkCancellation()
        guard let firstImage = frames.first(where: { $0 != nil }) ?? nil else {
            throw AnalysisError.noVideoTrack
        }
        let tileWidth = max(
            1, Int((Double(firstImage.width) * Double(tileHeight) / Double(firstImage.height)).rounded()))
        let columns = min(configuration.columns, count)
        let rows = (count + columns - 1) / columns
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let ctx = CGContext(
                data: nil, width: tileWidth * columns, height: tileHeight * rows, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { throw AnalysisError.failed("could not allocate sheet") }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.interpolationQuality = .high
        for (i, frame) in frames.enumerated() {
            guard let frame else { continue }
            let column = i % columns
            let row = i / columns
            // CGContext's origin is bottom-left; tiles are laid out top-down like the slicing rects expect.
            let rect = CGRect(
                x: column * tileWidth, y: ctx.height - (row + 1) * tileHeight, width: tileWidth, height: tileHeight)
            ctx.draw(frame, in: rect)
        }
        guard let image = ctx.makeImage() else { throw AnalysisError.failed("could not render sheet") }
        let info = SheetInfo(
            fps: fps, tileHeight: tileHeight, tileWidth: tileWidth, chunk: chunk, firstTile: firstTile, count: count,
            columns: columns)

        let dir = cache.layout.artifactDir(contentHash: media.contentHash).appendingPathComponent(
            "thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jpegURL = cache.layout.artifactDir(contentHash: media.contentHash).appendingPathComponent(name + ".jpg")
        let infoURL = cache.layout.artifactDir(contentHash: media.contentHash).appendingPathComponent(name + ".json")
        try AVThumbnailProvider.context.writeJPEGRepresentation(
            of: CIImage(cgImage: image), to: jpegURL, colorSpace: colorSpace,
            options: [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: configuration.jpegQuality
            ])
        try JSONEncoder().encode(info).write(to: infoURL, options: .atomic)
        let now = clock.now()
        try cache.ensureMedia(contentHash: media.contentHash, url: media.url, now: now)
        try cache.recordArtifact(
            contentHash: media.contentHash, kind: .thumbnails, paramsHash: paramsHash,
            path: cache.artifactPath(contentHash: media.contentHash, name: name + ".jpg"),
            summary: try? JSONValue(encoding: info), now: now)
        return Sheet(info: info, image: image)
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func scaled(_ image: CGImage, toHeight height: Int) -> CGImage {
        let width = max(1, Int((Double(image.width) * Double(height) / Double(image.height)).rounded()))
        guard
            let ctx = CGContext(
                data: nil, width: width, height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }
}

/// Owns one `AVAssetImageGenerator` per file (non-Sendable, so it lives inside this actor) and keeps the most
/// recently used ones alive.
actor GeneratorPool {
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var order: [URL] = []
    private let limit = 8

    func frames(for url: URL, times: [CMTime], maxHeight: Int, tolerance: CMTime) async throws -> [CGImage?] {
        let generator = self.generator(for: url)
        generator.maximumSize = CGSize(width: maxHeight * 8, height: maxHeight)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var out = [CGImage?](repeating: nil, count: times.count)
        var index = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            switch result {
            case .success(requestedTime: _, image: let image, actualTime: _):
                if index < out.count { out[index] = image }
            case .failure(requestedTime: _, error: let error):
                if index == 0 && times.count == 1 { throw AnalysisError.failed(error.localizedDescription) }
            @unknown default: break
            }
            index += 1
        }
        return out
    }

    private func generator(for url: URL) -> AVAssetImageGenerator {
        if let existing = generators[url] {
            order.removeAll { $0 == url }
            order.append(url)
            return existing
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generators[url] = generator
        order.append(url)
        while order.count > limit, let victim = order.first {
            order.removeFirst()
            generators.removeValue(forKey: victim)
        }
        return generator
    }
}
