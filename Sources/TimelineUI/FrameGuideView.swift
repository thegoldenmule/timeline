import CoreGraphics
import Foundation
import Observation
import SwiftUI
import TimelineCore

// MARK: - The geometry

/// Where the frame lands in the preview, and where the footage lands inside the frame.
///
/// The preview hosts `AVPlayerLayer`s with `videoGravity = .resizeAspect` over a black background, and
/// the composition they play is built at the frame's own size
/// (`AVFoundationRenderer.compile`, `renderSize`). So the picture is `min(viewport / frame)` scaled and
/// centred — which is `ExportFraming`'s arithmetic with the viewport as the output. This type is a
/// reading of `ExportFraming`, not a second implementation of the fit: if the guide computed its own,
/// it could drift from what `resizeAspect` actually does and point at the wrong pixels.
///
/// Every rectangle here is in the viewport's points, with the origin at its top-left — the space a
/// `GeometryReader` over the preview hands out.
public struct FrameGuide: Hashable, Sendable {
    /// The preview's bounds, in points.
    public let viewport: CGSize
    /// The frame every clip is fitted into, in pixels.
    public let frameSize: FrameSize
    /// The worst-fitting clip's fit *into that frame*, when the footage does not fill it. Nil when the
    /// footage fills the frame, or when there is no footage to judge.
    public let media: ExportFraming?

    public init(viewport: CGSize, frameSize: FrameSize, media: ExportFraming? = nil) {
        self.viewport = viewport
        self.frameSize = frameSize
        self.media = media
    }

    /// The guide for a sequence's own mismatch: its frame, and the clip that loses the most picture.
    public init(viewport: CGSize, mismatch: FormatMismatch) {
        self.init(
            viewport: viewport, frameSize: mismatch.sequenceSize, media: mismatch.worst?.framing)
    }

    /// Under a point of viewport is nothing to draw into, and a frame with no area cannot be fitted.
    public var isVisible: Bool {
        viewport.width >= 1 && viewport.height >= 1 && frameSize.width > 0 && frameSize.height > 0
    }

    /// The frame fitted into the viewport, the same way the player layer fits the picture.
    public var framing: ExportFraming {
        ExportFraming(
            output: viewport, sequence: CGSize(width: frameSize.width, height: frameSize.height))
    }

    /// Points per frame pixel.
    public var scale: CGFloat { framing.scale }

    /// The guide itself: where the picture starts and stops.
    public var rect: CGRect { framing.fitted }

    /// Where the footage actually lands inside the guide, when it does not fill the frame. The fit is
    /// in frame pixels, so it reaches points through the same scale the frame did.
    public var mediaRect: CGRect? {
        guard let media, !media.isExact else { return nil }
        let fitted = media.fitted
        return CGRect(
            x: rect.minX + fitted.minX * scale, y: rect.minY + fitted.minY * scale,
            width: fitted.width * scale, height: fitted.height * scale)
    }

    /// True when the frame is the viewport's own shape, so there is no surround to wash.
    public var fillsViewport: Bool {
        abs(rect.width - viewport.width) <= ExportFraming.barTolerance
            && abs(rect.height - viewport.height) <= ExportFraming.barTolerance
    }

    /// "2160 × 3840 · 9:16", the shape stated as well as drawn.
    public var label: String {
        let size = CGSize(width: frameSize.width, height: frameSize.height)
        return "\(ExportFraming.pixels(size)) · \(ExportFraming.aspectLabel(size))"
    }

    /// "656 px pillarboxed": what the frame is adding to this footage, in the export sheet's own words.
    public var mediaLabel: String? {
        guard let media, !media.isExact else { return nil }
        return FrameGuideText.bars(media.bars)
    }
}

// MARK: - Copy

public enum FrameGuideText {
    public static let show = "Show frame guide"
    public static let hide = "Hide frame guide"
    public static let help =
        "Draws the frame the picture is fitted into, so black around the picture can be told from black "
        + "inside it."

    /// The compact form of `ExportFraming.barsDescription`, for a badge on the picture rather than a
    /// line in a sheet. Same words, same number.
    public static func bars(_ bars: ExportFraming.Bars) -> String? {
        switch bars {
        case .none: return nil
        case .letterbox(let bar): return "\(Int(bar.rounded())) px \(ExportText.letterboxBadge)"
        case .pillarbox(let bar): return "\(Int(bar.rounded())) px \(ExportText.pillarboxBadge)"
        }
    }
}

// MARK: - The flag

/// Whether the preview draws its frame guide, remembered across launches.
///
/// The `PanelLayoutModel` pattern, key for key: `UserDefaults` read and written here rather than through
/// `@AppStorage` (which only works inside a `View`), the suite injected so a test gets a throwaway one,
/// and `object(forKey:)` rather than `bool(forKey:)` because the latter cannot tell a missing key from a
/// stored `false` — and this flag defaults to *on*. It is not a `PanelID`: the preview is not a panel,
/// and has no width, rail, or `⌥⌘` shortcut to carry.
@MainActor @Observable
public final class PreviewGuideModel {
    static let frameGuideKey = "preview.frameGuide"

