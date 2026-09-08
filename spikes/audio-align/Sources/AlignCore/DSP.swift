import Foundation
import Accelerate

public func nextPow2(_ n: Int) -> Int { var p = 1; while p < n { p <<= 1 }; return p }

/// RBJ biquads, returned as [b0,b1,b2,a1,a2] (a0-normalized) for vDSP.Biquad.
public enum Biquad {
    static func norm(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> [Double] {
        [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }
    public static func lowpass(fs: Double, f0: Double, q: Double = 0.7071) -> [Double] {
        let w = 2 * .pi * f0 / fs, c = cos(w), al = sin(w) / (2 * q)
        return norm((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al)
    }
    public static func highpass(fs: Double, f0: Double, q: Double = 0.7071) -> [Double] {
        let w = 2 * .pi * f0 / fs, c = cos(w), al = sin(w) / (2 * q)
        return norm((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al)
    }
    public static func lowShelf(fs: Double, f0: Double, gainDB: Double) -> [Double] {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f0 / fs, c = cos(w), al = sin(w) / 2 * sqrt(2.0), s = 2 * sqrt(A) * al
        return norm(A * ((A + 1) - (A - 1) * c + s), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - s),
                    (A + 1) + (A - 1) * c + s, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - s)
    }
    public static func highShelf(fs: Double, f0: Double, gainDB: Double) -> [Double] {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f0 / fs, c = cos(w), al = sin(w) / 2 * sqrt(2.0), s = 2 * sqrt(A) * al
        return norm(A * ((A + 1) + (A - 1) * c + s), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - s),
                    (A + 1) - (A - 1) * c + s, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - s)
    }
}

public func applyBiquads(_ x: [Float], _ sections: [[Double]]) -> [Float] {
    var bq = vDSP.Biquad(coefficients: sections.flatMap { $0 }, channelCount: 1, sectionCount: vDSP_Length(sections.count), ofType: Float.self)!
    return bq.apply(input: x)
}

/// Arbitrary-ratio 4-point Hermite resampler. `ratio` = input samples per output sample. Zero delay.
public func resampleHermite(_ x: [Float], ratio: Double) -> [Float] {
    let n = Int(Double(x.count - 3) / ratio)
    var out = [Float](repeating: 0, count: n)
    x.withUnsafeBufferPointer { xp in
        for i in 0..<n {
            let pos = Double(i) * ratio; let k = Int(pos); let f = Float(pos - Double(k))
            let xm1 = k > 0 ? xp[k - 1] : xp[k], x0 = xp[k], x1 = xp[k + 1], x2 = xp[k + 2]
            let c1 = 0.5 * (x1 - xm1), c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2, c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
            out[i] = ((c3 * f + c2) * f + c1) * f + x0
        }
    }
    return out
}

/// Blackman-windowed sinc lowpass FIR, unity DC gain. `cutoff` as fraction of input fs.
public func lowpassFIR(taps: Int, cutoff: Double) -> [Float] {
    let m = Double(taps - 1)
    var h = (0..<taps).map { i -> Float in
        let x = Double(i) - m / 2
        let s = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
        let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / m) + 0.08 * cos(4 * .pi * Double(i) / m)
        return Float(s * w)
    }
    let sum = h.reduce(0, +); for i in h.indices { h[i] /= sum }
    return h
}

/// FIR + integer decimation in one vDSP call.
public func decimate(_ x: [Float], by m: Int, filter: [Float]) -> [Float] {
    let outCount = (x.count - filter.count) / m
    var out = [Float](repeating: 0, count: outCount)
    vDSP_desamp(x, vDSP_Stride(m), filter, &out, vDSP_Length(outCount), vDSP_Length(filter.count))
    return out
}

/// Thin wrapper around vDSP packed real FFT (vDSP_fft_zrip). Spectra are n/2 split-complex with
/// re[0] = DC and im[0] = Nyquist (packed format). Forward output is 2x the true DFT; inverse is unnormalized
/// (sum without 1/n), so forward->inverse round trip is scaled by 2n, and a product of two forward spectra
/// inverted is scaled by 4n.
public final class RealFFT {
    public let n: Int, half: Int, log2n: vDSP_Length
    let setup: FFTSetup
    public init(n: Int) {
        precondition(n == nextPow2(n)); self.n = n; half = n / 2
        log2n = vDSP_Length(log2(Double(n)).rounded()); setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    public func forward(_ x: UnsafePointer<Float>, count: Int, re: inout [Float], im: inout [Float]) {
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_vclr(rp.baseAddress!, 1, vDSP_Length(half)); vDSP_vclr(ip.baseAddress!, 1, vDSP_Length(half))
            x.withMemoryRebound(to: DSPComplex.self, capacity: count / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(count / 2)) }
            if count & 1 == 1 { rp[count / 2] = x[count - 1] }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        } }
    }
    public func forward(_ x: [Float]) -> (re: [Float], im: [Float]) {
        var re = [Float](repeating: 0, count: half), im = re
        x.withUnsafeBufferPointer { forward($0.baseAddress!, count: min(x.count, n), re: &re, im: &im) }
        return (re, im)
    }
    public func inverse(re: [Float], im: [Float]) -> [Float] {
        var re = re, im = im, out = [Float](repeating: 0, count: n)
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
            out.withUnsafeMutableBufferPointer { op in
                op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half)) }
            }
        } }
        return out
    }
    /// Packed-spectrum product a * conj(b); bin 0 carries (DC, Nyquist) and is handled separately.
    public static func multiplyConj(_ a: (re: [Float], im: [Float]), _ b: (re: [Float], im: [Float])) -> (re: [Float], im: [Float]) {
        var re = vDSP.add(vDSP.multiply(a.re, b.re), vDSP.multiply(a.im, b.im))
        var im = vDSP.subtract(vDSP.multiply(a.im, b.re), vDSP.multiply(a.re, b.im))
        re[0] = a.re[0] * b.re[0]; im[0] = a.im[0] * b.im[0]
        return (re, im)
    }
}

