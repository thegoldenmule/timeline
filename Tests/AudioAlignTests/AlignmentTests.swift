import AVFoundation
import Contracts
import ContractsTestSupport
import Foundation
import Synchronization
import Testing
import TimelineCore

@testable import AudioAlign

// MARK: - Helpers

func now() -> ContinuousClock.Instant { .now }

func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
}

/// Writes mono float samples as a 32-bit float `.caf` (the same container `TestMedia` uses).
func writeCAF(_ samples: [Float], sampleRate: Double, to url: URL) throws {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let file = try AVAudioFile(
        forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let chunk = 1 << 16
    var start = 0
    while start < samples.count {
        let count = min(chunk, samples.count - start)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        samples.withUnsafeBufferPointer { p in
            buffer.floatChannelData![0].update(from: p.baseAddress! + start, count: count)
        }
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer)
        start += count
    }
}

struct AlignedPair {
    var alignment: Alignment
    var truth: TestMedia.AlignmentTruth
    var generationSeconds: Double

    /// Offset error of the best candidate in milliseconds.
    var offsetErrorMs: Double {
        guard let offset = alignment.offset else { return .nan }
        return (offset.seconds - truth.offsetSeconds) * 1000
    }

    var driftErrorPPM: Double { alignment.driftPPM - truth.driftPPM }
}

func alignPair(
    seed: UInt64 = 1, cameraDuration: Double, renderDuration: Double, offsetSeconds: Double, driftPPM: Double,
    snrDB: Double, parameters: AlignmentParameters = AlignmentParameters(), in directory: TestMedia.Directory
) async throws -> AlignedPair {
    let t0 = now()
    let pair = try await TestMedia.alignmentPair(
        seed: seed, cameraDuration: cameraDuration, renderDuration: renderDuration, offsetSeconds: offsetSeconds,
        driftPPM: driftPPM, snrDB: snrDB, in: directory.url)
    let generation = seconds(since: t0)
    let alignment = try await OnsetAligner().align(
        reference: .file(pair.camera.url, contentHash: "camera"), target: .file(pair.render.url, contentHash: "render"),
        parameters: parameters)
    return AlignedPair(alignment: alignment, truth: pair.truth, generationSeconds: generation)
}

func describe(_ label: String, _ r: AlignedPair) {
    let a = r.alignment
    print(
        String(
            format: "[AudioAlign] %@: status %@ offset err %.4f ms drift %.2f ppm (truth %.0f, err %.3f) "
                + "confidence %.3f candidates %d verified %d elapsed %.3f s (generation %.2f s)",
            label, a.status.rawValue, r.offsetErrorMs, a.driftPPM, r.truth.driftPPM, r.driftErrorPPM, a.confidence,
            a.candidates.count, a.candidates.filter(\.verified).count, a.elapsedSeconds, r.generationSeconds))
}

// MARK: - Accuracy

struct SNRCase: CustomStringConvertible {
    var snrDB: Double
    var driftPPM: Double
    /// Where the render starts in the camera track: near the start, the middle, or the end.
    var placement: String
    var description: String { "SNR \(Int(snrDB)) dB, drift \(Int(driftPPM)) ppm, \(placement)" }

    static let cameraDuration = 600.0
    static let renderDuration = 150.0

    var offsetSeconds: Double {
        switch placement {
        case "start": 0.4
        case "middle": 300.123
        default: Self.cameraDuration - Self.renderDuration - 0.6  // leaves room for the 0.1 s reverb tail
        }
    }

    static let all: [SNRCase] = {
        var cases: [SNRCase] = []
        for snr in [0.0, -5, -10] {
            for drift in [23.0, 0] {
                for placement in ["start", "middle", "end"] {
                    cases.append(SNRCase(snrDB: snr, driftPPM: drift, placement: placement))
                }
            }
        }
        return cases
    }()
}

@Suite struct AccuracyTests {
    /// Offset within 0.1 ms and drift within 1 ppm down to -10 dB SNR, with and without drift, with the render
    /// near the start, middle, and end of the camera track.
    @Test(arguments: SNRCase.all) func offsetAndDriftWithinBudget(_ c: SNRCase) async throws {
        let dir = try TestMedia.Directory()
        let r = try await alignPair(
            seed: 1, cameraDuration: SNRCase.cameraDuration, renderDuration: SNRCase.renderDuration,
            offsetSeconds: c.offsetSeconds, driftPPM: c.driftPPM, snrDB: c.snrDB, in: dir)
        describe(c.description, r)
        #expect(r.alignment.status == .aligned)
        #expect(abs(r.offsetErrorMs) < 0.1, "offset error \(r.offsetErrorMs) ms")
        #expect(abs(r.driftErrorPPM) < 1, "drift error \(r.driftErrorPPM) ppm")
        #expect(r.alignment.confidence > 0.9)
        #expect(r.alignment.candidates.first?.verified == true)
        #expect(r.alignment.offset?.timescale == 48_000_000)
        #expect(r.alignment.referenceHash == "camera" && r.alignment.targetHash == "render")
        #expect(r.alignment.parametersHash == OnsetAligner.parametersHash(AlignmentParameters()))
        let proof = try #require(r.alignment.proof)
        #expect(proof.correlation.count <= AlignerDefaults.proofCorrelationPoints)
        #expect(proof.windowTimesSeconds.count == proof.windowOffsetsMs.count)
        #expect(proof.windowInliers.count == proof.windowOffsetsMs.count)
        #expect(proof.windowInliers.filter { $0 }.count >= proof.windowInliers.count * 6 / 10)
        #expect(abs(proof.fitInterceptMs - c.offsetSeconds * 1000) < 0.1)
    }
}
