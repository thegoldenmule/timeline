import Contracts
import Foundation
import SwiftUI
import TimelineCore

/// An editable copy of a clip's properties. The inspector edits the draft freely and commits one
/// property group at a time; `operations(against:)` lists what changed, one command per group.
public struct InspectorDraft: Hashable, Sendable {
    public enum Group: Hashable, Sendable, CaseIterable {
        case speed
        case transform
        case opacity
        case audio
    }

    public var clipId: ClipID
    public var speedPercent: Double
    public var transform: Transform
    public var opacity: Double
    public var gain: Double
    public var muted: Bool
    public var pitchCorrected: Bool

    public init(_ clip: Clip) {
        clipId = clip.id
        speedPercent = clip.speed.doubleValue * 100
        transform = clip.transform.constantValue ?? .identity
        opacity = clip.opacity.constantValue ?? 1
        gain = clip.audio.gain.constantValue ?? 1
        muted = clip.audio.muted
        pitchCorrected = clip.audio.pitchCorrected
    }

    public var speed: Rational {
        let pct = max(1, min(10000, speedPercent.rounded()))
        return Rational(Int64(pct), 100).reduced
    }

    public var audio: ClipAudio { ClipAudio(gain: .constant(gain), muted: muted, pitchCorrected: pitchCorrected) }

    /// The groups whose values differ from `clip`.
    public func changedGroups(against clip: Clip) -> [Group] {
        var groups: [Group] = []
        if speed != clip.speed { groups.append(.speed) }
        if transform != (clip.transform.constantValue ?? .identity) { groups.append(.transform) }
        if opacity != (clip.opacity.constantValue ?? 1) { groups.append(.opacity) }
        if audio != clip.audio { groups.append(.audio) }
        return groups
    }

    /// One operation per changed group.
    public func operations(against clip: Clip) -> [Command.Operation] {
        changedGroups(against: clip).map { operation(for: $0) }
    }

    public func operation(for group: Group) -> Command.Operation {
        switch group {
        case .speed: .setClipSpeed(.init(clipId: .id(clipId), after: speed))
        case .transform: .setClipTransform(.init(clipId: .id(clipId), after: .constant(transform)))
        case .opacity: .setClipOpacity(.init(clipId: .id(clipId), after: .constant(opacity)))
        case .audio: .setClipAudio(.init(clipId: .id(clipId), after: audio))
        }
    }
}

extension TimelineViewModel {
    /// Commits one property group of `draft` if it differs from the clip: exactly one command.
    @discardableResult
    public func commit(_ group: InspectorDraft.Group, from draft: InspectorDraft) async -> CommandResult? {
        guard let clip = clip(draft.clipId), draft.changedGroups(against: clip).contains(group) else { return nil }
        return await apply(draft.operation(for: group))
    }
}

/// Properties of the selected clip. Text fields commit on submit or focus loss, sliders when the drag
/// ends, toggles on change: one command per edit, never per keystroke.
public struct InspectorView: View {
    public let viewModel: TimelineViewModel
    @State private var draft: InspectorDraft?
    @FocusState private var focused: InspectorDraft.Group?

    public init(viewModel: TimelineViewModel) {
        self.viewModel = viewModel
    }

    private var clip: Clip? { viewModel.selectedClips.first }

    public var body: some View {
        Group {
            if let clip, let seq = viewModel.sequence {
                Form {
                    header(clip, in: seq)
                    if draft != nil {
                        speedSection
                        if seq.track(clip.trackId)?.kind == .video {
                            transformSection
                            opacitySection
                        }
                        if seq.track(clip.trackId)?.kind != .caption { audioSection }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("No clip selected", systemImage: "film")
            }
        }
        .onAppear { reset() }
        .onChange(of: clip) { _, _ in reset() }
        .onChange(of: focused) { old, _ in
            if let old { commit(old) }
        }
        .frame(minWidth: 260)
    }

    private func reset() {
        draft = clip.map { InspectorDraft($0) }
    }

    private func commit(_ group: InspectorDraft.Group) {
        guard let draft else { return }
        Task {
            await viewModel.commit(group, from: draft)
            reset()
        }
    }

    private func header(_ clip: Clip, in seq: Sequence) -> some View {
        let fd = seq.frameDuration
        let asset = clip.assetId.flatMap { viewModel.project.assets[$0] }
        return Section(clip.label ?? asset?.displayName ?? clip.text ?? "Clip") {
            LabeledContent("Start", value: Timecode.frames(clip.start, frameDuration: fd))
            LabeledContent("Duration", value: Timecode.frames(seq.duration(of: clip), frameDuration: fd))
            LabeledContent("Source in", value: Timecode.frames(clip.sourceIn, frameDuration: fd))
            LabeledContent("Source out", value: Timecode.frames(clip.sourceOut, frameDuration: fd))
            if let group = clip.linkGroupId {
                LabeledContent("Link group", value: String(group.rawValue.suffix(6)))
            }
            if let asset, asset.offline { Label("Offline media", systemImage: "exclamationmark.triangle") }
        }
    }

    private var speedSection: some View {
        Section("Speed") {
            TextField("Speed %", value: binding(\.speedPercent), format: .number)
                .focused($focused, equals: .speed)
                .onSubmit { commit(.speed) }
        }
    }

    private var transformSection: some View {
        Section("Transform") {
            TextField("X", value: binding(\.transform.x), format: .number)
                .focused($focused, equals: .transform).onSubmit { commit(.transform) }
            TextField("Y", value: binding(\.transform.y), format: .number)
                .focused($focused, equals: .transform).onSubmit { commit(.transform) }
            TextField("Scale", value: binding(\.transform.scale), format: .number)
                .focused($focused, equals: .transform).onSubmit { commit(.transform) }
            TextField("Rotation", value: binding(\.transform.rotation), format: .number)
                .focused($focused, equals: .transform).onSubmit { commit(.transform) }
        }
    }

    private var opacitySection: some View {
        Section("Opacity") {
            Slider(value: binding(\.opacity), in: 0...1) { editing in
                if !editing { commit(.opacity) }
            }
            Text(String(format: "%.0f%%", (draft?.opacity ?? 1) * 100)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Slider(value: binding(\.gain), in: 0...2) { editing in
                if !editing { commit(.audio) }
            }
            Text(String(format: "Gain %.2f", draft?.gain ?? 1)).font(.caption).foregroundStyle(.secondary)
            Toggle("Muted", isOn: binding(\.muted)).onChange(of: draft?.muted) { _, _ in commit(.audio) }
            Toggle("Pitch corrected", isOn: binding(\.pitchCorrected))
                .onChange(of: draft?.pitchCorrected) { _, _ in commit(.audio) }
        }
    }

    private func binding<V>(_ keyPath: WritableKeyPath<InspectorDraft, V>) -> Binding<V> {
        Binding(
            get: { draft.map { $0[keyPath: keyPath] } ?? InspectorDraft.placeholder[keyPath: keyPath] },
            set: { draft?[keyPath: keyPath] = $0 })
    }
}

extension InspectorDraft {
    static let placeholder = InspectorDraft(
        Clip(id: "placeholder", trackId: "placeholder", start: .zero, sourceIn: .zero, sourceOut: RationalTime(1, 1)))
}
