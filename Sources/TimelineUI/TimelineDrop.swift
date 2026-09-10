import AppKit
import Contracts
import CoreGraphics
import CoreTransferable
import Foundation
import TimelineCore
import UniformTypeIdentifiers

/// Where a file drop lands: the track under the pointer (nil on the ruler, the header column, or the
/// empty area below the tracks, meaning "the first matching track") and the sequence time under the
/// pointer, snapped like a gesture when snapping is on.
public struct TimelineDropTarget: Hashable, Sendable {
    public var trackId: TrackID?
    public var at: RationalTime
    /// The snap target `at` landed on, for the guide line.
    public var snappedTo: RationalTime?

    public init(trackId: TrackID?, at: RationalTime, snappedTo: RationalTime? = nil) {
        self.trackId = trackId
        self.at = at
        self.snappedTo = snappedTo
    }
}

/// The file types a drop accepts: anything whose type conforms to movie, audio, or image.
public enum MediaFileTypes {
    public static let accepted: [UTType] = [.movie, .audio, .image]

    public static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return accepted.contains { type.conforms(to: $0) }
    }

    /// The media files among `urls`, in order.
    public static func mediaURLs(_ urls: [URL]) -> [URL] { urls.filter(isMedia) }

    /// What kind of media a file looks like from its name alone, or nil when it is not media. A guess for
    /// drawing only — the importer's probe is what decides an asset's kind.
    public static func kind(of url: URL) -> AssetKind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        return nil
    }
}

/// One row dragged out of the library panel. It carries what a drop needs to decide without another
/// catalog read — the content hash the open project is checked against, and the project the row came
/// from, so the app knows whether the drop has to duplicate a foreign asset first.
public struct LibraryDragItem: Codable, Hashable, Sendable {
    public var contentHash: String
    public var displayName: String
    public var kind: AssetKind
    public var duration: RationalTime
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var assetId: AssetID?
    public var projectId: ProjectID?
    /// Where the catalog last saw the file; the app re-resolves by hash first.
    public var url: URL?

    public init(
        contentHash: String, displayName: String, kind: AssetKind, duration: RationalTime, hasVideo: Bool,
        hasAudio: Bool, assetId: AssetID? = nil, projectId: ProjectID? = nil, url: URL? = nil
    ) {
        self.contentHash = contentHash
        self.displayName = displayName
        self.kind = kind
        self.duration = duration
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.assetId = assetId
        self.projectId = projectId
        self.url = url
    }

    public init(_ asset: Asset, projectId: ProjectID? = nil, url: URL? = nil) {
        self.init(
            contentHash: asset.contentHash, displayName: asset.displayName, kind: asset.kind,
            duration: asset.duration, hasVideo: asset.hasVideo, hasAudio: asset.hasAudio, assetId: asset.id,
            projectId: projectId, url: url)
    }
}

/// What a library drag puts on the pasteboard. The type is registered dynamically: `TimelineApp` is an
/// SPM executable with no Info.plist to declare it in, and a drag never leaves the process.
public struct LibraryDragPayload: Codable, Hashable, Sendable, Transferable {
    public var items: [LibraryDragItem]

    public init(items: [LibraryDragItem]) { self.items = items }

    public static let typeIdentifier = "com.thegoldenmule.timeline.library-item"
    public static let contentType = UTType(exportedAs: typeIdentifier, conformingTo: .data)
    /// What `TimelineMetalView` registers and reads; the raw type, so nothing depends on `UTType`
    /// conformance resolving at runtime.
    public static let pasteboardType = NSPasteboard.PasteboardType(typeIdentifier)

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType, encoder: ProjectCodec.encoder, decoder: ProjectCodec.decoder)
    }

    public func data() throws -> Data { try ProjectCodec.encode(self) }

    public init(data: Data) throws { self = try ProjectCodec.decode(LibraryDragPayload.self, from: data) }

    /// The rows the drag now in flight is carrying, handed straight across rather than through the
    /// pasteboard.
    ///
    /// Everything registered on an `NSItemProvider` — the payload's bytes and the file URL alike — is
    /// promised through SwiftUI's drag bridge and resolved asynchronously, so a drop reading the
    /// pasteboard gets whatever has arrived by then: sometimes the rows, sometimes an empty `Data`,
    /// sometimes nothing at all. That race is what made dropping a library row flakey. A drag out of the
    /// panel never leaves the process, so `MediaLibraryModel.dragProvider` records the rows here and the
    /// drop targets read them from here; the pasteboard's own copies remain for other applications.
    @MainActor public static var inFlight: LibraryDragPayload?

    /// The library rows a drag is carrying: the ones handed across in-process, else whatever the
    /// pasteboard managed to resolve. Empty when this is not a library drag at all.
    @MainActor public static func items(on pasteboard: NSPasteboard) -> [LibraryDragItem] {
        guard pasteboard.availableType(from: [pasteboardType]) != nil else { return [] }
        if let payload = inFlight, !payload.items.isEmpty { return payload.items }
        guard let data = pasteboard.data(forType: pasteboardType), let payload = try? LibraryDragPayload(data: data)
        else { return [] }
        return payload.items
    }

    /// Called once a drop has taken the rows, so a later drag cannot see them.
    @MainActor public static func endInFlight() { inFlight = nil }
}

extension TimelineViewModel {
    // MARK: Drop targets (the state machine; NSDraggingInfo-free)

    /// The drop target for a view point: the row under `y` (nil on the ruler or below the tracks) and the
    /// time under `x`, snapped to clip edges, markers, the playhead, and zero when snapping is on.
    public func dropTarget(at point: CGPoint) -> TimelineDropTarget {
        let l = layout
        let raw = l.time(atX: point.x)
        let (at, snapped) = snapEdge(raw)
        let trackId = l.isInRuler(point) ? nil : l.row(atY: point.y)?.trackId
        return TimelineDropTarget(trackId: trackId, at: at, snappedTo: snapped)
    }

    /// A drag entered or moved over the view: the scene draws the indicator until `endDrop`.
    public func updateDrop(at point: CGPoint) {
        dropTarget = dropTarget(at: point)
    }

    /// The drag left the view or ended without a drop.
    public func endDrop() {
        dropTarget = nil
    }

    /// Hands the media files among `urls` to `onDropMedia` at the target under `point` and clears the
    /// indicator. False when nothing was media or nobody is listening.
    @discardableResult
    public func dropMedia(_ urls: [URL], at point: CGPoint) -> Bool {
        let target = dropTarget(at: point)
        dropTarget = nil
        let media = MediaFileTypes.mediaURLs(urls)
        guard !media.isEmpty, let onDropMedia else { return false }
        onDropMedia(media, target)
        return true
    }

    /// Hands library rows to `onDropLibraryItems` at the target under `point` and clears the indicator.
    /// False when the payload was empty or nobody is listening.
    @discardableResult
    public func dropLibraryItems(_ items: [LibraryDragItem], at point: CGPoint) -> Bool {
        let target = dropTarget(at: point)
        dropTarget = nil
        guard !items.isEmpty, let onDropLibraryItems else { return false }
        onDropLibraryItems(items, target)
        return true
    }
}
