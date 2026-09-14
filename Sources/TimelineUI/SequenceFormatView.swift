import Foundation
import SwiftUI
import TimelineCore

// MARK: - The mismatch

/// Whether a sequence's own clips fill its frame, and by how much they miss.
///
/// This is the stage the export sheet could not see. `TimelineCompositor` aspect-fits **twice**: each
/// source into the sequence frame (`Compositor.swift`, "One layer in sequence coordinates"), and then
/// the sequence into the export's frame. `ExportFraming` already describes the second fit, and the
/// first one is the same arithmetic with different arguments — so this type is a reading of
/// `ExportFraming` over `(output: the sequence frame, sequence: the clip's display size)`, not a
/// second implementation of it.
///
/// Every size here is a **display** size: `Asset.displaySize` with the rotation applied. A portrait
/// phone clip probes as landscape 3840x2160 with `rotation -90`, so judging this from the encoded
/// probe size answers it backwards for exactly the footage most likely to be in the wrong frame.
public struct FormatMismatch: Hashable, Sendable {
    /// One clip that does not fill the sequence frame.
    public struct Offender: Hashable, Sendable, Identifiable {
        public let clipId: ClipID
        public let assetName: String
        public let displaySize: FrameSize
        /// The clip fitted into the sequence frame: the bars are this fit's bars.
        public let framing: ExportFraming

        public var id: ClipID { clipId }
        public var bars: ExportFraming.Bars { framing.bars }
        public var barsDescription: String { framing.barsDescription }
    }

    /// One video clip's contribution, whether or not it offends.
    public struct ClipSize: Hashable, Sendable {
        public let clipId: ClipID
        public let assetName: String
        public let size: FrameSize

        public init(clipId: ClipID, assetName: String, size: FrameSize) {
            self.clipId = clipId
            self.assetName = assetName
            self.size = size
        }
    }

    public let sequenceSize: FrameSize
    /// Every video clip that carries a display size, in timeline order.
    public let clips: [ClipSize]
    public let offenders: [Offender]

    public init(sequenceSize: FrameSize, clips: [ClipSize]) {
        self.sequenceSize = sequenceSize
        self.clips = clips
        let frame = CGSize(width: sequenceSize.width, height: sequenceSize.height)
        self.offenders = clips.compactMap { clip in
            let framing = ExportFraming(
                output: frame, sequence: CGSize(width: clip.size.width, height: clip.size.height))
            guard !framing.isExact else { return nil }
            return Offender(
                clipId: clip.clipId, assetName: clip.assetName, displaySize: clip.size, framing: framing)
        }
    }

    /// The clips of a sequence, read through their assets' display sizes.
    public init(sequence: Sequence, assets: [AssetID: Asset]) {
        var clips: [ClipSize] = []
        for track in sequence.tracks where track.kind == .video {
            for clip in track.clips.values.sorted(by: { $0.start < $1.start }) {
                guard let assetId = clip.assetId, let asset = assets[assetId], let size = asset.displaySize
                else { continue }
                clips.append(ClipSize(clipId: clip.id, assetName: asset.displayName, size: size))
            }
        }
        self.init(sequenceSize: sequence.frameSize, clips: clips)
    }

    /// True when every clip fills the frame, or when there is nothing to judge.
    public var isClean: Bool { offenders.isEmpty }

    /// True when there is no footage to compare against, so "clean" says nothing.
    public var isEmpty: Bool { clips.isEmpty }

    /// The clip that loses the most picture: the one whose fit covers the least of the frame.
    public var worst: Offender? {
        offenders.min { $0.framing.coverage < $1.framing.coverage }
    }

    /// The frame the footage itself wants, when the clips agree on a shape.
    ///
    /// Agreement is by *shape*, not by pixels — a 1080x1920 and a 2160x3840 clip want the same frame —
    /// and the answer is the largest of them, so matching never throws resolution away. Nil when the
    /// sequence holds clips of two different shapes, because then no single frame fits them all and
    /// the user has to choose.
    public var suggestedSize: FrameSize? {
        guard let first = clips.first?.size else { return nil }
        guard clips.allSatisfy({ $0.size.fills(first) }) else { return nil }
        return clips.map(\.size).max { $0.width * $0.height < $1.width * $1.height }
    }

    /// The clip the suggestion followed, for copy that can name it.
    public var suggestedSource: String? {
        guard let size = suggestedSize else { return nil }
        return clips.first { $0.size == size }?.assetName
    }

