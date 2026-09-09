import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import PublishKit

@Suite struct CaptionWriterTests {
    private func cue(_ start: Double, _ end: Double, _ text: String) -> CaptionCue {
        CaptionCue(
            start: RationalTime(seconds: start, timescale: 1000), end: RationalTime(seconds: end, timescale: 1000),
            text: text)
    }

    @Test func srtFormatsTimingsAndNumbering() {
        let cues = [cue(1.001, 2.502, "Hello there"), cue(3661.25, 3662, "and welcome")]
        let text = SRTWriter.text(for: cues)
        // Each cue block ends with a blank line, the last one included.
        let expected = [
            "1", "00:00:01,001 --> 00:00:02,502", "Hello there", "", "2", "01:01:01,250 --> 01:01:02,000",
            "and welcome", "", "",
        ].joined(separator: "\n")
        #expect(text == expected)
        #expect(text.hasSuffix("and welcome\n\n"))
        // The fixture's frame-based cues: 12 frames at 23.976 is 500.5 ms, floored.
        let fixture = SRTWriter.text(for: Fixtures.captionCues)
        #expect(
            fixture.hasPrefix(
                "1\n00:00:00,500 --> 00:00:02,002\nHello there\n\n2\n00:00:02,502 --> 00:00:04,504\nand welcome\n"))
    }

    @Test func vttHasHeaderAndDotMilliseconds() {
        let text = VTTWriter.text(for: [cue(0.5, 2.0, "Hi"), cue(2.0, 2.75, "there")])
        let expected = [
            "WEBVTT", "", "00:00:00.500 --> 00:00:02.000", "Hi", "", "00:00:02.000 --> 00:00:02.750", "there", "", "",
        ].joined(separator: "\n")
        #expect(text == expected)
        #expect(text.hasPrefix("WEBVTT\n\n") && !text.contains(","))
    }

    @Test func overlappingCuesAreNudged() {
        // The second cue starts inside the first: it is moved to one millisecond after the first ends,
        // and a cue that would then end before it starts gets a one-millisecond span.
        let cues = [
            cue(1.0, 3.0, "first"), cue(2.0, 4.0, "second"), cue(3.0005, 3.0005, "third"), cue(0.0, 0.0, "zero"),
        ]
        let timed = CaptionTiming.normalize(cues)
        #expect(timed.map(\.text) == ["zero", "first", "second", "third"])
        #expect(timed[0].startMs == 0 && timed[0].endMs == 1)
        #expect(timed[1].startMs == 1000 && timed[1].endMs == 3000)
        #expect(timed[2].startMs == 3001 && timed[2].endMs == 4000)
        #expect(timed[3].startMs == 4001 && timed[3].endMs == 4002)
        #expect(zip(timed, timed.dropFirst()).allSatisfy { $0.endMs < $1.startMs })
        #expect(timed.allSatisfy { $0.endMs > $0.startMs })
        // Touching cues are not overlapping and stay put.
        let touching = CaptionTiming.normalize([cue(1, 2, "a"), cue(2, 3, "b")])
        #expect(touching.map(\.startMs) == [1000, 2000] && touching.map(\.endMs) == [2000, 3000])
        let srt = SRTWriter.text(for: cues)
        #expect(srt.contains("00:00:03,001 --> 00:00:04,000\nsecond"))
    }

    @Test func emptyTracksProduceAnEmptyBody() {
        #expect(SRTWriter.text(for: []) == "")
        #expect(SRTWriter.data(for: []).isEmpty)
        #expect(VTTWriter.text(for: []) == "WEBVTT\n\n")
        // Blank cues are dropped too.
        #expect(SRTWriter.text(for: [cue(1, 2, "   "), cue(2, 3, "\n")]) == "")
        #expect(VTTWriter.text(for: [cue(1, 2, "")]) == "WEBVTT\n\n")
    }
}
