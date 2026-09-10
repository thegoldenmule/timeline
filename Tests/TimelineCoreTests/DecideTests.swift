import Foundation
import Testing
import TimelineCore

@Suite struct DecideTests {
    @Test func createProjectOnlyOnBlank() throws {
        let b = ProjectBuilder()
        try b.createProject(name: "P")
        #expect(b.project.name == "P")
        #expect(b.project.version == 1)
        #expect(b.project.sequences.count == 1)
        #expect(b.project.activeSequenceId == b.sequenceId)
        #expect(
            b.rejection(
                .createProject(.init(name: "Q", sequence: .init(name: "s", frameDuration: fd24, width: 1, height: 1))))
                != nil)
        #expect(b.rejection(.addSequence(.init(name: "s", frameDuration: fd24, width: 1, height: 1))) != nil)
    }

    @Test func staleVersionCarriesChangedSince() throws {
        let s = try Scene()
        try s.video(at: 0, length: 24)
        let cmd = s.b.command(.renameProject(.init(name: "x")), expectedVersion: 2)
        #expect {
            try decide(s.b.project, cmd, ids: s.b.ids, clock: s.b.clock, history: s.b.history)
        } throws: { error in
            guard case .staleVersion(let current, let changed) = error as? EditorError else { return false }
            #expect(current == s.b.project.version)
            #expect(changed?.fromVersion == 2)
            #expect(changed?.toVersion == current)
            #expect(changed?.transactions.count == 3)
            #expect(changed?.transactions.last?.events.first?.type == "ClipAdded")
            return true
        }
        // Matching version passes; omitted version passes.
        _ = try decide(
            s.b.project, s.b.command(.renameProject(.init(name: "x")), expectedVersion: s.b.project.version),
            ids: s.b.ids, clock: s.b.clock)
    }

    @Test func noopCommandsEmitNothing() throws {
        let s = try Scene()
        #expect(try s.b.apply(.renameProject(.init(name: "Untitled"))).isEmpty)
        #expect(try s.b.apply(.setTrackMuted(.init(trackId: .id(s.v), muted: false))).isEmpty)
        let c = try s.video(at: 0, length: 24)
        #expect(try s.b.apply(.moveClip(.init(clipId: .id(c), to: .init(start: .zero)))).isEmpty)
        #expect(try s.b.apply(.trimClip(.init(clipId: .id(c), edge: .tail, to: frames(24)))).isEmpty)
    }

    // MARK: addClip

    @Test func addClipAutoLinksToMatchingAudioTrack() throws {
        let s = try Scene()
        let c = try s.linked(at: 10, length: 48, sourceIn: 5)
        let clip = try #require(s.b.clip(c))
        let partner = try #require(s.partner(of: c))
        #expect(clip.trackId == s.v)
        #expect(partner.trackId == s.a)
        #expect(partner.start == clip.start)
        #expect(partner.sourceIn == clip.sourceIn && partner.sourceOut == clip.sourceOut)
        #expect(clip.linkGroupId != nil && clip.linkGroupId == partner.linkGroupId)
        // link: none adds only one clip
        let solo = try s.video(at: 100, length: 10)
        #expect(s.b.clip(solo)?.linkGroupId == nil)
        #expect(s.b.audioTracks[0].clips.count == 1)
    }

    @Test func addClipSnapsToFramesOnVideoAndKeepsSamplesOnAudio() throws {
        let s = try Scene()
        let c = try s.b.addClip(
            track: s.v, asset: s.asset, at: RationalTime(1000, 48000), sourceIn: RationalTime(3, 48000),
            sourceOut: RationalTime(48048 + 500, 48000))
        let clip = try #require(s.b.clip(c))
        #expect(clip.start == .zero)
        #expect(clip.sourceIn == .zero)
        #expect(clip.sourceOut == frames(24))
        let audio = try s.b.importAsset(name: "a.wav", duration: RationalTime(480_000, 48000), hasVideo: false)
        let ac = try s.b.addClip(
            track: s.a, asset: audio, at: RationalTime(1001, 48000), sourceIn: RationalTime(7, 48000),
            sourceOut: RationalTime(9007, 48000))
        let aclip = try #require(s.b.clip(ac))
        #expect(aclip.start == RationalTime(1001, 48000))
        #expect(aclip.sourceIn == RationalTime(7, 48000))
        #expect(s.b.sequence.duration(of: aclip) == RationalTime(9000, 48000))
    }

    @Test func addClipRejectsBadSourceRangeAndWrongTrackKind() throws {
        let s = try Scene(assetFrames: 100)
        #expect(
            s.b.rejection(
                .addClip(
                    .init(
                        sequenceId: .id(s.b.sequenceId), trackId: .id(s.v), assetId: .id(s.asset), at: .zero,
                        sourceIn: frames(10), sourceOut: frames(101)))) != nil)
        #expect(
            s.b.rejection(
                .addClip(
                    .init(
                        sequenceId: .id(s.b.sequenceId), trackId: .id(s.v), assetId: .id(s.asset), at: .zero,
                        sourceIn: frames(10), sourceOut: frames(10)))) != nil)
        let audioOnly = try s.b.importAsset(name: "a.wav", duration: RationalTime(48000, 48000), hasVideo: false)
        #expect(
            s.b.rejection(
                .addClip(
                    .init(
                        sequenceId: .id(s.b.sequenceId), trackId: .id(s.v), assetId: .id(audioOnly), at: .zero,
                        sourceIn: .zero, sourceOut: frames(10)))) != nil)
        #expect(
            s.b.rejection(
                .addClip(
                    .init(
                        sequenceId: .id(s.b.sequenceId), trackId: .id(s.v), assetId: .id("nope"), at: .zero,
                        sourceIn: .zero, sourceOut: frames(10)))) == .notFound(id: "nope"))
    }

    @Test func addClipOverwriteTrimsNeighbours() throws {
        let s = try Scene()
        let left = try s.video(at: 0, length: 48)
        let right = try s.video(at: 48, length: 48, sourceIn: 100)
        let middle = try s.b.addClip(
            track: s.v, asset: s.asset, at: frames(24), sourceIn: frames(300), sourceOut: frames(348), mode: .overwrite)
        #expect(s.b.end(left) == frames(24))
        #expect(s.b.clip(left)?.sourceOut == frames(24))
        #expect(s.b.start(right) == frames(72))
        #expect(s.b.clip(right)?.sourceIn == frames(124))
        #expect(s.b.start(middle) == frames(24))
        // Fully covered neighbour is removed; a spanning neighbour is split.
        let small = try s.video(at: 200, length: 10, sourceIn: 400)
        try s.b.addClip(
            track: s.v, asset: s.asset, at: frames(190), sourceIn: .zero, sourceOut: frames(30), mode: .overwrite)
        #expect(s.b.clip(small) == nil)
        let big = try s.video(at: 300, length: 100, sourceIn: 0)
        try s.b.addClip(
            track: s.v, asset: s.asset, at: frames(340), sourceIn: .zero, sourceOut: frames(10), mode: .overwrite)
        let clipsAfter300 = s.b.videoTracks[0].clips.values.filter { $0.start >= frames(300) }.sorted {
            $0.start < $1.start
        }
        #expect(clipsAfter300.count == 3)
        #expect(s.b.end(big) == frames(340))
        #expect(clipsAfter300[2].start == frames(350) && clipsAfter300[2].sourceIn == frames(50))
    }

    @Test func addClipRippleInsertsAcrossTracks() throws {
        let s = try Scene()
        let v1 = try s.video(at: 0, length: 48)
        let v2 = try s.video(at: 48, length: 48, sourceIn: 100)
        let audio = try s.b.importAsset(name: "a.wav", duration: RationalTime(480_000, 48000), hasVideo: false)
        let a1 = try s.b.addClip(
            track: s.a, asset: audio, at: frames(60), sourceIn: .zero, sourceOut: RationalTime(48000, 48000))
        try s.b.apply(.addMarker(.init(sequenceId: .id(s.b.sequenceId), at: frames(48), label: "m")))
        try s.b.addClip(
            track: s.v, asset: s.asset, at: frames(48), sourceIn: .zero, sourceOut: frames(24), mode: .ripple)
        #expect(s.b.end(v1) == frames(48))
        #expect(s.b.start(v2) == frames(72))
        #expect(s.b.start(a1) == frames(84))
        #expect(s.b.sequence.markers.values.first?.at == frames(72))
        // Inserting into the middle of a clip splits it.
        try s.b.addClip(
            track: s.v, asset: s.asset, at: frames(24), sourceIn: .zero, sourceOut: frames(24), mode: .ripple)
        let clips = s.b.videoTracks[0].clips.values.sorted { $0.start < $1.start }
        #expect(clips.count == 5)
        #expect(clips[0].id == v1 && s.b.end(v1) == frames(24))
        #expect(clips[2].sourceIn == frames(24) && clips[2].start == frames(48))
    }

    /// The insert falls between two frames, so each track cuts where it is allowed to: the video track
    /// floors to the frame, the audio track cuts where asked. The tail the video cut therefore begins a
    /// fraction of a frame *before* the insert point, and shifting only what starts at or after that point
    /// left it behind — the video was cut for nothing and everything after it lost sync with the audio,
    /// which did move. Both tails travel with the insert.
    @Test func aRippleInsertShiftsEveryTailItSplitEvenOneCutBeforeThePoint() throws {
        let s = try Scene()
        let video = try s.linked(at: 0, length: 96)
        let audio = try #require(s.partner(of: video)).id
        let later = try s.video(at: 120, length: 24)
        let delta = frames(24)

        // Between frames 48 and 49, which is what dropping on an audio track gives you.
        let at = frames(48) + RationalTime(1, 48000)
        try s.b.addClip(track: s.a, asset: s.asset, at: at, sourceIn: .zero, sourceOut: delta, mode: .ripple)

        // Each half of the pair was cut where its own track allows.
        #expect(s.b.end(video) == frames(48))
        #expect(s.b.end(audio) == at)
        let videoTail = try #require(
            s.b.videoTracks[0].clips.values.first { $0.start > frames(48) && $0.id != later })
        let audioTail = try #require(s.b.audioTracks[0].clips.values.first { $0.start > at })
        // ...and both tails moved by the inserted duration, so the pair still lines up and nothing that
        // followed it slipped.
        #expect(videoTail.start == frames(48) + delta)
        #expect(audioTail.start == at + delta)
        #expect(s.b.start(later) == frames(120) + delta)
        #expect(s.b.clip(videoTail.id)?.linkGroupId == s.b.clip(audioTail.id)?.linkGroupId)
    }

    // MARK: trim

    @Test func rippleTailTrimShiftsEveryUnlockedTrackAndMarkers() throws {
        let s = try Scene(videoTracks: 2)
        let v2 = s.b.videoTracks[1].id
        let first = try s.linked(at: 0, length: 48)
        let second = try s.linked(at: 48, length: 48, sourceIn: 100)
        let other = try s.video(at: 40, length: 20, sourceIn: 200, track: v2)
        let early = try s.video(at: 0, length: 10, sourceIn: 300, track: v2)
        try s.b.apply(.addMarker(.init(sequenceId: .id(s.b.sequenceId), at: frames(70), label: "m")))
        try s.b.apply(.trimClip(.init(clipId: .id(first), edge: .tail, to: frames(36), mode: .ripple)))
        #expect(s.b.end(first) == frames(36))
        #expect(s.b.clip(first)?.sourceOut == frames(36))
        #expect(s.partner(of: first)?.sourceOut == frames(36))
        #expect(s.b.start(second) == frames(36))
        #expect(s.partner(of: second)?.start == frames(36))
        #expect(s.b.start(early) == .zero, "clips before the edit point stay")
        #expect(s.b.start(other) == frames(40), "clips starting before the edit point stay")
        #expect(s.b.sequence.markers.values.first?.at == frames(58))
        // rippleScope track leaves other tracks alone.
        try s.b.apply(
            .trimClip(.init(clipId: .id(second), edge: .tail, to: frames(72), mode: .ripple, rippleScope: .track)))
        #expect(s.b.start(other) == frames(40))
        #expect(s.b.sequence.markers.values.first?.at == frames(58), "track-scoped ripple leaves markers alone")
    }

    @Test func rippleHeadTrimKeepsStartAndSlidesContent() throws {
        let s = try Scene()
        let first = try s.video(at: 0, length: 48, sourceIn: 10)
        let second = try s.video(at: 48, length: 48, sourceIn: 100)
        try s.b.apply(.trimClip(.init(clipId: .id(first), edge: .head, to: frames(12), mode: .ripple)))
        #expect(s.b.start(first) == .zero)
        #expect(s.b.clip(first)?.sourceIn == frames(22))
        #expect(s.b.end(first) == frames(36))
        #expect(s.b.start(second) == frames(36))
        // Extending the head backwards in ripple mode pushes later material right.
        try s.b.apply(.trimClip(.init(clipId: .id(first), edge: .head, to: frames(-12), mode: .ripple)))
        #expect(s.b.start(first) == .zero)
        #expect(s.b.clip(first)?.sourceIn == frames(10))
        #expect(s.b.start(second) == frames(48))
        // Cannot extend past the media.
        #expect(s.b.rejection(.trimClip(.init(clipId: .id(first), edge: .head, to: frames(-11)))) != nil)
        #expect(s.b.rejection(.trimClip(.init(clipId: .id(first), edge: .tail, to: frames(0)))) != nil)
    }

    @Test func overwriteTrimMovesEdgeAndTrimsNeighbour() throws {
        let s = try Scene()
        let first = try s.video(at: 0, length: 48, sourceIn: 10)
        let second = try s.video(at: 48, length: 48, sourceIn: 100)
        try s.b.apply(.trimClip(.init(clipId: .id(first), edge: .tail, to: frames(60), mode: .overwrite)))
        #expect(s.b.end(first) == frames(60))
        #expect(s.b.start(second) == frames(60))
        #expect(s.b.clip(second)?.sourceIn == frames(112))
        try s.b.apply(.trimClip(.init(clipId: .id(second), edge: .head, to: frames(72), mode: .overwrite)))
        #expect(s.b.start(second) == frames(72))
        #expect(s.b.end(first) == frames(60), "overwrite leaves a gap")
        try s.b.apply(.trimClip(.init(clipId: .id(second), edge: .head, to: frames(50), mode: .overwrite)))
        #expect(s.b.end(first) == frames(50))
    }

    @Test func unlinkedTrimLeavesPartnerAlone() throws {
        let s = try Scene()
        let c = try s.linked(at: 0, length: 48)
        try s.b.apply(.trimClip(.init(clipId: .id(c), edge: .tail, to: frames(24), mode: .ripple, unlinked: true)))
        #expect(s.b.end(c) == frames(24))
        #expect(s.partner(of: c)?.sourceOut == frames(48))
    }

    // MARK: move

    @Test func moveClipMovesGroupAndDropsTransitions() throws {
        let s = try Scene()
        let first = try s.linked(at: 0, length: 48, sourceIn: 24)
        let second = try s.linked(at: 48, length: 48, sourceIn: 200)
        try s.b.apply(
            .addTransition(
                .init(leftClipId: .id(first), rightClipId: .id(second), kind: "dissolve", duration: frames(8))))
        #expect(s.b.sequence.transitions.count == 1)
        let events = try s.b.apply(.moveClip(.init(clipId: .id(second), to: .init(start: frames(200)))))
        #expect(events.map(\.type) == ["TransitionRemoved", "ClipMoved", "ClipMoved"])
        #expect(s.b.sequence.transitions.isEmpty)
        #expect(s.b.start(second) == frames(200))
        #expect(s.partner(of: second)?.start == frames(200))
        // Move to another track of the same kind only.
        let v2 = try s.b.addTracks(.video, count: 1)[0]
        try s.b.apply(.moveClip(.init(clipId: .id(second), to: .init(trackId: .id(v2), start: frames(0)))))
        #expect(s.b.clip(second)?.trackId == v2)
        #expect(s.partner(of: second)?.trackId == s.a)
        #expect(s.b.rejection(.moveClip(.init(clipId: .id(second), to: .init(trackId: .id(s.a), start: .zero)))) != nil)
        #expect(s.b.rejection(.moveClip(.init(clipId: .id(second), to: .init(start: frames(-1))))) != nil)
    }

    @Test func moveClipRippleInsertsAtDestination() throws {
        let s = try Scene()
        let a = try s.video(at: 0, length: 24)
        let b = try s.video(at: 24, length: 24, sourceIn: 100)
        let c = try s.video(at: 48, length: 24, sourceIn: 200)
        try s.b.apply(.moveClip(.init(clipId: .id(c), to: .init(start: .zero), mode: .ripple)))
        #expect(s.b.start(c) == .zero)
        #expect(s.b.start(a) == frames(24))
        #expect(s.b.start(b) == frames(48))
        try Invariants.check(s.b.project)
    }

    // MARK: split and join

    @Test func splitAndJoinRoundTrip() throws {
        let s = try Scene()
        let c = try s.linked(at: 0, length: 48, sourceIn: 10)
        let next = try s.linked(at: 48, length: 48, sourceIn: 100)
        try s.b.apply(
            .addTransition(.init(leftClipId: .id(c), rightClipId: .id(next), kind: "dissolve", duration: frames(8))))
        let newIds: [ClipID] = ["new-video", "new-audio"]
        let events = try s.b.apply(.splitClip(.init(clipId: .id(c), at: frames(20), newIds: newIds)))
        #expect(events.filter { $0.type == "ClipSplit" }.count == 2)
        let left = try #require(s.b.clip(c))
        let right = try #require(s.b.clip("new-video"))
        #expect(left.sourceOut == frames(30) && right.sourceIn == frames(30) && right.sourceOut == frames(58))
        #expect(right.start == frames(20))
        #expect(s.b.clip("new-audio")?.start == frames(20))
        #expect(right.linkGroupId == s.b.clip("new-audio")?.linkGroupId)
        #expect(right.linkGroupId != left.linkGroupId)
        #expect(
            s.b.sequence.transitions.values.first?.leftClipId == "new-video", "a tail transition follows the right part"
        )
        try Invariants.check(s.b.project)
        #expect(s.b.rejection(.splitClip(.init(clipId: .id(c), at: frames(0)))) != nil)
        #expect(s.b.rejection(.splitClip(.init(clipId: .id(c), at: frames(20)))) != nil)

        try s.b.apply(.joinClips(.init(leftClipId: .id(c), rightClipId: "new-video")))
        #expect(s.b.clip("new-video") == nil)
        #expect(s.b.clip(c)?.sourceOut == frames(58))
        #expect(s.b.end(c) == frames(48))
        #expect(s.b.sequence.transitions.values.first?.leftClipId == c)
        #expect(
            s.b.rejection(.joinClips(.init(leftClipId: .id(c), rightClipId: .id(next)))) != nil, "source not contiguous"
        )
    }

    // MARK: remove

    @Test func removeClipRippleClosesGapAndRemovesTransition() throws {
        let s = try Scene()
        let a = try s.linked(at: 0, length: 24, sourceIn: 24)
        let b = try s.linked(at: 24, length: 24, sourceIn: 100)
        let c = try s.linked(at: 48, length: 24, sourceIn: 200)
        try s.b.apply(
            .addTransition(.init(leftClipId: .id(a), rightClipId: .id(b), kind: "dissolve", duration: frames(4))))
        let events = try s.b.apply(.removeClip(.init(clipId: .id(b), mode: .ripple)))
        #expect(events.map(\.type) == ["TransitionRemoved", "ClipRemoved", "ClipRemoved", "ClipMoved", "ClipMoved"])
        #expect(s.b.clip(b) == nil)
        #expect(s.b.start(c) == frames(24))
        #expect(s.partner(of: c)?.start == frames(24))
        #expect(s.b.start(a) == .zero)
        try s.b.apply(.removeClip(.init(clipId: .id(c), mode: .overwrite, unlinked: true)))
        #expect(s.b.clip(c) == nil)
        #expect(s.partner(of: a) != nil)
        #expect(s.b.audioTracks[0].clips.count == 2, "unlinked remove leaves the partner")
    }

    // MARK: speed

    @Test func setClipSpeedRipplesDurationChange() throws {
        let s = try Scene()
        let a = try s.linked(at: 0, length: 48)
        let b = try s.video(at: 48, length: 24, sourceIn: 100)
        try s.b.apply(.setClipSpeed(.init(clipId: .id(a), after: Rational(2, 1))))
        #expect(s.b.end(a) == frames(24))
        #expect(s.partner(of: a)?.speed == Rational(2, 1))
        #expect(s.b.start(b) == frames(24))
        try s.b.apply(.setClipSpeed(.init(clipId: .id(a), after: Rational(1, 2), mode: .overwrite)))
        #expect(s.b.end(a) == frames(96))
        #expect(s.b.clip(b) == nil, "overwrite eats the neighbour")
        #expect(s.b.rejection(.setClipSpeed(.init(clipId: .id(a), after: Rational(0, 1)))) != nil)
        try Invariants.check(s.b.project)
    }

    // MARK: transitions

    @Test func transitionHandlesReportMaxDuration() throws {
        let s = try Scene(assetFrames: 200)
        let left = try s.video(at: 0, length: 48, sourceIn: 0)  // left handle: 200 - 48 = 152 frames
        let right = try s.video(at: 48, length: 48, sourceIn: 6)  // right handle 6 frames
        #expect(
            s.b.rejection(
                .addTransition(
                    .init(leftClipId: .id(left), rightClipId: .id(right), kind: "dissolve", duration: frames(24))))
                == .transitionHandles(maxDuration: frames(12)))
        #expect(
            s.b.rejection(
                .addTransition(
                    .init(
                        leftClipId: .id(left), rightClipId: .id(right), kind: "dissolve", duration: frames(24),
                        alignment: .startOnCut)))
                == .transitionHandles(maxDuration: frames(6)))
        try s.b.apply(
            .addTransition(
                .init(
                    leftClipId: .id(left), rightClipId: .id(right), kind: "dissolve", duration: frames(24),
                    alignment: .endOnCut)))
        let t = try #require(s.b.sequence.transitions.values.first)
        #expect(t.duration == frames(24) && t.trackId == s.v)
        #expect(
            s.b.rejection(.updateTransition(.init(transitionId: .id(t.id), alignment: .centered)))
                == .transitionHandles(maxDuration: frames(12)))
        try s.b.apply(.updateTransition(.init(transitionId: .id(t.id), duration: frames(12), alignment: .centered)))
        #expect(s.b.sequence.transitions[t.id]?.alignment == .centered)
        // Not adjacent -> invalid; duplicate cut -> invalid.
        let far = try s.video(at: 150, length: 10, sourceIn: 100)
        #expect(
            s.b.rejection(
                .addTransition(
                    .init(leftClipId: .id(right), rightClipId: .id(far), kind: "dissolve", duration: frames(2)))) != nil
        )
        #expect(
            s.b.rejection(
                .addTransition(.init(leftClipId: .id(left), rightClipId: .id(right), kind: "wipe", duration: frames(2)))
            ) != nil)
        // Trimming the right clip's head away from the handle drops the transition in the same transaction.
        let events = try s.b.apply(.trimClip(.init(clipId: .id(right), edge: .head, to: frames(50), mode: .overwrite)))
        #expect(events.map(\.type) == ["ClipTrimmed", "TransitionRemoved"])
        #expect(s.b.rejection(.removeTransition(.init(transitionId: .id(t.id)))) == .notFound(id: t.id.rawValue))
        #expect(
            s.b.rejection(
                .addTransition(
                    .init(leftClipId: .id(left), rightClipId: .id(right), kind: "dissolve", duration: frames(2))))
                != nil)
        try s.b.apply(.trimClip(.init(clipId: .id(right), edge: .head, to: frames(48), mode: .overwrite)))
        try s.b.apply(
            .addTransition(
                .init(id: "t2", leftClipId: .id(left), rightClipId: .id(right), kind: "dissolve", duration: frames(2))))
        #expect(try s.b.apply(.removeTransition(.init(transitionId: "t2"))).map(\.type) == ["TransitionRemoved"])
    }

    // MARK: locked tracks

    @Test func lockedTrackRejectsEditsAndIsSkippedByRipple() throws {
        let s = try Scene(videoTracks: 2)
        let v2 = s.b.videoTracks[1].id
        let a = try s.video(at: 0, length: 48)
        let b = try s.video(at: 48, length: 48, sourceIn: 100)
        let onV2 = try s.video(at: 60, length: 10, sourceIn: 200, track: v2)
        let pair = try s.linked(at: 200, length: 10, sourceIn: 300)
        try s.b.apply(.setTrackLocked(.init(trackId: .id(v2), locked: true)))
        #expect(s.b.rejection(.trimClip(.init(clipId: .id(onV2), edge: .tail, to: frames(65)))) == .trackLocked(v2))
        #expect(s.b.rejection(.moveClip(.init(clipId: .id(onV2), to: .init(start: .zero)))) == .trackLocked(v2))
        #expect(s.b.rejection(.removeClip(.init(clipId: .id(onV2)))) == .trackLocked(v2))
        #expect(
            s.b.rejection(.moveClip(.init(clipId: .id(a), to: .init(trackId: .id(v2), start: .zero))))
                == .trackLocked(v2))
        #expect(
            s.b.rejection(
                .addClip(
                    .init(
                        sequenceId: .id(s.b.sequenceId), trackId: .id(v2), assetId: .id(s.asset), at: .zero,
                        sourceIn: .zero, sourceOut: frames(1)))) == .trackLocked(v2))
        try s.b.apply(.trimClip(.init(clipId: .id(a), edge: .tail, to: frames(24), mode: .ripple)))
        #expect(s.b.start(b) == frames(24))
        #expect(s.b.start(onV2) == frames(60), "ripple skips locked tracks")
        #expect(s.b.start(pair) == frames(176))
        // A locked partner track blocks group edits.
        try s.b.apply(.setTrackLocked(.init(trackId: .id(s.a), locked: true)))
        #expect(s.b.rejection(.removeClip(.init(clipId: .id(pair)))) == .trackLocked(s.a))
        try s.b.apply(.removeClip(.init(clipId: .id(pair), unlinked: true)))
        #expect(s.b.rejection(.removeTrack(.init(trackId: .id(s.a)))) == .trackLocked(s.a))
    }

    // MARK: batch

    @Test func batchResolvesRefs() throws {
        let s = try Scene()
        let c = try s.video(at: 0, length: 48, sourceIn: 24)
        let events = try s.b.apply(
            .batch([
                .splitClip(.init(clipId: .id(c), at: frames(24))),
                .addTransition(.init(leftClipId: .id(c), rightClipId: .ref(0), kind: "dissolve", duration: frames(8))),
                .addMarker(.init(sequenceId: .id(s.b.sequenceId), at: frames(24), label: "cut")),
                .moveMarker(.init(markerId: .ref(2), to: frames(30))),
            ]))
        #expect(events.map(\.type) == ["ClipSplit", "TransitionAdded", "MarkerAdded", "MarkerMoved"])
        #expect(Set(events.map(\.txnId)).count == 1)
        let t = try #require(s.b.sequence.transitions.values.first)
        #expect(t.leftClipId == c)
        #expect(s.b.clip(t.rightClipId)?.start == frames(24))
        #expect(s.b.sequence.markers.values.first?.at == frames(30))
        #expect(s.b.history.transactions.count == 6)
        // A bad ref or nested batch is rejected as a whole.
        #expect(s.b.rejection(.batch([.removeMarker(.init(markerId: .ref(5)))])) != nil)
        #expect(s.b.rejection(.batch([.batch([])])) != nil)
        #expect(s.b.rejection(.batch([.undo(.init())])) != nil)
        #expect(s.b.rejection(.removeMarker(.init(markerId: .ref(0)))) != nil)
        // Client-supplied ids are honoured and reusable by ref.
        try s.b.apply(
            .batch([
                .addTrack(.init(id: "v-extra", sequenceId: .id(s.b.sequenceId), kind: .video)),
                .addClip(
                    .init(
                        id: "clip-x", sequenceId: .id(s.b.sequenceId), trackId: .ref(0), assetId: .id(s.asset),
                        at: .zero, sourceIn: .zero, sourceOut: frames(10), link: .none)),
                .setClipOpacity(.init(clipId: .ref(1), after: .constant(0.5))),
            ]))
        #expect(s.b.clip("clip-x")?.trackId == "v-extra")
        #expect(s.b.clip("clip-x")?.opacity == .constant(0.5))
    }

    // MARK: tracks, captions, markers, assets

    @Test func trackOperations() throws {
        let s = try Scene()
        let t = try s.b.addTracks(.video, count: 1)[0]
        #expect(s.b.sequence.tracks.map(\.name) == ["V1", "A1", "V2"])
        try s.b.apply(.reorderTrack(.init(trackId: .id(t), position: 0)))
        #expect(s.b.sequence.tracks.first?.id == t)
        try s.b.apply(.renameTrack(.init(trackId: .id(t), name: "Overlay")))
        try s.b.apply(.setTrackMuted(.init(trackId: .id(t), muted: true)))
        #expect(s.b.sequence.tracks.first?.name == "Overlay" && s.b.sequence.tracks.first?.muted == true)
        let c = try s.video(at: 0, length: 10, track: t)
        let d = try s.video(at: 10, length: 10, sourceIn: 50, track: t)
        try s.b.apply(
            .addTransition(.init(leftClipId: .id(c), rightClipId: .id(d), kind: "dissolve", duration: frames(2))))
        let events = try s.b.apply(.removeTrack(.init(trackId: .id(t))))
        #expect(events.map(\.type) == ["TransitionRemoved", "TrackRemoved"])
        #expect(s.b.sequence.tracks.count == 2)
        #expect(s.b.rejection(.reorderTrack(.init(trackId: .id(s.v), position: 5))) != nil)
    }

    @Test func soloingATrackEmitsOneEventAndSettingItAgainEmitsNothing() throws {
        let s = try Scene(audioTracks: 2)
        let a2 = s.b.audioTracks[1].id
        let events = try s.b.apply(.setTrackSolo(.init(trackId: .id(a2), solo: true)))
        #expect(events.map(\.type) == ["TrackSoloSet"])
        #expect(s.b.sequence.track(a2)?.solo == true)
        #expect(try s.b.apply(.setTrackSolo(.init(trackId: .id(a2), solo: true))).isEmpty)
    }

    @Test func aSoloedTrackSilencesItsPeersAndUndoBringsThemBack() throws {
        let s = try Scene(audioTracks: 2)
        let a2 = s.b.audioTracks[1].id
        try s.b.apply(.setTrackSolo(.init(trackId: .id(a2), solo: true)))
        let seq = s.b.sequence
        #expect(seq.silence(of: seq.track(s.a)!) == .solo)
        #expect(seq.isActive(seq.track(a2)!))
        // Video is a different kind, so the picture is untouched.
        #expect(seq.isActive(seq.track(s.v)!))
        try s.b.apply(.undo(.init()))
        #expect(s.b.sequence.tracks.allSatisfy { s.b.sequence.isActive($0) })
    }

    @Test func aLockedTrackCannotBeRemoved() throws {
        let s = try Scene()
        try s.b.apply(.setTrackLocked(.init(trackId: .id(s.a), locked: true)))
        #expect(s.b.rejection(.removeTrack(.init(trackId: .id(s.a)))) == .trackLocked(s.a))
        try s.b.apply(.setTrackLocked(.init(trackId: .id(s.a), locked: false)))
        #expect(s.b.rejection(.removeTrack(.init(trackId: .id(s.a)))) == nil)
    }

    @Test func removingATrackTakesItsClipsAndUndoRestoresThemAtTheSamePosition() throws {
        let s = try Scene()
        let t = try s.b.addTracks(.audio, count: 1)[0]
        try s.b.apply(.setTrackMuted(.init(trackId: .id(t), muted: true)))
        let asset = try s.b.importAsset(name: "vo.wav", duration: frames(600), hasVideo: false)
        let c = try s.b.addClip(track: t, asset: asset, at: .zero, sourceIn: .zero, sourceOut: frames(24))
        let before = s.b.sequence
        try s.b.apply(.removeTrack(.init(trackId: .id(t))))
        #expect(s.b.sequence.track(t) == nil && s.b.clip(c) == nil)
        try s.b.apply(.undo(.init()))
        #expect(s.b.sequence == before)
        #expect(s.b.sequence.track(t)?.muted == true && s.b.clip(c) != nil)
    }

    @Test func captionsAndMarkers() throws {
        let s = try Scene()
        try s.b.apply(
            .addCaptionTrack(
                .init(id: "cap", sequenceId: .id(s.b.sequenceId), language: "en", style: CaptionStyle(fontSize: 40))))
        #expect(s.b.captionTracks[0].language == "en")
        try s.b.apply(
            .replaceCaptions(
                .init(
                    trackId: "cap",
                    items: [
                        .init(
                            id: "c1", start: frames(0), duration: frames(24), text: "Hi",
                            words: [CaptionWord(text: "Hi", t0: .zero, t1: frames(10))]),
                        .init(
                            id: "c2", start: RationalTime(24 * 1001 + 100, 24000), duration: frames(24), text: "there"),
                    ])))
        #expect(s.b.clip("c2")?.start == frames(24))
        #expect(s.b.clip("c1")?.caption?.text == "Hi")
        #expect(
            s.b.rejection(
                .replaceCaptions(
                    .init(
                        trackId: "cap",
                        items: [
                            .init(start: .zero, duration: frames(10), text: "a"),
                            .init(start: frames(5), duration: frames(10), text: "b"),
                        ]))) != nil)
        #expect(s.b.rejection(.replaceCaptions(.init(trackId: .id(s.v), items: []))) != nil)
        try s.b.apply(.editCaption(.init(clipId: "c1", text: "Hello")))
        #expect(s.b.clip("c1")?.text == "Hello" && s.b.clip("c1")?.words?.count == 1)
        try s.b.apply(.setCaptionStyle(.init(clipId: "c1", style: CaptionStyle(color: "#ff0"))))
        try s.b.apply(.setCaptionStyle(.init(trackId: "cap", style: nil)))
        #expect(s.b.clip("c1")?.style?.color == "#ff0")
        #expect(s.b.captionTracks[0].captionStyle == nil)
        #expect(s.b.rejection(.setCaptionStyle(.init(style: nil))) != nil)
        let plain = try s.video(at: 0, length: 5)
        #expect(s.b.rejection(.editCaption(.init(clipId: .id(plain), text: "x"))) != nil)
        // Captions ripple like other clips and are frame aligned.
        let v = try s.video(at: 100, length: 24)
        try s.b.apply(.trimClip(.init(clipId: .id(v), edge: .head, to: frames(110), mode: .ripple)))
        #expect(s.b.clip("c1")?.start == .zero)
        try s.b.apply(
            .addMarker(.init(id: "m", sequenceId: .id(s.b.sequenceId), at: RationalTime(1, 48000), label: "x")))
        #expect(s.b.sequence.markers["m"]?.at == .zero)
        try s.b.apply(.moveMarker(.init(markerId: "m", to: frames(3))))
        try s.b.apply(.removeMarker(.init(markerId: "m")))
        #expect(s.b.sequence.markers.isEmpty)
        #expect(s.b.rejection(.moveMarker(.init(markerId: "m", to: .zero))) == .notFound(id: "m"))
    }

    @Test func assetOperations() throws {
        let s = try Scene()
        #expect(
            s.b.rejection(
                .importAsset(
                    .init(
                        contentHash: s.b.project.assets[s.asset]!.contentHash, libraryPath: "x", displayName: "dup",
                        kind: .video, duration: frames(1), hasVideo: true, hasAudio: false))) != nil)
        let c = try s.video(at: 0, length: 10)
        #expect(s.b.rejection(.removeAsset(.init(assetId: .id(s.asset)))) != nil)
        try s.b.apply(.relinkAsset(.init(assetId: .id(s.asset), libraryPath: "moved/cam.mov", offline: true)))
        #expect(s.b.project.assets[s.asset]?.offline == true)
        try s.b.apply(
            .recordAssetAnalysis(
                .init(assetId: .id(s.asset), kind: "transcript", cacheKey: "abc", summary: ["words": 12])))
        #expect(s.b.project.assets[s.asset]?.analyses["transcript"]?.cacheKey == "abc")
        try s.b.apply(.removeClip(.init(clipId: .id(c))))
        let snapshot = s.b.project.assets[s.asset]!
        try s.b.apply(.removeAsset(.init(assetId: .id(s.asset))))
        #expect(s.b.project.assets.isEmpty)
        try s.b.apply(.restoreAsset(.init(asset: snapshot)))
        #expect(s.b.project.assets[s.asset] == snapshot)
        try s.b.apply(.setProjectSettings(.init(after: ProjectSettings(sampleRate: 44100))))
        #expect(s.b.project.settings.sampleRate == 44100)
        #expect(
            s.b.rejection(
                .setSequenceSettings(
                    .init(
                        sequenceId: .id(s.b.sequenceId),
                        after: .init(name: "S", frameDuration: RationalTime(1, 30), width: 1, height: 1)))) == nil)
        try s.video(at: 0, length: 10)
        #expect(
            s.b.rejection(
                .setSequenceSettings(
                    .init(
                        sequenceId: .id(s.b.sequenceId),
                        after: .init(name: "S", frameDuration: fd24, width: 1, height: 1)))) != nil)
    }

    @Test func effectsAndClipProperties() throws {
        let s = try Scene()
        let c = try s.video(at: 0, length: 10)
        try s.b.apply(.addEffect(.init(clipId: .id(c), effectId: "fx", kind: "blur", params: ["radius": .constant(4)])))
        try s.b.apply(.updateEffect(.init(clipId: .id(c), effectId: "fx", enabled: false)))
        #expect(
            s.b.clip(c)?.effects == [Effect(id: "fx", kind: "blur", enabled: false, params: ["radius": .constant(4)])])
        try s.b.apply(.setClipTransform(.init(clipId: .id(c), after: .constant(Transform(scale: 2)))))
        try s.b.apply(.setClipAudio(.init(clipId: .id(c), after: ClipAudio(gain: .constant(0.5), muted: true))))
        #expect(s.b.clip(c)?.transform.constantValue?.scale == 2)
        #expect(s.b.clip(c)?.audio.muted == true)
        try s.b.apply(.removeEffect(.init(clipId: .id(c), effectId: "fx")))
        #expect(s.b.clip(c)?.effects.isEmpty == true)
        #expect(s.b.rejection(.removeEffect(.init(clipId: .id(c), effectId: "fx"))) == .notFound(id: "fx"))
    }

    @Test func linkAndUnlink() throws {
        let s = try Scene()
        let a = try s.video(at: 0, length: 10)
        let audioAsset = try s.b.importAsset(name: "a.wav", duration: RationalTime(48000, 48000), hasVideo: false)
        let b = try s.b.addClip(
            track: s.a, asset: audioAsset, at: .zero, sourceIn: .zero, sourceOut: RationalTime(24000, 48000))
        try s.b.apply(.linkClips(.init(clipIds: [.id(a), .id(b)])))
        let g = try #require(s.b.clip(a)?.linkGroupId)
        #expect(s.b.clip(b)?.linkGroupId == g)
        try s.b.apply(.moveClip(.init(clipId: .id(a), to: .init(start: frames(10)))))
        #expect(s.b.start(b) == frames(10))
        let other = try s.linked(at: 100, length: 10)
        #expect(s.b.rejection(.linkClips(.init(clipIds: [.id(a), .id(other)]))) != nil)
        try s.b.apply(.unlinkClips(.init(clipIds: [.id(a)])))
        #expect(s.b.clip(a)?.linkGroupId == nil && s.b.clip(b)?.linkGroupId == g)
        #expect(try s.b.apply(.linkClips(.init(clipIds: [.id(a), .id(b)]))).count == 1)
        #expect(s.b.clip(a)?.linkGroupId == g)
    }

    @Test func labelsForOperations() {
        #expect(label(for: .trimClip(.init(clipId: "c", edge: .head, to: .zero))) == "Trim clip")
        #expect(label(for: .setTrackLocked(.init(trackId: "t", locked: true))) == "Lock track")
        #expect(label(for: .setTrackSolo(.init(trackId: "t", solo: true))) == "Solo track")
        #expect(label(for: .setTrackSolo(.init(trackId: "t", solo: false))) == "Unsolo track")
        #expect(label(for: .batch([.redo, .undo(.init())])) == "2 edits")
        #expect(Command(commandId: "k", actor: .human, label: "Custom", operation: .redo).effectiveLabel == "Custom")
    }
}