    /// One line for the status bar and the export sheet's warning.
    public var summary: String {
        guard let worst else {
            return isEmpty
                ? "\(sequenceSize.description) · \(sequenceSize.aspectLabel)"
                : "\(sequenceSize.description) · \(sequenceSize.aspectLabel) — footage fills the frame"
        }
        let count = offenders.count
        let noun = count == 1 ? "clip" : "clips"
        return "\(sequenceSize.description) \(sequenceSize.orientation.rawValue) frame — "
            + "\(count) \(noun) \(worst.barsDescription.lowercased())"
    }

    /// The sentence the sheet and the offer use: what is wrong and what fixes it.
    public var advice: String? {
        guard let worst else { return nil }
        guard let suggested = suggestedSize else {
            return "\(offenders.count) clip(s) do not fill the \(sequenceSize.description) frame and export "
                + "with black bars. The footage is not all one shape, so pick the frame you want below."
        }
        return "\(worst.assetName) is \(worst.displaySize.description) "
            + "(\(worst.displaySize.orientation.rawValue)) in a \(sequenceSize.description) "
            + "\(sequenceSize.orientation.rawValue) frame, so it exports \(worst.barsDescription.lowercased()). "
            + "Matching the sequence to the footage makes it \(suggested.description)."
    }
}

// MARK: - Copy

public enum SequenceFormatText {
    public static let title = "Sequence format"
    public static let frame = "Frame"
    public static let width = "Width"
    public static let height = "Height"
    public static let frameRate = "Frame rate"
    public static let apply = "Change format"
    public static let cancel = "Cancel"
    public static let custom = "Custom"
    public static let matchMedia = "Match media"
    public static let change = "Change format…"
    public static let matchOffer = "Match sequence to media"
    public static let dismiss = "Dismiss"

    public static let note =
        "The frame every clip is fitted into. Changing it rewrites no clip and is one undo step; the "
        + "preview and every export follow it."

    public static let captionNote =
        "Captions are sized from the frame and reflow with it, unless a caption style sets an explicit "
        + "font size."

    public static let rateLocked =
        "The frame rate cannot change once a video or caption track holds clips. The frame size can, at "
        + "any time."

    public static func matchMediaLabel(_ size: FrameSize, source: String?) -> String {
        guard let source else { return "\(matchMedia) — \(size.description)" }
        return "\(matchMedia) — \(size.description), from \(source)"
    }

    public static func dimensionRange(_ minimum: Int, _ maximum: Int) -> String {
        "Width and height must be between \(minimum) and \(maximum)"
    }

    public static let evenDimensions = "Width and height must both be even numbers"

    public static func fps(_ rate: Rational) -> String { ExportText.fps(rate) }
}

// MARK: - Presets

/// A named frame a sequence can take. Deliberately short: the ladder people actually shoot and post.
public struct SequenceFormatPreset: Hashable, Sendable, Identifiable {
    public let name: String
    public let size: FrameSize

    public init(name: String, size: FrameSize) {
        self.name = name
        self.size = size
    }

    public var id: String { name }

    /// "Landscape HD — 1920x1080, 16:9".
    public var label: String { "\(name) — \(size.description), \(size.aspectLabel)" }

    public static let builtIn: [SequenceFormatPreset] = [
        SequenceFormatPreset(name: "Landscape HD", size: FrameSize(width: 1920, height: 1080)),
        SequenceFormatPreset(name: "Portrait HD", size: FrameSize(width: 1080, height: 1920)),
        SequenceFormatPreset(name: "Square", size: FrameSize(width: 1080, height: 1080)),
        SequenceFormatPreset(name: "Landscape UHD", size: FrameSize(width: 3840, height: 2160)),
        SequenceFormatPreset(name: "Portrait UHD", size: FrameSize(width: 2160, height: 3840)),
    ]
}

// MARK: - Draft

/// What the format sheet edits: the sequence's frame, and the rate when the core will still take one.
///
/// The same shape as `ProjectRename` — validation lives here, the operation is `nil` when the draft is
/// invalid or unchanged, and the sheet is a thin rendering of it. The frame-rate rule is not restated:
/// `canChangeFrameRate` is read from the same condition `decide` tests, so the two cannot drift.
public struct SequenceFormat: Hashable, Sendable {
    public static let minimumDimension = 16
    public static let maximumDimension = 8192

    public enum Selection: Hashable, Sendable {
        case preset(String)
        case matchMedia
        case custom
    }

    public let sequenceId: SequenceID
    public let current: SequenceSettings
    public let mismatch: FormatMismatch
    /// False once a video or caption track holds clips, exactly as `Decide.setSequenceSettings` tests it.
    public let canChangeFrameRate: Bool

    public var selection: Selection
    public var customWidth: Int
    public var customHeight: Int
    public var rate: Rational

