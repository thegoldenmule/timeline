import Foundation
import Testing
import TimelineCore

@testable import AudioAlign

/// Deterministic RNG for test signals.
struct TestRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Float { Float(Double(next() >> 11) / Double(1 << 53)) }
    mutating func signal(_ count: Int) -> [Float] { (0..<count).map { _ in uniform() * 2 - 1 } }
    /// Chunk sizes that vary between 1 and `maxChunk`, covering `total` samples.
    mutating func chunks(total: Int, maxChunk: Int) -> [Int] {
        var sizes: [Int] = []
        var left = total
        while left > 0 {
            let s = min(left, 1 + Int(next() % UInt64(maxChunk)))
            sizes.append(s)
            left -= s
        }
        return sizes
    }
}

func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "count \(a.count) vs \(b.count)")
    return zip(a, b).map { abs($0 - $1) }.max() ?? 0
}

@Suite struct RealFFTTests {
    @Test func forwardInverseRoundTripIsScaledBy2N() {
        var rng = TestRNG(seed: 1)
        let n = 1024
        let x = rng.signal(n)
        let fft = RealFFT(n: n)
        var re = [Float](repeating: 0, count: n / 2), im = re, y = [Float](repeating: 0, count: n)
        fft.forward(x, re: &re, im: &im)
        fft.inverse(re: &re, im: &im, into: &y)
        for i in 0..<n { #expect(abs(y[i] / Float(2 * n) - x[i]) < 1e-4) }
    }

    @Test func oddLengthInputIsZeroPadded() {
        let n = 64
        let x: [Float] = (0..<33).map { Float($0) }
        let fft = RealFFT(n: n)
        var re = [Float](repeating: 0, count: n / 2), im = re, y = [Float](repeating: 0, count: n)
        fft.forward(x, re: &re, im: &im)
        fft.inverse(re: &re, im: &im, into: &y)
        for i in 0..<n { #expect(abs(y[i] / Float(2 * n) - (i < 33 ? x[i] : 0)) < 1e-3) }
    }

    @Test func correlationOfShiftedImpulsePeaksAtTheShift() {
        // Inverse of a * conj(b) is scaled by 4n; the peak of an impulse pair lands at the shift.
        let n = 256
        var a = [Float](repeating: 0, count: n), b = a
        a[40] = 1
        b[10] = 1
        let fft = RealFFT(n: n)
        var aRe = [Float](repeating: 0, count: n / 2), aIm = aRe, bRe = aRe, bIm = aRe, re = aRe, im = aRe
        fft.forward(a, re: &aRe, im: &aIm)
        fft.forward(b, re: &bRe, im: &bIm)
        RealFFT.multiplyConjugate(aRe: aRe, aIm: aIm, bRe: bRe, bIm: bIm, re: &re, im: &im)
        var r = [Float](repeating: 0, count: n)
        fft.inverse(re: &re, im: &im, into: &r)
        let peak = r.indices.max { r[$0] < r[$1] }!
        #expect(peak == 30)
        #expect(abs(r[30] / Float(4 * n) - 1) < 1e-4)
    }
}

@Suite struct StreamingFilterTests {
    @Test func decimatorChunkedMatchesWhole() {
        var rng = TestRNG(seed: 2)
        let x = rng.signal(50_000)
        let filter = lowpassFIR(taps: 127, cutoff: 0.075)
        var whole = StreamingDecimator(factor: 6, filter: filter)
        let expected = x.withUnsafeBufferPointer { whole.process($0) }
        var chunked = StreamingDecimator(factor: 6, filter: filter)
        var actual: [Float] = []
        var start = 0
        for size in rng.chunks(total: x.count, maxChunk: 3000) {
            x.withUnsafeBufferPointer {
                actual += chunked.process(UnsafeBufferPointer(rebasing: $0[start..<(start + size)]))
            }
            start += size
            #expect(chunked.residentSampleCount < filter.count + 6)
        }
        #expect(actual.count == expected.count)
        #expect(maxAbsDifference(actual, expected) < 1e-6)
    }

    @Test func biquadChunkedMatchesWhole() {
        var rng = TestRNG(seed: 3)
        let x = rng.signal(20_000)
        let sections = [
            BiquadDesign.highpass(sampleRate: 8000, cutoff: 300), BiquadDesign.lowpass(sampleRate: 8000, cutoff: 3000),
        ]
        var whole = StreamingBiquad(sections: sections)
        let expected = whole.process(x)
        var chunked = StreamingBiquad(sections: sections)
        var actual: [Float] = []
        var start = 0
        for size in rng.chunks(total: x.count, maxChunk: 700) {
            actual += chunked.process(Array(x[start..<(start + size)]))
            start += size
        }
        #expect(maxAbsDifference(actual, expected) < 1e-4)
    }

    @Test func hermiteChunkedMatchesWhole() {
        var rng = TestRNG(seed: 4)
        let x = rng.signal(30_000)
        let ratio = 1.1025
        var whole = StreamingHermiteResampler(ratio: ratio)
        let expected = whole.process(x)
        var chunked = StreamingHermiteResampler(ratio: ratio)
        var actual: [Float] = []
        var start = 0
        for size in rng.chunks(total: x.count, maxChunk: 900) {
            actual += chunked.process(Array(x[start..<(start + size)]))
            start += size
            #expect(chunked.residentSampleCount < 905)
        }
        #expect(actual.count == expected.count)
        #expect(maxAbsDifference(actual, expected) < 1e-6)
        // Output j sits at input position j * ratio (zero delay): check on a slow sine.
        let sine = (0..<4000).map { Float(sin(Double($0) * 0.01)) }
        var r = StreamingHermiteResampler(ratio: 0.7)
        let y = r.process(sine)
        for j in stride(from: 10, to: y.count, by: 97) {
            #expect(abs(y[j] - Float(sin(Double(j) * 0.7 * 0.01))) < 1e-4)
        }
    }

    @Test func hermiteResampleAtUnityRatioIsIdentity() {
        var rng = TestRNG(seed: 5)
        let x = rng.signal(500)
        let y = hermiteResample(x, start: 0, ratio: 1, count: 500)
        #expect(maxAbsDifference(x, y) < 1e-7)
        // Positions outside the input read as zero rather than trapping.
        let z = hermiteResample(x, start: -10, ratio: 1, count: 530)
        #expect(z[0] == 0 && z[529] == 0)
        #expect(abs(z[10] - x[0]) < 1e-7)
    }

    @Test func lowpassFIRHasUnityDCGain() {
        let h = lowpassFIR(taps: 127, cutoff: 0.075)
        #expect(abs(h.reduce(0, +) - 1) < 1e-5)
        #expect(h[63] == h.max())
    }
}

@Suite struct RobustFitTests {
    @Test func theilSenRecoversLineThroughAnOutlier() {
        let x = (0..<20).map { Double($0) * 10 }
        var y = x.map { 100 - 1.104 * $0 }
        y[7] += 500
        let fit = theilSen(x: x, y: y, inlierTolerance: 1)
        #expect(abs(fit.slope + 1.104) < 1e-9)
        #expect(abs(fit.intercept - 100) < 1e-9)
        #expect(fit.inlierCount == 19)
        #expect(fit.inliers[7] == false)
        #expect(fit.mad < 1e-9)
    }

    @Test func theilSenWithSlopeHeldAtZeroUsesTheMedianOffset() {
        let fit = theilSen(x: [0, 1], y: [10, 20], inlierTolerance: 1, fitSlope: false)
        #expect(fit.slope == 0)
        #expect(fit.intercept == 15)
    }

    @Test func runningMedianMatchesNaive() {
        var rng = TestRNG(seed: 6)
        let x = rng.signal(400)
        let w = 63
        let fast = OnsetEnvelopeBuilder.subtractRunningMedian(x, windowFrames: w)
        let h = w / 2
        for f in 0..<x.count {
            let window = x[max(0, f - h)..<min(x.count, f + h + 1)].sorted()
            #expect(fast[f] == x[f] - window[window.count / 2])
        }
    }
}

@Suite struct OnsetEnvelopeTests {
    @Test func builderChunkedMatchesWholeAndStaysBounded() throws {
        var rng = TestRNG(seed: 7)
        let x = rng.signal(48_000 * 4)
        let p = AlignmentParameters()
        var whole = try OnsetEnvelopeBuilder(inputSampleRate: 48_000, parameters: p)
        whole.append(x)
        let expected = whole.finish()
        var chunked = try OnsetEnvelopeBuilder(inputSampleRate: 48_000, parameters: p)
        var start = 0
        let maxChunk = 5000
        for size in rng.chunks(total: x.count, maxChunk: maxChunk) {
            chunked.append(Array(x[start..<(start + size)]))
            start += size
            #expect(chunked.residentSampleCount <= maxChunk + AlignerDefaults.decimationFilterTaps + p.envelopeWindow)
        }
        let actual = chunked.finish()
        #expect(actual.frameCount == expected.frameCount)
        let decimated = (x.count - AlignerDefaults.decimationFilterTaps) / 6 + 1
        #expect(expected.frameCount == (decimated - p.envelopeWindow) / p.envelopeHop + 1)
        #expect(maxAbsDifference(actual.values, expected.values) < 1e-4)
        #expect(abs(actual.values.reduce(0, +)) < 1e-2)
        #expect(actual.frameRate == 62.5)
    }

    @Test func builderHandlesNonIntegerDecimation() throws {
        var rng = TestRNG(seed: 8)
        let x = rng.signal(44_100 * 2)
        var builder = try OnsetEnvelopeBuilder(inputSampleRate: 44_100, parameters: AlignmentParameters())
        builder.append(x)
        let envelope = builder.finish()
        // 2 s at 62.5 frames per second, less the STFT window and filter delays.
        #expect(envelope.frameCount > 120 && envelope.frameCount <= 125)
    }

    @Test func envelopeFileRoundTrips() throws {
        let envelope = OnsetEnvelope(values: [0.5, -1.25, 3e-5, 0], frameRate: 62.5)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("onset-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: url) }
        try envelope.write(to: url)
        #expect(try Data(contentsOf: url).count == 16)
        let back = try OnsetEnvelope.read(from: url, parameters: AlignmentParameters())
        #expect(back == envelope)
        try Data([1, 2, 3]).write(to: url)
        #expect(throws: AudioAlignError.invalidEnvelopeFile(url)) {
            try OnsetEnvelope.read(from: url, parameters: AlignmentParameters())
        }
    }

    @Test func parametersAreValidated() {
        var p = AlignmentParameters()
        p.envelopeWindow = 500
        #expect(throws: AudioAlignError.self) { try OnsetEnvelopeBuilder(inputSampleRate: 48_000, parameters: p) }
        p = AlignmentParameters()
        p.bandpassHighHz = 5000
        #expect(throws: AudioAlignError.self) { try OnsetEnvelopeBuilder(inputSampleRate: 48_000, parameters: p) }
    }
}

@Suite struct CoarsePassTests {
    @Test func selfCorrelationIsOneAtTheInsertedLag() {
        var rng = TestRNG(seed: 9)
        let b = (0..<4000).map { _ in rng.uniform() - 0.5 }
        var a = (0..<50_000).map { _ in rng.uniform() * 1e-3 }
        for i in 0..<b.count { a[12_345 + i] += b[i] }
        let result = CoarsePass.correlate(reference: a, target: b, frameRate: 62.5, parameters: AlignmentParameters())
        #expect(result.candidates.first?.lagFrames == 12_345)
        #expect(abs((result.candidates.first?.ncc ?? 0) - 1) < 1e-2)
        #expect(result.peak / max(result.second, 1e-6) > 5)
        #expect(result.candidates.count == 1)
        #expect(result.ncc.count == result.candidates.count.magnitude + 50_000 + 4000 - 2 * 2000 + 1 - 1)
    }

    @Test func repeatedMaterialYieldsTwoCandidates() {
        var rng = TestRNG(seed: 10)
        let b = (0..<3000).map { _ in rng.uniform() - 0.5 }
        var a = (0..<40_000).map { _ in rng.uniform() * 1e-3 }
        for i in 0..<b.count {
            a[5000 + i] += b[i]
            a[25_000 + i] += b[i]
        }
        let result = CoarsePass.correlate(reference: a, target: b, frameRate: 62.5, parameters: AlignmentParameters())
        #expect(result.candidates.count == 2)
        #expect(Set(result.candidates.map(\.lagFrames)) == [5000, 25_000])
    }

    @Test func silentStretchesDoNotInflateTheScore() {
        var rng = TestRNG(seed: 11)
        let b = (0..<2000).map { _ in rng.uniform() - 0.5 }
        var a = [Float](repeating: 0, count: 30_000)
        for i in 0..<b.count { a[20_000 + i] += b[i] }
        for i in 0..<10_000 { a[i] = (rng.uniform() - 0.5) * 1e-4 }
        let result = CoarsePass.correlate(reference: a, target: b, frameRate: 62.5, parameters: AlignmentParameters())
        #expect(result.candidates.first?.lagFrames == 20_000)
        #expect(result.ncc.allSatisfy { $0 <= 1.01 })
    }

    @Test func pooledCorrelationKeepsPeaks() {
        var ncc = [Float](repeating: 0.1, count: 10_000)
        ncc[7777] = 0.9
        let (pooled, bucket) = CoarsePass.pooled(ncc, points: 100)
        #expect(bucket == 100)
        #expect(pooled.count == 100)
        #expect(pooled[77] == 0.9)
    }
}

@Suite struct AlignerHelperTests {
    @Test func parametersHashIsStableAndSensitive() {
        let a = OnsetAligner.parametersHash(AlignmentParameters())
        #expect(a == OnsetAligner.parametersHash(AlignmentParameters()))
        #expect(a.count == 64)
        var p = AlignmentParameters()
        p.fineWindowCount += 1
        #expect(OnsetAligner.parametersHash(p) != a)
    }

    @Test func offsetTimeKeepsSubSampleResolution() {
        let t = OnsetAligner.offsetTime(samples: 123_456.789, sampleRate: 48_000)
        #expect(t.timescale == 48_000_000)
        #expect(t.value == 123_456_789)
        #expect(abs(t.seconds - 123_456.789 / 48_000) < 1e-12)
        #expect(OnsetAligner.offsetTime(samples: 10, sampleRate: 48_000).rescaled(to: 48_000)?.value == 10)
    }

    @Test func windowStartsSpreadOverTheTarget() {
        #expect(OnsetAligner.windowStarts(targetFrames: 100, windowSamples: 10, count: 3) == [0, 45, 90])
        #expect(OnsetAligner.windowStarts(targetFrames: 25, windowSamples: 10, count: 24) == [0, 15])
        #expect(OnsetAligner.windowStarts(targetFrames: 10, windowSamples: 10, count: 24) == [0])
        #expect(OnsetAligner.windowStarts(targetFrames: 5, windowSamples: 10, count: 24) == [])
    }

    @Test func bufferSourceReadsAreZeroPadded() throws {
        let source = BufferAudioSource(samples: [1, 2, 3, 4], sampleRate: 48_000)
        #expect(try source.read(frames: -2..<6) == [0, 0, 1, 2, 3, 4, 0, 0])
        #expect(try source.read(frames: 10..<12) == [0, 0])
        var chunks: [[Float]] = []
        try source.forEachChunk(chunkFrames: 3) { chunks.append(Array($0)) }
        #expect(chunks == [[1, 2, 3], [4]])
    }
}
