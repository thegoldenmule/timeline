import AppKit
import Contracts
import CoreGraphics
import Foundation
import TimelineCore

/// Which pointer tool the timeline is in. View state: it is not a fact about the project, it is not
/// undoable, and two windows on one project would disagree about it, so unlike `Track.solo` it never
/// reaches `TimelineCore`, the store, or the event log.
public enum TimelineTool: String, Hashable, Sendable, CaseIterable {
    /// Drag to move, drag an edge to trim, click to select. The default.
    case selection
    /// Click a clip to cut it there. `C` arms it, `V` puts it away.
    case razor

    /// The SF Symbol the toolbar draws. `scissors` is what the Split button already uses, so one glyph
    /// means one thing across the toolbar, the picker, and the cursor.
    public var symbolName: String {
        switch self {
        case .selection: "cursorarrow"
        case .razor: "scissors"
        }
    }
}

/// Where a razor cut would land: the time under the pointer, snapped like a drop, and the clips it would
/// split. An empty `clipIds` means the click is inert — no command, and the blade draws dimmed — which is
/// how the razor never sends a command `decide` would reject.
public struct RazorTarget: Hashable, Sendable {
    public var at: RationalTime
    /// The snap target `at` landed on, for the guide band.
    public var snappedTo: RationalTime?
    /// The row under the pointer; nil on the ruler, the header column, or below the last track.
    public var trackId: TrackID?
    /// True when Shift was held: every unlocked track, not just `trackId`.
    public var allTracks: Bool
    /// True when Option was held: cut the addressed clips alone, not their link groups. Carried here
    /// rather than re-read at commit time so the cut is exactly the one the blade was drawn for.
    public var unlinked: Bool
    /// The clips that would be split, ordered by (start, id) so two runs cut identically.
    public var clipIds: [ClipID]

    public init(
        at: RationalTime, snappedTo: RationalTime? = nil, trackId: TrackID? = nil, allTracks: Bool = false,
        unlinked: Bool = false, clipIds: [ClipID] = []
    ) {
        self.at = at
        self.snappedTo = snappedTo
        self.trackId = trackId
        self.allTracks = allTracks
        self.unlinked = unlinked
        self.clipIds = clipIds
    }

    /// True when clicking here would emit a command.
    public var isCuttable: Bool { !clipIds.isEmpty }
}

/// Which cursor belongs over a point. Pure so it is tested; `nsCursor` is the thin AppKit shell that is
/// not.
public enum TimelineCursorKind: Hashable, Sendable {
    case arrow
    case razor
}

public enum TimelineCursor {
    /// The blade only over the track lanes: the ruler still scrubs and the header buttons still click
    /// while the razor is armed, so locking a track — the way you opt it out of being cut — stays
    /// reachable.
    public static func kind(for tool: TimelineTool, at point: CGPoint, layout: TimelineLayout)
        -> TimelineCursorKind
    {
        guard tool == .razor else { return .arrow }
        if layout.isInHeader(point) || layout.isInRuler(point) { return .arrow }
        return point.y >= layout.rulerHeight ? .razor : .arrow
    }

    @MainActor
    public static func nsCursor(_ kind: TimelineCursorKind) -> NSCursor {
        switch kind {
        case .arrow: NSCursor.arrow
        case .razor: razor
        }
    }

    /// Side of the cursor image, and where the cut line sits inside it.
    static let cursorSize: CGFloat = 24
    static let bladeX: CGFloat = 5

