import Contracts
import Foundation
import TimelineCore

/// The onset-strength envelope of spikes/audio-align (`DSP.swift: onsetEnvelope`), computed as a stream:
/// anti-aliased resampling of the mono input to `envelopeSampleRate`, RBJ high-pass and low-pass at the bandpass
/// edges, a Hann-windowed STFT (`envelopeWindow` / `envelopeHop`), log power in `envelopeBands` log-spaced bands,
/// the half-wave rectified first difference averaged over bands, minus a running median of
/// `envelopeMedianSeconds`, minus the mean. The output matches the spike's function on the same 8 kHz input up
/// to float rounding: the spike normalises the input to unit RMS before the log, which is the same as adding
/// `epsilon * meanPower` inside the log here, so the RMS is folded in at the end rather than needing a first pass.
///
/// Memory: only the band powers per frame are kept (24 floats per 16 ms; 43 MB for two hours); the audio is not.
struct OnsetEnvelopeBuilder {
    /// The parameters that shape the artifact, hashed into `params_hash`.
    struct Parameters: Hashable, Sendable, Codable {
        var bandpassLowHz: Double
        var bandpassHighHz: Double
        var sampleRate: Int
        var window: Int
        var hop: Int
        var bands: Int
        var medianSeconds: Double
        var firTaps: Int = OnsetEnvelopeBuilder.firTaps
        var epsilon: Float = OnsetEnvelopeBuilder.epsilon

        init(_ p: AlignmentParameters) {
            bandpassLowHz = p.bandpassLowHz
            bandpassHighHz = p.bandpassHighHz
            sampleRate = p.envelopeSampleRate
            window = p.envelopeWindow
            hop = p.envelopeHop
            bands = p.envelopeBands
            medianSeconds = p.envelopeMedianSeconds
        }
    }

    static let version = 1
    static let firTaps = 127
    static let epsilon: Float = 1e-6

    let parameters: Parameters
    private var resampler: Resampler
    private var highpass: Biquad
    private var lowpass: Biquad
    private let fft: RealFFT
    private let window: [Float]
    private let edges: [Int]
    private var pending: [Float] = []
    private var bandPowers: [Float] = []
    private var frames = 0
    private var sumSquares: Double = 0
    private var sampleCount: Int64 = 0

    init(parameters: Parameters, inputSampleRate: Double) {
        self.parameters = parameters
        let fs = Double(parameters.sampleRate)
        resampler = Resampler(inputRate: inputSampleRate, outputRate: fs, taps: parameters.firTaps)
        highpass = Biquad.highpass(fs: fs, f0: parameters.bandpassLowHz)
        lowpass = Biquad.lowpass(fs: fs, f0: parameters.bandpassHighHz)
        fft = RealFFT(n: parameters.window)
        let n = parameters.window
        window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        let binHz = fs / Double(n)
        var e = (0...parameters.bands).map { b -> Int in
            let f =
                parameters.bandpassLowHz
                * pow(parameters.bandpassHighHz / parameters.bandpassLowHz, Double(b) / Double(parameters.bands))
            return Int((f / binHz).rounded())
        }
        for b in 1...parameters.bands { e[b] = max(e[b], e[b - 1] + 1) }
        edges = e.map { min($0, n / 2) }
    }

    /// Frames emitted per second of audio.
    var framesPerSecond: Double { Double(parameters.sampleRate) / Double(parameters.hop) }

    mutating func push(_ input: UnsafeBufferPointer<Float>) {
        var block = resampler.process(input)
        highpass.process(&block)
        lowpass.process(&block)
        for v in block { sumSquares += Double(v * v) }
        sampleCount += Int64(block.count)
        pending.append(contentsOf: block)
        analyzePending()
    }

