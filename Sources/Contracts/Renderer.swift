import AVFoundation
import CoreGraphics
import Foundation
import TimelineCore

// MARK: - Compiled

/// The owning module's private half of a `Compiled`: the `AVMutableComposition`,
/// `AVVideoComposition`, and `AVMutableAudioMix` (RenderKit), or whatever a fake keeps. Downcast inside
/// the module that created it; nothing else reads it. Conformers hold immutable values only: a
/// composition handed to a player is frozen (mutating it is silently ignored while paused and stalls
/// playback 0.4-1.6 s while playing, measured in spikes/preview-update).
public protocol CompiledPayload: Sendable {}

public enum CompiledTag: IDTag { public static let kind = "compiled" }
public typealias CompiledID = TypedID<CompiledTag>

/// An opaque, immutable render of one `Sequence` at one version. Value semantics: `update` returns a new
/// token, never mutates this one.
///
/// The two fingerprints are what `Renderer.update` diffs:
/// - `structuralFingerprint` covers the track segments (per track: source, source range, target start,
///   speed; transition overlaps count because they change segments). A change here needs a new
///   `AVPlayerItem`.
/// - `instructionFingerprint` covers everything else (transforms, opacity, effects, captions, transition
///   kind and params, audio gain and mutes). A change here is applied to the live item by replacing its
///   `videoComposition` and `audioMix`: measured 2 ms paused, one frame period (32 ms) playing.
public struct Compiled: Sendable, Identifiable {
    public var id: CompiledID
    public var sequenceId: SequenceID
    public var structuralFingerprint: String
    public var instructionFingerprint: String
    public var duration: RationalTime
    public var hasAudio: Bool
    public var options: RenderOptions
    public var payload: any CompiledPayload

    public init(
        id: CompiledID = CompiledID(minting: UUIDv7Generator()), sequenceId: SequenceID, structuralFingerprint: String,
        instructionFingerprint: String, duration: RationalTime, hasAudio: Bool, options: RenderOptions,
        payload: any CompiledPayload
    ) {
        self.id = id
        self.sequenceId = sequenceId
        self.structuralFingerprint = structuralFingerprint
        self.instructionFingerprint = instructionFingerprint
        self.duration = duration
        self.hasAudio = hasAudio
        self.options = options
        self.payload = payload
    }
}

public enum RenderQuality: String, Codable, Sendable, Hashable, CaseIterable {
    /// Fast path for the viewer: proxies allowed, reduced render scale.
    case preview
    /// Full resolution, what export and frame grabs use.
    case full
}

public struct RenderOptions: Hashable, Sendable, Codable {
    /// False builds a video-only composition. A 200-clip video-only item reaches `readyToPlay` in 2-4 ms
    /// versus 15-25 ms (fast regime) or 340-590 ms (slow regime) with two AAC tracks, so gestures
    /// compile without audio and the audio-bearing item is swapped in on gesture end.
    public var audio: Bool
    public var quality: RenderQuality
    /// Overrides `ProjectSettings.blendSpace` when set (gamma is the product default; linear is
    /// Core Image's native behaviour and reads (188,188,0) for a red-green dissolve midpoint).
    public var blendSpace: BlendSpace?

    public init(audio: Bool = true, quality: RenderQuality = .preview, blendSpace: BlendSpace? = nil) {
        self.audio = audio
        self.quality = quality
        self.blendSpace = blendSpace
    }

    public static let preview = RenderOptions()
    public static let gesture = RenderOptions(audio: false, quality: .preview)
    public static let full = RenderOptions(audio: true, quality: .full)
}

/// What `Renderer.update` decided.
public enum RenderUpdate: Sendable {
    /// Segments unchanged: call `Renderer.apply(_:to:)` on the live player item.
    case instructionsOnly(Compiled)
    /// Segments changed: build a new player item with `Renderer.playerItem(for:)`, seek it while
    /// detached, then `replaceCurrentItem` (or switch to a second `AVPlayer` while playing).
    case structural(Compiled)

