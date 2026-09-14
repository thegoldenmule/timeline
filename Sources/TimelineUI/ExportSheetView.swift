import Contracts
import CoreGraphics
import Foundation
import SwiftUI
import TimelineCore

// MARK: - Framing

/// How a sequence lands inside an export's frame.
///
/// This is `TimelineCompositor`'s mapping written down where a human can see it before the render
/// happens (`Sources/RenderKit/Compositor.swift`, "Sequence space to render-context space"): the
/// picture is scaled by the **smaller** of the two ratios, centred with a rounded translation, and
/// composited over black. The renderer never crops, so neither does this — a schematic that showed a
/// crop would be a worse lie than the hardcoded reel it replaces (`docs/plans/export-sheet.md`, 1).
public struct ExportFraming: Hashable, Sendable {
    /// The black the compositor writes where the fitted picture does not reach.
    public enum Bars: Hashable, Sendable {
        /// The aspects agree: the picture fills the frame.
        case none
        /// Black above and below; the height of one of the two bars, in output pixels.
        case letterbox(CGFloat)
        /// Black left and right; the width of one of the two bars, in output pixels.
        case pillarbox(CGFloat)
    }

    /// Under half an output pixel is not a bar; it is the rounding the compositor already does.
    public static let barTolerance: CGFloat = 0.5

    /// The export's frame, in pixels.
    public let output: CGSize
    /// The sequence's own size, in pixels.
    public let sequence: CGSize

    public init(output: CGSize, sequence: CGSize) {
        self.output = CGSize(width: max(1, output.width), height: max(1, output.height))
        self.sequence = CGSize(width: max(1, sequence.width), height: max(1, sequence.height))
    }

    /// `min(context/sequence)`, exactly as the compositor computes it.
    public var scale: CGFloat {
        min(output.width / sequence.width, output.height / sequence.height)
    }

    /// Where the picture actually lands inside the frame. The origin is rounded because the
    /// compositor rounds its translation; the size is not, because the compositor does not.
    public var fitted: CGRect {
        let size = CGSize(width: sequence.width * scale, height: sequence.height * scale)
        return CGRect(
            x: ((output.width - size.width) / 2).rounded(), y: ((output.height - size.height) / 2).rounded(),
            width: size.width, height: size.height)
    }

    public var bars: Bars {
        let horizontal = (output.width - fitted.width) / 2
        let vertical = (output.height - fitted.height) / 2
        if horizontal > ExportFraming.barTolerance { return .pillarbox(horizontal) }
        if vertical > ExportFraming.barTolerance { return .letterbox(vertical) }
        return .none
    }

    /// True when the sequence fills the frame and nothing is padded.
    public var isExact: Bool { bars == .none }

    /// The fraction of the output frame the picture covers, 0...1.
    public var coverage: Double {
        Double((fitted.width * fitted.height) / (output.width * output.height))
    }

    /// "1080 × 1920 · 9:16", the frame this export writes.
    public var outputLabel: String {
        "\(ExportFraming.pixels(output)) · \(ExportFraming.aspectLabel(output))"
    }

    /// One line under the picture saying what the renderer will do, in its own terms.
    public var summary: String {
        guard !isExact else { return "\(outputLabel) — the sequence fills the frame" }
        return "\(outputLabel) — the \(ExportFraming.pixels(sequence)) sequence "
            + "(\(ExportFraming.aspectLabel(sequence))) fills \(Int((coverage * 100).rounded()))% of it"
    }

    /// What the bars are, named the way an editor names them.
    public var barsDescription: String {
        switch bars {
        case .none: return ExportText.fillsFrame
        case .letterbox(let bar): return ExportText.letterboxed(Int(bar.rounded()))
        case .pillarbox(let bar): return ExportText.pillarboxed(Int(bar.rounded()))
        }
    }

