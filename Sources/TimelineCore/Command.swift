import Foundation

/// Who issued a command. Encodes as `"human"`, `"agent:<sessionId>"`, or `"system"`.
public enum Actor: Hashable, Sendable, Codable, CustomStringConvertible {
    case human
    case agent(sessionId: String)
    case system

    public var description: String {
        switch self {
        case .human: "human"
        case .agent(let id): "agent:\(id)"
        case .system: "system"
        }
    }

    public init?(_ string: String) {
        switch string {
        case "human": self = .human
        case "system": self = .system
        default:
            guard string.hasPrefix("agent:") else { return nil }
            self = .agent(sessionId: String(string.dropFirst("agent:".count)))
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let actor = Actor(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown actor \(s)")
        }
        self = actor
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// An id argument inside an operation: either a concrete id or `{ "$ref": n }`, the id created by
/// operation `n` of the enclosing batch.
public enum Ref<ID: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    case id(ID)
    case ref(Int)

    public init(_ id: ID) { self = .id(id) }

    public var idValue: ID? {
        if case .id(let id) = self { return id }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case ref = "$ref"
    }

    public init(from decoder: any Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.ref) {
            self = .ref(try c.decode(Int.self, forKey: .ref))
        } else {
            self = .id(try decoder.singleValueContainer().decode(ID.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .id(let id):
            var c = encoder.singleValueContainer()
            try c.encode(id)
        case .ref(let n):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(n, forKey: .ref)
        }
    }
}

extension Ref: ExpressibleByUnicodeScalarLiteral, ExpressibleByExtendedGraphemeClusterLiteral,
    ExpressibleByStringLiteral
where ID: ExpressibleByStringLiteral, ID.StringLiteralType == String {
    public init(stringLiteral value: String) { self = .id(ID(stringLiteral: value)) }
}

public enum EditMode: String, Codable, Hashable, Sendable, CaseIterable {
    case overwrite
    case ripple
}

public enum RippleScope: String, Codable, Hashable, Sendable, CaseIterable {
    case sequence
    case track
}

public enum LinkMode: String, Codable, Hashable, Sendable, CaseIterable {
    case auto
    case none
}

public enum Edge: String, Codable, Hashable, Sendable, CaseIterable {
    case head
    case tail
}

/// A request to change the project. `decide` turns it into events or rejects it.
public struct Command: Hashable, Sendable, Codable {
    /// Idempotency key supplied by the caller.
    public var commandId: CommandID
    public var actor: Actor
    /// Agents supply the version they last saw; the UI omits it.
    public var expectedVersion: Int64?
    /// Undo-history label; defaults to `label(for:)` of the operation.
    public var label: String?
    public var operation: Operation

    public init(
        commandId: CommandID, actor: Actor, expectedVersion: Int64? = nil, label: String? = nil, operation: Operation
    ) {
        self.commandId = commandId
        self.actor = actor
        self.expectedVersion = expectedVersion
        self.label = label
        self.operation = operation
    }

    public var effectiveLabel: String { label ?? TimelineCore.label(for: operation) }
}

extension Command {
    // MARK: Operation

    /// Every operation the model accepts. Encodes as `{ "type": "<camelCaseName>", ...fields }`.
    public indirect enum Operation: Hashable, Sendable {
        case createProject(CreateProject)
        case setProjectSettings(SetProjectSettings)
        case renameProject(RenameProject)
        case addSequence(SequenceSpec)
        case setSequenceSettings(SetSequenceSettings)
        case setActiveSequence(SetActiveSequence)
        case importAsset(ImportAsset)
        case relinkAsset(RelinkAsset)
        case removeAsset(RemoveAsset)
        case restoreAsset(RestoreAsset)
        case recordAssetAnalysis(RecordAssetAnalysis)
        case addTrack(AddTrack)
        case removeTrack(RemoveTrack)
        case reorderTrack(ReorderTrack)
        case renameTrack(RenameTrack)
        case setTrackMuted(SetTrackMuted)
        case setTrackLocked(SetTrackLocked)
        case addClip(AddClip)
        case moveClip(MoveClip)
        case trimClip(TrimClip)
        case splitClip(SplitClip)
        case joinClips(JoinClips)
        case removeClip(RemoveClip)
        case setClipSpeed(SetClipSpeed)
        case setClipTransform(SetClipTransform)
        case setClipOpacity(SetClipOpacity)
        case setClipAudio(SetClipAudio)
        case addEffect(AddEffect)
        case updateEffect(UpdateEffect)
        case removeEffect(RemoveEffect)
        case addTransition(AddTransition)
        case updateTransition(UpdateTransition)
        case removeTransition(RemoveTransition)
        case linkClips(LinkClips)
        case unlinkClips(UnlinkClips)
        case addCaptionTrack(AddCaptionTrack)
        case replaceCaptions(ReplaceCaptions)
        case editCaption(EditCaption)
        case setCaptionStyle(SetCaptionStyle)
        case addMarker(AddMarker)
        case moveMarker(MoveMarker)
        case removeMarker(RemoveMarker)
        case undo(Undo)
        case redo
        case batch([Operation])

        // MARK: Project

        public struct SequenceSpec: Hashable, Sendable, Codable {
            public var id: SequenceID?
            public var name: String
            public var frameDuration: RationalTime
            public var width: Int
            public var height: Int

            public init(id: SequenceID? = nil, name: String, frameDuration: RationalTime, width: Int, height: Int) {
                self.id = id
                self.name = name
                self.frameDuration = frameDuration
                self.width = width
                self.height = height
            }
        }

        public struct CreateProject: Hashable, Sendable, Codable {
            public var id: ProjectID?
            public var name: String
            public var settings: ProjectSettings?
            public var sequence: SequenceSpec

            public init(id: ProjectID? = nil, name: String, settings: ProjectSettings? = nil, sequence: SequenceSpec) {
                self.id = id
                self.name = name
                self.settings = settings
                self.sequence = sequence
            }
        }

        public struct SetProjectSettings: Hashable, Sendable, Codable {
            public var after: ProjectSettings
            public init(after: ProjectSettings) { self.after = after }
        }

        public struct RenameProject: Hashable, Sendable, Codable {
            public var name: String
            public init(name: String) { self.name = name }
        }

        public struct SetSequenceSettings: Hashable, Sendable, Codable {
            public var sequenceId: Ref<SequenceID>
            public var after: SequenceSettings
            public init(sequenceId: Ref<SequenceID>, after: SequenceSettings) {
                self.sequenceId = sequenceId
                self.after = after
            }
        }

        public struct SetActiveSequence: Hashable, Sendable, Codable {
            public var sequenceId: Ref<SequenceID>
            public init(sequenceId: Ref<SequenceID>) { self.sequenceId = sequenceId }
        }

        // MARK: Assets

        public struct ImportAsset: Hashable, Sendable, Codable {
            public var id: AssetID?
            public var contentHash: String
            public var libraryPath: String
            public var displayName: String
            public var kind: AssetKind
            public var duration: RationalTime
            public var hasVideo: Bool
            public var hasAudio: Bool
            public var sampleRate: Int?
            public var frameDuration: RationalTime?
            public var probe: Probe

            public init(
                id: AssetID? = nil, contentHash: String, libraryPath: String, displayName: String, kind: AssetKind,
                duration: RationalTime, hasVideo: Bool, hasAudio: Bool, sampleRate: Int? = nil,
                frameDuration: RationalTime? = nil, probe: Probe = Probe()
            ) {
                self.id = id
                self.contentHash = contentHash
                self.libraryPath = libraryPath
                self.displayName = displayName
                self.kind = kind
                self.duration = duration
                self.hasVideo = hasVideo
                self.hasAudio = hasAudio
                self.sampleRate = sampleRate
                self.frameDuration = frameDuration
                self.probe = probe
            }
        }

        public struct RelinkAsset: Hashable, Sendable, Codable {
            public var assetId: Ref<AssetID>
            public var libraryPath: String
            public var offline: Bool

            public init(assetId: Ref<AssetID>, libraryPath: String, offline: Bool = false) {
                self.assetId = assetId
                self.libraryPath = libraryPath
                self.offline = offline
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                assetId = try c.decode(Ref<AssetID>.self, forKey: .assetId)
                libraryPath = try c.decode(String.self, forKey: .libraryPath)
                offline = try c.decodeIfPresent(Bool.self, forKey: .offline) ?? false
            }
        }

        public struct RemoveAsset: Hashable, Sendable, Codable {
            public var assetId: Ref<AssetID>
            public init(assetId: Ref<AssetID>) { self.assetId = assetId }
        }

        /// Re-inserts a previously removed asset from a snapshot (the event log or the library sidecar).
        public struct RestoreAsset: Hashable, Sendable, Codable {
            public var asset: Asset
            public init(asset: Asset) { self.asset = asset }
        }

        public struct RecordAssetAnalysis: Hashable, Sendable, Codable {
            public var assetId: Ref<AssetID>
            public var kind: String
            public var cacheKey: String
            public var summary: JSONValue?

            public init(assetId: Ref<AssetID>, kind: String, cacheKey: String, summary: JSONValue? = nil) {
                self.assetId = assetId
                self.kind = kind
                self.cacheKey = cacheKey
                self.summary = summary
            }
        }

        // MARK: Tracks

        public struct AddTrack: Hashable, Sendable, Codable {
            public var id: TrackID?
            public var sequenceId: Ref<SequenceID>
            public var kind: TrackKind
            public var name: String?
            /// Index in `tracks`; defaults to the end.
            public var position: Int?

            public init(
                id: TrackID? = nil, sequenceId: Ref<SequenceID>, kind: TrackKind, name: String? = nil,
                position: Int? = nil
            ) {
                self.id = id
                self.sequenceId = sequenceId
                self.kind = kind
                self.name = name
                self.position = position
            }
        }

        public struct RemoveTrack: Hashable, Sendable, Codable {
            public var trackId: Ref<TrackID>
            public init(trackId: Ref<TrackID>) { self.trackId = trackId }
        }

        public struct ReorderTrack: Hashable, Sendable, Codable {
            public var trackId: Ref<TrackID>
            public var position: Int
            public init(trackId: Ref<TrackID>, position: Int) {
                self.trackId = trackId
                self.position = position
            }
        }

        public struct RenameTrack: Hashable, Sendable, Codable {
            public var trackId: Ref<TrackID>
            public var name: String
            public init(trackId: Ref<TrackID>, name: String) {
                self.trackId = trackId
                self.name = name
            }
        }

        public struct SetTrackMuted: Hashable, Sendable, Codable {
            public var trackId: Ref<TrackID>
            public var muted: Bool
            public init(trackId: Ref<TrackID>, muted: Bool) {
                self.trackId = trackId
                self.muted = muted
            }
        }

        public struct SetTrackLocked: Hashable, Sendable, Codable {
            public var trackId: Ref<TrackID>
            public var locked: Bool
            public init(trackId: Ref<TrackID>, locked: Bool) {
                self.trackId = trackId
                self.locked = locked
            }
        }

        // MARK: Clips

        public struct AddClip: Hashable, Sendable, Codable {
            public var id: ClipID?
            public var sequenceId: Ref<SequenceID>
            public var trackId: Ref<TrackID>
            /// Nil for generated clips.
            public var assetId: Ref<AssetID>?
            public var at: RationalTime
            public var sourceIn: RationalTime
            public var sourceOut: RationalTime
            public var mode: EditMode
            public var rippleScope: RippleScope
            public var link: LinkMode
            /// Client id for the partner clip `link: auto` creates on the matching track.
            public var linkedId: ClipID?
            public var label: String?

            public init(
                id: ClipID? = nil, sequenceId: Ref<SequenceID>, trackId: Ref<TrackID>, assetId: Ref<AssetID>? = nil,
                at: RationalTime, sourceIn: RationalTime, sourceOut: RationalTime, mode: EditMode = .ripple,
                rippleScope: RippleScope = .sequence, link: LinkMode = .auto, linkedId: ClipID? = nil,
                label: String? = nil
            ) {
                self.id = id
                self.sequenceId = sequenceId
                self.trackId = trackId
                self.assetId = assetId
                self.at = at
                self.sourceIn = sourceIn
                self.sourceOut = sourceOut
                self.mode = mode
                self.rippleScope = rippleScope
                self.link = link
                self.linkedId = linkedId
                self.label = label
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decodeIfPresent(ClipID.self, forKey: .id)
                sequenceId = try c.decode(Ref<SequenceID>.self, forKey: .sequenceId)
                trackId = try c.decode(Ref<TrackID>.self, forKey: .trackId)
                assetId = try c.decodeIfPresent(Ref<AssetID>.self, forKey: .assetId)
                at = try c.decode(RationalTime.self, forKey: .at)
                sourceIn = try c.decode(RationalTime.self, forKey: .sourceIn)
                sourceOut = try c.decode(RationalTime.self, forKey: .sourceOut)
                mode = try c.decodeIfPresent(EditMode.self, forKey: .mode) ?? .ripple
                rippleScope = try c.decodeIfPresent(RippleScope.self, forKey: .rippleScope) ?? .sequence
                link = try c.decodeIfPresent(LinkMode.self, forKey: .link) ?? .auto
                linkedId = try c.decodeIfPresent(ClipID.self, forKey: .linkedId)
                label = try c.decodeIfPresent(String.self, forKey: .label)
            }
        }

        public struct MoveTarget: Hashable, Sendable, Codable {
            public var trackId: Ref<TrackID>?
            public var start: RationalTime
            public init(trackId: Ref<TrackID>? = nil, start: RationalTime) {
                self.trackId = trackId
                self.start = start
            }
        }

        public struct MoveClip: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            public var to: MoveTarget
            public var mode: EditMode
            public var rippleScope: RippleScope
            public var unlinked: Bool

            public init(
                clipId: Ref<ClipID>, to: MoveTarget, mode: EditMode = .overwrite, rippleScope: RippleScope = .sequence,
                unlinked: Bool = false
            ) {
                self.clipId = clipId
                self.to = to
                self.mode = mode
                self.rippleScope = rippleScope
                self.unlinked = unlinked
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                clipId = try c.decode(Ref<ClipID>.self, forKey: .clipId)
                to = try c.decode(MoveTarget.self, forKey: .to)
                mode = try c.decodeIfPresent(EditMode.self, forKey: .mode) ?? .overwrite
                rippleScope = try c.decodeIfPresent(RippleScope.self, forKey: .rippleScope) ?? .sequence
                unlinked = try c.decodeIfPresent(Bool.self, forKey: .unlinked) ?? false
            }
        }

        public struct TrimClip: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            public var edge: Edge
            /// The new timeline position of the edge.
            public var to: RationalTime
            public var mode: EditMode
            public var rippleScope: RippleScope
            public var unlinked: Bool

            public init(
                clipId: Ref<ClipID>, edge: Edge, to: RationalTime, mode: EditMode = .ripple,
                rippleScope: RippleScope = .sequence, unlinked: Bool = false
            ) {
                self.clipId = clipId
                self.edge = edge
                self.to = to
                self.mode = mode
                self.rippleScope = rippleScope
                self.unlinked = unlinked
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                clipId = try c.decode(Ref<ClipID>.self, forKey: .clipId)
                edge = try c.decode(Edge.self, forKey: .edge)
                to = try c.decode(RationalTime.self, forKey: .to)
                mode = try c.decodeIfPresent(EditMode.self, forKey: .mode) ?? .ripple
                rippleScope = try c.decodeIfPresent(RippleScope.self, forKey: .rippleScope) ?? .sequence
                unlinked = try c.decodeIfPresent(Bool.self, forKey: .unlinked) ?? false
            }
        }

        public struct SplitClip: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            /// Timeline time of the cut on the addressed clip.
            public var at: RationalTime
            /// One id per created clip: the addressed clip's first, then the other group members in
            /// track order.
            public var newIds: [ClipID]?
            public var unlinked: Bool

            public init(clipId: Ref<ClipID>, at: RationalTime, newIds: [ClipID]? = nil, unlinked: Bool = false) {
                self.clipId = clipId
                self.at = at
                self.newIds = newIds
                self.unlinked = unlinked
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                clipId = try c.decode(Ref<ClipID>.self, forKey: .clipId)
                at = try c.decode(RationalTime.self, forKey: .at)
                newIds = try c.decodeIfPresent([ClipID].self, forKey: .newIds)
                unlinked = try c.decodeIfPresent(Bool.self, forKey: .unlinked) ?? false
            }
        }

        public struct JoinClips: Hashable, Sendable, Codable {
            public var leftClipId: Ref<ClipID>
            public var rightClipId: Ref<ClipID>
            public init(leftClipId: Ref<ClipID>, rightClipId: Ref<ClipID>) {
                self.leftClipId = leftClipId
                self.rightClipId = rightClipId
            }
        }

        public struct RemoveClip: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            public var mode: EditMode
            public var rippleScope: RippleScope
            public var unlinked: Bool

            public init(
                clipId: Ref<ClipID>, mode: EditMode = .ripple, rippleScope: RippleScope = .sequence,
                unlinked: Bool = false
            ) {
                self.clipId = clipId
                self.mode = mode
                self.rippleScope = rippleScope
                self.unlinked = unlinked
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                clipId = try c.decode(Ref<ClipID>.self, forKey: .clipId)
                mode = try c.decodeIfPresent(EditMode.self, forKey: .mode) ?? .ripple
                rippleScope = try c.decodeIfPresent(RippleScope.self, forKey: .rippleScope) ?? .sequence
                unlinked = try c.decodeIfPresent(Bool.self, forKey: .unlinked) ?? false
            }
        }

