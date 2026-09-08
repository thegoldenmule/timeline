import Contracts
import ContractsTestSupport
import Foundation
import Speech
import Synchronization
import Testing
import TimelineCore

@testable import MediaKit

@Suite(.serialized) struct TranscriptionTests {
    static var speechAvailable: Bool { SpeechFixture.sayAvailable && SpeechTranscriber.isAvailable }

    @Test(.enabled(if: TranscriptionTests.speechAvailable), .timeLimit(.minutes(10)))
    func transcribesSayFixtureUnderTenPercentWER() async throws {
        let lib = try TestLibrary()
        let rendered = ContinuousClock.now
        let audio = try #require(try SpeechFixture.render(into: lib.media.url))
        print("say rendered the fixture in \(String(format: "%.2f", elapsed(rendered))) s")
        let imported = try await lib.library.importAsset(url: audio, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let analyzer = lib.analyzer()
        let locale = Locale(identifier: "en_US")

        let reservedBefore = await AssetInventory.reservedLocales.map(\.identifier).sorted()
        let download = Mutex<[JobProgress]>([])
        let started = ContinuousClock.now
        let transcript = try await analyzer.transcribe(
            media, locale: locale, options: TranscriptionOptions(alternatives: true)
        ) {
            progress in
            if progress.stage == "download" { download.withLock { $0.append(progress) } }
        }
        let seconds = elapsed(started)
        let reservedAfter = await AssetInventory.reservedLocales.map(\.identifier).sorted()
        let downloadSeconds =
            (try? lib.cache.artifact(
                contentHash: media.contentHash, kind: .transcript,
                paramsHash: String(transcript.cacheKey.split(separator: "/").last ?? "")))?.summary?["downloadSeconds"]?
            .numberValue
        print(
            "transcribed \(String(format: "%.1f", imported.asset.duration.seconds)) s of speech in "
                + "\(String(format: "%.2f", seconds)) s (\(String(format: "%.0f", imported.asset.duration.seconds / seconds))x realtime)"
                + (downloadSeconds.map { ", model download \(String(format: "%.1f", $0)) s" }
                    ?? ", model already installed")
                + ", download progress reports: \(download.withLock { $0.count })")
        #expect(
            reservedAfter == reservedBefore,
            "locale reservation released: before \(reservedBefore), after \(reservedAfter)")

        #expect(transcript.engine == "speechanalyzer")
        #expect(transcript.language.lowercased().hasPrefix("en"))
        #expect(transcript.words.count > 150)
        #expect(!transcript.segments.isEmpty)
        #expect(transcript.cacheKey.hasPrefix("\(media.contentHash)/transcript/v1-"))
        for word in transcript.words {
            #expect(word.t1 >= word.t0)
            #expect(word.confidence >= 0 && word.confidence <= 1)
        }
        #expect(transcript.words.allSatisfy { $0.confidence > 0 }, "every word carries a confidence")
        #expect(zip(transcript.words, transcript.words.dropFirst()).allSatisfy { $0.t0 <= $1.t0 }, "monotonic")
        #expect(transcript.words.last!.t1.seconds <= imported.asset.duration.seconds + 0.5)
        #expect(transcript.words.map(\.t1).max()!.seconds > 30)
        let distinctStarts = Set(transcript.words.map(\.t0))
        #expect(distinctStarts.count > transcript.words.count / 2, "per-word ranges, not one range per phrase")

        let hypothesis = WordErrorRate.normalize(transcript.text)
        let reference = WordErrorRate.normalize(SpeechFixture.script)
        let normalizedReference = WordErrorRate.normalize(WordErrorRate.numberNormalized(SpeechFixture.script))
        let raw = WordErrorRate.rate(reference: reference, hypothesis: hypothesis)
        let normalized = WordErrorRate.rate(reference: normalizedReference, hypothesis: hypothesis)
        print(
            "WER raw \(String(format: "%.1f", raw * 100))%, number-normalized \(String(format: "%.1f", normalized * 100))% "
                + "(\(reference.count) reference words, \(hypothesis.count) hypothesis words)")
        #expect(normalized < 0.10, "WER \(normalized)")
        #expect(hypothesis.contains("sundance"))

        // Recorded artifact, FTS index, and a cache hit on the second call.
        let hits = try analyzer.searchTranscript("Sundance", contentHashes: [media.contentHash])
        #expect(hits.count == 1)
        #expect(hits.first?.t0.seconds ?? 0 > 20)
        #expect(try analyzer.searchTranscript("Sundance", contentHashes: ["sha256-other"]).isEmpty)
        let t1 = ContinuousClock.now
        let cached = try await analyzer.transcribe(
            media, locale: locale, options: TranscriptionOptions(alternatives: true))
        print("transcript cache hit in \(String(format: "%.4f", elapsed(t1))) s")
        #expect(cached == transcript)
        let artifacts = try lib.cache.artifacts(contentHash: media.contentHash, kind: .transcript)
        #expect(artifacts.count == 1)
        #expect(artifacts[0].path.hasSuffix("/transcript.json"))

        // Different options are a different artifact.
        let plain = try await analyzer.transcribe(media, locale: locale, options: TranscriptionOptions())
        #expect(plain.cacheKey != transcript.cacheKey)
        #expect(plain.segments.allSatisfy { $0.alternatives.isEmpty })
        #expect(try lib.cache.artifacts(contentHash: media.contentHash, kind: .transcript).count == 2)

        let op = MediaKit.analysisOperation(for: imported.asset, kind: .transcript, cacheKey: transcript.cacheKey)
        if case .recordAssetAnalysis(let r) = op { #expect(r.cacheKey == transcript.cacheKey) }
    }

    @Test(.enabled(if: SpeechTranscriber.isAvailable))
    func unsupportedLocaleIsRejected() async throws {
        let lib = try TestLibrary()
        let tone = try await TestMedia.tone(duration: 1, in: lib.media.url, name: "tone")
        let imported = try await lib.library.importAsset(url: tone.url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        await #expect(throws: AnalysisError.unsupportedLocale("xx_YY")) {
            try await lib.analyzer().transcribe(
                media, locale: Locale(identifier: "xx_YY"), options: TranscriptionOptions())
        }
    }

    @Test func wordErrorRateHelper() {
        #expect(WordErrorRate.normalize("Hello, World! It’s 5 o'clock.") == ["hello", "world", "it's", "5", "o'clock"])
        #expect(WordErrorRate.rate(reference: ["a", "b", "c"], hypothesis: ["a", "b", "c"]) == 0)
        #expect(WordErrorRate.rate(reference: ["a", "b", "c"], hypothesis: ["a", "x", "c"]) == 1.0 / 3)
        #expect(WordErrorRate.rate(reference: ["a", "b"], hypothesis: []) == 1)
        #expect(WordErrorRate.numberNormalized("ninety six minutes").contains("96 minutes"))
    }
}
