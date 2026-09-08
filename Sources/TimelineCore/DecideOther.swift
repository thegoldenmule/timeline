import Foundation

extension Decider {
    // MARK: Effects

    mutating func addEffect(_ o: Command.Operation.AddEffect) throws(EditorError) {
        let l = try locate(try resolve(o.clipId))
        try requireUnlocked(l.track)
        let id = o.effectId ?? mint()
        guard !l.clip.effects.contains(where: { $0.id == id }) else {
            throw .invalid(reason: "Effect \(id) already exists")
        }
        let index = o.index ?? l.clip.effects.count
        guard index >= 0, index <= l.clip.effects.count else { throw .invalid(reason: "Effect index out of range") }
        let effect = Effect(id: id, kind: o.kind, params: o.params)
        emit(
            .clipEffectAdded(
                .init(sequenceId: l.sequence.id, clipId: l.clip.id, effectId: id, index: index, after: effect)))
        created(id.rawValue)
    }

    mutating func updateEffect(_ o: Command.Operation.UpdateEffect) throws(EditorError) {
        let l = try locate(try resolve(o.clipId))
        try requireUnlocked(l.track)
        let id = try resolve(o.effectId)
        guard let before = l.clip.effects.first(where: { $0.id == id }) else { throw .notFound(id: id.rawValue) }
        var after = before
        if let kind = o.kind { after.kind = kind }
        if let enabled = o.enabled { after.enabled = enabled }
        if let params = o.params { after.params = params }
        if before != after {
            emit(
                .clipEffectChanged(
                    .init(sequenceId: l.sequence.id, clipId: l.clip.id, effectId: id, before: before, after: after)))
        }
    }

    mutating func removeEffect(_ o: Command.Operation.RemoveEffect) throws(EditorError) {
        let l = try locate(try resolve(o.clipId))
        try requireUnlocked(l.track)
        let id = try resolve(o.effectId)
        guard let index = l.clip.effects.firstIndex(where: { $0.id == id }) else { throw .notFound(id: id.rawValue) }
        emit(
            .clipEffectRemoved(
                .init(
                    sequenceId: l.sequence.id, clipId: l.clip.id, effectId: id, index: index,
                    before: l.clip.effects[index])))
    }

    // MARK: Links

    mutating func linkClips(_ o: Command.Operation.LinkClips) throws(EditorError) {
        var located: [Located] = []
        for ref in o.clipIds { located.append(try locate(try resolve(ref))) }
        guard located.count >= 2 else { throw .invalid(reason: "Linking needs at least two clips") }
        let seqIds = Set(located.map(\.sequence.id))
        guard seqIds.count == 1, let seqId = seqIds.first else {
            throw .invalid(reason: "Clips must be in one sequence")
        }
        for l in located { try requireUnlocked(l.track) }
        let existing = Set(located.compactMap(\.clip.linkGroupId))
        guard existing.count <= 1 else {
            throw .invalid(reason: "Clips belong to different link groups", suggestion: "Unlink them first")
        }
        let group = o.linkGroupId ?? existing.first ?? mint()
        let joining = located.filter { $0.clip.linkGroupId != group }.map(\.clip.id)
        if !joining.isEmpty { emit(.clipsLinked(.init(sequenceId: seqId, linkGroupId: group, clipIds: joining))) }
        created(group.rawValue)
    }

    mutating func unlinkClips(_ o: Command.Operation.UnlinkClips) throws(EditorError) {
        var byGroup: [LinkGroupID: [ClipID]] = [:]
        var seqId: SequenceID?
        for ref in o.clipIds {
            let l = try locate(try resolve(ref))
            try requireUnlocked(l.track)
            seqId = l.sequence.id
            if let g = l.clip.linkGroupId { byGroup[g, default: []].append(l.clip.id) }
        }
        guard let seqId else { return }
        for (group, clips) in byGroup.sorted(by: { $0.key < $1.key }) {
            emit(.clipsUnlinked(.init(sequenceId: seqId, linkGroupId: group, clipIds: clips)))
        }
    }

    // MARK: Transitions

    func validatedTransition(_ t: Transition, in seq: Sequence) throws(EditorError) -> Transition {
        let left = try locate(t.leftClipId)
        let right = try locate(t.rightClipId)
        guard left.sequence.id == seq.id, right.sequence.id == seq.id, left.track.id == right.track.id else {
            throw .invalid(reason: "A transition joins two clips on one track")
        }
        try requireUnlocked(left.track)
        guard left.end == right.clip.start else {
            throw .invalid(reason: "Clips \(left.clip.id) and \(right.clip.id) are not adjacent")
        }
        var result = t
        result.trackId = left.track.id
        result.duration = snap(t.duration, left.track, in: seq)
        guard result.duration.isPositive else { throw .invalid(reason: "Transition duration must be at least a frame") }
        let max = Invariants.maxTransitionDuration(
            left: left.clip, right: right.clip, alignment: result.alignment, in: seq, assets: state.assets)
        guard result.duration <= max else { throw .transitionHandles(maxDuration: max) }
        return result
    }

    mutating func addTransition(_ o: Command.Operation.AddTransition) throws(EditorError) {
        let leftId = try resolve(o.leftClipId)
        let rightId = try resolve(o.rightClipId)
        let seq = try locate(leftId).sequence
        let id = o.id ?? mint()
        guard state.locate(transition: id) == nil else { throw .invalid(reason: "Transition \(id) already exists") }
        if let existing = seq.transitions.values.first(where: { $0.leftClipId == leftId && $0.rightClipId == rightId })
        {
            throw .invalid(
                reason: "Transition \(existing.id) already sits on that cut", suggestion: "Update it instead")
        }
        let draft = Transition(
            id: id, trackId: "", leftClipId: leftId, rightClipId: rightId, kind: o.kind, duration: o.duration,
            alignment: o.alignment, params: o.params)
        let t = try validatedTransition(draft, in: seq)
        emit(.transitionAdded(.init(sequenceId: seq.id, transitionId: id, after: t)))
        created(id.rawValue)
    }