    private mutating func analyzePending() {
        let n = parameters.window
        let hop = parameters.hop
        var offset = 0
        var frame = [Float](repeating: 0, count: n)
        var power = [Float](repeating: 0, count: n / 2 + 1)
        while offset + n <= pending.count {
            for i in 0..<n { frame[i] = pending[offset + i] * window[i] }
            fft.powerSpectrum(frame, into: &power)
            for b in 0..<parameters.bands {
                var s: Float = 0
                for k in edges[b]..<edges[b + 1] { s += power[k] }
                bandPowers.append(s)
            }
            frames += 1
            offset += hop
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    /// The finished envelope: one value per hop.
    mutating func finish() -> [Float] {
        let bands = parameters.bands
        let meanPower = sampleCount > 0 ? Float(sumSquares / Double(sampleCount)) : 1
        let eps = parameters.epsilon * max(meanPower, Float.leastNormalMagnitude)
        var onset = [Float](repeating: 0, count: frames)
        if frames > 1 {
            var prev = [Float](repeating: 0, count: bands)
            var cur = [Float](repeating: 0, count: bands)
            for b in 0..<bands { prev[b] = log(bandPowers[b] + eps) }
            for f in 1..<frames {
                var acc: Float = 0
                for b in 0..<bands {
                    cur[b] = log(bandPowers[f * bands + b] + eps)
                    acc += max(0, cur[b] - prev[b])
                }
                onset[f] = acc / Float(bands)
                swap(&prev, &cur)
            }
        }
        var medianFrames = Int((parameters.medianSeconds * framesPerSecond).rounded())
        if medianFrames % 2 == 0 { medianFrames += 1 }
        let out = OnsetEnvelopeBuilder.detrend(onset, medianFrames: max(medianFrames, 1))
        let mean = out.isEmpty ? 0 : out.reduce(0, +) / Float(out.count)
        return out.map { $0 - mean }
    }

    static func detrend(_ x: [Float], medianFrames: Int) -> [Float] {
        let h = medianFrames / 2
        var out = x
        var win: [Float] = []
        for f in 0..<x.count {
            win.removeAll(keepingCapacity: true)
            win.append(contentsOf: x[max(0, f - h)..<min(x.count, f + h + 1)])
            win.sort()
            out[f] = x[f] - win[win.count / 2]
        }
        return out
    }

    /// The `onset-8k.f32` bytes: little-endian Float32, one per hop.
    static func encode(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 4)
        for v in samples {
            var bits = v.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> [Float] {
        let count = data.count / 4
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                out[i] = Float(
                    bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
        return out
    }
}

// MARK: - DSP primitives (pure Swift; MediaKit does not link Accelerate)

/// RBJ biquad (transposed direct form II) with state, so it streams.
struct Biquad {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0 / a0)
        self.b1 = Float(b1 / a0)
        self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0)
        self.a2 = Float(a2 / a0)
    }

    static func lowpass(fs: Double, f0: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * f0 / fs
        let c = cos(w)
        let al = sin(w) / (2 * q)
        return Biquad(b0: (1 - c) / 2, b1: 1 - c, b2: (1 - c) / 2, a0: 1 + al, a1: -2 * c, a2: 1 - al)
    }

    static func highpass(fs: Double, f0: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * f0 / fs
        let c = cos(w)
        let al = sin(w) / (2 * q)
        return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + al, a1: -2 * c, a2: 1 - al)
    }

    mutating func process(_ x: inout [Float]) {
        for i in x.indices {
            let input = x[i]
            let y = b0 * input + z1
            z1 = b1 * input - a1 * y + z2
            z2 = b2 * input - a2 * y
            x[i] = y
        }
    }
}

/// Streaming rate conversion: a Blackman-windowed sinc low-pass evaluated only at the two input positions that
/// bracket each output sample, then linear interpolation (the input is oversampled several times over the
/// pass-band, so the interpolation error is far below the filter's stop-band). Unity ratio is a pass-through.
struct Resampler {
    let ratio: Double
    private let taps: [Float]
    private var history: [Float] = []
    private var position: Double = 0