    public var compiled: Compiled {
        switch self {
        case .instructionsOnly(let c), .structural(let c): c
        }
    }

    public var isStructural: Bool {
        if case .structural = self { return true }
        return false
    }
}

// MARK: - Export preset

/// A Codable description of an export so render receipts are stable across versions.
public struct ExportPreset: Hashable, Sendable, Codable {
    public enum Container: String, Codable, Sendable, Hashable, CaseIterable {
        case mp4
        case mov
    }

    public enum VideoCodec: String, Codable, Sendable, Hashable, CaseIterable {
        case h264
        case hevc
        /// HEVC Main10 in BT.2020/HLG; the codec for all-HDR sources per the platform decisions.
        case hevcHLG10
        case proRes422
        case proRes4444
    }

    public enum AudioCodec: String, Codable, Sendable, Hashable, CaseIterable {
        case aac
        case alac
        case pcm
    }

    public enum OutputSize: Hashable, Sendable, Codable {
        case matchSequence
        case fixed(width: Int, height: Int)
    }

    public enum FrameRatePolicy: Hashable, Sendable, Codable {
        case matchSequence
        /// Fixes `videoComposition.frameDuration`; variable-rate sources are conformed.
        case fixed(Rational)
    }

    public enum VideoQuality: Hashable, Sendable, Codable {
        case bitrate(bitsPerSecond: Int)
        /// 0...1, mapped onto the encoder's quality key.
        case quality(Double)
    }

    public enum HDRPolicy: String, Codable, Sendable, Hashable, CaseIterable {
        /// HLG in, HLG out when every source is HDR, else tone-mapped SDR.
        case auto
        case preserve
        case toneMapToSDR
    }

    public var name: String
    public var container: Container
    public var videoCodec: VideoCodec
    public var size: OutputSize
    public var frameRate: FrameRatePolicy
    public var videoQuality: VideoQuality
    public var audioCodec: AudioCodec
    public var audioBitrate: Int?
    /// Normalisation target; social presets use -14 LUFS.
    public var loudnessTargetLUFS: Double?
    public var hdr: HDRPolicy

    public init(
        name: String, container: Container, videoCodec: VideoCodec, size: OutputSize = .matchSequence,
        frameRate: FrameRatePolicy = .matchSequence, videoQuality: VideoQuality, audioCodec: AudioCodec = .aac,
        audioBitrate: Int? = 192_000, loudnessTargetLUFS: Double? = nil, hdr: HDRPolicy = .auto
    ) {
        self.name = name
        self.container = container
        self.videoCodec = videoCodec
        self.size = size
        self.frameRate = frameRate
        self.videoQuality = videoQuality
        self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate
        self.loudnessTargetLUFS = loudnessTargetLUFS
        self.hdr = hdr
    }

    public var fileExtension: String { container.rawValue }

    public static let hevcHLG4K = ExportPreset(
        name: "HEVC HLG 4K", container: .mov, videoCodec: .hevcHLG10, size: .fixed(width: 3840, height: 2160),
        videoQuality: .bitrate(bitsPerSecond: 60_000_000), hdr: .preserve)

    public static let h264_1080p = ExportPreset(
        name: "H.264 1080p", container: .mp4, videoCodec: .h264, size: .fixed(width: 1920, height: 1080),
        videoQuality: .bitrate(bitsPerSecond: 12_000_000), hdr: .toneMapToSDR)

    /// Vertical social reel: 1080x1920, -14 LUFS.
    public static let reel9x16 = ExportPreset(
        name: "Reel 9:16", container: .mp4, videoCodec: .h264, size: .fixed(width: 1080, height: 1920),
        videoQuality: .bitrate(bitsPerSecond: 10_000_000), loudnessTargetLUFS: -14, hdr: .toneMapToSDR)

