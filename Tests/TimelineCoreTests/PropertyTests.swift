import Foundation
import Testing
import TimelineCore

/// Draws random, mostly valid commands against a project.
struct CommandDrawer {
    var rng: SeededRandom

    init(seed: UInt64) { rng = SeededRandom(seed: seed) }

    mutating func pick<T>(_ items: [T]) -> T? {
        guard !items.isEmpty else { return nil }
        return items[Int.random(in: 0..<items.count, using: &rng)]
    }

    mutating func time(_ maxFrames: Int64) -> RationalTime {
        RationalTime.frames(Int64.random(in: 0...maxFrames, using: &rng), of: fd24)
    }

    mutating func draw(from b: ProjectBuilder) -> Command.Operation {
        let seq = b.sequence
        let clips = seq.tracks.filter { $0.kind != .caption }.flatMap { $0.clips.values }.sorted { $0.id < $1.id }
        let mode: EditMode = Bool.random(using: &rng) ? .ripple : .overwrite
        let scope: RippleScope = Int.random(in: 0..<4, using: &rng) == 0 ? .track : .sequence
        let unlinked = Int.random(in: 0..<5, using: &rng) == 0
        switch Int.random(in: 0..<14, using: &rng) {
        case 0, 1:
            guard let c = pick(clips) else { return .redo }
            let end = seq.end(of: c)
            let edge: Edge = Bool.random(using: &rng) ? .head : .tail
            let delta = RationalTime.frames(Int64.random(in: -12...12, using: &rng), of: fd24)
            return .trimClip(
                .init(
                    clipId: .id(c.id), edge: edge, to: (edge == .head ? c.start : end) + delta, mode: mode,
                    rippleScope: scope, unlinked: unlinked))
        case 2:
            guard let c = pick(clips) else { return .redo }
            let tracks = seq.tracks.filter { $0.kind == seq.track(c.trackId)?.kind }
            let target = Bool.random(using: &rng) ? pick(tracks)?.id : nil
            return .moveClip(
                .init(
                    clipId: .id(c.id), to: .init(trackId: target.map { .id($0) }, start: time(300)), mode: mode,
                    rippleScope: scope, unlinked: unlinked))
        case 3:
            guard let c = pick(clips) else { return .redo }
            let dur = seq.duration(of: c)
            let at =
                c.start
                + RationalTime.frames(
                    Int64.random(in: 0...Swift.max(1, dur.frameIndex(frameDuration: fd24)), using: &rng), of: fd24)
            return .splitClip(.init(clipId: .id(c.id), at: at, unlinked: unlinked))
        case 4:
            guard let c = pick(clips) else { return .redo }
            return .removeClip(.init(clipId: .id(c.id), mode: mode, rippleScope: scope, unlinked: unlinked))
        case 5:
            guard let c = pick(clips) else { return .redo }
            let speeds = [Rational(1, 2), Rational(2, 1), Rational(3, 2), Rational.one]
            return .setClipSpeed(.init(clipId: .id(c.id), after: pick(speeds)!, mode: mode, rippleScope: scope))
        case 6:
            guard let track = pick(seq.tracks.filter { $0.kind != .caption }),
                let asset = pick(Array(b.project.assets.values))
            else { return .redo }
            let total = asset.duration.frameIndex(frameDuration: fd24)
            let len = Int64.random(in: 1...Swift.max(1, Swift.min(total, 60)), using: &rng)
            let start = Int64.random(in: 0...Swift.max(0, total - len), using: &rng)
            let link: LinkMode = Bool.random(using: &rng) ? .auto : .none
            return .addClip(
                .init(
                    sequenceId: .id(seq.id), trackId: .id(track.id), assetId: .id(asset.id), at: time(300),
                    sourceIn: RationalTime.frames(start, of: fd24),
                    sourceOut: RationalTime.frames(start + len, of: fd24), mode: mode, rippleScope: scope, link: link))
        case 7:
            let pairs = seq.tracks.flatMap { t -> [(Clip, Clip)] in
                let sorted = t.clips.values.sorted { $0.start < $1.start }
                return zip(sorted, sorted.dropFirst()).filter { seq.end(of: $0.0) == $0.1.start }
            }
            guard let (l, r) = pick(pairs) else { return .redo }
            let alignment: TransitionAlignment = pick(TransitionAlignment.allCases)!
            return .addTransition(
                .init(
                    leftClipId: .id(l.id), rightClipId: .id(r.id), kind: "dissolve",
                    duration: RationalTime.frames(Int64.random(in: 1...16, using: &rng), of: fd24), alignment: alignment
                ))
        case 8:
            guard let t = pick(Array(seq.transitions.values)) else { return .redo }
            return Bool.random(using: &rng)
                ? .removeTransition(.init(transitionId: .id(t.id)))
                : .updateTransition(
                    .init(
                        transitionId: .id(t.id),
                        duration: RationalTime.frames(Int64.random(in: 1...16, using: &rng), of: fd24)))
        case 9:
            if let m = pick(Array(seq.markers.values)), Bool.random(using: &rng) {
                return Bool.random(using: &rng)
                    ? .moveMarker(.init(markerId: .id(m.id), to: time(300))) : .removeMarker(.init(markerId: .id(m.id)))
            }
            return .addMarker(.init(sequenceId: .id(seq.id), at: time(300), label: "m"))
        case 10:
            guard let a = pick(clips), let b2 = pick(clips), a.id != b2.id else { return .redo }
            return Bool.random(using: &rng)
                ? .linkClips(.init(clipIds: [.id(a.id), .id(b2.id)])) : .unlinkClips(.init(clipIds: [.id(a.id)]))
        case 11:
            guard let t = pick(seq.tracks) else { return .redo }
            return .setTrackLocked(.init(trackId: .id(t.id), locked: !t.locked))
        case 12:
            let joinable = seq.tracks.flatMap { t -> [(Clip, Clip)] in
                let sorted = t.clips.values.sorted { $0.start < $1.start }
                return zip(sorted, sorted.dropFirst()).filter {
                    seq.end(of: $0.0) == $0.1.start && $0.0.sourceOut == $0.1.sourceIn && $0.0.assetId == $0.1.assetId
                }
            }
            guard let (l, r) = pick(joinable) else { return .redo }
            return .joinClips(.init(leftClipId: .id(l.id), rightClipId: .id(r.id)))
        default:
            return Bool.random(using: &rng) ? .undo(.init()) : .redo
        }
    }
}

