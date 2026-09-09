import AppKit
import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import Testing
import TimelineCore

@testable import TimelineUI

/// File drops go through `TimelineViewModel.dropTarget(at:)` and the drop state machine with view
/// points, the same path the `NSDraggingDestination` methods take, without an `NSDraggingInfo`.
@MainActor
@Suite("File drops land where the pointer is")
struct DropTests {
    @Test func dropTargetOverAVideoTrackNamesItAndTheTimeUnderThePointer() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let l = f.viewModel.layout
        let row = try #require(l.rows.first { $0.kind == .video })
        let target = f.viewModel.dropTarget(at: CGPoint(x: l.x(forSeconds: 30), y: row.midY))
        #expect(target.trackId == row.trackId)
        #expect(abs(target.at.seconds - 30) < 1e-6)
        #expect(target.snappedTo == nil)
        #expect(!target.at.isNegative)
    }

    @Test func dropTargetOverAnAudioTrackNamesTheAudioTrack() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let l = f.viewModel.layout
        let row = try #require(l.rows.first { $0.kind == .audio })
        let target = f.viewModel.dropTarget(at: CGPoint(x: l.x(forSeconds: 42), y: row.y + 3))
        #expect(target.trackId == row.trackId)
        #expect(f.sequence.track(target.trackId!)?.kind == .audio)
        #expect(abs(target.at.seconds - 42) < 1e-6)
    }

    @Test func rulerAndTheAreaBelowTheTracksHaveNoTrack() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let l = f.viewModel.layout
        let ruler = f.viewModel.dropTarget(at: CGPoint(x: l.x(forSeconds: 12), y: 10))
        #expect(ruler.trackId == nil)
        #expect(abs(ruler.at.seconds - 12) < 1e-6)
        let below = f.viewModel.dropTarget(at: CGPoint(x: l.x(forSeconds: 12), y: l.contentBottom + 20))
        #expect(below.trackId == nil)
        #expect(abs(below.at.seconds - 12) < 1e-6)
        // Left of the track area the time clamps to zero rather than going negative.
        let header = f.viewModel.dropTarget(at: CGPoint(x: 20, y: l.rows[0].midY))
        #expect(header.at == .zero)
    }

    @Test func snappingLandsOnTheNearestClipEdge() async throws {
        let f = try await UIFixture.make("three-clips")
        let clip = f.clips(.video)[1]
        let edge = f.sequence.end(of: clip)
        let l = f.viewModel.layout
        let row = l.rows[0]
        // Five points right of the edge is inside the tolerance.
        let point = CGPoint(x: l.x(for: edge) + 5, y: row.midY)
        f.viewModel.snappingEnabled = true
        let snapped = f.viewModel.dropTarget(at: point)
        #expect(snapped.at == edge)
        #expect(snapped.snappedTo == edge)
        f.viewModel.snappingEnabled = false
        let free = f.viewModel.dropTarget(at: point)
        #expect(free.at != edge)
        #expect(free.snappedTo == nil)
        #expect(abs(free.at.seconds - (edge.seconds + 5 * l.secondsPerPoint)) < 1e-6)
    }

    @Test func mediaTypesAcceptMoviesAudioAndImagesOnly() {
        for ext in ["mov", "mp4", "wav", "m4a", "png"] {
            #expect(MediaFileTypes.isMedia(URL(fileURLWithPath: "/tmp/clip.\(ext)")), "\(ext)")
        }
        for ext in ["txt", "json", "tlproj", ""] {
            #expect(!MediaFileTypes.isMedia(URL(fileURLWithPath: "/tmp/notes.\(ext)")), "\(ext)")
        }
        let urls = [
            URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.mov"), URL(fileURLWithPath: "/tmp/c.wav"),
        ]
        #expect(MediaFileTypes.mediaURLs(urls).map(\.lastPathComponent) == ["b.mov", "c.wav"])
    }

    @Test func indicatorAppearsWhileADragIsOverTheViewAndDisappearsAfterExit() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let l = f.viewModel.layout
        let row = l.rows[0]
        let before = TimelineSceneBuilder.build(from: f.viewModel)
        #expect(!before.overlayQuads.contains { $0.color == TimelineTheme.dropIndicator })
        #expect(f.viewModel.dropTarget == nil)

        f.viewModel.updateDrop(at: CGPoint(x: l.x(forSeconds: 20), y: row.midY))
        #expect(f.viewModel.dropTarget?.trackId == row.trackId)
        let during = TimelineSceneBuilder.build(from: f.viewModel)
        let line = try #require(during.overlayQuads.first { $0.color == TimelineTheme.dropIndicator })
        #expect(abs(line.rect.midX - l.x(forSeconds: 20)) < 1.5)
        let highlight = try #require(during.overlayQuads.first { $0.color == TimelineTheme.dropHighlight })
        #expect(highlight.rect.minY == row.y && highlight.rect.height == row.height)
        #expect(during.triangles.contains { $0.color == TimelineTheme.dropIndicator })

        // Over the ruler: the line, no row highlight.
        f.viewModel.updateDrop(at: CGPoint(x: l.x(forSeconds: 20), y: 10))
        let ruler = TimelineSceneBuilder.build(from: f.viewModel)
        #expect(ruler.overlayQuads.contains { $0.color == TimelineTheme.dropIndicator })
        #expect(!ruler.overlayQuads.contains { $0.color == TimelineTheme.dropHighlight })

        f.viewModel.endDrop()
        #expect(f.viewModel.dropTarget == nil)
        let after = TimelineSceneBuilder.build(from: f.viewModel)
        #expect(!after.overlayQuads.contains { $0.color == TimelineTheme.dropIndicator })
        #expect(!after.overlayQuads.contains { $0.color == TimelineTheme.dropHighlight })
    }

    @Test func droppingHandsMediaToTheCallbackAndClearsTheIndicator() async throws {
        let f = try await UIFixture.make("three-clips")
        f.viewModel.snappingEnabled = false
        let l = f.viewModel.layout
        let row = try #require(l.rows.first { $0.kind == .audio })
        var received: [(urls: [URL], target: TimelineDropTarget)] = []
        f.viewModel.onDropMedia = { urls, target in received.append((urls, target)) }
        let point = CGPoint(x: l.x(forSeconds: 8), y: row.midY)
        f.viewModel.updateDrop(at: point)
        let urls = [
            URL(fileURLWithPath: "/tmp/one.mov"), URL(fileURLWithPath: "/tmp/notes.txt"),
            URL(fileURLWithPath: "/tmp/two.wav"),
        ]
        #expect(f.viewModel.dropMedia(urls, at: point))
        #expect(f.viewModel.dropTarget == nil)
        #expect(received.count == 1)
        #expect(received[0].urls.map(\.lastPathComponent) == ["one.mov", "two.wav"])
        #expect(received[0].target.trackId == row.trackId)
        #expect(abs(received[0].target.at.seconds - 8) < 1e-6)
        // Nothing but text: refused, the callback stays quiet.
        f.viewModel.updateDrop(at: point)
        #expect(!f.viewModel.dropMedia([URL(fileURLWithPath: "/tmp/notes.txt")], at: point))
        #expect(f.viewModel.dropTarget == nil)
        #expect(received.count == 1)
        #expect(await f.receivedCommands.isEmpty)
    }

    @Test func metalViewRegistersForFileDrags() async throws {
        let f = try await UIFixture.make("three-clips")
        let view = TimelineMetalView(viewModel: f.viewModel)
        #expect(view.registeredDraggedTypes.contains(.fileURL))
    }
}
