import Foundation

/// Turns a command into events or rejects it. Pure: no I/O, all ids and times injected.
///
/// - Parameters:
///   - state: the current project.
///   - command: the request; a `batch` is processed sequentially with `$ref` resolution.
///   - ids: mints every id (transaction, events, created entities).
///   - clock: stamps `occurredAt`.
///   - history: needed for `undo`/`redo` and, when complete, for a `ChangedSince` on stale versions.
/// - Returns: the events of one transaction (possibly empty for a no-op), already validated:
///   the state after `evolve` passes `Invariants.check`.
public func decide(
    _ state: Project, _ command: Command, ids: any IDGenerator, clock: any Clock, history: History = History()
) throws(EditorError) -> [DomainEvent] {
    if let expected = command.expectedVersion, expected != state.version {
        var changed: ChangedSince?
        if Int64(history.eventCount) == state.version, expected >= 0, expected < state.version {
            changed = ChangedSince.build(from: Array(history.allEvents.dropFirst(Int(expected))), fromVersion: expected)
        }
        throw .staleVersion(current: state.version, changedSince: changed)
    }
    var decider = Decider(state: state, command: command, ids: ids, clock: clock, history: history)
    switch command.operation {
    case .batch(let ops):
        for (i, op) in ops.enumerated() {
            decider.opIndex = i
            switch op {
            case .batch: throw .invalid(reason: "Batches do not nest")
            case .undo, .redo: throw .invalid(reason: "undo and redo cannot be part of a batch")
            default: try decider.run(op)
            }
        }
    case .undo(let op):
        try decider.undo(op)
    case .redo:
        try decider.redo()
    default:
        try decider.run(command.operation)
    }
    if !decider.events.isEmpty {
        try Invariants.check(decider.state)
    }
    return decider.events
}

/// Working state for one `decide` call. Every emitted event is folded into `state` immediately, so
/// later steps of a batch or a multi-step edit see the effect of earlier ones.
struct Decider {
    var state: Project
    let command: Command
    let ids: any IDGenerator
    let clock: any Clock
    let history: History
    let txnId: TransactionID
    var events: [DomainEvent] = []
    /// Primary id created by each batch operation, for `$ref` resolution.
    var createdIds: [Int: String] = [:]
    var opIndex = 0

    init(state: Project, command: Command, ids: any IDGenerator, clock: any Clock, history: History) {
        self.state = state
        self.command = command
        self.ids = ids
        self.clock = clock
        self.history = history
        txnId = TransactionID(minting: ids)
    }

    // MARK: Emitting

    mutating func emit(_ payload: EventPayload, causation: EventID? = nil) {
        let event = DomainEvent(
            eventId: EventID(minting: ids), txnId: txnId, commandId: command.commandId, actor: command.actor,
            occurredAt: clock.now(), causationId: causation, payload: payload)
        events.append(event)
        evolve(&state, event)
    }

    mutating func created(_ id: String) { createdIds[opIndex] = id }

    func mint<Tag: IDTag>(_ type: TypedID<Tag>.Type = TypedID<Tag>.self) -> TypedID<Tag> {
        TypedID<Tag>(minting: ids)
    }

    // MARK: Resolving

    func resolve<ID: TypedIDProtocol>(_ ref: Ref<ID>) throws(EditorError) -> ID {
        switch ref {
        case .id(let id): return id
        case .ref(let n):
            guard let raw = createdIds[n] else {
                throw .invalid(reason: "$ref \(n) does not name an id created by an earlier operation")
            }
            return ID(raw)
        }
    }

    func sequence(_ id: SequenceID) throws(EditorError) -> Sequence {
        guard let s = state.sequences[id] else { throw .notFound(id: id.rawValue) }
        return s
    }

    /// The single sequence of a v1 project, for ops that do not name one.
    func onlySequence() throws(EditorError) -> Sequence {
        if let active = state.activeSequence { return active }
        guard let s = state.sequences.values.first else { throw .invalid(reason: "Project has no sequence") }
        return s
    }

    struct Located {
        var sequence: Sequence
        var track: Track
        var clip: Clip
        var isFrameAligned: Bool { track.kind.isFrameAligned }
        var frameDuration: RationalTime? { isFrameAligned ? sequence.frameDuration : nil }
        var duration: RationalTime { clip.duration(frameDuration: frameDuration) }
        var end: RationalTime { clip.start + duration }
    }

