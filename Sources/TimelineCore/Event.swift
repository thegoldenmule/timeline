import Foundation

/// A fact about the project, in past tense. Carries the envelope the store persists per row;
/// `payload` carries the change with enough before/after data to be inverted without state.
public struct DomainEvent: Hashable, Sendable {
    public var eventId: EventID
    /// Groups the events of one command; the undo unit.
    public var txnId: TransactionID
    public var commandId: CommandID
    public var actor: Actor
    public var occurredAt: Date
    public var schemaVersion: Int
    /// The event that caused this one, e.g. the original event a compensating event inverts.
    public var causationId: EventID?
    public var metadata: [String: JSONValue]?
    public var payload: EventPayload

    public init(
        eventId: EventID, txnId: TransactionID, commandId: CommandID, actor: Actor, occurredAt: Date,
        schemaVersion: Int = Upcaster.currentSchemaVersion, causationId: EventID? = nil,
        metadata: [String: JSONValue]? = nil, payload: EventPayload
    ) {
        self.eventId = eventId
        self.txnId = txnId
        self.commandId = commandId
        self.actor = actor
        self.occurredAt = occurredAt
        self.schemaVersion = schemaVersion
        self.causationId = causationId
        self.metadata = metadata
        self.payload = payload
    }

    public var type: String { payload.typeName }
}

/// Snapshot-free description of an asset's location, for `AssetRelinked`.
public struct AssetLocation: Hashable, Sendable, Codable {
    public var libraryPath: String
    public var offline: Bool

    public init(libraryPath: String, offline: Bool) {
        self.libraryPath = libraryPath
        self.offline = offline
    }
}

/// Every event type. Encodes as `{ "type": "<PascalCaseName>", ...fields }`; every timeline event
/// carries `sequenceId`, and every embedded clip snapshot carries `clipSchema`.
public enum EventPayload: Hashable, Sendable {
    case projectCreated(ProjectCreated)
    case projectSettingsChanged(ProjectSettingsChanged)
    case projectRenamed(ProjectRenamed)
    case sequenceAdded(SequenceAdded)
    case sequenceSettingsChanged(SequenceSettingsChanged)
    case activeSequenceChanged(ActiveSequenceChanged)
    case assetImported(AssetImported)
    case assetRelinked(AssetRelinked)
    case assetRemoved(AssetRemoved)
    case assetRestored(AssetRestored)
    case assetAnalysisRecorded(AssetAnalysisRecorded)
    case trackAdded(TrackAdded)
    case trackRemoved(TrackRemoved)
    case trackRestored(TrackRestored)
    case trackReordered(TrackReordered)
    case trackRenamed(TrackRenamed)
    case trackMuteSet(TrackMuteSet)
    case trackLockSet(TrackLockSet)
    case trackSoloSet(TrackSoloSet)
    case clipAdded(ClipAdded)
    case clipRemoved(ClipRemoved)
    case clipMoved(ClipMoved)
    case clipTrimmed(ClipTrimmed)
    case clipSplit(ClipSplit)
    case clipsJoined(ClipsJoined)
    case clipSpeedSet(ClipSpeedSet)
    case clipTransformSet(ClipTransformSet)
    case clipOpacitySet(ClipOpacitySet)
    case clipAudioSet(ClipAudioSet)
    case clipEffectAdded(ClipEffectAdded)
    case clipEffectChanged(ClipEffectChanged)
    case clipEffectRemoved(ClipEffectRemoved)
    case clipsLinked(ClipsLinked)
    case clipsUnlinked(ClipsUnlinked)
    case transitionAdded(TransitionAdded)
    case transitionChanged(TransitionChanged)
    case transitionRemoved(TransitionRemoved)
    case captionTrackAdded(CaptionTrackAdded)
    case captionsReplaced(CaptionsReplaced)
    case captionEdited(CaptionEdited)
    case captionStyleSet(CaptionStyleSet)
    case markerAdded(MarkerAdded)
    case markerMoved(MarkerMoved)
    case markerRemoved(MarkerRemoved)
    case transactionUndone(TransactionUndone)
    case transactionRedone(TransactionRedone)

    // MARK: Project

    public struct ProjectCreated: Hashable, Sendable, Codable {
        public var projectId: ProjectID
        public var name: String
        public var settings: ProjectSettings
        /// The first sequence, with no tracks.
        public var sequence: Sequence
        public init(projectId: ProjectID, name: String, settings: ProjectSettings, sequence: Sequence) {
            self.projectId = projectId
            self.name = name
            self.settings = settings
            self.sequence = sequence
        }
    }

    public struct ProjectSettingsChanged: Hashable, Sendable, Codable {
        public var before: ProjectSettings
        public var after: ProjectSettings
        public init(before: ProjectSettings, after: ProjectSettings) {
            self.before = before
            self.after = after
        }
    }

    public struct ProjectRenamed: Hashable, Sendable, Codable {
        public var before: String
        public var after: String
        public init(before: String, after: String) {
            self.before = before
            self.after = after
        }
    }

