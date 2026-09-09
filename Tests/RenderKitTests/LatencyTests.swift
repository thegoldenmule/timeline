import AVFoundation
import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import RenderKit
import Testing
import TimelineCore

/// Edit-to-first-updated-frame latency on a 200-clip sequence, measured through `PreviewPlayer` and an
/// `AVPlayerItemVideoOutput` polled every millisecond (the harness from spikes/preview-update). Debug builds
/// assert the plan's bounds times `debugSlack`; `swift test -c release` reports the real numbers.
@MainActor
final class LatencyHarness {
    static let colors: [TestMedia.Color] = [.red, .green, .blue, Color(r: 1, g: 1, b: 0)]
    typealias Color = TestMedia.Color

    let scene: Scene
    let player: PreviewPlayer
    var assets: [AssetID] = []
    var clips: [ClipID] = []
    private var outputs: [(item: AVPlayerItem, output: AVPlayerItemVideoOutput)] = []
    private(set) var frames: [(wall: ContinuousClock.Instant, time: CMTime)] = []
    private var poller: Task<Void, Never>?
    var lastUpdateMs = 0.0

    init(clipCount: Int = 200) async throws {
        scene = try Scene("RenderKitLatency")
        for (i, color) in LatencyHarness.colors.enumerated() {
            let clip = try await scene.barcodeWithAudio(
                color, name: "src\(i)", seconds: 1, frequency: 220 * Double(i + 1))
            assets.append(try scene.importClip(clip))
        }
        for i in 0..<clipCount {
            clips.append(try scene.add(assets[i % 4], at: Int64(i) * 30, sourceIn: 0, count: 30, link: .auto))
        }
        player = PreviewPlayer(renderer: scene.renderer())
        player.isMuted = true
        player.configureItem = { [weak self] item in
            let output = bgraOutput()
            item.add(output)
            self?.outputs.append((item, output))
        }
    }

    var sequence: Sequence { scene.sequence }
    var projectAssets: [AssetID: Asset] { scene.assets }

    func source(of clipIndex: Int) -> Int {
        let clip = scene.sequence.clip(clips[clipIndex])!
        return assets.firstIndex(of: clip.assetId!)!
    }

    /// Expected centre colour of clip `index` in gamma blend space.
    func expected(_ index: Int) -> (Int, Int, Int) {
        let clip = scene.sequence.clip(clips[index])!
        let c = LatencyHarness.colors[source(of: index)]
        let opacity = clip.opacity.constantValue ?? 1
        return (
            Int((c.r * 255 * opacity).rounded()), Int((c.g * 255 * opacity).rounded()),
            Int((c.b * 255 * opacity).rounded())
        )
    }

    // MARK: Polling

