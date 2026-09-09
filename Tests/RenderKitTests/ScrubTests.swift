import AVFoundation
import Contracts
import ContractsTestSupport
import Foundation
import RenderKit
import Testing
import TimelineCore

/// Scrubbing at 30 seeks per second for 5 s must not grow resident memory, must leave no request in flight,
/// and must let the compositor instances go when their items go.
@Suite(.serialized) struct ScrubTests {
    @Test @MainActor func scrubbingDoesNotGrowMemoryOrLeakCompositors() async throws {
        let h = try await LatencyHarness(clipCount: 200)
        let renderer = h.scene.renderer()
        let compiled = try await renderer.compile(h.sequence, assets: h.projectAssets, options: .gesture)
        let countBefore = TimelineCompositor.liveInstances.count

        // The player and item live in this scope only, so the compositor can be released afterwards.
        func session() async throws {
            let item = renderer.playerItem(for: compiled)
            let output = bgraOutput()
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            #expect(await waitUntilReady(item))
            var rng = SeededRandom(seed: 7)

            func scrub(seconds: Double, label: String) async throws -> (frames: Int, seeks: Int) {
                var frames = 0
                var seeks = 0
                let start = ContinuousClock.now
                let period = Duration.milliseconds(1000.0 / 30)
                let deadline = start + .seconds(seconds)
                while ContinuousClock.now < deadline {
                    let target = CMTime(value: Int64.random(in: 0..<6000, using: &rng), timescale: 30)
                    // Fire and forget: the next seek cancels this one's pending composition requests.
                    item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                    seeks += 1
                    let next = start + period * seeks
                    while ContinuousClock.now < next {
                        let now = item.currentTime()
                        if output.hasNewPixelBuffer(forItemTime: now),
                            output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) != nil
                        {
                            frames += 1
                        }
                        try await Task.sleep(for: .milliseconds(1))
                    }
                }
                print("[scrub] \(label): \(seeks) seeks, \(frames) frames in \(seconds) s")
                return (frames, seeks)
            }

            _ = try await scrub(seconds: 2, label: "warm-up")
            let before = residentMemory()
            let run = try await scrub(seconds: 5, label: "measured")
            let after = residentMemory()
            let growth = Double(Int64(after) - Int64(before)) / Double(1 << 20)
            print(
                "[scrub] resident memory before \(before >> 20) MB, after \(after >> 20) MB, growth \(fmt(growth)) MB")
            #expect(run.seeks >= 145, "30 seeks per second: \(run.seeks)")
            #expect(run.frames > 30, "frames kept arriving while scrubbing")
            #expect(growth < 64 * debugSlack, "resident memory grew \(fmt(growth)) MB")

            // This item's compositor is the one that rendered for this `Compiled` (other suites run in parallel).
            let mine = TimelineCompositor.liveInstances.filter { $0.statistics.compiledIds.contains(compiled.id) }
            #expect(mine.count == 1, "one compositor per item: \(mine.count)")
            #expect(mine.allSatisfy { $0.statistics.inFlight == 0 }, "no composition request left in flight")
            let framesComposed = mine.map(\.statistics.frames).reduce(0, +)
            print(
                "[scrub] compositors for this item \(mine.count), frames composed \(framesComposed), alive overall \(TimelineCompositor.liveInstances.count)"
            )
            #expect(framesComposed >= run.frames)
            player.replaceCurrentItem(with: nil)
        }
        try await session()

        // Dropping the item drops its compositor: nothing leaks through the registry.
        func stillAlive() -> Int {
            TimelineCompositor.liveInstances.filter { $0.statistics.compiledIds.contains(compiled.id) }.count
        }
        var remaining = stillAlive()
        for _ in 0..<100 where remaining > 0 {
            try await Task.sleep(for: .milliseconds(20))
            remaining = stillAlive()
        }
        print("[scrub] compositors alive before the session \(countBefore), this item's after release \(remaining)")
        #expect(remaining == 0, "the scrubbed item's compositor was released")
    }
}
