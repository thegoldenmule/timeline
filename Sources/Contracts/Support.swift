import Foundation
import Synchronization
import TimelineCore

/// Fan-out of values to any number of `AsyncStream` subscribers. Every `subscribe()` returns a fresh
/// stream that yields values sent after the call; buffering is unbounded so a slow consumer never
/// drops a change. Actors expose it through a `nonisolated` property so a subscriber never has to hop
/// onto the actor to start listening.
public final class Broadcaster<Element: Sendable>: Sendable {
    private struct State {
        var next = 0
        var continuations: [Int: AsyncStream<Element>.Continuation] = [:]
        var finished = false
    }

    private let state = Mutex(State())

    public init() {}

    /// A stream of every element sent after this call.
    public func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .unbounded)
        let id: Int? = state.withLock { s in
            guard !s.finished else { return nil }
            let id = s.next
            s.next += 1
            s.continuations[id] = continuation
            return id
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    public func send(_ element: Element) {
        let targets = state.withLock { Array($0.continuations.values) }
        for c in targets { c.yield(element) }
    }

    /// Ends every current and future stream.
    public func finish() {
        let targets: [AsyncStream<Element>.Continuation] = state.withLock { s in
            s.finished = true
            let all = Array(s.continuations.values)
            s.continuations.removeAll()
            return all
        }
        for c in targets { c.finish() }
    }

    public var subscriberCount: Int { state.withLock { $0.continuations.count } }
}

/// A dependency-free stable hash for cache keys and fingerprints: FNV-1a over bytes, rendered as
/// 16 hex digits. It is a fingerprint, not a content hash; MediaKit's `contentHash` is SHA-256.
public enum StableHash {
    public static func fnv1a(_ data: Data) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }

    public static func fnv1a(_ string: String) -> String { fnv1a(Data(string.utf8)) }

    /// Fingerprint of any encodable value through the canonical project codec (sorted keys), so equal
    /// values hash equal regardless of construction order.
    public static func fnv1a<T: Encodable>(encoding value: T) throws -> String {
        try fnv1a(ProjectCodec.encoder.encode(value))
    }
}

/// A half-open time range `[start, end)` on a media or timeline clock.
public struct TimeRange: Hashable, Sendable, Codable {
    public var start: RationalTime
    public var end: RationalTime

    public init(start: RationalTime, end: RationalTime) {
        self.start = start
        self.end = end
    }

    public var duration: RationalTime { end - start }
    public func contains(_ t: RationalTime) -> Bool { t >= start && t < end }
}
