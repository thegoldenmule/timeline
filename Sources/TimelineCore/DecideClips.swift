import Foundation

extension Decider {
    // MARK: Ripple and overwrite helpers

    /// Tracks a ripple applies to: every unlocked track for `.sequence`, only `addressed` for `.track`.
    func rippleTracks(_ scope: RippleScope, addressed: Set<TrackID>, in seq: Sequence) -> Set<TrackID> {
        switch scope {
        case .sequence: Set(seq.tracks.filter { !$0.locked }.map(\.id))
        case .track: addressed.filter { id in seq.track(id).map { !$0.locked } ?? false }
        }
    }

    /// Shifts every clip that starts at or after `point` on `tracks` by `delta`, and every marker at
    /// or after `point`. Emits one `ClipMoved`/`MarkerMoved` per shifted item.
    ///
    /// `including` shifts named clips whatever their start. It carries the tails `splitSpanningClips`
    /// just made: a tail begins at its own track's *snapped* cut, which on a frame-aligned track can be
    /// a fraction of a frame before `point`, and a tail left behind by the shift is the whole insert
    /// gone wrong — the clip is cut for no reason and everything after it loses sync.
    mutating func ripple(
        in sequenceId: SequenceID, from point: RationalTime, by delta: RationalTime, scope: RippleScope,
        addressed: Set<TrackID>, excluding: Set<ClipID> = [], including: Set<ClipID> = []
    ) {
        guard !delta.isZero, let seq = state.sequences[sequenceId] else { return }
        let tracks = rippleTracks(scope, addressed: addressed, in: seq)
        for track in seq.tracks where tracks.contains(track.id) {
            let clips = track.clips.values
                .filter { ($0.start >= point || including.contains($0.id)) && !excluding.contains($0.id) }
                .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            for clip in delta.isNegative ? clips : clips.reversed() {
                emit(
                    .clipMoved(
                        .init(
                            sequenceId: seq.id, clipId: clip.id,
                            before: ClipPlacement(trackId: track.id, start: clip.start),
                            after: ClipPlacement(trackId: track.id, start: clip.start + delta))))
            }
        }
        guard scope == .sequence else { return }
        for marker in seq.markers.values.filter({ $0.at >= point }).sorted(by: { ($0.at, $0.id) < ($1.at, $1.id) }) {
            emit(
                .markerMoved(
                    .init(sequenceId: seq.id, markerId: marker.id, before: marker.at, after: marker.at + delta)))
        }
    }

    /// Insert semantics: splits any clip that spans `point` on `tracks`, so the right part can shift.
    /// Returns the tails, which the caller's `ripple` must shift as a set — each one starts at its own
    /// track's snapped cut, not at `point`.
    @discardableResult
    mutating func splitSpanningClips(
        in sequenceId: SequenceID, at point: RationalTime, tracks: Set<TrackID>,
        excluding: Set<ClipID> = []
    ) throws(EditorError) -> Set<ClipID> {
        guard let seq = state.sequences[sequenceId] else { return [] }
        var tails: Set<ClipID> = []
        for track in seq.tracks where tracks.contains(track.id) {
            for clip in track.clips.values.sorted(by: { $0.id < $1.id }) where !excluding.contains(clip.id) {
                let end = seq.end(of: clip)
                if clip.start < point && point < end {
                    let cut = snap(point, track, in: seq)
                    if clip.start < cut && cut < end {
                        let tail: ClipID = mint()
                        try splitSingle(clip, at: cut, newId: tail, in: seq, track: track, newGroup: clip.linkGroupId)
                        tails.insert(tail)
                    }
                }
            }
        }
        return tails
    }