    func locate(_ clipId: ClipID) throws(EditorError) -> Located {
        guard let (seq, i, clip) = state.locate(clip: clipId) else { throw .notFound(id: clipId.rawValue) }
        return Located(sequence: seq, track: seq.tracks[i], clip: clip)
    }

    func locateTrack(_ trackId: TrackID) throws(EditorError) -> (sequence: Sequence, index: Int, track: Track) {
        guard let (seq, i) = state.locate(track: trackId) else { throw .notFound(id: trackId.rawValue) }
        return (seq, i, seq.tracks[i])
    }

    func asset(_ id: AssetID) throws(EditorError) -> Asset {
        guard let a = state.assets[id] else { throw .notFound(id: id.rawValue) }
        return a
    }

    func requireUnlocked(_ track: Track) throws(EditorError) {
        if track.locked { throw .trackLocked(track.id) }
    }

    func requireCreated() throws(EditorError) {
        guard state.isCreated else { throw .invalid(reason: "Project has not been created yet") }
    }

    /// Snaps `t` to the sequence frame when `track` is frame aligned.
    func snap(_ t: RationalTime, _ track: Track, in seq: Sequence) -> RationalTime {
        track.kind.isFrameAligned ? t.snapped(to: seq.frameDuration) : t
    }

    // MARK: Dispatch

    mutating func run(_ op: Command.Operation) throws(EditorError) {
        switch op {
        case .createProject(let o): try createProject(o)
        case .setProjectSettings(let o):
            try requireCreated()
            if state.settings != o.after {
                emit(.projectSettingsChanged(.init(before: state.settings, after: o.after)))
            }
        case .renameProject(let o):
            try requireCreated()
            if state.name != o.name { emit(.projectRenamed(.init(before: state.name, after: o.name))) }
        case .addSequence:
            throw .invalid(reason: "Projects hold one sequence in this version")
        case .setSequenceSettings(let o): try setSequenceSettings(o)
        case .setActiveSequence(let o):
            let id = try resolve(o.sequenceId)
            _ = try sequence(id)
            if state.activeSequenceId != id {
                emit(.activeSequenceChanged(.init(before: state.activeSequenceId, after: id)))
            }
        case .importAsset(let o): try importAsset(o)
        case .relinkAsset(let o):
            let a = try asset(try resolve(o.assetId))
            let after = AssetLocation(libraryPath: o.libraryPath, offline: o.offline)
            let before = AssetLocation(libraryPath: a.libraryPath, offline: a.offline)
            if before != after { emit(.assetRelinked(.init(assetId: a.id, before: before, after: after))) }
        case .removeAsset(let o): try removeAsset(o)
        case .restoreAsset(let o): try restoreAsset(o)
        case .recordAssetAnalysis(let o):
            let a = try asset(try resolve(o.assetId))
            emit(
                .assetAnalysisRecorded(
                    .init(
                        assetId: a.id, kind: o.kind, cacheKey: o.cacheKey, summary: o.summary,
                        before: a.analyses[o.kind])))
        case .addTrack(let o): try addTrack(o)
        case .removeTrack(let o): try removeTrack(o)
        case .reorderTrack(let o): try reorderTrack(o)
        case .renameTrack(let o):
            let (seq, _, t) = try locateTrack(try resolve(o.trackId))
            if t.name != o.name {
                emit(.trackRenamed(.init(sequenceId: seq.id, trackId: t.id, before: t.name, after: o.name)))
            }
        case .setTrackMuted(let o):
            let (seq, _, t) = try locateTrack(try resolve(o.trackId))
            if t.muted != o.muted {
                emit(.trackMuteSet(.init(sequenceId: seq.id, trackId: t.id, before: t.muted, after: o.muted)))
            }
        case .setTrackLocked(let o):
            let (seq, _, t) = try locateTrack(try resolve(o.trackId))
            if t.locked != o.locked {
                emit(.trackLockSet(.init(sequenceId: seq.id, trackId: t.id, before: t.locked, after: o.locked)))
            }
        case .addClip(let o): try addClip(o)
        case .moveClip(let o): try moveClip(o)
        case .trimClip(let o): try trimClip(o)
        case .splitClip(let o): try splitClip(o)
        case .joinClips(let o): try joinClips(o)
        case .removeClip(let o): try removeClip(o)
        case .setClipSpeed(let o): try setClipSpeed(o)
        case .setClipTransform(let o):
            let l = try locate(try resolve(o.clipId))
            try requireUnlocked(l.track)
            if l.clip.transform != o.after {
                emit(
                    .clipTransformSet(
                        .init(sequenceId: l.sequence.id, clipId: l.clip.id, before: l.clip.transform, after: o.after)))
            }
        case .setClipOpacity(let o):
            let l = try locate(try resolve(o.clipId))
            try requireUnlocked(l.track)
            if l.clip.opacity != o.after {
                emit(
                    .clipOpacitySet(
                        .init(sequenceId: l.sequence.id, clipId: l.clip.id, before: l.clip.opacity, after: o.after)))
            }
        case .setClipAudio(let o):
            let l = try locate(try resolve(o.clipId))
            try requireUnlocked(l.track)
            if l.clip.audio != o.after {
                emit(
                    .clipAudioSet(
                        .init(sequenceId: l.sequence.id, clipId: l.clip.id, before: l.clip.audio, after: o.after)))
            }
        case .addEffect(let o): try addEffect(o)
        case .updateEffect(let o): try updateEffect(o)
        case .removeEffect(let o): try removeEffect(o)
        case .addTransition(let o): try addTransition(o)
        case .updateTransition(let o): try updateTransition(o)
        case .removeTransition(let o):
            let id = try resolve(o.transitionId)
            guard let (seq, t) = state.locate(transition: id) else { throw .notFound(id: id.rawValue) }
            try requireUnlocked(try locateTrack(t.trackId).track)
            emit(.transitionRemoved(.init(sequenceId: seq.id, transitionId: t.id, before: t)))
        case .linkClips(let o): try linkClips(o)
        case .unlinkClips(let o): try unlinkClips(o)
        case .addCaptionTrack(let o): try addCaptionTrack(o)
        case .replaceCaptions(let o): try replaceCaptions(o)
        case .editCaption(let o): try editCaption(o)
        case .setCaptionStyle(let o): try setCaptionStyle(o)
        case .addMarker(let o): try addMarker(o)
        case .moveMarker(let o):
            let id = try resolve(o.markerId)
            guard let (seq, m) = state.locate(marker: id) else { throw .notFound(id: id.rawValue) }
            let to = o.to.snapped(to: seq.frameDuration)
            guard !to.isNegative else { throw .invalid(reason: "Marker time must not be negative") }
            if m.at != to { emit(.markerMoved(.init(sequenceId: seq.id, markerId: m.id, before: m.at, after: to))) }
        case .removeMarker(let o):
            let id = try resolve(o.markerId)
            guard let (seq, m) = state.locate(marker: id) else { throw .notFound(id: id.rawValue) }
            emit(.markerRemoved(.init(sequenceId: seq.id, markerId: m.id, before: m)))
        case .undo, .redo, .batch:
            throw .invalid(reason: "\(op.typeName) is handled at the top level")
        }
    }

