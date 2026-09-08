import AVFoundation
import Contracts
import Foundation
import Speech
import TimelineCore

/// The five SpeechAnalyzer locale reservation slots (`AssetInventory.maximumReservedLocales`). A locale that was
/// already reserved for this process when a transcription starts stays reserved afterwards; one this actor
/// reserved is released when the last transcription using it finishes. When every slot is taken by other
/// locales, the least recently used one this actor holds and no transcription is using is released first.
actor LocaleReservations {
    private var held: [String: Int] = [:]
    private var recent: [String] = []

    /// Reserves and installs assets for `transcriber`. Returns the download time when a download was needed.
    func acquire(_ locale: Locale, transcriber: SpeechTranscriber, progress: (@Sendable (JobProgress) -> Void)?)
        async throws -> Double?
    {
        let key = LocaleReservations.key(locale)
        let reservedBefore = await AssetInventory.reservedLocales.map(LocaleReservations.key)
        let previouslyReserved = reservedBefore.contains(key)
        if !previouslyReserved, reservedBefore.count >= AssetInventory.maximumReservedLocales {
            let idle = recent.first { held[$0, default: 0] == 0 && reservedBefore.contains($0) }
            let victim = idle ?? reservedBefore.first { held[$0] == nil }
            if let victim {
                _ = await AssetInventory.release(reservedLocale: Locale(identifier: victim))
                held.removeValue(forKey: victim)
                recent.removeAll { $0 == victim }
            }
        }
        var downloadSeconds: Double?
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let started = Date()
            progress?(JobProgress(fraction: nil, message: "Downloading speech model for \(locale.identifier)", stage: "download"))
            let watcher = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    progress?(JobProgress(fraction: request.progress.fractionCompleted, stage: "download"))
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
            downloadSeconds = Date().timeIntervalSince(started)
        }
        if !previouslyReserved { held[key, default: 0] += 1 }
        recent.removeAll { $0 == key }
        recent.append(key)
        return downloadSeconds
    }

    func release(_ locale: Locale) async {
        let key = LocaleReservations.key(locale)
        guard let count = held[key] else { return }
        if count <= 1 {
            held.removeValue(forKey: key)
            _ = await AssetInventory.release(reservedLocale: locale)
        } else {
            held[key] = count - 1
        }
    }

    static func key(_ locale: Locale) -> String { locale.identifier(.bcp47).lowercased() }
}

/// SpeechAnalyzer + SpeechTranscriber file transcription as measured in spikes/speech: results are consumed in a
/// task started before `analyzeSequence`, volatile results are never requested and their ranges ignored, and the
/// per-run `audioTimeRange` / `transcriptionConfidence` attributes become `TranscriptWord`s.
enum SpeechEngine {
    struct Parameters: Hashable, Sendable, Codable {
        var locale: String
        var options: TranscriptionOptions
        var engine: String = "speechanalyzer"
    }

    static let version = 1

    struct Output: Sendable {
        var words: [TranscriptWord]
        var segments: [TranscriptSegment]
        var language: String
        var downloadSeconds: Double?
        var elapsedSeconds: Double
    }

    static func isSupported(_ locale: Locale) async -> Bool {
        let key = LocaleReservations.key(locale)
        return await SpeechTranscriber.supportedLocales.contains { LocaleReservations.key($0) == key }
    }

    /// Transcribes an audio file (any format `AVAudioFile` opens).
    static func transcribe(
        audioURL: URL, locale: Locale, options: TranscriptionOptions, reservations: LocaleReservations,
        progress: (@Sendable (JobProgress) -> Void)?
    ) async throws -> Output {
        guard SpeechTranscriber.isAvailable else { throw AnalysisError.engineUnavailable("SpeechTranscriber") }
        guard await isSupported(locale) else { throw AnalysisError.unsupportedLocale(locale.identifier) }
        let started = Date()
        var reporting: Set<SpeechTranscriber.ReportingOption> = []
        if options.alternatives { reporting.insert(.alternativeTranscriptions) }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: reporting,
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let downloadSeconds = try await reservations.acquire(locale, transcriber: transcriber, progress: progress)
        do {
            var output = try await analyze(audioURL: audioURL, transcriber: transcriber, options: options, progress: progress)
            await reservations.release(locale)
            output.language = locale.identifier(.bcp47)
            output.downloadSeconds = downloadSeconds
            output.elapsedSeconds = Date().timeIntervalSince(started)
            return output
        } catch {
            await reservations.release(locale)
            throw error
        }
    }

    private static func analyze(
        audioURL: URL, transcriber: SpeechTranscriber, options: TranscriptionOptions,
        progress: (@Sendable (JobProgress) -> Void)?
    ) async throws -> Output {
        try Task.checkCancellation()
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL)
        } catch {
            throw AnalysisError.failed("open audio: \(error.localizedDescription)")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task<[SpeechTranscriber.Result], any Error> {
            var out: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results where result.isFinal {
                out.append(result)
            }
            return out
        }
        progress?(JobProgress(fraction: 0, stage: "transcribe"))
        do {
            try await analyzer.prepareToAnalyze(in: file.processingFormat)
            let last = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinish(through: last ?? .zero)
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            if error is CancellationError { throw error }
            throw AnalysisError.failed("SpeechAnalyzer: \(error.localizedDescription)")
        }
        let results = try await collector.value
        try Task.checkCancellation()

        var words: [TranscriptWord] = []
        var segments: [TranscriptSegment] = []
        for result in results {
            words.append(contentsOf: SpeechEngine.words(from: result.text))
            let range = TimeRange(
                start: RationalTime(cmValue: result.range.start.value, timescale: result.range.start.timescale),
                end: RationalTime(cmValue: result.range.end.value, timescale: result.range.end.timescale))
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            let alternatives =
                options.alternatives
                ? result.alternatives.map { String($0.characters).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0 != text }
                : []
            segments.append(TranscriptSegment(text: text, range: range, alternatives: alternatives))
        }
        return Output(words: words, segments: segments, language: "", downloadSeconds: nil, elapsedSeconds: 0)
    }

    /// One word per attributed run; a run covering several space-separated tokens (never observed in the spike)
    /// splits into words sharing the run's range and confidence.
    static func words(from text: AttributedString) -> [TranscriptWord] {
        var out: [TranscriptWord] = []
        for run in text.runs {
            let s = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let range = run.audioTimeRange else { continue }
            let t0 = RationalTime(cmValue: range.start.value, timescale: range.start.timescale)
            let t1 = RationalTime(cmValue: range.end.value, timescale: range.end.timescale)
            let confidence = run.transcriptionConfidence ?? 0
            for part in s.split(separator: " ") where !part.isEmpty {
                out.append(TranscriptWord(text: String(part), t0: t0, t1: t1, confidence: confidence))
            }
        }
        return out
    }
}