    /// Overwrite semantics: makes `[from, to)` on `trackId` free of other clips by trimming, splitting,
    /// or removing whatever overlaps it.
    mutating func clearRange(
        on trackId: TrackID, in sequenceId: SequenceID, from: RationalTime, to: RationalTime, excluding: Set<ClipID>
    ) throws(EditorError) {
        guard from < to, let seq = state.sequences[sequenceId], let track = seq.track(trackId) else { return }
        let overlapping = track.clips.values
            .filter { !excluding.contains($0.id) && $0.start < to && seq.end(of: $0) > from }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        for clip in overlapping {
            let end = seq.end(of: clip)
            if clip.start >= from && end <= to {
                removeSingle(clip, in: seq)
            } else if clip.start < from && end > to {
                let newId: ClipID = mint()
                try splitSingle(clip, at: to, newId: newId, in: seq, track: track, newGroup: clip.linkGroupId)
                guard let left = state.sequences[sequenceId]?.clip(clip.id) else { continue }
                try trimSingle(left, edge: .tail, to: from, keepStart: true, in: seq, track: track)
            } else if clip.start < from {
                try trimSingle(clip, edge: .tail, to: from, keepStart: true, in: seq, track: track)
            } else {
                try trimSingle(clip, edge: .head, to: to, keepStart: false, in: seq, track: track)
            }
        }
    }

    /// Removes transitions that no longer join two adjacent clips with enough handles.
    mutating func sweepTransitions(in sequenceId: SequenceID) {
        guard let seq = state.sequences[sequenceId] else { return }
        for t in seq.transitions.values.sorted(by: { $0.id < $1.id }) {
            var valid = false
            if let left = seq.clip(t.leftClipId), let right = seq.clip(t.rightClipId),
                left.trackId == t.trackId, right.trackId == t.trackId, seq.end(of: left) == right.start
            {
                let max = Invariants.maxTransitionDuration(
                    left: left, right: right, alignment: t.alignment, in: seq, assets: state.assets)
                valid = t.duration <= max
            }
            if !valid { emit(.transitionRemoved(.init(sequenceId: seq.id, transitionId: t.id, before: t))) }
        }
    }

    /// Removes the transitions attached to `clipId`.
    mutating func removeTransitions(of clipId: ClipID, in seq: Sequence) {
        for t in seq.transitions.values.filter({ $0.leftClipId == clipId || $0.rightClipId == clipId })
            .sorted(by: { $0.id < $1.id })
        {
            emit(.transitionRemoved(.init(sequenceId: seq.id, transitionId: t.id, before: t)))
        }
    }

    // MARK: Single-clip primitives (no link fan-out, no ripple)

    mutating func removeSingle(_ clip: Clip, in seq: Sequence) {
        removeTransitions(of: clip.id, in: seq)
        emit(.clipRemoved(.init(sequenceId: seq.id, clipId: clip.id, snapshot: clip)))
    }

    /// Trims one edge of `clip` so that edge sits at `to`. `keepStart` is the ripple head-trim form,
    /// where the clip keeps its start and its content slides.
    mutating func trimSingle(
        _ clip: Clip, edge: Edge, to: RationalTime, keepStart: Bool, in seq: Sequence, track: Track
    ) throws(EditorError) {
        let fd: RationalTime? = track.kind.isFrameAligned ? seq.frameDuration : nil
        let to = snap(to, track, in: seq)
        var after = ClipRange(clip)
        switch edge {
        case .head:
            let delta = to - clip.start
            after.sourceIn = clip.sourceIn + delta * clip.speed
            if !keepStart { after.start = to }
        case .tail:
            after.sourceOut = clip.sourceIn + (to - clip.start) * clip.speed
        }
        guard !after.start.isNegative else { throw .invalid(reason: "Clip \(clip.id) cannot start before zero") }
        guard !after.sourceIn.isNegative else {
            throw .invalid(reason: "Clip \(clip.id) has no media before its current head")
        }
        if let assetId = clip.assetId {
            let a = try asset(assetId)
            guard after.sourceOut <= a.duration else {
                throw .invalid(reason: "Clip \(clip.id) has no media after its current tail")
            }
        }
        guard after.sourceIn < after.sourceOut else { throw .invalid(reason: "Trim would leave clip \(clip.id) empty") }
        var probe = clip
        probe.sourceIn = after.sourceIn
        probe.sourceOut = after.sourceOut
        guard probe.duration(frameDuration: fd).isPositive else {
            throw .invalid(reason: "Trim would leave clip \(clip.id) shorter than a frame")
        }
        if after != ClipRange(clip) {
            emit(
                .clipTrimmed(
                    .init(sequenceId: seq.id, clipId: clip.id, edge: edge, before: ClipRange(clip), after: after)))
        }
    }

