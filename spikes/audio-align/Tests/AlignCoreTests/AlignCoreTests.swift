import Testing
import Foundation
@testable import AlignCore

@Test func fftScaleRoundTrip() {
    // forward->inverse of vDSP_fft_zrip is scaled by 2n
    let n = 1024, x = (0..<n).map { _ in Float.random(in: -1...1) }
    let fft = RealFFT(n: n), s = fft.forward(x), y = fft.inverse(re: s.re, im: s.im)
    for i in stride(from: 0, to: n, by: 97) { #expect(abs(y[i] / Float(2 * n) - x[i]) < 1e-4) }
}

@Test func coarseSelfCorrelationIsOne() {
    var rng = SplitMix64(seed: 3)
    let b = (0..<4000).map { _ in Float(rng.uniform()) - 0.5 }
    var a = (0..<50000).map { _ in Float(rng.uniform()) * 1e-3 }; for i in 0..<b.count { a[12345 + i] += b[i] }
    let r = coarseAlign(cam: a, daw: b)
    #expect(r.lagFrames == 12345)
    #expect(abs(r.ncc - 1) < 1e-2)
    #expect(r.ratio > 5)
}

@Test func theilSenRecoversLine() {
    let x = (0..<20).map { Double($0) * 10 }
    var y = x.map { 100 - 1.104 * $0 }
    y[7] += 500  // outlier
    let fit = theilSen(x: x, y: y, inlierTol: 1)
    #expect(abs(fit.slope + 1.104) < 1e-9); #expect(abs(fit.intercept - 100) < 1e-9); #expect(fit.inliers == 19)
}
