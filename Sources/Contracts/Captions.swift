import Foundation
import TimelineCore

/// Timeline-relative cues from a caption track: one per caption clip, `start = clip.start`,
/// `end = sequence.end(of: clip)` (frame-rounded, the way the sequence places the clip), text =
/// `clip.text`, sorted by start then end, empty texts and zero-length clips skipped. Never built from
/// the raw transcript: transcript times are media-relative and wrong after any cut (publish-plan.md D7).
public enum CaptionCues {
    public static func make(from track: Track, in sequence: Sequence) -> [CaptionCue] {
        guard track.kind == .caption else { return [] }
        return track.clips.values.compactMap { clip -> CaptionCue? in
            guard let text = clip.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let end = sequence.end(of: clip)
            guard end > clip.start else { return nil }
            return CaptionCue(start: clip.start, end: end, text: text)
        }.sorted { a, b in a.start != b.start ? a.start < b.start : a.end < b.end }
    }

    /// Every caption track of the sequence as a `PublishCaptionTrack`, in track order, skipping tracks
    /// without cues. Language falls back to `defaultLanguage`; the name is the track name.
    public static func tracks(in sequence: Sequence, format: CaptionFormat = .srt, defaultLanguage: String = "en")
        -> [PublishCaptionTrack]
    {
        sequence.tracks.filter { $0.kind == .caption }.compactMap { track in
            let cues = make(from: track, in: sequence)
            guard !cues.isEmpty else { return nil }
            return PublishCaptionTrack(
                trackId: track.id, language: track.language ?? defaultLanguage, name: track.name, format: format,
                cues: cues)
        }
    }
}
