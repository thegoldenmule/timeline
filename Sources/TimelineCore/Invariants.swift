import Foundation

/// The structural rules of `docs/design/timeline-model.md` section 3, checked after every transaction.
/// Items 5 and 6 (link groups keep their offsets; locked tracks are never mutated) are behavioural
/// and enforced by `decide`; the property tests cover them.
public enum Invariants {
    public static func check(_ state: Project) throws(EditorError) {
        var seen = Set<String>()
        func unique(_ id: String) throws(EditorError) {
            guard seen.insert(id).inserted else { throw .invalid(reason: "Duplicate id \(id)") }
        }
        try unique(state.id.rawValue)
        for (key, asset) in state.assets {
            guard key == asset.id else { throw .invalid(reason: "Asset \(asset.id) is stored under key \(key)") }
            try unique(asset.id.rawValue)
            guard asset.duration.isPositive else {
                throw .invalid(reason: "Asset \(asset.id) has a non-positive duration")
            }
        }
        if let active = state.activeSequenceId, state.sequences[active] == nil {
            throw .notFound(id: active.rawValue)
        }
        for (key, seq) in state.sequences {
            guard key == seq.id else { throw .invalid(reason: "Sequence \(seq.id) is stored under key \(key)") }
            try unique(seq.id.rawValue)
            guard seq.frameDuration.isPositive else {
                throw .invalid(reason: "Sequence \(seq.id) has a non-positive frame duration")
            }
            try check(sequence: seq, assets: state.assets, seen: &seen)
        }
    }

    static func check(sequence seq: Sequence, assets: [AssetID: Asset], seen: inout Set<String>) throws(EditorError) {
        func unique(_ id: String) throws(EditorError) {
            guard seen.insert(id).inserted else { throw .invalid(reason: "Duplicate id \(id)") }
        }
        var clipTrack: [ClipID: TrackID] = [:]
        for track in seq.tracks {
            try unique(track.id.rawValue)
            let fd: RationalTime? = track.kind.isFrameAligned ? seq.frameDuration : nil
            var placed: [(start: RationalTime, end: RationalTime, id: ClipID)] = []
            for (key, clip) in track.clips {
                guard key == clip.id else { throw .invalid(reason: "Clip \(clip.id) is stored under key \(key)") }
                try unique(clip.id.rawValue)
                guard clip.trackId == track.id else {
                    throw .invalid(reason: "Clip \(clip.id) claims track \(clip.trackId) but sits on \(track.id)")
                }
                clipTrack[clip.id] = track.id
                // 2. Source range.
                guard !clip.sourceIn.isNegative, clip.sourceIn < clip.sourceOut else {
                    throw .invalid(reason: "Clip \(clip.id) has an empty or negative source range")
                }
                if let assetId = clip.assetId {
                    guard let asset = assets[assetId] else { throw .notFound(id: assetId.rawValue) }
                    guard clip.sourceOut <= asset.duration else {
                        throw .invalid(reason: "Clip \(clip.id) reads past the end of asset \(assetId)")
                    }
                }
                guard clip.speed.isPositive else { throw .invalid(reason: "Clip \(clip.id) has a non-positive speed") }
                // 3. Frame boundaries on video and caption tracks.
                if let fd {
                    for (name, t) in [
                        ("start", clip.start), ("sourceIn", clip.sourceIn), ("sourceOut", clip.sourceOut),
                    ]
                    where !t.isFrameAligned(frameDuration: fd) {
                        throw .invalid(reason: "Clip \(clip.id) \(name) \(t) is not on a frame boundary")
                    }
                }
                let duration = clip.duration(frameDuration: fd)
                guard duration.isPositive else { throw .invalid(reason: "Clip \(clip.id) has zero timeline duration") }
                for effect in clip.effects { try unique(effect.id.rawValue) }
                placed.append((clip.start, clip.start + duration, clip.id))
            }
            // 1. No overlaps.
            placed.sort { $0.start < $1.start }
            for i in placed.indices.dropFirst() where placed[i].start < placed[i - 1].end {
                throw .invalid(reason: "Clips \(placed[i - 1].id) and \(placed[i].id) overlap on track \(track.id)")
            }
        }
        // 4. Transitions.
        for (key, tr) in seq.transitions {
            guard key == tr.id else { throw .invalid(reason: "Transition \(tr.id) is stored under key \(key)") }
            try unique(tr.id.rawValue)
            guard let left = seq.clip(tr.leftClipId) else { throw .notFound(id: tr.leftClipId.rawValue) }
            guard let right = seq.clip(tr.rightClipId) else { throw .notFound(id: tr.rightClipId.rawValue) }
            guard clipTrack[left.id] == tr.trackId, clipTrack[right.id] == tr.trackId else {
                throw .invalid(reason: "Transition \(tr.id) references clips on another track")
            }
            guard seq.track(tr.trackId)?.kind != .caption else {
                throw .invalid(reason: "Transition \(tr.id) sits on a caption track")
            }
            guard seq.end(of: left) == right.start else {
                throw .invalid(reason: "Transition \(tr.id) joins clips that are not adjacent")
            }
            guard tr.duration.isPositive else { throw .invalid(reason: "Transition \(tr.id) has no duration") }
            let max = maxTransitionDuration(left: left, right: right, alignment: tr.alignment, in: seq, assets: assets)
            guard tr.duration <= max else { throw .transitionHandles(maxDuration: max) }
        }
        for (key, marker) in seq.markers {
            guard key == marker.id else { throw .invalid(reason: "Marker \(marker.id) is stored under key \(key)") }
            try unique(marker.id.rawValue)
        }
    }

    /// The longest transition that fits between `left` and `right` with `alignment`, given the
    /// source media beyond the cut on each side. Generated clips have unlimited handles.
    public static func maxTransitionDuration(
        left: Clip, right: Clip, alignment: TransitionAlignment, in seq: Sequence, assets: [AssetID: Asset]
    ) -> RationalTime {
        // Generated clips have no media limit; a 68-year handle stands in for infinity and still
        // converts to frames without overflowing.
        let unlimited = RationalTime(Int64(Int32.max), 1)
        var leftAvail = unlimited
        if let a = left.assetId.flatMap({ assets[$0] }) {
            leftAvail = (a.duration - left.sourceOut) / left.speed
        }
        var rightAvail = unlimited
        if right.assetId.flatMap({ assets[$0] }) != nil {
            rightAvail = right.sourceIn / right.speed
        }
        var max: RationalTime
        switch alignment {
        case .centered: max = RationalTime.min(leftAvail, rightAvail) * 2
        case .startOnCut: max = rightAvail
        case .endOnCut: max = leftAvail
        }
        if max.isNegative { max = .zero }
        if let kind = seq.track(left.trackId)?.kind, kind.isFrameAligned {
            max = max.floored(to: seq.frameDuration)
        }
        return max
    }
}
