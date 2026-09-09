import Contracts
import Foundation

/// SubRip: numbered cues, `HH:MM:SS,mmm --> HH:MM:SS,mmm`, a blank line after each cue. The most
/// compatible caption format YouTube accepts (publish-plan.md D7).
public enum SRTWriter {
    public static func text(for cues: [CaptionCue]) -> String {
        var lines: [String] = []
        for (index, cue) in CaptionTiming.normalize(cues).enumerated() {
            lines.append(String(index + 1))
            lines.append(
                "\(CaptionTiming.timestamp(cue.startMs, separator: ",")) --> \(CaptionTiming.timestamp(cue.endMs, separator: ","))"
            )
            lines.append(cue.text)
            lines.append("")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func data(for cues: [CaptionCue]) -> Data { Data(text(for: cues).utf8) }
}