    mutating func updateTransition(_ o: Command.Operation.UpdateTransition) throws(EditorError) {
        let id = try resolve(o.transitionId)
        guard let (seq, before) = state.locate(transition: id) else { throw .notFound(id: id.rawValue) }
        var draft = before
        if let kind = o.kind { draft.kind = kind }
        if let duration = o.duration { draft.duration = duration }
        if let alignment = o.alignment { draft.alignment = alignment }
        if let params = o.params { draft.params = params }
        let after = try validatedTransition(draft, in: seq)
        if after != before {
            emit(.transitionChanged(.init(sequenceId: seq.id, transitionId: id, before: before, after: after)))
        }
    }

    // MARK: Captions

    mutating func addCaptionTrack(_ o: Command.Operation.AddCaptionTrack) throws(EditorError) {
        let seq = try sequence(try resolve(o.sequenceId))
        let id = o.id ?? mint()
        guard state.locate(track: id) == nil else { throw .invalid(reason: "Track \(id) already exists") }
        emit(
            .captionTrackAdded(
                .init(
                    sequenceId: seq.id, trackId: id, name: o.name ?? defaultTrackName(.caption, in: seq),
                    position: seq.tracks.count, language: o.language, style: o.style)))
        created(id.rawValue)
    }

    mutating func replaceCaptions(_ o: Command.Operation.ReplaceCaptions) throws(EditorError) {
        let (seq, _, track) = try locateTrack(try resolve(o.trackId))
        guard track.kind == .caption else { throw .invalid(reason: "Track \(track.id) is not a caption track") }
        try requireUnlocked(track)
        var after: [Clip] = []
        var usedIds = Set<ClipID>()
        for item in o.items {
            let id = item.id ?? mint()
            guard usedIds.insert(id).inserted else { throw .invalid(reason: "Duplicate caption id \(id)") }
            if let existing = state.locate(clip: id), existing.clip.trackId != track.id {
                throw .invalid(reason: "Clip \(id) already exists on another track")
            }
            let start = item.start.snapped(to: seq.frameDuration)
            let duration = item.duration.snapped(to: seq.frameDuration)
            guard !start.isNegative else { throw .invalid(reason: "Caption cannot start before zero") }
            guard duration.isPositive else { throw .invalid(reason: "Caption \(id) is shorter than a frame") }
            let clip = Clip(
                id: id, trackId: track.id, start: start, sourceIn: .zero, sourceOut: duration, text: item.text,
                words: item.words, style: item.style)
            after.append(clip)
        }
        after.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        for i in after.indices.dropFirst() where after[i].start < after[i - 1].start + after[i - 1].sourceOut {
            throw .invalid(reason: "Captions \(after[i - 1].id) and \(after[i].id) overlap")
        }
        let before = track.clips.values.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        if before != after {
            emit(.captionsReplaced(.init(sequenceId: seq.id, trackId: track.id, before: before, after: after)))
        }
    }

    mutating func editCaption(_ o: Command.Operation.EditCaption) throws(EditorError) {
        let l = try locate(try resolve(o.clipId))
        try requireUnlocked(l.track)
        guard l.track.kind == .caption, let before = l.clip.caption else {
            throw .invalid(reason: "Clip \(l.clip.id) is not a caption")
        }
        var after = before
        if let text = o.text { after.text = text }
        if let words = o.words { after.words = words }
        if before != after {
            emit(.captionEdited(.init(sequenceId: l.sequence.id, clipId: l.clip.id, before: before, after: after)))
        }
    }

    mutating func setCaptionStyle(_ o: Command.Operation.SetCaptionStyle) throws(EditorError) {
        switch (o.trackId, o.clipId) {
        case (nil, nil), (.some, .some):
            throw .invalid(reason: "setCaptionStyle takes exactly one of trackId or clipId")
        case (.some(let ref), nil):
            let (seq, _, track) = try locateTrack(try resolve(ref))
            guard track.kind == .caption else { throw .invalid(reason: "Track \(track.id) is not a caption track") }
            try requireUnlocked(track)
            if track.captionStyle != o.style {
                emit(
                    .captionStyleSet(
                        .init(
                            sequenceId: seq.id, trackId: track.id, clipId: nil, before: track.captionStyle,
                            after: o.style)))
            }
        case (nil, .some(let ref)):
            let l = try locate(try resolve(ref))
            try requireUnlocked(l.track)
            guard l.track.kind == .caption else { throw .invalid(reason: "Clip \(l.clip.id) is not a caption") }
            if l.clip.style != o.style {
                emit(
                    .captionStyleSet(
                        .init(
                            sequenceId: l.sequence.id, trackId: l.track.id, clipId: l.clip.id, before: l.clip.style,
                            after: o.style)))
            }
        }
    }

    // MARK: Markers

    mutating func addMarker(_ o: Command.Operation.AddMarker) throws(EditorError) {
        let seq = try sequence(try resolve(o.sequenceId))
        let id = o.id ?? mint()
        guard state.locate(marker: id) == nil else { throw .invalid(reason: "Marker \(id) already exists") }
        let at = o.at.snapped(to: seq.frameDuration)
        guard !at.isNegative else { throw .invalid(reason: "Marker time must not be negative") }
        emit(
            .markerAdded(
                .init(sequenceId: seq.id, markerId: id, after: Marker(id: id, at: at, label: o.label, colour: o.colour))
            ))
        created(id.rawValue)
    }
}
