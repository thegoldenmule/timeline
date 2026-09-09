import Contracts
import Foundation
import TimelineCore

/// A cue in whole milliseconds, the resolution SRT and WebVTT carry.
struct TimedCue: Hashable, Sendable {
    var startMs: Int64
    var endMs: Int64
    var text: String
}

/// Turns timeline cues into millisecond cues the writers can print: sorted by start, blank texts
/// dropped, `end > start` enforced (a one-millisecond cue at least), and a cue that starts inside the
/// previous one nudged to begin one millisecond after it ends (touching cues are left alone).
enum CaptionTiming {
    static func normalize(_ cues: [CaptionCue]) -> [TimedCue] {
        var result: [TimedCue] = []
        let sorted = cues.sorted { a, b in a.start != b.start ? a.start < b.start : a.end < b.end }
        for cue in sorted {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var start = milliseconds(cue.start)
            var end = milliseconds(cue.end)
            if let previous = result.last, start < previous.endMs { start = previous.endMs + 1 }
            if end <= start { end = start + 1 }
            result.append(TimedCue(startMs: start, endMs: end, text: text))
        }
        return result
    }

    static func milliseconds(_ time: RationalTime) -> Int64 {
        let scaled = Int128(time.value) * 1000 / Int128(time.timescale)
        return Int64(clamping: max(0, scaled))
    }

    /// `HH:MM:SS<separator>mmm`.
    static func timestamp(_ ms: Int64, separator: String) -> String {
        let hours = ms / 3_600_000
        let minutes = ms % 3_600_000 / 60_000
        let seconds = ms % 60_000 / 1000
        let millis = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, separator, millis)
    }
}
