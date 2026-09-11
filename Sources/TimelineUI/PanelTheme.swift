import CoreGraphics
import Foundation
import SwiftUI

/// The design tokens for the window's SwiftUI chrome: spacing, corner radii, panel metrics, the type
/// roles, and the semantic fills. Every panel outside the Metal timeline reads its numbers from here
/// (`docs/design/ui-style.md`). Tests assert on these values.
///
/// `TimelineTheme` is the other half and stays separate on purpose: a fixed dark `SceneColor` palette
/// written unmanaged to BGRA8, consumed by a pure value type with no appearance to resolve a dynamic
/// colour against. The two must agree in exactly two places — `posterRadius` and `barHeight` — and
/// `StyleTests` asserts both so they cannot drift.
public enum PanelTheme {

    // MARK: Spacing

    /// A disclosure's body under its label, or a scroll view clear of its indicator. Nothing smaller.
    public static let hairGap: CGFloat = 2
    /// Between the lines inside one row, card, or chip.
    public static let rowGap: CGFloat = 4
    /// Between controls in a strip, and between a symbol and its label.
    public static let controlGap: CGFloat = 6
    /// Between sibling sections in a panel body.
    public static let sectionGap: CGFloat = 8
    /// From a panel's edge to its content.
    public static let panelInset: CGFloat = 8
    /// Inside a card that floats on its own background: an approval card, an account block.
    public static let cardInset: CGFloat = 12
    /// Inside a settings page or a sheet.
    public static let pageInset: CGFloat = 16
    /// A header's or status bar's vertical padding. There is no horizontal counterpart on purpose:
    /// bars use `panelInset` like everything else, so a header's symbol starts exactly where the
    /// content under it does.
    public static let barInsetV: CGFloat = 5

    // MARK: Corner radii

    /// A poster, thumbnail, or small plate. Equal to `TimelineTheme.controlCornerRadius`: the same
    /// plate is drawn on a track header by Metal and in a chip by SwiftUI.
    public static let posterRadius: CGFloat = 3
    /// An attachment chip or a token-sized control.
    public static let chipRadius: CGFloat = 6
    /// A message bubble, the composer field, the drag overlay.
    public static let bubbleRadius: CGFloat = 8
    /// A card floating over a panel.
    public static let cardRadius: CGFloat = 10

    // MARK: Panel metrics

    /// A panel header's height. Equal to `TimelineLayout.rulerHeight`, so a header lines up with the
    /// ruler across a split.
    public static let barHeight: CGFloat = 28
    /// A collapsed panel's spine: a 22 pt icon button plus `barInsetV` either side.
    public static let railWidth: CGFloat = 32
    /// The seam between two panels: a hairline `Divider` centred in this much hit area.
    public static let dividerThickness: CGFloat = 8
    /// What the preview-and-timeline column is never squeezed below, whatever the side panels want.
    public static let centreMinimum: CGFloat = 480
    /// A library row's poster, in points. The picture behind it is asked for in *pixels* — see
    /// `MediaLibraryRow` — because a 36 pt box is 72 px of screen on every Mac made this decade.
    public static let posterSize = CGSize(width: 64, height: 36)
    /// An attachment chip's poster, in points.
    public static let chipPosterSize = CGSize(width: 40, height: 26)

    /// The reserved run for a rail's rotated title. Rotated text reports its *unrotated* bounds, so
    /// the length has to be named rather than measured.
    public static let railTitleRun: CGFloat = 84

    // MARK: Type roles

    /// A panel header's name. The only bold text in a panel.
    public static let panelTitle = Font.caption.weight(.semibold)
    /// A named group inside a panel body. `Form`'s own `Section` headers are left to SwiftUI.
    public static let sectionTitle = Font.headline
    /// A list row's first line.
    public static let rowTitle = Font.subheadline
    /// Prose the human reads at length: a transcript message, an approval summary.
    public static let bodyText = Font.body
    /// Secondary text: hints, empty states, one-line errors.
    public static let caption = Font.caption
    /// Tertiary metadata: badges, counts, "running", a cost.
    public static let detail = Font.caption2
    /// A tool name, a path, a shell command.
    public static let mono = Font.system(.caption, design: .monospaced)
    /// A JSON blob or a transcript dump.
    public static let monoSmall = Font.system(.caption2, design: .monospaced)
    /// A number that must not jitter as it counts: a cost, a percentage, a timecode.
    public static let monoDigit = Font.caption2.monospacedDigit()

    // MARK: Fills and strokes

    /// Headers and status bars.
    public static let barMaterial: Material = .bar
    /// A card floating over a panel.
    public static let cardMaterial: Material = .regularMaterial
    /// A text field or composer plate.
    public static let fieldFill = AnyShapeStyle(.background.secondary)
    /// What the assistant said.
    public static let bubbleFill = AnyShapeStyle(.quinary)
    /// What the human said. The accent wash is the only place the accent colour fills anything.
    public static let ownBubbleFill = AnyShapeStyle(Color.accentColor.opacity(0.14))
    /// A chip, and the placeholder behind a poster that has not landed.
    public static let chipFill = AnyShapeStyle(.quaternary)
    public static let posterFill = AnyShapeStyle(.quaternary)

    /// A resting border.
    public static let borderIdle = Color.secondary.opacity(0.25)
    /// A border that is saying something: a drop is over this target.
    public static let borderActive = Color.accentColor
    public static let borderWidth: CGFloat = 1
    public static let borderWidthActive: CGFloat = 2

    /// Something needs attention but nothing failed: a missing file, an unaudited client.
    public static let warning = Color.orange
    /// Something failed.
    public static let danger = Color.red

    // MARK: The timeline bridge

    /// A scene colour as a SwiftUI colour, for chrome that labels something the timeline drew — a
    /// track-kind swatch, a link-group dot. sRGB, not linear: the renderer writes these floats to
    /// BGRA8 unmanaged, so sRGB is what the screen actually shows. One-way; nothing converts back.
    public static func color(_ c: SceneColor) -> Color {
        Color(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b), opacity: Double(c.a))
    }
}
