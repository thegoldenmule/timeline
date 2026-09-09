import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import MediaKit

/// Throughput numbers for the streamed analyses on a long file. Off by default (they take a while in debug);
/// run with `MEDIAKIT_BENCH=1 swift test -c release --filter BenchmarkTests`.
@Suite(.serialized) struct BenchmarkTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MEDIAKIT_BENCH"] != nil }
    static var minutes: Double { Double(ProcessInfo.processInfo.environment["MEDIAKIT_BENCH"] ?? "") ?? 10 }

    @Test(.enabled(if: BenchmarkTests.enabled), .timeLimit(.minutes(30)))
    func streamedAnalysesOnLongAudio() async throws {
        let lib = try TestLibrary()
        let seconds = BenchmarkTests.minutes * 60
        let clicks = stride(from: 0.5, to: seconds, by: 0.5).map { $0 }
        let generated = ContinuousClock.now
        let clip = try await TestMedia.transients(
            clickTimes: clicks, duration: seconds, in: lib.media.url, name: "long")
        print("generated \(Int(seconds)) s of clicks in \(String(format: "%.1f", elapsed(generated))) s")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .reference)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let analyzer = lib.analyzer()

        var t = ContinuousClock.now
        let envelope = try await analyzer.onsetEnvelope(media, parameters: AlignmentParameters())
        let envelopeSeconds = elapsed(t)
        print(
            "onset envelope: \(Int(seconds)) s of 48 kHz audio in \(String(format: "%.2f", envelopeSeconds)) s "
                + "(\(String(format: "%.0f", seconds / envelopeSeconds))x realtime), \(envelope.frameCount) frames")

        t = ContinuousClock.now
        let peaks = try await analyzer.waveformPeaks(media, samplesPerPixel: 8192)
        let peaksSeconds = elapsed(t)
        print(
            "peaks: \(Int(seconds)) s in \(String(format: "%.2f", peaksSeconds)) s "
                + "(\(String(format: "%.0f", seconds / peaksSeconds))x realtime), \(peaks.count) pairs at hop 8192")

        t = ContinuousClock.now
        let silence = try await analyzer.detectSilence(media, parameters: SilenceParameters())
        let silenceSeconds = elapsed(t)
        print(
            "silence: \(Int(seconds)) s in \(String(format: "%.2f", silenceSeconds)) s "
                + "(\(String(format: "%.0f", seconds / silenceSeconds))x realtime), \(silence.ranges.count) ranges")

        t = ContinuousClock.now
        let hash = try await ContentHash.sha256(of: clip.url)
        let hashSeconds = elapsed(t)
        let bytes = Double((try? FileManager.default.attributesOfItem(atPath: clip.url.path)[.size] as? Int) ?? 0)
        print(
            "sha256: \(String(format: "%.0f", bytes / 1e6)) MB in \(String(format: "%.2f", hashSeconds)) s "
                + "(\(String(format: "%.1f", bytes / hashSeconds / 1e9)) GB/s) \(hash.prefix(20))")
        #expect(envelope.frameCount > 0)
    }
}