    @ObservationIgnored private let defaults: UserDefaults

    public private(set) var showsFrameGuide: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showsFrameGuide = defaults.object(forKey: Self.frameGuideKey) as? Bool ?? true
    }

    public func setShowsFrameGuide(_ value: Bool) {
        showsFrameGuide = value
        defaults.set(value, forKey: Self.frameGuideKey)
    }

    public func toggleFrameGuide() {
        setShowsFrameGuide(!showsFrameGuide)
    }
}

// MARK: - Views

/// The frame drawn over the preview: a stroke on its edge, a wash over everything outside it, the size
/// and aspect in the corner, and — when the footage does not fill the frame — where the footage actually
/// lands and how much black the frame is adding.
///
/// It draws nothing the picture can be confused with and takes no clicks.
public struct FrameGuideOverlay: View {
    public let mismatch: FormatMismatch

    public init(mismatch: FormatMismatch) {
        self.mismatch = mismatch
    }

    public var body: some View {
        GeometryReader { proxy in
            let guide = FrameGuide(viewport: proxy.size, mismatch: mismatch)
            if guide.isVisible {
                ZStack(alignment: .topLeading) {
                    surround(guide, in: proxy.size)
                    if let media = guide.mediaRect {
                        Rectangle()
                            .strokeBorder(
                                PanelTheme.warning,
                                style: StrokeStyle(
                                    lineWidth: PanelTheme.frameGuideWidth, dash: [PanelTheme.rowGap])
                            )
                            .frame(width: media.width, height: media.height)
                            .position(x: media.midX, y: media.midY)
                            .accessibilityIdentifier("frame-guide-media")
                    }
                    Rectangle()
                        .strokeBorder(PanelTheme.frameGuideStroke, lineWidth: PanelTheme.frameGuideWidth)
                        .frame(width: guide.rect.width, height: guide.rect.height)
                        .position(x: guide.rect.midX, y: guide.rect.midY)
                    label(guide)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        // The guide is a drawing, not a control: the button in the corner is the only thing on the
        // preview that answers a click.
        .allowsHitTesting(false)
        .accessibilityIdentifier("frame-guide")
    }

    /// Everything outside the frame, washed so the panel's own black stops reading as picture. Even-odd
    /// over the two rectangles, so the frame itself is left alone.
    @ViewBuilder private func surround(_ guide: FrameGuide, in size: CGSize) -> some View {
        if !guide.fillsViewport {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(guide.rect)
            }
            .fill(PanelTheme.frameGuideSurround, style: FillStyle(eoFill: true))
            .accessibilityIdentifier("frame-guide-surround")
        }
    }

    /// The numbers, inside the frame's top-leading corner so they are read as belonging to it.
    private func label(_ guide: FrameGuide) -> some View {
        VStack(alignment: .leading, spacing: PanelTheme.hairGap) {
            Text(guide.label)
                .font(PanelTheme.monoDigit)
                .accessibilityIdentifier("frame-guide-label")
            if let bars = guide.mediaLabel {
                Text(bars)
                    .font(PanelTheme.monoDigit)
                    .foregroundStyle(PanelTheme.warning)
                    .accessibilityIdentifier("frame-guide-bars")
            }
        }
        .lineLimit(1)
        .padding(.horizontal, PanelTheme.rowGap)
        .padding(.vertical, PanelTheme.hairGap)
        .background(PanelTheme.barMaterial, in: RoundedRectangle(cornerRadius: PanelTheme.posterRadius))
        .padding(PanelTheme.rowGap)
        .offset(x: guide.rect.minX, y: guide.rect.minY)
    }
}

/// The frame guide's switch, on the preview because that is what it is about. It stays visible when the
/// guide is off, which is the only way back.
public struct FrameGuideToggle: View {
    public let isOn: Bool
    public let toggle: () -> Void

    public init(isOn: Bool, toggle: @escaping () -> Void) {
        self.isOn = isOn
        self.toggle = toggle
    }

    public var body: some View {
        Button(action: toggle) {
            // The frame, and the frame struck through: the state is legible without the tooltip, which
            // matters for the off state because then there is nothing else on the preview to read.
            Image(systemName: isOn ? "rectangle.dashed" : "rectangle.slash")
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .padding(PanelTheme.rowGap)
                .background(PanelTheme.barMaterial, in: RoundedRectangle(cornerRadius: PanelTheme.chipRadius))
        }
        .buttonStyle(.plain)
        .help(isOn ? FrameGuideText.hide : FrameGuideText.show)
        .accessibilityLabel(isOn ? FrameGuideText.hide : FrameGuideText.show)
        .accessibilityIdentifier("frame-guide-toggle")
    }
}
