// Spike: SpeechAnalyzer + SpeechTranscriber file transcription from a plain CLI process.
// Usage: speechspike <audio-file> <out.json> [--volatile] [--dictation]
import AVFoundation
import CoreMedia
import Foundation
import Speech

struct Word: Codable { var text: String; var start: Double?; var end: Double?; var confidence: Double? }
struct Segment: Codable {
    var text: String; var start: Double; var end: Double; var isFinal: Bool
    var finalizationTime: Double; var words: [Word]; var alternatives: [String]
}
struct Output: Codable {
    var file: String; var audioDuration: Double; var wallSeconds: Double; var realtimeFactor: Double
    var assetStatusBefore: String; var assetDownloadSeconds: Double?
    var supportedLocaleCount: Int; var installedLocales: [String]
    var transcript: String; var words: [Word]; var segments: [Segment]
}

func secs(_ t: CMTime) -> Double { CMTimeGetSeconds(t) }
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// Break an AttributedString into words, attaching per-run audioTimeRange / confidence.
func words(from text: AttributedString) -> [Word] {
    var out: [Word] = []
    for run in text.runs {
        let s = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { continue }
        let tr = run.audioTimeRange
        let conf = run.transcriptionConfidence
        // If a single run covers several words, split evenly (flagged by identical ranges on each piece).
        let parts = s.split(separator: " ").map(String.init)
        for p in parts {
            out.append(Word(text: p, start: tr.map { secs($0.start) }, end: tr.map { secs($0.end) }, confidence: conf))
        }
    }
    return out
}

let args = CommandLine.arguments
guard args.count >= 3 else { log("usage: speechspike <audio> <out.json> [--volatile] [--dictation]"); exit(2) }
let inURL = URL(fileURLWithPath: args[1]); let outURL = URL(fileURLWithPath: args[2])
let wantVolatile = args.contains("--volatile"); let useDictation = args.contains("--dictation")
let locale = Locale(identifier: args.firstIndex(of: "--locale").flatMap { args.indices.contains($0+1) ? args[$0+1] : nil } ?? "en_US")

if let i = args.firstIndex(of: "--release"), args.indices.contains(i+1) {
    let ok = await AssetInventory.release(reservedLocale: Locale(identifier: args[i+1]))
    log("release(\(args[i+1])) -> \(ok); reserved now \(await AssetInventory.reservedLocales.map(\.identifier))"); exit(0)
}
let t0 = Date()
let supported = await SpeechTranscriber.supportedLocales
let installed = await SpeechTranscriber.installedLocales
log("SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable) supported=\(supported.count) installed=\(installed.map(\.identifier))")
log("locale query took \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")

// Build the module.
var reporting: Set<SpeechTranscriber.ReportingOption> = [.alternativeTranscriptions]
if wantVolatile { reporting.insert(.volatileResults) }
let transcriber = SpeechTranscriber(
    locale: locale, transcriptionOptions: [], reportingOptions: reporting,
    attributeOptions: [.audioTimeRange, .transcriptionConfidence])
let dictation = DictationTranscriber(
    locale: locale, contentHints: [], transcriptionOptions: [], reportingOptions: [],
    attributeOptions: [.audioTimeRange, .transcriptionConfidence])
let modules: [any SpeechModule] = useDictation ? [dictation] : [transcriber]

// Ensure assets.
let statusBefore = await AssetInventory.status(forModules: modules)
log("AssetInventory.status before: \(statusBefore)")
var downloadSecs: Double? = nil
if let req = try await AssetInventory.assetInstallationRequest(supporting: modules) {
    log("Asset install needed; downloading... (progress: \(req.progress.totalUnitCount))")
    let d0 = Date()
    let watcher = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); log("  progress \(Int(req.progress.fractionCompleted*100))%") } }
    try await req.downloadAndInstall()
    watcher.cancel()
    downloadSecs = Date().timeIntervalSince(d0)
    log("Asset download+install took \(String(format: "%.1f", downloadSecs!))s; status now \(await AssetInventory.status(forModules: modules))")
} else { log("Assets already installed; no download needed.") }
let reservedBefore = await AssetInventory.reservedLocales
log("reservedLocales=\(reservedBefore.map(\.identifier)) max=\(AssetInventory.maximumReservedLocales)")

// Open the file and run analysis.
let file = try AVAudioFile(forReading: inURL)
let duration = Double(file.length) / file.fileFormat.sampleRate
log("audio: \(inURL.lastPathComponent) \(file.fileFormat.sampleRate)Hz ch=\(file.fileFormat.channelCount) dur=\(String(format: "%.2f", duration))s")
if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) { log("bestAvailableAudioFormat: \(best)") }

let analyzer = SpeechAnalyzer(modules: modules)
var segments: [Segment] = []
var volatileCount = 0

// Collect results concurrently with analysis. Result structs are Sendable; collect into an array in this task.
let collector: Task<[Segment], Error> = Task {
    var segs: [Segment] = []
    if useDictation {
        for try await r in dictation.results {
            segs.append(Segment(text: String(r.text.characters), start: secs(r.range.start), end: secs(r.range.end),
                                isFinal: r.isFinal, finalizationTime: secs(r.resultsFinalizationTime),
                                words: words(from: r.text), alternatives: r.alternatives.map { String($0.characters) }))
        }
    } else {
        for try await r in transcriber.results {
            segs.append(Segment(text: String(r.text.characters), start: secs(r.range.start), end: secs(r.range.end),
                                isFinal: r.isFinal, finalizationTime: secs(r.resultsFinalizationTime),
                                words: words(from: r.text), alternatives: r.alternatives.map { String($0.characters) }))
        }
    }
    return segs
}

let a0 = Date()
try await analyzer.prepareToAnalyze(in: file.processingFormat)
let prepSecs = Date().timeIntervalSince(a0)
let a1 = Date()
let lastTime = try await analyzer.analyzeSequence(from: file)
try await analyzer.finalizeAndFinish(through: lastTime ?? .zero)
let analyzeSecs = Date().timeIntervalSince(a1)
segments = try await collector.value
let wall = Date().timeIntervalSince(a0)
volatileCount = segments.filter { !$0.isFinal }.count
log("prepare=\(String(format: "%.2f", prepSecs))s analyze+finalize=\(String(format: "%.2f", analyzeSecs))s total=\(String(format: "%.2f", wall))s lastTime=\(lastTime.map(secs) ?? -1)")
log("results: \(segments.count) (\(volatileCount) volatile)  realtime factor: \(String(format: "%.1f", duration / wall))x")

let finals = segments.filter(\.isFinal)
let allWords = finals.flatMap(\.words)
let transcript = finals.map(\.text).joined(separator: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
let out = Output(file: inURL.lastPathComponent, audioDuration: duration, wallSeconds: wall, realtimeFactor: duration / wall,
                 assetStatusBefore: "\(statusBefore)", assetDownloadSeconds: downloadSecs,
                 supportedLocaleCount: supported.count, installedLocales: installed.map(\.identifier),
                 transcript: transcript, words: allWords, segments: segments)
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(out).write(to: outURL)
try transcript.write(to: outURL.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
print(transcript)
