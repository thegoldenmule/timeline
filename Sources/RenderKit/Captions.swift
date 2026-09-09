import CoreGraphics
import CoreText
import Foundation
import TimelineCore

/// Core Text rendering for captions and slates, inside the compositor (Core Animation captions only work in
/// export, see docs/research/README.md). Produces sRGB CGImages in sequence pixels; the compositor caches them.
enum CaptionRenderer {
    static let defaultFont = "HelveticaNeue-Bold"
    static let highlightColor = CGColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 1)
    static let defaultColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let slateBackground = CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    struct Placement {
        var image: CGImage
        /// Bottom-left origin of the image in sequence coordinates (CI space).
        var origin: CGPoint
    }

    /// Renders the caption with `activeWord` highlighted, placed by `style.position` within `sequenceSize`.
    static func caption(_ spec: CaptionSpec, activeWord: Int?, sequenceSize: CGSize) -> Placement? {
        let words = spec.words.isEmpty ? spec.text.split(separator: " ").map(String.init) : spec.words.map(\.text)
        let fontSize = spec.style.fontSize ?? (sequenceSize.height * 0.05).rounded()
        let font = CTFontCreateWithName((spec.style.fontFamily ?? defaultFont) as CFString, fontSize, nil)
        let color = spec.style.color.flatMap(parseColor) ?? defaultColor
        let attributed = NSMutableAttributedString()
        for (i, word) in words.enumerated() {
            let wordColor = i == activeWord ? highlightColor : color
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): wordColor,
            ]
            attributed.append(NSAttributedString(string: (i == 0 ? "" : " ") + word, attributes: attrs))
        }
        guard attributed.length > 0 else { return nil }
        let background = spec.style.backgroundColor.flatMap(parseColor)
        guard let image = draw(attributed, fontSize: fontSize, background: background) else { return nil }
        let x = ((sequenceSize.width - CGFloat(image.width)) / 2).rounded()
        let y: CGFloat
        switch (spec.style.position ?? "bottom").lowercased() {
        case "top": y = (sequenceSize.height * 0.92 - CGFloat(image.height)).rounded()
        case "center", "middle": y = ((sequenceSize.height - CGFloat(image.height)) / 2).rounded()
        default: y = (sequenceSize.height * 0.08).rounded()
        }
        return Placement(image: image, origin: CGPoint(x: x, y: y))
    }

    /// A full-frame slate for an offline asset.
    static func slate(label: String, sequenceSize: CGSize) -> CGImage? {
        let w = max(2, Int(sequenceSize.width))
        let h = max(2, Int(sequenceSize.height))
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(slateBackground)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Diagonal hatch so the slate is unmistakable even when scaled down.
        ctx.setStrokeColor(CGColor(srgbRed: 0.25, green: 0.25, blue: 0.28, alpha: 1))
        ctx.setLineWidth(CGFloat(max(2, h / 200)))
        let step = CGFloat(max(24, h / 12))
        var x = -CGFloat(h)
        while x < CGFloat(w) {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x + CGFloat(h), y: CGFloat(h)))
            x += step
        }
        ctx.strokePath()
        let fontSize = (sequenceSize.height * 0.045).rounded()
        let font = CTFontCreateWithName(defaultFont as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Offline: \(label)", attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        ctx.textPosition = CGPoint(
            x: (CGFloat(w) - bounds.width) / 2 - bounds.minX, y: (CGFloat(h) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    private static func draw(_ text: NSAttributedString, fontSize: CGFloat, background: CGColor?) -> CGImage? {
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        let pad = max(6, fontSize * 0.3)
        let w = Int((bounds.width + pad * 2).rounded(.up))
        let h = Int((bounds.height + pad * 2).rounded(.up))
        guard w > 0, h > 0,
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if let background {
            ctx.setFillColor(background)
            let box = CGPath(
                roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: pad * 0.6, cornerHeight: pad * 0.6,
                transform: nil)
            ctx.addPath(box)
            ctx.fillPath()
        }
        ctx.setShadow(
            offset: CGSize(width: fontSize * 0.04, height: -fontSize * 0.04), blur: fontSize * 0.08,
            color: CGColor(gray: 0, alpha: 0.9))
        ctx.textPosition = CGPoint(x: pad - bounds.minX, y: pad - bounds.minY)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    /// `#rgb`, `#rrggbb`, or `#rrggbbaa`.
    static func parseColor(_ hex: String) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r: Double
        let g: Double
        let b: Double
        var a = 1.0
        switch s.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default: return nil
        }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
