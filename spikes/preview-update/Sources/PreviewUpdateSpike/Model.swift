import AVFoundation

/// Minimal model: N one-second clips laid back-to-back, alternating video tracks 1/2 (audio 3/4), cycling through
/// 4 source files. `opacity` is the only compositor-side (instruction) parameter; `source`/`sourceIn` are segment-side.
struct Clip: Sendable {
    var source: Int; var start: CMTime; var duration: CMTime; var sourceIn: CMTime; var track: Int; var opacity: CGFloat = 1
    var range: CMTimeRange { CMTimeRange(start: start, duration: duration) }
}
struct Timeline: Sendable {
    var clips: [Clip]
    static func synthetic(count: Int) -> Timeline {
        Timeline(clips: (0..<count).map { i in Clip(source: i % 4, start: CMTime(value: Int64(i), timescale: 1), duration: CMTime(value: 1, timescale: 1),
                                                    sourceIn: CMTime(value: Int64(i % 3), timescale: 1), track: 1 + i % 2) })
    }
}
enum Colors {
    static let rgb = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
    /// Expected sRGB centre colour after compositing: opacity is applied in CI's linear working space, so 0.5 -> ~186/255.
    static func expected(_ c: Clip) -> (Int, Int, Int) {
        let k = pow(Double(c.opacity), 1 / 2.2), e = rgb[c.source]
        return (Int(Double(e.0) * k), Int(Double(e.1) * k), Int(Double(e.2) * k))
    }
}
func near(_ c: (Int, Int, Int), _ e: (Int, Int, Int), tol: Int = 48) -> Bool { abs(c.0 - e.0) <= tol && abs(c.1 - e.1) <= tol && abs(c.2 - e.2) <= tol }

final class Instr: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid   // always run the compositor so per-frame cost is measurable
    let base: CMPersistentTrackID
    let opacity: CGFloat
    init(_ c: Clip) { timeRange = c.range; base = CMPersistentTrackID(c.track); opacity = c.opacity; requiredSourceTrackIDs = [NSNumber(value: base)] }
}

/// Compiles a Timeline into AVFoundation objects. Source tracks are loaded once and cached (loadTracks is async and
/// is the only part of compilation that touches the disk).
@MainActor final class Compiler {
    let sources: [URL]
    private(set) var tracks: [(v: AVAssetTrack, a: AVAssetTrack)] = []
    private var assets: [AVURLAsset] = []   // AVAssetTrack.asset is weak: letting the asset die makes insertTimeRange fail with -12780
    init(sources: [URL]) { self.sources = sources }

    func preload() async throws {
        tracks = []; assets = []
        for url in sources {
            let asset = AVURLAsset(url: url); assets.append(asset)
            tracks.append((try await asset.loadTracks(withMediaType: .video)[0], try await asset.loadTracks(withMediaType: .audio)[0]))
        }
    }
    func buildComposition(_ tl: Timeline) throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        let v = [1, 2].map { comp.addMutableTrack(withMediaType: .video, preferredTrackID: CMPersistentTrackID($0))! }
        let a = [3, 4].map { comp.addMutableTrack(withMediaType: .audio, preferredTrackID: CMPersistentTrackID($0))! }
        for c in tl.clips {
            let src = tracks[c.source], r = CMTimeRange(start: c.sourceIn, duration: c.duration)
            try v[c.track - 1].insertTimeRange(r, of: src.v, at: c.start)
            try a[c.track - 1].insertTimeRange(r, of: src.a, at: c.start)
        }
        return comp
    }
    func buildVideoComposition(_ tl: Timeline) -> AVMutableVideoComposition {
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = Compositor.self
        vc.frameDuration = CMTime(value: 1, timescale: Media.fps)
        vc.renderSize = CGSize(width: Media.width, height: Media.height)
        vc.instructions = tl.clips.map(Instr.init)
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return vc
    }
    /// Strategy C: splice a new source into the live composition's tracks in place (video + audio).
    func spliceInPlace(_ comp: AVMutableComposition, old: Clip, new: Clip) throws {
        let src = tracks[new.source]
        for (id, srcTrack) in [(old.track, src.v), (old.track + 2, src.a)] {
            let t = comp.tracks.first { $0.trackID == CMPersistentTrackID(id) }!
            t.removeTimeRange(old.range)   // shifts later segments earlier...
            try t.insertTimeRange(CMTimeRange(start: new.sourceIn, duration: new.duration), of: srcTrack, at: new.start)  // ...and this shifts them back
        }
    }
}
