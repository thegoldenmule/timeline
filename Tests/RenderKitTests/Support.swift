import AVFoundation
import Contracts
import ContractsTestSupport
import CoreGraphics
import CoreVideo
import Foundation
import RenderKit
import Testing
import TimelineCore

/// 8-bit BGRA code values of an image or pixel buffer, with region means in top-left coordinates. An 8-bit
/// image is read in its own colour space (AVFoundation tags composed frames BT.709), so values are the
/// compositor's code values, not a display conversion; HDR images are converted to sRGB.
struct Pixels {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(_ image: CGImage) {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let own = image.colorSpace.flatMap { $0.model == .rgb && image.bitsPerComponent == 8 ? $0 : nil }
        buffer.withUnsafeMutableBytes { p in
            guard
                let ctx = CGContext(
                    data: p.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: own ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        data = buffer
    }

    init(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        self.width = width
        self.height = height
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let src = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                out.withUnsafeMutableBytes { p in
                    p.baseAddress!.advanced(by: y * width * 4).copyMemory(
                        from: src.advanced(by: y * stride), byteCount: width * 4)
                }
            }
        }
        data = out
    }

    /// (r, g, b) at a top-left pixel coordinate.
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let o = (y * width + x) * 4
        return (Int(data[o + 2]), Int(data[o + 1]), Int(data[o]))
    }

    /// Mean (r, g, b) over a top-left rect.
    func mean(_ rect: CGRect) -> (Int, Int, Int) {
        let x0 = max(0, Int(rect.minX))
        let y0 = max(0, Int(rect.minY))
        let x1 = min(width, Int(rect.maxX))
        let y1 = min(height, Int(rect.maxY))
        var r = 0
        var g = 0
        var b = 0
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let o = (y * width + x) * 4
                b += Int(data[o])
                g += Int(data[o + 1])
                r += Int(data[o + 2])
                n += 1
            }
        }
        guard n > 0 else { return (0, 0, 0) }
        return (r / n, g / n, b / n)
    }

    /// The centre of the frame, avoiding the barcode strip (top 1/24) and the caption band (bottom 20%).
    var centerRect: CGRect {
        CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 3)
    }

    var frameIndex: Int? {
        guard let image = cgImage else { return nil }
        return TestMedia.decodeFrameIndex(from: image)
    }

    var cgImage: CGImage? {
        data.withUnsafeBytes { p -> CGImage? in
            guard
                let ctx = CGContext(
                    data: UnsafeMutableRawPointer(mutating: p.baseAddress), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }
}

func near(_ c: (Int, Int, Int), _ e: (Int, Int, Int), tolerance: Int) -> Bool {
    abs(c.0 - e.0) <= tolerance && abs(c.1 - e.1) <= tolerance && abs(c.2 - e.2) <= tolerance
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return .nan }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func fmt(_ x: Double) -> String { String(format: "%.1f", x) }

/// `true` in `swift test -c release`.
let isReleaseBuild: Bool = {
    #if DEBUG
        return false
    #else
        return true
    #endif
}()

/// Debug builds assert loose bounds (the plan's numbers times this); release runs report the real numbers.
let debugSlack: Double = isReleaseBuild ? 1 : 4

@MainActor
func waitUntilReady(_ item: AVPlayerItem, timeout: Duration = .seconds(20)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while item.status == .unknown, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return item.status == .readyToPlay
}

/// Resident memory of this process in bytes (`mach_task_basic_info.resident_size`).
func residentMemory() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

/// A temporary library root whose `Library/2026/2026-09-08/` holds the files the fixture and generated
/// projects reference, generated once per process with `TestMedia`.
final class FixtureLibrary: Sendable {
    let directory: TestMedia.Directory
    let layout: LibraryLayout
    let clips: [String: TestMedia.Clip]

    static let frameDuration = CMTime(value: 1001, timescale: 24000)
    static let folder = "2026/2026-09-08"

    private init(directory: TestMedia.Directory, layout: LibraryLayout, clips: [String: TestMedia.Clip]) {
        self.directory = directory
        self.layout = layout
        self.clips = clips
    }

    private static let shared = Task<FixtureLibrary, any Error> { try await make() }

    static func get() async throws -> FixtureLibrary { try await shared.value }

    var mediaDirectory: URL { layout.libraryDir.appendingPathComponent(FixtureLibrary.folder, isDirectory: true) }

    /// Writes `name` into the library folder and returns the asset's `libraryPath`.
    func path(_ name: String) -> String { "\(FixtureLibrary.folder)/\(name)" }

    private static func make() async throws -> FixtureLibrary {
        let directory = try TestMedia.Directory(prefix: "RenderKitLibrary")
        let layout = LibraryLayout(root: directory.url)
        let media = layout.libraryDir.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var clips: [String: TestMedia.Clip] = [:]
        // three-clips: IMG_1575.MOV (720 frames, A/V), Screen Recording.mov (480 frames, video only),
        // band-mix-v3.wav (120 s). linked-transition: IMG_1581.MOV (600 frames, A/V). The A/V files are muxed
        // here from a video-only clip and a tone: `TestMedia.videoWithAudio` stalls past a few seconds.
        let scratch = directory.url.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        clips["IMG_1575.MOV"] = try await muxed(
            video: try await TestMedia.barcodeCounter(
                background: .red, size: CGSize(width: 640, height: 360), frameDuration: frameDuration,
                duration: 720 * frameDuration.seconds, in: scratch, name: "cam-v"),
            audio: try await TestMedia.tone(
                frequency: 440, duration: 720 * frameDuration.seconds, codec: .aac, in: scratch, name: "cam-a"),
            to: media.appendingPathComponent("IMG_1575.MOV"))
        clips["Screen Recording.mov"] = try await TestMedia.barcodeCounter(
            background: .green, size: CGSize(width: 640, height: 360), frameDuration: frameDuration,
            duration: 480 * frameDuration.seconds, in: media, name: "Screen Recording")
        clips["band-mix-v3.wav"] = try await TestMedia.tone(
            frequency: 220, duration: 120, channels: 2, codec: .pcm16, in: media, name: "band-mix-v3")
        clips["IMG_1581.MOV"] = try await muxed(
            video: try await TestMedia.barcodeCounter(
                background: .blue, size: CGSize(width: 640, height: 360), frameDuration: frameDuration,
                duration: 600 * frameDuration.seconds, in: scratch, name: "cam2-v"),
            audio: try await TestMedia.tone(
                frequency: 880, duration: 600 * frameDuration.seconds, codec: .aac, in: scratch, name: "cam2-a"),
            to: media.appendingPathComponent("IMG_1581.MOV"))
        return FixtureLibrary(directory: directory, layout: layout, clips: clips)
    }
}

/// Muxes a video-only clip and an audio clip into one QuickTime file with a passthrough export.
func muxed(video: TestMedia.Clip, audio: TestMedia.Clip, to url: URL) async throws -> TestMedia.Clip {
    let composition = AVMutableComposition()
    let v = AVURLAsset(url: video.url)
    let a = AVURLAsset(url: audio.url)
    let videoTrack = try #require(try await v.loadTracks(withMediaType: .video).first)
    let audioTrack = try #require(try await a.loadTracks(withMediaType: .audio).first)
    let duration = try await v.load(.duration)
    let cv = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1))
    let ca = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2))
    try cv.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
    try ca.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
    let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
    try? FileManager.default.removeItem(at: url)
    try await session.export(to: url, as: .mov)
    var description = video.description
    description.hasAudio = true
    description.sampleRate = audio.description.sampleRate
    description.channels = audio.description.channels
    description.audioCodec = audio.description.audioCodec
    description.toneFrequency = audio.description.toneFrequency
    return TestMedia.Clip(url: url, description: description)
}

