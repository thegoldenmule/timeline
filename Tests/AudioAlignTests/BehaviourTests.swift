import AVFoundation
import Contracts
import ContractsTestSupport
import Foundation
import Synchronization
import Testing
import TimelineCore

@testable import AudioAlign

/// Pink noise (Paul Kellet filter) at unit RMS, as in the spike's camera synthesis.
func pinkNoise(count: Int, seed: UInt64) -> [Float] {
    var rng = TestRNG(seed: seed)
    var out = [Float](repeating: 0, count: count)
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    var sumSquares = 0.0
    out.withUnsafeMutableBufferPointer { o in
        for i in 0..<count {
            let w = rng.uniform() * 2 - 1
            b0 = 0.99886 * b0 + w * 0.0555179
            b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522
            b5 = -0.7616 * b5 - w * 0.0168980
            let v = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
            b6 = w * 0.115926
            o[i] = v
            sumSquares += Double(v * v)
        }
        let g = Float(1 / (sumSquares / Double(count)).squareRoot())
        for i in 0..<count { o[i] *= g }
    }
    return out
}

func rms(_ x: ArraySlice<Float>) -> Float {
    var acc = 0.0
    for v in x { acc += Double(v) * Double(v) }
    return Float((acc / Double(max(1, x.count))).squareRoot())
}

