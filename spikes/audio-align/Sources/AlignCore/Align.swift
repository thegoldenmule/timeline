import Foundation
import Accelerate

public struct CoarseResult {
    public var lagFrames: Int          // position of DAW envelope frame 0 within camera envelope
    public var ncc: Float              // normalized cross-correlation at the peak
    public var second: Float           // best NCC outside the exclusion zone around the peak
    public var ratio: Float { ncc / max(second, 1e-6) }
    public var candidates: [(lag: Int, ncc: Float)]  // NMS peaks >= candidateFrac * peak
}

/// FFT cross-correlation of onset envelopes, normalized by the energy of the overlapping segments,
/// with a minimum-overlap constraint. Returns peak, second peak and a candidate list.
public func coarseAlign(cam a: [Float], daw b: [Float], minOverlapFrac: Double = 0.5,
                        exclusionFrames: Int = 312, candidateFrac: Float = 0.5) -> CoarseResult {
    let La = a.count, Lb = b.count, n = nextPow2(La + Lb)
    let fft = RealFFT(n: n)
    let prod = RealFFT.multiplyConj(fft.forward(a), fft.forward(b))
    let r = fft.inverse(re: prod.re, im: prod.im)
    let scale = 1 / (4 * Double(n))
    var pa = [Double](repeating: 0, count: La + 1), pb = [Double](repeating: 0, count: Lb + 1)
    for i in 0..<La { pa[i + 1] = pa[i] + Double(a[i]) * Double(a[i]) }
    for i in 0..<Lb { pb[i + 1] = pb[i] + Double(b[i]) * Double(b[i]) }
    let minOv = Int(Double(Lb) * minOverlapFrac)
    let lagLo = -(Lb - minOv), lagHi = La - minOv
    // Energy floor: a near-silent camera stretch must not inflate NCC (floor = 10% of the mean power over the overlap).
    let meanA = pa[La] / Double(La), meanB = pb[Lb] / Double(Lb)
    var ncc = [Float](repeating: 0, count: lagHi - lagLo)
    for l in lagLo..<lagHi {
        let n0 = max(0, -l), n1 = min(Lb, La - l), ov = Double(n1 - n0)
        let ea = max(pa[n1 + l] - pa[n0 + l], 0.1 * ov * meanA), eb = max(pb[n1] - pb[n0], 0.1 * ov * meanB)
        ncc[l - lagLo] = Float(Double(r[l >= 0 ? l : n + l]) * scale / sqrt(max(ea * eb, 1e-12)))
    }
    var maxV: Float = 0, maxI: vDSP_Length = 0
    vDSP_maxvi(ncc, 1, &maxV, &maxI, vDSP_Length(ncc.count))
    var second: Float = -1
    for i in 0..<ncc.count where abs(i - Int(maxI)) > exclusionFrames { second = max(second, ncc[i]) }
    var cands: [(lag: Int, ncc: Float)] = []
    let idxs = (0..<ncc.count).filter { ncc[$0] >= candidateFrac * maxV }.sorted { ncc[$0] > ncc[$1] }
    for i in idxs where !cands.contains(where: { abs($0.lag - i) <= exclusionFrames }) {
        cands.append((i, ncc[i])); if cands.count >= 5 { break }
    }
    return CoarseResult(lagFrames: Int(maxI) + lagLo, ncc: maxV, second: second,
                        candidates: cands.map { ($0.lag + lagLo, $0.ncc) })
}

public struct FineWindow {
    public let tDAW: Double     // nominal DAW time of window center (s)
    public let offset: Double   // camera sample position of DAW sample 0 implied by this window
    public let peak: Float
    public let ratio: Float     // peak / best peak more than 1 ms away
}

