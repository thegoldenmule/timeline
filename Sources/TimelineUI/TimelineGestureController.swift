import Contracts
import CoreGraphics
import Foundation
import TimelineCore

/// Keys the timeline responds to, decoupled from `NSEvent` key codes.
public enum TimelineKey: Hashable, Sendable {
    /// `B`: split the selection (or the clips under the playhead) at the playhead.
    case split
    /// Delete or Backspace.
    case delete
    /// Arrow keys nudge the playhead one frame (Shift: ten).
    case left
    case right
    /// `N` toggles snapping.
    case toggleSnapping
    /// `V` and `C` put the selection tool and the razor in the pointer's hand.
    case tool(TimelineTool)
    /// `M` and `S` mute and solo the tracks of the selected clips.
    case toggleMute
    case toggleSolo
    case undo
    case redo
    case zoomIn
    case zoomOut
    case escape
}

/// What the pointer is over.
public enum HitTarget: Hashable, Sendable {
    case ruler
    /// A button in a track header. `.header` stays the header's background around them.
    case control(TrackID, TrackControl)
    case header(TrackID)
    case clip(ClipID, GestureKind)
    case empty(TrackID?)
}

/// Turns pointer and key input into view-model calls: hit testing, scrubbing, selection, one drag
/// gesture at a time. Works on points in the view's flipped coordinate space, so tests drive it
/// without constructing `NSEvent`s.
@MainActor
public final class TimelineGestureController {
    private enum State {
        case idle
        case scrubbing
        case dragging
        /// The razor is pressed; the blade follows the pointer and the cut goes on release.
        case razor
    }

    public let viewModel: TimelineViewModel
    private var state = State.idle
    /// Set on mouse down over a clip; the drag starts once the pointer moves past `dragThreshold`.
    private var armed: (kind: GestureKind, clip: ClipID, point: CGPoint, modifiers: EditModifiers)?
    /// Set on mouse down over a header button; the command goes on release, and only if the pointer is still
    /// over the same button, so dragging off cancels the click the way a button should.
    private var armedControl: (track: TrackID, control: TrackControl)?
    /// Where the pointer was last seen, so `flagsChanged` can redraw the blade — Shift widens a cut from
    /// one track to all of them — without waiting for the mouse to move.
    private var lastPoint: CGPoint?
    public var dragThreshold: CGFloat = 3

    public init(viewModel: TimelineViewModel) {
        self.viewModel = viewModel
    }

    public var isDragging: Bool { state == .dragging }

    // MARK: Hit testing

    public func hitTest(_ point: CGPoint) -> HitTarget {
        let layout = viewModel.layout
        if layout.isInRuler(point) { return .ruler }
        guard let row = layout.row(atY: point.y) else { return .empty(nil) }
        if layout.isInHeader(point) {
            if let control = layout.control(atPoint: point, in: row) { return .control(row.trackId, control) }
            return .header(row.trackId)
        }
        guard let seq = viewModel.displaySequence, let track = seq.track(row.trackId) else { return .empty(nil) }
        let seconds = layout.seconds(atX: point.x)
        let tolerance = Double(TimelineLayout.trimHandleWidth) * layout.secondsPerPoint
        var best: (Clip, Double)?
        for clip in track.clips.values {
            let start = clip.start.seconds
            let end = seq.end(of: clip).seconds
            guard seconds >= start - tolerance && seconds <= end + tolerance else { continue }
            let inside = seconds >= start && seconds <= end
            let distance = inside ? 0 : min(abs(seconds - start), abs(seconds - end))
            if best == nil || distance < best!.1 { best = (clip, distance) }
        }
        guard let (clip, _) = best else { return .empty(row.trackId) }
        let rect = layout.rect(for: clip, in: seq) ?? .zero
        let handle = min(TimelineLayout.trimHandleWidth, rect.width / 3)
        if point.x <= rect.minX + handle { return .clip(clip.id, .trimHead) }
        if point.x >= rect.maxX - handle { return .clip(clip.id, .trimTail) }
        return .clip(clip.id, .move)
    }

    // MARK: Mouse

    public func mouseDown(at point: CGPoint, modifiers: EditModifiers = []) {
        viewModel.modifiers = modifiers
        armedControl = nil
        lastPoint = point
        // The razor owns the lanes and nothing else: the ruler still scrubs and the header buttons still
        // click, so locking a track — which is how you opt it out of being cut — stays reachable while
        // the blade is armed.
        if viewModel.activeTool == .razor, isInLanes(point) {
            state = .razor
            viewModel.updateRazor(at: point, modifiers: modifiers)
            return
        }
        switch hitTest(point) {
        case .ruler:
            state = .scrubbing
            viewModel.setPlayhead(viewModel.layout.time(atX: point.x))
        case .control(let trackId, let control):
            // A press on a button neither scrubs nor changes the clip selection.
            armedControl = (trackId, control)
            state = .idle
        case .header:
            state = .idle
        case .clip(let id, let kind):
            if kind == .move {
                if modifiers.contains(.shift) {
                    viewModel.select(id, extend: true)
                } else if !viewModel.selection.contains(id) {
                    viewModel.select(id)
                }
            } else if !viewModel.selection.contains(id) {
                viewModel.select(id)
            }
            armed = (kind, id, point, modifiers)
            state = .idle
        case .empty:
            if !modifiers.contains(.shift) { viewModel.select(nil) }
            viewModel.setPlayhead(viewModel.layout.time(atX: point.x))
            state = .scrubbing
        }
    }