    public struct SequenceAdded: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var name: String
        public var frameDuration: RationalTime
        public var width: Int
        public var height: Int
        public init(sequenceId: SequenceID, name: String, frameDuration: RationalTime, width: Int, height: Int) {
            self.sequenceId = sequenceId
            self.name = name
            self.frameDuration = frameDuration
            self.width = width
            self.height = height
        }
    }

    public struct SequenceSettingsChanged: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var before: SequenceSettings
        public var after: SequenceSettings
        public init(sequenceId: SequenceID, before: SequenceSettings, after: SequenceSettings) {
            self.sequenceId = sequenceId
            self.before = before
            self.after = after
        }
    }

    public struct ActiveSequenceChanged: Hashable, Sendable, Codable {
        public var before: SequenceID?
        public var after: SequenceID?
        public init(before: SequenceID?, after: SequenceID?) {
            self.before = before
            self.after = after
        }
    }

    // MARK: Assets

    public struct AssetImported: Hashable, Sendable, Codable {
        public var assetId: AssetID
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

        public init(_ asset: Asset) {
            assetId = asset.id
            contentHash = asset.contentHash
            libraryPath = asset.libraryPath
            displayName = asset.displayName
            kind = asset.kind
            duration = asset.duration
            hasVideo = asset.hasVideo
            hasAudio = asset.hasAudio
            sampleRate = asset.sampleRate
            frameDuration = asset.frameDuration
            probe = asset.probe
        }

        public var asset: Asset {
            Asset(
                id: assetId, contentHash: contentHash, libraryPath: libraryPath, displayName: displayName, kind: kind,
                duration: duration, hasVideo: hasVideo, hasAudio: hasAudio, sampleRate: sampleRate,
                frameDuration: frameDuration, probe: probe)
        }
    }

    public struct AssetRelinked: Hashable, Sendable, Codable {
        public var assetId: AssetID
        public var before: AssetLocation
        public var after: AssetLocation
        public init(assetId: AssetID, before: AssetLocation, after: AssetLocation) {
            self.assetId = assetId
            self.before = before
            self.after = after
        }
    }

    public struct AssetRemoved: Hashable, Sendable, Codable {
        public var assetId: AssetID
        public var snapshot: Asset
        public init(assetId: AssetID, snapshot: Asset) {
            self.assetId = assetId
            self.snapshot = snapshot
        }
    }

    public struct AssetRestored: Hashable, Sendable, Codable {
        public var assetId: AssetID
        public var snapshot: Asset
        public init(assetId: AssetID, snapshot: Asset) {
            self.assetId = assetId
            self.snapshot = snapshot
        }
    }

    public struct AssetAnalysisRecorded: Hashable, Sendable, Codable {
        public var assetId: AssetID
        public var kind: String
        public var cacheKey: String
        public var summary: JSONValue?
        public var before: AssetAnalysis?
        public init(assetId: AssetID, kind: String, cacheKey: String, summary: JSONValue?, before: AssetAnalysis?) {
            self.assetId = assetId
            self.kind = kind
            self.cacheKey = cacheKey
            self.summary = summary
            self.before = before
        }

        public var after: AssetAnalysis { AssetAnalysis(kind: kind, cacheKey: cacheKey, summary: summary) }
    }

    // MARK: Tracks

    public struct TrackAdded: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var trackId: TrackID
        public var kind: TrackKind
        public var position: Int
        public var name: String
        public init(sequenceId: SequenceID, trackId: TrackID, kind: TrackKind, position: Int, name: String) {
            self.sequenceId = sequenceId
            self.trackId = trackId
            self.kind = kind
            self.position = position
            self.name = name
        }
    }

    public struct TrackRemoved: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var trackId: TrackID
        public var position: Int
        public var snapshot: Track
        public var clipSchema: Int
        public init(
            sequenceId: SequenceID, trackId: TrackID, position: Int, snapshot: Track,
            clipSchema: Int = Upcaster.currentClipSchema
        ) {
            self.sequenceId = sequenceId
            self.trackId = trackId
            self.position = position
            self.snapshot = snapshot
            self.clipSchema = clipSchema
        }
    }

    public struct TrackRestored: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var trackId: TrackID
        public var position: Int
        public var snapshot: Track
        public var clipSchema: Int
        public init(
            sequenceId: SequenceID, trackId: TrackID, position: Int, snapshot: Track,
            clipSchema: Int = Upcaster.currentClipSchema
        ) {
            self.sequenceId = sequenceId
            self.trackId = trackId
            self.position = position
            self.snapshot = snapshot
            self.clipSchema = clipSchema
        }
    }

    public struct TrackReordered: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var trackId: TrackID
        public var before: Int
        public var after: Int
        public init(sequenceId: SequenceID, trackId: TrackID, before: Int, after: Int) {
            self.sequenceId = sequenceId
            self.trackId = trackId
            self.before = before
            self.after = after
        }
    }

    public struct TrackRenamed: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var trackId: TrackID
        public var before: String
        public var after: String
        public init(sequenceId: SequenceID, trackId: TrackID, before: String, after: String) {
            self.sequenceId = sequenceId
            self.trackId = trackId
            self.before = before
            self.after = after
        }
    }

    public struct TrackMuteSet: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var trackId: TrackID
        public var before: Bool
        public var after: Bool
        public init(sequenceId: SequenceID, trackId: TrackID, before: Bool, after: Bool) {
            self.sequenceId = sequenceId
            self.trackId = trackId
            self.before = before
            self.after = after
        }
    }

    public struct TrackLockSet: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var trackId: TrackID
        public var before: Bool
        public var after: Bool
        public init(sequenceId: SequenceID, trackId: TrackID, before: Bool, after: Bool) {
            self.sequenceId = sequenceId
            self.trackId = trackId
            self.before = before
            self.after = after
        }
    }

    /// Only this track's own flag; which of its peers fall silent follows from `Sequence.silence(of:)`
    /// and is never recorded, so the rule can change without rewriting history.
    public struct TrackSoloSet: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var trackId: TrackID
        public var before: Bool
        public var after: Bool
        public init(sequenceId: SequenceID, trackId: TrackID, before: Bool, after: Bool) {
            self.sequenceId = sequenceId
            self.trackId = trackId
            self.before = before
            self.after = after
        }
    }

    // MARK: Clips

    public struct ClipAdded: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var snapshot: Clip
        public var clipSchema: Int
        public init(
            sequenceId: SequenceID, clipId: ClipID, snapshot: Clip, clipSchema: Int = Upcaster.currentClipSchema
        ) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.snapshot = snapshot
            self.clipSchema = clipSchema
        }
    }

    public struct ClipRemoved: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var snapshot: Clip
        public var clipSchema: Int
        public init(
            sequenceId: SequenceID, clipId: ClipID, snapshot: Clip, clipSchema: Int = Upcaster.currentClipSchema
        ) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.snapshot = snapshot
            self.clipSchema = clipSchema
        }
    }

    public struct ClipMoved: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var before: ClipPlacement
        public var after: ClipPlacement
        public init(sequenceId: SequenceID, clipId: ClipID, before: ClipPlacement, after: ClipPlacement) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.before = before
            self.after = after
        }
    }

    public struct ClipTrimmed: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var edge: Edge
        public var before: ClipRange
        public var after: ClipRange
        public init(sequenceId: SequenceID, clipId: ClipID, edge: Edge, before: ClipRange, after: ClipRange) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.edge = edge
            self.before = before
            self.after = after
        }
    }

    /// `clipId` keeps the head (`after` range); `newClip` is the tail, starting at `at`.
    public struct ClipSplit: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var at: RationalTime
        public var newClipId: ClipID
        public var before: ClipRange
        public var after: ClipRange
        public var newClip: Clip
        public var clipSchema: Int
        public init(
            sequenceId: SequenceID, clipId: ClipID, at: RationalTime, newClipId: ClipID, before: ClipRange,
            after: ClipRange, newClip: Clip, clipSchema: Int = Upcaster.currentClipSchema
        ) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.at = at
            self.newClipId = newClipId
            self.before = before
            self.after = after
            self.newClip = newClip
            self.clipSchema = clipSchema
        }
    }

    public struct ClipsJoined: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var keptClipId: ClipID
        public var removedClipId: ClipID
        public var keptBefore: ClipRange
        public var keptAfter: ClipRange
        public var removedSnapshot: Clip
        public var clipSchema: Int
        public init(
            sequenceId: SequenceID, keptClipId: ClipID, removedClipId: ClipID, keptBefore: ClipRange,
            keptAfter: ClipRange, removedSnapshot: Clip, clipSchema: Int = Upcaster.currentClipSchema
        ) {
            self.sequenceId = sequenceId
            self.keptClipId = keptClipId
            self.removedClipId = removedClipId
            self.keptBefore = keptBefore
            self.keptAfter = keptAfter
            self.removedSnapshot = removedSnapshot
            self.clipSchema = clipSchema
        }
    }

    public struct ClipSpeedSet: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var before: Rational
        public var after: Rational
        public init(sequenceId: SequenceID, clipId: ClipID, before: Rational, after: Rational) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.before = before
            self.after = after
        }
    }

    public struct ClipTransformSet: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var before: Animatable<Transform>
        public var after: Animatable<Transform>
        public init(sequenceId: SequenceID, clipId: ClipID, before: Animatable<Transform>, after: Animatable<Transform>)
        {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.before = before
            self.after = after
        }
    }

    public struct ClipOpacitySet: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var before: Animatable<Double>
        public var after: Animatable<Double>
        public init(sequenceId: SequenceID, clipId: ClipID, before: Animatable<Double>, after: Animatable<Double>) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.before = before
            self.after = after
        }
    }

    public struct ClipAudioSet: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var before: ClipAudio
        public var after: ClipAudio
        public init(sequenceId: SequenceID, clipId: ClipID, before: ClipAudio, after: ClipAudio) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.before = before
            self.after = after
        }
    }

    public struct ClipEffectAdded: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var effectId: EffectID
        public var index: Int
        public var after: Effect
        public init(sequenceId: SequenceID, clipId: ClipID, effectId: EffectID, index: Int, after: Effect) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.effectId = effectId
            self.index = index
            self.after = after
        }
    }

    public struct ClipEffectChanged: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var effectId: EffectID
        public var before: Effect
        public var after: Effect
        public init(sequenceId: SequenceID, clipId: ClipID, effectId: EffectID, before: Effect, after: Effect) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.effectId = effectId
            self.before = before
            self.after = after
        }
    }

    public struct ClipEffectRemoved: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var effectId: EffectID
        public var index: Int
        public var before: Effect
        public init(sequenceId: SequenceID, clipId: ClipID, effectId: EffectID, index: Int, before: Effect) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.effectId = effectId
            self.index = index
            self.before = before
        }
    }

    public struct ClipsLinked: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var linkGroupId: LinkGroupID
        /// Only the clips that joined the group (members already in it are not listed).
        public var clipIds: [ClipID]
        public init(sequenceId: SequenceID, linkGroupId: LinkGroupID, clipIds: [ClipID]) {
            self.sequenceId = sequenceId
            self.linkGroupId = linkGroupId
            self.clipIds = clipIds
        }
    }

    public struct ClipsUnlinked: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var linkGroupId: LinkGroupID
        public var clipIds: [ClipID]
        public init(sequenceId: SequenceID, linkGroupId: LinkGroupID, clipIds: [ClipID]) {
            self.sequenceId = sequenceId
            self.linkGroupId = linkGroupId
            self.clipIds = clipIds
        }
    }

    // MARK: Transitions

    public struct TransitionAdded: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var transitionId: TransitionID
        public var after: Transition
        public init(sequenceId: SequenceID, transitionId: TransitionID, after: Transition) {
            self.sequenceId = sequenceId
            self.transitionId = transitionId
            self.after = after
        }
    }

    public struct TransitionChanged: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var transitionId: TransitionID
        public var before: Transition
        public var after: Transition
        public init(sequenceId: SequenceID, transitionId: TransitionID, before: Transition, after: Transition) {
            self.sequenceId = sequenceId
            self.transitionId = transitionId
            self.before = before
            self.after = after
        }
    }

    public struct TransitionRemoved: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var transitionId: TransitionID
        public var before: Transition
        public init(sequenceId: SequenceID, transitionId: TransitionID, before: Transition) {
            self.sequenceId = sequenceId
            self.transitionId = transitionId
            self.before = before
        }
    }

    // MARK: Captions

    public struct CaptionTrackAdded: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var trackId: TrackID
        public var name: String
        public var position: Int
        public var language: String
        public var style: CaptionStyle?
        public init(
            sequenceId: SequenceID, trackId: TrackID, name: String, position: Int, language: String,
            style: CaptionStyle?
        ) {
            self.sequenceId = sequenceId
            self.trackId = trackId
            self.name = name
            self.position = position
            self.language = language
            self.style = style
        }
    }

    public struct CaptionsReplaced: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var trackId: TrackID
        public var before: [Clip]
        public var after: [Clip]
        public var clipSchema: Int
        public init(
            sequenceId: SequenceID, trackId: TrackID, before: [Clip], after: [Clip],
            clipSchema: Int = Upcaster.currentClipSchema
        ) {
            self.sequenceId = sequenceId
            self.trackId = trackId
            self.before = before
            self.after = after
            self.clipSchema = clipSchema
        }
    }

    public struct CaptionEdited: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var clipId: ClipID
        public var before: CaptionItem
        public var after: CaptionItem
        public init(sequenceId: SequenceID, clipId: ClipID, before: CaptionItem, after: CaptionItem) {
            self.sequenceId = sequenceId
            self.clipId = clipId
            self.before = before
            self.after = after
        }
    }

    /// `clipId` nil: the track's default style changed; otherwise one item's override.
    public struct CaptionStyleSet: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var trackId: TrackID
        public var clipId: ClipID?
        public var before: CaptionStyle?
        public var after: CaptionStyle?
        public init(
            sequenceId: SequenceID, trackId: TrackID, clipId: ClipID?, before: CaptionStyle?, after: CaptionStyle?
        ) {
            self.sequenceId = sequenceId
            self.trackId = trackId
            self.clipId = clipId
            self.before = before
            self.after = after
        }
    }

    // MARK: Markers

    public struct MarkerAdded: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var markerId: MarkerID
        public var after: Marker
        public init(sequenceId: SequenceID, markerId: MarkerID, after: Marker) {
            self.sequenceId = sequenceId
            self.markerId = markerId
            self.after = after
        }
    }

    public struct MarkerMoved: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var markerId: MarkerID
        public var before: RationalTime
        public var after: RationalTime
        public init(sequenceId: SequenceID, markerId: MarkerID, before: RationalTime, after: RationalTime) {
            self.sequenceId = sequenceId
            self.markerId = markerId
            self.before = before
            self.after = after
        }
    }

    public struct MarkerRemoved: Hashable, Sendable, Codable {
        public var sequenceId: SequenceID
        public var markerId: MarkerID
        public var before: Marker
        public init(sequenceId: SequenceID, markerId: MarkerID, before: Marker) {
            self.sequenceId = sequenceId
            self.markerId = markerId
            self.before = before
        }
    }

    // MARK: History markers

    public struct TransactionUndone: Hashable, Sendable, Codable {
        public var targetTxnId: TransactionID
        public init(targetTxnId: TransactionID) { self.targetTxnId = targetTxnId }
    }

    public struct TransactionRedone: Hashable, Sendable, Codable {
        public var targetTxnId: TransactionID
        public init(targetTxnId: TransactionID) { self.targetTxnId = targetTxnId }
    }
}