    // MARK: Project and assets

    mutating func createProject(_ o: Command.Operation.CreateProject) throws(EditorError) {
        guard !state.isCreated else { throw .invalid(reason: "Project already created") }
        guard o.sequence.frameDuration.isPositive else { throw .invalid(reason: "frameDuration must be positive") }
        guard o.sequence.width > 0, o.sequence.height > 0 else {
            throw .invalid(reason: "Sequence size must be positive")
        }
        let projectId = o.id ?? mint()
        let seq = Sequence(
            id: o.sequence.id ?? mint(), name: o.sequence.name, frameDuration: o.sequence.frameDuration,
            width: o.sequence.width, height: o.sequence.height)
        emit(
            .projectCreated(
                .init(projectId: projectId, name: o.name, settings: o.settings ?? ProjectSettings(), sequence: seq)))
        created(projectId.rawValue)
    }

    mutating func setSequenceSettings(_ o: Command.Operation.SetSequenceSettings) throws(EditorError) {
        let seq = try sequence(try resolve(o.sequenceId))
        let before = SequenceSettings(seq)
        guard before != o.after else { return }
        guard o.after.frameDuration.isPositive else { throw .invalid(reason: "frameDuration must be positive") }
        guard o.after.width > 0, o.after.height > 0 else { throw .invalid(reason: "Sequence size must be positive") }
        if before.frameDuration != o.after.frameDuration {
            let hasFrameClips = seq.tracks.contains { $0.kind.isFrameAligned && !$0.clips.isEmpty }
            guard !hasFrameClips else {
                throw .invalid(
                    reason: "Cannot change the frame rate of a sequence with video or caption clips",
                    suggestion: "Remove the clips first")
            }
        }
        emit(.sequenceSettingsChanged(.init(sequenceId: seq.id, before: before, after: o.after)))
    }

