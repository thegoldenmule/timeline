import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import Testing
import TimelineCore

@testable import TimelineUI

/// Every gesture goes through `TimelineGestureController` with view points, the same path the
/// `NSEvent` handlers take, and must hand the store exactly one command on release.
@MainActor
@Suite("Gestures emit one command each")
struct GestureTests {
    /// 0.05 s per point at the default zoom: 100 points is five seconds.
    let pointsPerSecond: CGFloat = 20

    @Test func moveIsOverwriteByDefaultAndEmitsOneCommand() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let g = TimelineGestureController(viewModel: f.viewModel)
        let clip = f.clips(.video)[2]
        let start = f.center(of: clip)

        g.mouseDown(at: start)
        #expect(f.viewModel.selection == [clip.id])
        for dx in stride(from: 10, through: 100, by: 10) {
            g.mouseDragged(to: CGPoint(x: start.x + CGFloat(dx), y: start.y))
        }
        // Local preview only: the clip appears moved, the store has seen nothing.
        #expect(g.isDragging)
        let preview = try #require(f.viewModel.preview)
        #expect(preview.isValid)
        #expect(preview.sequence.clip(clip.id)!.start > clip.start)
        #expect(await f.receivedCommands.isEmpty)

        let result = await g.mouseUp(at: CGPoint(x: start.x + 100, y: start.y))
        #expect(result?.status == .applied)
        let commands = await f.receivedCommands
        #expect(commands.count == 1)
        guard case .moveClip(let op) = commands[0].operation else {
            Issue.record("expected moveClip, got \(commands[0].operation.typeName)")
            return
        }
        #expect(op.clipId == .id(clip.id))
        #expect(op.mode == .overwrite)
        #expect(op.unlinked == false)
        #expect(op.to.trackId == nil)
        #expect(abs(op.to.start.seconds - (clip.start.seconds + 5)) < 0.01)
        #expect(commands[0].actor == .human)
        #expect(commands[0].expectedVersion == nil)
        // The store applied it and the model mirrors it.
        #expect(f.viewModel.preview == nil && f.viewModel.pending == nil)
        let moved = try #require(f.viewModel.clip(clip.id))
        #expect(abs(moved.start.seconds - (clip.start.seconds + 5)) < 0.05)
        #expect(f.viewModel.commandCount == 1)
    }

    @Test func commandFlipsMoveToRippleAndOptionUnlinks() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        f.viewModel.snappingEnabled = false
        let g = TimelineGestureController(viewModel: f.viewModel)
        let clip = f.clips(.video)[1]
        let partner = try #require(f.clips(.audio).first { $0.linkGroupId == clip.linkGroupId })
        let start = f.center(of: clip)
        let mods: EditModifiers = [.command, .option]

        g.mouseDown(at: start, modifiers: mods)
        g.mouseDragged(to: CGPoint(x: start.x + 60, y: start.y), modifiers: mods)
        // The preview honours `unlinked`: only the addressed clip moves in the scratch sequence.
        let preview = try #require(f.viewModel.preview)
        #expect(preview.sequence.clip(partner.id)?.start == partner.start)
        #expect(preview.sequence.clip(clip.id)!.start > clip.start)
        _ = await g.mouseUp(at: CGPoint(x: start.x + 60, y: start.y), modifiers: mods)

        let commands = await f.receivedCommands
        #expect(commands.count == 1)
        guard case .moveClip(let op) = commands[0].operation else {
            Issue.record("expected moveClip")
            return
        }
        #expect(op.mode == .ripple)
        #expect(op.unlinked == true)
        #expect(f.viewModel.clip(partner.id)?.start == partner.start)
    }

    @Test func linkedMoveWithoutOptionMovesTheWholeGroup() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        f.viewModel.snappingEnabled = false
        let g = TimelineGestureController(viewModel: f.viewModel)
        let clip = f.clips(.video)[1]
        let partner = try #require(f.clips(.audio).first { $0.linkGroupId == clip.linkGroupId })
        let start = f.center(of: clip)
        g.mouseDown(at: start)
        g.mouseDragged(to: CGPoint(x: start.x + 40, y: start.y))
        _ = await g.mouseUp(at: CGPoint(x: start.x + 40, y: start.y))
        let commands = await f.receivedCommands
        #expect(commands.count == 1)
        guard case .moveClip(let op) = commands[0].operation else {
            Issue.record("expected moveClip")
            return
        }
        #expect(op.unlinked == false)
        let movedPartner = try #require(f.viewModel.clip(partner.id))
        #expect(movedPartner.start > partner.start)
        #expect(f.viewModel.clip(clip.id)!.start - movedPartner.start == clip.start - partner.start)
    }

    @Test func trimTailIsRippleByDefault() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let g = TimelineGestureController(viewModel: f.viewModel)
        let clips = f.clips(.video)
        let clip = clips[0]
        let r = f.rect(of: clip)
        let handle = CGPoint(x: r.maxX - 3, y: r.midY)
        #expect(g.hitTest(handle) == .clip(clip.id, .trimTail))

        g.mouseDown(at: handle)
        g.mouseDragged(to: CGPoint(x: handle.x - 20, y: handle.y))
        let preview = try #require(f.viewModel.preview)
        #expect(preview.isValid)
        // Ripple: the following clips shift left in the preview.
        #expect(preview.sequence.clip(clips[1].id)!.start < clips[1].start)
        _ = await g.mouseUp(at: CGPoint(x: handle.x - 20, y: handle.y))

        let commands = await f.receivedCommands
        #expect(commands.count == 1)
        guard case .trimClip(let op) = commands[0].operation else {
            Issue.record("expected trimClip")
            return
        }
        #expect(op.clipId == .id(clip.id))
        #expect(op.edge == .tail)
        #expect(op.mode == .ripple)
        #expect(op.unlinked == false)
        let expected = f.sequence.end(of: clip).seconds - 1
        #expect(abs(op.to.seconds - expected) < 0.01)
        #expect(f.viewModel.clip(clips[1].id)!.start < clips[1].start)
    }

    @Test func trimHeadWithCommandIsOverwrite() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let g = TimelineGestureController(viewModel: f.viewModel)
        let clips = f.clips(.video)
        let clip = clips[1]
        let r = f.rect(of: clip)
        let handle = CGPoint(x: r.minX + 3, y: r.midY)
        #expect(g.hitTest(handle) == .clip(clip.id, .trimHead))

        g.mouseDown(at: handle, modifiers: [.command])
        g.mouseDragged(to: CGPoint(x: handle.x + 10, y: handle.y), modifiers: [.command])
        _ = await g.mouseUp(at: CGPoint(x: handle.x + 10, y: handle.y), modifiers: [.command])

        let commands = await f.receivedCommands
        #expect(commands.count == 1)
        guard case .trimClip(let op) = commands[0].operation else {
            Issue.record("expected trimClip")
            return
        }
        #expect(op.edge == .head)
        #expect(op.mode == .overwrite)
        #expect(abs(op.to.seconds - (clip.start.seconds + 0.5)) < 0.01)
        // Overwrite leaves the neighbours alone.
        #expect(f.viewModel.clip(clips[2].id)!.start == clips[2].start)
        #expect(f.viewModel.clip(clip.id)!.start > clip.start)
    }

    @Test func splitAtPlayheadEmitsOneSplitCommand() async throws {
        let f = try await UIFixture.make("three-clips")
        let g = TimelineGestureController(viewModel: f.viewModel)
        let clip = f.clips(.video)[2]
        // A click without a drag selects and emits nothing.
        g.mouseDown(at: f.center(of: clip))
        let click = await g.mouseUp(at: f.center(of: clip))
        #expect(click == nil)
        #expect(await f.receivedCommands.isEmpty)

        let at = clip.start + RationalTime(seconds: 2)
        f.viewModel.setPlayhead(at)
        let result = await g.key(.split)
        #expect(result?.status == .applied)
        let commands = await f.receivedCommands
        #expect(commands.count == 1)
        guard case .splitClip(let op) = commands[0].operation else {
            Issue.record("expected splitClip")
            return
        }
        #expect(op.clipId == .id(clip.id))
        #expect(op.at == f.viewModel.playhead)
        #expect(op.unlinked == false)
        #expect(f.clips(.video).count == 4)
    }

    @Test func splitWithNothingSelectedCutsUnderThePlayheadOncePerLinkGroup() async throws {
        let f = try await UIFixture.make("linked-transition-caption-undone")
        let g = TimelineGestureController(viewModel: f.viewModel)
        let clip = f.clips(.video)[1]
        f.viewModel.setPlayhead(clip.start + RationalTime(seconds: 1))
        _ = await g.key(.split, modifiers: [])
        let commands = await f.receivedCommands
        #expect(commands.count == 1)
        guard case .splitClip = commands[0].operation else {
            Issue.record("expected a single splitClip, got \(commands[0].operation.typeName)")
            return
        }
        #expect(f.clips(.video).count == 3)
        #expect(f.clips(.audio).count == 3)
    }

    @Test func deleteIsRippleByDefaultAndFlipsWithCommand() async throws {
        let f = try await UIFixture.make("three-clips")
        let g = TimelineGestureController(viewModel: f.viewModel)
        let clips = f.clips(.video)
        f.viewModel.select(clips[1].id)
        _ = await g.key(.delete)
        var commands = await f.receivedCommands
        #expect(commands.count == 1)
        guard case .removeClip(let op) = commands[0].operation else {
            Issue.record("expected removeClip")
            return
        }
        #expect(op.clipId == .id(clips[1].id))
        #expect(op.mode == .ripple)
        #expect(op.unlinked == false)
        #expect(f.viewModel.clip(clips[2].id)!.start == clips[1].start)
        #expect(f.viewModel.selection.isEmpty)

        f.viewModel.select(clips[2].id)
        _ = await g.key(.delete, modifiers: [.command, .option])
        commands = await f.receivedCommands
        #expect(commands.count == 2)
        guard case .removeClip(let second) = commands[1].operation else {
            Issue.record("expected removeClip")
            return
        }
        #expect(second.mode == .overwrite)
        #expect(second.unlinked == true)
        #expect(f.clips(.video).count == 1)
    }

    @Test func escapeCancelsADragWithoutACommand() async throws {
        let f = try await UIFixture.make("three-clips")
        let g = TimelineGestureController(viewModel: f.viewModel)
        let clip = f.clips(.video)[0]
        let start = f.center(of: clip)
        g.mouseDown(at: start)
        g.mouseDragged(to: CGPoint(x: start.x + 50, y: start.y))
        #expect(f.viewModel.pending != nil)
        _ = await g.key(.escape)
        #expect(f.viewModel.pending == nil && f.viewModel.preview == nil)
        let result = await g.mouseUp(at: CGPoint(x: start.x + 50, y: start.y))
        #expect(result == nil)
        #expect(await f.receivedCommands.isEmpty)
    }

    @Test func rulerScrubsAndArrowsNudgeThePlayhead() async throws {
        let f = try await UIFixture.make("three-clips")
        let g = TimelineGestureController(viewModel: f.viewModel)
        g.mouseDown(at: CGPoint(x: 320, y: 10))
        #expect(abs(f.viewModel.playhead.seconds - 10) < 0.05)
        g.mouseDragged(to: CGPoint(x: 340, y: 10))
        _ = await g.mouseUp(at: CGPoint(x: 340, y: 10))
        #expect(abs(f.viewModel.playhead.seconds - 11) < 0.05)
        #expect(f.viewModel.playhead.isFrameAligned(frameDuration: f.viewModel.frameDuration))
        let before = f.viewModel.playhead
        _ = await g.key(.right)
        #expect(f.viewModel.playhead - before == f.viewModel.frameDuration)
        _ = await g.key(.left, modifiers: [.shift])
        #expect(before - f.viewModel.playhead == RationalTime.frames(9, of: f.viewModel.frameDuration))
        _ = await g.key(.toggleSnapping)
        #expect(!f.viewModel.snappingEnabled)
        #expect(await f.receivedCommands.isEmpty)
    }

    @Test func draggingOntoAnotherTrackOfTheSameKindRetargets() async throws {
        let builder = try Fixtures.builder("three-clips")
        try builder.addTracks(.video, count: 1)
        let store = FakeProjectStore(builder: builder)
        let vm = TimelineViewModel(store: store)
        vm.viewSize = CGSize(width: 1200, height: 400)
        vm.snappingEnabled = false
        await vm.load()
        let g = TimelineGestureController(viewModel: vm)
        let seq = vm.sequence!
        let clip = seq.tracks[0].clips.values.sorted { $0.start < $1.start }[2]
        let target = seq.tracks.last { $0.kind == .video }!
        let start = CGPoint(x: vm.layout.rect(for: clip, in: seq)!.midX, y: vm.layout.rect(for: clip, in: seq)!.midY)
        let targetY = vm.layout.row(for: target.id)!.y + 10
        g.mouseDown(at: start)
        g.mouseDragged(to: CGPoint(x: start.x + 5, y: targetY))
        _ = await g.mouseUp(at: CGPoint(x: start.x + 5, y: targetY))
        let commands = await store.receivedCommands
        #expect(commands.count == 1)
        guard case .moveClip(let op) = commands[0].operation else {
            Issue.record("expected moveClip")
            return
        }
        #expect(op.to.trackId == .id(target.id))
        #expect(vm.clip(clip.id)?.trackId == target.id)
        // An audio row is not a valid target for a video clip.
        let audioY = vm.layout.rows.first { $0.kind == .audio }!.y + 5
        let moved = vm.clip(clip.id)!
        let p = CGPoint(x: vm.layout.rect(for: moved, in: vm.sequence!)!.midX, y: vm.layout.row(for: target.id)!.midY)
        g.mouseDown(at: p)
        g.mouseDragged(to: CGPoint(x: p.x + 5, y: audioY))
        #expect(vm.pending?.targetTrackId == nil)
        _ = await g.key(.escape)
    }

    @Test func snappingLandsOnNeighbourEdgesAndReportsTheGuide() async throws {
        let f = try await UIFixture.make("three-clips")
        let g = TimelineGestureController(viewModel: f.viewModel)
        let clips = f.clips(.video)
        let clip = clips[2]
        let audio = f.clips(.audio)[0]
        let audioEnd = f.sequence.end(of: audio)
        // Drag C's head to within tolerance of the audio clip's end (11.25 s): 5 points away.
        let targetX = f.viewModel.layout.x(for: audioEnd) + 5
        let start = f.center(of: clip)
        let dx = targetX - f.rect(of: clip).minX
        g.mouseDown(at: start)
        g.mouseDragged(to: CGPoint(x: start.x + dx, y: start.y))
        #expect(f.viewModel.preview?.snappedTo == audioEnd)
        let scene = TimelineSceneBuilder.build(from: f.viewModel)
        #expect(scene.overlayQuads.contains { $0.color == TimelineTheme.snapGuide })
        _ = await g.mouseUp(at: CGPoint(x: start.x + dx, y: start.y))
        let commands = await f.receivedCommands
        guard case .moveClip(let op) = commands[0].operation else {
            Issue.record("expected moveClip")
            return
        }
        #expect(op.to.start == audioEnd)
    }

    @Test func invalidDropShowsAnInvalidPreviewAndTheStoreRejectsNothingSilently() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        // Lock the video track: the gesture never starts.
        let track = f.sequence.tracks[0]
        await f.viewModel.setTrackLocked(track.id, true)
        let g = TimelineGestureController(viewModel: f.viewModel)
        let clip = f.clips(.video)[0]
        let start = f.center(of: clip)
        g.mouseDown(at: start)
        g.mouseDragged(to: CGPoint(x: start.x + 50, y: start.y))
        #expect(f.viewModel.pending == nil)
        _ = await g.mouseUp(at: CGPoint(x: start.x + 50, y: start.y))
        #expect(await f.receivedCommands.count == 1)  // only the lock command
    }
}