// MARK: - Names and ids

extension EventPayload {
    /// The `"type"` discriminator: `<Aggregate><Verb>` in PascalCase.
    public var typeName: String {
        switch self {
        case .projectCreated: "ProjectCreated"
        case .projectSettingsChanged: "ProjectSettingsChanged"
        case .projectRenamed: "ProjectRenamed"
        case .sequenceAdded: "SequenceAdded"
        case .sequenceSettingsChanged: "SequenceSettingsChanged"
        case .activeSequenceChanged: "ActiveSequenceChanged"
        case .assetImported: "AssetImported"
        case .assetRelinked: "AssetRelinked"
        case .assetRemoved: "AssetRemoved"
        case .assetRestored: "AssetRestored"
        case .assetAnalysisRecorded: "AssetAnalysisRecorded"
        case .trackAdded: "TrackAdded"
        case .trackRemoved: "TrackRemoved"
        case .trackRestored: "TrackRestored"
        case .trackReordered: "TrackReordered"
        case .trackRenamed: "TrackRenamed"
        case .trackMuteSet: "TrackMuteSet"
        case .trackLockSet: "TrackLockSet"
        case .trackSoloSet: "TrackSoloSet"
        case .clipAdded: "ClipAdded"
        case .clipRemoved: "ClipRemoved"
        case .clipMoved: "ClipMoved"
        case .clipTrimmed: "ClipTrimmed"
        case .clipSplit: "ClipSplit"
        case .clipsJoined: "ClipsJoined"
        case .clipSpeedSet: "ClipSpeedSet"
        case .clipTransformSet: "ClipTransformSet"
        case .clipOpacitySet: "ClipOpacitySet"
        case .clipAudioSet: "ClipAudioSet"
        case .clipEffectAdded: "ClipEffectAdded"
        case .clipEffectChanged: "ClipEffectChanged"
        case .clipEffectRemoved: "ClipEffectRemoved"
        case .clipsLinked: "ClipsLinked"
        case .clipsUnlinked: "ClipsUnlinked"
        case .transitionAdded: "TransitionAdded"
        case .transitionChanged: "TransitionChanged"
        case .transitionRemoved: "TransitionRemoved"
        case .captionTrackAdded: "CaptionTrackAdded"
        case .captionsReplaced: "CaptionsReplaced"
        case .captionEdited: "CaptionEdited"
        case .captionStyleSet: "CaptionStyleSet"
        case .markerAdded: "MarkerAdded"
        case .markerMoved: "MarkerMoved"
        case .markerRemoved: "MarkerRemoved"
        case .transactionUndone: "TransactionUndone"
        case .transactionRedone: "TransactionRedone"
        }
    }

