import Accelerate

/// Thin wrapper around the vDSP packed real FFT (`vDSP_fft_zrip`), ported from `spikes/audio-align`.
///
/// Spectra are `n/2` split-complex values in packed format: `re[0]` is the DC term and `im[0]` the Nyquist term
/// (both real), so a plain complex multiply corrupts bin 0; see `multiplyConjugate`. Scaling: the forward
/// transform returns 2x the DFT and the inverse is an unnormalised sum, so a forward->inverse round trip is
/// scaled by `2n` and the inverse of a product of two forward spectra by `4n`.
///
/// Not `Sendable`: `FFTSetup` is an opaque pointer. Create one per task.
final class RealFFT {
    let n: Int
    let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(n: Int) {
        precondition(n >= 2 && n & (n - 1) == 0, "FFT size must be a power of two, got \(n)")
        self.n = n
        half = n / 2
        log2n = vDSP_Length(n.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    static func nextPowerOfTwo(_ n: Int) -> Int {
        var p = 2
        while p < n { p <<= 1 }
        return p
    }

    /// Forward transform of `x` zero-padded to `n` (`x.count <= n`) into packed split-complex `re` / `im`, each
    /// of `half` values.
    func forward(_ x: UnsafeBufferPointer<Float>, re: inout [Float], im: inout [Float]) {
        let count = x.count
        precondition(count <= n && re.count == half && im.count == half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_vclr(rp.baseAddress!, 1, vDSP_Length(half))
                vDSP_vclr(ip.baseAddress!, 1, vDSP_Length(half))
                // `ctoz` reads `count / 2` interleaved pairs; an odd trailing sample lands in `realp[count / 2]`.
                if count >= 2, let base = x.baseAddress {
                    base.withMemoryRebound(to: DSPComplex.self, capacity: count / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(count / 2))
                    }
                }
                if count & 1 == 1 { rp[count / 2] = x[count - 1] }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    func forward(_ x: [Float], re: inout [Float], im: inout [Float]) {
        x.withUnsafeBufferPointer { forward($0, re: &re, im: &im) }
    }

    /// Inverse transform of a packed spectrum into `out` (`n` values). The spectrum buffers are destroyed.
    func inverse(re: inout [Float], im: inout [Float], into out: inout [Float]) {
        precondition(out.count == n && re.count == half && im.count == half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }
        }
    }

    /// Power spectrum `re^2 + im^2` of a packed spectrum (bin 0 mixes DC and Nyquist).
    func power(re: inout [Float], im: inout [Float], into power: inout [Float]) {
        precondition(power.count == half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
    }

    /// Packed-spectrum product `a * conj(b)`, with bin 0 (DC, Nyquist) multiplied as two real values.
    static func multiplyConjugate(
        aRe: [Float], aIm: [Float], bRe: [Float], bIm: [Float], re: inout [Float], im: inout [Float]
    ) {
        re = vDSP.add(vDSP.multiply(aRe, bRe), vDSP.multiply(aIm, bIm))
        im = vDSP.subtract(vDSP.multiply(aIm, bRe), vDSP.multiply(aRe, bIm))
        re[0] = aRe[0] * bRe[0]
        im[0] = aIm[0] * bIm[0]
    }
}