    public init(sequence: Sequence, assets: [AssetID: Asset]) {
        self.sequenceId = sequence.id
        self.current = SequenceSettings(sequence)
        self.mismatch = FormatMismatch(sequence: sequence, assets: assets)
        self.canChangeFrameRate = !sequence.tracks.contains { $0.kind.isFrameAligned && !$0.clips.isEmpty }
        let size = sequence.frameSize
        self.customWidth = size.width - size.width % 2
        self.customHeight = size.height - size.height % 2
        self.rate = Rational(Int64(sequence.frameDuration.timescale), max(1, sequence.frameDuration.value))
        // Opening on the row that already describes the sequence keeps the sheet honest about where it
        // starts; when nothing matches, Custom is holding the sequence's own numbers anyway.
        if let preset = SequenceFormatPreset.builtIn.first(where: { $0.size == size }) {
            self.selection = .preset(preset.name)
        } else {
            self.selection = .custom
        }
    }

    /// The frame the footage wants, when its clips agree on a shape.
    public var matchMediaSize: FrameSize? { mismatch.suggestedSize }
    public var matchMediaSource: String? { mismatch.suggestedSource }

    /// True when matching would actually change something — the row is pointless otherwise.
    public var canMatchMedia: Bool {
        guard let size = matchMediaSize else { return false }
        return size != current.frameSize
    }

    /// Matching is the recommended row exactly when the footage does not fit the frame it is in.
    public var recommendsMatchMedia: Bool { canMatchMedia && !mismatch.isClean }

    /// The frame the draft would write.
    public var size: FrameSize {
        switch selection {
        case .preset(let name):
            return SequenceFormatPreset.builtIn.first { $0.name == name }?.size ?? current.frameSize
        case .matchMedia:
            return matchMediaSize ?? current.frameSize
        case .custom:
            return FrameSize(width: customWidth, height: customHeight)
        }
    }

    public var frameDuration: RationalTime {
        guard canChangeFrameRate else { return current.frameDuration }
        return RationalTime(rate.den, Int32(clamping: rate.num))
    }

    /// What the chosen frame would do to the footage: the sheet's live answer, and what makes matching
    /// visibly the fix rather than a claim that it is.
    public var resultingMismatch: FormatMismatch {
        FormatMismatch(sequenceSize: size, clips: mismatch.clips)
    }

    public var validationError: String? {
        guard case .custom = selection else { return nil }
        let range = SequenceFormat.minimumDimension...SequenceFormat.maximumDimension
        guard range.contains(customWidth), range.contains(customHeight) else {
            return SequenceFormatText.dimensionRange(
                SequenceFormat.minimumDimension, SequenceFormat.maximumDimension)
        }
        // Odd dimensions are not rejected by the core, but every codec here subsamples chroma and an
        // odd frame is where that goes wrong; the export sheet holds the same line.
        guard customWidth % 2 == 0, customHeight % 2 == 0 else { return SequenceFormatText.evenDimensions }
        return nil
    }

    public var after: SequenceSettings {
        SequenceSettings(
            name: current.name, frameDuration: frameDuration, width: size.width, height: size.height)
    }

    public var isUnchanged: Bool { after == current }

    /// An unchanged draft may be submitted — Return on a sheet opened by mistake should close it.
    public var canSubmit: Bool { validationError == nil }

    /// Nil when the draft is invalid or would change nothing, so the no-op never reaches the store.
    public var operation: Command.Operation? {
        guard validationError == nil, !isUnchanged else { return nil }
        return .setSequenceSettings(.init(sequenceId: .id(sequenceId), after: after))
    }
}

// MARK: - Views

/// The sequence's frame with its footage drawn inside it: the stage the export sheet cannot show,
/// because by the time an export is framed this has already happened.
public struct FormatMismatchView: View {
    public let mismatch: FormatMismatch

    public init(mismatch: FormatMismatch) {
        self.mismatch = mismatch
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.rowGap) {
            GeometryReader { proxy in
                let frame = CGSize(width: mismatch.sequenceSize.width, height: mismatch.sequenceSize.height)
                let scale = min(proxy.size.width / frame.width, proxy.size.height / frame.height)
                ZStack {
                    RoundedRectangle(cornerRadius: PanelTheme.posterRadius)
                        .fill(PanelTheme.letterboxFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: PanelTheme.posterRadius)
                                .strokeBorder(PanelTheme.borderIdle, lineWidth: PanelTheme.borderWidth)
                        )
                        .frame(width: frame.width * scale, height: frame.height * scale)
                    if let worst = mismatch.worst {
                        Rectangle()
                            .fill(PanelTheme.posterFill)
                            .frame(
                                width: worst.framing.fitted.width * scale,
                                height: worst.framing.fitted.height * scale)
                    } else {
                        Rectangle()
                            .fill(PanelTheme.posterFill)
                            .frame(width: frame.width * scale, height: frame.height * scale)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: PanelTheme.framePreviewHeight)
            .accessibilityIdentifier("format-framing")
            Text(mismatch.summary)
                .font(PanelTheme.monoDigit)
                .foregroundStyle(.secondary)
            if let worst = mismatch.worst {
                Label(worst.barsDescription, systemImage: "rectangle.compress.vertical")
                    .font(PanelTheme.caption)
                    .foregroundStyle(PanelTheme.warning)
                    .accessibilityIdentifier("format-bars")
            } else if !mismatch.isEmpty {
                Label(ExportText.fillsFrame, systemImage: "checkmark.circle")
                    .font(PanelTheme.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("format-bars")
            }
        }
    }
}

/// The format sheet: what frame the sequence is in, what the footage wants, and what the change does.
public struct SequenceFormatSheet: View {
    @State private var draft: SequenceFormat
    @State private var error: String?
    @State private var isBusy = false