    public static let allTypeNames: [String] = [
        "ProjectCreated", "ProjectSettingsChanged", "ProjectRenamed", "SequenceAdded", "SequenceSettingsChanged",
        "ActiveSequenceChanged", "AssetImported", "AssetRelinked", "AssetRemoved", "AssetRestored",
        "AssetAnalysisRecorded", "TrackAdded", "TrackRemoved", "TrackRestored", "TrackReordered", "TrackRenamed",
        "TrackMuteSet", "TrackLockSet", "TrackSoloSet", "ClipAdded", "ClipRemoved", "ClipMoved", "ClipTrimmed",
        "ClipSplit",
        "ClipsJoined", "ClipSpeedSet", "ClipTransformSet", "ClipOpacitySet", "ClipAudioSet", "ClipEffectAdded",
        "ClipEffectChanged", "ClipEffectRemoved", "ClipsLinked", "ClipsUnlinked", "TransitionAdded",
        "TransitionChanged", "TransitionRemoved", "CaptionTrackAdded", "CaptionsReplaced", "CaptionEdited",
        "CaptionStyleSet", "MarkerAdded", "MarkerMoved", "MarkerRemoved", "TransactionUndone", "TransactionRedone",
    ]

    /// True for `TransactionUndone` and `TransactionRedone`.
    public var isHistoryMarker: Bool {
        switch self {
        case .transactionUndone, .transactionRedone: true
        default: false
        }
    }

