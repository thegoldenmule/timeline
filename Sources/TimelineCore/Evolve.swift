import Foundation

// MARK: - Lookup helpers

extension Sequence {
    /// Index of the track with `id`.
    public func trackIndex(of id: TrackID) -> Int? { tracks.firstIndex { $0.id == id } }

    public func track(_ id: TrackID) -> Track? {
        guard let i = trackIndex(of: id) else { return nil }
        return tracks[i]
    }

    /// Index of the track that holds `clipId`.
    public func trackIndex(containing clipId: ClipID) -> Int? {
        tracks.firstIndex { $0.clips[clipId] != nil }
    }

    public func clip(_ id: ClipID) -> Clip? {
        for t in tracks {
            if let c = t.clips[id] { return c }
        }
        return nil
    }

    /// Timeline duration of `clip` on its track (frame-rounded on video and caption tracks).
    public func duration(of clip: Clip) -> RationalTime {
        let kind = track(clip.trackId)?.kind ?? .video
        return clip.duration(frameDuration: kind.isFrameAligned ? frameDuration : nil)
    }

    /// Exclusive end of `clip` on the timeline.
    public func end(of clip: Clip) -> RationalTime { clip.start + duration(of: clip) }

    /// Every clip in `linkGroupId`, across tracks.
    public func members(of linkGroupId: LinkGroupID) -> [Clip] {
        tracks.flatMap { $0.clips.values.filter { $0.linkGroupId == linkGroupId } }
    }

    /// Mutates the clip with `id` in place (no dictionary copies).
    mutating func withClip(_ id: ClipID, _ body: (inout Clip) -> Void) {
        guard let i = trackIndex(containing: id) else { return }
        body(&tracks[i].clips[id]!)
    }

    mutating func withTrack(_ id: TrackID, _ body: (inout Track) -> Void) {
        guard let i = trackIndex(of: id) else { return }
        body(&tracks[i])
    }

    mutating func insertClip(_ clip: Clip) {
        guard let i = trackIndex(of: clip.trackId) else { return }
        tracks[i].clips[clip.id] = clip
    }

    @discardableResult
    mutating func removeClip(_ id: ClipID) -> Clip? {
        guard let i = trackIndex(containing: id) else { return nil }
        return tracks[i].clips.removeValue(forKey: id)
    }
}

extension Project {
    /// The sequence, track index, and clip for `clipId`, searching every sequence.
    public func locate(clip clipId: ClipID) -> (sequence: Sequence, trackIndex: Int, clip: Clip)? {
        for seq in sequences.values {
            if let i = seq.trackIndex(containing: clipId), let c = seq.tracks[i].clips[clipId] {
                return (seq, i, c)
            }
        }
        return nil
    }

    public func locate(track trackId: TrackID) -> (sequence: Sequence, trackIndex: Int)? {
        for seq in sequences.values {
            if let i = seq.trackIndex(of: trackId) { return (seq, i) }
        }
        return nil
    }

    public func locate(transition id: TransitionID) -> (sequence: Sequence, transition: Transition)? {
        for seq in sequences.values {
            if let t = seq.transitions[id] { return (seq, t) }
        }
        return nil
    }

    public func locate(marker id: MarkerID) -> (sequence: Sequence, marker: Marker)? {
        for seq in sequences.values {
            if let m = seq.markers[id] { return (seq, m) }
        }
        return nil
    }

    mutating func withSequence(_ id: SequenceID, _ body: (inout Sequence) -> Void) {
        guard sequences[id] != nil else { return }
        body(&sequences[id]!)
    }
}

// MARK: - evolve

/// Applies one event. This `inout` form is the workhorse: the store and replay use it so a fold of
/// 10,000 events does not copy the clip dictionaries once per event.
public func evolve(_ state: inout Project, _ event: DomainEvent) {
    apply(event.payload, to: &state)
    state.version += 1
}

/// Value-returning form. Copies the state once per call; prefer the `inout` form in loops.
public func evolve(_ state: Project, _ event: DomainEvent) -> Project {
    var s = state
    evolve(&s, event)
    return s
}

/// Folds many events with the `inout` form.
public func evolve(_ state: inout Project, _ events: [DomainEvent]) {
    for e in events { evolve(&state, e) }
}