/// A scratch library root for tests that write their own media.
struct ScratchLibrary {
    let directory: TestMedia.Directory
    let layout: LibraryLayout
    var media: URL { layout.libraryDir.appendingPathComponent(FixtureLibrary.folder, isDirectory: true) }

    init(prefix: String) throws {
        directory = try TestMedia.Directory(prefix: prefix)
        layout = LibraryLayout(root: directory.url)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String { "\(FixtureLibrary.folder)/\(name)" }
}

extension ProjectBuilder {
    /// Imports `clip` as an asset whose `libraryPath` is `folder/name`, with a duration from the description.
    @discardableResult
    func importClip(
        _ clip: TestMedia.Clip, name: String? = nil, frameDuration: RationalTime = RationalTime(1001, 24000)
    ) throws(EditorError) -> AssetID {
        let d = clip.description
        let duration: RationalTime
        if let frames = d.frameCount, let fd = d.frameDuration {
            duration = RationalTime(Int64(frames) * fd.value, fd.timescale)
        } else {
            duration = RationalTime(seconds: d.duration, timescale: 48000)
        }
        return try importAsset(
            name: name ?? clip.url.lastPathComponent, duration: duration, hasVideo: d.hasVideo, hasAudio: d.hasAudio,
            sampleRate: d.hasAudio ? Int(d.sampleRate ?? 48000) : nil,
            frameDuration: d.hasVideo ? (d.frameDuration.map { RationalTime($0) } ?? frameDuration) : nil)
    }
}
