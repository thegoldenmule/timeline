import Contracts
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import TimelineCore

/// CoreGraphics-only image helpers for the tools' image blocks (no AppKit, so they run off the main
/// actor): PNG and JPEG encoding, the `look_at` contact sheet, and the `align_audio` proof image.
public enum ToolImages {
    public enum Failure: Error, Sendable { case contextFailed, encodingFailed }

    /// Encodes a `CGImage` as PNG through ImageIO.
    public static func png(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return out as Data
    }

    /// Encodes a `CGImage` as JPEG through ImageIO (`quality` 0...1; 0.85 keeps a 1280x720 thumbnail
    /// well under YouTube's 2 MB limit).
    public static func jpeg(_ image: CGImage, quality: Double = 0.85) throws -> Data {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return out as Data
    }

    static func context(width: Int, height: Int) throws -> CGContext {
        guard
            let ctx = CGContext(
                data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.contextFailed }
        return ctx
    }

    static func draw(_ text: String, at point: CGPoint, size: CGFloat, in ctx: CGContext, gray: CGFloat = 1) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: gray, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    /// One labelled cell per thumbnail, `columns` across, labels in seconds. Returns the sheet and its
    /// layout so the structured result can say which cell is which time.
    public struct ContactSheet: Sendable {
        public var image: CGImage
        public var columns: Int
        public var rows: Int
        public var cellWidth: Int
        public var cellHeight: Int
    }

    public static func contactSheet(_ thumbnails: [Thumbnail], columns: Int = 3, labelHeight: Int = 18) throws
        -> ContactSheet
    {
        guard let first = thumbnails.first else { throw Failure.contextFailed }
        let columns = max(1, min(columns, thumbnails.count))
        let rows = (thumbnails.count + columns - 1) / columns
        let cellWidth = thumbnails.map(\.image.width).max() ?? first.image.width
        let cellHeight = (thumbnails.map(\.image.height).max() ?? first.image.height) + labelHeight
        let ctx = try context(width: cellWidth * columns, height: cellHeight * rows)
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, thumb) in thumbnails.enumerated() {
            let column = i % columns
            let row = i / columns
            // CoreGraphics origin is bottom-left; row 0 goes at the top.
            let originY = CGFloat((rows - 1 - row) * cellHeight)
            let originX = CGFloat(column * cellWidth)
            ctx.draw(
                thumb.image,
                in: CGRect(
                    x: originX, y: originY + CGFloat(labelHeight), width: CGFloat(thumb.image.width),
                    height: CGFloat(thumb.image.height)))
            draw(
                String(format: "#%d  %.3fs", i, thumb.time.seconds), at: CGPoint(x: originX + 4, y: originY + 4),
                size: 11, in: ctx)
        }
        guard let image = ctx.makeImage() else { throw Failure.contextFailed }
        return ContactSheet(image: image, columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
    }

    /// The alignment proof: the coarse correlation curve on top, the per-window fine offsets with the
    /// drift line below (inliers filled, outliers hollow).
    public static func alignmentProof(_ proof: AlignmentProof, width: Int = 640, height: Int = 320) throws -> CGImage {
        let ctx = try context(width: width, height: height)
        let w = CGFloat(width)
        let h = CGFloat(height)
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let half = h / 2
        let margin: CGFloat = 24

        // Top: correlation curve.
        let corr = proof.correlation
        if corr.count > 1 {
            let maxAbs = CGFloat(corr.map { abs($0) }.max() ?? 1)
            let scale = maxAbs > 0 ? (half - margin * 2) / maxAbs : 1
            ctx.setStrokeColor(CGColor(red: 0.95, green: 0.55, blue: 0.1, alpha: 1))
            ctx.setLineWidth(1)
            for (i, v) in corr.enumerated() {
                let x = margin + (w - margin * 2) * CGFloat(i) / CGFloat(corr.count - 1)
                let y = half + margin + CGFloat(v) * scale
                if i == 0 { ctx.move(to: CGPoint(x: x, y: y)) } else { ctx.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.strokePath()
            let lagEnd = proof.correlationLagStartSeconds + Double(corr.count - 1) * proof.correlationLagStepSeconds
            draw(
                String(format: "coarse NCC  lag %.2fs .. %.2fs", proof.correlationLagStartSeconds, lagEnd),
                at: CGPoint(x: margin, y: h - 16), size: 10, in: ctx, gray: 0.8)
        }

        // Bottom: fine offsets and drift fit.
        let times = proof.windowTimesSeconds
        let offsets = proof.windowOffsetsMs
        if let tMin = times.min(), let tMax = times.max(), !offsets.isEmpty {
            let fitAt: (Double) -> Double = { t in proof.fitInterceptMs + proof.fitSlopePPM * t / 1000 }
            let allY = offsets + [fitAt(tMin), fitAt(tMax)]
            let yMin = allY.min() ?? 0
            let yMax = allY.max() ?? 1
            let ySpan = max(yMax - yMin, 0.001)
            let tSpan = max(tMax - tMin, 0.001)
            func point(_ t: Double, _ ms: Double) -> CGPoint {
                CGPoint(
                    x: margin + (w - margin * 2) * CGFloat((t - tMin) / tSpan),
                    y: margin + (half - margin * 2) * CGFloat((ms - yMin) / ySpan))
            }
            ctx.setStrokeColor(CGColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1))
            ctx.setLineWidth(1.5)
            ctx.move(to: point(tMin, fitAt(tMin)))
            ctx.addLine(to: point(tMax, fitAt(tMax)))
            ctx.strokePath()
            for (i, t) in times.enumerated() where i < offsets.count {
                let p = point(t, offsets[i])
                let rect = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
                let inlier = i < proof.windowInliers.count ? proof.windowInliers[i] : true
                if inlier {
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fillEllipse(in: rect)
                } else {
                    ctx.setStrokeColor(CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 1))
                    ctx.setLineWidth(1)
                    ctx.strokeEllipse(in: rect)
                }
            }
            draw(
                String(
                    format: "fine offsets (ms) vs time; fit %.3f ms + %.2f ppm, %d/%d inliers", proof.fitInterceptMs,
                    proof.fitSlopePPM, proof.windowInliers.filter { $0 }.count, offsets.count),
                at: CGPoint(x: margin, y: 6), size: 10, in: ctx, gray: 0.8)
        }
        guard let image = ctx.makeImage() else { throw Failure.contextFailed }
        return image
    }
}
