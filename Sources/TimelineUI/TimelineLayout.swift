import CoreGraphics
import Foundation
import TimelineCore

/// Seconds per point at each zoom level, widest first. Six levels, from about an hour across the
/// view down to a few frames per point.
public enum ZoomLevel {
    public static let secondsPerPoint: [Double] = [4.0, 1.0, 0.25, 0.05, 0.01, 0.002]
    public static var count: Int { secondsPerPoint.count }
    public static let defaultIndex = 3
}

/// The buttons every track header carries, in the order they are drawn and hit tested.
public enum TrackControl: String, Hashable, Sendable, CaseIterable {
    case mute
    case solo
    case lock
    case remove

    /// The single capital the scene draws in the button. Capitals of similar width, because the scene
    /// builder centres them with a fixed offset and has no font metrics.
    public var glyph: String {
        switch self {
        case .mute: "M"
        case .solo: "S"
        case .lock: "L"
        case .remove: "X"
        }
    }
}

/// One row of the track area.
public struct TrackRow: Hashable, Sendable {
    public var trackId: TrackID
    public var kind: TrackKind
    public var y: CGFloat
    public var height: CGFloat

    public var maxY: CGFloat { y + height }
    public var midY: CGFloat { y + height / 2 }
    public func contains(_ y: CGFloat) -> Bool { y >= self.y && y < maxY }
}

/// Pure geometry: how sequence time and tracks map onto the view. Built from the view model's zoom
/// and scroll state and the sequence's track list. The scene builder, hit tests, and gestures all use
/// it, so the timeline has exactly one coordinate system. Y grows downward (the Metal view is flipped).
public struct TimelineLayout: Hashable, Sendable {
    public var size: CGSize
    public var secondsPerPoint: Double
    /// Sequence time (seconds) at the left edge of the track area.
    public var scrollSeconds: Double
    public var rulerHeight: CGFloat = 28
    public var headerWidth: CGFloat = 148
    public var trackGap: CGFloat = 2
    public var rows: [TrackRow] = []

    public static let trackHeights: [TrackKind: CGFloat] = [.video: 64, .audio: 44, .caption: 28]
    /// Points within which a clip edge counts as a trim handle.
    public static let trimHandleWidth: CGFloat = 8
    /// Side of one header button, and the gap between two of them.
    public static let controlSize: CGFloat = 18
    public static let controlGap: CGFloat = 3
    /// Padding between the header's edges and its contents.
    public static let headerInset: CGFloat = 8
    /// Rows at least this tall put the button strip on its own line under the name; shorter rows (captions)
    /// put it beside the name and let the name truncate.
    public static let stackedRowHeight: CGFloat = 40
    /// Height of the track name's text box.
    public static let nameHeight: CGFloat = 14
    /// Points within which a dragged edge snaps to a snap target.
    public static let snapTolerance: CGFloat = 8
    /// Timescale for times derived from pointer positions; `decide` snaps them to frames or samples.
    public static let pointerTimescale: Int32 = 48000

    public init(size: CGSize, secondsPerPoint: Double, scrollSeconds: Double, tracks: [Track]) {
        self.size = size
        self.secondsPerPoint = secondsPerPoint
        self.scrollSeconds = scrollSeconds
        var y = rulerHeight + trackGap
        var rows: [TrackRow] = []
        for track in tracks {
            let h = TimelineLayout.trackHeights[track.kind] ?? 48
            rows.append(TrackRow(trackId: track.id, kind: track.kind, y: y, height: h))
            y += h + trackGap
        }
        self.rows = rows
    }

    // MARK: Time <-> x

    public var trackAreaMinX: CGFloat { headerWidth }
    public var trackAreaWidth: CGFloat { max(0, size.width - headerWidth) }
    public var visibleStartSeconds: Double { scrollSeconds }
    public var visibleEndSeconds: Double { scrollSeconds + Double(trackAreaWidth) * secondsPerPoint }
    public var contentBottom: CGFloat { rows.last?.maxY ?? rulerHeight }

    public func x(forSeconds seconds: Double) -> CGFloat {
        headerWidth + CGFloat((seconds - scrollSeconds) / secondsPerPoint)
    }

    public func x(for time: RationalTime) -> CGFloat { x(forSeconds: time.seconds) }

    public func seconds(atX x: CGFloat) -> Double {
        scrollSeconds + Double(x - headerWidth) * secondsPerPoint
    }

    /// The sequence time under `x`, never negative.
    public func time(atX x: CGFloat) -> RationalTime {
        RationalTime(seconds: max(0, seconds(atX: x)), timescale: TimelineLayout.pointerTimescale)
    }

    public func width(for duration: RationalTime) -> CGFloat { CGFloat(duration.seconds / secondsPerPoint) }

    // MARK: Rows

    public func row(atY y: CGFloat) -> TrackRow? { rows.first { $0.contains(y) } }
    public func row(for trackId: TrackID) -> TrackRow? { rows.first { $0.trackId == trackId } }