/// GCC-PHAT (|G|^rho whitening, band-limited) in a ±maxLag window around the coarse lag, one estimate per excerpt,
/// with parabolic peak interpolation.
public func fineAlign(cam: [Float], daw: [Float], coarseStart: Int, fs: Double = 48000, winSec: Double = 10, hopSec: Double = 10,
                      maxLagMs: Double = 100, rho: Float = 1.0, bandHz: (Double, Double) = (80, 7000)) -> [FineWindow] {
    let Ld = Int(winSec * fs), hop = Int(hopSec * fs), M = Int(maxLagMs / 1000 * fs)
    let n = nextPow2(Ld + 2 * M), fft = RealFFT(n: n)
    let kLo = Int(bandHz.0 / fs * Double(n)), kHi = min(n / 2 - 1, Int(bandHz.1 / fs * Double(n)))
    var result: [FineWindow] = []
    var w = 0
    while w + Ld <= daw.count {
        let cs = coarseStart + w - M
        if cs >= 0 && cs + Ld + 2 * M <= cam.count {
            var C = (re: [Float](repeating: 0, count: n / 2), im: [Float](repeating: 0, count: n / 2)), D = C
            cam.withUnsafeBufferPointer { fft.forward($0.baseAddress! + cs, count: Ld + 2 * M, re: &C.re, im: &C.im) }
            daw.withUnsafeBufferPointer { fft.forward($0.baseAddress! + w, count: Ld, re: &D.re, im: &D.im) }
            var G = RealFFT.multiplyConj(C, D)
            let mag = vDSP.hypot(G.re, G.im)
            let eps = vDSP.maximum(mag) * 1e-6 + 1e-20
            for k in 0..<n / 2 {
                let wgt: Float = (k >= kLo && k <= kHi) ? 1 / (pow(mag[k], rho) + eps) : 0
                G.re[k] *= wgt; G.im[k] *= wgt
            }
            let r = fft.inverse(re: G.re, im: G.im)
            var pv: Float = 0, pi: vDSP_Length = 0
            vDSP_maxvi(r, 1, &pv, &pi, vDSP_Length(2 * M + 1))
            let p = Int(pi); var frac = 0.0
            if p > 0 && p < 2 * M {
                let y0 = Double(r[p - 1]), y1 = Double(r[p]), y2 = Double(r[p + 1]), den = y0 - 2 * y1 + y2
                if den != 0 { frac = 0.5 * (y0 - y2) / den }
            }
            var second: Float = 0
            for i in 0...(2 * M) where abs(i - p) > 48 { second = max(second, r[i]) }
            result.append(FineWindow(tDAW: (Double(w) + Double(Ld) / 2) / fs, offset: Double(coarseStart) + Double(p) + frac - Double(M),
                                     peak: pv, ratio: pv / max(second, 1e-9)))
        }
        w += hop
    }
    return result
}

public struct LineFit { public let slope: Double, intercept: Double, mad: Double, inliers: Int, n: Int }

public func median(_ v: [Double]) -> Double {
    if v.isEmpty { return .nan }
    let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
}

/// Theil-Sen robust line: median of pairwise slopes, median intercept. Refit once on inliers (|res| <= tol).
public func theilSen(x: [Double], y: [Double], inlierTol: Double) -> LineFit {
    func fit(_ x: [Double], _ y: [Double]) -> (Double, Double) {
        var slopes: [Double] = []
        for i in 0..<x.count { for j in (i + 1)..<x.count where x[j] != x[i] { slopes.append((y[j] - y[i]) / (x[j] - x[i])) } }
        let s = slopes.isEmpty ? 0 : median(slopes)
        return (s, median(zip(x, y).map { $1 - s * $0 }))
    }
    var (s, b) = fit(x, y)
    var res = zip(x, y).map { abs($1 - (b + s * $0)) }
    let keep = res.indices.filter { res[$0] <= inlierTol }
    if keep.count >= 3 && keep.count < x.count {
        (s, b) = fit(keep.map { x[$0] }, keep.map { y[$0] })
        res = zip(x, y).map { abs($1 - (b + s * $0)) }
    }
    return LineFit(slope: s, intercept: b, mad: median(res), inliers: res.filter { $0 <= inlierTol }.count, n: x.count)
}