/// Folds many events, returning the result.
public func evolve(_ state: Project, _ events: [DomainEvent]) -> Project {
    var s = state
    evolve(&s, events)
    return s
}

func apply(_ payload: EventPayload, to state: inout Project) {
    switch payload {
    case .projectCreated(let p):
        state.id = p.projectId
        state.name = p.name
        state.settings = p.settings
        state.sequences = [p.sequence.id: p.sequence]
        state.activeSequenceId = p.sequence.id
        state.assets = [:]
    case .projectSettingsChanged(let p):
        state.settings = p.after
    case .projectRenamed(let p):
        state.name = p.after
    case .sequenceAdded(let p):
        state.sequences[p.sequenceId] = Sequence(
            id: p.sequenceId, name: p.name, frameDuration: p.frameDuration, width: p.width, height: p.height)
    case .sequenceSettingsChanged(let p):
        state.withSequence(p.sequenceId) { s in
            s.name = p.after.name
            s.frameDuration = p.after.frameDuration
            s.width = p.after.width
            s.height = p.after.height
        }
    case .activeSequenceChanged(let p):
        state.activeSequenceId = p.after
    case .assetImported(let p):
        state.assets[p.assetId] = p.asset
    case .assetRelinked(let p):
        state.assets[p.assetId]?.libraryPath = p.after.libraryPath
        state.assets[p.assetId]?.offline = p.after.offline
    case .assetRemoved(let p):
        state.assets.removeValue(forKey: p.assetId)
    case .assetRestored(let p):
        state.assets[p.assetId] = p.snapshot
    case .assetAnalysisRecorded(let p):
        state.assets[p.assetId]?.analyses[p.kind] = p.after
    case .trackAdded(let p):
        state.withSequence(p.sequenceId) { s in
            let track = Track(id: p.trackId, kind: p.kind, name: p.name)
            s.tracks.insert(track, at: Swift.min(p.position, s.tracks.count))
        }
    case .trackRemoved(let p):
        state.withSequence(p.sequenceId) { s in
            if let i = s.trackIndex(of: p.trackId) { s.tracks.remove(at: i) }
        }
    case .trackRestored(let p):
        state.withSequence(p.sequenceId) { s in
            s.tracks.insert(p.snapshot, at: Swift.min(p.position, s.tracks.count))
        }
    case .trackReordered(let p):
        state.withSequence(p.sequenceId) { s in
            guard let i = s.trackIndex(of: p.trackId) else { return }
            let t = s.tracks.remove(at: i)
            s.tracks.insert(t, at: Swift.min(p.after, s.tracks.count))
        }
    case .trackRenamed(let p):
        state.withSequence(p.sequenceId) { $0.withTrack(p.trackId) { $0.name = p.after } }
    case .trackMuteSet(let p):
        state.withSequence(p.sequenceId) { $0.withTrack(p.trackId) { $0.muted = p.after } }
    case .trackLockSet(let p):
        state.withSequence(p.sequenceId) { $0.withTrack(p.trackId) { $0.locked = p.after } }
    case .clipAdded(let p):
        state.withSequence(p.sequenceId) { $0.insertClip(p.snapshot) }
    case .clipRemoved(let p):
        state.withSequence(p.sequenceId) { $0.removeClip(p.clipId) }
    case .clipMoved(let p):
        state.withSequence(p.sequenceId) { s in
            if p.before.trackId == p.after.trackId {
                s.withClip(p.clipId) { $0.start = p.after.start }
            } else if var clip = s.removeClip(p.clipId) {
                clip.trackId = p.after.trackId
                clip.start = p.after.start
                s.insertClip(clip)
            }
        }
    case .clipTrimmed(let p):
        state.withSequence(p.sequenceId) { s in
            s.withClip(p.clipId) { c in
                c.start = p.after.start
                c.sourceIn = p.after.sourceIn
                c.sourceOut = p.after.sourceOut
            }
        }
    case .clipSplit(let p):
        state.withSequence(p.sequenceId) { s in
            s.withClip(p.clipId) { c in
                c.start = p.after.start
                c.sourceIn = p.after.sourceIn
                c.sourceOut = p.after.sourceOut
                if let words = c.words { c.words = words.filter { $0.t0 < p.after.sourceOut } }
            }
            s.insertClip(p.newClip)
        }
    case .clipsJoined(let p):
        state.withSequence(p.sequenceId) { s in
            let removedWords = s.clip(p.removedClipId)?.words ?? []
            s.removeClip(p.removedClipId)
            s.withClip(p.keptClipId) { c in
                c.start = p.keptAfter.start
                c.sourceIn = p.keptAfter.sourceIn
                c.sourceOut = p.keptAfter.sourceOut
                if c.words != nil { c.words = (c.words ?? []) + removedWords }
            }
        }
    case .clipSpeedSet(let p):
        state.withSequence(p.sequenceId) { $0.withClip(p.clipId) { $0.speed = p.after } }
    case .clipTransformSet(let p):
        state.withSequence(p.sequenceId) { $0.withClip(p.clipId) { $0.transform = p.after } }
    case .clipOpacitySet(let p):
        state.withSequence(p.sequenceId) { $0.withClip(p.clipId) { $0.opacity = p.after } }
    case .clipAudioSet(let p):
        state.withSequence(p.sequenceId) { $0.withClip(p.clipId) { $0.audio = p.after } }
    case .clipEffectAdded(let p):
        state.withSequence(p.sequenceId) {
            $0.withClip(p.clipId) { $0.effects.insert(p.after, at: Swift.min(p.index, $0.effects.count)) }
        }
    case .clipEffectChanged(let p):
        state.withSequence(p.sequenceId) {
            $0.withClip(p.clipId) { c in
                if let i = c.effects.firstIndex(where: { $0.id == p.effectId }) { c.effects[i] = p.after }
            }
        }
    case .clipEffectRemoved(let p):
        state.withSequence(p.sequenceId) {
            $0.withClip(p.clipId) { $0.effects.removeAll { $0.id == p.effectId } }
        }
    case .clipsLinked(let p):
        state.withSequence(p.sequenceId) { s in
            for id in p.clipIds { s.withClip(id) { $0.linkGroupId = p.linkGroupId } }
        }
    case .clipsUnlinked(let p):
        state.withSequence(p.sequenceId) { s in
            for id in p.clipIds { s.withClip(id) { $0.linkGroupId = nil } }
        }
    case .transitionAdded(let p):
        state.withSequence(p.sequenceId) { $0.transitions[p.transitionId] = p.after }
    case .transitionChanged(let p):
        state.withSequence(p.sequenceId) { $0.transitions[p.transitionId] = p.after }
    case .transitionRemoved(let p):
        state.withSequence(p.sequenceId) { $0.transitions.removeValue(forKey: p.transitionId) }
    case .captionTrackAdded(let p):
        state.withSequence(p.sequenceId) { s in
            let track = Track(id: p.trackId, kind: .caption, name: p.name, language: p.language, captionStyle: p.style)
            s.tracks.insert(track, at: Swift.min(p.position, s.tracks.count))
        }
    case .captionsReplaced(let p):
        state.withSequence(p.sequenceId) { s in
            s.withTrack(p.trackId) { t in
                for c in p.before { t.clips.removeValue(forKey: c.id) }
                for c in p.after { t.clips[c.id] = c }
            }
        }
    case .captionEdited(let p):
        state.withSequence(p.sequenceId) { $0.withClip(p.clipId) { $0.caption = p.after } }
    case .captionStyleSet(let p):
        state.withSequence(p.sequenceId) { s in
            if let clipId = p.clipId {
                s.withClip(clipId) { $0.style = p.after }
            } else {
                s.withTrack(p.trackId) { $0.captionStyle = p.after }
            }
        }
    case .markerAdded(let p):
        state.withSequence(p.sequenceId) { $0.markers[p.markerId] = p.after }
    case .markerMoved(let p):
        state.withSequence(p.sequenceId) { $0.markers[p.markerId]?.at = p.after }
    case .markerRemoved(let p):
        state.withSequence(p.sequenceId) { $0.markers.removeValue(forKey: p.markerId) }
    case .transactionUndone, .transactionRedone:
        break
    }
}
