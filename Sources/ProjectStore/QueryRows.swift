import Contracts
import Foundation
import GRDB
import TimelineCore

// The query tables of storage.md section 5, as GRDB records. Every row is a pure function of one model
// entity (plus, for tracks, its index in the sequence), which is what lets rebuild write them in bulk
// from the final state and match the incrementally maintained rows exactly.

/// A row of `assets`.
public struct AssetRow: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "assets"

    public var assetId: String
    public var contentHash: String
    public var kind: String
    public var libraryPath: String
    public var displayName: String
    public var durationV: Int64
    public var durationTs: Int32
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var offline: Bool
    public var probe: String?

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case contentHash = "content_hash"
        case kind
        case libraryPath = "library_path"
        case displayName = "display_name"
        case durationV = "duration_v"
        case durationTs = "duration_ts"
        case hasVideo = "has_video"
        case hasAudio = "has_audio"
        case offline
        case probe
    }

    init(_ asset: Asset) throws {
        assetId = asset.id.rawValue
        contentHash = asset.contentHash
        kind = asset.kind.rawValue
        libraryPath = asset.libraryPath
        displayName = asset.displayName
        durationV = asset.duration.value
        durationTs = asset.duration.timescale
        hasVideo = asset.hasVideo
        hasAudio = asset.hasAudio
        offline = asset.offline
        probe = String(decoding: try ProjectCodec.encode(asset.probe), as: UTF8.self)
    }

    /// The asset this row projects. The projection has no columns for `sampleRate`, `frameDuration`, or
    /// `analyses`, so those come back empty: enough to browse and to import by hash (the cross-project
    /// catalog), not a substitute for the owning project's state.
    public func asset() throws -> Asset {
        guard let kind = AssetKind(rawValue: kind) else {
            throw ProjectStoreError.storage("asset \(assetId) has an unknown kind \(self.kind)")
        }
        return Asset(
            id: AssetID(assetId), contentHash: contentHash, libraryPath: libraryPath, displayName: displayName,
            kind: kind, duration: RationalTime(value: durationV, timescale: durationTs), hasVideo: hasVideo,
            hasAudio: hasAudio,
            probe: try probe.map { try ProjectCodec.decode(Probe.self, from: Data($0.utf8)) } ?? Probe(),
            offline: offline)
    }
}

/// A row of `sequences`.
public struct SequenceRow: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sequences"

    public var sequenceId: String
    public var name: String
    public var frameV: Int64
    public var frameTs: Int32
    public var width: Int
    public var height: Int

    enum CodingKeys: String, CodingKey {
        case sequenceId = "sequence_id"
        case name
        case frameV = "frame_v"
        case frameTs = "frame_ts"
        case width
        case height
    }

    init(_ sequence: Sequence) {
        sequenceId = sequence.id.rawValue
        name = sequence.name
        frameV = sequence.frameDuration.value
        frameTs = sequence.frameDuration.timescale
        width = sequence.width
        height = sequence.height
    }
}

/// A row of `tracks`; `position` is the track's index in `Sequence.tracks`.
public struct TrackRow: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tracks"

    public var trackId: String
    public var sequenceId: String
    public var kind: String
    public var position: Int
    public var name: String
    public var muted: Bool
    public var locked: Bool

    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case sequenceId = "sequence_id"
        case kind
        case position
        case name
        case muted
        case locked
    }

    init(_ track: Track, sequenceId: SequenceID, position: Int) {
        trackId = track.id.rawValue
        self.sequenceId = sequenceId.rawValue
        kind = track.kind.rawValue
        self.position = position
        name = track.name
        muted = track.muted
        locked = track.locked
    }
}

/// The clip fields that live in `clips.props` as JSON.
struct ClipProps: Codable, Hashable {
    var transform: Animatable<Transform>
    var opacity: Animatable<Double>
    var effects: [Effect]
    var audio: ClipAudio
    var words: [CaptionWord]?
    var style: CaptionStyle?
    var label: String?
    var meta: [String: JSONValue]?
}

