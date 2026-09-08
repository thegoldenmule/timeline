import Foundation
import Testing
import TimelineCore

@Suite struct CodableRoundTripTests {
    @Test func everyOperationRoundTrips() throws {
        let ops = ProjectFixtures.exampleOperations()
        #expect(Set(ops.map(\.typeName)) == Set(Command.Operation.allTypeNames))
        #expect(ops.count == Command.Operation.allTypeNames.count)
        for op in ops {
            let data = try ProjectCodec.encode(op)
            let back = try ProjectCodec.decode(Command.Operation.self, from: data)
            #expect(back == op, "\(op.typeName)")
            #expect(try ProjectCodec.encode(back) == data, "\(op.typeName) is byte stable")
            let json = try ProjectCodec.decode(JSONValue.self, from: data)
            #expect(json["type"]?.stringValue == op.typeName)
        }
        let command = Command(
            commandId: "command-1", actor: .agent(sessionId: "s"), expectedVersion: 7, label: "Batch",
            operation: .batch(ops))
        let data = try ProjectCodec.encode(command)
        #expect(try ProjectCodec.decode(Command.self, from: data) == command)
    }

    @Test func everyEventRoundTrips() throws {
        let events = ProjectFixtures.exampleEvents()
        #expect(Set(events.keys) == Set(EventPayload.allTypeNames))
        for (type, event) in events {
            let data = try ProjectCodec.encode(event)
            let back = try ProjectCodec.decode(DomainEvent.self, from: data)
            #expect(back == event, "\(type)")
            #expect(try ProjectCodec.encode(back) == data, "\(type) is byte stable")
            let json = try ProjectCodec.decode(JSONValue.self, from: data)
            #expect(json["type"]?.stringValue == type)
            #expect(json["payload"]?["type"] == nil)
            if let sid = event.payload.sequenceId {
                #expect(json["payload"]?["sequenceId"]?.stringValue == sid.rawValue)
            }
            // The payload alone (with its own type key) also round-trips.
            let pdata = try ProjectCodec.encode(event.payload)
            #expect(try ProjectCodec.decode(EventPayload.self, from: pdata) == event.payload)
            // Store row form: type + schemaVersion + fields.
            let row = try EventPayload.decode(
                type: type, schemaVersion: event.schemaVersion, fieldsJSON: try event.payload.fieldsJSON())
            #expect(row == event.payload)
        }
        let list = Array(events.values)
        #expect(try ProjectCodec.decode([DomainEvent].self, from: try ProjectCodec.encode(list)) == list)
    }

    @Test func everyEventIsInvertibleOrAMarkerOrCreation() {
        for (type, event) in ProjectFixtures.exampleEvents() {
            let inverse = invert(event)
            switch event.payload {
            case .projectCreated, .sequenceAdded, .transactionUndone, .transactionRedone:
                #expect(inverse.isEmpty, "\(type)")
            default:
                #expect(inverse.count == 1, "\(type)")
                // Inverting twice yields the original payload, except for the three "added" events whose
                // inverse's inverse is the corresponding "restored" event.
                if let once = inverse.first, !["TrackAdded", "CaptionTrackAdded", "AssetImported"].contains(type) {
                    #expect(invert(once) == [event.payload], "\(type)")
                }
            }
        }
    }

    @Test func projectCanonicalEncodingIsByteStable() throws {
        let project = try ProjectGenerator(seed: 42).generate()
        let a = try project.canonicalJSON()
        let b = try project.canonicalJSON()
        #expect(a == b)
        let decoded = try Project.fromJSON(a)
        #expect(decoded == project)
        #expect(try decoded.canonicalJSON() == a)
        // Insertion order into dictionaries does not change the bytes.
        var reordered = project
        let seq = reordered.sequences.values.first!
        var shuffledTrack = seq.tracks[0]
        let clips = Array(shuffledTrack.clips.values.reversed())
        shuffledTrack.clips = [:]
        for c in clips { shuffledTrack.clips[c.id] = c }
        reordered.sequences[seq.id]!.tracks[0] = shuffledTrack
        #expect(try reordered.canonicalJSON() == a)
        #expect(!String(decoding: a, as: UTF8.self).contains("\\/"))
    }

    @Test func jsonValueRoundTripsNumbersAndNesting() throws {
        let value: JSONValue = ["a": 1, "b": 2.5, "c": [true, nil, "x"], "d": ["e": 12345678901234]]
        let data = try ProjectCodec.encode(value)
        #expect(
            String(decoding: data, as: UTF8.self) == #"{"a":1,"b":2.5,"c":[true,null,"x"],"d":{"e":12345678901234}}"#)
        #expect(try ProjectCodec.decode(JSONValue.self, from: data) == value)
        #expect(value["d"]?["e"]?.intValue == 12_345_678_901_234)
        #expect(value["c"]?[0]?.boolValue == true)
        #expect(try JSONValue(encoding: RationalTime(1, 2)) == ["v": 1, "ts": 2])
        #expect(try JSONValue(encoding: RationalTime(1, 2)).decoded(as: RationalTime.self) == RationalTime(1, 2))
    }

    @Test func animatableShapes() throws {
        let c: Animatable<Double> = .constant(1)
        #expect(String(decoding: try ProjectCodec.encode(c), as: UTF8.self) == #"{"constant":1}"#)
        let k: Animatable<Double> = .keyframes([.init(t: .zero, value: 0, easing: .hold)])
        let data = try ProjectCodec.encode(k)
        #expect(
            String(decoding: data, as: UTF8.self) == #"{"keyframes":[{"easing":"hold","t":{"ts":1,"v":0},"value":0}]}"#)
        #expect(try ProjectCodec.decode(Animatable<Double>.self, from: data) == k)
        #expect(throws: DecodingError.self) { try ProjectCodec.decode(Animatable<Double>.self, from: Data("{}".utf8)) }
    }

    @Test func alignmentParametersHaveSpikeDefaults() throws {
        let p = AlignmentParameters()
        #expect(p.envelopeSampleRate == 8000)
        #expect(p.bandpassLowHz == 300 && p.bandpassHighHz == 3000)
        #expect(p.envelopeHop == 128 && p.envelopeWindow == 512)
        #expect(p.fineWindowSeconds == 10 && p.fineWindowCount == 24)
        #expect(p.inlierToleranceMs == 0.5 && p.minimumInlierFraction == 0.6 && p.maxFitMADMs == 0.5)
        #expect(p.candidateCutoffRatio == 0.5 && p.maxCandidates == 5)
        let data = try ProjectCodec.encode(p)
        #expect(try ProjectCodec.decode(AlignmentParameters.self, from: data) == p)
        #expect(ProjectSettings().alignment == p)
    }
}