    /// The sequence a timeline event belongs to; nil for project and asset events.
    public var sequenceId: SequenceID? {
        switch self {
        case .projectCreated, .projectSettingsChanged, .projectRenamed, .activeSequenceChanged, .assetImported,
            .assetRelinked, .assetRemoved, .assetRestored, .assetAnalysisRecorded, .transactionUndone,
            .transactionRedone:
            nil
        case .sequenceAdded(let p): p.sequenceId
        case .sequenceSettingsChanged(let p): p.sequenceId
        case .trackAdded(let p): p.sequenceId
        case .trackRemoved(let p): p.sequenceId
        case .trackRestored(let p): p.sequenceId
        case .trackReordered(let p): p.sequenceId
        case .trackRenamed(let p): p.sequenceId
        case .trackMuteSet(let p): p.sequenceId
        case .trackLockSet(let p): p.sequenceId
        case .trackSoloSet(let p): p.sequenceId
        case .clipAdded(let p): p.sequenceId
        case .clipRemoved(let p): p.sequenceId
        case .clipMoved(let p): p.sequenceId
        case .clipTrimmed(let p): p.sequenceId
        case .clipSplit(let p): p.sequenceId
        case .clipsJoined(let p): p.sequenceId
        case .clipSpeedSet(let p): p.sequenceId
        case .clipTransformSet(let p): p.sequenceId
        case .clipOpacitySet(let p): p.sequenceId
        case .clipAudioSet(let p): p.sequenceId
        case .clipEffectAdded(let p): p.sequenceId
        case .clipEffectChanged(let p): p.sequenceId
        case .clipEffectRemoved(let p): p.sequenceId
        case .clipsLinked(let p): p.sequenceId
        case .clipsUnlinked(let p): p.sequenceId
        case .transitionAdded(let p): p.sequenceId
        case .transitionChanged(let p): p.sequenceId
        case .transitionRemoved(let p): p.sequenceId
        case .captionTrackAdded(let p): p.sequenceId
        case .captionsReplaced(let p): p.sequenceId
        case .captionEdited(let p): p.sequenceId
        case .captionStyleSet(let p): p.sequenceId
        case .markerAdded(let p): p.sequenceId
        case .markerMoved(let p): p.sequenceId
        case .markerRemoved(let p): p.sequenceId
        }
    }

    /// The single clip a clip event addresses (what the store indexes as `clip_id`).
    public var clipId: ClipID? {
        switch self {
        case .clipAdded(let p): p.clipId
        case .clipRemoved(let p): p.clipId
        case .clipMoved(let p): p.clipId
        case .clipTrimmed(let p): p.clipId
        case .clipSplit(let p): p.clipId
        case .clipsJoined(let p): p.keptClipId
        case .clipSpeedSet(let p): p.clipId
        case .clipTransformSet(let p): p.clipId
        case .clipOpacitySet(let p): p.clipId
        case .clipAudioSet(let p): p.clipId
        case .clipEffectAdded(let p): p.clipId
        case .clipEffectChanged(let p): p.clipId
        case .clipEffectRemoved(let p): p.clipId
        case .captionEdited(let p): p.clipId
        case .captionStyleSet(let p): p.clipId
        default: nil
        }
    }