/// A row of `clips`. `ClipRow.clip(in:)` turns it back into a model value for the UI's observations.
public struct ClipRow: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "clips"

    public var clipId: String
    public var sequenceId: String
    public var trackId: String
    public var assetId: String?
    public var linkGroupId: String?
    public var startV: Int64
    public var startTs: Int32
    public var inV: Int64
    public var inTs: Int32
    public var outV: Int64
    public var outTs: Int32
    public var speedNum: Int64
    public var speedDen: Int64
    public var text: String?
    public var props: String?

    enum CodingKeys: String, CodingKey {
        case clipId = "clip_id"
        case sequenceId = "sequence_id"
        case trackId = "track_id"
        case assetId = "asset_id"
        case linkGroupId = "link_group_id"
        case startV = "start_v"
        case startTs = "start_ts"
        case inV = "in_v"
        case inTs = "in_ts"
        case outV = "out_v"
        case outTs = "out_ts"
        case speedNum = "speed_num"
        case speedDen = "speed_den"
        case text
        case props
    }

    init(_ clip: Clip, sequenceId: SequenceID) throws {
        clipId = clip.id.rawValue
        self.sequenceId = sequenceId.rawValue
        trackId = clip.trackId.rawValue
        assetId = clip.assetId?.rawValue
        linkGroupId = clip.linkGroupId?.rawValue
        startV = clip.start.value
        startTs = clip.start.timescale
        inV = clip.sourceIn.value
        inTs = clip.sourceIn.timescale
        outV = clip.sourceOut.value
        outTs = clip.sourceOut.timescale
        speedNum = clip.speed.num
        speedDen = clip.speed.den
        text = clip.text
        let p = ClipProps(
            transform: clip.transform, opacity: clip.opacity, effects: clip.effects, audio: clip.audio,
            words: clip.words, style: clip.style, label: clip.label, meta: clip.meta)
        props = String(decoding: try ProjectCodec.encode(p), as: UTF8.self)
    }

    public var start: RationalTime { RationalTime(startV, startTs) }
    public var sourceIn: RationalTime { RationalTime(inV, inTs) }
    public var sourceOut: RationalTime { RationalTime(outV, outTs) }
    public var speed: Rational { Rational(speedNum, speedDen) }

    /// The model clip this row describes.
    public func clip() throws -> Clip {
        let p = try props.map { try ProjectCodec.decode(ClipProps.self, from: Data($0.utf8)) }
        return Clip(
            id: ClipID(clipId), trackId: TrackID(trackId), assetId: assetId.map { AssetID($0) },
            linkGroupId: linkGroupId.map { LinkGroupID($0) }, start: start, sourceIn: sourceIn, sourceOut: sourceOut,
            speed: speed, transform: p?.transform ?? .constant(.identity), opacity: p?.opacity ?? .constant(1),
            effects: p?.effects ?? [], audio: p?.audio ?? ClipAudio(), text: text, words: p?.words, style: p?.style,
            label: p?.label, meta: p?.meta)
    }
}

/// A row of `transitions`.
public struct TransitionRow: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transitions"

    public var transitionId: String
    public var sequenceId: String
    public var trackId: String
    public var leftClipId: String
    public var rightClipId: String
    public var kind: String
    public var durationV: Int64
    public var durationTs: Int32
    public var alignment: String
    public var params: String?

    enum CodingKeys: String, CodingKey {
        case transitionId = "transition_id"
        case sequenceId = "sequence_id"
        case trackId = "track_id"
        case leftClipId = "left_clip_id"
        case rightClipId = "right_clip_id"
        case kind
        case durationV = "duration_v"
        case durationTs = "duration_ts"
        case alignment
        case params
    }

    init(_ t: Transition, sequenceId: SequenceID) throws {
        transitionId = t.id.rawValue
        self.sequenceId = sequenceId.rawValue
        trackId = t.trackId.rawValue
        leftClipId = t.leftClipId.rawValue
        rightClipId = t.rightClipId.rawValue
        kind = t.kind
        durationV = t.duration.value
        durationTs = t.duration.timescale
        alignment = t.alignment.rawValue
        params = String(decoding: try ProjectCodec.encode(t.params), as: UTF8.self)
    }
}

