import Foundation
import Accelerate

/// Deterministic, fast RNG (SplitMix64).
public struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * uniform() }
}

public enum EventKind { case tone, chord, hit, bass }
public struct Event { public var start: Double; public var dur: Double; public var freq: Double; public var amp: Float; public var kind: EventKind }

/// A sample-rate-independent description of a "performance": rendering at any rate is exact,
/// so ground-truth offsets/drift are known to the sample without any resampler in the synth path.
public struct Score {
    public var events: [Event]
    public let length: Double
    static let scale: [Double] = [0, 2, 4, 5, 7, 9, 11]
    static func midi(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    static func randNote(_ r: inout SplitMix64, base: Int) -> Double {
        midi(Double(base + 12 * Int(r.next() % 3)) + scale[Int(r.next() % 7)])
    }

    /// `variantSeed` re-pitches ~10% of melodic notes (the "repeated song with variations" case).
    public static func make(length: Double, seed: UInt64, variantSeed: UInt64? = nil) -> Score {
        var rng = SplitMix64(seed: seed)
        var ev: [Event] = []
        for voice in 0..<3 {                                   // melodic voices, 200-600 ms notes
            var t = 0.0
            while t < length {
                let d = rng.range(0.2, 0.6)
                ev.append(Event(start: t, dur: d, freq: randNote(&rng, base: 48 + 7 * voice), amp: 0.25, kind: .tone))
                t += d
            }
        }
        var t = 0.0
        while t < length {                                     // sustained chords, 2-4 s
            let d = rng.range(2, 4); let root = 36 + Int(rng.next() % 12)
            for iv in [0, 4, 7] { ev.append(Event(start: t, dur: d, freq: midi(Double(root + iv)), amp: 0.12, kind: .chord)) }
            t += d
        }
        t = 0.3
        while t < length {                                     // percussive hits every ~0.5 s ± 100 ms
            ev.append(Event(start: t, dur: 0.12, freq: rng.range(2000, 5000), amp: 0.7, kind: .hit))
            t += 0.5 + rng.range(-0.1, 0.1)
        }
        if let vs = variantSeed {
            var vr = SplitMix64(seed: vs)
            for i in ev.indices where ev[i].kind == .tone { if vr.uniform() < 0.10 { ev[i].freq = randNote(&vr, base: 48) } }
        }
        return Score(events: ev, length: length)
    }

    /// Bass line present ONLY in the camera recording.
    public static func bassLine(length: Double, seed: UInt64) -> Score {
        var rng = SplitMix64(seed: seed); var ev: [Event] = []; var t = 0.0
        while t < length {
            ev.append(Event(start: t, dur: 0.95, freq: midi(Double(28 + Int(rng.next() % 17))), amp: 0.35, kind: .bass))
            t += 1.0
        }
        return Score(events: ev, length: length)
    }

    public func render(sampleRate fs: Double, from t0: Double = 0) -> [Float] {
        let n = Int((length - t0) * fs)
        var out = [Float](repeating: 0, count: n)
        let twoPi = Float(2 * Double.pi)
        for e in events {
            let s0 = max(0, Int(((e.start - t0) * fs).rounded(.up)))
            let s1 = min(n, Int(((e.start + e.dur - t0) * fs)))
            if s1 <= s0 { continue }
            let w = twoPi * Float(e.freq)
            for i in s0..<s1 {
                let t = Float(Double(i) / fs + t0 - e.start)
                var v: Float
                switch e.kind {
                case .tone, .chord, .bass:
                    let decay: Float = e.kind == .chord ? 0.3 : 1.5
                    let env = min(1, t / 0.005) * min(1, (Float(e.dur) - t) / 0.02) * exp(-t * decay)
                    let ph = w * t
                    v = e.kind == .bass ? env * (sin(ph) + 0.3 * sin(2 * ph))
                                        : env * (sin(ph) + 0.5 * sin(2 * ph) + 0.3 * sin(3 * ph) + 0.15 * sin(4 * ph))
                case .hit:
                    v = exp(-t / 0.008) * sin(w * t) + 0.8 * exp(-t / 0.05) * sin(twoPi * 180 * t) + 0.5 * exp(-t / 0.004) * sin(twoPi * 7000 * t)
                }
                out[i] += v * e.amp
            }
        }
        return out
    }
}

public enum Synth {
    /// Paul Kellet pink-noise filter on white noise, normalized to unit RMS.
    public static func pinkNoise(count: Int, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        var out = [Float](repeating: 0, count: count)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        for i in 0..<count {
            let w = Float(rng.uniform()) * 2 - 1
            b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759; b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856; b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
            out[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
            b6 = w * 0.115926
        }
        var rms: Float = 0; vDSP_rmsqv(out, 1, &rms, vDSP_Length(count))
        var g = 1 / rms; vDSP_vsmul(out, 1, &g, &out, 1, vDSP_Length(count))
        return out
    }

    public static let camEchoes: [(Double, Float)] = [(0, 1), (0.013, 0.5), (0.029, 0.4), (0.047, 0.3), (0.071, 0.2), (0.113, 0.12)]
    public static let dawEchoes: [(Double, Float)] = [(0, 1), (0.021, 0.35), (0.037, 0.25), (0.061, 0.18), (0.089, 0.1)]

    public static func addWithEchoes(_ src: [Float], into dst: inout [Float], at start: Int, gain: Float, echoes: [(Double, Float)], fs: Double) {
        for (d, g) in echoes {
            let s = start + Int((d * fs).rounded())
            let cnt = min(src.count, dst.count - s); if cnt <= 0 || s < 0 { continue }
            var gg = gain * g
            dst.withUnsafeMutableBufferPointer { dp in
                vDSP_vsma(src, 1, &gg, dp.baseAddress! + s, 1, dp.baseAddress! + s, 1, vDSP_Length(cnt))
            }
        }
    }

    /// Camera track: pink noise at `snrDB` + reverberant performance(s) + camera-only bass + LF rumble + soft-knee AGC.
    public static func buildCamera(noise: [Float], inserts: [(offset: Double, perf: [Float])], bass: [Float], snrDB: Double, fs: Double, seed: UInt64) -> [Float] {
        var cam = [Float](repeating: 0, count: noise.count)
        var sigRMS: Float = 0
        for (i, ins) in inserts.enumerated() {
            let s = Int((ins.offset * fs).rounded())
            addWithEchoes(ins.perf, into: &cam, at: s, gain: 1, echoes: camEchoes, fs: fs)
            if i == 0 { cam.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + s, 1, &sigRMS, vDSP_Length(ins.perf.count)) } }
            addWithEchoes(bass, into: &cam, at: s, gain: 1, echoes: [(0, 1)], fs: fs)
        }
        var g = sigRMS * Float(pow(10, -snrDB / 20))
        cam.withUnsafeMutableBufferPointer { cp in vDSP_vsma(noise, 1, &g, cp.baseAddress!, 1, cp.baseAddress!, 1, vDSP_Length(cp.count)) }
        // wind-like rumble: white -> one-pole LP at 30 Hz, RMS = 2x performance RMS
        var rng = SplitMix64(seed: seed); var y: Float = 0
        let a = Float(exp(-2 * Double.pi * 30 / fs))
        let k = 2 * sigRMS / sqrt((1 - a) / (1 + a)) / sqrt(1.0 / 3.0)
        for i in 0..<cam.count { y = a * y + (1 - a) * (Float(rng.uniform()) * 2 - 1); cam[i] += k * y }
        compress(&cam, thresholdDB: 20 * log10(sigRMS) - 6, ratio: 4, kneeDB: 6, fs: fs)
        return cam
    }