    /// Every entity id this event touches, for `changedIds`.
    public var touchedIds: [String] {
        switch self {
        case .projectCreated(let p): [p.projectId.rawValue, p.sequence.id.rawValue]
        case .projectSettingsChanged, .projectRenamed: []
        case .sequenceAdded(let p): [p.sequenceId.rawValue]
        case .sequenceSettingsChanged(let p): [p.sequenceId.rawValue]
        case .activeSequenceChanged(let p): [p.before?.rawValue, p.after?.rawValue].compactMap { $0 }
        case .assetImported(let p): [p.assetId.rawValue]
        case .assetRelinked(let p): [p.assetId.rawValue]
        case .assetRemoved(let p): [p.assetId.rawValue]
        case .assetRestored(let p): [p.assetId.rawValue]
        case .assetAnalysisRecorded(let p): [p.assetId.rawValue]
        case .trackAdded(let p): [p.trackId.rawValue]
        case .trackRemoved(let p): [p.trackId.rawValue] + p.snapshot.clips.keys.map(\.rawValue).sorted()
        case .trackRestored(let p): [p.trackId.rawValue] + p.snapshot.clips.keys.map(\.rawValue).sorted()
        case .trackReordered(let p): [p.trackId.rawValue]
        case .trackRenamed(let p): [p.trackId.rawValue]
        case .trackMuteSet(let p): [p.trackId.rawValue]
        case .trackLockSet(let p): [p.trackId.rawValue]
        case .trackSoloSet(let p): [p.trackId.rawValue]
        case .clipAdded(let p): [p.clipId.rawValue]
        case .clipRemoved(let p): [p.clipId.rawValue]
        case .clipMoved(let p): [p.clipId.rawValue]
        case .clipTrimmed(let p): [p.clipId.rawValue]
        case .clipSplit(let p): [p.clipId.rawValue, p.newClipId.rawValue]
        case .clipsJoined(let p): [p.keptClipId.rawValue, p.removedClipId.rawValue]
        case .clipSpeedSet(let p): [p.clipId.rawValue]
        case .clipTransformSet(let p): [p.clipId.rawValue]
        case .clipOpacitySet(let p): [p.clipId.rawValue]
        case .clipAudioSet(let p): [p.clipId.rawValue]
        case .clipEffectAdded(let p): [p.clipId.rawValue, p.effectId.rawValue]
        case .clipEffectChanged(let p): [p.clipId.rawValue, p.effectId.rawValue]
        case .clipEffectRemoved(let p): [p.clipId.rawValue, p.effectId.rawValue]
        case .clipsLinked(let p): [p.linkGroupId.rawValue] + p.clipIds.map(\.rawValue)
        case .clipsUnlinked(let p): [p.linkGroupId.rawValue] + p.clipIds.map(\.rawValue)
        case .transitionAdded(let p): [p.transitionId.rawValue]
        case .transitionChanged(let p): [p.transitionId.rawValue]
        case .transitionRemoved(let p): [p.transitionId.rawValue]
        case .captionTrackAdded(let p): [p.trackId.rawValue]
        case .captionsReplaced(let p):
            [p.trackId.rawValue] + (p.before + p.after).map(\.id.rawValue)
        case .captionEdited(let p): [p.clipId.rawValue]
        case .captionStyleSet(let p): [p.clipId?.rawValue ?? p.trackId.rawValue]
        case .markerAdded(let p): [p.markerId.rawValue]
        case .markerMoved(let p): [p.markerId.rawValue]
        case .markerRemoved(let p): [p.markerId.rawValue]
        case .transactionUndone(let p): [p.targetTxnId.rawValue]
        case .transactionRedone(let p): [p.targetTxnId.rawValue]
        }
    }

    /// One line for `ChangedSince` and logs.
    public var summary: String {
        switch self {
        case .projectCreated(let p): "Created project \(p.name)"
        case .projectSettingsChanged: "Changed project settings"
        case .projectRenamed(let p): "Renamed project to \(p.after)"
        case .sequenceAdded(let p): "Added sequence \(p.name)"
        case .sequenceSettingsChanged(let p): "Changed settings of sequence \(p.sequenceId)"
        case .activeSequenceChanged(let p): "Switched to sequence \(p.after?.rawValue ?? "none")"
        case .assetImported(let p): "Imported \(p.displayName)"
        case .assetRelinked(let p): "Relinked asset \(p.assetId) to \(p.after.libraryPath)"
        case .assetRemoved(let p): "Removed asset \(p.assetId)"
        case .assetRestored(let p): "Restored asset \(p.assetId)"
        case .assetAnalysisRecorded(let p): "Recorded \(p.kind) analysis for asset \(p.assetId)"
        case .trackAdded(let p): "Added \(p.kind.rawValue) track \(p.name)"
        case .trackRemoved(let p): "Removed track \(p.snapshot.name)"
        case .trackRestored(let p): "Restored track \(p.snapshot.name)"
        case .trackReordered(let p): "Moved track \(p.trackId) to position \(p.after)"
        case .trackRenamed(let p): "Renamed track to \(p.after)"
        case .trackMuteSet(let p): p.after ? "Muted track \(p.trackId)" : "Unmuted track \(p.trackId)"
        case .trackLockSet(let p): p.after ? "Locked track \(p.trackId)" : "Unlocked track \(p.trackId)"
        case .trackSoloSet(let p): p.after ? "Soloed track \(p.trackId)" : "Unsoloed track \(p.trackId)"
        case .clipAdded(let p): "Added clip \(p.clipId) at \(p.snapshot.start)"
        case .clipRemoved(let p): "Removed clip \(p.clipId)"
        case .clipMoved(let p): "Moved clip \(p.clipId) to \(p.after.start)"
        case .clipTrimmed(let p): "Trimmed \(p.edge.rawValue) of clip \(p.clipId)"
        case .clipSplit(let p): "Split clip \(p.clipId) at \(p.at)"
        case .clipsJoined(let p): "Joined clip \(p.removedClipId) into \(p.keptClipId)"
        case .clipSpeedSet(let p): "Set speed of clip \(p.clipId) to \(p.after)"
        case .clipTransformSet(let p): "Changed transform of clip \(p.clipId)"
        case .clipOpacitySet(let p): "Changed opacity of clip \(p.clipId)"
        case .clipAudioSet(let p): "Changed audio of clip \(p.clipId)"
        case .clipEffectAdded(let p): "Added \(p.after.kind) effect to clip \(p.clipId)"
        case .clipEffectChanged(let p): "Changed \(p.after.kind) effect on clip \(p.clipId)"
        case .clipEffectRemoved(let p): "Removed \(p.before.kind) effect from clip \(p.clipId)"
        case .clipsLinked(let p): "Linked \(p.clipIds.count) clips"
        case .clipsUnlinked(let p): "Unlinked \(p.clipIds.count) clips"
        case .transitionAdded(let p): "Added \(p.after.kind) transition"
        case .transitionChanged(let p): "Changed transition \(p.transitionId)"
        case .transitionRemoved(let p): "Removed transition \(p.transitionId)"
        case .captionTrackAdded(let p): "Added caption track \(p.name)"
        case .captionsReplaced(let p): "Replaced captions on track \(p.trackId) (\(p.after.count) items)"
        case .captionEdited(let p): "Edited caption \(p.clipId)"
        case .captionStyleSet(let p): "Changed caption style on \(p.clipId?.rawValue ?? p.trackId.rawValue)"
        case .markerAdded(let p): "Added marker \(p.after.label)"
        case .markerMoved(let p): "Moved marker \(p.markerId) to \(p.after)"
        case .markerRemoved(let p): "Removed marker \(p.before.label)"
        case .transactionUndone(let p): "Undid transaction \(p.targetTxnId)"
        case .transactionRedone(let p): "Redid transaction \(p.targetTxnId)"
        }
    }
}

