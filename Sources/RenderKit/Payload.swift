import AVFoundation
import Contracts
import CoreMedia
import Foundation
import TimelineCore

/// One segment of a composition track, as placed by the compiler. RationalTime throughout so tests compare
/// exactly.
public struct SegmentInfo: Sendable, Hashable {
    public var clipId: ClipID?
    /// Nil for the filler (slates, generated clips, stills, the duration pin).
    public var sourceURL: URL?
    public var sourceTrackID: CMPersistentTrackID?
    public var sourceRange: TimeRange
    public var targetRange: TimeRange
    public var speed: Rational
    public var isFiller: Bool

    public init(
        clipId: ClipID?, sourceURL: URL?, sourceTrackID: CMPersistentTrackID?, sourceRange: TimeRange,
        targetRange: TimeRange, speed: Rational, isFiller: Bool
    ) {
        self.clipId = clipId
        self.sourceURL = sourceURL
        self.sourceTrackID = sourceTrackID
        self.sourceRange = sourceRange
        self.targetRange = targetRange
        self.speed = speed
        self.isFiller = isFiller
    }
}

/// One composition track and its segments.
public struct CompositionTrackInfo: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable {
        case video
        case audio
        /// The black track that pins the composition duration to the sequence duration.
        case filler
    }

    public var trackID: CMPersistentTrackID
    public var role: Role
    /// The model track this composition track serves (nil for the filler).
    public var modelTrackId: TrackID?
    /// 0 = A, 1 = B for the alternating pair; dedicated speed tracks count up from 2.
    public var slot: Int
    public var segments: [SegmentInfo]
}

/// Where a video clip landed: which composition track, over which (transition-extended) timeline range.
struct VideoPlacement: Sendable {
    var clipId: ClipID
    var trackIndex: Int
    var compositionTrackID: CMPersistentTrackID
    var range: CMTimeRange
    var content: LayerContent
    var source: MediaSource?
}

struct AudioPlacement: Sendable {
    var clipId: ClipID
    var compositionTrackID: CMPersistentTrackID
    var range: CMTimeRange
    var fadeIn: CMTimeRange?
    var fadeOut: CMTimeRange?
}

/// The frozen half of a compile: the composition and everything derived from clip placement. An
/// instructions-only update reuses it untouched.
final class CompositionStructure: @unchecked Sendable {
    /// Immutable copy of the mutable composition the compiler built; never handed out mutable.
    let composition: AVComposition
    let tracks: [CompositionTrackInfo]
    let videoPlacements: [ClipID: VideoPlacement]
    let audioPlacements: [ClipID: AudioPlacement]
    let duration: CMTime
    let hdr: Bool
    let hasAudio: Bool
    let offlineAssets: [Asset]
    /// Keeps every `AVURLAsset` behind the composition alive.
    let sources: [AssetID: MediaSource]
    let filler: MediaSource

    init(
        composition: AVComposition, tracks: [CompositionTrackInfo], videoPlacements: [ClipID: VideoPlacement],
        audioPlacements: [ClipID: AudioPlacement], duration: CMTime, hdr: Bool, hasAudio: Bool,
        offlineAssets: [Asset], sources: [AssetID: MediaSource], filler: MediaSource
    ) {
        self.composition = composition
        self.tracks = tracks
        self.videoPlacements = videoPlacements
        self.audioPlacements = audioPlacements
        self.duration = duration
        self.hdr = hdr
        self.hasAudio = hasAudio
        self.offlineAssets = offlineAssets
        self.sources = sources
        self.filler = filler
    }
}

/// RenderKit's `Compiled.payload`: the composition, the video composition built from
/// `AVVideoComposition.Configuration`, the audio mix, the instruction table, and the inputs. Every reference
/// here is immutable; `AVVideoComposition` and `AVAudioMix` are the immutable classes, the composition is an
/// immutable copy.
public final class RenderPayload: CompiledPayload, @unchecked Sendable {
    let structure: CompositionStructure
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
    public let instructions: InstructionTable
    public let blendSpace: BlendSpace
    public let renderSize: CGSize
    public let frameDuration: CMTime
    public let sequence: Sequence
    public let assets: [AssetID: Asset]
    public let options: RenderOptions

    init(
        structure: CompositionStructure, videoComposition: AVVideoComposition, audioMix: AVAudioMix?,
        instructions: InstructionTable, blendSpace: BlendSpace, renderSize: CGSize, frameDuration: CMTime,
        sequence: Sequence, assets: [AssetID: Asset], options: RenderOptions
    ) {
        self.structure = structure
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.instructions = instructions
        self.blendSpace = blendSpace
        self.renderSize = renderSize
        self.frameDuration = frameDuration
        self.sequence = sequence
        self.assets = assets
        self.options = options
    }

    /// The frozen composition. Read-only by type: never cast it back to a mutable one.
    public var composition: AVComposition { structure.composition }
    public var tracks: [CompositionTrackInfo] { structure.tracks }
    public var duration: CMTime { structure.duration }
    /// True when every online video source is HDR: the composition is 10-bit HLG end to end.
    public var isHDR: Bool { structure.hdr }
    public var hasAudio: Bool { structure.hasAudio }
    public var offlineAssets: [Asset] { structure.offlineAssets }
    /// The loaded source for an asset, when it is online and referenced.
    public func source(for assetId: AssetID) -> MediaSource? { structure.sources[assetId] }

    public var videoTracks: [CompositionTrackInfo] { tracks.filter { $0.role == .video } }
    public var audioTracks: [CompositionTrackInfo] { tracks.filter { $0.role == .audio } }
}

extension Compiled {
    /// The RenderKit payload, or nil for a `Compiled` from another renderer.
    public var renderPayload: RenderPayload? { payload as? RenderPayload }
}