        public struct SetClipSpeed: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            public var after: Rational
            /// How the change in timeline duration is absorbed.
            public var mode: EditMode
            public var rippleScope: RippleScope

            public init(
                clipId: Ref<ClipID>, after: Rational, mode: EditMode = .ripple, rippleScope: RippleScope = .sequence
            ) {
                self.clipId = clipId
                self.after = after
                self.mode = mode
                self.rippleScope = rippleScope
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                clipId = try c.decode(Ref<ClipID>.self, forKey: .clipId)
                after = try c.decode(Rational.self, forKey: .after)
                mode = try c.decodeIfPresent(EditMode.self, forKey: .mode) ?? .ripple
                rippleScope = try c.decodeIfPresent(RippleScope.self, forKey: .rippleScope) ?? .sequence
            }
        }

        public struct SetClipTransform: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            public var after: Animatable<Transform>
            public init(clipId: Ref<ClipID>, after: Animatable<Transform>) {
                self.clipId = clipId
                self.after = after
            }
        }

        public struct SetClipOpacity: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            public var after: Animatable<Double>
            public init(clipId: Ref<ClipID>, after: Animatable<Double>) {
                self.clipId = clipId
                self.after = after
            }
        }

        public struct SetClipAudio: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            public var after: ClipAudio
            public init(clipId: Ref<ClipID>, after: ClipAudio) {
                self.clipId = clipId
                self.after = after
            }
        }

        public struct AddEffect: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            public var effectId: EffectID?
            public var kind: String
            public var params: [String: Animatable<JSONValue>]
            /// Index in the clip's effect list; defaults to the end.
            public var index: Int?

            public init(
                clipId: Ref<ClipID>, effectId: EffectID? = nil, kind: String,
                params: [String: Animatable<JSONValue>] = [:], index: Int? = nil
            ) {
                self.clipId = clipId
                self.effectId = effectId
                self.kind = kind
                self.params = params
                self.index = index
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                clipId = try c.decode(Ref<ClipID>.self, forKey: .clipId)
                effectId = try c.decodeIfPresent(EffectID.self, forKey: .effectId)
                kind = try c.decode(String.self, forKey: .kind)
                params = try c.decodeIfPresent([String: Animatable<JSONValue>].self, forKey: .params) ?? [:]
                index = try c.decodeIfPresent(Int.self, forKey: .index)
            }
        }

        public struct UpdateEffect: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            public var effectId: Ref<EffectID>
            public var kind: String?
            public var enabled: Bool?
            /// Replaces the whole parameter set when present.
            public var params: [String: Animatable<JSONValue>]?

            public init(
                clipId: Ref<ClipID>, effectId: Ref<EffectID>, kind: String? = nil, enabled: Bool? = nil,
                params: [String: Animatable<JSONValue>]? = nil
            ) {
                self.clipId = clipId
                self.effectId = effectId
                self.kind = kind
                self.enabled = enabled
                self.params = params
            }
        }

        public struct RemoveEffect: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            public var effectId: Ref<EffectID>
            public init(clipId: Ref<ClipID>, effectId: Ref<EffectID>) {
                self.clipId = clipId
                self.effectId = effectId
            }
        }

        public struct AddTransition: Hashable, Sendable, Codable {
            public var id: TransitionID?
            public var leftClipId: Ref<ClipID>
            public var rightClipId: Ref<ClipID>
            public var kind: String
            public var duration: RationalTime
            public var alignment: TransitionAlignment
            public var params: [String: JSONValue]

            public init(
                id: TransitionID? = nil, leftClipId: Ref<ClipID>, rightClipId: Ref<ClipID>, kind: String,
                duration: RationalTime, alignment: TransitionAlignment = .centered, params: [String: JSONValue] = [:]
            ) {
                self.id = id
                self.leftClipId = leftClipId
                self.rightClipId = rightClipId
                self.kind = kind
                self.duration = duration
                self.alignment = alignment
                self.params = params
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decodeIfPresent(TransitionID.self, forKey: .id)
                leftClipId = try c.decode(Ref<ClipID>.self, forKey: .leftClipId)
                rightClipId = try c.decode(Ref<ClipID>.self, forKey: .rightClipId)
                kind = try c.decode(String.self, forKey: .kind)
                duration = try c.decode(RationalTime.self, forKey: .duration)
                alignment = try c.decodeIfPresent(TransitionAlignment.self, forKey: .alignment) ?? .centered
                params = try c.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
            }
        }

        public struct UpdateTransition: Hashable, Sendable, Codable {
            public var transitionId: Ref<TransitionID>
            public var kind: String?
            public var duration: RationalTime?
            public var alignment: TransitionAlignment?
            public var params: [String: JSONValue]?

            public init(
                transitionId: Ref<TransitionID>, kind: String? = nil, duration: RationalTime? = nil,
                alignment: TransitionAlignment? = nil, params: [String: JSONValue]? = nil
            ) {
                self.transitionId = transitionId
                self.kind = kind
                self.duration = duration
                self.alignment = alignment
                self.params = params
            }
        }

        public struct RemoveTransition: Hashable, Sendable, Codable {
            public var transitionId: Ref<TransitionID>
            public init(transitionId: Ref<TransitionID>) { self.transitionId = transitionId }
        }

        public struct LinkClips: Hashable, Sendable, Codable {
            public var clipIds: [Ref<ClipID>]
            /// Group to join; defaults to the group any member already has, else a new one.
            public var linkGroupId: LinkGroupID?
            public init(clipIds: [Ref<ClipID>], linkGroupId: LinkGroupID? = nil) {
                self.clipIds = clipIds
                self.linkGroupId = linkGroupId
            }
        }

        public struct UnlinkClips: Hashable, Sendable, Codable {
            public var clipIds: [Ref<ClipID>]
            public init(clipIds: [Ref<ClipID>]) { self.clipIds = clipIds }
        }

        // MARK: Captions

        public struct AddCaptionTrack: Hashable, Sendable, Codable {
            public var id: TrackID?
            public var sequenceId: Ref<SequenceID>
            public var name: String?
            public var language: String
            public var style: CaptionStyle?

            public init(
                id: TrackID? = nil, sequenceId: Ref<SequenceID>, name: String? = nil, language: String,
                style: CaptionStyle? = nil
            ) {
                self.id = id
                self.sequenceId = sequenceId
                self.name = name
                self.language = language
                self.style = style
            }
        }

        public struct CaptionInput: Hashable, Sendable, Codable {
            public var id: ClipID?
            public var start: RationalTime
            public var duration: RationalTime
            public var text: String
            public var words: [CaptionWord]
            public var style: CaptionStyle?

            public init(
                id: ClipID? = nil, start: RationalTime, duration: RationalTime, text: String,
                words: [CaptionWord] = [], style: CaptionStyle? = nil
            ) {
                self.id = id
                self.start = start
                self.duration = duration
                self.text = text
                self.words = words
                self.style = style
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decodeIfPresent(ClipID.self, forKey: .id)
                start = try c.decode(RationalTime.self, forKey: .start)
                duration = try c.decode(RationalTime.self, forKey: .duration)
                text = try c.decode(String.self, forKey: .text)
                words = try c.decodeIfPresent([CaptionWord].self, forKey: .words) ?? []
                style = try c.decodeIfPresent(CaptionStyle.self, forKey: .style)
            }
        }

        public struct ReplaceCaptions: Hashable, Sendable, Codable {
            public var trackId: Ref<TrackID>
            public var items: [CaptionInput]
            public init(trackId: Ref<TrackID>, items: [CaptionInput]) {
                self.trackId = trackId
                self.items = items
            }
        }

        public struct EditCaption: Hashable, Sendable, Codable {
            public var clipId: Ref<ClipID>
            public var text: String?
            public var words: [CaptionWord]?
            public init(clipId: Ref<ClipID>, text: String? = nil, words: [CaptionWord]? = nil) {
                self.clipId = clipId
                self.text = text
                self.words = words
            }
        }

        /// Exactly one of `trackId` (track default style) or `clipId` (item override) is given.
        public struct SetCaptionStyle: Hashable, Sendable, Codable {
            public var trackId: Ref<TrackID>?
            public var clipId: Ref<ClipID>?
            public var style: CaptionStyle?
            public init(trackId: Ref<TrackID>? = nil, clipId: Ref<ClipID>? = nil, style: CaptionStyle?) {
                self.trackId = trackId
                self.clipId = clipId
                self.style = style
            }
        }

        // MARK: Markers

        public struct AddMarker: Hashable, Sendable, Codable {
            public var id: MarkerID?
            public var sequenceId: Ref<SequenceID>
            public var at: RationalTime
            public var label: String
            public var colour: String?

            public init(
                id: MarkerID? = nil, sequenceId: Ref<SequenceID>, at: RationalTime, label: String, colour: String? = nil
            ) {
                self.id = id
                self.sequenceId = sequenceId
                self.at = at
                self.label = label
                self.colour = colour
            }
        }

        public struct MoveMarker: Hashable, Sendable, Codable {
            public var markerId: Ref<MarkerID>
            public var to: RationalTime
            public init(markerId: Ref<MarkerID>, to: RationalTime) {
                self.markerId = markerId
                self.to = to
            }
        }

        public struct RemoveMarker: Hashable, Sendable, Codable {
            public var markerId: Ref<MarkerID>
            public init(markerId: Ref<MarkerID>) { self.markerId = markerId }
        }

        // MARK: History

        public struct Undo: Hashable, Sendable, Codable {
            /// Defaults to the latest live transaction.
            public var txnId: TransactionID?
            public init(txnId: TransactionID? = nil) { self.txnId = txnId }
        }
    }
}