    private let commit: (SequenceFormat) async -> String?
    private let cancel: () -> Void

    public init(
        draft: SequenceFormat, commit: @escaping (SequenceFormat) async -> String?,
        cancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.commit = commit
        self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionGap) {
            Text(SequenceFormatText.title).font(PanelTheme.sectionTitle)
            FormatMismatchView(mismatch: draft.resultingMismatch)
            if let advice = draft.mismatch.advice, !draft.mismatch.isClean {
                Text(advice)
                    .font(PanelTheme.caption)
                    .foregroundStyle(PanelTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("format-advice")
            }
            framePicker
            if case .custom = draft.selection { customFields }
            rateRow
            Text(SequenceFormatText.note)
                .font(PanelTheme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = error ?? draft.validationError {
                Text(error).font(PanelTheme.caption).foregroundStyle(PanelTheme.danger)
            }
            HStack {
                Spacer()
                Button(SequenceFormatText.cancel, role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(SequenceFormatText.apply) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.canSubmit || isBusy)
            }
        }
        .padding(PanelTheme.pageInset)
        .frame(width: PanelTheme.formSheetWidth)
    }

    private var framePicker: some View {
        Picker(SequenceFormatText.frame, selection: frameSelection) {
            if let size = draft.matchMediaSize, draft.canMatchMedia {
                Text(SequenceFormatText.matchMediaLabel(size, source: draft.matchMediaSource))
                    .tag(SequenceFormat.Selection.matchMedia)
            }
            ForEach(SequenceFormatPreset.builtIn) { preset in
                Text(preset.label).tag(SequenceFormat.Selection.preset(preset.name))
            }
            Text(SequenceFormatText.custom).tag(SequenceFormat.Selection.custom)
        }
        .accessibilityIdentifier("format-frame")
    }

    private var customFields: some View {
        HStack(spacing: PanelTheme.controlGap) {
            Text(SequenceFormatText.width).font(PanelTheme.caption)
            TextField(SequenceFormatText.width, value: $draft.customWidth, format: .number)
                .frame(width: PanelTheme.numberFieldWidth)
            Text(SequenceFormatText.height).font(PanelTheme.caption)
            TextField(SequenceFormatText.height, value: $draft.customHeight, format: .number)
                .frame(width: PanelTheme.numberFieldWidth)
        }
        .labelsHidden()
    }

    @ViewBuilder private var rateRow: some View {
        if draft.canChangeFrameRate {
            Picker(SequenceFormatText.frameRate, selection: $draft.rate) {
                ForEach(ExportDraft.rates, id: \.self) { rate in
                    Text(SequenceFormatText.fps(rate)).tag(rate)
                }
            }
            .accessibilityIdentifier("format-rate")
        } else {
            VStack(alignment: .leading, spacing: PanelTheme.hairGap) {
                Text("\(SequenceFormatText.frameRate): \(SequenceFormatText.fps(draft.rate))")
                    .font(PanelTheme.caption)
                Text(SequenceFormatText.rateLocked)
                    .font(PanelTheme.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("format-rate-locked")
        }
    }

    /// The picker binds through the draft so a preset row also re-seeds the custom fields: switching to
    /// Custom after choosing Portrait HD starts from 1080x1920, not from where the sheet opened.
    private var frameSelection: Binding<SequenceFormat.Selection> {
        Binding(
            get: { draft.selection },
            set: { selection in
                let previous = draft.size
                draft.selection = selection
                if case .custom = selection {
                    draft.customWidth = previous.width - previous.width % 2
                    draft.customHeight = previous.height - previous.height % 2
                }
            })
    }

    private func submit() {
        isBusy = true
        Task { @MainActor in
            error = await commit(draft)
            isBusy = false
        }
    }
}