    /// "1920 × 1080".
    public static func pixels(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    /// "16:9" when the reduced ratio is small enough to read, else "2.35:1". A shape nobody names in
    /// whole numbers is more legible as a decimal than as 256:109.
    public static func aspectLabel(_ size: CGSize) -> String {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return "—" }
        var a = width
        var b = height
        while b != 0 { (a, b) = (b, a % b) }
        let w = width / a
        let h = height / a
        if w <= 64, h <= 64 { return "\(w):\(h)" }
        return ExportText.decimal(Double(width) / Double(height), places: 2) + ":1"
    }
}

// MARK: - Copy

/// The texts of the export sheet; public so the app and the tests reference the same strings.
public enum ExportText {
    public static let title = "Export"
    public static let preset = "Preset"
    public static let size = "Size"
    public static let custom = "Custom"
    public static let width = "Width"
    public static let height = "Height"
    public static let frameRate = "Frame rate"
    public static let destination = "Save to"
    public static let choose = "Choose…"
    public static let export = "Export"
    public static let cancel = "Cancel"
    public static let fillsFrame = "Fills the frame"
    public static let matchSequence = "Match sequence"
    /// Said once, under the picture, because it is the whole reason this sheet exists.
    public static let fitNote =
        "The sequence is scaled to fit and centred on black. Nothing is cropped, so a frame that is not "
        + "the sequence's shape is padded to fill it."

    public static func letterboxed(_ bar: Int) -> String {
        "Letterboxed: \(bar) px of black above and below"
    }

    public static func pillarboxed(_ bar: Int) -> String {
        "Pillarboxed: \(bar) px of black to the left and right"
    }

    /// The badge on a preset row whose shape disagrees with the sequence's.
    public static let letterboxBadge = "letterboxed"
    public static let pillarboxBadge = "pillarboxed"

    /// The warning about the stage before this one: the footage does not fill the sequence, so no
    /// preset here can save it. Named in the sheet where the problem is found, not where it is caused.
    public static func sequenceMismatch(
        _ clip: String, _ clipSize: String, _ sequenceSize: String, _ bars: String
    ) -> String {
        "\(clip) is \(clipSize) in a \(sequenceSize) sequence, so it is \(bars) before this export "
            + "begins. No preset removes that — the sequence's own frame is what to change."
    }

    public static func dimensionRange(_ minimum: Int, _ maximum: Int) -> String {
        "Width and height are between \(minimum) and \(maximum) pixels"
    }

    /// H.264 and HEVC encode in macroblocks: an odd render size fails at the encoder rather than
    /// warning, so the sheet refuses it here.
    public static let evenDimensions = "Width and height must both be even numbers"
    public static let noDestination = "Choose a file to export to"

    /// "30 fps", "29.97 fps".
    public static func fps(_ rate: Rational) -> String {
        "\(decimal(rate.doubleValue)) fps"
    }