/// Sequence settings a command can change.
public struct SequenceSettings: Hashable, Sendable, Codable {
    public var name: String
    public var frameDuration: RationalTime
    public var width: Int
    public var height: Int

    public init(name: String, frameDuration: RationalTime, width: Int, height: Int) {
        self.name = name
        self.frameDuration = frameDuration
        self.width = width
        self.height = height
    }

    public init(_ sequence: Sequence) {
        self.init(
            name: sequence.name, frameDuration: sequence.frameDuration, width: sequence.width, height: sequence.height)
    }
}

// MARK: - Operation names, labels, Codable

extension Command.Operation {
    /// The `"type"` discriminator: the camelCase command name.
    public var typeName: String {
        switch self {
        case .createProject: "createProject"
        case .setProjectSettings: "setProjectSettings"
        case .renameProject: "renameProject"
        case .addSequence: "addSequence"
        case .setSequenceSettings: "setSequenceSettings"
        case .setActiveSequence: "setActiveSequence"
        case .importAsset: "importAsset"
        case .relinkAsset: "relinkAsset"
        case .removeAsset: "removeAsset"
        case .restoreAsset: "restoreAsset"
        case .recordAssetAnalysis: "recordAssetAnalysis"
        case .addTrack: "addTrack"
        case .removeTrack: "removeTrack"
        case .reorderTrack: "reorderTrack"
        case .renameTrack: "renameTrack"
        case .setTrackMuted: "setTrackMuted"
        case .setTrackLocked: "setTrackLocked"
        case .addClip: "addClip"
        case .moveClip: "moveClip"
        case .trimClip: "trimClip"
        case .splitClip: "splitClip"
        case .joinClips: "joinClips"
        case .removeClip: "removeClip"
        case .setClipSpeed: "setClipSpeed"
        case .setClipTransform: "setClipTransform"
        case .setClipOpacity: "setClipOpacity"
        case .setClipAudio: "setClipAudio"
        case .addEffect: "addEffect"
        case .updateEffect: "updateEffect"
        case .removeEffect: "removeEffect"
        case .addTransition: "addTransition"
        case .updateTransition: "updateTransition"
        case .removeTransition: "removeTransition"
        case .linkClips: "linkClips"
        case .unlinkClips: "unlinkClips"
        case .addCaptionTrack: "addCaptionTrack"
        case .replaceCaptions: "replaceCaptions"
        case .editCaption: "editCaption"
        case .setCaptionStyle: "setCaptionStyle"
        case .addMarker: "addMarker"
        case .moveMarker: "moveMarker"
        case .removeMarker: "removeMarker"
        case .undo: "undo"
        case .redo: "redo"
        case .batch: "batch"
        }
    }

