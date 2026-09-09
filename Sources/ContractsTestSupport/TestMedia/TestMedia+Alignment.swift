// The synthetic camera-vs-render pair from spikes/audio-align (Synth.swift and main.swift), ported faithfully
// with the vDSP calls replaced by scalar loops so this target stays on its declared frameworks.
//
// Everything is generated from a sample-rate-independent "score" (note events with times in seconds), so the
// camera and render are computed exactly at their own rates and the ground truth is known to the sample without
// a resampler in the synth path. Clock drift is simulated by rendering the DAW at `fs * (1 + ppm * 1e-6)` and
// labelling it `fs`.
import Foundation

extension TestMedia {
    /// Writes a long noisy "camera" recording containing a reverberant, EQ-different copy of a short clean "DAW
    /// render", both as mono 32-bit float `.caf` files, with the placement, drift, and SNR in the description.
    ///
    /// - camera: pink noise at `snrDB` relative to the performance RMS, the performance through a 6-tap room
    ///   reverb, a bass line present only in the camera, low-frequency rumble, and a soft-knee compressor (AGC).
    /// - render: the same performance through a different reverb, low shelf +6 dB at 200 Hz and high shelf -6 dB
    ///   at 4 kHz, no noise, no bass, rendered at `renderSampleRate * (1 + driftPPM * 1e-6)`, plus a 0.1 s tail.
    ///
    /// The performance, the bass line, the pink noise, and the DAW render are memoized by the parameters that
    /// determine them (`AlignmentSynthesisCache`), so a suite that sweeps offset and SNR over one seed pays for
    /// them once. Pass `cacheSynthesis: false` to force a full recomputation — a test that asserts the generator
    /// is deterministic must not be handed the same buffer twice.
    public static func alignmentPair(
        seed: UInt64 = 1, cameraDuration: Double = 20, renderDuration: Double = 5, offsetSeconds: Double = 7.345,
        driftPPM: Double = 23, snrDB: Double = 0, cameraSampleRate: Double = defaultSampleRate,
        renderSampleRate: Double = 44100, cacheSynthesis: Bool = true, in directory: URL? = nil, name: String? = nil
    ) async throws -> AlignmentPair {
        guard offsetSeconds >= 0, offsetSeconds + renderDuration <= cameraDuration else {
            throw Error.unsupportedParameters("the render must lie inside the camera recording")
        }
        let cache = AlignmentSynthesisCache.shared
        let performance = await cache.samples(
            "perf-\(seed)-\(renderDuration)-\(cameraSampleRate)", caching: cacheSynthesis
        ) {
            AlignScore.make(length: renderDuration, seed: seed).render(sampleRate: cameraSampleRate)
        }
        let bass = await cache.samples("bass-\(seed)-\(renderDuration)-\(cameraSampleRate)", caching: cacheSynthesis) {
            AlignScore.bassLine(length: renderDuration, seed: seed &+ 4).render(sampleRate: cameraSampleRate)
        }
        let noiseCount = Int(cameraDuration * cameraSampleRate)
        let noise = await cache.samples("noise-\(seed)-\(noiseCount)", caching: cacheSynthesis) {
            AlignSynth.pinkNoise(count: noiseCount, seed: seed &+ 6)
        }
        let render = await cache.samples(
            "render-\(seed)-\(renderDuration)-\(renderSampleRate)-\(driftPPM)", caching: cacheSynthesis
        ) {
            AlignSynth.dawProcess(
                AlignScore.make(length: renderDuration, seed: seed).render(
                    sampleRate: renderSampleRate * (1 + driftPPM * 1e-6)), fs: renderSampleRate)
        }
        let camera = AlignSynth.buildCamera(
            noise: noise, inserts: [(offset: offsetSeconds, perf: performance)], bass: bass, snrDB: snrDB,
            fs: cameraSampleRate, seed: seed &+ 10)

        let base = name ?? "align-\(UUID().uuidString.prefix(8))"
        let cameraURL = try outputURL(in: directory, name: "\(base)-camera", defaultName: base, ext: "caf")
        let renderURL = try outputURL(
            in: cameraURL.deletingLastPathComponent(), name: "\(base)-render", defaultName: base, ext: "caf")
        try await writeAudio(to: cameraURL, samples: camera, sampleRate: cameraSampleRate, channels: 1, codec: .pcm)
        try await writeAudio(to: renderURL, samples: render, sampleRate: renderSampleRate, channels: 1, codec: .pcm)

        let truth = AlignmentTruth(
            offsetSeconds: offsetSeconds, offsetSamples: offsetSeconds * cameraSampleRate, driftPPM: driftPPM,
            snrDB: snrDB, seed: seed, cameraSampleRate: cameraSampleRate, renderSampleRate: renderSampleRate)
        var cameraDescription = audioDescription(
            frames: camera.count, sampleRate: cameraSampleRate, channels: 1, codec: .pcm)
        cameraDescription.alignment = truth
        var renderDescription = audioDescription(
            frames: render.count, sampleRate: renderSampleRate, channels: 1, codec: .pcm)
        renderDescription.alignment = truth
        return AlignmentPair(
            camera: Clip(url: cameraURL, description: cameraDescription),
            render: Clip(url: renderURL, description: renderDescription), truth: truth)
    }
}