    func startPolling() {
        frames.removeAll()
        poller?.cancel()
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                _ = self?.poll()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    /// Polls the live item's output once; records the frame's wall time and item time.
    @discardableResult
    func poll() -> Pixels? {
        guard let item = player.currentItem, let output = outputs.last(where: { $0.item === item })?.output else {
            return nil
        }
        let now = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: now) else { return nil }
        var shown = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &shown) else { return nil }
        frames.append((.now, shown))
        return Pixels(buffer)
    }

    func waitFrame(timeout: Duration = .seconds(5), where predicate: (Pixels) -> Bool) async -> Double? {
        let t0 = ContinuousClock.now
        while ContinuousClock.now - t0 < timeout {
            if let px = poll(), predicate(px) { return milliseconds(from: t0) }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    func waitFrame(matching color: (Int, Int, Int), timeout: Duration = .seconds(5)) async -> Double? {
        await waitFrame(timeout: timeout) { near($0.mean($0.centerRect), color, tolerance: 6) }
    }

    /// Parks the playhead mid-clip, paused, or plays through it from 0.6 s earlier.
    func park(at index: Int, playing: Bool) async throws {
        let mid = CMTime(value: Int64(index) * 30 + 15, timescale: 30)
        player.pause()
        if !playing {
            await player.seek(to: mid)
            let arrived = await waitFrame(matching: expected(index))
            #expect(arrived != nil, "parked frame for clip \(index)")
        } else {
            await player.seek(to: mid - CMTime(value: 18, timescale: 30))
            player.play()
            let deadline = ContinuousClock.now + .seconds(5)
            while player.currentTime < mid - CMTime(value: 3, timescale: 30), ContinuousClock.now < deadline {
                _ = poll()
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    // MARK: Edits

    /// Instruction-only: toggles the clip's opacity between 1 and 0.5.
    func toggleOpacity(_ index: Int) throws {
        let clip = scene.sequence.clip(clips[index])!
        let next: Double = (clip.opacity.constantValue ?? 1) == 1 ? 0.5 : 1
        try scene.builder.apply(.setClipOpacity(.init(clipId: .id(clips[index]), after: .constant(next))))
    }

    /// Structural: replaces the clip (and its linked audio) with the same range from a different source.
    func replaceSource(_ index: Int) throws {
        let old = scene.sequence.clip(clips[index])!
        let nextSource = (source(of: index) + 2) % 4
        try scene.builder.apply(.removeClip(.init(clipId: .id(clips[index]), mode: .overwrite)))
        clips[index] = try scene.add(assets[nextSource], at: Int64(index) * 30, sourceIn: 0, count: 30, link: .auto)
        _ = old
    }

    /// Applies the current sequence through the preview player, timing `update` itself.
    func applyEdit() async throws -> RenderUpdate {
        let t0 = ContinuousClock.now
        let result = try await player.update(scene.sequence, assets: scene.assets)
        lastUpdateMs = milliseconds(from: t0)
        return result
    }

    /// Longest wall-clock interval between consecutive delivered frames since `since`.
    func maxFrameGap(since: ContinuousClock.Instant) -> Double {
        var gap = 0.0
        let recent = frames.filter { $0.wall >= since }
        for (a, b) in zip(recent, recent.dropFirst()) { gap = max(gap, milliseconds(from: a.wall, to: b.wall)) }
        return gap
    }
}

func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant = .now) -> Double {
    let d = end - start
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

@Suite(.serialized) struct LatencyTests {
    @Test @MainActor func instructionOnlyEditsUpdateTheLiveItem() async throws {
        let h = try await LatencyHarness()
        let t0 = ContinuousClock.now
        let compiled = try await h.player.load(h.sequence, assets: h.projectAssets)
        print(
            "[latency] 200-clip A/V compile + first swap: \(fmt(milliseconds(from: t0))) ms, readyToPlay \(fmt(h.player.swaps.last?.readyToPlayMs ?? -1)) ms"
        )
        #expect(compiled.hasAudio)
        #expect(compiled.renderPayload?.instructions.count ?? 0 >= 200)

        var paused: [Double] = []
        var playing: [Double] = []
        var updateMs: [Double] = []
        for run in 0..<5 {
            let index = 100 + run
            try await h.park(at: index, playing: false)
            try h.toggleOpacity(index)
            let expected = h.expected(index)
            let t = ContinuousClock.now
            let result = try await h.applyEdit()
            #expect(!result.isStructural)
            updateMs.append(h.lastUpdateMs)
            let ms = await h.waitFrame(matching: expected)
            #expect(ms != nil, "paused run \(run): no frame with \(expected)")
            paused.append(ms.map { $0 + h.lastUpdateMs } ?? milliseconds(from: t))
        }
        for run in 0..<5 {
            let index = 120 + run
            try await h.park(at: index, playing: true)
            try h.toggleOpacity(index)
            let expected = h.expected(index)
            let t = ContinuousClock.now
            let result = try await h.applyEdit()
            #expect(!result.isStructural)
            let ms = await h.waitFrame(matching: expected)
            #expect(ms != nil, "playing run \(run): no frame with \(expected)")
            playing.append(ms.map { $0 + h.lastUpdateMs } ?? milliseconds(from: t))
            h.player.pause()
        }
        print(
            "[latency] instruction-only, paused: \(paused.map(fmt)) median \(fmt(median(paused))) ms (update() alone \(fmt(median(updateMs))) ms)"
        )
        print("[latency] instruction-only, playing: \(playing.map(fmt)) median \(fmt(median(playing))) ms")
        #expect(median(paused) <= 10 * debugSlack)
        #expect(median(playing) <= 40 * debugSlack)
    }

    @Test @MainActor func structuralEditsSwapItems() async throws {
        let h = try await LatencyHarness()
        try await h.player.load(h.sequence, assets: h.projectAssets)

        // Video-only during a gesture, paused.
        h.player.beginGesture()
        var videoOnly: [Double] = []
        var videoOnlyReady: [Double] = []
        for run in 0..<6 {
            let index = 60 + run
            try await h.park(at: index, playing: false)
            try h.replaceSource(index)
            let expected = h.expected(index)
            let t = ContinuousClock.now
            let result = try await h.applyEdit()
            #expect(result.isStructural)
            #expect(!result.compiled.hasAudio, "gesture compiles are video-only")
            let ms = await h.waitFrame(matching: expected)
            #expect(ms != nil, "video-only run \(run): no frame with \(expected)")
            let total = milliseconds(from: t)
            if run > 0 {  // the first swap also switches from the audio item to the video-only one
                videoOnly.append(total)
                videoOnlyReady.append(h.player.swaps.last?.readyToPlayMs ?? -1)
            }
        }
        print(
            "[latency] structural video-only, paused: \(videoOnly.map(fmt)) median \(fmt(median(videoOnly))) ms (readyToPlay \(videoOnlyReady.map(fmt)))"
        )
        #expect(median(videoOnly) <= 50 * debugSlack)

        // Gesture end: the audio-bearing item comes back.
        let tEnd = ContinuousClock.now
        try await h.player.endGesture(h.sequence, assets: h.projectAssets)
        print(
            "[latency] endGesture audio swap: \(fmt(milliseconds(from: tEnd))) ms, readyToPlay \(fmt(h.player.swaps.last?.readyToPlayMs ?? -1)) ms"
        )
        #expect(h.player.compiled?.hasAudio == true)

        // Audio-bearing swap, paused.
        var withAudio: [Double] = []
        var withAudioReady: [Double] = []
        for run in 0..<5 {
            let index = 80 + run
            try await h.park(at: index, playing: false)
            try h.replaceSource(index)
            let expected = h.expected(index)
            let t = ContinuousClock.now
            let result = try await h.applyEdit()
            #expect(result.isStructural && result.compiled.hasAudio)
            let ms = await h.waitFrame(matching: expected)
            #expect(ms != nil, "audio run \(run): no frame with \(expected)")
            withAudio.append(milliseconds(from: t))
            withAudioReady.append(h.player.swaps.last?.readyToPlayMs ?? -1)
        }
        print(
            "[latency] structural with audio, paused: \(withAudio.map(fmt)) median \(fmt(median(withAudio))) ms (readyToPlay \(withAudioReady.map(fmt)))"
        )
        #expect(median(withAudio) <= 150 * debugSlack)
    }

    @Test @MainActor func pictureNeverFreezesAcrossAPlayingSwap() async throws {
        let h = try await LatencyHarness()
        try await h.player.load(h.sequence, assets: h.projectAssets)
        var gaps: [Double] = []
        var totals: [Double] = []
        var jumps: [Double] = []
        for run in 0..<5 {
            let index = 140 + run * 3
            try await h.park(at: index, playing: true)
            h.startPolling()
            try await Task.sleep(for: .milliseconds(150))
            try h.replaceSource(index)
            let expected = h.expected(index)
            let before = h.player.currentTime
            let t = ContinuousClock.now
            let result = try await h.applyEdit()
            #expect(result.isStructural && result.compiled.hasAudio)
            let ms = await h.waitFrame(matching: expected)
            let total = milliseconds(from: t)
            let after = h.player.currentTime
            try await Task.sleep(for: .milliseconds(600))
            h.stopPolling()
            #expect(ms != nil, "playing run \(run): no frame with \(expected)")
            #expect(h.player.isPlaying, "still playing after the swap")
            let gap = h.maxFrameGap(since: t - .milliseconds(150))
            gaps.append(gap)
            totals.append(total)
            jumps.append((after - before).seconds * 1000 - total)
            h.player.pause()
        }
        print("[latency] playing structural swap edit->frame: \(totals.map(fmt)) median \(fmt(median(totals))) ms")
        print(
            "[latency] playing structural swap max frame gap: \(gaps.map(fmt)) median \(fmt(median(gaps))) ms; item-time jump \(jumps.map(fmt)) ms"
        )
        print(
            "[latency] swap records: \(h.player.swaps.suffix(5).map { "ready \(fmt($0.readyToPlayMs)) total \(fmt($0.totalMs)) audio=\($0.hasAudio) playing=\($0.wasPlaying) ok=\($0.ready)" })"
        )
        #expect(median(gaps) < 250 * debugSlack, "the old player keeps delivering frames until the new item is ready")
        let allReady = h.player.swaps.allSatisfy(\.ready)
        #expect(allReady)
    }
}
