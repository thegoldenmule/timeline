import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import QuartzCore
import Testing
import TimelineCore

@testable import TimelineUI

@MainActor
@Suite("Frame time at 1,000 clips")
struct BenchmarkTests {
    /// The bound the median frame must stay under. Release is the real target (16.7 ms for 60 fps);
    /// debug builds of TimelineCore's 128-bit arithmetic are several times slower, so the bound is loose.
    static var bound: Double {
        #if DEBUG
            50
        #else
            16
        #endif
    }

    /// Generates off the main actor so the other suites' polling keeps running meanwhile.
    static func thousandClipsStore() async throws -> FakeProjectStore {
        try await Task.detached {
            var gen = ProjectGenerator(seed: 1000)
            gen.videoTracks = 4...4
            gen.audioTracks = 2...2
            gen.clipsPerTrack = 250...250
            gen.assetCount = 4...4
            return FakeProjectStore(builder: try gen.builder())
        }.value
    }

    @Test func rendersSixtyFramesAtFiveZoomLevels() async throws {
        let generated = CACurrentMediaTime()
        let store = try await BenchmarkTests.thousandClipsStore()
        let vm = TimelineViewModel(store: store)
        await vm.load()
        vm.viewSize = CGSize(width: 1600, height: 600)
        let seq = vm.sequence!
        let clipCount = seq.tracks.reduce(0) { $0 + $1.clips.count }
        print("benchmark: generated \(clipCount) clips in \(Int((CACurrentMediaTime() - generated) * 1000)) ms")
        #expect(clipCount >= 1000)
        let end = seq.tracks.flatMap { $0.clips.values }.map { seq.end(of: $0).seconds }.max() ?? 0
        let renderer = try TimelineRenderer()
        // Select and place the playhead so overlays are part of every frame.
        vm.selection = Set(seq.tracks[0].clips.keys.prefix(20))
        vm.setPlayhead(RationalTime(seconds: end / 2))

        var report: [String] = []
        #if DEBUG
            report.append("configuration: debug (bound \(BenchmarkTests.bound) ms)")
        #else
            report.append("configuration: release (bound \(BenchmarkTests.bound) ms)")
        #endif
        for zoom in 0..<5 {
            vm.setZoom(index: zoom)
            let visible = Double(vm.layout.trackAreaWidth) * vm.secondsPerPoint
            vm.scrollSeconds = max(0, end / 2 - visible / 2)
            for _ in 0..<5 { _ = try renderer.render(scene: TimelineSceneBuilder.build(from: vm)) }
            var times: [Double] = []
            var drawn = 0
            for i in 0..<60 {
                // Nudge the playhead so no frame is identical to the last.
                vm.setPlayhead(RationalTime(seconds: end / 2 + Double(i) * vm.secondsPerPoint))
                let t0 = CACurrentMediaTime()
                let scene = TimelineSceneBuilder.build(from: vm)
                _ = try renderer.render(scene: scene)
                times.append((CACurrentMediaTime() - t0) * 1000)
                drawn = scene.stats.clipsDrawn
            }
            times.sort()
            let median = times[times.count / 2]
            let p95 = times[Int(Double(times.count) * 0.95)]
            let line = String(
                format:
                    "zoom %d (%.3f s/pt): %d/%d clips drawn, median %.2f ms, p95 %.2f ms, max %.2f ms, %d draw calls, %d vertices",
                zoom, vm.secondsPerPoint, drawn, clipCount, median, p95, times.last!, renderer.lastFrameStats.drawCalls,
                renderer.lastFrameStats.solidVertices + renderer.lastFrameStats.texturedVertices)
            report.append(line)
            #expect(median < BenchmarkTests.bound, Comment(rawValue: line))
        }
        for line in report { print("benchmark: \(line)") }
    }

    @Test func gesturePreviewOnAThousandClipsIsInteractive() async throws {
        let store = try await BenchmarkTests.thousandClipsStore()
        let vm = TimelineViewModel(store: store)
        await vm.load()
        vm.viewSize = CGSize(width: 1600, height: 600)
        let seq = vm.sequence!
        let clip = seq.tracks[0].clips.values.sorted { $0.start < $1.start }[10]
        vm.beginGesture(.move, clip: clip.id, at: clip.start, modifiers: [.command])
        var times: [Double] = []
        for i in 1...30 {
            let t0 = CACurrentMediaTime()
            vm.updateGesture(to: clip.start + RationalTime(seconds: Double(i) * 0.1))
            times.append((CACurrentMediaTime() - t0) * 1000)
        }
        times.sort()
        print(
            String(
                format: "benchmark: ripple move preview on %d clips: median %.2f ms, max %.2f ms",
                seq.tracks.reduce(0) { $0 + $1.clips.count }, times[times.count / 2], times.last!))
        #expect(vm.preview?.isValid == true)
        #expect(times[times.count / 2] < BenchmarkTests.bound * 4)
        vm.cancelGesture()
    }
}
