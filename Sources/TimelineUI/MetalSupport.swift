import CoreGraphics
import CoreText
import Foundation
import Metal

/// BGRA8 textures from CoreGraphics bitmaps: thumbnails and rasterised labels.
enum MetalTextures {
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// Draws `image` into a premultiplied BGRA bitmap and uploads it.
    static func texture(from image: CGImage, device: any MTLDevice) -> (any MTLTexture)? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { ptr -> Bool in
            guard
                let ctx = CGContext(
                    data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return upload(data, width: w, height: h, device: device)
    }

    static func upload(_ data: [UInt8], width w: Int, height h: Int, device: any MTLDevice) -> (any MTLTexture)? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        data.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: w * 4)
        }
        return texture
    }
}

/// White glyph textures for `SceneLabel`s, tinted at draw time. Keyed by text, size, scale, and (only
/// when truncation is needed) the available width, so a thousand clips sharing one asset name share
/// one texture.
@MainActor
final class LabelCache {
    struct Entry {
        var texture: any MTLTexture
        /// Size in points.
        var size: CGSize
    }

    private struct Key: Hashable {
        var text: String
        var fontSize: CGFloat
        var scale: CGFloat
        var maxWidth: Int?
    }

    private let device: any MTLDevice
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var naturalWidths: [String: CGFloat] = [:]
    private var fonts: [CGFloat: CTFont] = [:]
    let capacity: Int

    init(device: any MTLDevice, capacity: Int = 1024) {
        self.device = device
        self.capacity = capacity
    }

    var count: Int { entries.count }

    func font(_ size: CGFloat) -> CTFont {
        if let f = fonts[size] { return f }
        let f =
            CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        fonts[size] = f
        return f
    }

    private func line(_ text: String, size: CGFloat) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font(size), .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    func naturalWidth(_ text: String, size: CGFloat) -> CGFloat {
        let key = "\(size)|\(text)"
        if let w = naturalWidths[key] { return w }
        let w = CGFloat(CTLineGetTypographicBounds(line(text, size: size), nil, nil, nil))
        naturalWidths[key] = w
        return w
    }

    func entry(for label: SceneLabel, scale: CGFloat) -> Entry? {
        guard !label.text.isEmpty, label.maxWidth >= 6 else { return nil }
        let natural = naturalWidth(label.text, size: label.fontSize)
        let truncated = natural > label.maxWidth
        let key = Key(
            text: label.text, fontSize: label.fontSize, scale: scale, maxWidth: truncated ? Int(label.maxWidth) : nil)
        if let e = entries[key] { return e }
        guard
            let e = rasterise(
                label.text, size: label.fontSize, scale: scale, maxWidth: truncated ? label.maxWidth : nil)
        else { return nil }
        if entries.count >= capacity, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
        entries[key] = e
        order.append(key)
        return e
    }

    private func rasterise(_ text: String, size: CGFloat, scale: CGFloat, maxWidth: CGFloat?) -> Entry? {
        var l = line(text, size: size)
        if let maxWidth {
            guard let t = CTLineCreateTruncatedLine(l, Double(maxWidth), .end, nil) else { return nil }
            l = t
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = ceil(CGFloat(CTLineGetTypographicBounds(l, &ascent, &descent, &leading)))
        let height = ceil(ascent + descent)
        guard width >= 1, height >= 1 else { return nil }
        let pw = Int(ceil(width * scale))
        let ph = Int(ceil(height * scale))
        var data = [UInt8](repeating: 0, count: pw * ph * 4)
        let ok = data.withUnsafeMutableBytes { ptr -> Bool in
            guard
                let ctx = CGContext(
                    data: ptr.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: MetalTextures.bitmapInfo)
            else { return false }
            ctx.scaleBy(x: scale, y: scale)
            ctx.setAllowsFontSmoothing(true)
            ctx.setShouldSmoothFonts(false)
            ctx.textPosition = CGPoint(x: 0, y: descent)
            CTLineDraw(l, ctx)
            return true
        }
        guard ok, let texture = MetalTextures.upload(data, width: pw, height: ph, device: device) else { return nil }
        return Entry(texture: texture, size: CGSize(width: width, height: height))
    }
}

/// Pixels read back from an offscreen render, BGRA8, row 0 at the top.
public struct RenderedFrame: Sendable {
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var data: [UInt8]

    public init(width: Int, height: Int, bytesPerRow: Int, data: [UInt8]) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.data = data
    }

    /// The colour at a pixel (r, g, b, a in 0...1).
    public func pixel(x: Int, y: Int) -> SceneColor {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel out of range")
        let i = y * bytesPerRow + x * 4
        return SceneColor(
            Float(data[i + 2]) / 255, Float(data[i + 1]) / 255, Float(data[i]) / 255, Float(data[i + 3]) / 255)
    }

    /// True when every byte is zero.
    public var isBlank: Bool { data.allSatisfy { $0 == 0 } }

    /// Number of pixels whose colour is within `tolerance` (per channel, 0...1) of `color`.
    public func count(of color: SceneColor, tolerance: Float = 0.02) -> Int {
        var n = 0
        for y in 0..<height {
            for x in 0..<width where pixel(x: x, y: y).matches(color, tolerance: tolerance) { n += 1 }
        }
        return n
    }

    public var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: MetalTextures.bitmapInfo),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension SceneColor {
    /// True when every channel is within `tolerance` (alpha ignored).
    public func matches(_ other: SceneColor, tolerance: Float = 0.02) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }
}