    /// Soft-knee compressor (AGC stand-in); gain recomputed every 32 samples.
    public static func compress(_ x: inout [Float], thresholdDB: Float, ratio: Float, kneeDB: Float, fs: Double) {
        let aA = Float(exp(-1 / (0.005 * fs))), aR = Float(exp(-1 / (0.2 * fs)))
        var env: Float = 0, gain: Float = 1
        for i in 0..<x.count {
            let a = abs(x[i])
            env = a > env ? aA * env + (1 - aA) * a : aR * env + (1 - aR) * a
            if i & 31 == 0 {
                let over = 20 * log10(env + 1e-9) - thresholdDB
                let eff: Float = over <= -kneeDB / 2 ? 0 : (over >= kneeDB / 2 ? over : (over + kneeDB / 2) * (over + kneeDB / 2) / (2 * kneeDB))
                gain = pow(10, -eff * (1 - 1 / ratio) / 20)
            }
            x[i] *= gain
        }
    }

    /// DAW render: different reverb, low-shelf +6 dB @200 Hz, high-shelf -6 dB @4 kHz, no noise/bass.
    public static func dawProcess(_ x: [Float], fs: Double) -> [Float] {
        var y = [Float](repeating: 0, count: x.count + Int(0.1 * fs))
        addWithEchoes(x, into: &y, at: 0, gain: 1, echoes: dawEchoes, fs: fs)
        if ProcessInfo.processInfo.environment["NOEQ"] == nil {   // NOEQ=1 isolates the EQ's contribution to offset bias
            y = applyBiquads(y, [Biquad.lowShelf(fs: fs, f0: 200, gainDB: 6), Biquad.highShelf(fs: fs, f0: 4000, gainDB: -6)])
        }
        var rms: Float = 0; vDSP_rmsqv(y, 1, &rms, vDSP_Length(y.count))
        var g = 0.1 / rms; vDSP_vsmul(y, 1, &g, &y, 1, vDSP_Length(y.count))
        return y
    }
}
