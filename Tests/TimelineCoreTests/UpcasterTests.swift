import Foundation
import Testing
import TimelineCore

@Suite struct UpcasterTests {
    @Test func currentVersionsAreStampedByDecide() throws {
        let s = try Scene()
        let c = try s.video(at: 0, length: 10)
        let events = try s.b.apply(.removeClip(.init(clipId: .id(c))))
        #expect(events.allSatisfy { $0.schemaVersion == Upcaster.currentSchemaVersion })
        guard case .clipRemoved(let p) = events[0].payload else { return }
        #expect(p.clipSchema == Upcaster.currentClipSchema)
    }

    @Test func clipTrimmedV0RenamesFromToToBeforeAfter() throws {
        let v0 = """
            {"sequenceId":"s1","clipId":"c1","edge":"tail",
             "from":{"start":{"v":0,"ts":1},"sourceIn":{"v":0,"ts":1},"sourceOut":{"v":10,"ts":1}},
             "to":{"start":{"v":0,"ts":1},"sourceIn":{"v":0,"ts":1},"sourceOut":{"v":5,"ts":1}}}
            """
        let payload = try EventPayload.decode(type: "ClipTrimmed", schemaVersion: 0, fieldsJSON: Data(v0.utf8))
        guard case .clipTrimmed(let p) = payload else {
            Issue.record("wrong payload")
            return
        }
        #expect(p.before.sourceOut == RationalTime(10, 1))
        #expect(p.after.sourceOut == RationalTime(5, 1))
        // Direct use of the registry.
        let raw = try ProjectCodec.decode(JSONValue.self, from: Data(v0.utf8))
        let lifted = Upcaster.upcast(type: "ClipTrimmed", version: 0, payload: raw)
        #expect(lifted["before"] != nil && lifted["from"] == nil)
        // A payload already at the current version is untouched.
        #expect(Upcaster.upcast(type: "ClipTrimmed", version: 1, payload: raw) == raw)
    }

    @Test func embeddedClipSnapshotsUpcastRecursively() throws {
        let clipV0 = """
            {"id":"c1","trackId":"t1","start":{"v":0,"ts":1},"in":{"v":0,"ts":1},"out":{"v":10,"ts":1},
             "speed":{"num":1,"den":1},"transform":{"constant":{"x":0,"y":0,"scale":1,"rotation":0,"anchorX":0.5,"anchorY":0.5}},
             "opacity":{"constant":1},"effects":[],"audio":{"gain":{"constant":1},"muted":false,"pitchCorrected":true}}
            """
        let added = #"{"sequenceId":"s1","clipId":"c1","clipSchema":0,"snapshot":\#(clipV0)}"#
        let payload = try EventPayload.decode(type: "ClipAdded", schemaVersion: 1, fieldsJSON: Data(added.utf8))
        guard case .clipAdded(let p) = payload else {
            Issue.record("wrong payload")
            return
        }
        #expect(p.snapshot.sourceOut == RationalTime(10, 1))
        #expect(p.clipSchema == Upcaster.currentClipSchema)

        // Arrays of clips and a track snapshot recurse too.
        let replaced = #"{"sequenceId":"s1","trackId":"t1","clipSchema":0,"before":[\#(clipV0)],"after":[]}"#
        guard
            case .captionsReplaced(let r) = try EventPayload.decode(
                type: "CaptionsReplaced", schemaVersion: 1, fieldsJSON: Data(replaced.utf8))
        else {
            Issue.record("wrong payload")
            return
        }
        #expect(r.before[0].sourceIn == .zero && r.clipSchema == 1)
        let track = #"{"id":"t1","kind":"video","name":"V1","muted":false,"locked":false,"clips":{"c1":\#(clipV0)}}"#
        let removed = #"{"sequenceId":"s1","trackId":"t1","position":0,"clipSchema":0,"snapshot":\#(track)}"#
        guard
            case .trackRemoved(let t) = try EventPayload.decode(
                type: "TrackRemoved", schemaVersion: 1, fieldsJSON: Data(removed.utf8))
        else {
            Issue.record("wrong payload")
            return
        }
        #expect(t.snapshot.clips["c1"]?.sourceOut == RationalTime(10, 1))

        // The full envelope path upcasts on decode and reports the current version.
        let envelope = """
            {"eventId":"e1","txnId":"t1","commandId":"k1","actor":"human","occurredAt":"2026-09-08T00:00:00.000Z",
             "schemaVersion":1,"type":"ClipAdded","payload":\(added)}
            """
        let event = try ProjectCodec.decode(DomainEvent.self, from: Data(envelope.utf8))
        #expect(event.schemaVersion == Upcaster.currentSchemaVersion)
        guard case .clipAdded(let q) = event.payload else { return }
        #expect(q.snapshot.sourceOut == RationalTime(10, 1) && q.clipSchema == Upcaster.currentClipSchema)
    }

    @Test func customRegistryStepsApplyInOrder() {
        var registry = Upcaster.Registry()
        registry.register(type: "Custom", from: 0) { p in
            var q = p
            q["a"] = 1
            return q
        }
        registry.registerEmbedded(type: "Custom", [.clip(key: "snap")])
        registry.registerClip(from: 0) { c in
            var d = c
            d["lifted"] = true
            return d
        }
        let payload: JSONValue = ["clipSchema": 0, "snap": ["id": "c"]]
        let out = Upcaster.upcast(type: "Custom", version: 0, payload: payload, registry: registry)
        #expect(out["a"] == 1)
        #expect(out["snap"]?["lifted"] == true)
        #expect(out["clipSchema"] == 1)
        #expect(Upcaster.upcast(type: "Unknown", version: 0, payload: payload, registry: registry) == payload)
    }
}
