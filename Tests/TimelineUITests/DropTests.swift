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

/// A drag from the library panel, without AppKit's private dragging session: a real `NSPasteboard` with
/// the types under test, handed to the view's `NSDraggingDestination` methods.
@MainActor
final class FakeDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let pasteboard: NSPasteboard
    var location: CGPoint

    init(pasteboard: NSPasteboard, location: CGPoint) {
        self.pasteboard = pasteboard
        self.location = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set { _ = newValue }
    }
    var animatesToDestination: Bool {
        get { false }
        set { _ = newValue }
    }
    var numberOfValidItemsForDrop: Int {
        get { 1 }
        set { _ = newValue }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

/// Drags out of the library panel take the same path as file drags: the same snapped target, the same
/// indicator, one different callback.
@MainActor
@Suite("Library drags land like file drags")
struct LibraryDropTests {
    private func item(_ name: String = "cam.mov", hash: String = "sha256-cam", project: ProjectID? = "project-2")
        -> LibraryDragItem
    {
        LibraryDragItem(
            contentHash: hash, displayName: name, kind: .video, duration: Fixtures.frames(240), hasVideo: true,
            hasAudio: true, assetId: "asset-cam", projectId: project,
            url: URL(fileURLWithPath: "/tmp/Library/\(name)"))
    }

    /// A pasteboard carrying the given types, named so the tests never touch the general pasteboard.
    private func pasteboard(library: [LibraryDragItem]? = nil, files: [URL] = []) throws -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("timeline-drop-tests-\(UUID().uuidString)"))
        board.clearContents()
        if let library {
            board.setData(try LibraryDragPayload(items: library).data(), forType: LibraryDragPayload.pasteboardType)
        }
        if !files.isEmpty { board.writeObjects(files.map { $0 as NSURL }) }
        return board
    }

    @Test func metalViewRegistersForFileAndLibraryDrags() async throws {
        let f = try await UIFixture.make("three-clips")
        let view = TimelineMetalView(viewModel: f.viewModel)
        #expect(view.registeredDraggedTypes.contains(.fileURL))
        #expect(view.registeredDraggedTypes.contains(LibraryDragPayload.pasteboardType))
        // AppKit reorders the registered list, so precedence is decided by the branch in
        // performDragOperation, not by registration order (aDragCarryingBothTypesIsTreatedAsALibraryDrag).
    }

    @Test func droppingLibraryItemsHandsThemToTheCallbackAtTheSnappedTarget() async throws {
        let f = try await UIFixture.make("three-clips")
        let clip = f.clips(.video)[1]
        let edge = f.sequence.end(of: clip)
        let l = f.viewModel.layout
        let row = l.rows[0]
        var received: [(items: [LibraryDragItem], target: TimelineDropTarget)] = []
        f.viewModel.onDropLibraryItems = { items, target in received.append((items, target)) }

        let point = CGPoint(x: l.x(for: edge) + 5, y: row.midY)
        f.viewModel.updateDrop(at: point)
        #expect(f.viewModel.dropLibraryItems([item(), item("band.wav")], at: point))
        #expect(f.viewModel.dropTarget == nil)
        #expect(received.count == 1)
        #expect(received[0].items.map(\.displayName) == ["cam.mov", "band.wav"])
        #expect(received[0].items[0].projectId == "project-2")
        #expect(received[0].items[0].contentHash == "sha256-cam")
        // Snapped exactly like a file drag, on the row under the pointer.
        #expect(received[0].target.trackId == row.trackId)
        #expect(received[0].target.at == edge)
        #expect(received[0].target.snappedTo == edge)
        // A library drop is not an edit by itself: the app decides what to apply.
        #expect(await f.receivedCommands.isEmpty)
    }

    @Test func aLibraryDragDrawsTheSameIndicatorAsAFileDrag() async throws {
        let f = try await UIFixture.make("three-clips")
        let view = TimelineMetalView(viewModel: f.viewModel)
        let l = f.viewModel.layout
        let point = CGPoint(x: l.x(forSeconds: 20), y: l.rows[0].midY)

        let files = FakeDraggingInfo(
            pasteboard: try pasteboard(files: [URL(fileURLWithPath: "/tmp/one.mov")]), location: point)
        #expect(view.draggingEntered(files) == .copy)
        let fileScene = TimelineSceneBuilder.build(from: f.viewModel)
        let fileTarget = f.viewModel.dropTarget
        view.draggingExited(files)

        let library = FakeDraggingInfo(pasteboard: try pasteboard(library: [item()]), location: point)
        #expect(view.draggingEntered(library) == .copy)
        let libraryScene = TimelineSceneBuilder.build(from: f.viewModel)
        #expect(f.viewModel.dropTarget == fileTarget)
        #expect(
            libraryScene.overlayQuads.filter { $0.color == TimelineTheme.dropIndicator }
                == fileScene.overlayQuads.filter { $0.color == TimelineTheme.dropIndicator })
        #expect(
            libraryScene.overlayQuads.filter { $0.color == TimelineTheme.dropHighlight }
                == fileScene.overlayQuads.filter { $0.color == TimelineTheme.dropHighlight })

        // Nothing either branch accepts: no operation, no indicator.
        let text = FakeDraggingInfo(
            pasteboard: try pasteboard(files: [URL(fileURLWithPath: "/tmp/notes.txt")]), location: point)
        #expect(view.draggingUpdated(text) == [])
        #expect(f.viewModel.dropTarget == nil)
    }

    /// The in-process handoff: the pasteboard's copy of the rows is empty (promised, unresolved) and the
    /// rows still land, because the panel handed them across directly. Without it the drop fell back to
    /// the file URL — or to nothing at all when that had not resolved either, which is what made dropping
    /// a library row flakey.
    @Test func rowsHandedAcrossInProcessLandEvenWhenThePasteboardIsEmpty() async throws {
        let f = try await UIFixture.make("three-clips")
        let view = TimelineMetalView(viewModel: f.viewModel)
        let l = f.viewModel.layout
        let point = CGPoint(x: l.x(forSeconds: 20), y: l.rows[0].midY)
        var libraryDrops: [[LibraryDragItem]] = []
        var fileDrops: [[URL]] = []
        f.viewModel.onDropLibraryItems = { items, _ in libraryDrops.append(items) }
        f.viewModel.onDropMedia = { urls, _ in fileDrops.append(urls) }

        let board = try pasteboard(files: [URL(fileURLWithPath: "/tmp/one.mov")])
        board.setData(Data(), forType: LibraryDragPayload.pasteboardType)
        LibraryDragPayload.inFlight = LibraryDragPayload(items: [item("cam.mov")])
        defer { LibraryDragPayload.endInFlight() }

        let sender = FakeDraggingInfo(pasteboard: board, location: point)
        #expect(view.draggingEntered(sender) == .copy)
        #expect(view.performDragOperation(sender))
        #expect(libraryDrops.map { $0.map(\.displayName) } == [["cam.mov"]])
        #expect(fileDrops.isEmpty)
        // The drop consumed them, so a later drag cannot pick up the same rows.
        #expect(LibraryDragPayload.inFlight == nil)
    }

    /// What a real drag out of the panel looks like: the library type is on the pasteboard but its bytes
    /// arrive empty (SwiftUI promises them through the provider bridge and resolves them asynchronously),
    /// so the file URL the drag also carries is what has to land. Taking the library branch on the type
    /// alone inserted nothing — the indicator lit up and the clip never appeared.
    @Test func aDragWhoseRowsArriveEmptyLandsAsAFileDrop() async throws {
        let f = try await UIFixture.make("three-clips")
        let view = TimelineMetalView(viewModel: f.viewModel)
        let l = f.viewModel.layout
        let point = CGPoint(x: l.x(forSeconds: 20), y: l.rows[0].midY)
        var libraryDrops: [[LibraryDragItem]] = []
        var fileDrops: [[URL]] = []
        f.viewModel.onDropLibraryItems = { items, _ in libraryDrops.append(items) }
        f.viewModel.onDropMedia = { urls, _ in fileDrops.append(urls) }

        let board = try pasteboard(files: [URL(fileURLWithPath: "/tmp/one.mov")])
        board.setData(Data(), forType: LibraryDragPayload.pasteboardType)
        #expect(board.data(forType: LibraryDragPayload.pasteboardType)?.isEmpty == true)
        let sender = FakeDraggingInfo(pasteboard: board, location: point)
        #expect(view.draggingEntered(sender) == .copy)
        #expect(view.performDragOperation(sender))
        #expect(libraryDrops.isEmpty)
        #expect(fileDrops.map { $0.map(\.lastPathComponent) } == [["one.mov"]])
    }

    @Test func aDragCarryingBothTypesIsTreatedAsALibraryDrag() async throws {
        let f = try await UIFixture.make("three-clips")
        let view = TimelineMetalView(viewModel: f.viewModel)
        let l = f.viewModel.layout
        let point = CGPoint(x: l.x(forSeconds: 20), y: l.rows[0].midY)
        var libraryDrops: [[LibraryDragItem]] = []
        var fileDrops: [[URL]] = []
        f.viewModel.onDropLibraryItems = { items, _ in libraryDrops.append(items) }
        f.viewModel.onDropMedia = { urls, _ in fileDrops.append(urls) }

        let board = try pasteboard(library: [item()], files: [URL(fileURLWithPath: "/tmp/one.mov")])
        let sender = FakeDraggingInfo(pasteboard: board, location: point)
        #expect(view.draggingEntered(sender) == .copy)
        #expect(view.performDragOperation(sender))
        #expect(libraryDrops.map { $0.map(\.displayName) } == [["cam.mov"]])
        #expect(fileDrops.isEmpty)
    }

    @Test func anEmptyLibraryPayloadIsRefusedAndLeavesNoIndicator() async throws {
        let f = try await UIFixture.make("three-clips")
        let view = TimelineMetalView(viewModel: f.viewModel)
        let l = f.viewModel.layout
        let point = CGPoint(x: l.x(forSeconds: 20), y: l.rows[0].midY)
        var libraryDrops: [[LibraryDragItem]] = []
        f.viewModel.onDropLibraryItems = { items, _ in libraryDrops.append(items) }

        #expect(!f.viewModel.dropLibraryItems([], at: point))
        #expect(f.viewModel.dropTarget == nil)
        #expect(libraryDrops.isEmpty)

        let sender = FakeDraggingInfo(pasteboard: try pasteboard(library: []), location: point)
        #expect(view.draggingEntered(sender) == [])
        #expect(!view.performDragOperation(sender))
        #expect(f.viewModel.dropTarget == nil)
        #expect(libraryDrops.isEmpty)
        #expect(await f.receivedCommands.isEmpty)
    }
}
