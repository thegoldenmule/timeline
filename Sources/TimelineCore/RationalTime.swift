import Foundation

/// A rational number used for speed factors and ratios. Denominator is always positive.
/// Encodes as `{ "num": Int64, "den": Int64 }`.
public struct Rational: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var num: Int64
    public var den: Int64

    public init(_ num: Int64, _ den: Int64) {
        precondition(den != 0, "Rational denominator must be non-zero")
        if den < 0 {
            self.num = -num
            self.den = -den
        } else {
            self.num = num
            self.den = den
        }
    }

    public init(num: Int64, den: Int64) { self.init(num, den) }

    public static let one = Rational(1, 1)
    public static let zero = Rational(0, 1)

    public var doubleValue: Double { Double(num) / Double(den) }
    public var isPositive: Bool { num > 0 }
    public var inverse: Rational { Rational(den, num) }

    public var reduced: Rational {
        let g = gcd(num.magnitude, den.magnitude)
        guard g > 1 else { return self }
        return Rational(num / Int64(g), den / Int64(g))
    }

    public var description: String { "\(num)/\(den)" }

    public static func == (lhs: Rational, rhs: Rational) -> Bool {
        Int128(lhs.num) * Int128(rhs.den) == Int128(rhs.num) * Int128(lhs.den)
    }

    public static func < (lhs: Rational, rhs: Rational) -> Bool {
        Int128(lhs.num) * Int128(rhs.den) < Int128(rhs.num) * Int128(lhs.den)
    }

    public func hash(into hasher: inout Hasher) {
        let r = reduced
        hasher.combine(r.num)
        hasher.combine(r.den)
    }

    public static func * (lhs: Rational, rhs: Rational) -> Rational {
        Rational.make(Int128(lhs.num) * Int128(rhs.num), Int128(lhs.den) * Int128(rhs.den))
    }

    public static func / (lhs: Rational, rhs: Rational) -> Rational { lhs * rhs.inverse }

    static func make(_ num: Int128, _ den: Int128) -> Rational {
        precondition(den != 0)
        let g = Int128(gcd(num.magnitude, den.magnitude))
        let n = g > 1 ? num / g : num
        let d = g > 1 ? den / g : den
        precondition(n >= Int128(Int64.min) && n <= Int128(Int64.max) && d <= Int128(Int64.max), "Rational overflow")
        return Rational(Int64(n), Int64(d))
    }

    enum CodingKeys: String, CodingKey {
        case num
        case den
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let num = try c.decode(Int64.self, forKey: .num)
        let den = try c.decode(Int64.self, forKey: .den)
        guard den > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .den, in: c, debugDescription: "den must be positive")
        }
        self.init(num, den)
    }
}

