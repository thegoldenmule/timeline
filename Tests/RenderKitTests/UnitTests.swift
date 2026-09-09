import AVFoundation
import Contracts
import CoreMedia
import Foundation
import RenderKit
import Testing
import TimelineCore

@Suite struct TimeConversionTests {
    @Test func rationalTimeRoundTripsThroughCMTime() {
        let t = RationalTime(1001, 24000)
        let cm = CMTime(t)
        #expect(cm.value == 1001 && cm.timescale == 24000 && cm.isNumeric)
        #expect(RationalTime(cm) == t)
        #expect(RationalTime(exactly: .invalid) == nil)
        #expect(RationalTime(exactly: .positiveInfinity) == nil)
        #expect(RationalTime(exactly: .indefinite) == nil)
        #expect(RationalTime(exactly: CMTime(value: 3, timescale: 600)) == RationalTime(3, 600))
        let negative = RationalTime(-5, 48000)
        #expect(RationalTime(CMTime(negative)) == negative)
    }

    @Test func timeRangeRoundTrips() {
        let range = TimeRange(start: RationalTime(1, 2), end: RationalTime(3, 4))
        let cm = CMTimeRange(range)
        #expect(cm.start == CMTime(value: 1, timescale: 2))
        #expect(cm.end == CMTime(value: 3, timescale: 4))
        #expect(TimeRange(exactly: cm) == range)
        #expect(TimeRange(exactly: CMTimeRange(start: .zero, duration: .indefinite)) == nil)
    }
}

@Suite struct InstructionTableTests {
    private func table(_ starts: [Int64]) -> InstructionTable {
        let instructions = zip(starts, starts.dropFirst()).map { a, b in
            RenderInstruction(
                timeRange: CMTimeRange(start: CMTime(value: a, timescale: 30), end: CMTime(value: b, timescale: 30)),
                layers: [], transitions: [:], captions: [], blendSpace: .gamma, hdr: false,
                sequenceSize: CGSize(width: 16, height: 9))
        }
        return InstructionTable(instructions)
    }

    @Test func lookupByTimeIsExactOnBoundaries() {
        let t = table([0, 30, 45, 90, 120])
        #expect(t.count == 4)
        #expect(t.duration == CMTime(value: 120, timescale: 30))
        func start(_ frames: Int64) -> Int64? {
            t.instruction(at: CMTime(value: frames, timescale: 30))?.timeRange.start.value
        }
        #expect(start(0) == 0)
        #expect(start(29) == 0)
        #expect(start(30) == 30)
        #expect(start(44) == 30)
        #expect(start(45) == 45)
        #expect(start(89) == 45)
        #expect(start(119) == 90)
        #expect(start(120) == 90, "the end time maps to the last instruction")
        #expect(start(121) == nil)
        #expect(start(-1) == nil)
        // Mixed timescale lookups compare exactly.
        #expect(t.instruction(at: CMTime(value: 1, timescale: 1))?.timeRange.start.value == 30)
        #expect(
            t.instructions(
                in: CMTimeRange(start: CMTime(value: 40, timescale: 30), end: CMTime(value: 100, timescale: 30))
            ).count == 3)
        #expect(InstructionTable([]).instruction(at: .zero) == nil)
    }

    @Test func lookupIsLogarithmic() {
        // 100,000 instructions: a linear scan would be visible; 10,000 lookups must stay in the low milliseconds.
        let starts = (0...100_000).map { Int64($0) }
        let t = table(starts)
        let t0 = ContinuousClock.now
        var hits = 0
        for i in stride(from: 0, to: 100_000, by: 10) {
            if t.instruction(at: CMTime(value: Int64(i), timescale: 30)) != nil { hits += 1 }
        }
        let elapsed = ms(t0)
        print("[table] 10,000 lookups over 100,000 instructions: \(fmt(elapsed)) ms")
        #expect(hits == 10_000)
        #expect(elapsed < 200 * debugSlack)
    }

    @Test func requiredTrackIDsAndTweeningFollowTheLayers() {
        let layer = LayerSpec(
            clipId: "c1", trackIndex: 0, content: .source(trackID: 7), clipStart: .zero,
            transform: .constant(.identity),
            opacity: .constant(1))
        let slate = LayerSpec(
            clipId: "c2", trackIndex: 1, content: .slate(label: "x"), clipStart: .zero, transform: .constant(.identity),
            opacity: .constant(1))
        let plain = RenderInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), layers: [layer, slate],
            transitions: [:], captions: [], blendSpace: .gamma, hdr: false, sequenceSize: CGSize(width: 16, height: 9))
        #expect(plain.sourceTrackIDs == [7])
        #expect(!plain.containsTweening)
        #expect(plain.passthroughTrackID == kCMPersistentTrackID_Invalid)
        let animated = LayerSpec(
            clipId: "c3", trackIndex: 0, content: .source(trackID: 7), clipStart: .zero,
            transform: .constant(.identity),
            opacity: .keyframes([Keyframe(t: .zero, value: 1), Keyframe(t: RationalTime(1, 1), value: 0)]))
        let tween = RenderInstruction(
            timeRange: plain.timeRange, layers: [animated], transitions: [:], captions: [], blendSpace: .gamma,
            hdr: false, sequenceSize: CGSize(width: 16, height: 9))
        #expect(tween.containsTweening)
    }
}

@Suite struct ProbeAndPresetTests {
    @Test func fourCCRendersCodes() {
        #expect(RenderKit.fourCC(kCMVideoCodecType_HEVC) == "hvc1")
        #expect(RenderKit.fourCC(kCMVideoCodecType_H264) == "avc1")
        #expect(RenderKit.fourCC(kAudioFormatMPEG4AAC) == "aac ")
        #expect(RenderKit.fourCC(kAudioFormatAPAC) == "apac")
    }
}
