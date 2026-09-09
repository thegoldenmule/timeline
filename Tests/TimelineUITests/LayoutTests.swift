import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import Testing
import TimelineCore

@testable import TimelineUI

@MainActor
@Suite("Layout, zoom, and scroll")
struct LayoutTests {
    @Test func timeAndPointsRoundTripAtEveryZoom() async throws {
        let f = try await UIFixture.make("three-clips")
        #expect(ZoomLevel.count >= 5)
        for i in 0..<ZoomLevel.count {
            f.viewModel.setZoom(index: i)
            let l = f.viewModel.layout
            #expect(l.secondsPerPoint == ZoomLevel.secondsPerPoint[i])
            let x = l.x(for: RationalTime(seconds: 7.5))
            #expect(abs(l.seconds(atX: x) - 7.5) < 1e-9)
            #expect(l.x(forSeconds: l.scrollSeconds) == l.headerWidth)
            #expect(CGFloat(l.majorTickSeconds() / l.secondsPerPoint) >= 90)
        }
        #expect(TimelineLayout.tickIntervals == TimelineLayout.tickIntervals.sorted())
    }

    @Test func zoomKeepsTheAnchoredTimeUnderThePointer() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.scrollSeconds = 20
        let anchorX: CGFloat = 700
        let before = f.viewModel.layout.seconds(atX: anchorX)
        f.viewModel.zoomIn(anchorX: anchorX)
        #expect(abs(f.viewModel.layout.seconds(atX: anchorX) - before) < 1e-6)
        f.viewModel.zoomOut(anchorX: anchorX)
        #expect(abs(f.viewModel.layout.seconds(atX: anchorX) - before) < 1e-6)
        // Zoom clamps at both ends and scroll never goes negative.
        f.viewModel.setZoom(index: 99)
        #expect(f.viewModel.zoomIndex == ZoomLevel.count - 1)
        f.viewModel.setZoom(index: -5, anchorX: 1100)
        #expect(f.viewModel.zoomIndex == 0)
        #expect(f.viewModel.scrollSeconds >= 0)
    }

    @Test func rowsFollowTrackOrderAndKinds() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let l = f.viewModel.layout
        #expect(l.rows.map(\.kind) == [.video, .audio, .caption])
        #expect(l.rows.map(\.trackId) == f.sequence.tracks.map(\.id))
        #expect(l.rows[0].y == l.rulerHeight + l.trackGap)
        #expect(l.rows[1].y == l.rows[0].maxY + l.trackGap)
        #expect(l.row(atY: l.rows[1].y + 3)?.trackId == l.rows[1].trackId)
        #expect(l.row(atY: 5) == nil)
        #expect(l.isInRuler(CGPoint(x: 500, y: 5)))
        #expect(!l.isInRuler(CGPoint(x: 50, y: 5)))
        #expect(l.isInHeader(CGPoint(x: 50, y: 100)))
        #expect(l.contentBottom == l.rows.last!.maxY)
    }

    @Test func clipRectsMatchTheirTimes() async throws {
        let f = try await UIFixture.make("three-clips")
        let l = f.viewModel.layout
        let clips = f.clips(.video)
        let a = l.rect(for: clips[0], in: f.sequence)!
        let b = l.rect(for: clips[1], in: f.sequence)!
        #expect(a.minX == l.headerWidth)
        #expect(abs(a.maxX - b.minX) < 0.001)
        #expect(abs(a.width - l.width(for: f.sequence.duration(of: clips[0]))) < 0.001)
        #expect(a.height == TimelineLayout.trackHeights[.video]! - 2)
        f.viewModel.scrollSeconds = 100
        #expect(!f.viewModel.layout.isVisible(startSeconds: 0, endSeconds: 11))
        #expect(f.viewModel.layout.isVisible(startSeconds: 90, endSeconds: 101))
    }

    @Test func timecodeLabels() {
        let fd = RationalTime(1001, 24000)
        #expect(Timecode.label(seconds: 0, interval: 1, frameDuration: fd) == "0:00")
        #expect(Timecode.label(seconds: 65, interval: 5, frameDuration: fd) == "1:05")
        #expect(Timecode.label(seconds: 3600 + 61, interval: 60, frameDuration: fd) == "1:01:01")
        #expect(Timecode.label(seconds: 1.5, interval: 0.5, frameDuration: fd) == "0:01:11")
        #expect(Timecode.frames(RationalTime.frames(30, of: fd), frameDuration: fd) == "0:01:06")
    }

    @Test func revealPlayheadScrolls() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.setPlayhead(RationalTime(seconds: 500))
        f.viewModel.revealPlayhead()
        let l = f.viewModel.layout
        #expect(l.visibleStartSeconds <= 500 && 500 <= l.visibleEndSeconds)
        f.viewModel.setPlayhead(RationalTime(seconds: -3))
        #expect(f.viewModel.playhead == .zero)
    }

    @Test func editModesFollowTheModelDefaultsAndCommandFlipsThem() async throws {
        let f = try await UIFixture.make("three-clips")
        let vm = f.viewModel
        #expect(vm.editMode(for: .move, modifiers: []) == .overwrite)
        #expect(vm.editMode(for: .trim, modifiers: []) == .ripple)
        #expect(vm.editMode(for: .delete, modifiers: []) == .ripple)
        #expect(vm.editMode(for: .move, modifiers: [.command]) == .ripple)
        #expect(vm.editMode(for: .trim, modifiers: [.command]) == .overwrite)
        #expect(vm.editMode(for: .delete, modifiers: [.command, .option]) == .overwrite)
        vm.modifiers = [.command]
        #expect(vm.editMode(for: .move) == .ripple)
    }

    @Test func everyRowGivesFourControlsInMuteSoloLockRemoveOrder() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let l = f.viewModel.layout
        for row in l.rows {
            #expect(l.controls(in: row).map(\.control) == [.mute, .solo, .lock, .remove])
        }
        #expect(TrackControl.allCases.map(\.glyph) == ["M", "S", "L", "X"])
    }

    @Test func tallRowsPutTheStripBelowTheNameAndShortRowsPutItBeside() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let l = f.viewModel.layout
        let video = l.rows[0]
        let caption = l.rows[2]
        #expect(l.isStacked(video) && !l.isStacked(caption))

        // Stacked: the name spans the header and the strip sits under it, left-aligned.
        let videoStrip = l.controls(in: video)
        let videoName = l.nameRect(in: video)
        #expect(videoStrip[0].rect.minX == TimelineLayout.headerInset)
        #expect(videoStrip[0].rect.minY >= videoName.maxY)
        #expect(videoName.width > TimelineLayout.controlStripWidth)

        // Beside: the strip is right-aligned on the row's centre line and the name gives way to it.
        let capStrip = l.controls(in: caption)
        let capName = l.nameRect(in: caption)
        #expect(abs(capStrip[3].rect.maxX - (l.headerWidth - TimelineLayout.headerInset)) < 0.001)
        #expect(abs(capStrip[0].rect.midY - caption.midY) < 0.001)
        #expect(capName.maxX <= capStrip[0].rect.minX)
        #expect(capName.width > 0)
    }

    @Test func controlRectsStayInsideTheHeaderAndNeverOverlap() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let l = f.viewModel.layout
        for row in l.rows {
            let rects = l.controls(in: row).map(\.rect)
            for rect in rects {
                #expect(rect.minX >= 0 && rect.maxX <= l.headerWidth)
                #expect(rect.minY >= row.y && rect.maxY <= row.maxY)
                #expect(rect.width == TimelineLayout.controlSize && rect.height == TimelineLayout.controlSize)
            }
            for (a, b) in zip(rects, rects.dropFirst()) {
                #expect(b.minX == a.maxX + TimelineLayout.controlGap)
            }
        }
    }

    @Test func controlAtPointFindsExactlyTheButtonUnderIt() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let l = f.viewModel.layout
        let row = l.rows[1]
        for (control, rect) in l.controls(in: row) {
            #expect(l.control(atPoint: CGPoint(x: rect.midX, y: rect.midY), in: row) == control)
        }
        // The gaps between buttons, the name line, and the header edge are not buttons.
        let strip = l.controls(in: row)
        #expect(l.control(atPoint: CGPoint(x: strip[0].rect.maxX + 1, y: strip[0].rect.midY), in: row) == nil)
        #expect(l.control(atPoint: CGPoint(x: 12, y: l.nameRect(in: row).midY), in: row) == nil)
        #expect(l.control(atPoint: CGPoint(x: l.headerWidth - 1, y: row.midY), in: row) == nil)
    }

    /// A fixture with two audio tracks, so solo has a peer to silence.
    private func twoAudioTracks() async throws -> (UIFixture, TrackID, TrackID) {
        let f = try await UIFixture.make("three-clips")
        await f.viewModel.apply(.addTrack(.init(sequenceId: .id(f.sequence.id), kind: .audio)))
        let audio = f.sequence.tracks.filter { $0.kind == .audio }
        return (f, audio[0].id, audio[1].id)
    }

    /// The plate quads drawn for one track's buttons, keyed by control.
    private func plates(_ scene: TimelineScene, _ layout: TimelineLayout, _ track: TrackID)
        -> [TrackControl: [SceneQuad]]
    {
        guard let row = layout.row(for: track) else { return [:] }
        var out: [TrackControl: [SceneQuad]] = [:]
        for (control, rect) in layout.controls(in: row) {
            out[control] = scene.overlayQuads.filter { rect.contains($0.rect) }
        }
        return out
    }

    @Test func aMutedTrackGetsAFilledMuteBadgeAndADimmedLane() async throws {
        let (f, a1, _) = try await twoAudioTracks()
        await f.viewModel.setTrackMuted(a1, true)
        let layout = f.viewModel.layout
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        let mute = try #require(plates(scene, layout, a1)[.mute])
        #expect(mute.count == 1, "a fill, not a ring")
        #expect(mute[0].color == TimelineTheme.mutedBadge)
        #expect(scene.labels.contains { $0.text == "M" })
        let row = try #require(layout.row(for: a1))
        let lane = try #require(scene.quads.first { $0.rect.minX == layout.trackAreaMinX && $0.rect.minY == row.y })
        #expect(lane.color == TimelineTheme.row(.audio).scaled(TimelineTheme.silentRowDim))
    }

    @Test func aTrackSilencedByAnotherTracksSoloGetsARingRatherThanAFill() async throws {
        let (f, a1, a2) = try await twoAudioTracks()
        await f.viewModel.apply(.setTrackSolo(.init(trackId: .id(a2), solo: true)))
        let layout = f.viewModel.layout
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        // A1 is silent but not muted: a red ring, drawn as the badge colour with the off plate inside it.
        let silenced = try #require(plates(scene, layout, a1)[.mute])
        #expect(silenced.count == 2)
        #expect(silenced[0].color == TimelineTheme.mutedBadge)
        #expect(silenced[1].color == TimelineTheme.controlOff)
        #expect(
            silenced[1].rect
                == silenced[0].rect.insetBy(dx: TimelineTheme.controlRingWidth, dy: TimelineTheme.controlRingWidth))
        // A2's own mute button is untouched; its solo button is filled.
        let soloed = plates(scene, layout, a2)
        #expect(soloed[.mute]?.count == 1 && soloed[.mute]?[0].color == TimelineTheme.controlOff)
        #expect(soloed[.solo]?[0].color == TimelineTheme.soloBadge)
    }

    @Test func theSoloedLaneBrightensAndGetsAnAccentBarWhileItsPeerDims() async throws {
        let (f, a1, a2) = try await twoAudioTracks()
        await f.viewModel.apply(.setTrackSolo(.init(trackId: .id(a2), solo: true)))
        let layout = f.viewModel.layout
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        func lane(_ id: TrackID) throws -> SceneQuad {
            let row = try #require(layout.row(for: id))
            return try #require(scene.quads.first { $0.rect.minX == layout.trackAreaMinX && $0.rect.minY == row.y })
        }
        let base = TimelineTheme.row(.audio)
        #expect(try lane(a2).color == base.scaled(TimelineTheme.soloRowBoost))
        #expect(try lane(a1).color == base.scaled(TimelineTheme.silentRowDim))
        let soloRow = try #require(layout.row(for: a2))
        let accent = try #require(
            scene.overlayQuads.first {
                $0.color == TimelineTheme.soloBadge && $0.rect.minX == layout.trackAreaMinX
                    && $0.rect.minY == soloRow.y
            })
        #expect(accent.rect.width == TimelineTheme.soloAccentWidth && accent.rect.height == soloRow.height)
        // The video track is a different kind and keeps its own colour.
        let video = try #require(f.sequence.tracks.first { $0.kind == .video })
        #expect(try lane(video.id).color == TimelineTheme.row(.video))
    }

    @Test func theRemoveButtonGoesInertOnALockedTrack() async throws {
        let (f, a1, _) = try await twoAudioTracks()
        await f.viewModel.setTrackLocked(a1, true)
        let layout = f.viewModel.layout
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        let buttons = plates(scene, layout, a1)
        #expect(buttons[.lock]?[0].color == TimelineTheme.lockedBadge)
        #expect(buttons[.remove]?[0].color == TimelineTheme.controlOff.with(alpha: 0.4))
        // A track that is only locked is still heard: the mute button stays off.
        #expect(buttons[.mute]?[0].color == TimelineTheme.controlOff)
    }

    @Test func sceneStatsCountLabelsAndMediaRequestsOnlyForWideClips() async throws {
        let f = try await UIFixture.make("three-clips", media: true, zoomIndex: 0)
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        // At four seconds per point every clip is a sliver: no labels, no media.
        #expect(scene.stats.clipsDrawn == 4)
        #expect(scene.stats.filmstrips == 0 && scene.stats.waveforms == 0)
        #expect(!scene.labels.contains { $0.text == "IMG_1575.MOV" })
        f.viewModel.setZoom(index: 4)
        let wide = TimelineSceneBuilder.build(from: f.viewModel)
        #expect(wide.stats.filmstrips >= 3 && wide.stats.waveforms >= 1)
        #expect(wide.labels.contains { $0.text == "IMG_1575.MOV" })
        #expect(wide.labels.contains { $0.text == "V1" } && wide.labels.contains { $0.text == "A1" })
    }
}