    /// Built once: a new `NSCursor` per `cursorUpdate` would churn and flicker.
    @MainActor
    static let razor: NSCursor = {
        let size = NSSize(width: cursorSize, height: cursorSize)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            // The cut line, haloed so it reads against any lane colour. This, not the glyph, is what the
            // hot spot points at, because it is where the cut actually lands.
            for (colour, width) in [(NSColor.black.withAlphaComponent(0.65), CGFloat(3)), (NSColor.white, 1)] {
                ctx.setStrokeColor(colour.cgColor)
                ctx.setLineWidth(width)
                ctx.move(to: CGPoint(x: bladeX, y: 0))
                ctx.addLine(to: CGPoint(x: bladeX, y: size.height))
                ctx.strokePath()
            }
            // The scissors sit to the right of the line so they never cover it.
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            if let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Razor")?
                .withSymbolConfiguration(config)
            {
                let r = NSRect(x: bladeX + 3, y: 2, width: symbol.size.width, height: symbol.size.height)
                NSColor.black.withAlphaComponent(0.65).set()
                symbol.draw(in: r.offsetBy(dx: 0.5, dy: -0.5))
                NSColor.white.set()
                symbol.draw(in: r)
            }
            return true
        }
        // Load-bearing: a template image draws as a flat black silhouette, invisible on the timeline's
        // background.
        image.isTemplate = false
        // `NSImage(size:flipped: false)` draws bottom-up while `hotSpot` is measured from the top left.
        // Harmless only because the blade is a full-height line, so nothing but its x matters.
        return NSCursor(image: image, hotSpot: NSPoint(x: bladeX, y: size.height / 2))
    }()
}

extension TimelineViewModel {
    // MARK: The tool

    public func selectTool(_ tool: TimelineTool) {
        guard activeTool != tool else { return }
        activeTool = tool
        if tool != .razor { razorTarget = nil }
    }

    // MARK: Razor targets (the state machine; NSEvent-free)

    /// The cut a razor click at `point` would make. Snapping runs first and the clip list is derived from
    /// the *snapped* time, so landing on a clip boundary yields an inert target rather than a command the
    /// core rejects.
    public func razorTarget(at point: CGPoint, modifiers: EditModifiers) -> RazorTarget {
        let l = layout
        let raw = l.time(atX: point.x)
        let allTracks = modifiers.contains(.shift)
        let unlinked = modifiers.contains(.option)
        guard let seq = sequence else {
            return RazorTarget(at: raw, allTracks: allTracks, unlinked: modifiers.contains(.option))
        }
        let trackId = l.isInRuler(point) ? nil : l.row(atY: point.y)?.trackId

        // The clip under the pointer, on an unlocked track. In single mode it is the only candidate.
        var anchor: Clip?
        if let trackId, let track = seq.track(trackId), !track.locked {
            anchor = track.clips.values.first { $0.start <= raw && raw <= seq.end(of: $0) }
        }

        // A linked partner shares its clip's start and end exactly, so excluding only the hovered clip
        // would leave its coincident twin in the target list and snap us onto a no-op cut anyway.
        var exclude: Set<ClipID> = []
        if !allTracks, let anchor {
            exclude = [anchor.id]
            if !unlinked, let g = anchor.linkGroupId { exclude = Set(seq.members(of: g).map(\.id)) }
        }
        let (at, snappedTo) = snapEdge(raw, excluding: exclude)

        let candidates = allTracks ? seq.tracks.flatMap { $0.clips.values } : anchor.map { [$0] } ?? []
        var seenGroups: Set<LinkGroupID> = []
        var clipIds: [ClipID] = []
        for clip in candidates.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) })
        where canCut(clip, at: at, unlinked: unlinked) {
            if !unlinked, let g = clip.linkGroupId {
                if seenGroups.contains(g) { continue }
                seenGroups.insert(g)
            }
            clipIds.append(clip.id)
        }
        return RazorTarget(
            at: at, snappedTo: snappedTo, trackId: trackId, allTracks: allTracks, unlinked: unlinked,
            clipIds: clipIds)
    }

    /// The pointer moved over the view with the razor armed; the scene draws the blade until `endRazor`.
    /// Assigns only on a real change: Observation fires on every set, and this runs at pointer rate.
    public func updateRazor(at point: CGPoint, modifiers: EditModifiers) {
        let next = razorTarget(at: point, modifiers: modifiers)
        if razorTarget != next { razorTarget = next }
    }

    /// The pointer left the view, the tool changed, or the cut was cancelled.
    public func endRazor() {
        if razorTarget != nil { razorTarget = nil }
    }

    /// Cuts where the blade is drawn, as exactly one command, leaving the selection and the playhead
    /// alone. Nil when the target is inert or absent.
    @discardableResult
    public func commitRazor() async -> CommandResult? {
        guard let target = razorTarget, let seq = sequence else { return nil }
        let clips = target.clipIds.compactMap { seq.clip($0) }
        guard !clips.isEmpty else { return nil }
        return await split(at: target.at, clips: clips, unlinked: target.unlinked)
    }
}