@Suite struct PropertyTests {
    @Test func generatedProjectsAreValidAndDeterministic() throws {
        for seed in UInt64(1)...40 {
            let p = try ProjectGenerator(seed: seed).generate()
            try Invariants.check(p)
            #expect(try ProjectGenerator(seed: seed).generate() == p)
            #expect(try Project.fromJSON(try p.canonicalJSON()) == p)
        }
        var g = ProjectGenerator(seed: 7)
        g.clipsPerTrack = 20...30
        g.videoTracks = 3...3
        let big = try g.generate()
        #expect(big.sequences.values.first!.tracks.flatMap(\.clips).count > 60)
    }

    @Test func randomCommandsKeepInvariantsAndInvertExactly() throws {
        var accepted = 0
        var rejected = 0
        var kinds = Set<String>()
        for seed in UInt64(1)...60 {
            let b = try ProjectGenerator(seed: seed).builder()
            var drawer = CommandDrawer(seed: seed &* 31)
            for _ in 0..<40 {
                let op = drawer.draw(from: b)
                let before = b.project
                let events: [DomainEvent]
                do {
                    events = try b.apply(b.command(op))
                } catch {
                    rejected += 1
                    continue
                }
                guard !events.isEmpty else { continue }
                accepted += 1
                kinds.insert(op.typeName)
                let after = b.project
                #expect(evolve(before, events) == after)
                try Invariants.check(after)
                #expect(after.version == before.version + Int64(events.count))
                // Applying the inverse restores the exact prior state (version aside).
                var restored = after
                for payload in invert(transaction: events) {
                    let e = DomainEvent(
                        eventId: EventID(minting: b.ids), txnId: "undo", commandId: "undo", actor: .system,
                        occurredAt: b.clock.now(), payload: payload)
                    evolve(&restored, e)
                }
                restored.version = before.version
                #expect(restored == before, "seed \(seed) \(op.typeName): inverse did not restore state")
                try Invariants.check(restored)
            }
            // The whole log replays to the same state.
            #expect(evolve(Project.blank, b.events) == b.project)
        }
        #expect(accepted > 800, "accepted \(accepted), rejected \(rejected)")
        #expect(
            kinds.isSuperset(of: [
                "trimClip", "moveClip", "splitClip", "removeClip", "setClipSpeed", "addClip", "addTransition", "undo",
                "redo", "joinClips", "linkClips",
            ]))
    }

    @Test func rippleKeepsCrossTrackSyncAndLinkGroupsAligned() throws {
        var checked = 0
        for seed in UInt64(100)...160 {
            let b = try ProjectGenerator(seed: seed).builder()
            var drawer = CommandDrawer(seed: seed)
            for _ in 0..<30 {
                let seq = b.sequence
                let clips = seq.tracks.flatMap { $0.clips.values }
                guard let target = drawer.pick(clips.filter { !(seq.track($0.trackId)?.locked ?? true) }) else {
                    continue
                }
                let end = seq.end(of: target)
                let op: Command.Operation
                let point: RationalTime
                if Bool.random(using: &drawer.rng) {
                    let delta = RationalTime.frames(Int64.random(in: -6...6, using: &drawer.rng), of: fd24)
                    op = .trimClip(.init(clipId: .id(target.id), edge: .tail, to: end + delta, mode: .ripple))
                    point = end
                } else {
                    op = .removeClip(.init(clipId: .id(target.id), mode: .ripple))
                    point = end
                }
                let before = b.project
                let beforeSeq = seq
                let events: [DomainEvent]
                do { events = try b.apply(b.command(op)) } catch { continue }
                guard !events.isEmpty else { continue }
                checked += 1
                let afterSeq = b.sequence
                let group = target.linkGroupId.map { beforeSeq.members(of: $0).map(\.id) } ?? [target.id]
                let moved = events.compactMap { e -> (ClipID, RationalTime)? in
                    if case .clipMoved(let p) = e.payload { return (p.clipId, p.after.start - p.before.start) }
                    return nil
                }
                let deltas = Set(moved.map(\.1))
                #expect(deltas.count <= 1, "one ripple delta per transaction")
                let delta = deltas.first ?? .zero
                // Every clip on an unlocked track that started at/after the point moved by delta; others stayed.
                for track in beforeSeq.tracks where !track.locked {
                    for clip in track.clips.values where !group.contains(clip.id) {
                        guard let now = afterSeq.clip(clip.id) else { continue }
                        if clip.start >= point {
                            #expect(now.start == clip.start + delta, "seed \(seed): clip after point shifted by delta")
                        } else {
                            #expect(now.start == clip.start, "seed \(seed): clip before point stays")
                        }
                    }
                }
                for track in beforeSeq.tracks where track.locked {
                    for clip in track.clips.values {
                        #expect(afterSeq.clip(clip.id)?.start == clip.start, "locked tracks never move")
                    }
                }
                // Link groups keep their relative offsets.
                for g in Set(afterSeq.tracks.flatMap { $0.clips.values.compactMap(\.linkGroupId) }) {
                    let members = afterSeq.members(of: g).sorted { $0.id < $1.id }
                    let earlier = members.compactMap { beforeSeq.clip($0.id) }.sorted { $0.id < $1.id }
                    guard members.count == earlier.count, members.count > 1 else { continue }
                    for (m, e) in zip(members, earlier) {
                        #expect(m.start - members[0].start == e.start - earlier[0].start, "seed \(seed): group offsets")
                    }
                }
                _ = before
            }
        }
        #expect(checked > 200)
    }

    @Test func fullHistoryReplayAndUndoChains() throws {
        for seed in UInt64(200)...215 {
            let b = try ProjectGenerator(seed: seed).builder()
            var drawer = CommandDrawer(seed: seed)
            let checkpoints = [b.project]
            var states = checkpoints
            for _ in 0..<15 {
                let op = drawer.draw(from: b)
                switch op {
                case .undo, .redo: continue
                default: break
                }
                if let events = try? b.apply(b.command(op)), !events.isEmpty { states.append(b.project) }
            }
            // Undo every accepted command back to the checkpoint, then redo them all.
            let count = states.count - 1
            for i in stride(from: count - 1, through: 0, by: -1) {
                try b.apply(.undo(.init()))
                #expect(b.project.withVersion(0) == states[i].withVersion(0), "seed \(seed): undo to state \(i)")
            }
            #expect(b.history.redoStack.count == count)
            for i in 1...Swift.max(1, count) where count > 0 {
                try b.apply(.redo)
                #expect(b.project.withVersion(0) == states[i].withVersion(0), "seed \(seed): redo to state \(i)")
            }
            #expect(b.rejection(.redo) == .nothingToRedo)
            #expect(evolve(Project.blank, b.events) == b.project)
        }
    }
}