/// A row of `markers`.
public struct MarkerRow: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "markers"

    public var markerId: String
    public var sequenceId: String
    public var atV: Int64
    public var atTs: Int32
    public var label: String
    public var colour: String?

    enum CodingKeys: String, CodingKey {
        case markerId = "marker_id"
        case sequenceId = "sequence_id"
        case atV = "at_v"
        case atTs = "at_ts"
        case label
        case colour
    }

    init(_ m: Marker, sequenceId: SequenceID) {
        markerId = m.id.rawValue
        self.sequenceId = sequenceId.rawValue
        atV = m.at.value
        atTs = m.at.timescale
        label = m.label
        colour = m.colour
    }
}

/// A row of `history`: one per transaction, `live` derived from the fold.
public struct HistoryRow: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "history"

    public var txnId: String
    public var firstSeq: Int64
    public var lastSeq: Int64
    public var actor: String
    public var label: String
    public var kind: String
    public var targetTxn: String?
    public var live: Bool

    enum CodingKeys: String, CodingKey {
        case txnId = "txn_id"
        case firstSeq = "first_seq"
        case lastSeq = "last_seq"
        case actor
        case label
        case kind
        case targetTxn = "target_txn"
        case live
    }
}

/// A row of `renders` (storage.md section 5; operational, not part of the event stream).
public struct RenderRow: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "renders"

    public enum Status: String, Codable, Sendable, Hashable, CaseIterable {
        case queued
        case running
        case done
        case failed
        case cancelled
    }

    public var renderId: String
    public var requestedAt: String
    public var completedAt: String?
    public var sequenceId: String
    /// A serialized `ExportPreset`.
    public var preset: String
    public var outputPath: String?
    public var outputHash: String?
    public var projectVersion: Int64
    public var status: Status
    /// JSON: settings, duration, warnings.
    public var receipt: String?

    enum CodingKeys: String, CodingKey {
        case renderId = "render_id"
        case requestedAt = "requested_at"
        case completedAt = "completed_at"
        case sequenceId = "sequence_id"
        case preset
        case outputPath = "output_path"
        case outputHash = "output_hash"
        case projectVersion = "project_version"
        case status
        case receipt
    }
}

/// A row of `publishes` (publish-plan.md section 4.2; operational, not part of the event stream). The JSON
/// columns hold a `PublishRequest`, a `PublishSession`, and a `PublishReceipt` through `ProjectCodec`;
/// `session` is the only place the resumable upload URL (a capability URL) is ever stored.
public struct PublishRow: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "publishes"

    public var publishId: String
    public var renderId: String
    public var destination: PublishDestination
    public var accountId: String
    public var requestedAt: String
    public var completedAt: String?
    public var status: PublishStatus
    /// JSON `PublishRequest`.
    public var request: String
    /// JSON `PublishSession`, kept while the upload can be resumed.
    public var session: String?
    public var bytesTotal: Int64?
    public var bytesSent: Int64?
    public var remoteId: String?
    public var remoteUrl: String?
    public var projectVersion: Int64
    /// JSON `PublishReceipt`.
    public var receipt: String?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case publishId = "publish_id"
        case renderId = "render_id"
        case destination
        case accountId = "account_id"
        case requestedAt = "requested_at"
        case completedAt = "completed_at"
        case status
        case request
        case session
        case bytesTotal = "bytes_total"
        case bytesSent = "bytes_sent"
        case remoteId = "remote_id"
        case remoteUrl = "remote_url"
        case projectVersion = "project_version"
        case receipt
        case error
    }
}