    /// Splits `clip` at timeline time `at` (already snapped). The right part gets `newId` and `newGroup`.
    mutating func splitSingle(
        _ clip: Clip, at: RationalTime, newId: ClipID, in seq: Sequence, track: Track, newGroup: LinkGroupID?
    ) throws(EditorError) {
        let end = seq.end(of: clip)
        guard clip.start < at, at < end else {
            throw .invalid(reason: "Split point \(at) is not inside clip \(clip.id)")
        }
        guard state.locate(clip: newId) == nil else { throw .invalid(reason: "Clip \(newId) already exists") }
        let sourceAt = clip.sourceIn + (at - clip.start) * clip.speed
        guard clip.sourceIn < sourceAt, sourceAt < clip.sourceOut else {
            throw .invalid(reason: "Split point \(at) is not inside clip \(clip.id)")
        }
        var right = clip
        right.id = newId
        right.start = at
        right.sourceIn = sourceAt
        right.linkGroupId = newGroup
        if let words = clip.words { right.words = words.filter { $0.t0 >= sourceAt } }
        let after = ClipRange(start: clip.start, sourceIn: clip.sourceIn, sourceOut: sourceAt)
        emit(
            .clipSplit(
                .init(
                    sequenceId: seq.id, clipId: clip.id, at: at, newClipId: newId, before: ClipRange(clip),
                    after: after,
                    newClip: right)))
        // A transition on the clip's tail now belongs to the right part.
        for t in seq.transitions.values.filter({ $0.leftClipId == clip.id }).sorted(by: { $0.id < $1.id }) {
            var moved = t
            moved.leftClipId = newId
            emit(.transitionChanged(.init(sequenceId: seq.id, transitionId: t.id, before: t, after: moved)))
        }
    }

    /// The clip and, unless `unlinked`, every other member of its link group on an unlocked track.
    func group(of l: Located, unlinked: Bool) throws(EditorError) -> [Located] {
        try requireUnlocked(l.track)
        guard !unlinked, let g = l.clip.linkGroupId else { return [l] }
        var result = [l]
        for member in l.sequence.members(of: g).sorted(by: { $0.id < $1.id }) where member.id != l.clip.id {
            let m = try locate(member.id)
            try requireUnlocked(m.track)
            result.append(m)
        }
        return result
    }

    // MARK: addClip

    /// The audio track that pairs with a video track (same ordinal), or vice versa.
    func partnerTrack(for track: Track, in seq: Sequence) -> Track? {
        let wanted: TrackKind = track.kind == .video ? .audio : .video
        let same = seq.tracks.filter { $0.kind == track.kind }
        let others = seq.tracks.filter { $0.kind == wanted }
        guard let ordinal = same.firstIndex(where: { $0.id == track.id }) else { return nil }
        if ordinal < others.count, !others[ordinal].locked { return others[ordinal] }
        return others.first { !$0.locked }
    }

