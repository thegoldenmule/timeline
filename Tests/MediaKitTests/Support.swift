import AVFoundation
import Contracts
import ContractsTestSupport
import Foundation
import TimelineCore

@testable import MediaKit

/// A throwaway library root with an on-disk cache database, removed when released.
final class TestLibrary: Sendable {
    let directory: TestMedia.Directory
    let layout: LibraryLayout
    let cache: CacheIndex
    let library: FileMediaLibrary
    let media: TestMedia.Directory

    init(inMemoryCache: Bool = false) throws {
        directory = try TestMedia.Directory(prefix: "MediaKitLibrary")
        layout = LibraryLayout(root: directory.url)
        cache = inMemoryCache ? try CacheIndex(inMemoryFor: layout) : try CacheIndex(layout: layout)
        library = try FileMediaLibrary(
            layout: layout, cache: cache, ids: SequentialIDGenerator(start: 100), clock: FixedClock())
        media = try TestMedia.Directory(prefix: "MediaKitMedia")
    }

    func analyzer() -> AppleMediaAnalyzer { AppleMediaAnalyzer(cache: cache, clock: FixedClock()) }

    /// Every regular file under `Library/`, relative paths.
    func libraryFiles() -> [String] { TestLibrary.files(under: layout.libraryDir) }

    static func files(under root: URL) -> [String] {
        let resolvedRoot = root.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else {
            return []
        }
        var out: [String] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let path = url.resolvingSymlinksInPath().path
                out.append(path.hasPrefix(resolvedRoot) ? String(path.dropFirst(resolvedRoot.count + 1)) : path)
            }
        }
        return out.sorted()
    }
}

/// Word error rate as `spikes/speech/wer.py` computes it: lowercase, curly apostrophes straightened, everything but
/// `[a-z0-9' ]` replaced by a space, Levenshtein distance over words divided by the reference length.
enum WordErrorRate {
    static func normalize(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        var cleaned = ""
        for ch in lowered {
            if ch.isASCII, ch.isLetter || ch.isNumber || ch == "'" || ch == " " {
                cleaned.append(ch)
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").map(String.init)
    }

    static func rate(reference: [String], hypothesis: [String]) -> Double {
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        var previous = Array(0...hypothesis.count)
        for i in 1...reference.count {
            var current = [i] + [Int](repeating: 0, count: hypothesis.count)
            for j in stride(from: 1, through: hypothesis.count, by: 1) {
                let substitution = previous[j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            previous = current
        }
        return Double(previous[hypothesis.count]) / Double(reference.count)
    }

    /// The spike's reference with spelled-out numbers replaced by the digits the engine renders.
    static let digits: [(String, String)] = [
        ("ninety second", "92nd"), ("four hundred", "400"), ("twelve", "12"), ("seven", "7"), ("twenty four", "24"),
        ("one hundred and eighteen", "118"), ("ninety six", "96"), ("twenty six", "26"),
    ]

    static func numberNormalized(_ text: String) -> String {
        var out = text.lowercased()
        for (words, digit) in digits { out = out.replacingOccurrences(of: words, with: digit) }
        return out
    }
}

/// The spike's script (`spikes/speech/script.txt`) rendered with `say`, so the transcript can be scored.
enum SpeechFixture {
    static let script = """
        Welcome to the Timeline video editor spike. Today we are testing whether Apple's Speech Analyzer can \
        transcribe a ninety second audio file faster than realtime. A typical documentary project contains about \
        four hundred clips, twelve audio tracks, and seven color grades. The editor, Marisol Okonkwo, cut the film \
        in Portland, Oregon, using footage shot on a Blackmagic Pocket Cinema camera at twenty four frames per \
        second. Her assistant editor, Dmitri Vasquez, synchronized the dual system audio using timecode from a \
        Zoom F8 recorder. The rough cut ran one hundred and eighteen minutes, but the final version was trimmed \
        to ninety six minutes for the Sundance Film Festival. Word level timestamps let us click on any word in \
        the transcript and jump the playhead to exactly that moment. We also need confidence scores to highlight \
        uncertain words in yellow. If the transcription engine returns phrases instead of individual words, the \
        interface must estimate word boundaries by dividing the phrase duration evenly. Finally, we must confirm \
        that the model assets download automatically without a graphical user interface, and that the entire \
        pipeline works from a plain command line process on macOS twenty six.
        """

    static var sayAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/say") }

    /// Renders `script` to an AIFF with `/usr/bin/say`. Returns nil when `say` produced nothing (no voices).
    static func render(into directory: URL, name: String = "speech") throws -> URL? {
        let scriptURL = directory.appendingPathComponent("script.txt")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("\(name).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", output.path, "-f", scriptURL.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else { return nil }
        return output
    }
}

/// A real ~50 MB media file for cancellation tests: 270 s of 32-bit float mono PCM at 48 kHz (51.8 MB), so the
/// import gets past the probe and into the chunked copy.
enum LargeFile {
    static func write(in directory: URL, name: String = "big") async throws -> URL {
        try await TestMedia.tone(frequency: 220, duration: 270, in: directory, name: name).url
    }
}

/// Two solid-colour clips joined into one file, for shot detection.
enum ShotFixture {
    static func twoShots(in directory: URL, seconds: Double = 1) async throws -> URL {
        let red = try await TestMedia.solidColor(.red, duration: seconds, in: directory, name: "red")
        let blue = try await TestMedia.solidColor(.blue, duration: seconds, in: directory, name: "blue")
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for clip in [red, blue] {
            let asset = AVURLAsset(url: clip.url)
            let duration = try await asset.load(.duration)
            try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: cursor)
            cursor = cursor + duration
        }
        let output = directory.appendingPathComponent("two-shots.mov")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else {
            throw TestMedia.Error.imageEncodingFailed
        }
        try await session.export(to: output, as: .mov)
        return output
    }
}

func elapsed(_ started: ContinuousClock.Instant) -> Double {
    let d = started.duration(to: .now)
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