    /// All operation type names, for schema generation and exhaustiveness tests.
    public static let allTypeNames: [String] = [
        "createProject", "setProjectSettings", "renameProject", "addSequence", "setSequenceSettings",
        "setActiveSequence", "importAsset", "relinkAsset", "removeAsset", "restoreAsset", "recordAssetAnalysis",
        "addTrack", "removeTrack", "reorderTrack", "renameTrack", "setTrackMuted", "setTrackLocked", "addClip",
        "moveClip", "trimClip", "splitClip", "joinClips", "removeClip", "setClipSpeed", "setClipTransform",
        "setClipOpacity", "setClipAudio", "addEffect", "updateEffect", "removeEffect", "addTransition",
        "updateTransition", "removeTransition", "linkClips", "unlinkClips", "addCaptionTrack", "replaceCaptions",
        "editCaption", "setCaptionStyle", "addMarker", "moveMarker", "removeMarker", "undo", "redo", "batch",
    ]
}

/// A human-readable undo-history label for an operation, e.g. "Trim clip".
public func label(for operation: Command.Operation) -> String {
    switch operation {
    case .createProject: "Create project"
    case .setProjectSettings: "Change project settings"
    case .renameProject: "Rename project"
    case .addSequence: "Add sequence"
    case .setSequenceSettings: "Change sequence settings"
    case .setActiveSequence: "Switch sequence"
    case .importAsset: "Import asset"
    case .relinkAsset: "Relink asset"
    case .removeAsset: "Remove asset"
    case .restoreAsset: "Restore asset"
    case .recordAssetAnalysis: "Record analysis"
    case .addTrack: "Add track"
    case .removeTrack: "Remove track"
    case .reorderTrack: "Reorder track"
    case .renameTrack: "Rename track"
    case .setTrackMuted(let op): op.muted ? "Mute track" : "Unmute track"
    case .setTrackLocked(let op): op.locked ? "Lock track" : "Unlock track"
    case .addClip: "Add clip"
    case .moveClip: "Move clip"
    case .trimClip: "Trim clip"
    case .splitClip: "Split clip"
    case .joinClips: "Join clips"
    case .removeClip: "Remove clip"
    case .setClipSpeed: "Change speed"
    case .setClipTransform: "Transform clip"
    case .setClipOpacity: "Change opacity"
    case .setClipAudio: "Change clip audio"
    case .addEffect: "Add effect"
    case .updateEffect: "Change effect"
    case .removeEffect: "Remove effect"
    case .addTransition: "Add transition"
    case .updateTransition: "Change transition"
    case .removeTransition: "Remove transition"
    case .linkClips: "Link clips"
    case .unlinkClips: "Unlink clips"
    case .addCaptionTrack: "Add caption track"
    case .replaceCaptions: "Replace captions"
    case .editCaption: "Edit caption"
    case .setCaptionStyle: "Change caption style"
    case .addMarker: "Add marker"
    case .moveMarker: "Move marker"
    case .removeMarker: "Remove marker"
    case .undo: "Undo"
    case .redo: "Redo"
    case .batch(let ops):
        switch ops.count {
        case 0: "Empty batch"
        case 1: label(for: ops[0])
        default: "\(ops.count) edits"
        }
    }
}