    mutating func importAsset(_ o: Command.Operation.ImportAsset) throws(EditorError) {
        try requireCreated()
        guard o.duration.isPositive else { throw .invalid(reason: "Asset duration must be positive") }
        if let existing = state.assets.values.first(where: { $0.contentHash == o.contentHash }) {
            throw .invalid(
                reason: "An asset with content hash \(o.contentHash) is already imported as \(existing.id)",
                suggestion: "Use asset \(existing.id)")
        }
        let id = o.id ?? mint()
        guard state.assets[id] == nil else { throw .invalid(reason: "Asset \(id) already exists") }
        let asset = Asset(
            id: id, contentHash: o.contentHash, libraryPath: o.libraryPath, displayName: o.displayName, kind: o.kind,
            duration: o.duration, hasVideo: o.hasVideo, hasAudio: o.hasAudio, sampleRate: o.sampleRate,
            frameDuration: o.frameDuration, probe: o.probe)
        emit(.assetImported(.init(asset)))
        created(id.rawValue)
    }

    mutating func removeAsset(_ o: Command.Operation.RemoveAsset) throws(EditorError) {
        let a = try asset(try resolve(o.assetId))
        let users = state.sequences.values.flatMap {
            $0.tracks.flatMap { $0.clips.values.filter { $0.assetId == a.id } }
        }
        guard users.isEmpty else {
            throw .invalid(
                reason: "Asset \(a.id) is used by \(users.count) clip(s)",
                suggestion: "Remove clips \(users.map(\.id.rawValue).sorted().joined(separator: ", ")) first")
        }
        emit(.assetRemoved(.init(assetId: a.id, snapshot: a)))
    }

    mutating func restoreAsset(_ o: Command.Operation.RestoreAsset) throws(EditorError) {
        try requireCreated()
        guard state.assets[o.asset.id] == nil else { throw .invalid(reason: "Asset \(o.asset.id) already exists") }
        if let existing = state.assets.values.first(where: { $0.contentHash == o.asset.contentHash }) {
            throw .invalid(reason: "Content hash already imported as \(existing.id)")
        }
        guard o.asset.duration.isPositive else { throw .invalid(reason: "Asset duration must be positive") }
        emit(.assetRestored(.init(assetId: o.asset.id, snapshot: o.asset)))
        created(o.asset.id.rawValue)
    }

    // MARK: Tracks

    func defaultTrackName(_ kind: TrackKind, in seq: Sequence) -> String {
        let n = seq.tracks.filter { $0.kind == kind }.count + 1
        switch kind {
        case .video: return "V\(n)"
        case .audio: return "A\(n)"
        case .caption: return "C\(n)"
        }
    }

    mutating func addTrack(_ o: Command.Operation.AddTrack) throws(EditorError) {
        let seq = try sequence(try resolve(o.sequenceId))
        let id = o.id ?? mint()
        guard state.locate(track: id) == nil else { throw .invalid(reason: "Track \(id) already exists") }
        let position = o.position ?? seq.tracks.count
        guard position >= 0, position <= seq.tracks.count else { throw .invalid(reason: "Track position out of range") }
        emit(
            .trackAdded(
                .init(
                    sequenceId: seq.id, trackId: id, kind: o.kind, position: position,
                    name: o.name ?? defaultTrackName(o.kind, in: seq))))
        created(id.rawValue)
    }

    mutating func removeTrack(_ o: Command.Operation.RemoveTrack) throws(EditorError) {
        let (seq, index, track) = try locateTrack(try resolve(o.trackId))
        try requireUnlocked(track)
        for t in seq.transitions.values.filter({ $0.trackId == track.id }).sorted(by: { $0.id < $1.id }) {
            emit(.transitionRemoved(.init(sequenceId: seq.id, transitionId: t.id, before: t)))
        }
        emit(.trackRemoved(.init(sequenceId: seq.id, trackId: track.id, position: index, snapshot: track)))
    }

    mutating func reorderTrack(_ o: Command.Operation.ReorderTrack) throws(EditorError) {
        let (seq, index, track) = try locateTrack(try resolve(o.trackId))
        guard o.position >= 0, o.position < seq.tracks.count else {
            throw .invalid(reason: "Track position out of range")
        }
        if index != o.position {
            emit(.trackReordered(.init(sequenceId: seq.id, trackId: track.id, before: index, after: o.position)))
        }
    }