    /// Up to `places` decimals, with the trailing zeros taken off: 30, 29.97, 23.976, 2.35.
    public static func decimal(_ value: Double, places: Int = 3) -> String {
        var text = String(format: "%.\(places)f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

// MARK: - Draft

/// What the export sheet edits: which preset, how big, how fast, and where the file goes. Everything
/// the tool is told is derived from these few fields, so the picture above the controls and the
/// `ExportPreset` sent down the wire cannot disagree.
public struct ExportDraft: Hashable, Sendable {
    /// Where the output size comes from: the chosen preset, or the two fields.
    public enum Sizing: String, Hashable, Sendable, CaseIterable {
        case preset
        case custom
    }

    /// The sheet's own frame-rate control. Every built-in preset leaves `frameRate` at
    /// `.matchSequence`, so this never fights the preset.
    public enum Rate: Hashable, Sendable {
        case matchSequence
        case fixed(Rational)
    }

    /// The preset the sheet defaults to: `h264_1080p`'s codec choices at the sequence's own size and
    /// rate. It is a real `ExportPreset` and goes down the wire like any other, so the receipt, the
    /// render ledger row, and the file name all name it (`docs/plans/export-sheet.md`, 6).
    public static let matchSequence = ExportPreset(
        name: ExportText.matchSequence, container: .mp4, videoCodec: .h264, size: .matchSequence,
        frameRate: .matchSequence, videoQuality: .bitrate(bitsPerSecond: 12_000_000), hdr: .toneMapToSDR)

    /// The picker's rows, in order.
    public static let presets: [ExportPreset] = [matchSequence] + ExportPreset.builtIn

    /// The fixed rates offered beside "match sequence": the broadcast and film ladder.
    public static let rates: [Rational] = [
        Rational(24000, 1001), Rational(24, 1), Rational(25, 1), Rational(30000, 1001), Rational(30, 1),
        Rational(50, 1), Rational(60000, 1001), Rational(60, 1),
    ]

    public static let minimumDimension = 16
    public static let maximumDimension = 8192

    public let sequenceId: SequenceID
    public let sequenceName: String
    /// The sequence's own pixels — what every framing in this sheet is measured against.
    public let sequenceSize: CGSize
    /// The sequence's frame rate, as frames per second.
    public let sequenceRate: Rational
    /// Where an export goes when the user has not said otherwise.
    public let exportsDirectory: URL

    public var presetName: String
    public var sizing: Sizing
    public var customWidth: Int
    public var customHeight: Int
    public var rate: Rate
    /// What the save panel came back with. Until then the destination follows the preset's name and
    /// container, so picking ProRes renames the file and makes it a .mov without anyone typing.
    private var chosenURL: URL?

    /// The default: the sequence's own size and rate, whatever shape it is. A portrait sequence cannot
    /// default to a landscape frame here, because no frame but the sequence's is ever the default
    /// (`docs/plans/export-sheet.md`, 5).
    public init(sequence: Sequence, exportsDirectory: URL) {
        self.sequenceId = sequence.id
        self.sequenceName = sequence.name
        let width = max(1, sequence.width)
        let height = max(1, sequence.height)
        self.sequenceSize = CGSize(width: width, height: height)
        self.sequenceRate = Rational(Int64(sequence.frameDuration.timescale), max(1, sequence.frameDuration.value))
        self.exportsDirectory = exportsDirectory
        self.presetName = ExportDraft.matchSequence.name
        self.sizing = .preset
        // Seeded from the sequence so switching to Custom starts from something real, and even so the
        // first thing typed over is not already invalid.
        self.customWidth = width - width % 2
        self.customHeight = height - height % 2
        self.rate = .matchSequence
    }

    public static func preset(named name: String) -> ExportPreset? {
        presets.first { $0.name == name }
    }

    /// The preset this sheet would send: the named one, re-sized and re-timed by the two controls
    /// below it.
    public var preset: ExportPreset {
        var preset = ExportDraft.preset(named: presetName) ?? ExportDraft.matchSequence
        if sizing == .custom {
            preset.size = .fixed(width: customWidth, height: customHeight)
            // A 720x1280 export whose receipt says "H.264 1080p" is a receipt that lies, and the
            // ledger row is what publish_youtube reads back.
            preset.name = "Custom \(customWidth)x\(customHeight)"
        }
        switch rate {
        case .matchSequence: preset.frameRate = .matchSequence
        case .fixed(let rate): preset.frameRate = .fixed(rate)
        }
        return preset
    }

    /// The frame the file is written in, with `.matchSequence` resolved the way `ExportPlan` resolves
    /// it (`Sources/RenderKit/Export.swift`).
    public var outputSize: CGSize { ExportDraft.size(of: preset, sequenceSize: sequenceSize) }

    public var framing: ExportFraming { ExportFraming(output: outputSize, sequence: sequenceSize) }

    /// The frame rate the file is written at.
    public var outputRate: Rational {
        switch rate {
        case .matchSequence: return sequenceRate
        case .fixed(let rate): return rate
        }
    }

    /// Where the file goes. A chosen path keeps its name but not its extension: the container is the
    /// preset's business.
    public var outputURL: URL {
        guard let chosenURL else {
            return ExportDraft.defaultURL(
                sequenceName: sequenceName, presetName: preset.name, fileExtension: preset.fileExtension,
                in: exportsDirectory)
        }
        return chosenURL.deletingPathExtension().appendingPathExtension(preset.fileExtension)
    }

    /// The save panel's answer.
    public mutating func chose(_ url: URL) { chosenURL = url }

    /// `<exports>/<sequence>-<preset>.<ext>`.
    ///
    /// The second copy of this formula, on purpose: `render_export` builds the same path when no
    /// `outputPath` is given (`RenderTools.ExportDestination`), and `TimelineUI` may not import
    /// `AgentKit` to share it (`conventions.md`, package layout). The skeleton check imports both and
    /// asserts the two agree (`docs/plans/export-sheet.md`, 8).
    public static func defaultURL(
        sequenceName: String, presetName: String, fileExtension: String, in directory: URL
    ) -> URL {
        let name = "\(sequenceName)-\(presetName)".replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(name).\(fileExtension)")
    }

    /// The size a named preset would write for this sequence.
    public func size(ofPresetNamed name: String) -> CGSize {
        guard let preset = ExportDraft.preset(named: name) else { return sequenceSize }
        return ExportDraft.size(of: preset, sequenceSize: sequenceSize)
    }

    /// What a preset row says it would do to this sequence: nil when it fills the frame, else the
    /// padding it would add. This is what makes the mismatch visible at the moment of choosing rather
    /// than after the render (`docs/plans/export-sheet.md`, 4).
    public func badge(forPresetNamed name: String) -> String? {
        switch ExportFraming(output: size(ofPresetNamed: name), sequence: sequenceSize).bars {
        case .none: return nil
        case .letterbox: return ExportText.letterboxBadge
        case .pillarbox: return ExportText.pillarboxBadge
        }
    }

    /// "Reel 9:16 — 1080 × 1920, letterboxed".
    public func label(forPresetNamed name: String) -> String {
        let size = ExportFraming.pixels(size(ofPresetNamed: name))
        guard let badge = badge(forPresetNamed: name) else { return "\(name) — \(size)" }
        return "\(name) — \(size), \(badge)"
    }

    /// Why this cannot be exported, or nil when it can. The validation is the sheet's, not the core's:
    /// `render_export` takes any preset an agent hands it.
    public var validationError: String? {
        if sizing == .custom {
            let range = ExportDraft.minimumDimension...ExportDraft.maximumDimension
            guard range.contains(customWidth), range.contains(customHeight) else {
                return ExportText.dimensionRange(ExportDraft.minimumDimension, ExportDraft.maximumDimension)
            }
            guard customWidth % 2 == 0, customHeight % 2 == 0 else { return ExportText.evenDimensions }
        }
        guard !outputURL.lastPathComponent.isEmpty, outputURL.lastPathComponent != "/" else {
            return ExportText.noDestination
        }
        return nil
    }

    public var canExport: Bool { validationError == nil }

    private static func size(of preset: ExportPreset, sequenceSize: CGSize) -> CGSize {
        switch preset.size {
        case .matchSequence: return sequenceSize
        case .fixed(let width, let height): return CGSize(width: width, height: height)
        }
    }
}

// MARK: - Views

/// The frame an export writes, with the sequence fitted inside it: black where the renderer will write
/// black, the picture where it will write the picture. `frame` is the real composed frame at the
/// playhead when one was cheap to get; without it the fitted rect is a labelled plate, which tells the
/// same story.
public struct ExportFramingView: View {
    public let framing: ExportFraming
    public let frame: CGImage?
    /// The *other* fit, drawn nested inside the sequence: the footage into the sequence frame. The
    /// compositor aspect-fits twice and this view used to draw only the outer one, which is how a
    /// sequence full of pillarboxed portrait clips could report "the sequence fills the frame" and be
    /// telling the truth about the wrong stage (`docs/plans/sequence-format.md`).
    public let media: ExportFraming?

    public init(framing: ExportFraming, frame: CGImage? = nil, media: ExportFraming? = nil) {
        self.framing = framing
        self.frame = frame
        self.media = media
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.rowGap) {
            GeometryReader { proxy in
                let scale = min(
                    proxy.size.width / framing.output.width, proxy.size.height / framing.output.height)
                ZStack {
                    RoundedRectangle(cornerRadius: PanelTheme.posterRadius)
                        .fill(PanelTheme.letterboxFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: PanelTheme.posterRadius)
                                .strokeBorder(PanelTheme.borderIdle, lineWidth: PanelTheme.borderWidth)
                        )
                        .frame(width: framing.output.width * scale, height: framing.output.height * scale)
                    picture
                        .frame(width: framing.fitted.width * scale, height: framing.fitted.height * scale)
                    if let media, !media.isExact {
                        // Sequence pixels reach points through both fits, so the inner rectangle is
                        // drawn where the footage actually lands in the exported frame.
                        let inner = framing.scale * scale
                        Rectangle()
                            .fill(PanelTheme.posterFill)
                            .overlay(
                                Rectangle()
                                    .strokeBorder(PanelTheme.warning, lineWidth: PanelTheme.borderWidth)
                            )
                            .frame(width: media.fitted.width * inner, height: media.fitted.height * inner)
                            .accessibilityIdentifier("export-media-framing")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: PanelTheme.framePreviewHeight)
            .accessibilityIdentifier("export-framing")
            Text(framing.summary)
                .font(PanelTheme.monoDigit)
                .foregroundStyle(.secondary)
            Label(
                framing.barsDescription,
                systemImage: framing.isExact ? "checkmark.circle" : "rectangle.compress.vertical"
            )
            .font(PanelTheme.caption)
            .foregroundStyle(framing.isExact ? Color.secondary : PanelTheme.warning)
            .accessibilityIdentifier("export-bars")
        }
    }

    @ViewBuilder private var picture: some View {
        if let frame {
            Image(decorative: frame, scale: 1)
                .resizable()
                .clipShape(Rectangle())
        } else {
            Rectangle()
                .fill(PanelTheme.posterFill)
                .overlay(
                    Text(ExportFraming.pixels(framing.sequence))
                        .font(PanelTheme.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                )
        }
    }
}

/// The export sheet: what the file will be, what it will look like, and where it goes.
///
/// It hands the draft over and closes rather than awaiting the export itself, and that is not
/// cosmetic: `render_export` always answers `approval_required` first, and the card that asks goes on
/// the approval stack in the right-hand column — which a modal sheet covers
/// (`docs/plans/export-sheet.md`, 3).
public struct ExportSheetView: View {
    @Binding public var draft: ExportDraft
    /// Runs the save panel; nil when the user cancelled it.
    public let onChoosePath: () -> URL?
    /// The composed frame at the playhead for the picture above the controls, when there is one to be
    /// had. Asked once, when the sheet opens.
    public let onPoster: (@MainActor () async -> CGImage?)?
    public let onExport: (ExportDraft) -> Void
    public let onCancel: () -> Void
    /// Whether the sequence's own clips fill its frame. An export cannot fix this — by the time a file
    /// is framed the footage has already been fitted into the sequence — so the sheet reports it and
    /// hands over to the format sheet rather than pretending a preset could help.
    public let mismatch: FormatMismatch?
    public let onChangeFormat: (() -> Void)?
    @State private var frame: CGImage?

    public init(
        draft: Binding<ExportDraft>, onChoosePath: @escaping () -> URL?,
        onPoster: (@MainActor () async -> CGImage?)? = nil, onExport: @escaping (ExportDraft) -> Void,
        onCancel: @escaping () -> Void, mismatch: FormatMismatch? = nil,
        onChangeFormat: (() -> Void)? = nil
    ) {
        self._draft = draft
        self.onChoosePath = onChoosePath
        self.onPoster = onPoster
        self.onExport = onExport
        self.onCancel = onCancel
        self.mismatch = mismatch
        self.onChangeFormat = onChangeFormat
    }

    /// The footage's fit into the sequence frame, for the nested rectangle and the warning.
    private var mediaFraming: ExportFraming? {
        guard let worst = mismatch?.worst else { return nil }
        return worst.framing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionGap) {
            Text(ExportText.title).font(PanelTheme.sectionTitle)
            ExportFramingView(framing: draft.framing, frame: frame, media: mediaFraming)
            if let mismatch, !mismatch.isClean, let worst = mismatch.worst {
                HStack(alignment: .firstTextBaseline, spacing: PanelTheme.controlGap) {
                    Label(
                        ExportText.sequenceMismatch(
                            worst.assetName, worst.displaySize.description,
                            mismatch.sequenceSize.description, worst.barsDescription.lowercased()),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(PanelTheme.caption)
                    .foregroundStyle(PanelTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    if let onChangeFormat {
                        Button(SequenceFormatText.change, action: onChangeFormat)
                            .buttonStyle(.link)
                            .font(PanelTheme.caption)
                    }
                }
                .accessibilityIdentifier("export-sequence-mismatch")
            }
            Text(ExportText.fitNote)
                .font(PanelTheme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // `.columns`, not `.grouped`: the picture above and the destination below sit at the page
            // gutter, and grouped's inset cards would put the controls somewhere else entirely
            // (`ui-style.md`, the inspector's form).
            Form {
                presetPicker
                sizePicker
                if draft.sizing == .custom { customSize }
                ratePicker
            }
            .formStyle(.columns)
            destination
            if let error = draft.validationError {
                Label(error, systemImage: "xmark.octagon")
                    .font(PanelTheme.caption)
                    .foregroundStyle(PanelTheme.danger)
                    .accessibilityIdentifier("export-error")
            }
            HStack(spacing: PanelTheme.controlGap) {
                Spacer(minLength: 0)
                Button(ExportText.cancel, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(ExportText.export) { onExport(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.canExport)
            }
        }
        .padding(PanelTheme.pageInset)
        .frame(width: PanelTheme.formSheetWidth)
        .task {
            guard let onPoster else { return }
            frame = await onPoster()
        }
    }

    private var presetPicker: some View {
        Picker(ExportText.preset, selection: $draft.presetName) {
            ForEach(ExportDraft.presets, id: \.name) { preset in
                Text(draft.label(forPresetNamed: preset.name)).tag(preset.name)
            }
        }
        .accessibilityIdentifier("export-preset")
    }

    private var sizePicker: some View {
        Picker(ExportText.size, selection: $draft.sizing) {
            Text(ExportFraming.pixels(draft.size(ofPresetNamed: draft.presetName)))
                .tag(ExportDraft.Sizing.preset)
            Text(ExportText.custom).tag(ExportDraft.Sizing.custom)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("export-size")
    }

    private var customSize: some View {
        LabeledContent(ExportText.custom) {
            HStack(spacing: PanelTheme.controlGap) {
                TextField(ExportText.width, value: $draft.customWidth, format: .number)
                    .labelsHidden()
                    .frame(width: PanelTheme.numberFieldWidth)
                    .accessibilityIdentifier("export-width")
                Text("×").foregroundStyle(.secondary)
                TextField(ExportText.height, value: $draft.customHeight, format: .number)
                    .labelsHidden()
                    .frame(width: PanelTheme.numberFieldWidth)
                    .accessibilityIdentifier("export-height")
                Spacer(minLength: 0)
            }
        }
    }

    private var ratePicker: some View {
        Picker(ExportText.frameRate, selection: $draft.rate) {
            Text("\(ExportText.matchSequence) (\(ExportText.fps(draft.sequenceRate)))")
                .tag(ExportDraft.Rate.matchSequence)
            ForEach(ExportDraft.rates, id: \.self) { rate in
                Text(ExportText.fps(rate)).tag(ExportDraft.Rate.fixed(rate))
            }
        }
        .accessibilityIdentifier("export-rate")
    }

    private var destination: some View {
        HStack(spacing: PanelTheme.controlGap) {
            VStack(alignment: .leading, spacing: PanelTheme.hairGap) {
                Text(ExportText.destination).font(PanelTheme.caption).foregroundStyle(.secondary)
                Text(draft.outputURL.path)
                    .font(PanelTheme.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("export-destination")
            }
            Spacer(minLength: 0)
            Button(ExportText.choose) {
                if let url = onChoosePath() { draft.chose(url) }
            }
        }
    }
}
