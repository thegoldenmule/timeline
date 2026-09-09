import Contracts
import CoreGraphics
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
}