    public func isInRuler(_ point: CGPoint) -> Bool { point.y < rulerHeight && point.x >= headerWidth }
    public func isInHeader(_ point: CGPoint) -> Bool { point.x < headerWidth }

    // MARK: Header controls

    /// Width of the whole button strip.
    public static var controlStripWidth: CGFloat {
        CGFloat(TrackControl.allCases.count) * controlSize
            + CGFloat(TrackControl.allCases.count - 1) * controlGap
    }

    /// True when `row` is tall enough for the name and the strip to sit on separate lines.
    public func isStacked(_ row: TrackRow) -> Bool { row.height >= TimelineLayout.stackedRowHeight }

    /// The four buttons of `row`'s header, in draw and hit-test order. The one definition the scene builder
    /// and the gesture controller both use, so what is drawn is exactly what is clickable.
    public func controls(in row: TrackRow) -> [(control: TrackControl, rect: CGRect)] {
        let size = TimelineLayout.controlSize
        let gap = TimelineLayout.controlGap
        let inset = TimelineLayout.headerInset
        let x0: CGFloat
        let y: CGFloat
        if isStacked(row) {
            x0 = inset
            y = row.maxY - size - 6
        } else {
            x0 = max(inset, headerWidth - inset - TimelineLayout.controlStripWidth)
            y = row.y + (row.height - size) / 2
        }
        return TrackControl.allCases.enumerated().map { i, control in
            (control, CGRect(x: x0 + CGFloat(i) * (size + gap), y: y, width: size, height: size))
        }
    }

    /// The button under `point`, if any.
    public func control(atPoint point: CGPoint, in row: TrackRow) -> TrackControl? {
        controls(in: row).first { $0.rect.contains(point) }?.control
    }

    /// Where the track name draws, and how wide it may be before it truncates.
    public func nameRect(in row: TrackRow) -> CGRect {
        let inset = TimelineLayout.headerInset
        let height = TimelineLayout.nameHeight
        if isStacked(row) {
            return CGRect(x: inset, y: row.y + 5, width: max(0, headerWidth - inset * 2), height: height)
        }
        let stripX = max(inset, headerWidth - inset - TimelineLayout.controlStripWidth)
        return CGRect(
            x: inset, y: row.y + (row.height - height) / 2, width: max(0, stripX - inset - 6), height: height)
    }

    // MARK: Clips

    /// The clip's rectangle given its timeline start and end (seconds).
    public func rect(startSeconds: Double, endSeconds: Double, row: TrackRow) -> CGRect {
        let x0 = x(forSeconds: startSeconds)
        let x1 = x(forSeconds: endSeconds)
        return CGRect(x: x0, y: row.y + 1, width: max(1, x1 - x0), height: row.height - 2)
    }

    public func rect(for clip: Clip, in sequence: Sequence) -> CGRect? {
        guard let row = row(for: clip.trackId) else { return nil }
        return rect(startSeconds: clip.start.seconds, endSeconds: sequence.end(of: clip).seconds, row: row)
    }

    /// True when `[start, end)` seconds intersects the visible track area.
    public func isVisible(startSeconds: Double, endSeconds: Double) -> Bool {
        endSeconds >= visibleStartSeconds && startSeconds <= visibleEndSeconds
    }

    // MARK: Ruler

    /// Nice tick intervals in seconds; the ruler picks the smallest whose labelled spacing is wide enough.
    public static let tickIntervals: [Double] = [
        1.0 / 60, 1.0 / 24, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600,
    ]

    /// The labelled tick interval for this zoom, at least `minimumSpacing` points apart.
    public func majorTickSeconds(minimumSpacing: CGFloat = 90) -> Double {
        for interval in TimelineLayout.tickIntervals where CGFloat(interval / secondsPerPoint) >= minimumSpacing {
            return interval
        }
        return TimelineLayout.tickIntervals.last!
    }
}

/// Timecode formatting for ruler labels and the inspector.
public enum Timecode {
    /// `h:mm:ss`, `m:ss`, or `m:ss:ff` depending on how fine `interval` is.
    public static func label(seconds: Double, interval: Double, frameDuration: RationalTime) -> String {
        let total = max(0, seconds)
        let h = Int(total / 3600)
        let m = Int(total / 60) % 60
        let s = Int(total) % 60
        if interval >= 1 {
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        }
        let fps = 1 / frameDuration.seconds
        let frame = Int(((total - floor(total)) * fps).rounded(.down))
        return h > 0
            ? String(format: "%d:%02d:%02d:%02d", h, m, s, frame) : String(format: "%d:%02d:%02d", m, s, frame)
    }

    /// `m:ss:ff` for a time at the sequence frame rate.
    public static func frames(_ time: RationalTime, frameDuration: RationalTime) -> String {
        label(seconds: time.seconds, interval: 0, frameDuration: frameDuration)
    }
}