// MARK: - Codable

extension EventPayload: Codable {
    private enum TypeKey: String, CodingKey {
        case type
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        let type = try c.decode(String.self, forKey: .type)
        self = try EventPayload(type: type, fields: decoder)
    }

    /// Decodes the fields of an event of `type` (a payload without its `"type"` key).
    public init(type: String, fields decoder: any Decoder) throws {
        switch type {
        case "ProjectCreated": self = .projectCreated(try ProjectCreated(from: decoder))
        case "ProjectSettingsChanged": self = .projectSettingsChanged(try ProjectSettingsChanged(from: decoder))
        case "ProjectRenamed": self = .projectRenamed(try ProjectRenamed(from: decoder))
        case "SequenceAdded": self = .sequenceAdded(try SequenceAdded(from: decoder))
        case "SequenceSettingsChanged": self = .sequenceSettingsChanged(try SequenceSettingsChanged(from: decoder))
        case "ActiveSequenceChanged": self = .activeSequenceChanged(try ActiveSequenceChanged(from: decoder))
        case "AssetImported": self = .assetImported(try AssetImported(from: decoder))
        case "AssetRelinked": self = .assetRelinked(try AssetRelinked(from: decoder))
        case "AssetRemoved": self = .assetRemoved(try AssetRemoved(from: decoder))
        case "AssetRestored": self = .assetRestored(try AssetRestored(from: decoder))
        case "AssetAnalysisRecorded": self = .assetAnalysisRecorded(try AssetAnalysisRecorded(from: decoder))
        case "TrackAdded": self = .trackAdded(try TrackAdded(from: decoder))
        case "TrackRemoved": self = .trackRemoved(try TrackRemoved(from: decoder))
        case "TrackRestored": self = .trackRestored(try TrackRestored(from: decoder))
        case "TrackReordered": self = .trackReordered(try TrackReordered(from: decoder))
        case "TrackRenamed": self = .trackRenamed(try TrackRenamed(from: decoder))
        case "TrackMuteSet": self = .trackMuteSet(try TrackMuteSet(from: decoder))
        case "TrackLockSet": self = .trackLockSet(try TrackLockSet(from: decoder))
        case "TrackSoloSet": self = .trackSoloSet(try TrackSoloSet(from: decoder))
        case "ClipAdded": self = .clipAdded(try ClipAdded(from: decoder))
        case "ClipRemoved": self = .clipRemoved(try ClipRemoved(from: decoder))
        case "ClipMoved": self = .clipMoved(try ClipMoved(from: decoder))
        case "ClipTrimmed": self = .clipTrimmed(try ClipTrimmed(from: decoder))
        case "ClipSplit": self = .clipSplit(try ClipSplit(from: decoder))
        case "ClipsJoined": self = .clipsJoined(try ClipsJoined(from: decoder))
        case "ClipSpeedSet": self = .clipSpeedSet(try ClipSpeedSet(from: decoder))
        case "ClipTransformSet": self = .clipTransformSet(try ClipTransformSet(from: decoder))
        case "ClipOpacitySet": self = .clipOpacitySet(try ClipOpacitySet(from: decoder))
        case "ClipAudioSet": self = .clipAudioSet(try ClipAudioSet(from: decoder))
        case "ClipEffectAdded": self = .clipEffectAdded(try ClipEffectAdded(from: decoder))
        case "ClipEffectChanged": self = .clipEffectChanged(try ClipEffectChanged(from: decoder))
        case "ClipEffectRemoved": self = .clipEffectRemoved(try ClipEffectRemoved(from: decoder))
        case "ClipsLinked": self = .clipsLinked(try ClipsLinked(from: decoder))
        case "ClipsUnlinked": self = .clipsUnlinked(try ClipsUnlinked(from: decoder))
        case "TransitionAdded": self = .transitionAdded(try TransitionAdded(from: decoder))
        case "TransitionChanged": self = .transitionChanged(try TransitionChanged(from: decoder))
        case "TransitionRemoved": self = .transitionRemoved(try TransitionRemoved(from: decoder))
        case "CaptionTrackAdded": self = .captionTrackAdded(try CaptionTrackAdded(from: decoder))
        case "CaptionsReplaced": self = .captionsReplaced(try CaptionsReplaced(from: decoder))
        case "CaptionEdited": self = .captionEdited(try CaptionEdited(from: decoder))
        case "CaptionStyleSet": self = .captionStyleSet(try CaptionStyleSet(from: decoder))
        case "MarkerAdded": self = .markerAdded(try MarkerAdded(from: decoder))
        case "MarkerMoved": self = .markerMoved(try MarkerMoved(from: decoder))
        case "MarkerRemoved": self = .markerRemoved(try MarkerRemoved(from: decoder))
        case "TransactionUndone": self = .transactionUndone(try TransactionUndone(from: decoder))
        case "TransactionRedone": self = .transactionRedone(try TransactionRedone(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown event type \(type)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: TypeKey.self)
        try c.encode(typeName, forKey: .type)
        try encodeFields(to: encoder)
    }

    /// Encodes the fields only (no `"type"` key), which is what the store's `payload` column holds.
    public func encodeFields(to encoder: any Encoder) throws {
        switch self {
        case .projectCreated(let p): try p.encode(to: encoder)
        case .projectSettingsChanged(let p): try p.encode(to: encoder)
        case .projectRenamed(let p): try p.encode(to: encoder)
        case .sequenceAdded(let p): try p.encode(to: encoder)
        case .sequenceSettingsChanged(let p): try p.encode(to: encoder)
        case .activeSequenceChanged(let p): try p.encode(to: encoder)
        case .assetImported(let p): try p.encode(to: encoder)
        case .assetRelinked(let p): try p.encode(to: encoder)
        case .assetRemoved(let p): try p.encode(to: encoder)
        case .assetRestored(let p): try p.encode(to: encoder)
        case .assetAnalysisRecorded(let p): try p.encode(to: encoder)
        case .trackAdded(let p): try p.encode(to: encoder)
        case .trackRemoved(let p): try p.encode(to: encoder)
        case .trackRestored(let p): try p.encode(to: encoder)
        case .trackReordered(let p): try p.encode(to: encoder)
        case .trackRenamed(let p): try p.encode(to: encoder)
        case .trackMuteSet(let p): try p.encode(to: encoder)
        case .trackLockSet(let p): try p.encode(to: encoder)
        case .trackSoloSet(let p): try p.encode(to: encoder)
        case .clipAdded(let p): try p.encode(to: encoder)
        case .clipRemoved(let p): try p.encode(to: encoder)
        case .clipMoved(let p): try p.encode(to: encoder)
        case .clipTrimmed(let p): try p.encode(to: encoder)
        case .clipSplit(let p): try p.encode(to: encoder)
        case .clipsJoined(let p): try p.encode(to: encoder)
        case .clipSpeedSet(let p): try p.encode(to: encoder)
        case .clipTransformSet(let p): try p.encode(to: encoder)
        case .clipOpacitySet(let p): try p.encode(to: encoder)
        case .clipAudioSet(let p): try p.encode(to: encoder)
        case .clipEffectAdded(let p): try p.encode(to: encoder)
        case .clipEffectChanged(let p): try p.encode(to: encoder)
        case .clipEffectRemoved(let p): try p.encode(to: encoder)
        case .clipsLinked(let p): try p.encode(to: encoder)
        case .clipsUnlinked(let p): try p.encode(to: encoder)
        case .transitionAdded(let p): try p.encode(to: encoder)
        case .transitionChanged(let p): try p.encode(to: encoder)
        case .transitionRemoved(let p): try p.encode(to: encoder)
        case .captionTrackAdded(let p): try p.encode(to: encoder)
        case .captionsReplaced(let p): try p.encode(to: encoder)
        case .captionEdited(let p): try p.encode(to: encoder)
        case .captionStyleSet(let p): try p.encode(to: encoder)
        case .markerAdded(let p): try p.encode(to: encoder)
        case .markerMoved(let p): try p.encode(to: encoder)
        case .markerRemoved(let p): try p.encode(to: encoder)
        case .transactionUndone(let p): try p.encode(to: encoder)
        case .transactionRedone(let p): try p.encode(to: encoder)
        }
    }

    /// The fields as canonical JSON bytes (no `"type"`), for the store's `payload` column.
    public func fieldsJSON() throws -> Data {
        try ProjectCodec.encoder.encode(FieldsBox(payload: self))
    }

    /// Decodes a store row: upcasts `payload` from `schemaVersion` (and any embedded `clipSchema`) first.
    public static func decode(
        type: String, schemaVersion: Int, fieldsJSON: Data, registry: Upcaster.Registry = .standard
    ) throws -> EventPayload {
        let raw = try ProjectCodec.decoder.decode(JSONValue.self, from: fieldsJSON)
        let latest = Upcaster.upcast(type: type, version: schemaVersion, payload: raw, registry: registry)
        return try latest.decodedPayload(type: type)
    }
}

/// Encodes a payload's fields as a bare object.
struct FieldsBox: Encodable {
    var payload: EventPayload
    func encode(to encoder: any Encoder) throws { try payload.encodeFields(to: encoder) }
}

extension JSONValue {
    /// Decodes a payload tree (already at the current schema) of `type`.
    func decodedPayload(type: String) throws -> EventPayload {
        var object = self
        object["type"] = .string(type)
        return try object.decoded(as: EventPayload.self)
    }
}

extension DomainEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case eventId
        case txnId
        case commandId
        case actor
        case occurredAt
        case schemaVersion
        case causationId
        case metadata
        case type
        case payload
    }