/// `CMTime` without flags: an exact rational number of seconds. Arithmetic never rounds; mixed
/// timescales are combined at their least common multiple (or, if that does not fit `Int32`, at
/// the fully reduced fraction). Comparison cross-multiplies in 128 bits. Encodes as `{ "v", "ts" }`.
public struct RationalTime: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        precondition(timescale > 0, "RationalTime timescale must be positive")
        self.value = value
        self.timescale = timescale
    }

    public init(_ value: Int64, _ timescale: Int32) { self.init(value: value, timescale: timescale) }

    /// Rounds `seconds` to the nearest unit of `timescale`. Display and test convenience only.
    public init(seconds: Double, timescale: Int32 = 48000) {
        self.init(value: Int64((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    public static let zero = RationalTime(value: 0, timescale: 1)

    /// Display only; never use for arithmetic or comparison.
    public var seconds: Double { Double(value) / Double(timescale) }
    public var isZero: Bool { value == 0 }
    public var isNegative: Bool { value < 0 }
    public var isPositive: Bool { value > 0 }
    public var description: String { "\(value)/\(timescale)" }

    public var reduced: RationalTime {
        let g = gcd(value.magnitude, UInt64(timescale))
        guard g > 1 else { return self }
        return RationalTime(value: value / Int64(g), timescale: Int32(Int64(timescale) / Int64(g)))
    }

    /// The same instant expressed at `timescale`, or nil if that is not exact.
    public func rescaled(to timescale: Int32) -> RationalTime? {
        precondition(timescale > 0)
        if timescale == self.timescale { return self }
        let num = Int128(value) * Int128(timescale)
        let den = Int128(self.timescale)
        guard num % den == 0 else { return nil }
        let v = num / den
        guard v >= Int128(Int64.min) && v <= Int128(Int64.max) else { return nil }
        return RationalTime(value: Int64(v), timescale: timescale)
    }

    // MARK: Equality and ordering

    public static func == (lhs: RationalTime, rhs: RationalTime) -> Bool {
        if lhs.timescale == rhs.timescale { return lhs.value == rhs.value }
        return Int128(lhs.value) * Int128(rhs.timescale) == Int128(rhs.value) * Int128(lhs.timescale)
    }

    public static func < (lhs: RationalTime, rhs: RationalTime) -> Bool {
        if lhs.timescale == rhs.timescale { return lhs.value < rhs.value }
        return Int128(lhs.value) * Int128(rhs.timescale) < Int128(rhs.value) * Int128(lhs.timescale)
    }

    public func hash(into hasher: inout Hasher) {
        let r = reduced
        hasher.combine(r.value)
        hasher.combine(r.timescale)
    }

    // MARK: Arithmetic

    /// Builds the exact value `num/den`, preferring `preferredTimescale` when the value is
    /// representable there, then the reduced fraction. Traps if the exact value cannot be
    /// represented at all, which does not happen for the timescales media uses.
    static func make(_ num: Int128, _ den: Int128, preferredTimescale: Int32? = nil) -> RationalTime {
        precondition(den > 0)
        if let ts = preferredTimescale {
            let scaled = num * Int128(ts)
            if scaled % den == 0 {
                let v = scaled / den
                if v >= Int128(Int64.min) && v <= Int128(Int64.max) {
                    return RationalTime(value: Int64(v), timescale: ts)
                }
            }
        }
        let g = Int128(gcd(num.magnitude, den.magnitude))
        let n = g > 1 ? num / g : num
        let d = g > 1 ? den / g : den
        precondition(
            n >= Int128(Int64.min) && n <= Int128(Int64.max) && d <= Int128(Int32.max),
            "RationalTime \(num)/\(den) is not representable exactly")
        return RationalTime(value: Int64(n), timescale: Int32(d))
    }

    private static func combine(_ lhs: RationalTime, _ rhs: RationalTime, _ op: (Int128, Int128) -> Int128)
        -> RationalTime
    {
        if lhs.timescale == rhs.timescale {
            let v = op(Int128(lhs.value), Int128(rhs.value))
            precondition(v >= Int128(Int64.min) && v <= Int128(Int64.max), "RationalTime overflow")
            return RationalTime(value: Int64(v), timescale: lhs.timescale)
        }
        let l = lcm(UInt64(lhs.timescale), UInt64(rhs.timescale))
        if l <= UInt64(Int32.max) {
            let ts = Int32(l)
            let lv = Int128(lhs.value) * Int128(l / UInt64(lhs.timescale))
            let rv = Int128(rhs.value) * Int128(l / UInt64(rhs.timescale))
            let v = op(lv, rv)
            precondition(v >= Int128(Int64.min) && v <= Int128(Int64.max), "RationalTime overflow")
            return RationalTime(value: Int64(v), timescale: ts)
        }
        let num = op(Int128(lhs.value) * Int128(rhs.timescale), Int128(rhs.value) * Int128(lhs.timescale))
        return make(num, Int128(lhs.timescale) * Int128(rhs.timescale))
    }

    public static func + (lhs: RationalTime, rhs: RationalTime) -> RationalTime { combine(lhs, rhs, +) }
    public static func - (lhs: RationalTime, rhs: RationalTime) -> RationalTime { combine(lhs, rhs, -) }
    public static func += (lhs: inout RationalTime, rhs: RationalTime) { lhs = lhs + rhs }
    public static func -= (lhs: inout RationalTime, rhs: RationalTime) { lhs = lhs - rhs }
    public static prefix func - (t: RationalTime) -> RationalTime {
        RationalTime(value: -t.value, timescale: t.timescale)
    }

    public static func * (lhs: RationalTime, rhs: Int64) -> RationalTime {
        make(Int128(lhs.value) * Int128(rhs), Int128(lhs.timescale), preferredTimescale: lhs.timescale)
    }

    public static func / (lhs: RationalTime, rhs: Int64) -> RationalTime {
        precondition(rhs != 0)
        let sign: Int128 = rhs < 0 ? -1 : 1
        return make(
            Int128(lhs.value) * sign, Int128(lhs.timescale) * Int128(rhs.magnitude),
            preferredTimescale: lhs.timescale)
    }

    /// Scales a duration by a speed-like factor: `t * (num/den)`.
    public static func * (lhs: RationalTime, rhs: Rational) -> RationalTime {
        precondition(rhs.den > 0)
        return make(
            Int128(lhs.value) * Int128(rhs.num), Int128(lhs.timescale) * Int128(rhs.den),
            preferredTimescale: lhs.timescale)
    }

    /// Divides a duration by a speed-like factor: `t / (num/den)`.
    public static func / (lhs: RationalTime, rhs: Rational) -> RationalTime {
        precondition(rhs.num != 0)
        return lhs * rhs.inverse
    }

    /// The exact ratio `self / other` as a `Rational`.
    public func ratio(to other: RationalTime) -> Rational {
        precondition(other.value != 0)
        return Rational.make(Int128(value) * Int128(other.timescale), Int128(other.value) * Int128(timescale))
    }

    // MARK: Frame snapping

    /// `self / frameDuration` as an exact fraction (numerator, positive denominator).
    private func frameFraction(_ frameDuration: RationalTime) -> (num: Int128, den: Int128) {
        precondition(frameDuration.isPositive, "frameDuration must be positive")
        return (Int128(value) * Int128(frameDuration.timescale), Int128(frameDuration.value) * Int128(timescale))
    }

    /// Whole frames from zero, rounding down (toward negative infinity).
    public func frameIndex(frameDuration: RationalTime) -> Int64 {
        let (n, d) = frameFraction(frameDuration)
        return Int64(floorDiv(n, d))
    }

    /// True when `self` is an exact multiple of `frameDuration`.
    public func isFrameAligned(frameDuration: RationalTime) -> Bool {
        let (n, d) = frameFraction(frameDuration)
        return n % d == 0
    }

    /// Nearest multiple of `frameDuration` (halves round up), expressed at `frameDuration`'s timescale.
    public func snapped(to frameDuration: RationalTime) -> RationalTime {
        let (n, d) = frameFraction(frameDuration)
        let frames = floorDiv(2 * n + d, 2 * d)
        return RationalTime.frames(Int64(frames), of: frameDuration)
    }

    /// Largest multiple of `frameDuration` that is `<= self`.
    public func floored(to frameDuration: RationalTime) -> RationalTime {
        RationalTime.frames(frameIndex(frameDuration: frameDuration), of: frameDuration)
    }

    /// Smallest multiple of `frameDuration` that is `>= self`.
    public func ceiled(to frameDuration: RationalTime) -> RationalTime {
        let (n, d) = frameFraction(frameDuration)
        let frames = -floorDiv(-n, d)
        return RationalTime.frames(Int64(frames), of: frameDuration)
    }

    /// `count` frames of `frameDuration`, at `frameDuration`'s timescale.
    public static func frames(_ count: Int64, of frameDuration: RationalTime) -> RationalTime {
        let v = Int128(frameDuration.value) * Int128(count)
        precondition(v >= Int128(Int64.min) && v <= Int128(Int64.max), "RationalTime overflow")
        return RationalTime(value: Int64(v), timescale: frameDuration.timescale)
    }

    // MARK: Codable as { "v": Int64, "ts": Int32 }

    enum CodingKeys: String, CodingKey {
        case value = "v"
        case timescale = "ts"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int64.self, forKey: .value)
        let ts = try c.decode(Int32.self, forKey: .timescale)
        guard ts > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .timescale, in: c, debugDescription: "ts must be positive")
        }
        self.init(value: v, timescale: ts)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(timescale, forKey: .timescale)
    }
}

extension RationalTime {
    /// The larger of two times.
    public static func max(_ a: RationalTime, _ b: RationalTime) -> RationalTime { a < b ? b : a }
    /// The smaller of two times.
    public static func min(_ a: RationalTime, _ b: RationalTime) -> RationalTime { a < b ? a : b }
}

// MARK: - Integer helpers

func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
    var (x, y) = (a, b)
    while y != 0 { (x, y) = (y, x % y) }
    return x
}

func gcd(_ a: UInt128, _ b: UInt128) -> UInt128 {
    var (x, y) = (a, b)
    while y != 0 { (x, y) = (y, x % y) }
    return x
}

func lcm(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let g = gcd(a, b)
    let (q, overflow) = (a / g).multipliedReportingOverflow(by: b)
    return overflow ? UInt64.max : q
}

/// Floor division for signed 128-bit values (`d` must be positive).
func floorDiv(_ n: Int128, _ d: Int128) -> Int128 {
    precondition(d > 0)
    let q = n / d
    return (n % d != 0 && n < 0) ? q - 1 : q
}
