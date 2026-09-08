import Contracts
import CoreMedia
import Foundation
import TimelineCore

// `RationalTime` <-> `CMTime` lives here, not in TimelineCore (conventions.md: TimelineCore is Foundation only).

extension CMTime {
    /// The same instant, exactly: `RationalTime` is `CMTime` without flags.
    public init(_ time: RationalTime) {
        self.init(value: time.value, timescale: time.timescale)
    }
}

extension RationalTime {
    /// Traps on a non-numeric `CMTime`; use `init?(exactly:)` when the time may be invalid or indefinite.
    public init(_ time: CMTime) {
        precondition(time.isNumeric && time.timescale > 0, "RationalTime needs a numeric CMTime, got \(time)")
        self.init(value: time.value, timescale: time.timescale)
    }

    /// Nil for invalid, indefinite, and infinite times.
    public init?(exactly time: CMTime) {
        guard time.isNumeric, time.timescale > 0 else { return nil }
        self.init(value: time.value, timescale: time.timescale)
    }
}

extension CMTimeRange {
    public init(_ range: TimeRange) {
        self.init(start: CMTime(range.start), end: CMTime(range.end))
    }
}

extension TimeRange {
    public init?(exactly range: CMTimeRange) {
        guard let start = RationalTime(exactly: range.start), let end = RationalTime(exactly: range.end) else {
            return nil
        }
        self.init(start: start, end: end)
    }
}

/// Milliseconds between two instants, for the latency log.
func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant = .now) -> Double {
    let d = end - start
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