    private struct ClipSchemaPeek: Decodable {
        var clipSchema: Int?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.decode(EventID.self, forKey: .eventId)
        txnId = try c.decode(TransactionID.self, forKey: .txnId)
        commandId = try c.decode(CommandID.self, forKey: .commandId)
        actor = try c.decode(Actor.self, forKey: .actor)
        occurredAt = try c.decode(Date.self, forKey: .occurredAt)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        causationId = try c.decodeIfPresent(EventID.self, forKey: .causationId)
        metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        let type = try c.decode(String.self, forKey: .type)
        let clipSchema = try c.decode(ClipSchemaPeek.self, forKey: .payload).clipSchema
        if version < Upcaster.currentSchemaVersion
            || (clipSchema ?? Upcaster.currentClipSchema) < Upcaster.currentClipSchema
        {
            let raw = try c.decode(JSONValue.self, forKey: .payload)
            let latest = Upcaster.upcast(type: type, version: version, payload: raw)
            payload = try latest.decodedPayload(type: type)
        } else {
            payload = try EventPayload(type: type, fields: try c.superDecoder(forKey: .payload))
        }
        schemaVersion = Upcaster.currentSchemaVersion
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eventId, forKey: .eventId)
        try c.encode(txnId, forKey: .txnId)
        try c.encode(commandId, forKey: .commandId)
        try c.encode(actor, forKey: .actor)
        try c.encode(occurredAt, forKey: .occurredAt)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(causationId, forKey: .causationId)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encode(payload.typeName, forKey: .type)
        try payload.encodeFields(to: c.superEncoder(forKey: .payload))
    }
}
