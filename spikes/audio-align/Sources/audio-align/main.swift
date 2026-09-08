import Foundation
import Accelerate
import AlignCore

struct TestCase {
    let name: String; let snrDB: Double; let driftPPM: Double
    let perfOffsets: [Double]      // camera time(s) where the performance starts; >1 = repeated song
    let dawStart: Double           // DAW render begins this many seconds into the performance
    var camLen: Double = 3600
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func timed<T>(_ label: String, _ body: () -> T) -> (T, Double) { let t = now(); let r = body(); return (r, now() - t) }
func peakRSSGB() -> Double { var ru = rusage(); getrusage(RUSAGE_SELF, &ru); return Double(ru.ru_maxrss) / 1e9 }
func f(_ v: Double, _ d: Int = 3) -> String { String(format: "%.\(d)f", v) }

let fsCam = 48000.0, fsDAW = 44100.0, perfLen = 240.0
let hop8 = 128, decim = 6, framesToSamples = hop8 * decim   // 1 envelope frame = 768 camera samples = 16 ms

print("audio-align spike  |  DAW \(Int(perfLen / 60)) min @44.1k  |  M4 Max\(ProcessInfo.processInfo.environment["NOEQ"] != nil ? "  |  NOEQ" : "")")
let score = Score.make(length: perfLen, seed: 1)
let scoreVar = Score.make(length: perfLen, seed: 1, variantSeed: 99)
let (perf48, tPerf) = timed("perf") { score.render(sampleRate: fsCam) }
let perfVar48 = scoreVar.render(sampleRate: fsCam)
let bass48 = Score.bassLine(length: perfLen, seed: 5).render(sampleRate: fsCam)
print("setup: performance render \(f(tPerf, 2))s")
let fir = lowpassFIR(taps: 127, cutoff: 3600 / fsCam)
let bp8 = [Biquad.highpass(fs: 8000, f0: 300), Biquad.lowpass(fs: 8000, f0: 3000)]
var pink: [Float] = []

let off = 37 * 60 + 12.345
let cases = [
    TestCase(name: "SNR +10 dB, drift +23 ppm", snrDB: 10, driftPPM: 23, perfOffsets: [off], dawStart: 0),
    TestCase(name: "SNR 0 dB, drift +23 ppm", snrDB: 0, driftPPM: 23, perfOffsets: [off], dawStart: 0),
    TestCase(name: "SNR -5 dB, drift +23 ppm", snrDB: -5, driftPPM: 23, perfOffsets: [off], dawStart: 0),
    TestCase(name: "SNR -10 dB, drift +23 ppm (stress)", snrDB: -10, driftPPM: 23, perfOffsets: [off], dawStart: 0),
    TestCase(name: "SNR -15 dB, drift +23 ppm (stress)", snrDB: -15, driftPPM: 23, perfOffsets: [off], dawStart: 0),
    TestCase(name: "SNR 0 dB, no drift", snrDB: 0, driftPPM: 0, perfOffsets: [off], dawStart: 0),
    TestCase(name: "SNR 0 dB, drift +23, DAW starts +30 s", snrDB: 0, driftPPM: 23, perfOffsets: [off], dawStart: 30),
    TestCase(name: "REPEATED SONG x2 (20 min apart), SNR +10, drift +23", snrDB: 10, driftPPM: 23, perfOffsets: [30 * 60 + 5.123, 50 * 60 + 5.123], dawStart: 0),
    TestCase(name: "120-min camera, SNR 0 dB, drift +23", snrDB: 0, driftPPM: 23, perfOffsets: [97 * 60 + 41.5], dawStart: 0, camLen: 7200),
]

for c in cases {
    print("\n=== \(c.name) ===")
    if pink.count != Int(c.camLen * fsCam) { pink = Synth.pinkNoise(count: Int(c.camLen * fsCam), seed: 7) }
    let inserts = c.perfOffsets.enumerated().map { (offset: $0.element, perf: $0.offset == 0 ? perf48 : perfVar48) }
    let (cam, tCam) = timed("cam") { Synth.buildCamera(noise: pink, inserts: inserts, bass: bass48, snrDB: c.snrDB, fs: fsCam, seed: 11) }
    let (daw, tDaw) = timed("daw") { Synth.dawProcess(score.render(sampleRate: fsDAW * (1 + c.driftPPM * 1e-6), from: c.dawStart), fs: fsDAW) }
    print("synth: camera \(f(tCam, 2))s, DAW \(f(tDaw, 2))s")
    let truths = c.perfOffsets.map { ($0 + c.dawStart) * fsCam }        // camera sample of DAW sample 0, per copy
    func nearestTruth(_ s: Double) -> (idx: Int, v: Double) { let i = truths.indices.min { abs(truths[$0] - s) < abs(truths[$1] - s) }!; return (i, truths[i]) }

    // --- stage 1: 48k -> 8k, bandpass, onset envelopes
    let (daw48, tRs) = timed("rs") { resampleHermite(daw, ratio: fsDAW / fsCam) }
    let (env, tEnv) = timed("env") { () -> ([Float], [Float]) in
        let cam8 = applyBiquads(decimate(cam, by: decim, filter: fir), bp8)
        let daw8 = applyBiquads(decimate(daw48, by: decim, filter: fir), bp8)
        return (onsetEnvelope(cam8), onsetEnvelope(daw8))
    }
    // --- stage 2: coarse FFT cross-correlation
    let (coarse, tCoarse) = timed("coarse") { coarseAlign(cam: env.0, daw: env.1) }
    let coarseSamples = coarse.lagFrames * framesToSamples
    let ct = nearestTruth(Double(coarseSamples))
    print("coarse: lag \(f(Double(coarseSamples) / fsCam))s  NCC \(f(Double(coarse.ncc)))  2nd \(f(Double(coarse.second)))  ratio \(f(Double(coarse.ratio), 2))  err \(f((Double(coarseSamples) - ct.v) / fsCam * 1000, 1)) ms vs copy #\(ct.idx)  [resample \(f(tRs, 2))s, env \(f(tEnv, 2))s, xcorr \(f(tCoarse, 3))s]")
    let ambiguous = coarse.candidates.count > 1
    if ambiguous { print("   AMBIGUOUS: \(coarse.candidates.count) coarse candidates >= 50% of peak -> user must choose; fine pass run on each:") }

    // --- stage 3: fine GCC-PHAT per 10 s window + Theil-Sen drift fit, for every coarse candidate
    var tFineTotal = 0.0, verified: [Int] = []
    for (ci, cand) in coarse.candidates.enumerated() {
        let start = cand.lag * framesToSamples
        let (wins, tFine) = timed("fine") { fineAlign(cam: cam, daw: daw48, coarseStart: start) }
        tFineTotal += tFine
        let fit = theilSen(x: wins.map { $0.tDAW }, y: wins.map { $0.offset }, inlierTol: 0.5e-3 * fsCam)
        let driftPPM = -fit.slope / fsCam * 1e6
        let t = nearestTruth(fit.intercept), errS = fit.intercept - t.v
        let wr = wins.map { Double($0.ratio) }
        let conf = min(1, max(0, (Double(coarse.ratio) - 1))) * Double(fit.inliers) / Double(max(fit.n, 1)) * max(0, 1 - fit.mad / fsCam * 1000 / 0.5)
        let tag = ambiguous ? "   cand #\(ci) @ \(f(Double(start) / fsCam))s (NCC \(f(Double(cand.ncc)))): " : "fine: "
        print("\(tag)\(wins.count) win, inliers \(fit.inliers)/\(fit.n) (<=0.5 ms), MAD \(f(fit.mad / fsCam * 1000, 3)) ms, PHAT ratio med \(f(median(wr), 1)) min \(f(wr.min() ?? 0, 1)), peak med \(f(median(wins.map { Double($0.peak) }), 3))  [\(f(tFine, 2))s]")
        print("      drift \(f(driftPPM, 1)) ppm (truth \(f(c.driftPPM, 0)))   offset err \(f(errS / fsCam * 1000, 3)) ms = \(f(errS, 1)) samples @48k vs copy #\(t.idx)\(ambiguous ? "" : "   confidence \(f(conf, 2))")")
        let ok = fit.inliers * 10 >= fit.n * 6 && fit.mad < 0.5e-3 * fsCam
        if ok { verified.append(ci) }
        if ci == 0 {
            let perWin = wins.map { w in f((w.offset - (t.v + w.tDAW * fsCam * (1 / (1 + c.driftPPM * 1e-6) - 1))) / fsCam * 1000, 2) }
            print("      per-window err ms: \(perWin.joined(separator: " "))")
        }
        if ok && ci == 0 {   // pass 2: undo the estimated drift, re-run the fine pass (peaks no longer smeared by drift)
            let (wins2, tF2) = timed("fine2") { fineAlign(cam: cam, daw: resampleHermite(daw48, ratio: 1 + driftPPM * 1e-6), coarseStart: start) }
            tFineTotal += tF2
            let fit2 = theilSen(x: wins2.map { $0.tDAW }, y: wins2.map { $0.offset }, inlierTol: 0.5e-3 * fsCam)
            let wr2 = wins2.map { Double($0.ratio) }
            print("      pass2 (drift-corrected): residual drift \(f(-fit2.slope / fsCam * 1e6, 2)) ppm, MAD \(f(fit2.mad / fsCam * 1000, 3)) ms, PHAT ratio med \(f(median(wr2), 1)), offset err \(f((fit2.intercept - t.v) / fsCam * 1000, 3)) ms  [\(f(tF2, 2))s]")
        }
    }
    let verdict = verified.count == 1 ? "CONFIDENT (1 candidate verified by fine pass)" : verified.isEmpty ? "NO ALIGNMENT (no candidate verified)" : "AMBIGUOUS (\(verified.count) candidates verified: \(verified.map { f(Double(coarse.candidates[$0].lag * framesToSamples) / fsCam, 1) + "s" }.joined(separator: ", ")))"
    print("verdict: \(verdict)   total align \(f(tRs + tEnv + tCoarse + tFineTotal, 2))s   peak RSS \(f(peakRSSGB(), 2)) GB")
}
