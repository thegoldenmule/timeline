import AVFoundation
import CoreImage
import Metal
import os

/// Same shape as the compositor spike, reduced to "base frame with optional opacity". Instruction lookup by time is
/// done by AVFoundation before `startRequest`; this class never touches the instruction array, so its per-frame cost
/// is independent of the number of instructions.
final class Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let device = MTLCreateSystemDefaultDevice()!
    // SPIKE_SHARED_CI=1: one process-wide CIContext instead of one per compositor instance (= per AVPlayerItem).
    static let sharedCI = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    static let useShared = ProcessInfo.processInfo.environment["SPIKE_SHARED_CI"] == "1"
    private let ci: CIContext
    static let bgra: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    struct Stats {
        var frames = 0; var totalNs: UInt64 = 0; var maxNs: UInt64 = 0; var contextChanges = 0; var instances = 0
        var markNs: UInt64 = 0; var initAtMs = 0.0; var ciInitMs = 0.0; var contextAtMs = 0.0; var firstRequestAtMs = 0.0   // lifecycle of the item created after mark()
    }
    static let stats = OSAllocatedUnfairLock(initialState: Stats())
    static func resetStats() { stats.withLock { $0 = Stats() } }
    static func mark() { stats.withLock { $0.markNs = DispatchTime.now().uptimeNanoseconds; $0.initAtMs = 0; $0.ciInitMs = 0; $0.contextAtMs = 0; $0.firstRequestAtMs = 0 } }
    static func sinceMark(_ s: Stats) -> Double { Double(DispatchTime.now().uptimeNanoseconds - s.markNs) / 1e6 }

    override init() {
        let t0 = DispatchTime.now().uptimeNanoseconds
        ci = Self.useShared ? Self.sharedCI : CIContext(mtlDevice: Self.device, options: [.cacheIntermediates: false])
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        super.init()
        Self.stats.withLock { $0.instances += 1; if $0.initAtMs == 0 { $0.initAtMs = Self.sinceMark($0); $0.ciInitMs = dt } }
    }
    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.bgra }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.bgra }
    func renderContextChanged(_ ctx: AVVideoCompositionRenderContext) { Self.stats.withLock { $0.contextChanges += 1; if $0.contextAtMs == 0 { $0.contextAtMs = Self.sinceMark($0) } } }
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        Self.stats.withLock { if $0.firstRequestAtMs == 0 { $0.firstRequestAtMs = Self.sinceMark($0) } }
        guard let ins = req.videoCompositionInstruction as? Instr, let src = req.sourceFrame(byTrackID: ins.base) else {
            return req.finish(with: NSError(domain: "spike", code: 10, userInfo: [NSLocalizedDescriptionKey: "unexpected instruction / missing source"])) }
        var img = CIImage(cvPixelBuffer: src)
        if ins.opacity < 1 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: ins.opacity)])
                .composited(over: CIImage(color: .black).cropped(to: img.extent))
        }
        guard let dst = req.renderContext.newPixelBuffer() else {
            return req.finish(with: NSError(domain: "spike", code: 11, userInfo: [NSLocalizedDescriptionKey: "no pixel buffer"])) }
        ci.render(img, to: dst, bounds: CGRect(origin: .zero, size: req.renderContext.size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let dt = DispatchTime.now().uptimeNanoseconds - t0
        Self.stats.withLock { $0.frames += 1; $0.totalNs += dt; $0.maxNs = max($0.maxNs, dt) }
        req.finish(withComposedVideoFrame: dst)
    }
}
