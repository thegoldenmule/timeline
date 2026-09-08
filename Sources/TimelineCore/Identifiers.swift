import Foundation

/// Marker for a `TypedID` family. Each entity kind gets its own tag so ids cannot be mixed up.
public protocol IDTag: Sendable {
    /// Short human-readable name used in errors, e.g. "clip".
    static var kind: String { get }
}

/// A lowercase UUID string carrying the kind of entity it names. Encodes as a plain JSON string.
public struct TypedID<Tag: IDTag>: Hashable, Comparable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible, CodingKeyRepresentable
{
    public var rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// Mints a fresh id from `generator`.
    public init(minting generator: any IDGenerator) { self.rawValue = generator.next() }

    public static var kind: String { Tag.kind }
    public var description: String { rawValue }

    public static func < (lhs: TypedID<Tag>, rhs: TypedID<Tag>) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    // CodingKeyRepresentable lets dictionaries keyed by ids encode as JSON objects.
    public var codingKey: any CodingKey { IDCodingKey(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) { rawValue = codingKey.stringValue }
}

struct IDCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

public enum ProjectTag: IDTag { public static let kind = "project" }
public enum AssetTag: IDTag { public static let kind = "asset" }
public enum SequenceTag: IDTag { public static let kind = "sequence" }
public enum TrackTag: IDTag { public static let kind = "track" }
public enum ClipTag: IDTag { public static let kind = "clip" }
public enum TransitionTag: IDTag { public static let kind = "transition" }
public enum LinkGroupTag: IDTag { public static let kind = "linkGroup" }
public enum MarkerTag: IDTag { public static let kind = "marker" }
public enum EffectTag: IDTag { public static let kind = "effect" }
public enum TransactionTag: IDTag { public static let kind = "transaction" }
public enum CommandTag: IDTag { public static let kind = "command" }
public enum EventTag: IDTag { public static let kind = "event" }

public typealias ProjectID = TypedID<ProjectTag>
public typealias AssetID = TypedID<AssetTag>
public typealias SequenceID = TypedID<SequenceTag>
public typealias TrackID = TypedID<TrackTag>
public typealias ClipID = TypedID<ClipTag>
public typealias TransitionID = TypedID<TransitionTag>
public typealias LinkGroupID = TypedID<LinkGroupTag>
public typealias MarkerID = TypedID<MarkerTag>
public typealias EffectID = TypedID<EffectTag>
public typealias TransactionID = TypedID<TransactionTag>
public typealias CommandID = TypedID<CommandTag>
public typealias EventID = TypedID<EventTag>

// MARK: - Generators

/// Mints id strings. Implementations must be safe to call from any thread.
public protocol IDGenerator: Sendable {
    func next() -> String
}

/// RFC 9562 UUIDv7: 48-bit Unix millisecond timestamp, version 7, variant 10, 12 bits of
/// monotonic counter (`rand_a`), 62 random bits. Monotonic within the process: ids minted in the
/// same millisecond increment the counter, and a counter overflow borrows the next millisecond.
public final class UUIDv7Generator: IDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var lastMillis: UInt64 = 0
    private var counter: UInt16 = 0

    public init() {}

    public func next() -> String {
        var random = SystemRandomNumberGenerator()
        let nowMillis = UInt64(Date().timeIntervalSince1970 * 1000)
        lock.lock()
        var millis = nowMillis
        if millis <= lastMillis {
            millis = lastMillis
            if counter == 0x0FFF {
                millis += 1
                counter = UInt16(random.next() & 0x07FF)
            } else {
                counter += 1
            }
        } else {
            counter = UInt16(random.next() & 0x07FF)
        }
        lastMillis = millis
        let seq = counter
        lock.unlock()
        let randB = random.next() & 0x3FFF_FFFF_FFFF_FFFF
        return UUIDv7Generator.format(millis: millis, randA: seq, randB: randB)
    }

    static func format(millis: UInt64, randA: UInt16, randB: UInt64) -> String {
        let hi = (millis & 0xFFFF_FFFF_FFFF) << 16 | 0x7000 | UInt64(randA & 0x0FFF)
        let lo = 0x8000_0000_0000_0000 | (randB & 0x3FFF_FFFF_FFFF_FFFF)
        return formatUUID(hi: hi, lo: lo)
    }
}

/// Deterministic ids for tests: `00000000-0000-7000-8000-000000000001`, `...0002`, and so on.
/// They are valid-looking, sort in mint order, and carry an optional prefix nibble set so several
/// generators in one test can be told apart.
public final class SequentialIDGenerator: IDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64
    private let millis: UInt64

    /// - Parameters:
    ///   - start: first counter value.
    ///   - millis: 48-bit timestamp field placed in the id (defaults to zero).
    public init(start: UInt64 = 1, millis: UInt64 = 0) {
        counter = start
        self.millis = millis & 0xFFFF_FFFF_FFFF
    }

    public func next() -> String {
        lock.lock()
        let n = counter
        counter += 1
        lock.unlock()
        return UUIDv7Generator.format(millis: millis, randA: UInt16(n >> 48 & 0x0FFF), randB: n & 0xFFFF_FFFF_FFFF)
    }
}

private func formatUUID(hi: UInt64, lo: UInt64) -> String {
    let h = hex(hi, width: 16)
    let l = hex(lo, width: 16)
    let a = h.prefix(8)
    let b = h.dropFirst(8).prefix(4)
    let c = h.dropFirst(12)
    let d = l.prefix(4)
    let e = l.dropFirst(4)
    return "\(a)-\(b)-\(c)-\(d)-\(e)"
}

private func hex(_ value: UInt64, width: Int) -> String {
    let s = String(value, radix: 16)
    return String(repeating: "0", count: Swift.max(0, width - s.count)) + s
}

extension String {
    /// True for a canonical lowercase UUID string (8-4-4-4-12 hex digits).
    public var isCanonicalUUID: Bool {
        let parts = split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return parts.allSatisfy { $0.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) } }
    }
}

// MARK: - Clock

/// Source of wall-clock time for event timestamps. Inject `FixedClock` in tests.
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Returns a fixed date, optionally advancing by `step` per call so events remain ordered.
public final class FixedClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private let step: TimeInterval

    public init(_ date: Date = Date(timeIntervalSince1970: 1_788_825_600), step: TimeInterval = 0) {
        current = date
        self.step = step
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let d = current
        current = current.addingTimeInterval(step)
        return d
    }
}
