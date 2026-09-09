import Accelerate
import Foundation
import TimelineCore

/// An onset-strength envelope: one value per `AlignmentParameters.envelopeHop` samples at
/// `envelopeSampleRate`, detrended by a running median and zero-mean. This is the coarse pass's input and the
/// `onset-8k.f32` cache format MediaKit stores (little-endian Float32, no header).
public struct OnsetEnvelope: Sendable, Hashable {
    public var values: [Float]
    /// Envelope frames per second (`envelopeSampleRate / envelopeHop`, 62.5 with the defaults).
    public var frameRate: Double

    public init(values: [Float], frameRate: Double) {
        self.values = values
        self.frameRate = frameRate
    }

    public var frameCount: Int { values.count }
    public var frameDuration: Double { 1 / frameRate }
    public var duration: Double { Double(values.count) / frameRate }

    public static func frameRate(for parameters: AlignmentParameters) -> Double {
        Double(parameters.envelopeSampleRate) / Double(parameters.envelopeHop)
    }

    /// The raw little-endian Float32 form MediaKit caches.
    public var fileData: Data {
        var data = Data(capacity: values.count * 4)
        for v in values {
            var bits = v.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    public func write(to url: URL) throws {
        try fileData.write(to: url, options: .atomic)
    }

    /// Reads a cached envelope written by `write(to:)` (or MediaKit) for the given parameters.
    public static func read(from url: URL, parameters: AlignmentParameters) throws -> OnsetEnvelope {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count % 4 == 0 else { throw AudioAlignError.invalidEnvelopeFile(url) }
        var values = [Float](repeating: 0, count: data.count / 4)
        data.withUnsafeBytes { raw in
            for i in values.indices {
                values[i] = Float(
                    bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
        return OnsetEnvelope(values: values, frameRate: frameRate(for: parameters))
    }
}

/// Computes an `OnsetEnvelope` incrementally from chunks of mono audio at any sample rate, so a two-hour
/// recording never has to be resident: only the FIR carry, the resampler history, one STFT window of pending
/// samples, and the (small) envelope itself are held between calls. MediaKit uses the same builder to produce
/// its cache file and `OnsetAligner` uses it for `AudioSource.file`.
///
/// Front end: FIR lowpass + integer decimation by `floor(inputSampleRate / envelopeSampleRate)`, a Hermite
/// stage to the exact envelope rate when that ratio is not an integer, RBJ Butterworth bandpass, then the
/// spike's STFT / log-band / rectified-difference onset function. `finish()` applies the running-median detrend
/// and removes the mean.
///
/// Not `Sendable`; use one builder per stream from a single task.
public struct OnsetEnvelopeBuilder {
    public let inputSampleRate: Double
    public let parameters: AlignmentParameters

    private var decimator: StreamingDecimator?
    private var resampler: StreamingHermiteResampler?
    private var bandpass: StreamingBiquad
    private var pending: [Float] = []
    private let fft: RealFFT
    private let window: [Float]
    private let bandEdges: [Int]
    private var previousLog: [Float]
    private var currentLog: [Float]
    private var hasPreviousFrame = false
    private var onset: [Float] = []
    private var frame: [Float]
    private var re: [Float]
    private var im: [Float]
    private var power: [Float]
    private var finished = false

    public init(inputSampleRate: Double, parameters: AlignmentParameters) throws {
        try Self.validate(parameters)
        guard inputSampleRate > 0 else {
            throw AudioAlignError.invalidParameters("input sample rate must be positive, got \(inputSampleRate)")
        }
        self.inputSampleRate = inputSampleRate
        self.parameters = parameters

        let envelopeRate = Double(parameters.envelopeSampleRate)
        let factor = max(1, Int(inputSampleRate / envelopeRate))
        if factor > 1 {
            let cutoffHz = AlignerDefaults.decimationCutoffFraction * envelopeRate / 2
            decimator = StreamingDecimator(
                factor: factor,
                filter: lowpassFIR(taps: AlignerDefaults.decimationFilterTaps, cutoff: cutoffHz / inputSampleRate))
        }
        let intermediateRate = inputSampleRate / Double(factor)
        let ratio = intermediateRate / envelopeRate
        if abs(ratio - 1) > 1e-9 { resampler = StreamingHermiteResampler(ratio: ratio) }

        bandpass = StreamingBiquad(sections: [
            BiquadDesign.highpass(sampleRate: envelopeRate, cutoff: parameters.bandpassLowHz),
            BiquadDesign.lowpass(sampleRate: envelopeRate, cutoff: parameters.bandpassHighHz),
        ])

        let nfft = parameters.envelopeWindow
        fft = RealFFT(n: nfft)
        var window = [Float](repeating: 0, count: nfft)
        vDSP_hann_window(&window, vDSP_Length(nfft), Int32(vDSP_HANN_NORM))
        self.window = window
        bandEdges = Self.bandEdges(parameters: parameters)
        previousLog = [Float](repeating: 0, count: parameters.envelopeBands)
        currentLog = previousLog
        frame = [Float](repeating: 0, count: nfft)
        re = [Float](repeating: 0, count: nfft / 2)
        im = re
        power = re
    }

    static func validate(_ p: AlignmentParameters) throws {
        guard p.envelopeSampleRate > 0 else { throw AudioAlignError.invalidParameters("envelopeSampleRate") }
        guard p.envelopeWindow >= 4, p.envelopeWindow & (p.envelopeWindow - 1) == 0 else {
            throw AudioAlignError.invalidParameters("envelopeWindow must be a power of two >= 4")
        }
        guard p.envelopeHop > 0, p.envelopeHop <= p.envelopeWindow else {
            throw AudioAlignError.invalidParameters("envelopeHop must be in 1...envelopeWindow")
        }
        guard p.envelopeBands > 0 else { throw AudioAlignError.invalidParameters("envelopeBands") }
        guard p.bandpassLowHz > 0, p.bandpassHighHz > p.bandpassLowHz,
            p.bandpassHighHz < Double(p.envelopeSampleRate) / 2
        else {
            throw AudioAlignError.invalidParameters("bandpass must satisfy 0 < low < high < envelopeSampleRate / 2")
        }
        guard p.envelopeMedianSeconds > 0 else { throw AudioAlignError.invalidParameters("envelopeMedianSeconds") }
    }

    /// Log-spaced band edges in bins between the bandpass edges, forced strictly increasing and inside the
    /// spectrum.
    static func bandEdges(parameters p: AlignmentParameters) -> [Int] {
        let binHz = Double(p.envelopeSampleRate) / Double(p.envelopeWindow)
        let half = p.envelopeWindow / 2
        var edges = (0...p.envelopeBands).map {
            Int(
                (p.bandpassLowHz * pow(p.bandpassHighHz / p.bandpassLowHz, Double($0) / Double(p.envelopeBands)) / binHz)
                    .rounded())
        }
        edges[0] = max(1, min(edges[0], half - p.envelopeBands - 1))
        for b in 1...p.envelopeBands { edges[b] = min(max(edges[b], edges[b - 1] + 1), half) }
        return edges
    }

    /// Envelope frames emitted so far.
    public var frameCount: Int { onset.count }

    /// Samples currently held between calls (FIR carry, resampler history, pending STFT samples); bounded by
    /// the chunk size plus a few filter lengths, whatever the recording length.
    public var residentSampleCount: Int {
        (decimator?.residentSampleCount ?? 0) + (resampler?.residentSampleCount ?? 0) + pending.count
    }

    public mutating func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    public mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        precondition(!finished, "OnsetEnvelopeBuilder used after finish()")
        guard !samples.isEmpty else { return }
        var x: [Float]
        if decimator != nil {
            x = decimator!.process(samples)
        } else {
            x = Array(samples)
        }
        if resampler != nil { x = resampler!.process(x) }
        x = bandpass.process(x)
        guard !x.isEmpty else { return }
        pending.append(contentsOf: x)
        processFrames()
    }

    private mutating func processFrames() {
        let nfft = parameters.envelopeWindow
        let hop = parameters.envelopeHop
        let bands = parameters.envelopeBands
        var start = 0
        while start + nfft <= pending.count {
            pending.withUnsafeBufferPointer { p in
                vDSP_vmul(p.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(nfft))
            }
            fft.forward(frame, re: &re, im: &im)
            fft.power(re: &re, im: &im, into: &power)
            power.withUnsafeBufferPointer { pw in
                for b in 0..<bands {
                    var s: Float = 0
                    let lo = bandEdges[b], hi = bandEdges[b + 1]
                    if hi > lo { vDSP_sve(pw.baseAddress! + lo, 1, &s, vDSP_Length(hi - lo)) }
                    currentLog[b] = log(s + AlignerDefaults.logPowerFloor)
                }
            }
            if hasPreviousFrame {
                var acc: Float = 0
                for b in 0..<bands { acc += max(0, currentLog[b] - previousLog[b]) }
                onset.append(acc / Float(bands))
            } else {
                onset.append(0)
                hasPreviousFrame = true
            }
            swap(&previousLog, &currentLog)
            start += hop
        }
        if start > 0 { pending.removeFirst(start) }
    }

    /// Detrends by a running median and removes the mean. The builder must not be used afterwards.
    public mutating func finish() -> OnsetEnvelope {
        precondition(!finished, "OnsetEnvelopeBuilder finished twice")
        finished = true
        let frameRate = OnsetEnvelope.frameRate(for: parameters)
        guard !onset.isEmpty else { return OnsetEnvelope(values: [], frameRate: frameRate) }
        var medianFrames = Int((parameters.envelopeMedianSeconds * frameRate).rounded())
        if medianFrames % 2 == 0 { medianFrames += 1 }
        var out = Self.subtractRunningMedian(onset, windowFrames: max(1, medianFrames))
        out = vDSP.add(-vDSP.mean(out), out)
        return OnsetEnvelope(values: out, frameRate: frameRate)
    }

    /// `x[f] - median(x[f - h ... f + h])` with the window clipped at the ends, via a sorted sliding window.
    static func subtractRunningMedian(_ x: [Float], windowFrames: Int) -> [Float] {
        let n = x.count
        let h = windowFrames / 2
        var sorted: [Float] = []
        sorted.reserveCapacity(windowFrames)
        func insert(_ v: Float) {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid] < v { lo = mid + 1 } else { hi = mid }
            }
            sorted.insert(v, at: lo)
        }
        func remove(_ v: Float) {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid] < v { lo = mid + 1 } else { hi = mid }
            }
            sorted.remove(at: lo)
        }
        for i in 0..<min(n, h + 1) { insert(x[i]) }
        var out = [Float](repeating: 0, count: n)
        for f in 0..<n {
            if f > 0 {
                if f + h < n { insert(x[f + h]) }
                if f - h - 1 >= 0 { remove(x[f - h - 1]) }
            }
            out[f] = x[f] - sorted[sorted.count / 2]
        }
        return out
    }
}
