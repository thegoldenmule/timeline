import Contracts
import CoreGraphics
import Foundation
import TimelineCore

/// Poster frames for the library panel's rows, on the same contract as `TimelineMediaCache`: a miss
/// returns nil, starts one deduplicated fetch, stores the image, and calls `onUpdate` so the list
/// redraws; entries evict oldest-first past `capacity`. The provider is the timeline's own
/// `ThumbnailProvider`, so a row over media the timeline has already drawn is served from the
/// content-addressed sprite sheets in `Cache/` and costs nothing.
@MainActor
public final class LibraryThumbnailCache {
    /// The poster identity: content hash, frame, and height, so the same file at the same row height is
    /// fetched once however many projects list it.
    public struct Key: Hashable, Sendable {
        public var contentHash: String
        public var time: RationalTime
        public var height: Int
    }

    /// The frame a poster is taken from: the midpoint, but never later than a second in, so a long clip
    /// does not seek far and the key stays the same across launches.
    public static let maximumPosterTime = RationalTime(1, 1)

    public static func posterTime(for duration: RationalTime) -> RationalTime {
        duration.isPositive ? RationalTime.min(duration / 2, maximumPosterTime) : .zero
    }

    public let thumbnails: (any ThumbnailProvider)?
    public let capacity: Int
    /// Called on the main actor after every completed fetch.
    public var onUpdate: (@MainActor () -> Void)?

    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var tasks: [Key: Task<Void, Never>] = [:]
    /// Keys whose fetch came back empty. Without this a row that has no picture to show starts a fresh
    /// fetch on every single redraw, for as long as it is on screen.
    private var failed: Set<Key> = []
    public private(set) var fetchCount = 0
    public private(set) var failedCount = 0

    public init(thumbnails: (any ThumbnailProvider)?, capacity: Int = 256) {
        self.thumbnails = thumbnails
        self.capacity = capacity
    }

    public var pendingCount: Int { tasks.count }
    public var count: Int { images.count }

    /// The poster for a row, or nil (with a fetch in flight) on a miss. Audio never reaches the
    /// provider: there is no picture to take, and the row draws a symbol instead.
    public func poster(for media: MediaReference, kind: AssetKind, duration: RationalTime, height: Int = 36)
        -> CGImage?
    {
        guard kind != .audio else { return nil }
        let key = Key(
            contentHash: media.contentHash, time: LibraryThumbnailCache.posterTime(for: duration), height: height)
        if let image = images[key] { return image }
        guard let provider = thumbnails, tasks[key] == nil, !failed.contains(key) else { return nil }
        fetchCount += 1
        tasks[key] = Task { @MainActor [weak self] in
            let thumbnail = try? await provider.thumbnail(for: media, at: key.time, height: height)
            guard let self else { return }
            if let thumbnail {
                self.store(thumbnail.image, for: key)
            } else {
                self.failedCount += 1
                self.failed.insert(key)
            }
            self.tasks[key] = nil
            self.onUpdate?()
        }
        return nil
    }

    private func store(_ image: CGImage, for key: Key) {
        if images[key] == nil { order.append(key) }
        images[key] = image
        while images.count > capacity, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
    }

    /// Waits for every fetch in flight (tests).
    public func drain() async {
        while pendingCount > 0 {
            for task in Array(tasks.values) { await task.value }
        }
    }

    public func clear() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        images = [:]
        order = []
        failed = []
    }
}
