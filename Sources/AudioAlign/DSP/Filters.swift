import Accelerate
import Foundation

/// RBJ Butterworth biquads as `[b0, b1, b2, a1, a2]`, a0-normalised, the layout `vDSP.Biquad` expects.
enum BiquadDesign {
    static let butterworthQ = 0.5.squareRoot()

    private static func normalised(
        _ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double
    ) -> [Double] {
        [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    static func lowpass(sampleRate fs: Double, cutoff f0: Double, q: Double = butterworthQ) -> [Double] {
        let w = 2 * Double.pi * f0 / fs
        let c = cos(w)
        let alpha = sin(w) / (2 * q)
        return normalised((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func highpass(sampleRate fs: Double, cutoff f0: Double, q: Double = butterworthQ) -> [Double] {
        let w = 2 * Double.pi * f0 / fs
        let c = cos(w)
        let alpha = sin(w) / (2 * q)
        return normalised((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }
}

/// Blackman-windowed sinc lowpass FIR with unity DC gain. `cutoff` is a fraction of the sample rate.
func lowpassFIR(taps: Int, cutoff: Double) -> [Float] {
    precondition(taps >= 3)
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

/// FIR lowpass plus integer decimation in one `vDSP_desamp` call, fed in chunks. Output sample `i` sits at input
/// sample `i * factor + (taps - 1) / 2`; the group delay is identical for both signals of an alignment and
/// cancels in the coarse lag.
struct StreamingDecimator {
    let factor: Int
    let filter: [Float]
    private var carry: [Float] = []

    init(factor: Int, filter: [Float]) {
        precondition(factor >= 1 && filter.count >= 1)
        self.factor = factor
        self.filter = filter
    }

    /// Input samples held back for the next call: always fewer than `taps + factor`.
    var residentSampleCount: Int { carry.count }

    mutating func process(_ x: UnsafeBufferPointer<Float>) -> [Float] {
        carry.append(contentsOf: x)
        let taps = filter.count
        guard carry.count >= taps else { return [] }
        let outCount = (carry.count - taps) / factor + 1
        var out = [Float](repeating: 0, count: outCount)
        vDSP_desamp(carry, vDSP_Stride(factor), filter, &out, vDSP_Length(outCount), vDSP_Length(taps))
        carry.removeFirst(outCount * factor)
        return out
    }
}

/// Arbitrary-ratio 4-point Hermite interpolation, fed in chunks. `ratio` is input samples per output sample;
/// output `j` sits at input position `j * ratio` (zero delay). Not band-limited: use it after a lowpass when
/// reducing the rate, and only for ratios near 1 or below.
struct StreamingHermiteResampler {
    let ratio: Double
    /// `buffer[0]` is the sample before the oldest unconsumed sample (a virtual zero at the very start).
    private var buffer: [Float] = [0]
    /// Position of the next output, in `buffer` coordinates.
    private var position: Double = 1

    init(ratio: Double) {
        precondition(ratio > 0)
        self.ratio = ratio
    }

    var residentSampleCount: Int { buffer.count }

    mutating func process(_ x: [Float]) -> [Float] {
        buffer.append(contentsOf: x)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(x.count) / ratio) + 2)
        buffer.withUnsafeBufferPointer { b in
            while Int(position) + 2 < b.count {
                out.append(hermite(b, at: position))
                position += ratio
            }
        }
        let drop = Int(position) - 1
        if drop > 0 {
            buffer.removeFirst(drop)
            position -= Double(drop)
        }
        return out
    }
}

/// Hermite sample of `x` at fractional index `pos`; requires `1 <= pos` and `Int(pos) + 2 < x.count`.
@inline(__always)
private func hermite(_ x: UnsafeBufferPointer<Float>, at pos: Double) -> Float {
    let k = Int(pos)
    let f = Float(pos - Double(k))
    let xm1 = x[k - 1], x0 = x[k], x1 = x[k + 1], x2 = x[k + 2]
    let c1 = 0.5 * (x1 - xm1)
    let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
    let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
    return ((c3 * f + c2) * f + c1) * f + x0
}

/// `count` Hermite-interpolated samples of `x` at positions `start + i * ratio`; positions whose 4-point
/// neighbourhood leaves `x` read as zero-padded.
func hermiteResample(_ x: [Float], start: Double, ratio: Double, count: Int) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    guard count > 0, !x.isEmpty else { return out }
    // Pad by one sample on the left and three on the right so every in-range position has its neighbours.
    var padded = [Float](repeating: 0, count: x.count + 4)
    padded.replaceSubrange(1..<(1 + x.count), with: x)
    padded.withUnsafeBufferPointer { p in
        for i in 0..<count {
            let pos = start + Double(i) * ratio + 1
            guard pos >= 1, Int(pos) + 2 < p.count else { continue }
            out[i] = hermite(p, at: pos)
        }
    }
    return out
}

/// A cascade of biquad sections that keeps its state between chunks.
struct StreamingBiquad {
    private var biquad: vDSP.Biquad<Float>

    init(sections: [[Double]]) {
        biquad = vDSP.Biquad(
            coefficients: sections.flatMap { $0 }, channelCount: 1, sectionCount: vDSP_Length(sections.count),
            ofType: Float.self)!
    }

    mutating func process(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return [] }
        return biquad.apply(input: x)
    }
}
