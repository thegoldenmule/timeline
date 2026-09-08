import AVFoundation
import CoreImage

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
    if !ok { failures += 1 }
    print("  [\(ok ? "PASS" : "FAIL")] \(name): \(detail)")
}
func near(_ c: (Int, Int, Int), _ e: (Int, Int, Int), tol: Int = 40) -> Bool {
    abs(c.0 - e.0) <= tol && abs(c.1 - e.1) <= tol && abs(c.2 - e.2) <= tol
}
func ms(_ start: ContinuousClock.Instant) -> String { let d = ContinuousClock.now - start
    return String(format: "%.1f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }

// Regions (top-left px coords) used by the assertions. Must match Model/Compositor placement.
enum Region {
    static let center = CGRect(x: 400, y: 200, width: 480, height: 300)       // below the barcode strip, above the caption
    static let pip = CGRect(x: 760, y: 80, width: 440, height: 200)            // PiP: scale 0.4 => 512x288 centered at (984, 224)
    static let pipBarcode = CGRect(x: 728, y: 80, width: 512, height: 10)      // PiP's own scaled barcode
    static let caption = CGRect(x: 440, y: 580, width: 400, height: 60)        // caption centered at y = 0.85 h = 612
}

/// (a) AVAssetImageGenerator frame grabs through the composition.
func runImageGeneratorChecks(asset: AVAsset, vc: AVVideoComposition?, label: String) async throws {
    print("\n== \(label): AVAssetImageGenerator ==")
    let gen = AVAssetImageGenerator(asset: asset)
    gen.videoComposition = vc
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    gen.appliesPreferredTrackTransform = true
    func grab(_ s: Double) async throws -> Pixels {
        let t0 = ContinuousClock.now
        let r = try await gen.image(at: CMTime(seconds: s, preferredTimescale: 600))
        let cs: String = r.image.colorSpace.flatMap { $0.name }.map { $0 as String } ?? "nil"
        print("  grab @\(s)s -> actual \(String(format: "%.4f", r.actualTime.seconds))s, \(r.image.width)x\(r.image.height), cs=\(cs), latency \(ms(t0))")
        return Pixels(r.image)
    }
    let p05 = try await grab(0.5)
    check("0.5s pure red", near(p05.mean(Region.center), (255, 0, 0)), "center mean = \(p05.mean(Region.center))")
    check("0.5s frame counter", Media.frameIndex(fromBarcodeIn: p05) == 15, "barcode = \(Media.frameIndex(fromBarcodeIn: p05)) (expect 15)")
    let p35 = try await grab(3.5)
    let m = p35.mean(Region.center)
    check("3.5s crossfade ~50/50 red/green", m.0 > 90 && m.0 < 210 && m.1 > 90 && m.1 < 210 && m.2 < 40 && abs(m.0 - m.1) < 30,
          "center mean = \(m) (linear-light dissolve of red+green => ~(188,188,0) in sRGB; gamma-space would be ~(128,128,0))")
    print("  (3.5s barcode strip is a blend of frames 105 and 15; decodes to \(Media.frameIndex(fromBarcodeIn: p35)) -- informational only)")
    let p55 = try await grab(5.5)
    let pip = p55.mean(Region.pip), bg = p55.mean(Region.center)
    // CI composites in linear light: 0.8*blue + 0.2*green => sRGB (0, 124, 231). Gamma-space compositing would give (0, 51, 204).
    check("5.5s PiP blue @ transformed location (opacity 0.8 over green)", near(pip, (0, 124, 231), tol: 40), "pip mean = \(pip) (expect ~(0,124,231) linear-light)")
    check("5.5s background still green", bg.0 < 40 && bg.1 > 200 && bg.2 < 60, "center mean = \(bg)")
    check("5.5s green frame counter", Media.frameIndex(fromBarcodeIn: p55) == 75, "barcode = \(Media.frameIndex(fromBarcodeIn: p55)) (expect (5.5-3)*30 = 75)")
    let p15 = try await grab(1.5)
    let cap = p15.mean(Region.caption)
    check("1.5s caption pixels present", !near(cap, (255, 0, 0), tol: 25), "caption region mean = \(cap) vs red bg (255,0,0)")
    let p101 = try await grab(1.0 + 1.0 / 30)  // one frame into the scale-in: caption should be tiny => region mostly red
    let capEarly = p101.mean(Region.caption)
    check("1.033s caption still scaling in (less coverage than at 1.5s)", abs(capEarly.0 - 255) + capEarly.1 + capEarly.2 < abs(cap.0 - 255) + cap.1 + cap.2,
          "early caption region mean = \(capEarly) vs settled \(cap)")
}

/// (b) AVAssetExportSession, then re-grab from the exported file with no video composition.
func runExport(_ c: Compiled, to url: URL, preset: String) async throws -> AVURLAsset {
    print("\n== AVAssetExportSession (\(preset)) ==")
    try? FileManager.default.removeItem(at: url)
    guard let ex = AVAssetExportSession(asset: c.composition, presetName: preset) else { throw NSError(domain: "spike", code: 20) }
    ex.videoComposition = c.videoComposition
    ex.audioMix = c.audioMix
    let before = SpikeCompositor.frameCount
    let t0 = ContinuousClock.now
    try await ex.export(to: url, as: .mov)
    let frames = SpikeCompositor.frameCount - before
    let dur = c.composition.duration.seconds
    print("  exported \(dur)s (\(frames) composed frames) in \(ms(t0)); file \(try FileManager.default.attributesOfItem(atPath: url.path)[.size] ?? 0) bytes")
    check("export ran the compositor", frames >= Int(dur * 30) - 2, "\(frames) startRequest calls during export")
    return AVURLAsset(url: url)
}

/// (c) AVPlayerItem + AVPlayerItemVideoOutput, headless.
@MainActor
func runPlayerChecks(_ c: Compiled) async throws {
    print("\n== AVPlayerItem + AVPlayerItemVideoOutput (headless) ==")
    let item = AVPlayerItem(asset: c.composition)
    item.videoComposition = c.videoComposition
    item.audioMix = c.audioMix
    item.seekingWaitsForVideoCompositionRendering = true
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    let t0 = ContinuousClock.now
    var polls = 0
    while item.status == .unknown && polls < 500 { try await Task.sleep(for: .milliseconds(10)); polls += 1 }
    check("item reaches .readyToPlay", item.status == .readyToPlay, "status = \(item.status.rawValue) after \(ms(t0)) \(item.error.map { "error: \($0)" } ?? "")")
    guard item.status == .readyToPlay else { return }

    for (s, expectFrame) in [(0.5, 15), (1.5, 45), (2.9, 87), (0.0, 0), (5.5, 75), (2.0, 60)] {  // 5.5s: green clip's strip, PiP active
        let target = CMTime(value: CMTimeValue(s * 600), timescale: 600)
        let t1 = ContinuousClock.now
        let finished = await item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        let seekMs = ms(t1)
        var pb: CVPixelBuffer?
        var waited = 0
        while pb == nil && waited < 200 {   // rate == 0: the output delivers the seek target frame once rendered
            let now = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: now) { pb = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) }
            if pb == nil { try await Task.sleep(for: .milliseconds(10)); waited += 1 }
        }
        guard let pb else { check("seek \(s)s frame available", false, "no pixel buffer from AVPlayerItemVideoOutput after 2s (seek finished=\(finished))"); continue }
        let px = Pixels(pb)
        let idx = Media.frameIndex(fromBarcodeIn: px)
        check("seek \(s)s frame-accurate", idx == expectFrame,
              "barcode frame = \(idx) (expect \(expectFrame)), currentTime = \(String(format: "%.4f", item.currentTime().seconds)), seek \(seekMs), frame ready after \(waited * 10) ms, center = \(px.mean(Region.center))")
    }
    // Also play for ~1s to prove real-time rendering works with no window/layer attached.
    let before = SpikeCompositor.frameCount
    await item.seek(to: CMTime(value: 3, timescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
    player.play()
    try await Task.sleep(for: .seconds(1.0))
    player.pause()
    let rendered = SpikeCompositor.frameCount - before
    check("headless playback renders frames", rendered > 20, "\(rendered) composed frames in 1s of play from 3.0s (crossfade region), currentTime = \(String(format: "%.3f", item.currentTime().seconds))")
}
