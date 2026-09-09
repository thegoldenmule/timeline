import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import MediaKit

@Suite struct AnalyzerTests {
    @Test func silenceBetweenClicks() async throws {
        let lib = try TestLibrary()
        let clip = try await TestMedia.transients(
            clickTimes: [0.5, 2.0], duration: 3, in: lib.media.url, name: "clicks")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let analyzer = lib.analyzer()

        let params = SilenceParameters(thresholdDB: -40, minimumDurationSeconds: 0.3)
        let silence = try await analyzer.detectSilence(media, parameters: params)
        #expect(silence.parameters == params)
        #expect(silence.ranges.count == 3, "\(silence.ranges)")
        let seconds = silence.ranges.map { ($0.start.seconds, $0.end.seconds) }
        #expect(abs(seconds[0].0 - 0) < 0.02 && abs(seconds[0].1 - 0.5) < 0.02)
        #expect(abs(seconds[1].0 - 0.5) < 0.05 && abs(seconds[1].1 - 2.0) < 0.02)
        #expect(abs(seconds[2].0 - 2.0) < 0.05 && abs(seconds[2].1 - 3.0) < 0.02)
        #expect(silence.ranges.allSatisfy { $0.start.timescale == 48000 })
        #expect(silence.cacheKey.hasPrefix("\(imported.asset.contentHash)/silence/v1-"))

        // A tone is never silent.
        let tone = try await TestMedia.tone(duration: 1, in: lib.media.url, name: "tone")
        let toneAsset = try await lib.library.importAsset(url: tone.url, mode: .copy)
        let loud = try await analyzer.detectSilence(
            MediaReference(asset: toneAsset.asset, layout: lib.layout), parameters: params)
        #expect(loud.ranges.isEmpty)

        // Video without audio.
        let video = try await TestMedia.colorBars(duration: 0.5, in: lib.media.url, name: "bars")
        let videoAsset = try await lib.library.importAsset(url: video.url, mode: .copy)
        await #expect(throws: AnalysisError.noAudioTrack) {
            try await analyzer.detectSilence(
                MediaReference(asset: videoAsset.asset, layout: lib.layout), parameters: params)
        }
    }

    @Test func artifactsAreContentAddressedAndInvalidatedByParams() async throws {
        let lib = try TestLibrary()
        let clip = try await TestMedia.transients(clickTimes: [1.0], duration: 2, in: lib.media.url, name: "inv")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let analyzer = lib.analyzer()
        let hash = imported.asset.contentHash

        let a = SilenceParameters(thresholdDB: -40, minimumDurationSeconds: 0.5)
        let first = try await analyzer.detectSilence(media, parameters: a)
        let rowsAfterFirst = try lib.cache.artifacts(contentHash: hash, kind: .silence)
        #expect(rowsAfterFirst.count == 1)
        #expect(rowsAfterFirst[0].cacheKey == first.cacheKey)
        #expect(
            rowsAfterFirst[0].path
                == "sha256/\(hash.dropFirst(7).prefix(2))/\(hash.dropFirst(9).prefix(2))/\(hash.dropFirst(7))/silence.json"
        )
        let firstURL = lib.cache.url(for: rowsAfterFirst[0])
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        let firstStamp = try FileManager.default.attributesOfItem(atPath: firstURL.path)[.modificationDate] as? Date

        // Unchanged parameters: cache hit, same key, nothing rewritten.
        let t0 = ContinuousClock.now
        let again = try await analyzer.detectSilence(media, parameters: a)
        let cachedSeconds = elapsed(t0)
        #expect(again == first)
        #expect(try lib.cache.artifacts(contentHash: hash, kind: .silence).count == 1)
        let againStamp = try FileManager.default.attributesOfItem(atPath: firstURL.path)[.modificationDate] as? Date
        #expect(againStamp == firstStamp)
        print("silence cache hit in \(String(format: "%.4f", cachedSeconds)) s")

        // Changed parameter: a new params hash, a new row, a new key; the old artifact stays valid.
        let b = SilenceParameters(thresholdDB: -60, minimumDurationSeconds: 0.5)
        let changed = try await analyzer.detectSilence(media, parameters: b)
        #expect(changed.cacheKey != first.cacheKey)
        #expect(changed.cacheKey.hasPrefix("\(hash)/silence/v1-"))
        let rows = try lib.cache.artifacts(contentHash: hash, kind: .silence)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.paramsHash)).count == 2)
        #expect(try lib.cache.artifact(contentHash: hash, kind: .silence, paramsHash: rows[0].paramsHash) != nil)

        // The key is the artifacts primary key rendered as `<hash>/<kind>/<paramsHash>`.
        for row in rows {
            #expect(
                row.cacheKey == AnalysisCacheKey.make(contentHash: hash, kind: .silence, paramsHash: row.paramsHash))
        }

        // Deleting the artifact file makes the next call recompute and re-record.
        try FileManager.default.removeItem(at: firstURL)
        let recomputed = try await analyzer.detectSilence(media, parameters: a)
        #expect(recomputed == first)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
    }

    @Test func shotsOnTwoColourClip() async throws {
        let lib = try TestLibrary()
        let url = try await ShotFixture.twoShots(in: lib.media.url, seconds: 1)
        let imported = try await lib.library.importAsset(url: url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let analyzer = lib.analyzer()
        let started = ContinuousClock.now
        let shots = try await analyzer.detectShots(
            media, parameters: ShotParameters(threshold: 0.3, minimumShotSeconds: 0.2))
        print(
            "shots on 2 s clip in \(String(format: "%.3f", elapsed(started))) s: \(shots.shots.map { ($0.range.start.seconds, $0.range.end.seconds) })"
        )
        #expect(shots.shots.count == 2, "\(shots.shots)")
        #expect(abs(shots.shots[0].range.end.seconds - 1) < 0.05)
        #expect(shots.shots[0].range.start == .zero)
        #expect(shots.shots[1].range.start == shots.shots[0].range.end)
        #expect(abs(shots.shots[1].range.end.seconds - 2) < 0.05)
        #expect(shots.shots[0].range.contains(shots.shots[0].keyframeAt))
        #expect(shots.cacheKey.hasPrefix("\(imported.asset.contentHash)/shots/v1-"))
        let cached = try await analyzer.detectShots(
            media, parameters: ShotParameters(threshold: 0.3, minimumShotSeconds: 0.2))
        #expect(cached == shots)

        // A single-colour clip is one shot.
        let bars = try await TestMedia.colorBars(duration: 1, in: lib.media.url, name: "bars")
        let barsAsset = try await lib.library.importAsset(url: bars.url, mode: .copy)
        let one = try await analyzer.detectShots(
            MediaReference(asset: barsAsset.asset, layout: lib.layout), parameters: ShotParameters())
        #expect(one.shots.count == 1)
    }

    @Test func onsetEnvelopeFileFormatAndPeaks() async throws {
        let lib = try TestLibrary()
        let clicks = [0.5, 1.25, 2.0, 3.1]
        let clip = try await TestMedia.transients(clickTimes: clicks, duration: 4, in: lib.media.url, name: "onsets")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let analyzer = lib.analyzer()
        let params = AlignmentParameters()

        let started = ContinuousClock.now
        let envelope = try await analyzer.onsetEnvelope(media, parameters: params)
        let seconds = elapsed(started)
        #expect(envelope.sampleRate == params.envelopeSampleRate)
        #expect(envelope.hop == params.envelopeHop)
        let url = try #require(envelope.url)
        #expect(url.lastPathComponent == "onset-8k.f32")
        #expect(url.path.contains("/sha256/"))
        let data = try Data(contentsOf: url)
        #expect(data.count == envelope.frameCount * 4, "little-endian Float32, one per hop")
        let fps = Double(params.envelopeSampleRate) / Double(params.envelopeHop)
        let expectedFrames = Int(4 * fps)
        #expect(abs(envelope.frameCount - expectedFrames) <= 4, "\(envelope.frameCount) vs \(expectedFrames)")
        print("onset envelope of 4 s in \(String(format: "%.3f", seconds)) s, \(envelope.frameCount) frames")

        // Decode as the aligner will: LE Float32; the largest values sit at the click frames. As in the spike,
        // frame f spans samples [f * hop, f * hop + window), so an onset shows up in the first frame whose window
        // reaches the click, three frames before floor(sample / hop).
        let samples = OnsetEnvelopeBuilder.decode(data)
        #expect(samples.count == envelope.frameCount)
        let mean = samples.reduce(0, +) / Float(samples.count)
        #expect(abs(mean) < 1e-3, "mean-subtracted")
        var top = Array(samples.enumerated()).sorted { $0.element > $1.element }.prefix(clicks.count).map(\.offset)
        top.sort()
        let expected = clicks.map { AnalyzerTests.onsetFrame(seconds: $0, parameters: params) }
        for (got, want) in zip(top, expected) {
            #expect(abs(got - want) <= 1, "peak frame \(got) vs click frame \(want)")
        }
        #expect(envelope.cacheKey.hasPrefix("\(imported.asset.contentHash)/onset-8k/v1-"))
        #expect(envelope.audioSource(audioURL: media.url, contentHash: media.contentHash) != nil)

        // Cache hit returns the same file; a changed band count is a new artifact.
        let again = try await analyzer.onsetEnvelope(media, parameters: params)
        #expect(
            again.url == envelope.url && again.frameCount == envelope.frameCount && again.cacheKey == envelope.cacheKey)
        var other = params
        other.envelopeBands = 12
        let changed = try await analyzer.onsetEnvelope(media, parameters: other)
        #expect(changed.cacheKey != envelope.cacheKey)
        #expect(try lib.cache.artifacts(contentHash: imported.asset.contentHash, kind: .onsetEnvelope).count == 2)
    }

    @Test func onsetEnvelopeMatchesReferenceOnStereoAAC() async throws {
        // 44.1 kHz stereo AAC exercises the non-integer resampling path; the click must still land.
        let lib = try TestLibrary()
        let clip = try await TestMedia.videoWithAudio(
            .transients(clickTimes: [0.75]), duration: 2, sampleRate: 44100, channels: 2, audioCodec: .aac,
            in: lib.media.url, name: "aac")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let envelope = try await lib.analyzer().onsetEnvelope(media, parameters: AlignmentParameters())
        let samples = OnsetEnvelopeBuilder.decode(try Data(contentsOf: try #require(envelope.url)))
        let peak = samples.indices.max { samples[$0] < samples[$1] } ?? -1
        let fps = 8000.0 / 128
        #expect(
            abs(peak - AnalyzerTests.onsetFrame(seconds: 0.75, parameters: AlignmentParameters())) <= 2,
            "peak frame \(peak)")
        #expect(abs(samples.count - Int(2 * fps)) <= 4)
    }

    /// The first envelope frame whose analysis window contains a click at `seconds`.
    static func onsetFrame(seconds: Double, parameters p: AlignmentParameters) -> Int {
        let sample = Int((seconds * Double(p.envelopeSampleRate)).rounded())
        return (sample - p.envelopeWindow) / p.envelopeHop + 1
    }

    @Test func analysisIsCancellable() async throws {
        let lib = try TestLibrary()
        let clip = try await TestMedia.tone(duration: 20, in: lib.media.url, name: "long")
        let imported = try await lib.library.importAsset(url: clip.url, mode: .copy)
        let media = MediaReference(asset: imported.asset, layout: lib.layout)
        let analyzer = lib.analyzer()
        let task = Task { try await analyzer.onsetEnvelope(media, parameters: AlignmentParameters()) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try lib.cache.artifacts(contentHash: imported.asset.contentHash, kind: .onsetEnvelope).isEmpty)
    }

    @Test func resamplerAndFFTBasics() {
        let n = 512
        let fft = RealFFT(n: n)
        let tone = (0..<n).map { Float(sin(2 * Double.pi * 32 * Double($0) / Double(n))) }
        var power = [Float](repeating: 0, count: n / 2 + 1)
        fft.powerSpectrum(tone, into: &power)
        let peak = power.indices.max { power[$0] < power[$1] }
        #expect(peak == 32)

        var resampler = Resampler(inputRate: 48000, outputRate: 8000, taps: 127)
        let input = [Float](repeating: 1, count: 48000)
        var out: [Float] = []
        for start in stride(from: 0, to: input.count, by: 4096) {
            let chunk = Array(input[start..<min(start + 4096, input.count)])
            chunk.withUnsafeBufferPointer { out.append(contentsOf: resampler.process($0)) }
        }
        #expect(abs(out.count - 8000) <= 2, "\(out.count)")
        #expect(out.dropFirst(100).allSatisfy { abs($0 - 1) < 0.01 }, "unity DC gain")

        let f32 = OnsetEnvelopeBuilder.encode([1, -0.5, 0.25])
        #expect(f32.count == 12)
        #expect(f32[0..<4] == Data([0, 0, 0x80, 0x3F]))
        #expect(OnsetEnvelopeBuilder.decode(f32) == [1, -0.5, 0.25])
    }

    @Test func cacheIndexHintsSearchAndAlignments() throws {
        let lib = try TestLibrary(inMemoryCache: true)
        let now = FixedClock().now()
        try lib.cache.upsertMedia(
            contentHash: "sha256-aa", size: 10, identity: nil, libraryPath: "x.mov", probe: nil, asset: nil, now: now)
        try lib.cache.upsertMedia(
            contentHash: "sha256-bb", size: 10, identity: nil, libraryPath: "y.mov", probe: nil, asset: nil, now: now)
        let grid = RationalTime(3, 50)
        func word(_ t: String, _ i: Int64) -> TranscriptWord {
            TranscriptWord(
                text: t, t0: RationalTime.frames(i, of: grid), t1: RationalTime.frames(i + 1, of: grid), confidence: 0.9
            )
        }
        try lib.cache.replaceTranscriptWords(
            contentHash: "sha256-aa", words: [word("Blackmagic", 0), word("camera", 1)])
        try lib.cache.replaceTranscriptWords(contentHash: "sha256-bb", words: [word("camera", 5), word("shop", 6)])
        let hits = try lib.cache.searchTranscript("camera")
        #expect(hits.map(\.contentHash) == ["sha256-aa", "sha256-bb"])
        #expect(hits[1].t0 == RationalTime.frames(5, of: grid))
        #expect(try lib.cache.searchTranscript("camera", contentHashes: ["sha256-bb"]).count == 1)
        #expect(try lib.cache.searchTranscript("camera", contentHashes: []).isEmpty)
        #expect(try lib.cache.searchTranscript("black*").map(\.word) == ["Blackmagic"])
        #expect(try lib.cache.searchTranscript("\"quoted\" OR").isEmpty)
        #expect(CacheIndex.ftsQuery("a \"b\" c*") == "\"a\" \"\"\"b\"\"\" \"c\"*")
        try lib.cache.replaceTranscriptWords(contentHash: "sha256-aa", words: [])
        #expect(try lib.cache.searchTranscript("camera").count == 1)

        let alignment = Alignment.fixture
        try lib.cache.recordAlignment(
            referenceHash: "sha256-aa", targetHash: "sha256-bb", paramsHash: "v1-x", alignment: alignment, now: now)
        let stored = try #require(
            try lib.cache.alignment(referenceHash: "sha256-aa", targetHash: "sha256-bb", paramsHash: "v1-x"))
        #expect(stored.alignment == alignment)
        #expect(try lib.cache.alignment(referenceHash: "sha256-aa", targetHash: "sha256-bb", paramsHash: "v2-x") == nil)

        let identity = FileIdentity(volumeUUID: "vol", fileID: 42, size: 10, modified: now)
        try lib.cache.rememberIdentity(identity, contentHash: "sha256-aa", path: "/tmp/x.mov", now: now)
        #expect(try lib.cache.contentHash(matching: identity) == "sha256-aa")
        var other = identity
        other.size = 11
        #expect(try lib.cache.contentHash(matching: other) == nil)
        #expect(try lib.cache.knownPaths(contentHash: "sha256-aa") == ["/tmp/x.mov"])
        try lib.cache.optimize()
    }
}
