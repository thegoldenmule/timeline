import AVFoundation

func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant = .now) -> Double {
    let d = end - start; return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
func fmt(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "-" }

enum Strategy: String, CaseIterable {
    case A_rebuild, A_preloaded, A_videoOnly, B_videoComposition, C_mutateInPlace, D1_seekBeforeAttach, D2_queuePlayer, D3_secondPlayer
    /// B can only express instruction-level edits; everything else swaps the source of the clip under the playhead.
    var edit: Edit { self == .B_videoComposition ? .opacity : .replaceSource }
}
enum Edit { case opacity, replaceSource }

struct Result {
    var strategy: Strategy; var playing: Bool
    var syncMs = 0.0            // synchronous part on the main actor (compile + object creation + swap call)
    var readyMs: Double?        // item.status == .readyToPlay (new items only)
    var seekMs: Double?         // await item.seek(to: currentTime) on the new item (new items only)
    var frameMs: Double?        // first composed frame reflecting the edit available on the video output
    var seekNeeded = false      // paused: no frame arrived until we re-seeked to the current time
    var maxWallGapMs = 0.0      // longest wall-clock interval between consecutive delivered frames (playing)
    var itemJumpMs = 0.0        // item-time discontinuity at the swap (playing): new frame time - extrapolated old time
    var stalls = 0              // polls where timeControlStatus != .playing while rate should be 1
    var note = ""
}

/// Headless AVQueuePlayer + AVPlayerItemVideoOutput. Everything AVPlayer-related stays on the main actor (AVPlayer,
/// AVPlayerItem and AVPlayerItemVideoOutput are not Sendable).
@MainActor final class Harness {
    let compiler: Compiler
    var player = AVQueuePlayer()
    var timeline: Timeline
    var comp: AVMutableComposition
    var item: AVPlayerItem
    var output: AVPlayerItemVideoOutput
    var frames: [(wall: ContinuousClock.Instant, t: CMTime)] = []
    var stalls = 0

    init(compiler: Compiler, timeline: Timeline) throws {
        self.compiler = compiler; self.timeline = timeline
        comp = try compiler.buildComposition(timeline)
        (item, output) = Self.makeItem(comp, compiler.buildVideoComposition(timeline))
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.insert(item, after: nil)
    }

    static func makeItem(_ asset: AVAsset, _ vc: AVVideoComposition) -> (AVPlayerItem, AVPlayerItemVideoOutput) {
        let it = AVPlayerItem(asset: asset)
        it.videoComposition = vc
        it.seekingWaitsForVideoCompositionRendering = true
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        it.add(out)
        return (it, out)
    }

    func waitReady(_ it: AVPlayerItem, timeout: Duration = .seconds(5)) async -> Bool {
        let t0 = ContinuousClock.now
        while it.status == .unknown && ContinuousClock.now - t0 < timeout {
            _ = pollFrame()   // keep recording frames from whatever `item`/`output` currently point at
            if player.rate != 0 && player.timeControlStatus != .playing { stalls += 1 }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return it.status == .readyToPlay
    }

    /// Poll the output once; record timing of every new frame.
    func pollFrame() -> Probe? {
        let now = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: now) else { return nil }
        var shown = CMTime.invalid
        guard let pb = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &shown) else { return nil }
        frames.append((.now, shown))
        if player.rate != 0 && player.timeControlStatus != .playing { stalls += 1 }
        return Probe(pb)
    }
    func waitFrame(timeout: Duration, where pred: (Probe) -> Bool) async -> (ms: Double, probe: Probe)? {
        let t0 = ContinuousClock.now
        while ContinuousClock.now - t0 < timeout {
            if let p = pollFrame(), pred(p) { return (ms(t0), p) }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }
    func observe(_ d: Duration) async { let t0 = ContinuousClock.now; while ContinuousClock.now - t0 < d { _ = pollFrame(); try? await Task.sleep(for: .milliseconds(1)) } }

    /// Park the playhead in the middle of clip `idx`, paused, or playing through it from 0.6 s earlier.
    func position(idx: Int, playing: Bool) async {
        let T = timeline.clips[idx].start + CMTime(value: 1, timescale: 2)
        player.pause()
        frames = []; stalls = 0
        if !playing {
            await item.seek(to: T, toleranceBefore: .zero, toleranceAfter: .zero)
            _ = await waitFrame(timeout: .seconds(2)) { _ in true }
        } else {
            await item.seek(to: T - CMTime(value: 6, timescale: 10), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            while item.currentTime() < T - CMTime(value: 1, timescale: 10) { _ = pollFrame(); try? await Task.sleep(for: .milliseconds(1)) }
        }
        stalls = 0
    }

    func run(_ s: Strategy, playing: Bool, idx: Int) async throws -> Result {
        await position(idx: idx, playing: playing)
        var tl2 = timeline
        switch s.edit {
        case .opacity: tl2.clips[idx].opacity = 0.5
        case .replaceSource: tl2.clips[idx].source = (tl2.clips[idx].source + 2) % 4
        }
        let exp = Colors.expected(tl2.clips[idx])
        let pred: (Probe) -> Bool = { near($0.center, exp) }
        var r = Result(strategy: s, playing: playing)
        let t0 = ContinuousClock.now
        let seekT = item.currentTime()   // where the user is; a new item must come up here
        Compositor.mark()

        switch s {
        case .A_rebuild, .A_preloaded, .A_videoOnly, .D1_seekBeforeAttach, .D2_queuePlayer, .D3_secondPlayer:
            let comp2 = try compiler.buildComposition(tl2)
            if s == .A_videoOnly { comp2.tracks(withMediaType: .audio).forEach { comp2.removeTrack($0) } }
            let vc2 = compiler.buildVideoComposition(tl2)
            if s == .A_preloaded { _ = try await comp2.load(.duration, .tracks) }
            let (it2, out2) = Self.makeItem(comp2, vc2)
            if s == .A_preloaded { it2.preferredForwardBufferDuration = 1 }
            switch s {
            case .D3_secondPlayer:   // prepare on a second player while the old one keeps playing, then switch players
                let p2 = AVQueuePlayer(); p2.isMuted = true; p2.actionAtItemEnd = .pause
                p2.insert(it2, after: nil)
                await it2.seek(to: seekT, toleranceBefore: .zero, toleranceAfter: .zero)
                r.syncMs = ms(t0)
                r.readyMs = await waitReady(it2) ? ms(t0) : nil
                if playing { p2.play() }
                player.pause(); player = p2
            case .D1_seekBeforeAttach, .A_videoOnly:   // seek the detached item first, then attach (a warm-up AVPlayer is impossible: an item can never be re-attached to another player)
                let tS = ContinuousClock.now
                await it2.seek(to: seekT, toleranceBefore: .zero, toleranceAfter: .zero)
                r.seekMs = ms(tS)
                player.replaceCurrentItem(with: it2)
                r.syncMs = ms(t0)
                r.readyMs = await waitReady(it2) ? ms(t0) : nil
            case .D2_queuePlayer:
                player.insert(it2, after: item)
                r.note = "queued status=\(it2.status.rawValue)"
                let tS = ContinuousClock.now
                await it2.seek(to: seekT, toleranceBefore: .zero, toleranceAfter: .zero)
                r.seekMs = ms(tS)
                player.advanceToNextItem()
                r.syncMs = ms(t0)
                r.readyMs = await waitReady(it2) ? ms(t0) : nil
            default:
                player.replaceCurrentItem(with: it2)
                r.syncMs = ms(t0)
                r.readyMs = await waitReady(it2) ? ms(t0) : nil
                let tS = ContinuousClock.now
                await it2.seek(to: seekT, toleranceBefore: .zero, toleranceAfter: .zero)
                r.seekMs = ms(tS)
            }
            item = it2; output = out2; comp = comp2
            let cs = Compositor.stats.withLock { $0 }
            r.note += " rate after swap=\(player.rate) compositor init@\(fmt(cs.initAtMs)) (CIContext \(fmt(cs.ciInitMs))) renderContextChanged@\(fmt(cs.contextAtMs)) firstRequest@\(fmt(cs.firstRequestAtMs))"
            if playing && player.rate == 0 { player.play(); r.note += " (play() re-issued)" }
            if let f = await waitFrame(timeout: .seconds(3), where: pred) { r.frameMs = f.ms }
        case .B_videoComposition:
            let vc2 = compiler.buildVideoComposition(tl2)
            item.videoComposition = vc2
            r.syncMs = ms(t0)
            if let f = await waitFrame(timeout: playing ? .seconds(3) : .milliseconds(500), where: pred) { r.frameMs = f.ms }
            else if !playing {
                r.seekNeeded = true
                await item.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
                if let f = await waitFrame(timeout: .seconds(3), where: pred) { r.frameMs = f.ms }
            }
        case .C_mutateInPlace:
            try compiler.spliceInPlace(comp, old: timeline.clips[idx], new: tl2.clips[idx])
            r.syncMs = ms(t0)
            r.note = "item.asset===comp: \(item.asset === comp) duration=\(comp.duration.seconds)"
            var last: Probe?
            if let f = await waitFrame(timeout: playing ? .seconds(3) : .milliseconds(500), where: { last = $0; return pred($0) }) { r.frameMs = f.ms }
            else if !playing {
                r.seekNeeded = true
                await item.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
                if let f = await waitFrame(timeout: .seconds(1), where: { last = $0; return pred($0) }) { r.frameMs = f.ms }
            }
            r.note += " framesDeliveredAfterEdit=\(frames.filter { $0.wall >= t0 }.count) lastFrame=\(last.map { "\($0.center) #\($0.frameIndex)" } ?? "none") itemError=\(item.error.map { "\($0)" } ?? "nil") status=\(item.status.rawValue)"
            if r.frameMs == nil {   // is the edit in the composition at all? Build a fresh item on the *same* mutated composition.
                let (it3, out3) = Self.makeItem(comp, item.videoComposition!)
                player.replaceCurrentItem(with: it3); item = it3; output = out3
                _ = await waitReady(it3)
                await it3.seek(to: seekT, toleranceBefore: .zero, toleranceAfter: .zero)
                let f = await waitFrame(timeout: .seconds(2), where: pred)
                r.note += " | fresh item on mutated comp shows edit: \(f != nil)"
                if playing { player.play() }
            }
        }
        if r.frameMs == nil { r.note += " NO EDITED FRAME (last centre \(frames.isEmpty ? "n/a" : "seen"))" }
        if playing {
            await observe(.seconds(1))
            for (a, b) in zip(frames, frames.dropFirst()) where b.wall >= t0 { r.maxWallGapMs = max(r.maxWallGapMs, ms(a.wall, b.wall)) }
            if let first = frames.first(where: { $0.wall >= t0 }) {   // item-time jump: where the new frame is vs where the old clock would be
                r.itemJumpMs = (first.t - seekT).seconds * 1000 - ms(t0, first.wall)
            }
            r.stalls = stalls
        }
        player.pause()
        timeline = tl2
        return r
    }
}
