import Foundation
import Testing
import TimelineCore

@Suite struct IdentifierTests {
    @Test func uuidv7IsValidAndMonotonic() {
        let gen = UUIDv7Generator()
        var previous = ""
        for _ in 0..<2000 {
            let id = gen.next()
            #expect(id.isCanonicalUUID)
            #expect(id[id.index(id.startIndex, offsetBy: 14)] == "7")
            let variant = id[id.index(id.startIndex, offsetBy: 19)]
            #expect("89ab".contains(variant))
            #expect(id > previous, "ids must be strictly increasing: \(previous) then \(id)")
            previous = id
        }
        // Timestamp field is close to now.
        let hex = String(gen.next().prefix(13).filter { $0 != "-" })
        let millis = UInt64(hex, radix: 16)!
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        #expect(millis <= now + 5 && millis > now - 60_000)
    }

    @Test func uuidv7MonotonicAcrossThreads() async {
        let gen = UUIDv7Generator()
        let ids = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<8 {
                group.addTask { (0..<500).map { _ in gen.next() } }
            }
            var all: [String] = []
            for await batch in group { all += batch }
            return all
        }
        #expect(Set(ids).count == ids.count)
    }

    @Test func sequentialGeneratorIsDeterministicAndSortable() {
        let a = SequentialIDGenerator()
        let b = SequentialIDGenerator()
        let ids = (0..<5).map { _ in a.next() }
        #expect(ids == (0..<5).map { _ in b.next() })
        #expect(ids == ids.sorted())
        #expect(ids[0] == "00000000-0000-7000-8000-000000000001")
        #expect(ids.allSatisfy { $0.isCanonicalUUID })
    }

    @Test func typedIdsAreStringsInJSON() throws {
        let id: ClipID = "00000000-0000-7000-8000-000000000042"
        let data = try ProjectCodec.encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"00000000-0000-7000-8000-000000000042\"")
        #expect(try ProjectCodec.decode(ClipID.self, from: data) == id)
        #expect(ClipID.kind == "clip")
        #expect(id.description == id.rawValue)
        let minted = TrackID(minting: SequentialIDGenerator(start: 7))
        #expect(minted.rawValue.hasSuffix("000000000007"))
    }

    @Test func idKeyedDictionariesEncodeAsObjects() throws {
        let dict: [ClipID: Int] = ["a": 1, "b": 2]
        let data = try ProjectCodec.encode(dict)
        #expect(String(decoding: data, as: UTF8.self) == #"{"a":1,"b":2}"#)
        #expect(try ProjectCodec.decode([ClipID: Int].self, from: data) == dict)
    }

    @Test func clocks() {
        let fixed = FixedClock(Date(timeIntervalSince1970: 100), step: 1)
        #expect(fixed.now() == Date(timeIntervalSince1970: 100))
        #expect(fixed.now() == Date(timeIntervalSince1970: 101))
        #expect(abs(SystemClock().now().timeIntervalSinceNow) < 1)
    }
}
