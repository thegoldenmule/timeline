import AVFoundation

/// Rational time, as the model stores it.
struct RTime: Sendable { var value: Int64; var timescale: Int32
    var cm: CMTime { CMTime(value: value, timescale: timescale) }
    static func s(_ x: Double) -> RTime { RTime(value: Int64(x * 600), timescale: 600) } }

struct Transform: Sendable { var scale: CGFloat = 1; var center: CGPoint? = nil; var opacity: CGFloat = 1 }  // center in top-left px coords

struct Clip: Sendable {
    var url: URL
    var timelineStart: RTime
    var sourceIn: RTime, sourceOut: RTime
    var transform: Transform? = nil           // present => this clip is a picture-in-picture overlay
    var crossfadeFromPrevious: RTime? = nil   // overlap duration with the previous (non-PiP) clip
}

struct Caption: Sendable { var text: String; var start: RTime; var end: RTime; var scaleInMs: Int = 300 }

struct Timeline: Sendable { var clips: [Clip]; var caption: Caption? }

/// Per-instruction data carried into the compositor. Must be a class (Obj-C protocol) and Sendable-ish.
final class SpikeInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    struct Layer: Sendable { var trackID: CMPersistentTrackID; var transform: Transform? }
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening: Bool
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let base: CMPersistentTrackID             // full-frame clip
    let crossfadeTo: CMPersistentTrackID?     // if set: dissolve base -> crossfadeTo over timeRange
    let pip: Layer?
    let caption: Caption?

    init(timeRange: CMTimeRange, base: CMPersistentTrackID, crossfadeTo: CMPersistentTrackID? = nil, pip: Layer? = nil, caption: Caption?) {
        self.timeRange = timeRange; self.base = base; self.crossfadeTo = crossfadeTo; self.pip = pip
        // Only carry the caption if it overlaps this instruction.
        if let c = caption, CMTimeRangeGetIntersection(timeRange, otherRange: CMTimeRange(start: c.start.cm, end: c.end.cm)).duration > .zero {
            self.caption = c } else { self.caption = nil }
        var ids = [base]; if let t = crossfadeTo { ids.append(t) }; if let p = pip { ids.append(p.trackID) }
        requiredSourceTrackIDs = ids.map { NSNumber(value: $0) }
        containsTweening = crossfadeTo != nil || self.caption != nil
    }
}

struct Compiled { let composition: AVMutableComposition; let videoComposition: AVMutableVideoComposition; let audioMix: AVMutableAudioMix }

/// Compile the model into AVFoundation objects. Full-frame clips alternate between video tracks 1/2; PiP clips
/// take whichever of the two tracks is free (they never coincide with a crossfade in this spike).
func compile(_ tl: Timeline) async throws -> Compiled {
    let comp = AVMutableComposition()
    let vTracks = [comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!, comp.addMutableTrack(withMediaType: .video, preferredTrackID: 2)!]
    let aTracks = [comp.addMutableTrack(withMediaType: .audio, preferredTrackID: 3)!, comp.addMutableTrack(withMediaType: .audio, preferredTrackID: 4)!]
    let mix = AVMutableAudioMix()
    let params = aTracks.map { AVMutableAudioMixInputParameters(track: $0) }
    struct Placed { let clip: Clip; let track: Int; let range: CMTimeRange }
    var placed: [Placed] = []
    var next = 0
    for clip in tl.clips {
        let asset = AVURLAsset(url: clip.url)
        let v = try await asset.loadTracks(withMediaType: .video)[0], a = try await asset.loadTracks(withMediaType: .audio)[0]
        let src = CMTimeRange(start: clip.sourceIn.cm, end: clip.sourceOut.cm)
        let range = CMTimeRange(start: clip.timelineStart.cm, duration: src.duration)
        let slot: Int
        if clip.transform != nil {  // PiP: pick a track not occupied at this time
            slot = placed.contains { $0.track == 0 && CMTimeRangeGetIntersection($0.range, otherRange: range).duration > .zero } ? 1 : 0
        } else { slot = next; next = 1 - next }
        try vTracks[slot].insertTimeRange(src, of: v, at: range.start)
        try aTracks[slot].insertTimeRange(src, of: a, at: range.start)
        if let xf = clip.crossfadeFromPrevious, let prev = placed.last(where: { $0.clip.transform == nil }) {
            let xr = CMTimeRange(start: range.start, duration: xf.cm)
            params[prev.track].setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: xr)
            params[slot].setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: xr)
        }
        if clip.transform != nil { params[slot].setVolume(0.3, at: range.start) }  // PiP audio ducked
        placed.append(Placed(clip: clip, track: slot, range: range))
    }
    mix.inputParameters = params

    // Build instructions from the sorted set of boundary times.
    var cuts = Set<CMTime>([.zero, comp.duration])
    for p in placed { cuts.insert(p.range.start); cuts.insert(p.range.end)
        if let xf = p.clip.crossfadeFromPrevious { cuts.insert(p.range.start + xf.cm) } }
    if let c = tl.caption { cuts.insert(c.start.cm); cuts.insert(c.end.cm) }
    let times = cuts.sorted()
    var instructions: [SpikeInstruction] = []
    for (t0, t1) in zip(times, times.dropFirst()) {
        let seg = CMTimeRange(start: t0, end: t1), mid = t0 + CMTime(value: seg.duration.value / 2, timescale: seg.duration.timescale)
        let active = placed.filter { $0.range.containsTime(mid) }
        let full = active.filter { $0.clip.transform == nil }.sorted { $0.range.start < $1.range.start }
        let pip = active.first { $0.clip.transform != nil }
        guard let base = full.first else { fatalError("gap in timeline at \(t0.seconds)s") }
        let xfTo = full.count > 1 ? full[1] : nil
        instructions.append(SpikeInstruction(timeRange: seg, base: CMPersistentTrackID(base.track + 1),
            crossfadeTo: xfTo.map { CMPersistentTrackID($0.track + 1) },
            pip: pip.map { .init(trackID: CMPersistentTrackID($0.track + 1), transform: $0.clip.transform) }, caption: tl.caption))
    }
    let vc = AVMutableVideoComposition()
    vc.customVideoCompositorClass = SpikeCompositor.self
    vc.frameDuration = CMTime(value: 1, timescale: Media.fps)
    vc.renderSize = CGSize(width: Media.width, height: Media.height)
    vc.instructions = instructions
    // Without these, source and render-context buffers arrive untagged and CI's colour guess shifts pure green to (0,231,40).
    vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    return Compiled(composition: comp, videoComposition: vc, audioMix: mix)
}