    public static let proRes = ExportPreset(
        name: "ProRes 422", container: .mov, videoCodec: .proRes422, videoQuality: .quality(1), audioCodec: .pcm,
        audioBitrate: nil, hdr: .preserve)

    public static let builtIn: [ExportPreset] = [.hevcHLG4K, .h264_1080p, .reel9x16, .proRes]
}

/// Written next to every export (`renders/<name>.json`) and returned as the export job's payload.
public struct ExportReceipt: Hashable, Sendable, Codable {
    public var preset: ExportPreset
    public var sequenceId: SequenceID
    public var projectVersion: Int64?
    public var outputURL: URL
    public var durationSeconds: Double
    public var startedAt: Date
    public var finishedAt: Date
    public var warnings: [String]
    /// `FileHash.sha256(of: outputURL)` ("sha256-<64 hex>"), what the render ledger stores and a publish
    /// verifies against. Nil in receipts written before the ledger existed.
    public var outputHash: String?

    public init(
        preset: ExportPreset, sequenceId: SequenceID, projectVersion: Int64?, outputURL: URL, durationSeconds: Double,
        startedAt: Date, finishedAt: Date, warnings: [String] = [], outputHash: String? = nil
    ) {
        self.preset = preset
        self.sequenceId = sequenceId
        self.projectVersion = projectVersion
        self.outputURL = outputURL
        self.durationSeconds = durationSeconds
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.warnings = warnings
        self.outputHash = outputHash
    }
}

public enum RenderError: Error, Hashable, Sendable, Codable {
    case sequenceEmpty
    case assetOffline(AssetID)
    case unsupported(String)
    case failed(String)
}

// MARK: - Protocol

/// Sequence to AVFoundation. Pure work (`compile`, `update`, `frame`, `export`) is `nonisolated async`;
/// anything that touches an `AVPlayerItem` is `@MainActor` because the player and its layer live there.
///
/// Contract, from timeline-model.md section 9 and spikes/preview-update:
/// - `compile` never writes to the model and never throws for an offline asset: it substitutes a slate.
/// - Compositions handed to a player are frozen. `update` diffs `compiled.structuralFingerprint` against
///   the new sequence: equal means `.instructionsOnly` (apply to the live item), different means
///   `.structural` (new item). The returned `Compiled` is complete either way.
/// - `playerItem(for:)` sets `seekingWaitsForVideoCompositionRendering`. Seek the item before attaching
///   it (0 ms detached versus 23-266 ms attached while playing). An item binds to one `AVPlayer` for life.
/// - `frame` keeps its `AVAssetImageGenerator` alive for the whole request (a temporary never completes)
///   and requests zero tolerance. First composed grab 64-133 ms cold, 15-45 ms after.
/// - `export` returns a `Job` (kind `.export`, class `.medium`) whose outcome carries the file and an
///   `ExportReceipt`; the export itself is `AVAssetExportSession.export(to:as:)`.
public protocol Renderer: Sendable {
    func compile(_ sequence: Sequence, assets: [AssetID: Asset], options: RenderOptions) async throws -> Compiled

    func update(_ compiled: Compiled, to sequence: Sequence, assets: [AssetID: Asset]) async throws -> RenderUpdate

    /// A new player item over `compiled`; the caller owns it and attaches it to exactly one player.
    @MainActor func playerItem(for compiled: Compiled) -> AVPlayerItem

    /// Replaces `videoComposition` and `audioMix` on a live item for an instructions-only update. The item
    /// must have been made from a `Compiled` with the same `structuralFingerprint`.
    @MainActor func apply(_ compiled: Compiled, to item: AVPlayerItem)

    /// One composed frame at `time`, at `size` (nil: the sequence size).
    func frame(_ compiled: Compiled, at time: RationalTime, size: CGSize?) async throws -> CGImage

    /// An export job writing `preset` to `url` (overwritten). Submit it to the `JobRunner`.
    func export(_ compiled: Compiled, preset: ExportPreset, to url: URL) -> Job
}