/// Memoizes the deterministic, expensive halves of `alignmentPair`: the performance, the bass line, the pink
/// noise, and the DAW render are each a pure function of the parameters in their key, so building the same
/// fixture twice recomputes nothing. `AudioAlignTests`' SNR matrix sweeps offset, drift, and SNR over one seed
/// and one camera length, which means eighteen cases share one 600 s noise buffer instead of synthesizing it
/// eighteen times.
///
/// Concurrent callers that miss the same key await one `Task` rather than racing to compute it. Entries live for
/// the process, capped at `budgetBytes` with the least recently used evicted first; sharing the buffers lowers
/// the peak resident set as well, since the parallel cases no longer each hold their own copy.
actor AlignmentSynthesisCache {
    static let shared = AlignmentSynthesisCache()

    /// A ceiling on what the memo keeps, not a promise that everything fits: over it, the least recently used
    /// key is dropped and recomputed the next time it is asked for. Only speed is at stake either way.
    private let budgetBytes = 1 << 30
    private var tasks: [String: Task<[Float], Never>] = [:]
    private var sizes: [String: Int] = [:]
    /// Keys least recently used first.
    private var order: [String] = []
    private var bytes = 0

    /// The samples for `key`, computed by `make` at most once. With `caching` false, `make` always runs and
    /// nothing is stored or read.
    func samples(_ key: String, caching: Bool = true, _ make: @Sendable @escaping () -> [Float]) async -> [Float] {
        guard caching else { return await Task.detached(priority: .userInitiated, operation: make).value }
        if let task = tasks[key] {
            touch(key)
            return await task.value
        }
        let task = Task.detached(priority: .userInitiated, operation: make)
        tasks[key] = task
        order.append(key)
        let value = await task.value
        record(key, size: value.count * MemoryLayout<Float>.stride)
        return value
    }

    private func touch(_ key: String) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }

    private func record(_ key: String, size: Int) {
        guard sizes[key] == nil else { return }
        sizes[key] = size
        bytes += size
        while bytes > budgetBytes, let oldest = order.first, oldest != key, let evicted = sizes[oldest] {
            order.removeFirst()
            tasks[oldest] = nil
            sizes[oldest] = nil
            bytes -= evicted
        }
    }
}

/// Deterministic, fast RNG (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * uniform() }
}

/// A sample-rate-independent description of a "performance".
struct AlignScore {
    enum Kind { case tone, chord, hit, bass }
    struct Event {
        var start: Double
        var dur: Double
        var freq: Double
        var amp: Float
        var kind: Kind
    }

