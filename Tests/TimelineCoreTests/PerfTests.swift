import Foundation
import Testing
import TimelineCore

@Suite struct PerfTests {
    /// Folds 10,000 events with the `inout` form and prints the time. No bound is asserted in debug;
    /// the storage design expects about 45 ms in release for this fold.
    @Test func foldTenThousandEvents() throws {
        let b = try ProjectFixtures.empty()
        let asset = try b.importAsset(name: "cam.mov", duration: RationalTime.frames(100_000, of: fd24))
        let v = b.v1
        var events: [DomainEvent] = []
        var clipIds: [ClipID] = []
        for i in 0..<5000 {
            let id = ClipID(minting: b.ids)
            clipIds.append(id)
            let clip = Clip(
                id: id, trackId: v, assetId: asset, start: RationalTime.frames(Int64(i) * 10, of: fd24),
                sourceIn: .zero, sourceOut: RationalTime.frames(10, of: fd24))
            events.append(
                DomainEvent(
                    eventId: EventID(minting: b.ids), txnId: "t", commandId: "c", actor: .human,
                    occurredAt: b.clock.now(),
                    payload: .clipAdded(.init(sequenceId: b.sequenceId, clipId: id, snapshot: clip))))
        }
        for (i, id) in clipIds.enumerated() {
            let start = RationalTime.frames(Int64(i) * 10, of: fd24)
            events.append(
                DomainEvent(
                    eventId: EventID(minting: b.ids), txnId: "t", commandId: "c", actor: .human,
                    occurredAt: b.clock.now(),
                    payload: .clipMoved(
                        .init(
                            sequenceId: b.sequenceId, clipId: id, before: ClipPlacement(trackId: v, start: start),
                            after: ClipPlacement(trackId: v, start: start + RationalTime.frames(1, of: fd24))))))
        }
        #expect(events.count == 10_000)
        var state = b.project
        let clock = ContinuousClock()
        let elapsed = clock.measure { evolve(&state, events) }
        print("evolve(&state, 10,000 events): \(elapsed)")
        #expect(state.version == b.project.version + 10_000)
        #expect(state.sequences[b.sequenceId]?.tracks[0].clips.count == 5000)
        try Invariants.check(state)
        let encodeTime = clock.measure { _ = try? state.canonicalJSON() }
        print("canonicalJSON of a 5,000-clip project: \(encodeTime)")
    }
}