@Suite struct VerdictTests {
    /// The same render twice inside one camera track: two verified candidates and `ambiguous`, never a single
    /// confident answer.
    @Test func repeatedMaterialIsAmbiguous() async throws {
        let dir = try TestMedia.Directory()
        let cameraDuration = 400.0, renderDuration = 90.0
        let first = 40.0, second = 250.0
        // Two pairs from the same seed share the noise, so splicing the second's performance region into the
        // first camera track is exactly "the performance inserted twice" with no seam.
        let a = try await TestMedia.alignmentPair(
            seed: 21, cameraDuration: cameraDuration, renderDuration: renderDuration, offsetSeconds: first,
            driftPPM: 23, snrDB: 5, in: dir.url)
        let b = try await TestMedia.alignmentPair(
            seed: 21, cameraDuration: cameraDuration, renderDuration: renderDuration, offsetSeconds: second,
            driftPPM: 23, snrDB: 5, in: dir.url)
        var camera = try await TestMedia.readAudio(url: a.camera.url).channel(0)
        let other = try await TestMedia.readAudio(url: b.camera.url).channel(0)
        let lo = Int(second * 48_000), hi = Int((second + renderDuration + 0.2) * 48_000)
        camera.replaceSubrange(lo..<hi, with: other[lo..<hi])
        let url = dir.file("twice.caf")
        try writeCAF(camera, sampleRate: 48_000, to: url)

        let alignment = try await OnsetAligner().align(
            reference: .file(url, contentHash: nil), target: .file(a.render.url, contentHash: nil),
            parameters: AlignmentParameters())
        let verified = alignment.candidates.filter(\.verified)
        print(
            "[AudioAlign] repeated: status \(alignment.status) verified offsets "
                + "\(verified.map { String(format: "%.4f", $0.offset.seconds) }) drifts "
                + "\(verified.map { String(format: "%.2f", $0.driftPPM) }) elapsed \(alignment.elapsedSeconds)")
        #expect(alignment.status == .ambiguous)
        #expect(verified.count == 2)
        let offsets = verified.map(\.offset.seconds).sorted()
        #expect(offsets.count == 2)
        if offsets.count == 2 {
            #expect(abs(offsets[0] - first) * 1000 < 0.1)
            #expect(abs(offsets[1] - second) * 1000 < 0.1)
        }
        for c in verified { #expect(abs(c.driftPPM - 23) < 1) }
        // The reported offset is the best verified candidate's, and candidates come best first.
        #expect(alignment.offset == alignment.candidates.first?.offset)
        #expect(alignment.candidates.first?.verified == true)
    }

    /// At -15 dB the coarse pass finds noise peaks; the fine pass must reject them all rather than verify a
    /// wrong lag. (With this camera length the true lag is occasionally still recoverable, which is allowed: the
    /// invariant is "never wrong", so an `aligned` result must be correct.)
    @Test func minusFifteenDecibelsFailsRatherThanLies() async throws {
        let dir = try TestMedia.Directory()
        let r = try await alignPair(
            seed: 4, cameraDuration: 600, renderDuration: 150, offsetSeconds: 200.5, driftPPM: 23, snrDB: -15,
            in: dir)
        describe("SNR -15 dB", r)
        #expect(r.alignment.status != .ambiguous)
        if r.alignment.status == .failed {
            #expect(r.alignment.offset == nil)
            #expect(r.alignment.confidence == 0)
            #expect(r.alignment.candidates.allSatisfy { !$0.verified })
        } else {
            #expect(abs(r.offsetErrorMs) < 0.1, "an aligned result must be correct: \(r.offsetErrorMs) ms")
        }
    }

    /// A target that shares nothing with the reference fails cleanly.
    @Test func unrelatedMaterialFails() async throws {
        let dir = try TestMedia.Directory()
        let a = try await TestMedia.alignmentPair(
            seed: 31, cameraDuration: 120, renderDuration: 30, offsetSeconds: 40, driftPPM: 0, snrDB: 10, in: dir.url)
        let b = try await TestMedia.alignmentPair(
            seed: 32, cameraDuration: 120, renderDuration: 30, offsetSeconds: 40, driftPPM: 0, snrDB: 10, in: dir.url)
        let alignment = try await OnsetAligner().align(
            reference: .file(a.camera.url, contentHash: nil), target: .file(b.render.url, contentHash: nil),
            parameters: AlignmentParameters())
        print("[AudioAlign] unrelated: status \(alignment.status) candidates \(alignment.candidates.count)")
        #expect(alignment.status == .failed)
        #expect(alignment.offset == nil)
    }
}

@Suite(.serialized) struct TransientTests {
    /// Two click tracks with a known click-time difference: the recovered offset is that difference, to the
    /// sample, on material with essentially no sustained energy.
    @Test func clickTracksAlignToTheClickTimeDifference() async throws {
        let dir = try TestMedia.Directory()
        let referenceClicks = [3.0, 3.7, 4.9, 5.2, 6.8, 7.1, 8.4, 9.9, 10.3, 11.6, 12.2, 13.9]
        let shift = 2.5
        let targetClicks = referenceClicks.map { $0 - shift }.filter { $0 > 0.05 && $0 < 9.9 }
        let reference = try await TestMedia.transients(clickTimes: referenceClicks, duration: 16, in: dir.url)
        let target = try await TestMedia.transients(clickTimes: targetClicks, duration: 10, in: dir.url)
        let expectedSamples = reference.description.clickSamples[0] - target.description.clickSamples[0]
        #expect(expectedSamples == Int(shift * 48_000))

        var p = AlignmentParameters()
        p.fineWindowSeconds = 2.5
        p.fineWindowCount = 4
        p.minimumOverlapSeconds = 5
        let alignment = try await OnsetAligner().align(
            reference: .file(reference.url, contentHash: nil), target: .file(target.url, contentHash: nil),
            parameters: p)
        let offsetSamples = (alignment.offset?.seconds ?? .nan) * 48_000
        print(
            "[AudioAlign] transients: status \(alignment.status) offset \(offsetSamples) samples "
                + "(expected \(expectedSamples)) drift \(alignment.driftPPM) confidence \(alignment.confidence)")
        #expect(alignment.status == .aligned)
        #expect(abs(offsetSamples - Double(expectedSamples)) < 1)
        #expect(alignment.driftPPM == 0)
    }
}

@Suite(.serialized) struct PlumbingTests {
    /// `AudioSource.envelope` (MediaKit's cache) and `AudioSource.file` give the same answer, and the cache file
    /// is what `onsetEnvelope(url:parameters:)` writes.
    @Test func cachedEnvelopeMatchesStreamedFile() async throws {
        let dir = try TestMedia.Directory()
        let pair = try await TestMedia.alignmentPair(
            seed: 41, cameraDuration: 90, renderDuration: 30, offsetSeconds: 33.3, driftPPM: 23, snrDB: 0,
            in: dir.url)
        let aligner = OnsetAligner()
        let p = AlignmentParameters()
        let envelope = try await aligner.onsetEnvelope(url: pair.camera.url, parameters: p)
        #expect(abs(envelope.duration - 90) < 1)
        // A second decode of the same file sees the same fixed-size chunks, so the cache is reproducible.
        let values = try await aligner.onsetEnvelopeValues(url: pair.camera.url, parameters: p)
        #expect(values.count == envelope.values.count)
        #expect(maxAbsDifference(values, envelope.values) < 1e-4)
        let cache = dir.file("onset-8k.f32")
        try envelope.write(to: cache)
        #expect(try OnsetEnvelope.read(from: cache, parameters: p) == envelope)

        let fromFile = try await aligner.align(
            reference: .file(pair.camera.url, contentHash: "h1"), target: .file(pair.render.url, contentHash: "h2"),
            parameters: p)
        let fromCache = try await aligner.align(
            reference: .envelope(cache, audioURL: pair.camera.url, contentHash: "h1"),
            target: .file(pair.render.url, contentHash: "h2"), parameters: p)
        #expect(fromFile.status == .aligned && fromCache.status == .aligned)
        #expect(abs((fromFile.offset?.seconds ?? 0) - (fromCache.offset?.seconds ?? 1)) * 1000 < 1e-3)
        #expect(abs(fromFile.driftPPM - fromCache.driftPPM) < 0.01)
        #expect(fromFile.candidates.count == fromCache.candidates.count)
        #expect(fromCache.referenceHash == "h1" && fromCache.targetHash == "h2")
        #expect(abs((fromFile.offset?.seconds ?? 0) - 33.3) * 1000 < 0.1)

        // The in-memory entry point agrees with the file path too.
        let camera = try await TestMedia.readAudio(url: pair.camera.url)
        let render = try await TestMedia.readAudio(url: pair.render.url)
        let fromBuffers = try await aligner.align(
            reference: BufferAudioSource(samples: camera.channel(0), sampleRate: camera.sampleRate),
            target: BufferAudioSource(samples: render.channel(0), sampleRate: render.sampleRate), parameters: p)
        #expect(fromBuffers.status == .aligned)
        #expect(abs((fromBuffers.offset?.seconds ?? 0) - (fromFile.offset?.seconds ?? 1)) * 1000 < 0.01)
    }

