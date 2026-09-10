import Contracts
import CoreGraphics
import Foundation
import Observation
import TimelineCore

/// Modifier keys that change what a gesture means: Option edits one clip of a link group (`unlinked`),
/// Command flips the edit mode (ripple <-> overwrite), Shift extends the selection.
public struct EditModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let option = EditModifiers(rawValue: 1 << 0)
    public static let command = EditModifiers(rawValue: 1 << 1)
    public static let shift = EditModifiers(rawValue: 1 << 2)
}

/// The kind of edit a gesture or key performs; decides the default edit mode.
public enum EditAction: Hashable, Sendable {
    case move
    case trim
    case delete
    case split

    /// Ripple for trim and delete, overwrite for drag-to-move (timeline-model.md section 4).
    public var defaultMode: EditMode {
        switch self {
        case .move: .overwrite
        case .trim, .delete, .split: .ripple
        }
    }
}

public enum GestureKind: Hashable, Sendable {
    case move
    case trimHead
    case trimTail

    public var action: EditAction { self == .move ? .move : .trim }
}

/// A drag in progress: where it started, where the pointer is, and the clip it addresses. Pure data so
/// the gesture logic is testable without `NSEvent`.
public struct PendingGesture: Hashable, Sendable {
    public var kind: GestureKind
    public var clipId: ClipID
    /// The clip as it was when the gesture began.
    public var original: Clip
    public var originalEnd: RationalTime
    /// Pointer time when the gesture began.
    public var anchor: RationalTime
    public var current: RationalTime
    /// Track under the pointer (move only); nil keeps the original track.
    public var targetTrackId: TrackID?
    public var modifiers: EditModifiers

    public var delta: RationalTime { current - anchor }
}

/// The gesture applied to a scratch copy of the sequence: what the timeline draws while the mouse is
/// down. Nothing here touches the store.
public struct GesturePreview: Sendable {
    public var sequence: Sequence
    public var operation: Command.Operation
    public var isValid: Bool
    /// The snap target the dragged edge landed on, for the guide line.
    public var snappedTo: RationalTime?
    public var message: String?
}

/// Mirrors a `ProjectStore` for the timeline, inspector, and history views, owns the UI state (selection,
/// playhead, zoom, scroll, snapping, modifiers), previews gestures on a scratch copy, and emits exactly
/// one `Command` per gesture on release.
@MainActor @Observable
public final class TimelineViewModel {
    public let store: any ProjectStore
    public let thumbnails: (any ThumbnailProvider)?
    public let waveforms: (any WaveformProvider)?
    public let libraryLayout: LibraryLayout

    public private(set) var project: Project = .blank
    public private(set) var history = History()
    public var selection: Set<ClipID> = []
    public var playhead: RationalTime = .zero
    private var zoomStorage: Int = ZoomLevel.defaultIndex
    private var scrollStorage: Double = 0
    /// Index into `ZoomLevel.secondsPerPoint`, clamped.
    public var zoomIndex: Int {
        get { zoomStorage }
        set { zoomStorage = min(max(newValue, 0), ZoomLevel.count - 1) }
    }
    /// Sequence time at the left edge of the track area, never negative.
    public var scrollSeconds: Double {
        get { scrollStorage }
        set { scrollStorage = max(0, newValue) }
    }
    public var snappingEnabled = true
    public var modifiers: EditModifiers = []
    /// The size the view last laid out at; the layout and hit tests derive from it.
    public var viewSize = CGSize(width: 1200, height: 400)
    public private(set) var pending: PendingGesture?
    public private(set) var preview: GesturePreview?
    public private(set) var lastError: EditorError?
    /// Commands accepted by the store through this view model.
    public private(set) var commandCount = 0
    /// Where a file drag over the view would land; the scene draws it until the drag leaves or drops.
    public internal(set) var dropTarget: TimelineDropTarget?
    /// Receives the media files dropped on the timeline and where they landed (`TimelineDrop.swift`).
    public var onDropMedia: (([URL], TimelineDropTarget) -> Void)?
    /// Receives rows dragged out of the library panel; the app duplicates a foreign asset first.
    public var onDropLibraryItems: (([LibraryDragItem], TimelineDropTarget) -> Void)?

    private let ids: any IDGenerator
    private var observation: Task<Void, Never>?

