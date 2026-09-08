// TestMedia: synthetic media for tests, written with AVAssetWriter into a temp directory.
// See docs/design/implementation-plan.md (section 1, rule 3) and docs/design/conventions.md ("Media in tests").
//
// Every generator is `nonisolated async throws`, returns a `Clip` (file URL plus a `Description` carrying the
// requested parameters and whatever ground truth the generator knows), and finishes a few seconds of media in
// well under a second. Nothing here is ever checked in; callers own the files (see `Directory`).
import AVFoundation
import CoreGraphics
import Foundation

public enum TestMedia {
    // MARK: Value types

    /// An RGB colour with components in 0...1 (sRGB code values for SDR clips; see `VideoCodec.hevcHLG10`).
    public struct Color: Sendable, Hashable {
        public var r: Double
        public var g: Double
        public var b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        public init(_ rgb: (r: Double, g: Double, b: Double)) {
            self.init(r: rgb.r, g: rgb.g, b: rgb.b)
        }

        public static let black = Color(r: 0, g: 0, b: 0)
        public static let white = Color(r: 1, g: 1, b: 1)
        public static let red = Color(r: 1, g: 0, b: 0)
        public static let green = Color(r: 0, g: 1, b: 0)
        public static let blue = Color(r: 0, g: 0, b: 1)
        public static let gray = Color(r: 0.5, g: 0.5, b: 0.5)

        /// The colour as 8-bit sRGB code values, the same rounding a solid frame is painted with.
        public var rgb8: (r: Int, g: Int, b: Int) {
            (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
    }

    public enum VideoCodec: String, Sendable, Hashable, CaseIterable {
        case h264
        case hevc
        case proRes422
        /// 10-bit HEVC Main10 in a BT.2020 / HLG container. Source frames are painted in sRGB and colour
        /// converted by Core Image into `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` buffers tagged
        /// BT.2020 primaries, ITU-R 2100 HLG transfer, and BT.2020 matrix, so a solid sRGB red becomes the same
        /// red inside the HLG container. RenderKit uses this to test HDR passthrough.
        case hevcHLG10

        public var isHDR: Bool { self == .hevcHLG10 }
    }

    public enum AudioCodec: String, Sendable, Hashable, CaseIterable {
        /// 32-bit float linear PCM in a `.caf` (AVAssetWriter refuses float in `.wav`). Ground truth (click
        /// positions, tone phase) survives exactly.
        case pcm
        /// 16-bit integer linear PCM in a `.wav`, for consumers that want the common container.
        case pcm16
        /// AAC-LC at 128 kb/s in an `.m4a`. Lossy: expect priming delay and smeared transients.
        case aac

        public var isLossless: Bool { self != .aac }
    }

    /// What the alignment pair generator knows about the two files it wrote.
    public struct AlignmentTruth: Sendable, Equatable {
        /// Camera time (seconds) at which sample 0 of the render lands.
        public var offsetSeconds: Double
        /// Camera sample index (at the camera sample rate) of render sample 0.
        public var offsetSamples: Double
        /// Render clock drift in parts per million: the render was synthesised at `sampleRate * (1 + ppm * 1e-6)`
        /// but is labelled `sampleRate`, so a positive value means the render clock runs fast.
        public var driftPPM: Double
        /// Pink-noise SNR (dB) relative to the performance RMS in the camera track.
        public var snrDB: Double
        public var seed: UInt64
        public var cameraSampleRate: Double
        public var renderSampleRate: Double
    }

    /// Everything a generator knows about the file it wrote.
    public struct Description: Sendable, Equatable {
        /// Nominal duration in seconds. For video this is exactly `frameCount * frameDuration`.
        public var duration: Double
        public var hasVideo: Bool
        public var hasAudio: Bool
        public var size: CGSize?
        public var fps: Double?
        public var frameDuration: CMTime?
        public var frameCount: Int?
        public var videoCodec: VideoCodec?
        public var sampleRate: Double?
        public var channels: Int?
        public var audioCodec: AudioCodec?
        /// Whether every frame carries a `Barcode` strip with its own frame index.
        public var hasBarcode: Bool = false
        public var color: Color?
        /// Left-to-right bar colours of a colour-bars clip.
        public var bars: [Color] = []
        public var toneFrequency: Double?
        /// Requested click times in seconds.
        public var clickTimes: [Double] = []
        /// Exact sample index (at `sampleRate`) where each click's first, full-amplitude sample sits.
        public var clickSamples: [Int] = []
        public var alignment: AlignmentTruth?

        public init(duration: Double, hasVideo: Bool, hasAudio: Bool) {
            self.duration = duration
            self.hasVideo = hasVideo
            self.hasAudio = hasAudio
        }
    }

    /// A generated file and its description.
    public struct Clip: Sendable, Equatable {
        public var url: URL
        public var description: Description

        public init(url: URL, description: Description) {
            self.url = url
            self.description = description
        }
    }

    /// The camera-vs-render pair from `alignmentPair`.
    public struct AlignmentPair: Sendable, Equatable {
        public var camera: Clip
        public var render: Clip
        public var truth: AlignmentTruth
    }

    public enum Error: Swift.Error, Sendable, Equatable {
        case writerFailed(String)
        case pixelBufferUnavailable
        case sampleBufferFailed(Int32)
        case unsupportedParameters(String)
        case imageEncodingFailed
    }

    // MARK: Temp directory

    /// A unique directory under `FileManager.default.temporaryDirectory`, removed on `deinit` or `cleanup()`.
    public final class Directory: Sendable {
        public let url: URL

        public init(prefix: String = "TestMedia") throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            self.url = url
        }

        public func cleanup() {
            try? FileManager.default.removeItem(at: url)
        }

        /// A file URL inside the directory.
        public func file(_ name: String) -> URL { url.appendingPathComponent(name) }

        deinit { cleanup() }
    }

    /// Resolves the output URL for a generator: the caller's directory or a fresh unique one that is not
    /// cleaned up automatically (callers that care pass a `Directory`).
    static func outputURL(in directory: URL?, name: String?, defaultName: String, ext: String) throws -> URL {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("TestMedia-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let base = name ?? "\(defaultName)-\(UUID().uuidString.prefix(8))"
        let url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: url)
        return url
    }
}