    var events: [Event]
    let length: Double
    static let scale: [Double] = [0, 2, 4, 5, 7, 9, 11]
    static func midi(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    static func randNote(_ r: inout SplitMix64, base: Int) -> Double {
        midi(Double(base + 12 * Int(r.next() % 3)) + scale[Int(r.next() % 7)])
    }

    /// `variantSeed` re-pitches ~10% of melodic notes (the "repeated song with variations" case).
    static func make(length: Double, seed: UInt64, variantSeed: UInt64? = nil) -> AlignScore {
        var rng = SplitMix64(seed: seed)
        var ev: [Event] = []
        for voice in 0..<3 {  // melodic voices, 200-600 ms notes
            var t = 0.0
            while t < length {
                let d = rng.range(0.2, 0.6)
                ev.append(Event(start: t, dur: d, freq: randNote(&rng, base: 48 + 7 * voice), amp: 0.25, kind: .tone))
                t += d
            }
        }
        var t = 0.0
        while t < length {  // sustained chords, 2-4 s
            let d = rng.range(2, 4)
            let root = 36 + Int(rng.next() % 12)
            for iv in [0, 4, 7] {
                ev.append(Event(start: t, dur: d, freq: midi(Double(root + iv)), amp: 0.12, kind: .chord))
            }
            t += d
        }
        t = 0.3
        while t < length {  // percussive hits every ~0.5 s +-100 ms
            ev.append(Event(start: t, dur: 0.12, freq: rng.range(2000, 5000), amp: 0.7, kind: .hit))
            t += 0.5 + rng.range(-0.1, 0.1)
        }
        if let vs = variantSeed {
            var vr = SplitMix64(seed: vs)
            for i in ev.indices where ev[i].kind == .tone {
                if vr.uniform() < 0.10 { ev[i].freq = randNote(&vr, base: 48) }
            }
        }
        return AlignScore(events: ev, length: length)
    }

    /// Bass line present ONLY in the camera recording.
    static func bassLine(length: Double, seed: UInt64) -> AlignScore {
        var rng = SplitMix64(seed: seed)
        var ev: [Event] = []
        var t = 0.0
        while t < length {
            ev.append(Event(start: t, dur: 0.95, freq: midi(Double(28 + Int(rng.next() % 17))), amp: 0.35, kind: .bass))
            t += 1.0
        }
        return AlignScore(events: ev, length: length)
    }

    func render(sampleRate fs: Double, from t0: Double = 0) -> [Float] {
        let n = Int((length - t0) * fs)
        var out = [Float](repeating: 0, count: n)
        let twoPi = Float(2 * Double.pi)
        out.withUnsafeMutableBufferPointer { o in
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
                        v =
                            e.kind == .bass
                            ? env * (sin(ph) + 0.3 * sin(2 * ph))
                            : env * (sin(ph) + 0.5 * sin(2 * ph) + 0.3 * sin(3 * ph) + 0.15 * sin(4 * ph))
                    case .hit:
                        v =
                            exp(-t / 0.008) * sin(w * t) + 0.8 * exp(-t / 0.05) * sin(twoPi * 180 * t) + 0.5
                            * exp(-t / 0.004) * sin(twoPi * 7000 * t)
                    }
                    o[i] += v * e.amp
                }
            }
        }
        return out
    }
}

enum AlignSynth {
    static func rms(_ x: UnsafeBufferPointer<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var acc: Double = 0
        for v in x { acc += Double(v) * Double(v) }
        return Float((acc / Double(x.count)).squareRoot())
    }

    static func rms(_ x: [Float]) -> Float { x.withUnsafeBufferPointer { rms($0) } }