    public init(
        store: any ProjectStore, thumbnails: (any ThumbnailProvider)? = nil, waveforms: (any WaveformProvider)? = nil,
        libraryLayout: LibraryLayout = .default, ids: any IDGenerator = UUIDv7Generator()
    ) {
        self.store = store
        self.thumbnails = thumbnails
        self.waveforms = waveforms
        self.libraryLayout = libraryLayout
        self.ids = ids
    }

    // MARK: Store mirror

    /// Loads the current state and history.
    public func load() async {
        await refresh()
    }

    /// Re-reads state and history from the store; the timeline redraws through observation.
    public func refresh() async {
        // Fetch both before assigning so observers never see a state without its history or selection.
        let state = await store.state()
        let fold = await store.history()
        project = state
        history = fold
        if let seq = sequence {
            selection = selection.filter { seq.clip($0) != nil }
        } else {
            selection = []
        }
        if pending != nil { computePreview() }
    }

    /// Follows `store.changes` so edits from agents and other views appear.
    public func startObserving() {
        guard observation == nil else { return }
        let stream = store.changes
        observation = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    public func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    public var sequence: Sequence? {
        project.activeSequence ?? project.sequences.values.min { $0.id < $1.id }
    }

    /// The sequence to draw: the gesture preview while a drag is in progress, else the store's.
    public var displaySequence: Sequence? { preview?.sequence ?? sequence }

    public var frameDuration: RationalTime { sequence?.frameDuration ?? RationalTime(1001, 24000) }

    public func clip(_ id: ClipID) -> Clip? { sequence?.clip(id) }

    public var selectedClips: [Clip] {
        guard let seq = sequence else { return [] }
        return selection.compactMap { seq.clip($0) }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    public var canUndo: Bool { history.latestLive != nil }
    public var canRedo: Bool { history.redoTarget != nil }

    // MARK: Layout and zoom

    public var secondsPerPoint: Double { ZoomLevel.secondsPerPoint[zoomIndex] }

    public var layout: TimelineLayout {
        TimelineLayout(
            size: viewSize, secondsPerPoint: secondsPerPoint, scrollSeconds: scrollSeconds,
            tracks: displaySequence?.tracks ?? [])
    }

    /// Changes the zoom level keeping the time under `anchorX` (view x) where it is.
    public func setZoom(index: Int, anchorX: CGFloat? = nil) {
        let clamped = min(max(index, 0), ZoomLevel.count - 1)
        let l = layout
        let anchor = anchorX ?? l.trackAreaMinX
        let anchoredSeconds = l.seconds(atX: anchor)
        zoomIndex = clamped
        scrollSeconds = anchoredSeconds - Double(anchor - l.headerWidth) * secondsPerPoint
    }

    public func zoomIn(anchorX: CGFloat? = nil) { setZoom(index: zoomIndex + 1, anchorX: anchorX) }
    public func zoomOut(anchorX: CGFloat? = nil) { setZoom(index: zoomIndex - 1, anchorX: anchorX) }

    /// Scrolls so the playhead is visible.
    public func revealPlayhead() {
        let l = layout
        let s = playhead.seconds
        if s < l.visibleStartSeconds || s > l.visibleEndSeconds {
            scrollSeconds = max(0, s - Double(l.trackAreaWidth) * secondsPerPoint * 0.25)
        }
    }

    /// Ripple by default for trims and deletes, overwrite for moves; Command flips it.
    public func editMode(for action: EditAction, modifiers: EditModifiers? = nil) -> EditMode {
        let base = action.defaultMode
        let flip = (modifiers ?? self.modifiers).contains(.command)
        guard flip else { return base }
        return base == .ripple ? .overwrite : .ripple
    }

    // MARK: Selection and playhead

    public func select(_ id: ClipID?, extend: Bool = false) {
        guard let id else {
            if !extend { selection = [] }
            return
        }
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    public func setPlayhead(_ time: RationalTime) {
        playhead = time.isNegative ? .zero : time.floored(to: frameDuration)
    }

    public func nudgePlayhead(frames: Int64) {
        let fd = frameDuration
        let base = playhead.floored(to: fd)
        let next = base + RationalTime.frames(frames, of: fd)
        playhead = next.isNegative ? .zero : next
    }

    // MARK: Gestures (the state machine; NSEvent-free)

    /// Starts a move or trim on `clip` with the pointer at `time`.
    public func beginGesture(_ kind: GestureKind, clip id: ClipID, at time: RationalTime, modifiers: EditModifiers) {
        guard let seq = sequence, let clip = seq.clip(id) else { return }
        if let track = seq.track(clip.trackId), track.locked { return }
        self.modifiers = modifiers
        pending = PendingGesture(
            kind: kind, clipId: id, original: clip, originalEnd: seq.end(of: clip), anchor: time, current: time,
            targetTrackId: nil, modifiers: modifiers)
        computePreview()
    }

    /// Moves the pointer to `time` (and, for moves, over `track`).
    public func updateGesture(to time: RationalTime, track: TrackID? = nil, modifiers: EditModifiers? = nil) {
        guard var p = pending else { return }
        p.current = time
        if let modifiers {
            p.modifiers = modifiers
            self.modifiers = modifiers
        }
        if p.kind == .move, let track, let seq = sequence, let target = seq.track(track),
            let origin = seq.track(p.original.trackId), target.kind == origin.kind, !target.locked
        {
            p.targetTrackId = track == p.original.trackId ? nil : track
        } else if p.kind == .move, track == nil {
            p.targetTrackId = nil
        }
        pending = p
        computePreview()
    }

    /// Updates the modifiers during a gesture (a `flagsChanged` mid-drag re-previews).
    public func updateModifiers(_ modifiers: EditModifiers) {
        self.modifiers = modifiers
        guard var p = pending else { return }
        p.modifiers = modifiers
        pending = p
        computePreview()
    }

    public func cancelGesture() {
        pending = nil
        preview = nil
    }

    /// Ends the gesture and emits its one command, or nothing if the pointer never moved the edit.
    @discardableResult
    public func commit() async -> CommandResult? {
        guard let p = pending else { return nil }
        let (op, _) = operation(for: p)
        pending = nil
        preview = nil
        guard hasChange(op, pending: p) else { return nil }
        return await apply(op)
    }

    /// The command the gesture would emit right now, with the snap it landed on.
    public func operation(for p: PendingGesture) -> (Command.Operation, snappedTo: RationalTime?) {
        let moving = movingClipIds(for: p)
        switch p.kind {
        case .move:
            let rawStart = p.original.start + p.delta
            let duration = p.originalEnd - p.original.start
            let (start, snapped) = snapMove(start: rawStart, duration: duration, excluding: moving)
            let clamped = start.isNegative ? RationalTime.zero : start
            let op = Command.Operation.moveClip(
                .init(
                    clipId: .id(p.clipId), to: .init(trackId: p.targetTrackId.map { .id($0) }, start: clamped),
                    mode: editMode(for: .move, modifiers: p.modifiers), unlinked: p.modifiers.contains(.option)))
            return (op, snapped)
        case .trimHead, .trimTail:
            let edge: Edge = p.kind == .trimHead ? .head : .tail
            let raw = (edge == .head ? p.original.start : p.originalEnd) + p.delta
            let (to, snapped) = snapEdge(raw, excluding: moving)
            let bounded = boundTrim(to, edge: edge, pending: p)
            let op = Command.Operation.trimClip(
                .init(
                    clipId: .id(p.clipId), edge: edge, to: bounded, mode: editMode(for: .trim, modifiers: p.modifiers),
                    unlinked: p.modifiers.contains(.option)))
            return (op, snapped)
        }
    }

    private func hasChange(_ op: Command.Operation, pending p: PendingGesture) -> Bool {
        switch op {
        case .moveClip(let m): m.to.start != p.original.start || m.to.trackId != nil
        case .trimClip(let t): t.to != (t.edge == .head ? p.original.start : p.originalEnd)
        default: true
        }
    }

    private func movingClipIds(for p: PendingGesture) -> Set<ClipID> {
        guard let seq = sequence else { return [p.clipId] }
        if p.modifiers.contains(.option) { return [p.clipId] }
        if let g = p.original.linkGroupId { return Set(seq.members(of: g).map(\.id)) }
        return [p.clipId]
    }

    /// Keeps a trim inside the clip's media and at least one frame long.
    private func boundTrim(_ to: RationalTime, edge: Edge, pending p: PendingGesture) -> RationalTime {
        let fd = frameDuration
        switch edge {
        case .head:
            let maxStart = p.originalEnd - fd
            let minStart = RationalTime.max(p.original.start - p.original.sourceIn / p.original.speed, .zero)
            return RationalTime.min(RationalTime.max(to, minStart), maxStart)
        case .tail:
            let minEnd = p.original.start + fd
            var maxEnd = to
            if let asset = p.original.assetId.flatMap({ project.assets[$0] }) {
                let remaining = (asset.duration - p.original.sourceIn) / p.original.speed
                maxEnd = RationalTime.min(to, p.original.start + remaining)
            }
            return RationalTime.max(maxEnd, minEnd)
        }
    }

    private func computePreview() {
        guard let p = pending, let seq = sequence else {
            preview = nil
            return
        }
        let (op, snapped) = operation(for: p)
        let cmd = Command(commandId: "preview", actor: .human, operation: op)
        do {
            let events = try decide(project, cmd, ids: SequentialIDGenerator(start: 1), clock: FixedClock())
            let evolved = evolve(project, events)
            let s = evolved.sequences[seq.id] ?? seq
            preview = GesturePreview(sequence: s, operation: op, isValid: true, snappedTo: snapped)
        } catch {
            preview = GesturePreview(
                sequence: fallbackSequence(for: p, operation: op, in: seq), operation: op, isValid: false,
                snappedTo: snapped, message: error.message)
        }
    }

    /// When `decide` rejects the pending edit, show the addressed clip where the pointer put it so the
    /// user sees what they are doing; the store never receives this shape.
    private func fallbackSequence(for p: PendingGesture, operation: Command.Operation, in seq: Sequence) -> Sequence {
        var s = seq
        guard let i = s.trackIndex(containing: p.clipId), var clip = s.tracks[i].clips[p.clipId] else { return s }
        switch operation {
        case .moveClip(let m):
            clip.start = m.to.start
            if let t = m.to.trackId?.idValue, let j = s.trackIndex(of: t), j != i {
                s.tracks[i].clips[p.clipId] = nil
                clip.trackId = t
                s.tracks[j].clips[p.clipId] = clip
                return s
            }
        case .trimClip(let t):
            if t.edge == .head {
                let d = t.to - clip.start
                clip.start = t.to
                clip.sourceIn = clip.sourceIn + d * clip.speed
            } else {
                let d = t.to - p.originalEnd
                clip.sourceOut = clip.sourceOut + d * clip.speed
            }
        default: break
        }
        s.tracks[i].clips[p.clipId] = clip
        return s
    }

    // MARK: Snapping

    /// Clip edges, markers, the playhead, and zero, excluding the clips being dragged.
    public func snapTargets(excluding: Set<ClipID> = []) -> [RationalTime] {
        guard let seq = sequence else { return [.zero, playhead] }
        var targets: [RationalTime] = [.zero, playhead]
        for track in seq.tracks {
            for clip in track.clips.values where !excluding.contains(clip.id) {
                targets.append(clip.start)
                targets.append(seq.end(of: clip))
            }
        }
        for m in seq.markers.values { targets.append(m.at) }
        return targets
    }

    public var snapToleranceSeconds: Double { Double(TimelineLayout.snapTolerance) * secondsPerPoint }

    /// The nearest target within tolerance, if snapping is on.
    public func snapEdge(_ time: RationalTime, excluding: Set<ClipID> = []) -> (RationalTime, RationalTime?) {
        guard snappingEnabled else { return (time, nil) }
        let tolerance = snapToleranceSeconds
        let t = time.seconds
        var best: (RationalTime, Double)?
        for target in snapTargets(excluding: excluding) {
            let d = abs(target.seconds - t)
            if d <= tolerance, best == nil || d < best!.1 { best = (target, d) }
        }
        guard let best else { return (time, nil) }
        return (best.0, best.0)
    }

    /// Snaps whichever of the head or tail is closest to a target.
    private func snapMove(start: RationalTime, duration: RationalTime, excluding: Set<ClipID>) -> (
        RationalTime, RationalTime?
    ) {
        guard snappingEnabled else { return (start, nil) }
        let (head, headSnap) = snapEdge(start, excluding: excluding)
        let (tail, tailSnap) = snapEdge(start + duration, excluding: excluding)
        switch (headSnap, tailSnap) {
        case (nil, nil): return (start, nil)
        case (.some, nil): return (head, headSnap)
        case (nil, .some): return (tail - duration, tailSnap)
        case (.some(let h), .some(let t)):
            let dh = abs(h.seconds - start.seconds)
            let dt = abs(t.seconds - (start + duration).seconds)
            return dh <= dt ? (head, headSnap) : (tail - duration, tailSnap)
        }
    }

    // MARK: Commands

    /// Sends one command to the store and refreshes. Errors land in `lastError`.
    @discardableResult
    public func apply(_ operation: Command.Operation, label: String? = nil) async -> CommandResult? {
        let cmd = Command(commandId: CommandID(minting: ids), actor: .human, label: label, operation: operation)
        do {
            let result = try await store.apply(cmd)
            commandCount += 1
            lastError = nil
            await refresh()
            return result
        } catch {
            lastError = error
            return nil
        }
    }

    /// The cut time as `decide` will see it on `track`: `splitClip` snaps to the sequence frame on video
    /// and caption tracks before it validates (`DecideClips.swift`), so a time half a frame from an edge
    /// passes a naive containment test and is still rejected. Every candidate filter uses this.
    public func cutTime(_ at: RationalTime, on track: Track) -> RationalTime {
        track.kind.isFrameAligned ? at.snapped(to: frameDuration) : at
    }

    /// True when splitting `clip` at `at` is something `decide` will accept: the frame-snapped point
    /// falls strictly inside it, its track is unlocked, and — unless `unlinked` — no member of its link
    /// group sits on a locked track. That last one is not politeness: `group(of:)` rejects the whole
    /// command when any member's track is locked, and a batch has no per-operation recovery, so one such
    /// clip would take every other cut in the gesture down with it.
    public func canCut(_ clip: Clip, at: RationalTime, unlinked: Bool) -> Bool {
        guard let seq = sequence, let track = seq.track(clip.trackId), !track.locked else { return false }
        let t = cutTime(at, on: track)
        guard clip.start < t, t < seq.end(of: clip) else { return false }
        if !unlinked, let g = clip.linkGroupId {
            if seq.members(of: g).contains(where: { seq.track($0.trackId)?.locked == true }) { return false }
        }
        return true
    }

    /// Splits `clips` at `at` as exactly one command: uncuttable clips dropped (`canCut`), one operation
    /// per link group unless `unlinked`, ordered by (start, id) so two runs cut identically. Nil when
    /// nothing is cuttable — a gesture that can do nothing sends nothing rather than collecting a
    /// rejection.
    @discardableResult
    public func split(at: RationalTime, clips: [Clip], unlinked: Bool) async -> CommandResult? {
        var seenGroups: Set<LinkGroupID> = []
        var ops: [Command.Operation] = []
        for clip in clips.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) })
        where canCut(clip, at: at, unlinked: unlinked) {
            if !unlinked, let g = clip.linkGroupId {
                if seenGroups.contains(g) { continue }
                seenGroups.insert(g)
            }
            ops.append(.splitClip(.init(clipId: .id(clip.id), at: at, unlinked: unlinked)))
        }
        guard !ops.isEmpty else { return nil }
        return await apply(ops.count == 1 ? ops[0] : .batch(ops), label: "Split clip")
    }

