import Contracts
import Foundation

/// WebVTT: the `WEBVTT` header, then `HH:MM:SS.mmm --> HH:MM:SS.mmm` cues separated by blank lines.
public enum VTTWriter {
    public static let header = "WEBVTT"

    public static func text(for cues: [CaptionCue]) -> String {
        var lines: [String] = [header, ""]
        for cue in CaptionTiming.normalize(cues) {
            lines.append(
                "\(CaptionTiming.timestamp(cue.startMs, separator: ".")) --> \(CaptionTiming.timestamp(cue.endMs, separator: "."))"
            )
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func data(for cues: [CaptionCue]) -> Data { Data(text(for: cues).utf8) }
}
