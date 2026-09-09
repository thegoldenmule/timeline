import AVFoundation
import Contracts
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Metal
import TimelineCore
import os

/// The one compositor for preview, frame grabs, and export: Core Image on a Metal-backed `CIContext`.
/// AVFoundation instantiates it (`customVideoCompositorClass`) and calls `startRequest` on its own serial
/// queue, so the class is `@unchecked Sendable` with lock-guarded caches; anything sized to the render context
/// is rebuilt in `renderContextChanged`.
///
/// Colour: the SDR compositor declares no HDR/wide-colour support and no self-conforming, so the engine hands
/// every source over as BT.709 8-bit YUV (tagged), the compositor reads those code values as sRGB, blends, and
/// writes sRGB code values back, which the encoder treats as BT.709 again: a cut passes code values through
/// unchanged and pure green stays pure green. `HDRTimelineCompositor` does the same in 10-bit HLG.
///
/// Blend space (`settings.blendSpace`): gamma uses the output encoding (sRGB / HLG) as the working space so a
/// 50/50 dissolve of red and green reads (128,128,0); linear uses Core Image's default linear working space
/// and reads (188,188,0).
public class TimelineCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    static let captionCacheLimit = 64

    struct Caches {
        var contexts: [BlendSpace: CIContext] = [:]
        var captions: [String: CIImage] = [:]
        var captionOrder: [String] = []
        var slates: [String: CIImage] = [:]
        var stills: [URL: CIImage] = [:]
        var renderSize: CGSize = .zero
        var background: CIImage?
        var inFlight = 0
        var frames = 0
        var contextChanges = 0
        var compiledIds: Set<CompiledID> = []
    }

    let caches = OSAllocatedUnfairLock(initialState: Caches())

    /// Weak references to every compositor AVFoundation has created, so tests can prove nothing is left in
    /// flight after a scrub and that instances go away with their player items.
    private static let registry = OSAllocatedUnfairLock(initialState: [WeakCompositor]())

    public override required init() {
        super.init()
        TimelineCompositor.registry.withLock { list in
            list.removeAll { $0.value == nil }
            list.append(WeakCompositor(value: self))
        }
    }

    /// The compositors still alive.
    public static var liveInstances: [TimelineCompositor] {
        registry.withLock { list in
            list.removeAll { $0.value == nil }
            return list.compactMap(\.value)
        }
    }

    // MARK: AVVideoCompositing

    class var isHDR: Bool { false }

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ]
        ]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    public var supportsWideColorSourceFrames: Bool { false }
    public var supportsHDRSourceFrames: Bool { false }
    public var canConformColorOfSourceFrames: Bool { false }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        let size = newRenderContext.size
        caches.withLock { c in
            c.contextChanges += 1
            c.renderSize = size
            c.background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
            c.captions.removeAll()
            c.captionOrder.removeAll()
            c.slates.removeAll()
        }
    }

    /// Requests are answered synchronously inside `startRequest`, so nothing is ever pending here; the
    /// counters let tests prove no request is left in flight after a scrub.
    public func cancelAllPendingVideoCompositionRequests() {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        caches.withLock { $0.inFlight += 1 }
        defer {
            caches.withLock {
                $0.inFlight -= 1
                $0.frames += 1
            }
        }
        guard let instruction = request.videoCompositionInstruction as? RenderInstruction else {
            request.finish(with: RenderKitError.frameUnavailable("unexpected instruction class"))
            return
        }
        caches.withLock { _ = $0.compiledIds.insert(instruction.compiledId) }
        let contextSize = request.renderContext.size
        let composed = compose(instruction, request: request, contextSize: contextSize)
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: RenderKitError.frameUnavailable("render context has no pixel buffer"))
            return
        }
        TimelineCompositor.tag(output, hdr: instruction.hdr)
        let context = context(for: instruction.blendSpace, hdr: instruction.hdr)
        context.render(
            composed, to: output, bounds: CGRect(origin: .zero, size: contextSize),
            colorSpace: instruction.hdr ? TimelineCompositor.hlg : TimelineCompositor.srgb)
        request.finish(withComposedVideoFrame: output)
    }

    /// Frames composed so far, requests in flight (always 0 between requests), render contexts seen, and the
    /// `Compiled` ids this instance has rendered for.
    public var statistics: (frames: Int, inFlight: Int, contextChanges: Int, compiledIds: Set<CompiledID>) {
        caches.withLock { ($0.frames, $0.inFlight, $0.contextChanges, $0.compiledIds) }
    }

    // MARK: Contexts

    private func context(for blendSpace: BlendSpace, hdr: Bool) -> CIContext {
        caches.withLock { c in
            if let ctx = c.contexts[blendSpace] { return ctx }
            var options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "RenderKit.\(blendSpace)"]
            if blendSpace == .gamma {
                // Blend in the output encoding: no linearisation, so a mid dissolve is the mean of code values.
                options[.workingColorSpace] = hdr ? TimelineCompositor.hlg : TimelineCompositor.srgb
            }
            let ctx =
                TimelineCompositor.device.map { CIContext(mtlDevice: $0, options: options) }
                ?? CIContext(options: options)
            c.contexts[blendSpace] = ctx
            return ctx
        }
    }

    static func tag(_ buffer: CVPixelBuffer, hdr: Bool) {
        let primaries = hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2
        let transfer = hdr ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2
        let matrix = hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
    }

    // MARK: Composition

    private func compose(
        _ instruction: RenderInstruction, request: AVAsynchronousVideoCompositionRequest, contextSize: CGSize
    )
        -> CIImage
    {
        let sequenceSize = instruction.sequenceSize
        let sequenceRect = CGRect(origin: .zero, size: sequenceSize)
        let time = request.compositionTime
        let inputSpace = instruction.hdr ? TimelineCompositor.hlg : TimelineCompositor.srgb
        let black = CIImage(color: .black).cropped(to: sequenceRect)
        var canvas = black

        let layers = instruction.layers
        var i = 0
        while i < layers.count {
            let layer = layers[i]
            if let transition = instruction.transitions[layer.trackIndex], i + 1 < layers.count,
                layers[i + 1].trackIndex == layer.trackIndex, transition.fromClip == layer.clipId,
                transition.toClip == layers[i + 1].clipId
            {
                let from = layerImage(
                    layer, request: request, time: time, sequenceRect: sequenceRect, inputSpace: inputSpace)
                let to = layerImage(
                    layers[i + 1], request: request, time: time, sequenceRect: sequenceRect, inputSpace: inputSpace)
                let blended = blend(
                    from ?? black, to ?? black, transition: transition, time: time, sequenceRect: sequenceRect)
                canvas = blended.composited(over: canvas)
                i += 2
            } else {
                if let image = layerImage(
                    layer, request: request, time: time, sequenceRect: sequenceRect, inputSpace: inputSpace)
                {
                    canvas = image.composited(over: canvas)
                }
                i += 1
            }
        }

        for caption in instruction.captions where caption.timeRange.containsTime(time) {
            if let image = captionImage(caption, time: time, sequenceSize: sequenceSize) {
                canvas = image.composited(over: canvas)
            }
        }

        // Sequence space to render-context space: aspect fit, letterboxed on black.
        let scale = min(contextSize.width / sequenceSize.width, contextSize.height / sequenceSize.height)
        let contextRect = CGRect(origin: .zero, size: contextSize)
        if scale == 1, sequenceSize == contextSize {
            return canvas.cropped(to: contextRect)
        }
        let fit = CGAffineTransform(
            translationX: ((contextSize.width - sequenceSize.width * scale) / 2).rounded(),
            y: ((contextSize.height - sequenceSize.height * scale) / 2).rounded()
        ).scaledBy(x: scale, y: scale)
        let background = caches.withLock { $0.background } ?? CIImage(color: .black).cropped(to: contextRect)
        return canvas.transformed(by: fit).composited(over: background).cropped(to: contextRect)
    }

    /// One layer in sequence coordinates: upright, aspect-fitted, transformed, effected, faded.
    private func layerImage(
        _ layer: LayerSpec, request: AVAsynchronousVideoCompositionRequest, time: CMTime, sequenceRect: CGRect,
        inputSpace: CGColorSpace
    ) -> CIImage? {
        guard !layer.hidden else { return nil }
        var image: CIImage
        switch layer.content {
        case .source(let trackID):
            guard let buffer = request.sourceFrame(byTrackID: trackID) else { return nil }
            image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: inputSpace])
            image = TimelineCompositor.upright(image, transform: layer.sourceTransform)
        case .slate(let label):
            image = slateImage(label, sequenceSize: sequenceRect.size)
        case .still(let url):
            guard let still = stillImage(url) else { return nil }
            image = still
        case .generated:
            image = CIImage(color: .black).cropped(to: sequenceRect)
        }

        // Aspect fit into the sequence.
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let s = min(sequenceRect.width / extent.width, sequenceRect.height / extent.height)
        let fit = CGAffineTransform(
            translationX: (sequenceRect.width - extent.width * s) / 2 - extent.minX * s,
            y: (sequenceRect.height - extent.height * s) / 2 - extent.minY * s
        ).scaledBy(x: s, y: s)
        image = image.transformed(by: fit)

        let seconds = (time - layer.clipStart).seconds
        let transform = SequenceCompiler.value(of: layer.transform, at: seconds)
        if transform != .identity {
            let frame = image.extent
            // Model: y down, anchor in unit coordinates of the clip's frame; CI: y up.
            let pivot = CGPoint(
                x: frame.minX + frame.width * transform.anchorX, y: frame.minY + frame.height * (1 - transform.anchorY))
            var m = CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
            m = m.concatenating(CGAffineTransform(scaleX: transform.scale, y: transform.scale))
            m = m.concatenating(CGAffineTransform(rotationAngle: -transform.rotation * .pi / 180))
            m = m.concatenating(CGAffineTransform(translationX: pivot.x + transform.x, y: pivot.y - transform.y))
            image = image.transformed(by: m)
        }

        for effect in layer.effects where effect.enabled {
            image = TimelineCompositor.apply(effect, to: image, seconds: seconds)
        }

        let opacity = SequenceCompiler.value(of: layer.opacity, at: seconds)
        if opacity < 1 {
            image = TimelineCompositor.faded(image, alpha: max(0, opacity))
        }
        return image.cropped(to: sequenceRect)
    }

    /// Applies an AVFoundation display matrix (top-left coordinates) to a CI image (bottom-left) and moves the
    /// result to the origin.
    static func upright(_ image: CIImage, transform: CGAffineTransform) -> CIImage {
        guard transform != .identity else { return image }
        let h = image.extent.height
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        let rotated = image.transformed(by: flipIn.concatenating(transform))
        let outHeight = rotated.extent.height
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: outHeight + 2 * rotated.extent.minY)
        let upright = rotated.transformed(by: flipOut)
        let origin = upright.extent.origin
        return upright.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// Opacity: `CIColorMatrix` works on unpremultiplied colour (Core Image premultiplies its output again),
    /// so only alpha is scaled and source-over gives `a * src + (1 - a) * dst`.
    static func faded(_ image: CIImage, alpha: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
    }

    static func apply(_ effect: Effect, to image: CIImage, seconds: Double) -> CIImage {
        func number(_ key: String, _ fallback: Double) -> Double {
            guard let param = effect.params[key] else { return fallback }
            switch param {
            case .constant(let v): return v.numberValue ?? fallback
            case .keyframes(let keys):
                let doubles = keys.compactMap { k -> Keyframe<Double>? in
                    k.value.numberValue.map { Keyframe(t: k.t, value: $0, easing: k.easing) }
                }
                return doubles.isEmpty ? fallback : SequenceCompiler.value(of: .keyframes(doubles), at: seconds)
            }
        }
        switch effect.kind.lowercased() {
        case "blur", "gaussianblur":
            let extent = image.extent
            return image.clampedToExtent().applyingFilter(
                "CIGaussianBlur", parameters: ["inputRadius": number("radius", 10)]
            )
            .cropped(to: extent)
        case "colorcontrols", "color", "colour":
            return image.applyingFilter(
                "CIColorControls",
                parameters: [
                    "inputBrightness": number("brightness", 0), "inputContrast": number("contrast", 1),
                    "inputSaturation": number("saturation", 1),
                ])
        case "invert":
            return image.applyingFilter("CIColorInvert")
        case "grayscale", "mono":
            return image.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
        default:
            return image
        }
    }

    // MARK: Transitions

    private func blend(_ from: CIImage, _ to: CIImage, transition: TransitionSpec, time: CMTime, sequenceRect: CGRect)
        -> CIImage
    {
        let p = transition.progress(at: time)
        let black = CIImage(color: .black).cropped(to: sequenceRect)
        switch transition.kind.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(
            of: "_", with: "")
        {
        case "diptoblack", "fadetoblack", "dip":
            if p < 0.5 {
                return TimelineCompositor.faded(from, alpha: 1 - 2 * p).composited(over: black)
            }
            return TimelineCompositor.faded(to, alpha: 2 * p - 1).composited(over: black)
        case "wipe":
            let w = sequenceRect.width
            let h = sequenceRect.height
            let direction = transition.params["direction"]?.stringValue?.lowercased() ?? "right"
            let reveal: CGRect
            switch direction {
            case "left": reveal = CGRect(x: w * (1 - p), y: 0, width: w * p, height: h)
            case "up": reveal = CGRect(x: 0, y: 0, width: w, height: h * p)
            case "down": reveal = CGRect(x: 0, y: h * (1 - p), width: w, height: h * p)
            default: reveal = CGRect(x: 0, y: 0, width: w * p, height: h)
            }
            return to.cropped(to: reveal).composited(over: from)
        default:
            let filter = CIFilter.dissolveTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.time = Float(p)
            return filter.outputImage ?? to
        }
    }

    // MARK: Captions, slates, stills

    private func captionImage(_ caption: CaptionSpec, time: CMTime, sequenceSize: CGSize) -> CIImage? {
        let active = caption.activeWord(at: time)
        let key =
            "\(caption.clipId.rawValue)|\(active ?? -1)|\(caption.text)|\(caption.style.hashValue)|\(sequenceSize)"
        if let cached = caches.withLock({ $0.captions[key] }) { return cached }
        guard let placement = CaptionRenderer.caption(caption, activeWord: active, sequenceSize: sequenceSize) else {
            return nil
        }
        let image = CIImage(cgImage: placement.image).transformed(
            by: CGAffineTransform(translationX: placement.origin.x, y: placement.origin.y))
        caches.withLock { c in
            c.captions[key] = image
            c.captionOrder.append(key)
            while c.captionOrder.count > TimelineCompositor.captionCacheLimit {
                c.captions[c.captionOrder.removeFirst()] = nil
            }
        }
        return image
    }

    private func slateImage(_ label: String, sequenceSize: CGSize) -> CIImage {
        let key = "\(label)|\(sequenceSize)"
        if let cached = caches.withLock({ $0.slates[key] }) { return cached }
        let image =
            CaptionRenderer.slate(label: label, sequenceSize: sequenceSize).map { CIImage(cgImage: $0) }
            ?? CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.14)).cropped(
                to: CGRect(origin: .zero, size: sequenceSize))
        caches.withLock { $0.slates[key] = image }
        return image
    }

    private func stillImage(_ url: URL) -> CIImage? {
        if let cached = caches.withLock({ $0.stills[url] }) { return cached }
        guard let image = CIImage(contentsOf: url) else { return nil }
        caches.withLock { $0.stills[url] = image }
        return image
    }
}

private struct WeakCompositor {
    weak var value: TimelineCompositor?
}

/// The 10-bit HLG variant, used when every video source is HDR: sources arrive as 10-bit YUV tagged
/// BT.2020/HLG and are passed through untouched on cuts; the output buffers are 10-bit YUV tagged the same way,
/// and the video composition sets `perFrameHDRDisplayMetadataPolicy = .propagate`.
public final class HDRTimelineCompositor: TimelineCompositor, @unchecked Sendable {
    override class var isHDR: Bool { true }

    public override var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ]
        ]
    }

    public override var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
    }

    public override var supportsWideColorSourceFrames: Bool { true }
    public override var supportsHDRSourceFrames: Bool { true }
    public override var canConformColorOfSourceFrames: Bool { true }
}
