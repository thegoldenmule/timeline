import AVFoundation

setvbuf(stdout, nil, _IOLBF, 0)
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let tmp = root.appendingPathComponent("tmp", isDirectory: true)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let runs = Int(ProcessInfo.processInfo.environment["SPIKE_RUNS"] ?? "") ?? 5

print("== Generating media ==")
let names = ["red", "green", "blue", "yellow"], colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]
let sources = names.map { tmp.appendingPathComponent("\($0).mov") }
let tGen = ContinuousClock.now
for (i, url) in sources.enumerated() where !FileManager.default.fileExists(atPath: url.path) {
    try Media.makeClip(url: url, color: colors[i], toneHz: 440 * Double(i + 1), seconds: 4)
}
let pcm = tmp.appendingPathComponent("red-pcm.mov")
if !FileManager.default.fileExists(atPath: pcm.path) { try Media.makeClip(url: pcm, color: (1, 0, 0), toneHz: 440, seconds: 4, lpcm: true) }
print("  4 clips (+1 LPCM-audio clip) ready in \(fmt(ms(tGen))) ms")

@MainActor func main() async throws {
    let compiler = Compiler(sources: sources)
    let tLoad = ContinuousClock.now
    try await compiler.preload()
    print("  loadTracks for 4 sources: \(fmt(ms(tLoad))) ms")

    // E1: compile scaling, pure CPU (tracks preloaded).
    print("\n== E: compile scaling (median of \(runs)) ==")
    for n in [20, 200] {
        let tl = Timeline.synthetic(count: n)
        var cMs: [Double] = [], vMs: [Double] = [], setMs: [Double] = []
        for _ in 0..<runs {
            let t0 = ContinuousClock.now; _ = try compiler.buildComposition(tl); cMs.append(ms(t0))
            let t1 = ContinuousClock.now; let vc = compiler.buildVideoComposition(tl); vMs.append(ms(t1))
            let it = AVPlayerItem(asset: try compiler.buildComposition(tl))
            let t2 = ContinuousClock.now; it.videoComposition = vc; setMs.append(ms(t2))
        }
        print("  \(n) clips: buildComposition \(fmt(median(cMs))) ms, buildVideoComposition \(fmt(median(vMs))) ms, item.videoComposition= \(fmt(median(setMs))) ms")
    }
    // E2: readyToPlay for a fresh player+item, 20 vs 200 clips (paused, seek to 10.5 s).
    for n in [20, 200] {
        var rMs: [Double] = [], sMs: [Double] = [], fMs: [Double] = []
        for _ in 0..<runs {
            let tl = Timeline.synthetic(count: n)
            let h = try Harness(compiler: compiler, timeline: tl)
            let t0 = ContinuousClock.now
            _ = await h.waitReady(h.item); rMs.append(ms(t0))
            let t1 = ContinuousClock.now
            await h.item.seek(to: CMTime(value: 21, timescale: 2), toleranceBefore: .zero, toleranceAfter: .zero); sMs.append(ms(t1))
            _ = await h.waitFrame(timeout: .seconds(3)) { _ in true }; fMs.append(ms(t0))
        }
        print("  \(n) clips: fresh AVPlayer+item -> readyToPlay \(fmt(median(rMs))) ms, then seek(10.5s) \(fmt(median(sMs))) ms, first composed frame at \(fmt(median(fMs))) ms total")
    }
    // E3: per-frame compositor cost while playing, 20 vs 200 instructions.
    for n in [20, 200] {
        let h = try Harness(compiler: compiler, timeline: Timeline.synthetic(count: n))
        await h.position(idx: 5, playing: true)
        Compositor.resetStats()
        await h.observe(.seconds(2))
        h.player.pause()
        let s = Compositor.stats.withLock { $0 }
        print("  \(n) instructions: \(s.frames) frames in 2 s playing, startRequest mean \(fmt(Double(s.totalNs) / Double(max(s.frames, 1)) / 1e6)) ms, max \(fmt(Double(s.maxNs) / 1e6)) ms; \(h.frames.count) frames on output")
    }

    // E4: what drives the readyToPlay cost? Fresh AVPlayer + item per run, paused, no seek.
    print("\n== E4: readyToPlay drivers (median of \(runs)) ==")
    func ready(_ label: String, _ make: () throws -> (AVAsset, AVVideoComposition?)) async throws {
        var xs: [Double] = []
        for _ in 0..<runs {
            let (asset, vc) = try make()
            let it = AVPlayerItem(asset: asset); it.videoComposition = vc
            let p = AVPlayer(playerItem: it); p.isMuted = true
            let t0 = ContinuousClock.now
            while it.status == .unknown && ms(t0) < 5000 { try? await Task.sleep(for: .milliseconds(1)) }
            xs.append(ms(t0))
            if it.status != .readyToPlay { print("  \(label): status \(it.status.rawValue) error \(it.error.map { "\($0)" } ?? "nil")") }
        }
        print("  \(label): readyToPlay \(fmt(median(xs))) ms")
    }
    let tl200 = Timeline.synthetic(count: 200), tl1 = Timeline.synthetic(count: 1)
    try await ready("200 clips, 2V+2A, custom compositor") { (try compiler.buildComposition(tl200), compiler.buildVideoComposition(tl200)) }
    try await ready("200 clips, 2V+2A, no videoComposition") { (try compiler.buildComposition(tl200), nil) }
    try await ready("200 clips, 2V only (audio tracks removed), custom compositor") {
        let c = try compiler.buildComposition(tl200); c.tracks(withMediaType: .audio).forEach { c.removeTrack($0) }; return (c, compiler.buildVideoComposition(tl200)) }
    try await ready("1 clip, 1V+1A (+1 empty V/A), custom compositor") { (try compiler.buildComposition(tl1), compiler.buildVideoComposition(tl1)) }
    try await ready("plain AVURLAsset red.mov, no videoComposition") { (AVURLAsset(url: sources[0]), nil) }
    try await ready("plain AVURLAsset red-pcm.mov (LPCM audio), no videoComposition") { (AVURLAsset(url: pcm), nil) }
    let pcmCompiler = Compiler(sources: [pcm, pcm, pcm, pcm]); try await pcmCompiler.preload()
    try await ready("200 clips, 2V+2A LPCM audio, custom compositor") { (try pcmCompiler.buildComposition(tl200), pcmCompiler.buildVideoComposition(tl200)) }
    try await ready("plain AVURLAsset red.mov + custom compositor (1 instruction)") {
        let a = AVURLAsset(url: sources[0]); let vc = compiler.buildVideoComposition(Timeline(clips: [Clip(source: 0, start: .zero, duration: CMTime(value: 4, timescale: 1), sourceIn: .zero, track: 1)]))
        return (a, vc) }

    // A-D on the 200-clip timeline.
    print("\n== A-D: edit-to-updated-frame on 200 clips, 2 video + 2 audio tracks (\(runs) runs each) ==")
    let h = try Harness(compiler: compiler, timeline: Timeline.synthetic(count: 200))
    _ = await h.waitReady(h.item)
    var idx = 20
    var table: [Result] = []
    let order: [Strategy] = [.A_rebuild, .A_preloaded, .A_videoOnly, .B_videoComposition, .D1_seekBeforeAttach, .D2_queuePlayer, .D3_secondPlayer, .C_mutateInPlace]  // C last: may be unsafe
    for s in order {
        for playing in [false, true] {
            var rs: [Result] = []
            for _ in 0..<runs {
                let r = try await h.run(s, playing: playing, idx: idx); idx += 2; rs.append(r)
                print("  \(s.rawValue) \(playing ? "playing" : "paused ") sync \(fmt(r.syncMs)) ready \(fmt(r.readyMs)) seek \(fmt(r.seekMs)) frame \(fmt(r.frameMs)) seekNeeded=\(r.seekNeeded) gap \(fmt(r.maxWallGapMs)) jump \(fmt(r.itemJumpMs)) stalls \(r.stalls) \(r.note)")
            }
            var m = rs[0]
            m.syncMs = median(rs.map(\.syncMs)); m.readyMs = rs.compactMap(\.readyMs).isEmpty ? nil : median(rs.compactMap(\.readyMs))
            m.frameMs = rs.compactMap(\.frameMs).isEmpty ? nil : median(rs.compactMap(\.frameMs))
            m.seekMs = rs.compactMap(\.seekMs).isEmpty ? nil : median(rs.compactMap(\.seekMs))
            m.maxWallGapMs = median(rs.map(\.maxWallGapMs)); m.itemJumpMs = median(rs.map(\.itemJumpMs)); m.stalls = rs.map(\.stalls).max() ?? 0
            m.seekNeeded = rs.contains { $0.seekNeeded }; m.note = "\(rs.compactMap(\.frameMs).count)/\(runs) ok"
            table.append(m)
        }
    }
    print("\n| Strategy | State | sync main-actor ms | readyToPlay ms | seek ms | edit->frame ms | paused re-seek needed | max frame gap ms (playing) | item-time jump ms | stalls | ok |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for m in table {
        print("| \(m.strategy.rawValue) | \(m.playing ? "playing" : "paused") | \(fmt(m.syncMs)) | \(fmt(m.readyMs)) | \(fmt(m.seekMs)) | \(fmt(m.frameMs)) | \(m.seekNeeded) | \(m.playing ? fmt(m.maxWallGapMs) : "-") | \(m.playing ? fmt(m.itemJumpMs) : "-") | \(m.stalls) | \(m.note) |")
    }
    let s = Compositor.stats.withLock { $0 }
    print("\ncompositor instances created: \(s.instances), renderContextChanged: \(s.contextChanges)")
}
try await main()
exit(0)