    mutating func addClip(_ o: Command.Operation.AddClip) throws(EditorError) {
        let seq = try sequence(try resolve(o.sequenceId))
        let trackId = try resolve(o.trackId)
        guard let track = seq.track(trackId) else { throw .notFound(id: trackId.rawValue) }
        try requireUnlocked(track)
        guard track.kind != .caption else {
            throw .invalid(reason: "Clips on caption tracks are added with replaceCaptions")
        }
        var assetValue: Asset?
        if let ref = o.assetId {
            let a = try asset(try resolve(ref))
            switch track.kind {
            case .video:
                guard a.hasVideo || a.kind == .image else {
                    throw .invalid(reason: "Asset \(a.id) has no video", suggestion: "Add it to an audio track")
                }
            case .audio:
                guard a.hasAudio else { throw .invalid(reason: "Asset \(a.id) has no audio") }
            case .caption: break
            }
            assetValue = a
        }
        let at = snap(o.at, track, in: seq)
        let sourceIn = snap(o.sourceIn, track, in: seq)
        let sourceOut = snap(o.sourceOut, track, in: seq)
        guard !at.isNegative else { throw .invalid(reason: "Clip cannot start before zero") }
        guard !sourceIn.isNegative, sourceIn < sourceOut else { throw .invalid(reason: "Source range is empty") }
        if let a = assetValue, sourceOut > a.duration {
            throw .invalid(reason: "Source range ends after the asset's duration \(a.duration)")
        }
        let id = o.id ?? mint()
        guard state.locate(clip: id) == nil else { throw .invalid(reason: "Clip \(id) already exists") }
        var clip = Clip(
            id: id, trackId: track.id, assetId: assetValue?.id, start: at, sourceIn: sourceIn, sourceOut: sourceOut)
        clip.label = o.label
        var clips = [clip]
        if o.link == .auto, let a = assetValue, a.hasVideo, a.hasAudio, let partner = partnerTrack(for: track, in: seq)
        {
            let partnerId = o.linkedId ?? mint()
            guard state.locate(clip: partnerId) == nil else {
                throw .invalid(reason: "Clip \(partnerId) already exists")
            }
            let group: LinkGroupID = mint()
            clips[0].linkGroupId = group
            var second = clips[0]
            second.id = partnerId
            second.trackId = partner.id
            clips.append(second)
        }
        let duration = clips[0].duration(frameDuration: track.kind.isFrameAligned ? seq.frameDuration : nil)
        guard duration.isPositive else { throw .invalid(reason: "Clip would be shorter than a frame") }
        let placed = Set(clips.map(\.id))
        let addressed = Set(clips.map(\.trackId))
        switch o.mode {
        case .ripple:
            let tracks = rippleTracks(o.rippleScope, addressed: addressed, in: seq)
            let tails = try splitSpanningClips(in: seq.id, at: at, tracks: tracks)
            ripple(
                in: seq.id, from: at, by: duration, scope: o.rippleScope, addressed: addressed, including: tails)
        case .overwrite:
            for c in clips {
                let end =
                    c.start
                    + c.duration(frameDuration: seq.track(c.trackId)!.kind.isFrameAligned ? seq.frameDuration : nil)
                try clearRange(on: c.trackId, in: seq.id, from: c.start, to: end, excluding: placed)
            }
        }
        for c in clips { emit(.clipAdded(.init(sequenceId: seq.id, clipId: c.id, snapshot: c))) }
        created(id.rawValue)
        sweepTransitions(in: seq.id)
    }

    // MARK: moveClip

    mutating func moveClip(_ o: Command.Operation.MoveClip) throws(EditorError) {
        let l = try locate(try resolve(o.clipId))
        let seq = l.sequence
        var destination = l.track
        if let ref = o.to.trackId {
            let id = try resolve(ref)
            guard let t = seq.track(id) else { throw .notFound(id: id.rawValue) }
            guard t.kind == l.track.kind else {
                throw .invalid(reason: "Cannot move a \(l.track.kind.rawValue) clip to a \(t.kind.rawValue) track")
            }
            try requireUnlocked(t)
            destination = t
        }
        let newStart = snap(o.to.start, destination, in: seq)
        guard !newStart.isNegative else { throw .invalid(reason: "Clip cannot start before zero") }
        let delta = newStart - l.clip.start
        let members = try group(of: l, unlinked: o.unlinked)
        if delta.isZero && destination.id == l.track.id { return }
        for m in members where (m.clip.start + delta).isNegative {
            throw .invalid(reason: "Linked clip \(m.clip.id) cannot start before zero")
        }
        let moving = Set(members.map(\.clip.id))
        for m in members { removeTransitions(of: m.clip.id, in: seq) }
        var placements: [(Located, TrackID, RationalTime)] = []
        for m in members {
            let t = m.clip.id == l.clip.id ? destination.id : m.track.id
            placements.append((m, t, m.clip.start + delta))
        }
        switch o.mode {
        case .ripple:
            let addressed = Set(placements.map(\.1))
            let tracks = rippleTracks(o.rippleScope, addressed: addressed, in: seq)
            let tails = try splitSpanningClips(in: seq.id, at: newStart, tracks: tracks, excluding: moving)
            ripple(
                in: seq.id, from: newStart, by: l.duration, scope: o.rippleScope, addressed: addressed,
                excluding: moving, including: tails)
        case .overwrite:
            for (m, trackId, start) in placements {
                try clearRange(on: trackId, in: seq.id, from: start, to: start + m.duration, excluding: moving)
            }
        }
        for (m, trackId, start) in placements {
            emit(
                .clipMoved(
                    .init(
                        sequenceId: seq.id, clipId: m.clip.id,
                        before: ClipPlacement(trackId: m.track.id, start: m.clip.start),
                        after: ClipPlacement(trackId: trackId, start: start))))
        }
        sweepTransitions(in: seq.id)
    }

