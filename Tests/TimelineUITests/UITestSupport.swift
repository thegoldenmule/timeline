import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import Testing
import TimelineCore

@testable import TimelineUI

/// A view model over a fixture store, plus the pieces tests poke at.
@MainActor
struct UIFixture {
    let store: FakeProjectStore
    let viewModel: TimelineViewModel
    let thumbnails: FakeThumbnailProvider?
    let waveforms: FakeWaveformProvider?
    let original: Project

    static func make(
        _ name: String = "three-clips", media: Bool = false, size: CGSize = CGSize(width: 1200, height: 400),
        zoomIndex: Int = ZoomLevel.defaultIndex
    ) async throws -> UIFixture {
        let store = try Fixtures.store(name)
        let thumbs = media ? FakeThumbnailProvider() : nil
        let waves = media ? FakeWaveformProvider() : nil
        let vm = TimelineViewModel(store: store, thumbnails: thumbs, waveforms: waves)
        vm.viewSize = size
        vm.zoomIndex = zoomIndex
        await vm.load()
        return UIFixture(store: store, viewModel: vm, thumbnails: thumbs, waveforms: waves, original: vm.project)
    }

    var sequence: Sequence { viewModel.sequence! }

    /// Clips on the first track of `kind`, sorted by start.
    func clips(_ kind: TrackKind = .video, track index: Int = 0) -> [Clip] {
        let tracks = sequence.tracks.filter { $0.kind == kind }
        return tracks[index].clips.values.sorted { $0.start < $1.start }
    }

    func rect(of clip: Clip) -> CGRect { viewModel.layout.rect(for: clip, in: sequence)! }

    func center(of clip: Clip) -> CGPoint {
        let r = rect(of: clip)
        return CGPoint(x: r.midX, y: r.midY)
    }

    var receivedCommands: [Command] {
        get async { await store.receivedCommands }
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes. The timeout is generous because
/// the benchmark suite runs alongside and occupies the main actor for seconds at a time.
@MainActor
func eventually(timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

extension SceneColor: CustomTestStringConvertible {
    public var testDescription: String { String(format: "(%.3f, %.3f, %.3f, %.3f)", r, g, b, a) }
}
