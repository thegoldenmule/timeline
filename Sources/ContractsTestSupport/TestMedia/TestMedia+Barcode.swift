// Frame-index barcode: a strip along the top edge of every frame that survives scaling, so tests can assert
// which source frame landed in an output frame (lifted from spikes/compositor, with a sync pattern added).
import CoreGraphics
import Foundation

extension TestMedia {
    /// Layout of the strip. Proportional to the frame so a scaled frame still decodes: 20 equal cells across the
    /// full width, the top `1/24` of the height tall. Cells 0-1 are a white/black sync pair, cells 2-17 carry the
    /// 16-bit frame index MSB first (white = 1), cells 18-19 are a black/white sync pair.
    public enum Barcode {
        public static let cells = 20
        public static let dataBits = 16
        public static let heightFraction = 1.0 / 24.0
        public static let maxIndex = (1 << dataBits) - 1

        /// Strip height in pixels for a frame of the given height.
        public static func stripHeight(forFrameHeight height: Int) -> Int {
            max(8, Int((Double(height) * heightFraction).rounded(.up)))
        }

        /// Cell values for a frame index, left to right.
        static func bits(for index: Int) -> [Bool] {
            precondition(index >= 0 && index <= maxIndex, "frame index out of barcode range")
            var out = [true, false]
            for i in 0..<dataBits { out.append((index >> (dataBits - 1 - i)) & 1 == 1) }
            out.append(false)
            out.append(true)
            return out
        }

        /// Paints the strip into a CG context (bottom-left origin) whose size is `size`.
        static func paint(index: Int, into ctx: CGContext, size: CGSize) {
            let strip = CGFloat(stripHeight(forFrameHeight: Int(size.height)))
            let cellWidth = size.width / CGFloat(cells)
            for (i, bit) in bits(for: index).enumerated() {
                ctx.setFillColor(gray: bit ? 1 : 0, alpha: 1)
                // Overlap cells by a pixel so scaling never leaves a seam of the underlying colour.
                let x0 = (CGFloat(i) * cellWidth).rounded(.down)
                let x1 = (CGFloat(i + 1) * cellWidth).rounded(.up)
                ctx.fill(CGRect(x: x0, y: size.height - strip, width: x1 - x0, height: strip))
            }
        }
    }

    /// Reads the frame index from a frame painted by `barcodeCounter` or `videoWithAudio`. Returns nil when the
    /// strip is missing, a cell is ambiguous (a blend of two frames during a dissolve reads as mid grey), or the
    /// sync cells are wrong.
    public static func decodeFrameIndex(from image: CGImage) -> Int? {
        // Render just the strip at full resolution (CG's downsampling does not area-average) and take the mean
        // luma of the middle half of every cell.
        let w = image.width
        let h = image.height
        let strip = Barcode.stripHeight(forFrameHeight: h)
        guard w >= Barcode.cells, h > strip else { return nil }
        var buf = [UInt8](repeating: 0, count: w * strip * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard
                let ctx = CGContext(
                    data: p.baseAddress, width: w, height: strip, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            // Bottom-left origin: shift the image down so only its top `strip` rows land in the context.
            ctx.draw(image, in: CGRect(x: 0, y: -(h - strip), width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let cellWidth = Double(w) / Double(Barcode.cells)
        var values: [Bool] = []
        values.reserveCapacity(Barcode.cells)
        for i in 0..<Barcode.cells {
            let x0 = Int((Double(i) + 0.25) * cellWidth)
            let x1 = max(x0 + 1, Int((Double(i) + 0.75) * cellWidth))
            var sum = 0
            var n = 0
            for y in (strip / 4)..<max(strip / 4 + 1, strip * 3 / 4) {
                for x in x0..<x1 {
                    let o = (y * w + x) * 4  // BGRA little endian
                    sum += (Int(buf[o + 2]) * 299 + Int(buf[o + 1]) * 587 + Int(buf[o]) * 114) / 1000
                    n += 1
                }
            }
            let luma = sum / n
            if luma >= 170 {
                values.append(true)
            } else if luma <= 85 {
                values.append(false)
            } else {
                return nil
            }
        }
        guard values[0], !values[1], !values[Barcode.cells - 2], values[Barcode.cells - 1] else { return nil }
        var index = 0
        for i in 0..<Barcode.dataBits where values[2 + i] { index |= 1 << (Barcode.dataBits - 1 - i) }
        return index
    }
}