    // MARK: trimClip

    mutating func trimClip(_ o: Command.Operation.TrimClip) throws(EditorError) {
        let l = try locate(try resolve(o.clipId))
        let seq = l.sequence
        let to = snap(o.to, l.track, in: seq)
        let members = try group(of: l, unlinked: o.unlinked)
        let delta: RationalTime
        let point: RationalTime
        switch o.edge {
        case .head:
            delta = to - l.clip.start
            point = o.mode == .ripple ? to : l.clip.start
        case .tail:
            delta = to - l.end
            point = l.end
        }
        if delta.isZero { return }
        let moving = Set(members.map(\.clip.id))
        switch o.mode {
        case .ripple:
            for m in members {
                let target = o.edge == .head ? m.clip.start + delta : m.end + delta
                try trimSingle(m.clip, edge: o.edge, to: target, keepStart: true, in: seq, track: m.track)
            }
            let shift = o.edge == .head ? -delta : delta
            ripple(
                in: seq.id, from: point, by: shift, scope: o.rippleScope, addressed: Set(members.map(\.track.id)),
                excluding: moving)
        case .overwrite:
            for m in members {
                let target = o.edge == .head ? m.clip.start + delta : m.end + delta
                if delta.isNegative && o.edge == .head {
                    try clearRange(on: m.track.id, in: seq.id, from: target, to: m.clip.start, excluding: moving)
                } else if delta.isPositive && o.edge == .tail {
                    try clearRange(on: m.track.id, in: seq.id, from: m.end, to: target, excluding: moving)
                }
                try trimSingle(m.clip, edge: o.edge, to: target, keepStart: false, in: seq, track: m.track)
            }
        }
        sweepTransitions(in: seq.id)
    }

    // MARK: splitClip

    mutating func splitClip(_ o: Command.Operation.SplitClip) throws(EditorError) {
        let l = try locate(try resolve(o.clipId))
        let seq = l.sequence
        let at = snap(o.at, l.track, in: seq)
        guard l.clip.start < at, at < l.end else {
            throw .invalid(reason: "Split point \(at) is not inside clip \(l.clip.id)")
        }
        let sourceAt = l.clip.sourceIn + (at - l.clip.start) * l.clip.speed
        var members = try group(of: l, unlinked: o.unlinked)
        // Other members split at the same source time; skip those the point falls outside of.
        members = members.filter { m in
            if m.clip.id == l.clip.id { return true }
            let mAt = m.clip.start + (sourceAt - m.clip.sourceIn) / m.clip.speed
            return m.clip.start < mAt && mAt < m.end
        }
        members =
            [l]
            + members.filter { $0.clip.id != l.clip.id }.sorted {
                (seq.trackIndex(of: $0.track.id) ?? 0, $0.clip.id) < (seq.trackIndex(of: $1.track.id) ?? 0, $1.clip.id)
            }
        let newGroup: LinkGroupID? = (members.count > 1 && l.clip.linkGroupId != nil) ? mint() : l.clip.linkGroupId
        var newIds = o.newIds ?? []
        for (i, m) in members.enumerated() {
            let newId: ClipID = i < newIds.count ? newIds[i] : mint()
            if i >= newIds.count { newIds.append(newId) }
            let mAt =
                m.clip.id == l.clip.id
                ? at : snap(m.clip.start + (sourceAt - m.clip.sourceIn) / m.clip.speed, m.track, in: seq)
            try splitSingle(m.clip, at: mAt, newId: newId, in: seq, track: m.track, newGroup: newGroup)
        }
        created(newIds[0].rawValue)
        sweepTransitions(in: seq.id)
    }

