import Accelerate
import Foundation
import TimelineCore

struct CoarseCandidate: Sendable, Hashable {
    /// Position of target envelope frame 0 within the reference envelope, in frames.
    var lagFrames: Int
    /// Normalised cross-correlation at that lag.
    var ncc: Float
}

struct CoarseResult: Sendable {
    /// Best first, non-maximum suppressed.
    var candidates: [CoarseCandidate]
    var peak: Float
    /// Best NCC outside the exclusion zone around the peak (diagnostic only; not a gate).
    var second: Float
    /// `ncc[i]` is the score at lag `lagStart + i` frames.
    var ncc: [Float]
    var lagStart: Int
}

/// FFT cross-correlation of two onset envelopes, normalised per lag by the energy of the overlapping segments
/// (Double prefix sums), with an energy floor over near-silent stretches and a minimum overlap. Ported from
/// `coarseAlign` in spikes/audio-align.
enum CoarsePass {
    static func correlate(
        reference a: [Float], target b: [Float], frameRate: Double, parameters p: AlignmentParameters
    ) -> CoarseResult {
        let la = a.count, lb = b.count
        let empty = CoarseResult(candidates: [], peak: 0, second: 0, ncc: [], lagStart: 0)
        guard la > 0, lb > 0 else { return empty }
        let shorter = min(la, lb)
        let minOverlap = max(
            1,
            min(
                shorter,
                max(Int(Double(shorter) * p.minimumOverlapFraction), Int(p.minimumOverlapSeconds * frameRate))))
        let lagLo = -(lb - minOverlap), lagHi = la - minOverlap + 1
        guard lagHi > lagLo else { return empty }

        let n = RealFFT.nextPowerOfTwo(la + lb)
        let fft = RealFFT(n: n)
        var aRe = [Float](repeating: 0, count: n / 2), aIm = aRe, bRe = aRe, bIm = aRe, re = aRe, im = aRe
        fft.forward(a, re: &aRe, im: &aIm)
        fft.forward(b, re: &bRe, im: &bIm)
        RealFFT.multiplyConjugate(aRe: aRe, aIm: aIm, bRe: bRe, bIm: bIm, re: &re, im: &im)
        var r = [Float](repeating: 0, count: n)
        fft.inverse(re: &re, im: &im, into: &r)
        let scale = 1 / (4 * Double(n))

        var pa = [Double](repeating: 0, count: la + 1), pb = [Double](repeating: 0, count: lb + 1)
        for i in 0..<la { pa[i + 1] = pa[i] + Double(a[i]) * Double(a[i]) }
        for i in 0..<lb { pb[i + 1] = pb[i] + Double(b[i]) * Double(b[i]) }
        let meanA = pa[la] / Double(la), meanB = pb[lb] / Double(lb)
        let floorFraction = p.energyFloorFraction

        var ncc = [Float](repeating: 0, count: lagHi - lagLo)
        ncc.withUnsafeMutableBufferPointer { out in
            r.withUnsafeBufferPointer { rp in
                for l in lagLo..<lagHi {
                    let n0 = max(0, -l), n1 = min(lb, la - l)
                    let overlap = Double(n1 - n0)
                    guard overlap > 0 else { continue }
                    let ea = max(pa[n1 + l] - pa[n0 + l], floorFraction * overlap * meanA)
                    let eb = max(pb[n1] - pb[n0], floorFraction * overlap * meanB)
                    let raw = Double(rp[l >= 0 ? l : n + l]) * scale
                    out[l - lagLo] = Float(raw / sqrt(max(ea * eb, 1e-12)))
                }
            }
        }

        var peak: Float = 0
        var peakIndex: vDSP_Length = 0
        vDSP_maxvi(ncc, 1, &peak, &peakIndex, vDSP_Length(ncc.count))
        let exclusion = max(1, Int(p.secondPeakExclusionSeconds * frameRate))
        var second: Float = -1
        for i in 0..<ncc.count where abs(i - Int(peakIndex)) > exclusion { second = max(second, ncc[i]) }

        var candidates: [CoarseCandidate] = []
        if peak > 0 {
            let cutoff = Float(p.candidateCutoffRatio) * peak
            let indices = (0..<ncc.count).filter { ncc[$0] >= cutoff }.sorted { ncc[$0] > ncc[$1] }
            for i in indices where !candidates.contains(where: { abs($0.lagFrames - lagLo - i) <= exclusion }) {
                candidates.append(CoarseCandidate(lagFrames: i + lagLo, ncc: ncc[i]))
                if candidates.count >= p.maxCandidates { break }
            }
        }
        return CoarseResult(candidates: candidates, peak: peak, second: second, ncc: ncc, lagStart: lagLo)
    }

    /// Max-pools `ncc` to at most `points` values so a proof image keeps every peak.
    static func pooled(_ ncc: [Float], points: Int) -> (values: [Float], bucket: Int) {
        guard ncc.count > points, points > 0 else { return (ncc, 1) }
        let bucket = (ncc.count + points - 1) / points
        var out: [Float] = []
        out.reserveCapacity(points)
        var start = 0
        while start < ncc.count {
            let end = min(ncc.count, start + bucket)
            out.append(ncc[start..<end].max() ?? 0)
            start = end
        }
        return (out, bucket)
    }
}