    /// Splits the selected clips (or, with nothing selected, every clip under the playhead) at the playhead.
    @discardableResult
    public func splitAtPlayhead(modifiers: EditModifiers? = nil) async -> CommandResult? {
        guard let seq = sequence else { return nil }
        let candidates = selectedClips.isEmpty ? seq.tracks.flatMap { $0.clips.values } : selectedClips
        return await split(
            at: playhead, clips: candidates, unlinked: (modifiers ?? self.modifiers).contains(.option))
    }

    /// Removes the selection as one command (ripple by default, Command flips, Option unlinks).
    @discardableResult
    public func deleteSelection(modifiers: EditModifiers? = nil) async -> CommandResult? {
        guard let seq = sequence else { return nil }
        let mods = modifiers ?? self.modifiers
        let unlinked = mods.contains(.option)
        let mode = editMode(for: .delete, modifiers: mods)
        var seenGroups: Set<LinkGroupID> = []
        var ops: [Command.Operation] = []
        for clip in selectedClips {
            if let track = seq.track(clip.trackId), track.locked { continue }
            if !unlinked, let g = clip.linkGroupId {
                if seenGroups.contains(g) { continue }
                seenGroups.insert(g)
            }
            ops.append(.removeClip(.init(clipId: .id(clip.id), mode: mode, unlinked: unlinked)))
        }
        guard !ops.isEmpty else { return nil }
        selection = []
        return await apply(ops.count == 1 ? ops[0] : .batch(ops), label: "Remove clip")
    }