    // MARK: Undo and redo

    mutating func undo(_ o: Command.Operation.Undo) throws(EditorError) {
        let target: Transaction
        if let id = o.txnId {
            guard let t = history[id] else { throw .notFound(id: id.rawValue) }
            guard t.kind == .edit else { throw .invalid(reason: "Only edit transactions can be undone") }
            guard history.isLive(t.id) else { throw .alreadyUndone }
            guard history.latestLive?.id == t.id else {
                throw .invalid(
                    reason: "Only the latest live transaction can be undone",
                    suggestion: "Undo \(history.latestLive?.id.rawValue ?? "") first")
            }
            target = t
        } else {
            guard let t = history.latestLive else { throw .invalid(reason: "Nothing to undo") }
            target = t
        }
        guard !target.events.contains(where: { if case .projectCreated = $0.payload { true } else { false } }) else {
            throw .invalid(reason: "The project creation cannot be undone")
        }
        emit(.transactionUndone(.init(targetTxnId: target.id)))
        for event in target.events.reversed() {
            for payload in invert(event.payload) {
                try checkPrecondition(payload)
                emit(payload, causation: event.eventId)
            }
        }
    }

    mutating func redo() throws(EditorError) {
        guard let target = history.redoTarget else { throw .nothingToRedo }
        emit(.transactionRedone(.init(targetTxnId: target.id)))
        for event in target.events {
            try checkPrecondition(event.payload)
            emit(event.payload, causation: event.eventId)
        }
    }

