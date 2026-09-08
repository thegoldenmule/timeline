import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Metal
import os

/// One compositor for preview, frame grabs, and export. AVFoundation instantiates this itself (via
/// `customVideoCompositorClass`) and calls `startRequest` on its own serial background queue, so the class is
/// `@unchecked Sendable` and guards its mutable state with a lock.
final class SpikeCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let device = MTLCreateSystemDefaultDevice()!
    // SPIKE_NO_CM=1 disables CI colour management (gamma-space blending, no input/output conversion) for comparison.
    static let noCM = ProcessInfo.processInfo.environment["SPIKE_NO_CM"] == "1"
    private let ci = CIContext(mtlDevice: device, options: noCM
        ? [.cacheIntermediates: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()] : [.cacheIntermediates: false])
    private let lock = OSAllocatedUnfairLock()
    private var captionCache: [String: CIImage] = [:]
    nonisolated(unsafe) static var frameCount = 0          // instrumentation only
    nonisolated(unsafe) static var renderContextChanges = 0
    nonisolated(unsafe) static var queueLabels = Set<String>()

    // BGRA8 for this spike. 10-bit / HDR declarations below compile on this SDK (see SPIKE.md); untested with HDR media.
    static let bgra: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    static let tenBit: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String:
        [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_4444AYpCbCr16, kCVPixelFormatType_64RGBAHalf]]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.bgra }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.bgra }
    var supportsWideColorSourceFrames: Bool { true }
    var supportsHDRSourceFrames: Bool { true }
    var canConformColorOfSourceFrames: Bool { true }

    func renderContextChanged(_ ctx: AVVideoCompositionRenderContext) { Self.renderContextChanges += 1 }
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
        Self.queueLabels.insert(String(cString: __dispatch_queue_get_label(nil)))
        guard let ins = req.videoCompositionInstruction as? SpikeInstruction else {
            return req.finish(with: NSError(domain: "spike", code: 10, userInfo: [NSLocalizedDescriptionKey: "unexpected instruction"])) }
        let size = req.renderContext.size
        let t = req.compositionTime.seconds
        func frame(_ id: CMPersistentTrackID) -> CIImage? { req.sourceFrame(byTrackID: id).map { CIImage(cvPixelBuffer: $0) } }

        var out = frame(ins.base) ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        if let to = ins.crossfadeTo, let b = frame(to) {
            let p = (t - ins.timeRange.start.seconds) / ins.timeRange.duration.seconds
            let f = CIFilter.dissolveTransition(); f.inputImage = out; f.targetImage = b; f.time = Float(min(max(p, 0), 1))
            out = f.outputImage ?? out
        }
        if let pip = ins.pip, let tr = pip.transform, let img = frame(pip.trackID) {
            let w = img.extent.width * tr.scale, h = img.extent.height * tr.scale
            let c = tr.center ?? CGPoint(x: size.width / 2, y: size.height / 2)
            var xf = CGAffineTransform(translationX: c.x - w / 2, y: size.height - c.y - h / 2)   // flip y: model is top-left
            xf = xf.scaledBy(x: tr.scale, y: tr.scale)
            let layer = img.transformed(by: xf).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: tr.opacity)])
            out = layer.composited(over: out)
        }
        if let cap = ins.caption, t >= cap.start.cm.seconds, t < cap.end.cm.seconds {
            let age = t - cap.start.cm.seconds, p = min(1, age / (Double(cap.scaleInMs) / 1000))
            let s = 1 - pow(1 - p, 3)   // ease-out cubic scale-in
            let img = captionImage(cap.text)
            let cx = size.width / 2, cy = size.height * 0.15
            let xf = CGAffineTransform(translationX: cx, y: cy).scaledBy(x: s, y: s).translatedBy(x: -img.extent.midX, y: -img.extent.midY)
            out = img.transformed(by: xf).composited(over: out)
        }
        guard let dst = req.renderContext.newPixelBuffer() else {
            return req.finish(with: NSError(domain: "spike", code: 11, userInfo: [NSLocalizedDescriptionKey: "no pixel buffer"])) }
        ci.render(out, to: dst, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.noCM ? nil : CGColorSpace(name: CGColorSpace.sRGB))
        Self.frameCount += 1
        if Self.frameCount == 1, let src = req.sourceFrame(byTrackID: ins.base) {
            func tags(_ pb: CVPixelBuffer) -> String { ["ColorPrimaries", "TransferFunction", "YCbCrMatrix"].map { k in
                "\(k)=\(CVBufferCopyAttachment(pb, k as CFString, nil).map { "\($0)" } ?? "nil")" }.joined(separator: " ") }
            print("  [compositor] source tags: \(tags(src))\n  [compositor] dest tags (post-render): \(tags(dst))\n  [compositor] renderContext.pixelAspectRatio=\(req.renderContext.pixelAspectRatio) videoComposition.colorPrimaries=\(req.renderContext.videoComposition.colorPrimaries ?? "nil")")
        }
        req.finish(withComposedVideoFrame: dst)
    }

    /// Core Text -> CGImage -> CIImage, cached per text. Yellow 72pt bold with a black shadow.
    private func captionImage(_ text: String) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        if let c = captionCache[text] { return c }
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 72, nil)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 1, green: 0.9, blue: 0, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs)!)
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        let w = Int(bounds.width.rounded(.up)) + 24, h = Int(bounds.height.rounded(.up)) + 24
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setShadow(offset: CGSize(width: 3, height: -3), blur: 6, color: CGColor(gray: 0, alpha: 1))
        ctx.textPosition = CGPoint(x: 12 - bounds.minX, y: 12 - bounds.minY)
        CTLineDraw(line, ctx)
        let img = CIImage(cgImage: ctx.makeImage()!)
        captionCache[text] = img
        return img
    }
}