extension Command.Operation: Codable {
    private enum TypeKey: String, CodingKey {
        case type
    }

    private struct Batch: Codable {
        var operations: [Command.Operation]
    }

    private struct Empty: Codable {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "createProject": self = .createProject(try CreateProject(from: decoder))
        case "setProjectSettings": self = .setProjectSettings(try SetProjectSettings(from: decoder))
        case "renameProject": self = .renameProject(try RenameProject(from: decoder))
        case "addSequence": self = .addSequence(try SequenceSpec(from: decoder))
        case "setSequenceSettings": self = .setSequenceSettings(try SetSequenceSettings(from: decoder))
        case "setActiveSequence": self = .setActiveSequence(try SetActiveSequence(from: decoder))
        case "importAsset": self = .importAsset(try ImportAsset(from: decoder))
        case "relinkAsset": self = .relinkAsset(try RelinkAsset(from: decoder))
        case "removeAsset": self = .removeAsset(try RemoveAsset(from: decoder))
        case "restoreAsset": self = .restoreAsset(try RestoreAsset(from: decoder))
        case "recordAssetAnalysis": self = .recordAssetAnalysis(try RecordAssetAnalysis(from: decoder))
        case "addTrack": self = .addTrack(try AddTrack(from: decoder))
        case "removeTrack": self = .removeTrack(try RemoveTrack(from: decoder))
        case "reorderTrack": self = .reorderTrack(try ReorderTrack(from: decoder))
        case "renameTrack": self = .renameTrack(try RenameTrack(from: decoder))
        case "setTrackMuted": self = .setTrackMuted(try SetTrackMuted(from: decoder))
        case "setTrackLocked": self = .setTrackLocked(try SetTrackLocked(from: decoder))
        case "addClip": self = .addClip(try AddClip(from: decoder))
        case "moveClip": self = .moveClip(try MoveClip(from: decoder))
        case "trimClip": self = .trimClip(try TrimClip(from: decoder))
        case "splitClip": self = .splitClip(try SplitClip(from: decoder))
        case "joinClips": self = .joinClips(try JoinClips(from: decoder))
        case "removeClip": self = .removeClip(try RemoveClip(from: decoder))
        case "setClipSpeed": self = .setClipSpeed(try SetClipSpeed(from: decoder))
        case "setClipTransform": self = .setClipTransform(try SetClipTransform(from: decoder))
        case "setClipOpacity": self = .setClipOpacity(try SetClipOpacity(from: decoder))
        case "setClipAudio": self = .setClipAudio(try SetClipAudio(from: decoder))
        case "addEffect": self = .addEffect(try AddEffect(from: decoder))
        case "updateEffect": self = .updateEffect(try UpdateEffect(from: decoder))
        case "removeEffect": self = .removeEffect(try RemoveEffect(from: decoder))
        case "addTransition": self = .addTransition(try AddTransition(from: decoder))
        case "updateTransition": self = .updateTransition(try UpdateTransition(from: decoder))
        case "removeTransition": self = .removeTransition(try RemoveTransition(from: decoder))
        case "linkClips": self = .linkClips(try LinkClips(from: decoder))
        case "unlinkClips": self = .unlinkClips(try UnlinkClips(from: decoder))
        case "addCaptionTrack": self = .addCaptionTrack(try AddCaptionTrack(from: decoder))
        case "replaceCaptions": self = .replaceCaptions(try ReplaceCaptions(from: decoder))
        case "editCaption": self = .editCaption(try EditCaption(from: decoder))
        case "setCaptionStyle": self = .setCaptionStyle(try SetCaptionStyle(from: decoder))
        case "addMarker": self = .addMarker(try AddMarker(from: decoder))
        case "moveMarker": self = .moveMarker(try MoveMarker(from: decoder))
        case "removeMarker": self = .removeMarker(try RemoveMarker(from: decoder))
        case "undo": self = .undo(try Undo(from: decoder))
        case "redo": self = .redo
        case "batch": self = .batch(try Batch(from: decoder).operations)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown operation \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: TypeKey.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .createProject(let op): try op.encode(to: encoder)
        case .setProjectSettings(let op): try op.encode(to: encoder)
        case .renameProject(let op): try op.encode(to: encoder)
        case .addSequence(let op): try op.encode(to: encoder)
        case .setSequenceSettings(let op): try op.encode(to: encoder)
        case .setActiveSequence(let op): try op.encode(to: encoder)
        case .importAsset(let op): try op.encode(to: encoder)
        case .relinkAsset(let op): try op.encode(to: encoder)
        case .removeAsset(let op): try op.encode(to: encoder)
        case .restoreAsset(let op): try op.encode(to: encoder)
        case .recordAssetAnalysis(let op): try op.encode(to: encoder)
        case .addTrack(let op): try op.encode(to: encoder)
        case .removeTrack(let op): try op.encode(to: encoder)
        case .reorderTrack(let op): try op.encode(to: encoder)
        case .renameTrack(let op): try op.encode(to: encoder)
        case .setTrackMuted(let op): try op.encode(to: encoder)
        case .setTrackLocked(let op): try op.encode(to: encoder)
        case .addClip(let op): try op.encode(to: encoder)
        case .moveClip(let op): try op.encode(to: encoder)
        case .trimClip(let op): try op.encode(to: encoder)
        case .splitClip(let op): try op.encode(to: encoder)
        case .joinClips(let op): try op.encode(to: encoder)
        case .removeClip(let op): try op.encode(to: encoder)
        case .setClipSpeed(let op): try op.encode(to: encoder)
        case .setClipTransform(let op): try op.encode(to: encoder)
        case .setClipOpacity(let op): try op.encode(to: encoder)
        case .setClipAudio(let op): try op.encode(to: encoder)
        case .addEffect(let op): try op.encode(to: encoder)
        case .updateEffect(let op): try op.encode(to: encoder)
        case .removeEffect(let op): try op.encode(to: encoder)
        case .addTransition(let op): try op.encode(to: encoder)
        case .updateTransition(let op): try op.encode(to: encoder)
        case .removeTransition(let op): try op.encode(to: encoder)
        case .linkClips(let op): try op.encode(to: encoder)
        case .unlinkClips(let op): try op.encode(to: encoder)
        case .addCaptionTrack(let op): try op.encode(to: encoder)
        case .replaceCaptions(let op): try op.encode(to: encoder)
        case .editCaption(let op): try op.encode(to: encoder)
        case .setCaptionStyle(let op): try op.encode(to: encoder)
        case .addMarker(let op): try op.encode(to: encoder)
        case .moveMarker(let op): try op.encode(to: encoder)
        case .removeMarker(let op): try op.encode(to: encoder)
        case .undo(let op): try op.encode(to: encoder)
        case .redo: try Empty().encode(to: encoder)
        case .batch(let ops): try Batch(operations: ops).encode(to: encoder)
        }
    }
}
