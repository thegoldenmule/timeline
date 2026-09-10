import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import Testing
import TimelineCore

@testable import TimelineUI

@MainActor
@Suite("Offscreen rendering")
struct RenderTests {
    @Test func rendersThreeClipsWithRulerAndClipBodies() async throws {
        let f = try await UIFixture.make("three-clips")
        let renderer = try TimelineRenderer()
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        let frame = try renderer.render(scene: scene)

        #expect(!frame.isBlank)
        #expect(frame.width == 1200 && frame.height == 400)
        #expect(scene.stats.clipsDrawn == 4)
        #expect(scene.stats.clipsCulled == 0)

        // Ruler across the top of the track area.
        #expect(frame.pixel(x: 600, y: 4).matches(TimelineTheme.ruler))
        #expect(frame.pixel(x: 60, y: 4).matches(TimelineTheme.ruler))
        // Track header on the left.
        let videoRow = f.viewModel.layout.rows[0]
        #expect(frame.pixel(x: 60, y: Int(videoRow.midY)).matches(TimelineTheme.header.scaled(1.05), tolerance: 0.03))
        // Empty track area right of the clips.
        #expect(frame.pixel(x: 1100, y: Int(videoRow.midY)).matches(TimelineTheme.rowVideo))

        // Each video clip's body colour at its screen rect; the audio clip in the audio colour.
        for clip in f.clips(.video) {
            let r = try #require(scene.clipRects[clip.id])
            let px = frame.pixel(x: Int(r.midX), y: Int(r.maxY - 6))
            #expect(px.matches(TimelineTheme.clipVideo), "clip \(clip.id) at \(r)")
        }
        let audio = try #require(f.clips(.audio).first)
        let ar = try #require(scene.clipRects[audio.id])
        #expect(frame.pixel(x: Int(ar.midX), y: Int(ar.maxY - 6)).matches(TimelineTheme.clipAudio))

        // Playhead at zero: red line at the track area's left edge.
        let playheadX = Int(f.viewModel.layout.x(for: .zero))
        #expect(frame.pixel(x: playheadX, y: 100).matches(TimelineTheme.playhead))
        // Ruler labels exist and start at zero.
        #expect(scene.labels.contains { $0.text == "0:00" })
    }

    @Test func rendersLinkedClipsTransitionCaptionsAndMarker() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let renderer = try TimelineRenderer()
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        let frame = try renderer.render(scene: scene)
        #expect(!frame.isBlank)

        // Linked video and audio clips both draw and carry the same link-group stripe colour.
        let video = f.clips(.video)
        let audio = f.clips(.audio)
        #expect(video.count == 2 && audio.count == 2)
        let group = try #require(video[0].linkGroupId)
        #expect(audio.contains { $0.linkGroupId == group })
        let vr = try #require(scene.clipRects[video[0].id])
        let partner = try #require(audio.first { $0.linkGroupId == group })
        let ar = try #require(scene.clipRects[partner.id])
        let stripe = TimelineTheme.linkGroupColor(group)
        #expect(frame.pixel(x: Int(vr.midX), y: Int(vr.maxY - 3)).matches(stripe, tolerance: 0.05))
        #expect(frame.pixel(x: Int(ar.midX), y: Int(ar.maxY - 3)).matches(stripe, tolerance: 0.05))

        // The transition wedge sits on the cut and differs from the plain clip colour on both sides.
        let transition = try #require(f.sequence.transitions.values.first)
        let tr = try #require(scene.transitionRects[transition.id])
        #expect(scene.stats.transitionsDrawn == 1)
        let cutX = f.viewModel.layout.x(for: f.sequence.end(of: video[0]))
        #expect(abs(tr.midX - cutX) < 1)
        let wedgeTop = frame.pixel(x: Int(tr.midX) - 2, y: Int(tr.minY) + 4)
        let wedgeBottom = frame.pixel(x: Int(tr.midX) + 2, y: Int(tr.maxY) - 8)
        #expect(!wedgeTop.matches(TimelineTheme.clipVideo))
        #expect(!wedgeBottom.matches(TimelineTheme.clipVideo))
        #expect(wedgeTop.matches(TimelineTheme.transition, tolerance: 0.05))
        #expect(wedgeBottom.matches(TimelineTheme.clipVideo.scaled(0.55), tolerance: 0.05))
        // Plain clip colour just outside the wedge.
        #expect(frame.pixel(x: Int(tr.minX) - 6, y: Int(tr.maxY) - 6).matches(TimelineTheme.clipVideo))

