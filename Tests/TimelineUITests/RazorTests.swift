import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import Observation
import Testing
import TimelineCore

@testable import TimelineUI

/// The razor resolves a pointer position into a cut before any command exists. Everything here is the
/// pure half: what a click *would* do, and what the scene draws while you decide.
@MainActor
@Suite("The razor resolves a cut before it makes one")
struct RazorTests {
    /// A point inside `clip`, `seconds` in from its start.
    func point(_ f: UIFixture, _ clip: Clip, seconds: Double) -> CGPoint {
        let l = f.viewModel.layout
        let row = l.row(for: clip.trackId)!
        return CGPoint(x: l.x(forSeconds: clip.start.seconds + seconds), y: row.midY)
    }

    @Test func hoveringAClipNamesThatClipAndItsTrack() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let clip = f.clips(.video)[1]

        let target = f.viewModel.razorTarget(at: point(f, clip, seconds: 1), modifiers: [])
        #expect(target.clipIds == [clip.id])
        #expect(target.trackId == clip.trackId)
        #expect(target.allTracks == false)
        #expect(target.isCuttable)
        #expect(abs(target.at.seconds - (clip.start.seconds + 1)) < 0.05)
    }

    @Test func hoveringAGapNamesNoClipAndTheBladeDrawsInert() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let l = f.viewModel.layout
        let last = f.clips(.video).last!
        let past = CGPoint(x: l.x(forSeconds: f.sequence.end(of: last).seconds + 5), y: l.rows[0].midY)

        let target = f.viewModel.razorTarget(at: past, modifiers: [])
        #expect(target.clipIds.isEmpty)
        #expect(!target.isCuttable)

        // Drawn, but dimmed and without the triangle a live cut gets.
        f.viewModel.selectTool(.razor)
        f.viewModel.updateRazor(at: past, modifiers: [])
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        let blade = try #require(scene.overlayQuads.first { $0.color.matches(TimelineTheme.razorIndicator) })
        #expect(blade.color.a < 1)
        #expect(!scene.triangles.contains { $0.color.matches(TimelineTheme.razorIndicator) })
    }

    @Test func shiftNamesEveryUnlockedTracksClipAndOmitsTheLockedOne() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        f.viewModel.snappingEnabled = false
        let video = f.clips(.video)[0]
        let at = point(f, video, seconds: 1)

        let single = f.viewModel.razorTarget(at: at, modifiers: [])
        #expect(single.clipIds == [video.id], "without Shift, only the clip under the pointer")

        let all = f.viewModel.razorTarget(at: at, modifiers: [.shift])
        #expect(all.allTracks)
        // The V/A pair is one link group and cuts once; the caption clip is its own.
        #expect(all.clipIds.count == 2)
        #expect(all.clipIds.contains(video.id))

        let caption = try #require(f.clips(.caption).first { $0.start <= all.at && all.at <= f.sequence.end(of: $0) })
        await f.viewModel.setTrackLocked(caption.trackId, true)
        let locked = f.viewModel.razorTarget(at: at, modifiers: [.shift])
        #expect(locked.clipIds == [video.id], "the locked track's clip is gone")
    }

    @Test func theCutSnapsToAnotherTracksEdgeThatFallsInsideTheClip() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let l = f.viewModel.layout
        let video = f.clips(.video)[0]
        let caption = f.clips(.caption)[1]
        // The caption begins partway through the first video clip: the cut a razor most wants to make.
        #expect(video.start < caption.start && caption.start < f.sequence.end(of: video))
        let near = CGPoint(x: l.x(for: caption.start) + 3, y: l.row(for: video.trackId)!.midY)

        let snapped = f.viewModel.razorTarget(at: near, modifiers: [])
        #expect(snapped.snappedTo == caption.start)
        #expect(snapped.at == caption.start)
        #expect(snapped.clipIds == [video.id], "the cut is still inside the clip under the pointer")
    }

    @Test func aClipNeverSnapsToItsOwnLinkGroupsEdges() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let l = f.viewModel.layout
        let video = f.clips(.video)[1]
        let partner = try #require(f.clips(.audio).first { $0.linkGroupId == video.linkGroupId })
        let end = f.sequence.end(of: video)
        #expect(f.sequence.end(of: partner) == end, "the pair share an edge, so both must be excluded")

        // Just inside its own tail. Its own edge and its partner's are the only targets nearby, and both
        // are excluded — snapping to the clip you are cutting only ever yields a cut at its own edge.
        let near = CGPoint(x: l.x(for: end) - 3, y: l.row(for: video.trackId)!.midY)
        let target = f.viewModel.razorTarget(at: near, modifiers: [])
        #expect(target.snappedTo == nil)
        #expect(target.at < end)
        #expect(target.clipIds == [video.id], "so the cut stays live instead of collapsing onto the edge")
    }

    @Test func aNeighboursCoincidentEdgeStillSnapsAndTheTargetComesBackInert() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let l = f.viewModel.layout
        let video = f.clips(.video)[1]
        // The previous clip ends exactly where this one starts, and it is a different link group, so it
        // is a legitimate snap target. Deriving the clip list from the *snapped* time is what turns that
        // into an inert click rather than a command `decide` would throw on.
        let near = CGPoint(x: l.x(for: video.start) + 3, y: l.row(for: video.trackId)!.midY)

        let target = f.viewModel.razorTarget(at: near, modifiers: [])
        #expect(target.at == video.start)
        #expect(target.clipIds.isEmpty)
        #expect(!target.isCuttable)
    }

    @Test func aSnapOntoAClipBoundaryYieldsAnInertTargetRatherThanARejection() async throws {
        let f = try await UIFixture.make("three-clips")
        let l = f.viewModel.layout
        let clips = f.clips(.video)
        // The seam between clip 0 and clip 1: snapping pulls the cut exactly onto it, where neither clip
        // can be split. `decide` would throw; the target simply names nothing.
        let seam = f.sequence.end(of: clips[0])
        let near = CGPoint(x: l.x(for: seam) + 2, y: l.rows[0].midY)

        let target = f.viewModel.razorTarget(at: near, modifiers: [])
        #expect(target.snappedTo == seam)
        #expect(target.clipIds.isEmpty, "a cut on the seam is not a cut")
    }

    @Test func aTimeWithinHalfAFrameOfAnEdgeIsFilteredOutOnVideoTracks() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let clip = f.clips(.video)[1]
        let fd = f.sequence.frameDuration
        // Inside the clip by a third of a frame: `clip.start < at` holds, but `decide` snaps to the frame
        // first and lands back on the start, where it throws.
        let sliver = clip.start + RationalTime(fd.value / 3, fd.timescale)
        #expect(sliver > clip.start)
        #expect(f.viewModel.cutTime(sliver, on: f.sequence.track(clip.trackId)!) == clip.start)
        #expect(f.viewModel.canCut(clip, at: sliver, unlinked: false) == false)

        // Audio keeps sample precision, so the same sliver is a real cut there.
        let audio = f.clips(.audio)[0]
        let audioSliver = audio.start + RationalTime(fd.value / 3, fd.timescale)
        #expect(f.viewModel.canCut(audio, at: audioSliver, unlinked: false))
    }

    @Test func theSceneDrawsTheBladeOverOneRowForASingleCutAndFullHeightForAll() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let l = f.viewModel.layout
        let clip = f.clips(.video)[1]
        let row = l.row(for: clip.trackId)!
        let at = point(f, clip, seconds: 1)

        let before = TimelineSceneBuilder.build(from: f.viewModel)
        #expect(!before.overlayQuads.contains { $0.color.matches(TimelineTheme.razorIndicator) })

        f.viewModel.selectTool(.razor)
        f.viewModel.updateRazor(at: at, modifiers: [])
        let single = TimelineSceneBuilder.build(from: f.viewModel)
        let oneRow = try #require(single.overlayQuads.first { $0.color.matches(TimelineTheme.razorIndicator) })
        #expect(oneRow.rect.minY == row.y && oneRow.rect.height == row.height)
        #expect(abs(oneRow.rect.midX - l.x(for: f.viewModel.razorTarget!.at)) < 1.5)
        #expect(single.triangles.contains { $0.color.matches(TimelineTheme.razorIndicator) })

        f.viewModel.updateRazor(at: at, modifiers: [.shift])
        let all = TimelineSceneBuilder.build(from: f.viewModel)
        let full = try #require(all.overlayQuads.first { $0.color.matches(TimelineTheme.razorIndicator) })
        #expect(full.rect.minY == l.rulerHeight)
        #expect(full.rect.height == l.size.height - l.rulerHeight)
    }

    @Test func theRazorDrawsTheSnapBandWhenItSnappedAndEndRazorClearsEverything() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let l = f.viewModel.layout
        let video = f.clips(.video)[1]
        let caption = f.clips(.caption)[1]
        f.viewModel.selectTool(.razor)

        f.viewModel.snappingEnabled = false
        f.viewModel.updateRazor(
            at: CGPoint(x: l.x(for: caption.start) + 3, y: l.row(for: video.trackId)!.midY), modifiers: [])
        let loose = TimelineSceneBuilder.build(from: f.viewModel)
        #expect(f.viewModel.razorTarget?.snappedTo == nil)
        #expect(!loose.overlayQuads.contains { $0.color.matches(TimelineTheme.snapGuide) })

        f.viewModel.snappingEnabled = true
        f.viewModel.updateRazor(
            at: CGPoint(x: l.x(for: caption.start) + 3, y: l.row(for: video.trackId)!.midY), modifiers: [])
        let snapped = TimelineSceneBuilder.build(from: f.viewModel)
        #expect(f.viewModel.razorTarget?.snappedTo == caption.start)
        let band = try #require(snapped.overlayQuads.first { $0.color.matches(TimelineTheme.snapGuide) })
        #expect(abs(band.rect.midX - l.x(for: caption.start)) < 1.5)

        f.viewModel.endRazor()
        let cleared = TimelineSceneBuilder.build(from: f.viewModel)
        #expect(!cleared.overlayQuads.contains { $0.color.matches(TimelineTheme.razorIndicator) })
        #expect(!cleared.triangles.contains { $0.color.matches(TimelineTheme.razorIndicator) })
    }

    @Test func updateRazorDoesNotReassignAnUnchangedTarget() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let at = point(f, f.clips(.video)[1], seconds: 1)
        f.viewModel.selectTool(.razor)
        f.viewModel.updateRazor(at: at, modifiers: [])
        let first = try #require(f.viewModel.razorTarget)

        // Observation fires on every set, and this runs at pointer rate, so an identical hover must not
        // schedule a redraw. `onChange` is a sendable closure, hence the box.
        let redraws = Counter()
        withObservationTracking {
            _ = f.viewModel.razorTarget
        } onChange: {
            redraws.bump()
        }
        f.viewModel.updateRazor(at: at, modifiers: [])
        #expect(redraws.value == 0)
        #expect(f.viewModel.razorTarget == first)

        f.viewModel.updateRazor(at: CGPoint(x: at.x + 40, y: at.y), modifiers: [])
        #expect(redraws.value == 1)
    }

    @Test func theCursorIsABladeOverTheLanesAndAnArrowOverTheRulerAndHeader() async throws {
        let f = try await UIFixture.make("three-clips")
        let l = f.viewModel.layout
        let lane = CGPoint(x: 600, y: l.rows[0].midY)
        let ruler = CGPoint(x: 600, y: 5)
        let header = CGPoint(x: 50, y: l.rows[0].midY)

        for point in [lane, ruler, header] {
            #expect(TimelineCursor.kind(for: .selection, at: point, layout: l) == .arrow)
        }
        #expect(TimelineCursor.kind(for: .razor, at: lane, layout: l) == .razor)
        #expect(TimelineCursor.kind(for: .razor, at: ruler, layout: l) == .arrow)
        #expect(TimelineCursor.kind(for: .razor, at: header, layout: l) == .arrow)
    }

    @Test func puttingTheToolAwayClearsTheBlade() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.selectTool(.razor)
        f.viewModel.updateRazor(at: point(f, f.clips(.video)[1], seconds: 1), modifiers: [])
        #expect(f.viewModel.razorTarget != nil)

        f.viewModel.selectTool(.selection)
        #expect(f.viewModel.razorTarget == nil)
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        #expect(!scene.overlayQuads.contains { $0.color.matches(TimelineTheme.razorIndicator) })
    }
}

/// A counter an Observation `onChange` closure can reach: it is `@Sendable`, so it cannot capture a
/// mutable local.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.withLock { count += 1 }
    }

    var value: Int { lock.withLock { count } }
}