    /// Paul Kellet pink-noise filter on white noise, normalized to unit RMS.
    static func pinkNoise(count: Int, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        var out = [Float](repeating: 0, count: count)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        out.withUnsafeMutableBufferPointer { o in
            for i in 0..<count {
                let w = Float(rng.uniform()) * 2 - 1
                b0 = 0.99886 * b0 + w * 0.0555179
                b1 = 0.99332 * b1 + w * 0.0750759
                b2 = 0.96900 * b2 + w * 0.1538520
                b3 = 0.86650 * b3 + w * 0.3104856
                b4 = 0.55000 * b4 + w * 0.5329522
                b5 = -0.7616 * b5 - w * 0.0168980
                o[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
                b6 = w * 0.115926
            }
            let g = 1 / rms(UnsafeBufferPointer(o))
            for i in 0..<count { o[i] *= g }
        }
        return out
    }

    static let camEchoes: [(Double, Float)] = [
        (0, 1), (0.013, 0.5), (0.029, 0.4), (0.047, 0.3), (0.071, 0.2), (0.113, 0.12),
    ]
    static let dawEchoes: [(Double, Float)] = [(0, 1), (0.021, 0.35), (0.037, 0.25), (0.061, 0.18), (0.089, 0.1)]

    static func addWithEchoes(
        _ src: [Float], into dst: inout [Float], at start: Int, gain: Float, echoes: [(Double, Float)], fs: Double
    ) {
        for (d, g) in echoes {
            let s = start + Int((d * fs).rounded())
            let cnt = min(src.count, dst.count - s)
            if cnt <= 0 || s < 0 { continue }
            let gg = gain * g
            dst.withUnsafeMutableBufferPointer { dp in
                src.withUnsafeBufferPointer { sp in
                    for i in 0..<cnt { dp[s + i] += sp[i] * gg }
                }
            }
        }
    }

    /// Camera track: pink noise at `snrDB` + reverberant performance(s) + camera-only bass + LF rumble + soft-knee
    /// AGC.
    static func buildCamera(
        noise: [Float], inserts: [(offset: Double, perf: [Float])], bass: [Float], snrDB: Double, fs: Double,
        seed: UInt64
    ) -> [Float] {
        var cam = [Float](repeating: 0, count: noise.count)
        var sigRMS: Float = 0
        for (i, ins) in inserts.enumerated() {
            let s = Int((ins.offset * fs).rounded())
            addWithEchoes(ins.perf, into: &cam, at: s, gain: 1, echoes: camEchoes, fs: fs)
            if i == 0 {
                cam.withUnsafeBufferPointer {
                    sigRMS = rms(UnsafeBufferPointer(rebasing: $0[s..<min($0.count, s + ins.perf.count)]))
                }
            }
            addWithEchoes(bass, into: &cam, at: s, gain: 1, echoes: [(0, 1)], fs: fs)
        }
        let g = sigRMS * Float(pow(10, -snrDB / 20))
        // wind-like rumble: white -> one-pole LP at 30 Hz, RMS = 2x performance RMS
        var rng = SplitMix64(seed: seed)
        var y: Float = 0
        let a = Float(exp(-2 * Double.pi * 30 / fs))
        let k = 2 * sigRMS / sqrt((1 - a) / (1 + a)) / sqrt(1.0 / 3.0)
        cam.withUnsafeMutableBufferPointer { cp in
            noise.withUnsafeBufferPointer { np in
                for i in 0..<cp.count {
                    y = a * y + (1 - a) * (Float(rng.uniform()) * 2 - 1)
                    cp[i] += np[i] * g + k * y
                }
            }
        }
        compress(&cam, thresholdDB: 20 * log10(sigRMS) - 6, ratio: 4, kneeDB: 6, fs: fs)
        return cam
    }

    /// Soft-knee compressor (AGC stand-in); gain recomputed every 32 samples.
    static func compress(_ x: inout [Float], thresholdDB: Float, ratio: Float, kneeDB: Float, fs: Double) {
        let aA = Float(exp(-1 / (0.005 * fs)))
        let aR = Float(exp(-1 / (0.2 * fs)))
        var env: Float = 0
        var gain: Float = 1
        x.withUnsafeMutableBufferPointer { xp in
            for i in 0..<xp.count {
                let a = abs(xp[i])
                env = a > env ? aA * env + (1 - aA) * a : aR * env + (1 - aR) * a
                if i & 31 == 0 {
                    let over = 20 * log10(env + 1e-9) - thresholdDB
                    let eff: Float =
                        over <= -kneeDB / 2
                        ? 0 : (over >= kneeDB / 2 ? over : (over + kneeDB / 2) * (over + kneeDB / 2) / (2 * kneeDB))
                    gain = pow(10, -eff * (1 - 1 / ratio) / 20)
                }
                xp[i] *= gain
            }
        }
    }

    /// DAW render: different reverb, low-shelf +6 dB @200 Hz, high-shelf -6 dB @4 kHz, no noise/bass, RMS 0.1.
    static func dawProcess(_ x: [Float], fs: Double) -> [Float] {
        var y = [Float](repeating: 0, count: x.count + Int(0.1 * fs))
        addWithEchoes(x, into: &y, at: 0, gain: 1, echoes: dawEchoes, fs: fs)
        y = applyBiquads(
            y, [Biquad.lowShelf(fs: fs, f0: 200, gainDB: 6), Biquad.highShelf(fs: fs, f0: 4000, gainDB: -6)])
        let g = 0.1 / rms(y)
        for i in y.indices { y[i] *= g }
        return y
    }

    /// Direct-form-I cascade of a0-normalized `[b0, b1, b2, a1, a2]` sections.
    static func applyBiquads(_ x: [Float], _ sections: [[Double]]) -> [Float] {
        var y = x
        for c in sections {
            let b0 = Float(c[0]), b1 = Float(c[1]), b2 = Float(c[2]), a1 = Float(c[3]), a2 = Float(c[4])
            var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
            y.withUnsafeMutableBufferPointer { p in
                for i in 0..<p.count {
                    let x0 = p[i]
                    let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                    x2 = x1
                    x1 = x0
                    y2 = y1
                    y1 = y0
                    p[i] = y0
                }
            }
        }
        return y
    }
}

/// RBJ shelving biquads as `[b0, b1, b2, a1, a2]`, a0-normalized.
enum Biquad {
    static func norm(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double)
        -> [Double]
    {
        [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    static func lowShelf(fs: Double, f0: Double, gainDB: Double) -> [Double] {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f0 / fs, c = cos(w), al = sin(w) / 2 * sqrt(2.0)
        let s = 2 * sqrt(A) * al
        return norm(
            A * ((A + 1) - (A - 1) * c + s), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - s),
            (A + 1) + (A - 1) * c + s, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - s)
    }

    static func highShelf(fs: Double, f0: Double, gainDB: Double) -> [Double] {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f0 / fs, c = cos(w), al = sin(w) / 2 * sqrt(2.0)
        let s = 2 * sqrt(A) * al
        return norm(
            A * ((A + 1) + (A - 1) * c + s), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - s),
            (A + 1) - (A - 1) * c + s, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - s)
    }
}