    /// Verifies that a compensating (or re-applied) payload's `before` still matches the state.
    func checkPrecondition(_ payload: EventPayload) throws(EditorError) {
        func drift(_ what: String) -> EditorError {
            .invalid(reason: "Cannot apply \(payload.typeName): \(what) changed since", suggestion: "Refresh and retry")
        }
        func clip(_ id: ClipID) throws(EditorError) -> Clip {
            guard let c = state.locate(clip: id)?.clip else { throw drift("clip \(id)") }
            return c
        }
        switch payload {
        case .projectSettingsChanged(let p):
            guard state.settings == p.before else { throw drift("project settings") }
        case .projectRenamed(let p):
            guard state.name == p.before else { throw drift("project name") }
        case .sequenceSettingsChanged(let p):
            guard let s = state.sequences[p.sequenceId], SequenceSettings(s) == p.before else {
                throw drift("sequence")
            }
        case .activeSequenceChanged(let p):
            guard state.activeSequenceId == p.before else { throw drift("active sequence") }
        case .assetImported(let p):
            guard state.assets[p.assetId] == nil else { throw drift("asset \(p.assetId)") }
        case .assetRelinked(let p):
            guard let a = state.assets[p.assetId], a.libraryPath == p.before.libraryPath, a.offline == p.before.offline
            else { throw drift("asset \(p.assetId)") }
        case .assetRemoved(let p):
            guard state.assets[p.assetId] != nil else { throw drift("asset \(p.assetId)") }
        case .assetRestored(let p):
            guard state.assets[p.assetId] == nil else { throw drift("asset \(p.assetId)") }
        case .assetAnalysisRecorded(let p):
            guard let a = state.assets[p.assetId], a.analyses[p.kind] == p.before else { throw drift("asset analysis") }
        case .trackAdded(let p):
            guard state.locate(track: p.trackId) == nil else { throw drift("track \(p.trackId)") }
        case .trackRemoved(let p):
            guard state.locate(track: p.trackId) != nil else { throw drift("track \(p.trackId)") }
        case .trackRestored(let p):
            guard state.locate(track: p.trackId) == nil else { throw drift("track \(p.trackId)") }
        case .trackReordered(let p):
            guard state.locate(track: p.trackId)?.trackIndex == p.before else { throw drift("track order") }
        case .trackRenamed(let p):
            guard let l = state.locate(track: p.trackId), l.sequence.tracks[l.trackIndex].name == p.before
            else { throw drift("track name") }
        case .trackMuteSet(let p):
            guard let l = state.locate(track: p.trackId), l.sequence.tracks[l.trackIndex].muted == p.before
            else { throw drift("track mute") }
        case .trackLockSet(let p):
            guard let l = state.locate(track: p.trackId), l.sequence.tracks[l.trackIndex].locked == p.before
            else { throw drift("track lock") }
        case .clipAdded(let p):
            guard state.locate(clip: p.clipId) == nil else { throw drift("clip \(p.clipId) exists") }
            guard state.locate(track: p.snapshot.trackId) != nil else { throw drift("track \(p.snapshot.trackId)") }
        case .clipRemoved(let p):
            _ = try clip(p.clipId)
        case .clipMoved(let p):
            let c = try clip(p.clipId)
            guard ClipPlacement(trackId: c.trackId, start: c.start) == p.before else { throw drift("clip placement") }
        case .clipTrimmed(let p):
            guard ClipRange(try clip(p.clipId)) == p.before else { throw drift("clip range") }
        case .clipSplit(let p):
            guard ClipRange(try clip(p.clipId)) == p.before else { throw drift("clip range") }
            guard state.locate(clip: p.newClipId) == nil else { throw drift("clip \(p.newClipId) exists") }
        case .clipsJoined(let p):
            guard ClipRange(try clip(p.keptClipId)) == p.keptBefore else { throw drift("clip range") }
            _ = try clip(p.removedClipId)
        case .clipSpeedSet(let p):
            guard try clip(p.clipId).speed == p.before else { throw drift("clip speed") }
        case .clipTransformSet(let p):
            guard try clip(p.clipId).transform == p.before else { throw drift("clip transform") }
        case .clipOpacitySet(let p):
            guard try clip(p.clipId).opacity == p.before else { throw drift("clip opacity") }
        case .clipAudioSet(let p):
            guard try clip(p.clipId).audio == p.before else { throw drift("clip audio") }
        case .clipEffectAdded(let p):
            guard !(try clip(p.clipId)).effects.contains(where: { $0.id == p.effectId }) else { throw drift("effect") }
        case .clipEffectChanged(let p):
            guard try clip(p.clipId).effects.contains(p.before) else { throw drift("effect") }
        case .clipEffectRemoved(let p):
            guard try clip(p.clipId).effects.contains(p.before) else { throw drift("effect") }
        case .clipsLinked(let p):
            for id in p.clipIds {
                let g = try clip(id).linkGroupId
                guard g == nil || g == p.linkGroupId else { throw drift("link group of \(id)") }
            }
        case .clipsUnlinked(let p):
            for id in p.clipIds where try clip(id).linkGroupId != p.linkGroupId { throw drift("link group of \(id)") }
        case .transitionAdded(let p):
            guard state.locate(transition: p.transitionId) == nil else { throw drift("transition exists") }
        case .transitionChanged(let p):
            guard state.locate(transition: p.transitionId)?.transition == p.before else { throw drift("transition") }
        case .transitionRemoved(let p):
            guard state.locate(transition: p.transitionId) != nil else { throw drift("transition") }
        case .captionTrackAdded(let p):
            guard state.locate(track: p.trackId) == nil else { throw drift("track \(p.trackId)") }
        case .captionsReplaced(let p):
            guard let l = state.locate(track: p.trackId) else { throw drift("track \(p.trackId)") }
            let current = Set(l.sequence.tracks[l.trackIndex].clips.values)
            guard current == Set(p.before) else { throw drift("captions") }
        case .captionEdited(let p):
            guard try clip(p.clipId).caption == p.before else { throw drift("caption") }
        case .captionStyleSet(let p):
            if let clipId = p.clipId {
                guard try clip(clipId).style == p.before else { throw drift("caption style") }
            } else {
                guard let l = state.locate(track: p.trackId), l.sequence.tracks[l.trackIndex].captionStyle == p.before
                else { throw drift("caption style") }
            }
        case .markerAdded(let p):
            guard state.locate(marker: p.markerId) == nil else { throw drift("marker exists") }
        case .markerMoved(let p):
            guard state.locate(marker: p.markerId)?.marker.at == p.before else { throw drift("marker") }
        case .markerRemoved(let p):
            guard state.locate(marker: p.markerId) != nil else { throw drift("marker") }
        case .projectCreated, .sequenceAdded, .transactionUndone, .transactionRedone:
            break
        }
    }
}

/// Lets `Decider.resolve` construct any typed id from a raw string.
public protocol TypedIDProtocol: Hashable, Sendable, Codable {
    init(_ rawValue: String)
    var rawValue: String { get }
}

extension TypedID: TypedIDProtocol {}