    @discardableResult
    public func undo() async -> CommandResult? {
        guard canUndo else { return nil }
        return await apply(.undo(.init()))
    }

    @discardableResult
    public func redo() async -> CommandResult? {
        guard canRedo else { return nil }
        return await apply(.redo)
    }

    // MARK: Inspector commands (one command per committed edit)

    @discardableResult
    public func setClipTransform(_ id: ClipID, _ transform: Transform) async -> CommandResult? {
        await apply(.setClipTransform(.init(clipId: .id(id), after: .constant(transform))))
    }

    @discardableResult
    public func setClipOpacity(_ id: ClipID, _ opacity: Double) async -> CommandResult? {
        await apply(.setClipOpacity(.init(clipId: .id(id), after: .constant(opacity))))
    }

    @discardableResult
    public func setClipAudio(_ id: ClipID, _ audio: ClipAudio) async -> CommandResult? {
        await apply(.setClipAudio(.init(clipId: .id(id), after: audio)))
    }

    @discardableResult
    public func setClipSpeed(_ id: ClipID, _ speed: Rational, mode: EditMode = .ripple) async -> CommandResult? {
        await apply(.setClipSpeed(.init(clipId: .id(id), after: speed, mode: mode)))
    }

    @discardableResult
    public func setTrackMuted(_ id: TrackID, _ muted: Bool) async -> CommandResult? {
        await apply(.setTrackMuted(.init(trackId: .id(id), muted: muted)))
    }

