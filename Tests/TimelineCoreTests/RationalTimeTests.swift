import Foundation
import Testing
import TimelineCore

@Suite struct RationalTimeTests {
    let fd24 = RationalTime(1001, 24000)
    let fd30 = RationalTime(1001, 30000)

    @Test func equalityCrossMultiplies() {
        #expect(RationalTime(1, 2) == RationalTime(2, 4))
        #expect(RationalTime(1, 2) != RationalTime(2, 3))
        #expect(RationalTime(1, 2).hashValue == RationalTime(2, 4).hashValue)
        #expect(RationalTime(48000, 48000) == RationalTime(24000, 24000))
    }

    @Test func comparisonMixedTimescales() {
        #expect(RationalTime(1001, 24000) < RationalTime(1001, 23999))
        #expect(RationalTime(1, 3) < RationalTime(1, 2))
        #expect(RationalTime(-1, 2) < RationalTime(0, 1))
        #expect(!(RationalTime(1, 2) < RationalTime(2, 4)))
        #expect(RationalTime.max(RationalTime(1, 2), RationalTime(2, 3)) == RationalTime(2, 3))
    }

    @Test func comparisonSurvivesLargeValues() {
        // Values near Int64.max would overflow a 64-bit cross multiplication.
        let a = RationalTime(Int64.max / 2, Int32.max)
        let b = RationalTime(Int64.max / 2 - 1, Int32.max)
        #expect(b < a)
        #expect(a > b)
        let c = RationalTime(Int64.max / 3, Int32.max - 1)
        #expect(c < a)
    }

    @Test func additionSameTimescale() {
        let sum = fd24 + fd24
        #expect(sum == RationalTime(2002, 24000))
        #expect(sum.timescale == 24000)
    }

    @Test func additionUsesLCM() {
        let sum = RationalTime(1, 24000) + RationalTime(1, 48000)
        #expect(sum.timescale == 48000)
        #expect(sum.value == 3)
        let mixed = RationalTime(1001, 24000) + RationalTime(1, 44100)
        #expect(mixed.timescale == 3_528_000)
        #expect(mixed == RationalTime(1001 * 147 + 80, 3_528_000))
    }

    @Test func subtractionIsExact() {
        let d = RationalTime(48048, 48000) - RationalTime(1001, 24000)
        #expect(d == RationalTime(46046, 48000))
        #expect((fd24 - fd24).isZero)
        #expect((RationalTime.zero - fd24).isNegative)
    }

    @Test func fallsBackToReducedFractionWhenLCMOverflows() {
        // Coprime timescales whose product exceeds Int32: 1/2 + 1/3 expressed at 100000 and 99999.
        let a = RationalTime(50000, 100_000)
        let b = RationalTime(33333, 99999)
        let sum = a + b
        #expect(sum == RationalTime(5, 6))
        #expect(sum.timescale == 6)
        #expect(sum.value == 5)
    }

    @Test func speedMultiplyDivide() {
        let dur = RationalTime(48048, 48000)
        #expect(dur / Rational(2, 1) == RationalTime(24024, 48000))
        #expect(dur * Rational(1, 2) == RationalTime(24024, 48000))
        #expect(dur * Rational(3, 2) == RationalTime(72072, 48000))
        let odd = RationalTime(1, 3) * Rational(1, 2)
        #expect(odd == RationalTime(1, 6))
        #expect(RationalTime(1001, 24000) / Rational(1001, 1000) == RationalTime(1000, 24000))
        #expect(RationalTime(10, 1) * 3 == RationalTime(30, 1))
        #expect(RationalTime(10, 1) / 4 == RationalTime(5, 2))
    }

    @Test func rescaleExactOrNil() {
        #expect(RationalTime(1001, 24000).rescaled(to: 48000) == RationalTime(2002, 48000))
        #expect(RationalTime(1001, 24000).rescaled(to: 1000) == nil)
        #expect(RationalTime(1, 2).reduced == RationalTime(1, 2))
        #expect(RationalTime(2002, 48000).reduced == RationalTime(1001, 24000))
        #expect(RationalTime(2002, 48000).reduced.timescale == 24000)
    }

    @Test func snappingNearestFloorCeil() {
        let t = RationalTime(1600, 48000)  // 1.6 frames of 1001/48000? use 24fps: 1001/24000 = 2002/48000
        let f = RationalTime(1001, 24000)
        #expect(t.snapped(to: f) == RationalTime(1001, 24000))
        #expect(t.floored(to: f) == RationalTime.zero)
        #expect(t.ceiled(to: f) == RationalTime(1001, 24000))
        // exactly half way rounds up
        let half = RationalTime(1001, 48000)
        #expect(half.snapped(to: f) == f)
        // already aligned is a fixed point
        let aligned = RationalTime.frames(10, of: f)
        #expect(aligned.snapped(to: f) == aligned)
        #expect(aligned.floored(to: f) == aligned)
        #expect(aligned.ceiled(to: f) == aligned)
        // negatives
        let neg = RationalTime(-1, 48000)
        #expect(neg.snapped(to: f) == .zero)
        #expect(neg.floored(to: f) == -f)
        #expect(neg.ceiled(to: f) == .zero)
        #expect(neg.frameIndex(frameDuration: f) == -1)
    }

    @Test func frameAlignment() {
        #expect(RationalTime(2002, 48000).isFrameAligned(frameDuration: fd24))
        #expect(!RationalTime(2003, 48000).isFrameAligned(frameDuration: fd24))
        #expect(RationalTime.zero.isFrameAligned(frameDuration: fd24))
        #expect(RationalTime.frames(24, of: fd24).isFrameAligned(frameDuration: fd24))
        #expect(!RationalTime.frames(1, of: fd24).isFrameAligned(frameDuration: fd30))
        #expect(RationalTime.frames(30, of: fd30) == RationalTime.frames(24, of: fd24))
        #expect(RationalTime.frames(10, of: fd24).frameIndex(frameDuration: fd24) == 10)
    }

    @Test func ratioAndSeconds() {
        #expect(RationalTime(48048, 48000).ratio(to: fd24) == Rational(24, 1))
        #expect(RationalTime(1, 2).seconds == 0.5)
        #expect(RationalTime(seconds: 1.5, timescale: 48000) == RationalTime(72000, 48000))
        #expect(RationalTime(3, 4).description == "3/4")
    }

    @Test func codableShape() throws {
        let data = try ProjectCodec.encode(RationalTime(1001, 24000))
        #expect(String(decoding: data, as: UTF8.self) == #"{"ts":24000,"v":1001}"#)
        let back = try ProjectCodec.decode(RationalTime.self, from: data)
        #expect(back == RationalTime(1001, 24000))
        #expect(throws: DecodingError.self) {
            try ProjectCodec.decode(RationalTime.self, from: Data(#"{"ts":0,"v":1}"#.utf8))
        }
    }

    @Test func rationalBasics() throws {
        #expect(Rational(1, 2) == Rational(2, 4))
        #expect(Rational(1, 2) < Rational(2, 3))
        #expect(Rational(-1, -2) == Rational(1, 2))
        #expect(Rational(2, -4).den == 4)
        #expect(Rational(2, 3) * Rational(3, 4) == Rational(1, 2))
        #expect(Rational(1, 2).inverse == Rational(2, 1))
        let data = try ProjectCodec.encode(Rational(3, 2))
        #expect(String(decoding: data, as: UTF8.self) == #"{"den":2,"num":3}"#)
        #expect(try ProjectCodec.decode(Rational.self, from: data) == Rational(3, 2))
    }
}
