import Contracts
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import TimelineCore

/// The Metal shaders, compiled at runtime so the package needs no `.metal` resource.
private let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 viewport; };

    struct SolidVertex {
        float2 position;
        float2 local;
        float2 size;
        float radius;
        float pad;
        float4 color;
    };

    struct SolidOut {
        float4 position [[position]];
        float4 color;
        float2 local;
        float2 size;
        float radius;
    };

    vertex SolidOut solid_vertex(uint vid [[vertex_id]], const device SolidVertex *v [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]]) {
        SolidVertex in = v[vid];
        SolidOut o;
        float2 ndc = float2(in.position.x / u.viewport.x * 2.0 - 1.0, 1.0 - in.position.y / u.viewport.y * 2.0);
        o.position = float4(ndc, 0.0, 1.0);
        o.color = in.color;
        o.local = in.local;
        o.size = in.size;
        o.radius = in.radius;
        return o;
    }

    fragment float4 solid_fragment(SolidOut in [[stage_in]]) {
        float alpha = in.color.a;
        if (in.radius > 0.0) {
            float2 halfSize = in.size * 0.5;
            float2 p = in.local - halfSize;
            float2 q = abs(p) - (halfSize - in.radius);
            float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - in.radius;
            alpha *= 1.0 - smoothstep(-0.6, 0.6, d);
        }
        return float4(in.color.rgb * alpha, alpha);
    }

    struct TexVertex {
        float2 position;
        float2 uv;
        float4 tint;
    };

    struct TexOut {
        float4 position [[position]];
        float2 uv;
        float4 tint;
    };

    vertex TexOut textured_vertex(uint vid [[vertex_id]], const device TexVertex *v [[buffer(0)]],
                                  constant Uniforms &u [[buffer(1)]]) {
        TexVertex in = v[vid];
        TexOut o;
        float2 ndc = float2(in.position.x / u.viewport.x * 2.0 - 1.0, 1.0 - in.position.y / u.viewport.y * 2.0);
        o.position = float4(ndc, 0.0, 1.0);
        o.uv = in.uv;
        o.tint = in.tint;
        return o;
    }

    fragment float4 textured_fragment(TexOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                      sampler s [[sampler(0)]]) {
        float4 c = tex.sample(s, in.uv);
        return c * float4(in.tint.rgb * in.tint.a, in.tint.a);
    }
    """

struct SolidVertex {
    var position: SIMD2<Float>
    var local: SIMD2<Float>
    var size: SIMD2<Float>
    var radius: Float
    var pad: Float = 0
    var color: SIMD4<Float>
}

struct TexVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var tint: SIMD4<Float>
}

struct Uniforms {
    var viewport: SIMD2<Float>
}

public enum TimelineRendererError: Error {
    case noDevice
    case noCommandQueue
    case shaderCompilation(String)
    case pipeline(String)
    case texture
}

/// Timings and counts of the last encoded frame.
public struct FrameStats: Sendable, Hashable {
    public var drawCalls = 0
    public var solidVertices = 0
    public var texturedVertices = 0
    /// Scene build plus encode, milliseconds.
    public var cpuMilliseconds: Double = 0
    /// Encode to GPU completion for offscreen renders, milliseconds.
    public var totalMilliseconds: Double = 0
    public init() {}
}

/// Draws a `TimelineScene` with Metal: one solid pipeline (rounded rects by signed distance, plain
/// triangles for wedges and waveforms) and one textured pipeline (filmstrip frames and labels). Vertex
/// data is rebuilt every frame from the scene, which is already culled, into a triple-buffered ring.
@MainActor
public final class TimelineRenderer {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let solidPipeline: any MTLRenderPipelineState
    private let texturedPipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    private let labels: LabelCache
    private var solidBuffers: [(any MTLBuffer)?] = [nil, nil, nil]
    private var texBuffers: [(any MTLBuffer)?] = [nil, nil, nil]
    private var frameIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    public var mediaCache: TimelineMediaCache?
    public private(set) var lastFrameStats = FrameStats()

    public static let pixelFormat = MTLPixelFormat.bgra8Unorm

    public init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw TimelineRendererError.noCommandQueue }
        self.queue = queue
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw TimelineRendererError.shaderCompilation(String(describing: error))
        }
        func pipeline(_ vertex: String, _ fragment: String) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let c = d.colorAttachments[0]!
            c.pixelFormat = TimelineRenderer.pixelFormat
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                throw TimelineRendererError.pipeline(String(describing: error))
            }
        }
        solidPipeline = try pipeline("solid_vertex", "solid_fragment")
        texturedPipeline = try pipeline("textured_vertex", "textured_fragment")
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else {
            throw TimelineRendererError.pipeline("sampler")
        }
        self.sampler = sampler
        labels = LabelCache(device: device)
    }

    public convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw TimelineRendererError.noDevice }
        try self.init(device: device)
    }

    public var labelCacheCount: Int { labels.count }

    public func makeCommandBuffer() -> (any MTLCommandBuffer)? { queue.makeCommandBuffer() }

    // MARK: Encoding

    /// Encodes `scene` into `renderPass` on `commandBuffer`. Waits for a ring slot when three frames are
    /// already in flight.
    public func encode(
        scene: TimelineScene, scale: CGFloat, renderPass: MTLRenderPassDescriptor, commandBuffer: any MTLCommandBuffer
    ) {
        let started = CACurrentMediaTime()
        inFlight.wait()
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        frameIndex = (frameIndex + 1) % 3
        var stats = FrameStats()

        // 1. Vertex data.
        var solid: [SolidVertex] = []
        solid.reserveCapacity((scene.quads.count + scene.overlayQuads.count) * 6 + scene.triangles.count * 3)
        for q in scene.quads { appendQuad(&solid, q) }
        let bodyCount = solid.count
        var tex: [TexVertex] = []
        var texDraws: [(texture: any MTLTexture, start: Int, count: Int)] = []
        for strip in scene.filmstrips {
            guard let frames = mediaCache?.filmstrip(strip.key), !frames.isEmpty else { continue }
            appendFilmstrip(&tex, &texDraws, strip, frames)
        }
        for w in scene.waveforms {
            guard let peaks = mediaCache?.peaks(w.key), peaks.count > 1 else { continue }
            appendWaveform(&solid, w, peaks)
        }
        for t in scene.triangles { appendTriangle(&solid, t) }
        for q in scene.overlayQuads { appendQuad(&solid, q) }
        let overlayCount = solid.count - bodyCount
        let labelStart = tex.count
        var labelDraws: [(texture: any MTLTexture, start: Int, count: Int)] = []
        for label in scene.labels {
            guard let entry = labels.entry(for: label, scale: scale) else { continue }
            let start = tex.count
            appendTexturedQuad(
                &tex, rect: CGRect(origin: label.origin, size: entry.size), uv: CGRect(x: 0, y: 0, width: 1, height: 1),
                tint: label.color)
            labelDraws.append((entry.texture, start, tex.count - start))
        }
        _ = labelStart

        // 2. Buffers.
        let solidBuffer = buffer(&solidBuffers[frameIndex], bytes: solid, minimum: 64 << 10)
        let texBuffer = buffer(&texBuffers[frameIndex], bytes: tex, minimum: 64 << 10)

        // 3. Encode.
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        let bg = scene.background
        renderPass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg.r), green: Double(bg.g), blue: Double(bg.b), alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
        var uniforms = Uniforms(viewport: SIMD2(Float(scene.size.width), Float(scene.size.height)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        if bodyCount > 0, let solidBuffer {
            encoder.setRenderPipelineState(solidPipeline)
            encoder.setVertexBuffer(solidBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: bodyCount)
            stats.drawCalls += 1
        }
        if !texDraws.isEmpty, let texBuffer {
            encoder.setRenderPipelineState(texturedPipeline)
            encoder.setVertexBuffer(texBuffer, offset: 0, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            for d in texDraws {
                encoder.setFragmentTexture(d.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: d.start, vertexCount: d.count)
                stats.drawCalls += 1
            }
        }
        if overlayCount > 0, let solidBuffer {
            encoder.setRenderPipelineState(solidPipeline)
            encoder.setVertexBuffer(solidBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: bodyCount, vertexCount: overlayCount)
            stats.drawCalls += 1
        }
        if !labelDraws.isEmpty, let texBuffer {
            encoder.setRenderPipelineState(texturedPipeline)
            encoder.setVertexBuffer(texBuffer, offset: 0, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            for d in labelDraws {
                encoder.setFragmentTexture(d.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: d.start, vertexCount: d.count)
                stats.drawCalls += 1
            }
        }
        encoder.endEncoding()
        stats.solidVertices = solid.count
        stats.texturedVertices = tex.count
        stats.cpuMilliseconds = (CACurrentMediaTime() - started) * 1000
        lastFrameStats = stats
    }

    /// Renders `scene` into a new texture and reads the pixels back. Synchronous; for tests and thumbnails.
    public func render(scene: TimelineScene, scale: CGFloat = 1) throws -> RenderedFrame {
        let started = CACurrentMediaTime()
        let w = max(1, Int((scene.size.width * scale).rounded()))
        let h = max(1, Int((scene.size.height * scale).rounded()))
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TimelineRenderer.pixelFormat, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        let unified = device.hasUnifiedMemory
        desc.storageMode = unified ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: desc), let cb = queue.makeCommandBuffer() else {
            throw TimelineRendererError.texture
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        encode(scene: scene, scale: scale, renderPass: pass, commandBuffer: cb)
        if !unified, let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        data.withUnsafeMutableBytes { ptr in
            texture.getBytes(
                ptr.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        lastFrameStats.totalMilliseconds = (CACurrentMediaTime() - started) * 1000
        return RenderedFrame(width: w, height: h, bytesPerRow: bytesPerRow, data: data)
    }

    // MARK: Geometry helpers

    private func buffer<T>(_ slot: inout (any MTLBuffer)?, bytes: [T], minimum: Int) -> (any MTLBuffer)? {
        let needed = max(1, bytes.count) * MemoryLayout<T>.stride
        if slot == nil || slot!.length < needed {
            slot = device.makeBuffer(length: max(minimum, needed * 2), options: .storageModeShared)
        }
        guard let b = slot else { return nil }
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { src in
                b.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }
        return b
    }

    private func appendQuad(_ out: inout [SolidVertex], _ q: SceneQuad) {
        let r = q.rect
        let color = SIMD4<Float>(q.color.r, q.color.g, q.color.b, q.color.a)
        let size = SIMD2<Float>(Float(r.width), Float(r.height))
        let radius = Float(min(q.cornerRadius, min(r.width, r.height) / 2))
        func v(_ x: CGFloat, _ y: CGFloat, _ lx: Float, _ ly: Float) -> SolidVertex {
            SolidVertex(
                position: SIMD2(Float(x), Float(y)), local: SIMD2(lx, ly), size: size, radius: radius, color: color)
        }
        let a = v(r.minX, r.minY, 0, 0)
        let b = v(r.maxX, r.minY, size.x, 0)
        let c = v(r.maxX, r.maxY, size.x, size.y)
        let d = v(r.minX, r.maxY, 0, size.y)
        out.append(contentsOf: [a, b, c, a, c, d])
    }

    private func appendTriangle(_ out: inout [SolidVertex], _ t: SceneTriangle) {
        let color = SIMD4<Float>(t.color.r, t.color.g, t.color.b, t.color.a)
        for p in [t.a, t.b, t.c] {
            out.append(
                SolidVertex(
                    position: SIMD2(Float(p.x), Float(p.y)), local: .zero, size: SIMD2(1, 1), radius: 0, color: color))
        }
    }

    private func appendWaveform(_ out: inout [SolidVertex], _ w: SceneWaveform, _ peaks: WaveformPeaks) {
        let r = w.rect
        let columns = peaks.count
        let stride = max(1, Int((CGFloat(columns) / max(1, r.width * 2)).rounded(.up)))
        let color = SIMD4<Float>(w.color.r, w.color.g, w.color.b, w.color.a)
        let mid = Float(r.midY)
        let half = Float(r.height / 2)
        func column(_ i: Int) -> (x: Float, top: Float, bottom: Float) {
            let x = Float(r.minX) + Float(i) * Float(r.width) / Float(max(1, columns - 1))
            let mx = max(-1, min(1, peaks.max[i]))
            let mn = max(-1, min(1, peaks.min[i]))
            return (x, mid - mx * half, mid - mn * half)
        }
        func v(_ x: Float, _ y: Float) -> SolidVertex {
            SolidVertex(position: SIMD2(x, y), local: .zero, size: SIMD2(1, 1), radius: 0, color: color)
        }
        var i = 0
        while i + stride < columns {
            let a = column(i)
            let b = column(i + stride)
            let topA = v(a.x, min(a.top, a.bottom - 1))
            let botA = v(a.x, a.bottom)
            let topB = v(b.x, min(b.top, b.bottom - 1))
            let botB = v(b.x, b.bottom)
            out.append(contentsOf: [topA, topB, botB, topA, botB, botA])
            i += stride
        }
    }

    private func appendTexturedQuad(_ out: inout [TexVertex], rect r: CGRect, uv: CGRect, tint: SceneColor) {
        let t = SIMD4<Float>(tint.r, tint.g, tint.b, tint.a)
        func v(_ x: CGFloat, _ y: CGFloat, _ u: CGFloat, _ vv: CGFloat) -> TexVertex {
            TexVertex(position: SIMD2(Float(x), Float(y)), uv: SIMD2(Float(u), Float(vv)), tint: t)
        }
        let a = v(r.minX, r.minY, uv.minX, uv.minY)
        let b = v(r.maxX, r.minY, uv.maxX, uv.minY)
        let c = v(r.maxX, r.maxY, uv.maxX, uv.maxY)
        let d = v(r.minX, r.maxY, uv.minX, uv.maxY)
        out.append(contentsOf: [a, b, c, a, c, d])
    }

    private func appendFilmstrip(
        _ out: inout [TexVertex], _ draws: inout [(texture: any MTLTexture, start: Int, count: Int)],
        _ strip: SceneFilmstrip, _ frames: [TimelineMediaCache.FilmstripFrame]
    ) {
        let r = strip.rect
        let slot = r.width / CGFloat(frames.count)
        for (i, frame) in frames.enumerated() {
            let x0 = r.minX + slot * CGFloat(i)
            let aspect = CGFloat(frame.texture.width) / CGFloat(max(1, frame.texture.height))
            let natural = r.height * aspect
            let width = min(slot, natural)
            guard width >= 1 else { continue }
            let uvWidth = width / natural
            let start = out.count
            appendTexturedQuad(
                &out, rect: CGRect(x: x0, y: r.minY, width: width, height: r.height),
                uv: CGRect(x: 0, y: 0, width: uvWidth, height: 1), tint: SceneColor(1, 1, 1, 1))
            draws.append((frame.texture, start, out.count - start))
        }
    }
}
