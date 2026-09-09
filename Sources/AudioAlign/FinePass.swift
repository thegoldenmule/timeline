import Accelerate
import Foundation
import TimelineCore

/// One GCC-PHAT measurement: where the reference sits relative to one excerpt of the target.
struct FineWindow: Sendable, Hashable {
    /// Nominal target time of the window centre, seconds.
    var targetTimeSeconds: Double
    /// Reference sample position of target sample 0 implied by this window (sub-sample).
    var offsetSamples: Double
    /// PHAT correlation peak value.
    var peak: Float
    /// Peak over the best value more than `AlignerDefaults.phatSecondPeakExclusionMs` away.
    var ratio: Float
}

/// A robust line `y = intercept + slope * x` through window offsets. Points flagged invalid (a PHAT peak with
/// no clear winner) never take part in the fit and never count as inliers, but they still count in the
/// denominator of `inlierFraction`.
struct LineFit: Sendable {
    var slope: Double
    var intercept: Double
    /// Median absolute residual over the valid points, in `y` units.
    var mad: Double
    var residuals: [Double]
    var valid: [Bool]
    var inlierTolerance: Double

    var count: Int { residuals.count }
    var inliers: [Bool] { zip(residuals, valid).map { $0 <= inlierTolerance && $1 } }
    var inlierCount: Int { inliers.filter { $0 }.count }
    var inlierFraction: Double { count == 0 ? 0 : Double(inlierCount) / Double(count) }
}

func median(_ v: [Double]) -> Double {
    if v.isEmpty { return .nan }
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
}

/// Theil-Sen robust line: median of pairwise slopes, median intercept, refit once on inliers (|residual| <=
/// `inlierTolerance`). With `fitSlope == false` the slope is held at zero (too few windows for a drift fit).
/// Points with `valid == false` are excluded from the fit.
func theilSen(
    x allX: [Double], y allY: [Double], valid allValid: [Bool]? = nil, inlierTolerance: Double,
    fitSlope: Bool = true
) -> LineFit {
    precondition(allX.count == allY.count)
    let valid = allValid ?? [Bool](repeating: true, count: allX.count)
    precondition(valid.count == allX.count)
    let validIndices = valid.indices.filter { valid[$0] }
    let x = validIndices.map { allX[$0] }, y = validIndices.map { allY[$0] }
    func fit(_ x: [Double], _ y: [Double]) -> (slope: Double, intercept: Double) {
        guard !x.isEmpty else { return (0, .nan) }
        var slope = 0.0
        if fitSlope {
            var slopes: [Double] = []
            for i in 0..<x.count {
                for j in (i + 1)..<x.count where x[j] != x[i] { slopes.append((y[j] - y[i]) / (x[j] - x[i])) }
            }
            slope = slopes.isEmpty ? 0 : median(slopes)
        }
        return (slope, median(zip(x, y).map { $1 - slope * $0 }))
    }
    var (s, b) = fit(x, y)
    var residuals = zip(x, y).map { abs($1 - (b + s * $0)) }
    let keep = residuals.indices.filter { residuals[$0] <= inlierTolerance }
    if keep.count >= 3 && keep.count < x.count {
        (s, b) = fit(keep.map { x[$0] }, keep.map { y[$0] })
        residuals = zip(x, y).map { abs($1 - (b + s * $0)) }
    }
    let allResiduals = zip(allX, allY).map { abs($1 - (b + s * $0)) }
    return LineFit(
        slope: s, intercept: b, mad: residuals.isEmpty ? .nan : median(residuals), residuals: allResiduals,
        valid: valid, inlierTolerance: inlierTolerance)
}

/// GCC-PHAT (`|G|^rho` whitening, band-limited) between a reference excerpt of `windowSamples + 2 * radius`
/// samples and a target excerpt of `windowSamples`, searching lags `0...2 * radius`, with parabolic peak
/// interpolation. Ported from `fineAlign` in spikes/audio-align. Not `Sendable`: holds FFT scratch.
final class FinePass {
    let sampleRate: Double
    let windowSamples: Int
    let radius: Int
    private let fft: RealFFT
    private let mask: [Float]
    private let rho: Float
    private let epsilon: Float
    private let exclusion: Int
    private var cRe: [Float], cIm: [Float], dRe: [Float], dIm: [Float], gRe: [Float], gIm: [Float]
    private var r: [Float]
    private var exponent: [Float]

    init(sampleRate: Double, windowSamples: Int, parameters p: AlignmentParameters) {
        self.sampleRate = sampleRate
        self.windowSamples = windowSamples
        radius = max(1, Int(p.fineSearchRadiusMs / 1000 * sampleRate))
        let n = RealFFT.nextPowerOfTwo(windowSamples + 2 * radius)
        fft = RealFFT(n: n)
        let half = n / 2
        let kLo = max(1, Int(p.phatBandLowHz / sampleRate * Double(n)))
        let kHi = min(half - 1, Int(p.phatBandHighHz / sampleRate * Double(n)))
        var mask = [Float](repeating: 0, count: half)
        if kHi >= kLo { for k in kLo...kHi { mask[k] = 1 } }
        self.mask = mask
        rho = Float(p.phatRho)
        epsilon = Float(p.phatEpsilon)
        exclusion = max(1, Int(p.phatSecondPeakExclusionMs / 1000 * sampleRate))
        cRe = [Float](repeating: 0, count: half)
        cIm = cRe
        dRe = cRe
        dIm = cRe
        gRe = cRe
        gIm = cRe
        r = [Float](repeating: 0, count: n)
        exponent = rho == 1 ? [] : [Float](repeating: rho, count: half)
    }

    /// Lag of the peak (samples into the reference excerpt, sub-sample), its value, and its ratio to the best
    /// value outside the exclusion zone.
    func measure(reference: [Float], target: [Float]) -> (lag: Double, peak: Float, ratio: Float) {
        precondition(reference.count == windowSamples + 2 * radius && target.count == windowSamples)
        fft.forward(reference, re: &cRe, im: &cIm)
        fft.forward(target, re: &dRe, im: &dIm)
        RealFFT.multiplyConjugate(aRe: cRe, aIm: cIm, bRe: dRe, bIm: dIm, re: &gRe, im: &gIm)
        var magnitude = vDSP.hypot(gRe, gIm)
        let eps = vDSP.maximum(magnitude) * epsilon + Float.leastNormalMagnitude
        if rho != 1 { magnitude = vForce.pow(bases: magnitude, exponents: exponent) }
        vDSP.add(eps, magnitude, result: &magnitude)
        var weight = vDSP.divide(1, magnitude)
        vDSP.multiply(weight, mask, result: &weight)
        vDSP.multiply(gRe, weight, result: &gRe)
        vDSP.multiply(gIm, weight, result: &gIm)
        fft.inverse(re: &gRe, im: &gIm, into: &r)

        let span = 2 * radius + 1
        var peakValue: Float = 0
        var peakIndex: vDSP_Length = 0
        vDSP_maxvi(r, 1, &peakValue, &peakIndex, vDSP_Length(span))
        let p = Int(peakIndex)
        var fraction = 0.0
        if p > 0 && p < span - 1 {
            let y0 = Double(r[p - 1]), y1 = Double(r[p]), y2 = Double(r[p + 1])
            let denominator = y0 - 2 * y1 + y2
            if denominator != 0 { fraction = 0.5 * (y0 - y2) / denominator }
        }
        var second: Float = 0
        for i in 0..<span where abs(i - p) > exclusion { second = max(second, r[i]) }
        return (Double(p) + fraction, peakValue, peakValue / max(second, Float.leastNormalMagnitude))
    }
}