/// Onset-strength envelope at fs/hop fps: STFT (nfft/hop), log-power in log-spaced bands,
/// half-wave rectified first difference, mean over bands, minus running median.
public func onsetEnvelope(_ xin: [Float], fs: Double = 8000, nfft: Int = 512, hop: Int = 128, bands: Int = 24,
                          fLo: Double = 300, fHi: Double = 3000, medianFrames: Int = 63) -> [Float] {
    var rms: Float = 0; vDSP_rmsqv(xin, 1, &rms, vDSP_Length(xin.count))
    let x = vDSP.multiply(1 / max(rms, 1e-9), xin)
    let frames = (x.count - nfft) / hop + 1
    let fft = RealFFT(n: nfft)
    var window = [Float](repeating: 0, count: nfft); vDSP_hann_window(&window, vDSP_Length(nfft), Int32(vDSP_HANN_NORM))
    var edges = (0...bands).map { Int((fLo * pow(fHi / fLo, Double($0) / Double(bands)) / (fs / Double(nfft))).rounded()) }
    for b in 1...bands { edges[b] = max(edges[b], edges[b - 1] + 1) }
    var prevLog = [Float](repeating: 0, count: bands), curLog = prevLog
    var onset = [Float](repeating: 0, count: frames)
    var frame = [Float](repeating: 0, count: nfft), power = [Float](repeating: 0, count: nfft / 2)
    var re = [Float](repeating: 0, count: nfft / 2), im = re
    x.withUnsafeBufferPointer { xp in
        for f in 0..<frames {
            vDSP_vmul(xp.baseAddress! + f * hop, 1, window, 1, &frame, 1, vDSP_Length(nfft))
            frame.withUnsafeBufferPointer { fft.forward($0.baseAddress!, count: nfft, re: &re, im: &im) }
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(nfft / 2))
            } }
            for b in 0..<bands {
                var s: Float = 0
                power.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + edges[b], 1, &s, vDSP_Length(edges[b + 1] - edges[b])) }
                curLog[b] = log(s + 1e-6)
            }
            if f > 0 { var acc: Float = 0; for b in 0..<bands { acc += max(0, curLog[b] - prevLog[b]) }; onset[f] = acc / Float(bands) }
            swap(&prevLog, &curLog)
        }
    }
    var out = onset; let h = medianFrames / 2; var win: [Float] = []
    for f in 0..<frames {
        win.removeAll(keepingCapacity: true); win.append(contentsOf: onset[max(0, f - h)..<min(frames, f + h + 1)]); win.sort()
        out[f] = onset[f] - win[win.count / 2]
    }
    return vDSP.add(-vDSP.mean(out), out)
}