    init(inputRate: Double, outputRate: Double, taps: Int) {
        ratio = inputRate / outputRate
        if inputRate <= outputRate {
            self.taps = []
        } else {
            self.taps = Resampler.lowpassFIR(taps: taps, cutoff: 0.45 * outputRate / inputRate)
        }
    }

    static func lowpassFIR(taps: Int, cutoff: Double) -> [Float] {
        let m = Double(taps - 1)
        var h = (0..<taps).map { i -> Float in
            let x = Double(i) - m / 2
            let s = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / m) + 0.08 * cos(4 * .pi * Double(i) / m)
            return Float(s * w)
        }
        let sum = h.reduce(0, +)
        for i in h.indices { h[i] /= sum }
        return h
    }

    mutating func process(_ input: UnsafeBufferPointer<Float>) -> [Float] {
        if taps.isEmpty && ratio == 1 { return Array(input) }
        history.append(contentsOf: input)
        let n = taps.count
        // The filtered value at integer index k needs history[k - n + 1 ... k].
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / ratio) + 2)
        let lastUsable = history.count - 2
        history.withUnsafeBufferPointer { h in
            taps.withUnsafeBufferPointer { t in
                func filtered(_ k: Int) -> Float {
                    if n == 0 { return h[k] }
                    var acc: Float = 0
                    let start = k - n + 1
                    if start >= 0 {
                        for i in 0..<n { acc += t[i] * h[k - i] }
                    } else {
                        for i in 0..<n where k - i >= 0 { acc += t[i] * h[k - i] }
                    }
                    return acc
                }
                while Int(position) + 1 <= lastUsable {
                    let k = Int(position)
                    let f = Float(position - Double(k))
                    let a = filtered(k)
                    let b = filtered(k + 1)
                    out.append(a + (b - a) * f)
                    position += ratio
                }
            }
        }
        // Drop history no longer needed by any future output: keep n samples before the next read position.
        let keepFrom = max(0, Int(position) - n)
        if keepFrom > 0 {
            history.removeFirst(keepFrom)
            position -= Double(keepFrom)
        }
        return out
    }
}

/// Radix-2 complex FFT used for real frames of `n` samples (power of two); yields the power spectrum of bins
/// 0...n/2.
final class RealFFT {
    let n: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private var re: [Float]
    private var im: [Float]

    init(n: Int) {
        precondition(n > 1 && n & (n - 1) == 0, "FFT size must be a power of two")
        self.n = n
        cosTable = (0..<n / 2).map { Float(cos(2 * Double.pi * Double($0) / Double(n))) }
        sinTable = (0..<n / 2).map { Float(-sin(2 * Double.pi * Double($0) / Double(n))) }
        re = [Float](repeating: 0, count: n)
        im = [Float](repeating: 0, count: n)
    }

    /// `power[k] = |X[k]|^2` for `k` in `0...n/2`.
    func powerSpectrum(_ x: [Float], into power: inout [Float]) {
        let bits = n.trailingZeroBitCount
        for i in 0..<n {
            var r = 0
            var v = i
            for _ in 0..<bits {
                r = (r << 1) | (v & 1)
                v >>= 1
            }
            re[r] = x[i]
            im[r] = 0
        }
        var size = 2
        while size <= n {
            let half = size / 2
            let step = n / size
            var start = 0
            while start < n {
                var k = 0
                for j in start..<start + half {
                    let wr = cosTable[k]
                    let wi = sinTable[k]
                    let tr = re[j + half] * wr - im[j + half] * wi
                    let ti = re[j + half] * wi + im[j + half] * wr
                    re[j + half] = re[j] - tr
                    im[j + half] = im[j] - ti
                    re[j] += tr
                    im[j] += ti
                    k += step
                }
                start += size
            }
            size <<= 1
        }
        for k in 0...n / 2 { power[k] = re[k] * re[k] + im[k] * im[k] }
    }
}
