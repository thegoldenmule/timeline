import Foundation

/// The compensating payloads for one event, defined per type from its before/after values.
/// History markers invert to nothing. Applying `invert` of a transaction's events in reverse order
/// restores the state before the transaction exactly.
public func invert(_ payload: EventPayload) -> [EventPayload] {
    switch payload {
    case .projectCreated:
        // The first event of a project is not undoable.
        return []
    case .projectSettingsChanged(let p):
        return [.projectSettingsChanged(.init(before: p.after, after: p.before))]
    case .projectRenamed(let p):
        return [.projectRenamed(.init(before: p.after, after: p.before))]
    case .sequenceAdded:
        // Sequences cannot be removed in v1; a sequence add is not undoable.
        return []
    case .sequenceSettingsChanged(let p):
        return [.sequenceSettingsChanged(.init(sequenceId: p.sequenceId, before: p.after, after: p.before))]
    case .activeSequenceChanged(let p):
        return [.activeSequenceChanged(.init(before: p.after, after: p.before))]
    case .assetImported(let p):
        return [.assetRemoved(.init(assetId: p.assetId, snapshot: p.asset))]
    case .assetRelinked(let p):
        return [.assetRelinked(.init(assetId: p.assetId, before: p.after, after: p.before))]
    case .assetRemoved(let p):
        return [.assetRestored(.init(assetId: p.assetId, snapshot: p.snapshot))]
    case .assetRestored(let p):
        return [.assetRemoved(.init(assetId: p.assetId, snapshot: p.snapshot))]
    case .assetAnalysisRecorded(let p):
        guard let before = p.before else { return [] }
        return [
            .assetAnalysisRecorded(
                .init(
                    assetId: p.assetId, kind: p.kind, cacheKey: before.cacheKey, summary: before.summary,
                    before: p.after))
        ]
    case .trackAdded(let p):
        let track = Track(id: p.trackId, kind: p.kind, name: p.name)
        return [
            .trackRemoved(.init(sequenceId: p.sequenceId, trackId: p.trackId, position: p.position, snapshot: track))
        ]
    case .trackRemoved(let p):
        return [
            .trackRestored(
                .init(sequenceId: p.sequenceId, trackId: p.trackId, position: p.position, snapshot: p.snapshot))
        ]
    case .trackRestored(let p):
        return [
            .trackRemoved(
                .init(sequenceId: p.sequenceId, trackId: p.trackId, position: p.position, snapshot: p.snapshot))
        ]
    case .trackReordered(let p):
        return [.trackReordered(.init(sequenceId: p.sequenceId, trackId: p.trackId, before: p.after, after: p.before))]
    case .trackRenamed(let p):
        return [.trackRenamed(.init(sequenceId: p.sequenceId, trackId: p.trackId, before: p.after, after: p.before))]
    case .trackMuteSet(let p):
        return [.trackMuteSet(.init(sequenceId: p.sequenceId, trackId: p.trackId, before: p.after, after: p.before))]
    case .trackLockSet(let p):
        return [.trackLockSet(.init(sequenceId: p.sequenceId, trackId: p.trackId, before: p.after, after: p.before))]
    case .clipAdded(let p):
        return [.clipRemoved(.init(sequenceId: p.sequenceId, clipId: p.clipId, snapshot: p.snapshot))]
    case .clipRemoved(let p):
        return [.clipAdded(.init(sequenceId: p.sequenceId, clipId: p.clipId, snapshot: p.snapshot))]
    case .clipMoved(let p):
        return [.clipMoved(.init(sequenceId: p.sequenceId, clipId: p.clipId, before: p.after, after: p.before))]
    case .clipTrimmed(let p):
        return [
            .clipTrimmed(
                .init(sequenceId: p.sequenceId, clipId: p.clipId, edge: p.edge, before: p.after, after: p.before))
        ]
    case .clipSplit(let p):
        return [
            .clipsJoined(
                .init(
                    sequenceId: p.sequenceId, keptClipId: p.clipId, removedClipId: p.newClipId, keptBefore: p.after,
                    keptAfter: p.before, removedSnapshot: p.newClip))
        ]
    case .clipsJoined(let p):
        return [
            .clipSplit(
                .init(
                    sequenceId: p.sequenceId, clipId: p.keptClipId, at: p.removedSnapshot.start,
                    newClipId: p.removedClipId, before: p.keptAfter, after: p.keptBefore, newClip: p.removedSnapshot))
        ]
    case .clipSpeedSet(let p):
        return [.clipSpeedSet(.init(sequenceId: p.sequenceId, clipId: p.clipId, before: p.after, after: p.before))]
    case .clipTransformSet(let p):
        return [.clipTransformSet(.init(sequenceId: p.sequenceId, clipId: p.clipId, before: p.after, after: p.before))]
    case .clipOpacitySet(let p):
        return [.clipOpacitySet(.init(sequenceId: p.sequenceId, clipId: p.clipId, before: p.after, after: p.before))]
    case .clipAudioSet(let p):
        return [.clipAudioSet(.init(sequenceId: p.sequenceId, clipId: p.clipId, before: p.after, after: p.before))]
    case .clipEffectAdded(let p):
        return [
            .clipEffectRemoved(
                .init(sequenceId: p.sequenceId, clipId: p.clipId, effectId: p.effectId, index: p.index, before: p.after)
            )
        ]
    case .clipEffectChanged(let p):
        return [
            .clipEffectChanged(
                .init(
                    sequenceId: p.sequenceId, clipId: p.clipId, effectId: p.effectId, before: p.after, after: p.before))
        ]
    case .clipEffectRemoved(let p):
        return [
            .clipEffectAdded(
                .init(sequenceId: p.sequenceId, clipId: p.clipId, effectId: p.effectId, index: p.index, after: p.before)
            )
        ]
    case .clipsLinked(let p):
        return [.clipsUnlinked(.init(sequenceId: p.sequenceId, linkGroupId: p.linkGroupId, clipIds: p.clipIds))]
    case .clipsUnlinked(let p):
        return [.clipsLinked(.init(sequenceId: p.sequenceId, linkGroupId: p.linkGroupId, clipIds: p.clipIds))]
    case .transitionAdded(let p):
        return [.transitionRemoved(.init(sequenceId: p.sequenceId, transitionId: p.transitionId, before: p.after))]
    case .transitionChanged(let p):
        return [
            .transitionChanged(
                .init(sequenceId: p.sequenceId, transitionId: p.transitionId, before: p.after, after: p.before))
        ]
    case .transitionRemoved(let p):
        return [.transitionAdded(.init(sequenceId: p.sequenceId, transitionId: p.transitionId, after: p.before))]
    case .captionTrackAdded(let p):
        let track = Track(id: p.trackId, kind: .caption, name: p.name, language: p.language, captionStyle: p.style)
        return [
            .trackRemoved(.init(sequenceId: p.sequenceId, trackId: p.trackId, position: p.position, snapshot: track))
        ]
    case .captionsReplaced(let p):
        return [
            .captionsReplaced(.init(sequenceId: p.sequenceId, trackId: p.trackId, before: p.after, after: p.before))
        ]
    case .captionEdited(let p):
        return [.captionEdited(.init(sequenceId: p.sequenceId, clipId: p.clipId, before: p.after, after: p.before))]
    case .captionStyleSet(let p):
        return [
            .captionStyleSet(
                .init(sequenceId: p.sequenceId, trackId: p.trackId, clipId: p.clipId, before: p.after, after: p.before))
        ]
    case .markerAdded(let p):
        return [.markerRemoved(.init(sequenceId: p.sequenceId, markerId: p.markerId, before: p.after))]
    case .markerMoved(let p):
        return [.markerMoved(.init(sequenceId: p.sequenceId, markerId: p.markerId, before: p.after, after: p.before))]
    case .markerRemoved(let p):
        return [.markerAdded(.init(sequenceId: p.sequenceId, markerId: p.markerId, after: p.before))]
    case .transactionUndone, .transactionRedone:
        return []
    }
}

/// Compensating payloads for a whole event, in order.
public func invert(_ event: DomainEvent) -> [EventPayload] { invert(event.payload) }

/// Compensating payloads for a transaction: every event inverted, in reverse order.
public func invert(transaction events: [DomainEvent]) -> [EventPayload] {
    events.reversed().flatMap { invert($0.payload) }
}
