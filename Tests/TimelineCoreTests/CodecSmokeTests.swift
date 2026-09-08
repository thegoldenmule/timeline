import Foundation
import Testing
import TimelineCore

@Suite struct CodecSmokeTests {
    @Test func operationFlattensWithTypeKey() throws {
        let op = Command.Operation.trimClip(
            .init(clipId: "c1", edge: .head, to: RationalTime(1001, 24000), mode: .ripple))
        let json = String(decoding: try ProjectCodec.encode(op), as: UTF8.self)
        #expect(
            json
                == #"{"clipId":"c1","edge":"head","mode":"ripple","rippleScope":"sequence","to":{"ts":24000,"v":1001},"type":"trimClip","unlinked":false}"#
        )
        let back = try ProjectCodec.decode(Command.Operation.self, from: Data(json.utf8))
        #expect(back == op)
        let minimal = try ProjectCodec.decode(
            Command.Operation.self,
            from: Data(#"{"type":"trimClip","clipId":"c1","edge":"tail","to":{"v":0,"ts":1}}"#.utf8))
        #expect(minimal == .trimClip(.init(clipId: "c1", edge: .tail, to: .zero)))
    }

    @Test func refEncodesAsStringOrRefObject() throws {
        let op = Command.Operation.addTransition(
            .init(leftClipId: "c1", rightClipId: .ref(0), kind: "dissolve", duration: RationalTime(12012, 24000)))
        let json = String(decoding: try ProjectCodec.encode(op), as: UTF8.self)
        #expect(json.contains(#""leftClipId":"c1""#))
        #expect(json.contains(#""rightClipId":{"$ref":0}"#))
        #expect(try ProjectCodec.decode(Command.Operation.self, from: Data(json.utf8)) == op)
    }

    @Test func eventEnvelopeShape() throws {
        let event = DomainEvent(
            eventId: "e1", txnId: "t1", commandId: "k1", actor: .agent(sessionId: "s"),
            occurredAt: Date(timeIntervalSince1970: 1_788_825_600.5),
            payload: .projectRenamed(.init(before: "a", after: "b")))
        let json = String(decoding: try ProjectCodec.encode(event), as: UTF8.self)
        #expect(
            json
                == #"{"actor":"agent:s","commandId":"k1","eventId":"e1","occurredAt":"2026-09-08T00:00:00.500Z","payload":{"after":"b","before":"a"},"schemaVersion":1,"txnId":"t1","type":"ProjectRenamed"}"#
        )
        let back = try ProjectCodec.decode(DomainEvent.self, from: Data(json.utf8))
        #expect(back == event)
    }

    @Test func payloadFieldsJSONAndDecodeRow() throws {
        let payload = EventPayload.markerMoved(
            .init(sequenceId: "s1", markerId: "m1", before: .zero, after: RationalTime(1, 1)))
        let fields = try payload.fieldsJSON()
        #expect(!String(decoding: fields, as: UTF8.self).contains("\"type\""))
        let back = try EventPayload.decode(type: "MarkerMoved", schemaVersion: 1, fieldsJSON: fields)
        #expect(back == payload)
    }

    @Test func actorStrings() throws {
        #expect(Actor("agent:abc") == .agent(sessionId: "abc"))
        #expect(Actor("human") == .human)
        #expect(Actor("bogus") == nil)
        #expect(String(decoding: try ProjectCodec.encode(Actor.system), as: UTF8.self) == "\"system\"")
    }
}