        // Caption items draw in the caption colour with their text as label.
        let captions = f.clips(.caption)
        #expect(captions.count == 2)
        let cr = try #require(scene.clipRects[captions[0].id])
        #expect(frame.pixel(x: Int(cr.maxX) - 4, y: Int(cr.midY)).matches(TimelineTheme.clipCaption))
        #expect(scene.labels.contains { $0.text == "Hello there" })

        // The marker sits in the ruler at its time.
        let marker = try #require(f.sequence.markers.values.first)
        let mx = Int(f.viewModel.layout.x(for: marker.at))
        #expect(
            frame.pixel(x: mx, y: Int(f.viewModel.layout.rulerHeight) - 4).matches(
                TimelineTheme.marker, tolerance: 0.05))
    }

    @Test func selectionOutlineAndPlayheadMove() async throws {
        let f = try await UIFixture.make("three-clips")
        let renderer = try TimelineRenderer()
        let clip = f.clips(.video)[1]
        f.viewModel.select(clip.id)
        f.viewModel.setPlayhead(RationalTime(seconds: 5))
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        let frame = try renderer.render(scene: scene)
        let r = try #require(scene.clipRects[clip.id])
        #expect(frame.pixel(x: Int(r.midX), y: Int(r.minY)).matches(TimelineTheme.selection))
        let x = Int(f.viewModel.layout.x(for: f.viewModel.playhead))
        #expect(frame.pixel(x: x, y: 200).matches(TimelineTheme.playhead))
        #expect(!frame.pixel(x: Int(f.viewModel.layout.x(for: .zero)), y: 200).matches(TimelineTheme.playhead))
    }

    @Test func filmstripsAndWaveformsAreFetchedPerZoomAndDrawn() async throws {
        let f = try await UIFixture.make("three-clips", media: true, zoomIndex: 4)
        let renderer = try TimelineRenderer()
        let cache = TimelineMediaCache(device: renderer.device, thumbnails: f.thumbnails, waveforms: f.waveforms)
        renderer.mediaCache = cache
        let thumbs = try #require(f.thumbnails)
        let waves = try #require(f.waveforms)

        // First frame: misses start fetches; bodies draw in the plain colour. Each clip asks for media in
        // aligned chunks, so a clip wider than one chunk contributes several keys.
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        let stripKeys = Set(scene.filmstrips.map(\.key))
        let waveKeys = Set(scene.waveforms.map(\.key))
        #expect(scene.stats.filmstrips >= 3 && scene.stats.waveforms >= 1)
        let before = try renderer.render(scene: scene)
        #expect(cache.pendingCount == stripKeys.count + waveKeys.count)
        #expect(cache.fetchCount == stripKeys.count + waveKeys.count)
        await cache.drain()
        #expect(thumbs.calls.count == stripKeys.count)
        #expect(waves.calls.count == waveKeys.count)
        #expect(cache.filmstripCount == stripKeys.count && cache.waveformCount == waveKeys.count)
        let strip = scene.filmstrips[0]
        #expect(thumbs.calls.contains { $0.count == strip.key.count && $0.height == strip.key.height })

        // Second frame: textures are drawn over the clip bodies.
        let after = try renderer.render(scene: scene)
        let r = strip.rect
        let px = CGPoint(x: r.minX + 10, y: r.midY)
        #expect(before.pixel(x: Int(px.x), y: Int(px.y)).matches(TimelineTheme.clipVideo))
        #expect(!after.pixel(x: Int(px.x), y: Int(px.y)).matches(TimelineTheme.clipVideo))
        let waveformPixelsBefore = before.count(of: TimelineTheme.waveform, tolerance: 0.1)
        let waveformPixelsAfter = after.count(of: TimelineTheme.waveform, tolerance: 0.1)
        #expect(waveformPixelsAfter > waveformPixelsBefore + 50)

        // A different zoom asks for a different frame count and samples per pixel.
        f.viewModel.setZoom(index: 3)
        let zoomed = TimelineSceneBuilder.build(from: f.viewModel)
        _ = try renderer.render(scene: zoomed)
        await cache.drain()
        #expect(thumbs.calls.count > stripKeys.count)
        #expect(Set(waves.calls.map(\.samplesPerPixel)).count == 2)
        #expect(zoomed.waveforms[0].key.samplesPerPixel == Int(0.05 * 48000))
    }

    /// Scrolling must slide a clip's filmstrip and waveform under it, not restretch them into whatever part
    /// of the clip is still on screen. The chunks that stay in view keep their keys and their widths, and
    /// their rects move by exactly the distance scrolled.
    @Test func mediaScrollsWithTheClipInsteadOfRescaling() async throws {
        let f = try await UIFixture.make("three-clips", media: true, zoomIndex: 4)
        let vm = f.viewModel
        let clip = f.clips(.video).first { self.width(of: $0, in: f) > vm.layout.trackAreaWidth } ?? f.clips(.video)[0]
        vm.scrollSeconds = clip.start.seconds
        let before = TimelineSceneBuilder.build(from: vm)

        // Scroll by a whole number of points so the shift is exact.
        let points: CGFloat = 200
        vm.scrollSeconds += Double(points) * vm.secondsPerPoint
        let after = TimelineSceneBuilder.build(from: vm)

        let shared = Set(before.filmstrips.map(\.key)).intersection(after.filmstrips.map(\.key))
        #expect(!shared.isEmpty)
        for key in shared {
            let a = try #require(before.filmstrips.first { $0.key == key })
            let b = try #require(after.filmstrips.first { $0.key == key })
            #expect(abs(b.rect.width - a.rect.width) < 0.001)
            #expect(abs((a.rect.minX - b.rect.minX) - points) < 0.001)
        }
        let sharedWaves = Set(before.waveforms.map(\.key)).intersection(after.waveforms.map(\.key))
        #expect(!sharedWaves.isEmpty)
        for key in sharedWaves {
            let a = try #require(before.waveforms.first { $0.key == key })
            let b = try #require(after.waveforms.first { $0.key == key })
            #expect(abs(b.rect.width - a.rect.width) < 0.001)
            #expect(abs((a.rect.minX - b.rect.minX) - points) < 0.001)
        }
        // Nothing draws over the track headers.
        for strip in after.filmstrips { #expect(strip.clipRect.minX >= vm.layout.trackAreaMinX) }
        for wave in after.waveforms { #expect(wave.clipRect.minX >= vm.layout.trackAreaMinX) }
    }

    @Test func theHeaderButtonsRasterizeInTheirStateColours() async throws {
        let f = try await UIFixture.make("three-clips")
        await f.viewModel.apply(.addTrack(.init(sequenceId: .id(f.sequence.id), kind: .audio)))
        let audio = f.sequence.tracks.filter { $0.kind == .audio }
        await f.viewModel.setTrackMuted(audio[0].id, true)
        await f.viewModel.apply(.setTrackSolo(.init(trackId: .id(audio[1].id), solo: true)))
        // The playhead is an overlay at the track area's left edge; move it off the solo accent bar.
        f.viewModel.setPlayhead(RationalTime(seconds: 5))
        let layout = f.viewModel.layout
        let renderer = try TimelineRenderer()
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        let frame = try renderer.render(scene: scene)

        /// A point inside a button's plate but clear of its capital.
        func plate(_ track: TrackID, _ control: TrackControl) throws -> (x: Int, y: Int) {
            let row = try #require(layout.row(for: track))
            let rect = try #require(layout.controls(in: row).first { $0.control == control }?.rect)
            return (Int(rect.maxX - 4), Int(rect.midY))
        }
        // A1: muted, so a solid red mute plate.
        let muted = try plate(audio[0].id, .mute)
        #expect(frame.pixel(x: muted.x, y: muted.y).matches(TimelineTheme.mutedBadge, tolerance: 0.03))
        // A2: soloed, so a solid blue solo plate and an off mute plate beside it.
        let solo = try plate(audio[1].id, .solo)
        #expect(frame.pixel(x: solo.x, y: solo.y).matches(TimelineTheme.soloBadge, tolerance: 0.03))
        let off = try plate(audio[1].id, .mute)
        #expect(frame.pixel(x: off.x, y: off.y).matches(TimelineTheme.controlOff, tolerance: 0.03))
        // The soloed lane carries its accent bar at the track area's left edge.
        let soloRow = try #require(layout.row(for: audio[1].id))
        #expect(
            frame.pixel(x: Int(layout.trackAreaMinX), y: Int(soloRow.midY))
                .matches(TimelineTheme.soloBadge, tolerance: 0.03))
    }

    private func width(of clip: Clip, in f: UIFixture) -> CGFloat {
        f.viewModel.layout.width(for: clip.duration(frameDuration: f.sequence.frameDuration))
    }

    @Test func theRazorIndicatorRasterizesInItsOwnColour() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let renderer = try TimelineRenderer()
        let clip = f.clips(.video)[1]
        let l = f.viewModel.layout
        let row = try #require(l.row(for: clip.trackId))
        let hover = CGPoint(x: l.x(forSeconds: clip.start.seconds + 1), y: row.midY)
        f.viewModel.selectTool(.razor)
        f.viewModel.updateRazor(at: hover, modifiers: [])

        let x = Int(l.x(for: try #require(f.viewModel.razorTarget).at))
        let single = try renderer.render(scene: TimelineSceneBuilder.build(from: f.viewModel))
        #expect(single.pixel(x: x, y: Int(row.midY)).matches(TimelineTheme.razorIndicator, tolerance: 0.05))
        // One row only: the row below is untouched.
        let other = try #require(l.rows.first { $0.trackId != clip.trackId })
        #expect(!single.pixel(x: x, y: Int(other.midY)).matches(TimelineTheme.razorIndicator, tolerance: 0.05))

        f.viewModel.updateRazor(at: hover, modifiers: [.shift])
        let all = try renderer.render(scene: TimelineSceneBuilder.build(from: f.viewModel))
        #expect(all.pixel(x: x, y: Int(other.midY)).matches(TimelineTheme.razorIndicator, tolerance: 0.05))
    }

    @Test func cullsClipsOutsideTheVisibleRange() async throws {
        var gen = ProjectGenerator(seed: 7)
        gen.videoTracks = 2...2
        gen.audioTracks = 1...1
        gen.clipsPerTrack = 60...60
        let store = FakeProjectStore(builder: try gen.builder())
        let vm = TimelineViewModel(store: store)
        await vm.load()
        vm.viewSize = CGSize(width: 800, height: 300)
        vm.setZoom(index: ZoomLevel.count - 1)
        let scene = TimelineSceneBuilder.build(from: vm)
        let total = vm.sequence!.tracks.reduce(0) { $0 + $1.clips.count }
        #expect(scene.stats.clipsDrawn + scene.stats.clipsCulled == total)
        #expect(scene.stats.clipsCulled > 0)
        #expect(scene.stats.clipsDrawn < total)
        for (_, r) in scene.clipRects {
            #expect(r.maxX >= vm.layout.trackAreaMinX - 4 && r.minX <= vm.viewSize.width + 4)
        }
    }

    @Test func metalViewRendersOffscreenAndObservesTheModel() async throws {
        let f = try await UIFixture.make("three-clips", media: true)
        let view = TimelineMetalView(viewModel: f.viewModel)
        #expect(view.renderError == nil)
        #expect(view.isFlipped)
        let frame = try view.renderOffscreen()
        #expect(!frame.isBlank)
        #expect(view.lastScene?.stats.clipsDrawn == 4)
        #expect(view.mediaCache != nil)
        #expect(view.gestures.hitTest(CGPoint(x: 600, y: 4)) == .ruler)
        // A model change requests a redraw through observation; so does a landed media fetch.
        let requests = view.redrawRequests
        f.viewModel.setPlayhead(RationalTime(seconds: 2))
        #expect(await eventually { view.redrawRequests > requests })
        let afterModel = view.redrawRequests
        // The first render's fetches may already have landed, so ask for new filmstrip keys at another zoom
        // before draining; the landed fetches then request a redraw of their own.
        f.viewModel.setZoom(index: max(0, f.viewModel.zoomIndex - 1))
        await view.mediaCache?.drain()
        #expect(await eventually { view.redrawRequests > afterModel })
        // The SwiftUI wrapper builds the same view.
        let wrapper = TimelineView(viewModel: f.viewModel)
        #expect(wrapper.viewModel === f.viewModel)
    }

    @Test func emptyProjectRendersChrome() async throws {
        let store = FakeProjectStore()
        let vm = TimelineViewModel(store: store)
        await vm.load()
        let renderer = try TimelineRenderer()
        let scene = TimelineSceneBuilder.build(from: vm)
        let frame = try renderer.render(scene: scene)
        #expect(frame.pixel(x: 600, y: 4).matches(TimelineTheme.ruler))
        #expect(scene.labels.contains { $0.text == "No sequence" })
    }
}