    public func mouseDragged(to point: CGPoint, modifiers: EditModifiers = []) {
        let layout = viewModel.layout
        lastPoint = point
        switch state {
        case .razor:
            viewModel.updateRazor(at: point, modifiers: modifiers)
        case .scrubbing:
            viewModel.setPlayhead(layout.time(atX: point.x))
        case .dragging:
            viewModel.updateGesture(
                to: layout.time(atX: point.x), track: layout.row(atY: point.y)?.trackId, modifiers: modifiers)
        case .idle:
            guard let armed else { return }
            let dx = point.x - armed.point.x
            let dy = point.y - armed.point.y
            guard abs(dx) >= dragThreshold || abs(dy) >= dragThreshold else { return }
            state = .dragging
            viewModel.beginGesture(
                armed.kind, clip: armed.clip, at: layout.time(atX: armed.point.x), modifiers: modifiers)
            self.armed = nil
            viewModel.updateGesture(
                to: layout.time(atX: point.x), track: layout.row(atY: point.y)?.trackId, modifiers: modifiers)
        }
    }

    /// Ends the gesture; a drag commits exactly one command.
    @discardableResult
    public func mouseUp(at point: CGPoint, modifiers: EditModifiers = []) async -> CommandResult? {
        let pressed = armedControl
        lastPoint = point
        defer {
            state = .idle
            armed = nil
            armedControl = nil
            // `modifiers` means "held during the gesture in progress", and there is no longer one. Leaving
            // them set let an Option-Command drag change what the *toolbar's* Delete button did minutes
            // later, because `deleteSelection()` and `splitAtPlayhead()` fall back to this when a caller
            // names no modifiers of its own.
            viewModel.modifiers = []
        }
        switch state {
        case .razor:
            viewModel.updateRazor(at: point, modifiers: modifiers)
            return await viewModel.commitRazor()
        case .dragging:
            viewModel.updateGesture(
                to: viewModel.layout.time(atX: point.x), track: viewModel.layout.row(atY: point.y)?.trackId,
                modifiers: modifiers)
            return await viewModel.commit()
        case .scrubbing, .idle:
            guard let pressed, case .control(let trackId, let control) = hitTest(point), trackId == pressed.track,
                control == pressed.control
            else { return nil }
            return await viewModel.toggle(control, on: trackId)
        }
    }

    public func flagsChanged(_ modifiers: EditModifiers) {
        viewModel.updateModifiers(modifiers)
        // Shift widens the cut from one track to all of them, so the blade must redraw where it stands.
        if viewModel.razorTarget != nil, let lastPoint {
            viewModel.updateRazor(at: lastPoint, modifiers: modifiers)
        }
    }

    /// The pointer moved with no button down. Only the razor cares.
    public func mouseMoved(to point: CGPoint, modifiers: EditModifiers = []) {
        lastPoint = point
        guard viewModel.activeTool == .razor else { return }
        if isInLanes(point) {
            viewModel.updateRazor(at: point, modifiers: modifiers)
        } else {
            viewModel.endRazor()
        }
    }

    /// True over the track lanes — not the ruler, not the header column, not below the last track.
    private func isInLanes(_ point: CGPoint) -> Bool {
        let layout = viewModel.layout
        guard !layout.isInRuler(point), !layout.isInHeader(point) else { return false }
        return layout.row(atY: point.y) != nil
    }

    // MARK: Keys

    @discardableResult
    public func key(_ key: TimelineKey, modifiers: EditModifiers = []) async -> CommandResult? {
        switch key {
        case .split: return await viewModel.splitAtPlayhead(modifiers: modifiers)
        case .delete: return await viewModel.deleteSelection(modifiers: modifiers)
        case .left: viewModel.nudgePlayhead(frames: modifiers.contains(.shift) ? -10 : -1)
        case .right: viewModel.nudgePlayhead(frames: modifiers.contains(.shift) ? 10 : 1)
        case .toggleSnapping: viewModel.snappingEnabled.toggle()
        case .tool(let tool): viewModel.selectTool(tool)
        case .toggleMute: return await viewModel.toggleTracksOfSelection(.mute)
        case .toggleSolo: return await viewModel.toggleTracksOfSelection(.solo)
        case .undo: return await viewModel.undo()
        case .redo: return await viewModel.redo()
        case .zoomIn: viewModel.zoomIn()
        case .zoomOut: viewModel.zoomOut()
        case .escape:
            // A ladder, because "Escape cancels" and "Escape puts the tool away" are different wishes and
            // one keystroke should not grant both: abandon the cut in flight, else the drag in flight,
            // else the tool, else the selection.
            if state == .razor {
                state = .idle
                viewModel.endRazor()
            } else if viewModel.pending != nil {
                viewModel.cancelGesture()
                state = .idle
                armed = nil
                armedControl = nil
            } else if viewModel.activeTool != .selection {
                viewModel.selectTool(.selection)
            } else {
                viewModel.select(nil)
            }
        }
        return nil
    }
}