    @discardableResult
    public func setTrackLocked(_ id: TrackID, _ locked: Bool) async -> CommandResult? {
        await apply(.setTrackLocked(.init(trackId: .id(id), locked: locked)))
    }

    @discardableResult
    public func setTrackSolo(_ id: TrackID, _ solo: Bool) async -> CommandResult? {
        await apply(.setTrackSolo(.init(trackId: .id(id), solo: solo)))
    }

    // MARK: Track header controls (one command per click)

    /// Flips the control's state on `id`. Returns nil for a control that is inert on this track, so a click
    /// that cannot do anything sends nothing rather than collecting a rejection.
    @discardableResult
    public func toggle(_ control: TrackControl, on id: TrackID) async -> CommandResult? {
        guard let track = sequence?.track(id) else { return nil }
        switch control {
        case .mute: return await setTrackMuted(id, !track.muted)
        case .solo: return await setTrackSolo(id, !track.solo)
        case .lock: return await setTrackLocked(id, !track.locked)
        case .remove:
            // `decide` rejects this, and the header draws the button inert to match.
            guard !track.locked else { return nil }
            selection.subtract(track.clips.keys)
            return await apply(.removeTrack(.init(trackId: .id(id))), label: "Remove track \(track.name)")
        }
    }

    /// The `M` and `S` keys: toggle mute or solo on every track holding a selected clip. The timeline has no
    /// track selection of its own, so the clip selection stands in for one; with nothing selected, nothing
    /// happens. Several tracks go in one batch, keeping one command per gesture.
    @discardableResult
    public func toggleTracksOfSelection(_ control: TrackControl) async -> CommandResult? {
        guard control == .mute || control == .solo, let seq = sequence, !selection.isEmpty else { return nil }
        let tracks = seq.tracks.filter { track in track.clips.keys.contains { selection.contains($0) } }
        guard !tracks.isEmpty else { return nil }
        let isOn: (Track) -> Bool = control == .mute ? { $0.muted } : { $0.solo }
        // If any of them is off, turn them all on; otherwise turn them all off.
        let after = tracks.contains { !isOn($0) }
        let ops: [Command.Operation] = tracks.filter { isOn($0) != after }
            .map { track in
                control == .mute
                    ? .setTrackMuted(.init(trackId: .id(track.id), muted: after))
                    : .setTrackSolo(.init(trackId: .id(track.id), solo: after))
            }
        guard !ops.isEmpty else { return nil }
        return await apply(ops.count == 1 ? ops[0] : .batch(ops))
    }

    // MARK: Observation helper

    /// Reads every property the scene depends on, so `withObservationTracking` registers them all.
    public func touchRenderInputs() {
        _ = project.version
        _ = selection.count
        _ = playhead
        _ = zoomIndex
        _ = scrollSeconds
        _ = snappingEnabled
        _ = modifiers
        _ = viewSize
        _ = preview?.isValid
        _ = pending?.current
        _ = dropTarget
    }
}