    // MARK: joinClips

    mutating func joinClips(_ o: Command.Operation.JoinClips) throws(EditorError) {
        let left = try locate(try resolve(o.leftClipId))
        let right = try locate(try resolve(o.rightClipId))
        try requireUnlocked(left.track)
        guard left.sequence.id == right.sequence.id, left.track.id == right.track.id else {
            throw .invalid(reason: "Clips to join must be on the same track")
        }
        guard left.clip.assetId == right.clip.assetId else {
            throw .invalid(reason: "Clips to join must share an asset")
        }
        guard left.clip.speed == right.clip.speed else {
            throw .invalid(reason: "Clips to join must have the same speed")
        }
        guard left.end == right.clip.start else { throw .invalid(reason: "Clips to join must be adjacent") }
        guard left.clip.sourceOut == right.clip.sourceIn else {
            throw .invalid(reason: "Clips to join must have contiguous source ranges")
        }
        let seq = left.sequence
        for t in seq.transitions.values.sorted(by: { $0.id < $1.id }) {
            if t.leftClipId == left.clip.id && t.rightClipId == right.clip.id {
                emit(.transitionRemoved(.init(sequenceId: seq.id, transitionId: t.id, before: t)))
            } else if t.leftClipId == right.clip.id {
                var moved = t
                moved.leftClipId = left.clip.id
                emit(.transitionChanged(.init(sequenceId: seq.id, transitionId: t.id, before: t, after: moved)))
            }
        }
        let keptAfter = ClipRange(start: left.clip.start, sourceIn: left.clip.sourceIn, sourceOut: right.clip.sourceOut)
        emit(
            .clipsJoined(
                .init(
                    sequenceId: seq.id, keptClipId: left.clip.id, removedClipId: right.clip.id,
                    keptBefore: ClipRange(left.clip), keptAfter: keptAfter, removedSnapshot: right.clip)))
        sweepTransitions(in: seq.id)
    }

    // MARK: removeClip

    mutating func removeClip(_ o: Command.Operation.RemoveClip) throws(EditorError) {
        let l = try locate(try resolve(o.clipId))
        let seq = l.sequence
        let members = try group(of: l, unlinked: o.unlinked)
        for m in members { removeSingle(m.clip, in: seq) }
        if o.mode == .ripple {
            ripple(
                in: seq.id, from: l.end, by: -l.duration, scope: o.rippleScope, addressed: Set(members.map(\.track.id)))
        }
        sweepTransitions(in: seq.id)
    }

    // MARK: setClipSpeed

    mutating func setClipSpeed(_ o: Command.Operation.SetClipSpeed) throws(EditorError) {
        let l = try locate(try resolve(o.clipId))
        let seq = l.sequence
        guard o.after.isPositive else { throw .invalid(reason: "Speed must be positive") }
        if l.clip.speed == o.after { return }
        let members = try group(of: l, unlinked: false)
        var probe = l.clip
        probe.speed = o.after
        let newDuration = probe.duration(frameDuration: l.frameDuration)
        guard newDuration.isPositive else { throw .invalid(reason: "Clip would be shorter than a frame at that speed") }
        let delta = newDuration - l.duration
        let moving = Set(members.map(\.clip.id))
        if delta.isPositive && o.mode == .overwrite {
            for m in members {
                var p = m.clip
                p.speed = o.after
                let end = m.clip.start + p.duration(frameDuration: m.frameDuration)
                try clearRange(on: m.track.id, in: seq.id, from: m.end, to: end, excluding: moving)
            }
        }
        for m in members {
            emit(.clipSpeedSet(.init(sequenceId: seq.id, clipId: m.clip.id, before: m.clip.speed, after: o.after)))
        }
        if o.mode == .ripple {
            ripple(
                in: seq.id, from: l.end, by: delta, scope: o.rippleScope, addressed: Set(members.map(\.track.id)),
                excluding: moving)
        }
        sweepTransitions(in: seq.id)
    }
}