    @Test func progressIsMonotonicAndReachesOne() async throws {
        let dir = try TestMedia.Directory()
        let pair = try await TestMedia.alignmentPair(
            seed: 42, cameraDuration: 60, renderDuration: 20, offsetSeconds: 10, driftPPM: 0, snrDB: 5, in: dir.url)
        let reported = Mutex<[Double]>([])
        let aligner = OnsetAligner { value in reported.withLock { $0.append(value) } }
        let alignment = try await aligner.align(
            reference: .file(pair.camera.url, contentHash: nil), target: .file(pair.render.url, contentHash: nil),
            parameters: AlignmentParameters())
        #expect(alignment.status == .aligned)
        let values = reported.withLock { $0 }
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(values.count > 5)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func cancellationStopsTheAlignment() async throws {
        let dir = try TestMedia.Directory()
        let pair = try await TestMedia.alignmentPair(
            seed: 43, cameraDuration: 120, renderDuration: 30, offsetSeconds: 10, driftPPM: 0, snrDB: 5, in: dir.url)
        let started = Mutex<Bool>(false)
        let aligner = OnsetAligner { _ in started.withLock { $0 = true } }
        let task = Task {
            try await aligner.align(
                reference: .file(pair.camera.url, contentHash: nil), target: .file(pair.render.url, contentHash: nil),
                parameters: AlignmentParameters())
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        let t0 = now()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(seconds(since: t0) < 2)
    }

    @Test func missingAudioTrackIsReported() async throws {
        let dir = try TestMedia.Directory()
        let url = dir.file("empty.f32")
        try Data([0, 0, 0, 0]).write(to: url)
        await #expect(throws: AudioAlignError.self) {
            try await OnsetAligner().align(
                reference: .file(url, contentHash: nil), target: .file(url, contentHash: nil),
                parameters: AlignmentParameters())
        }
    }

    @Test func invalidParametersAreRejectedBeforeDecoding() async throws {
        var p = AlignmentParameters()
        p.fineWindowCount = 0
        let source = BufferAudioSource(samples: [Float](repeating: 0, count: 48_000), sampleRate: 48_000)
        await #expect(throws: AudioAlignError.invalidParameters("fineWindowCount")) {
            try await OnsetAligner().align(reference: source, target: source, parameters: p)
        }
    }
}

/// The scale tests: real two-hour fixtures, minutes of synthesis, a wall-clock budget. Off by default because
/// they set the whole target's wall clock on their own; run them with `AUDIOALIGN_BENCH=1 make bench`.
@Suite(.serialized) struct LongRecordingTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["AUDIOALIGN_BENCH"] != nil }

    /// A two-hour camera track against a five-minute render: streamed through the chunked envelope path with
    /// bounded resident audio, aligned in well under the budget (2 s release; asserted generously here because
    /// the test may run in debug), and the offset still within 0.1 ms.
    @Test(.enabled(if: LongRecordingTests.enabled), .timeLimit(.minutes(10)))
    func twoHourRecordingAlignsQuickly() async throws {
        let dir = try TestMedia.Directory()
        let renderDuration = 300.0, insertSeconds = 5.0, cameraDuration = 7200.0
        let pair = try await TestMedia.alignmentPair(
            seed: 51, cameraDuration: renderDuration + 10, renderDuration: renderDuration, offsetSeconds: insertSeconds,
            driftPPM: 23, snrDB: 0, in: dir.url)
        let performance = try await TestMedia.readAudio(url: pair.camera.url).channel(0)
        // Build the long track directly: pink noise at the pair's own noise level, with the pair's camera
        // (noise + performance + rumble + AGC) spliced in at a known position deep inside the second hour.
        let t0 = now()
        let fs = 48_000.0
        // A 10-minute pink-noise block tiled twelve times: the render never contains this noise, so its
        // repetition is invisible to the alignment and keeps the debug-mode synthesis short.
        let noiseLevel = rms(performance[0..<Int(4 * fs)])
        var block = pinkNoise(count: Int(600 * fs), seed: 52)
        for i in block.indices { block[i] *= noiseLevel }
        var camera: [Float] = []
        camera.reserveCapacity(Int(cameraDuration * fs))
        while camera.count < Int(cameraDuration * fs) { camera.append(contentsOf: block) }
        let splice = 97 * 60 + 41.5
        let at = Int(splice * fs)
        camera.replaceSubrange(at..<(at + performance.count), with: performance)
        let url = dir.file("two-hours.caf")
        try writeCAF(camera, sampleRate: fs, to: url)
        let expectedOffset = splice + insertSeconds
        print(String(format: "[AudioAlign] 2 h synthesis + write %.1f s", seconds(since: t0)))

        var builderPeak = 0
        let source = try await AudioFileSource.open(url: url)
        #expect(source.frameCount == Int64(cameraDuration * fs))
        var builder = try OnsetEnvelopeBuilder(inputSampleRate: fs, parameters: AlignmentParameters())
        var chunks = 0
        let t1 = now()
        try source.forEachChunk(chunkFrames: AlignerDefaults.streamingChunkFrames) { chunk in
            #expect(chunk.count <= AlignerDefaults.streamingChunkFrames)
            builder.append(chunk)
            builderPeak = max(builderPeak, builder.residentSampleCount)
            chunks += 1
        }
        let envelope = builder.finish()
        let envelopeSeconds = seconds(since: t1)
        #expect(chunks >= Int(cameraDuration * fs) / AlignerDefaults.streamingChunkFrames)
        #expect(builderPeak <= AlignerDefaults.streamingChunkFrames + AlignmentParameters().decimationFilterTaps + 512)
        #expect(abs(envelope.duration - cameraDuration) < 1)

        let t2 = now()
        let alignment = try await OnsetAligner().align(
            reference: .file(url, contentHash: nil), target: .file(pair.render.url, contentHash: nil),
            parameters: AlignmentParameters())
        let wall = seconds(since: t2)
        let errorMs = ((alignment.offset?.seconds ?? .nan) - expectedOffset) * 1000
        print(
            String(
                format: "[AudioAlign] 2 h camera vs 5 min render: status %@ offset err %.4f ms drift %.2f ppm "
                    + "confidence %.3f align %.3f s (envelope alone %.3f s, peak resident %d samples)",
                alignment.status.rawValue, errorMs, alignment.driftPPM, alignment.confidence, wall, envelopeSeconds,
                builderPeak))
        #expect(alignment.status == .aligned)
        #expect(abs(errorMs) < 0.1)
        #expect(abs(alignment.driftPPM - 23) < 1)
        // 2 s is the release budget; debug builds of the scalar parts and parallel test load need headroom.
        #expect(wall < 20, "alignment took \(wall) s")
    }
}
