import AVFoundation
import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import Testing
import TimelineCore

@Suite struct FakeRendererTests {
    @Test func propertyEditIsInstructionsOnlyAndTrimIsStructural() async throws {
        let renderer: any Renderer = FakeRenderer()
        let b = try Fixtures.builder("three-clips")
        let clip = try #require(Fixtures.firstVideoClip(in: b.project))
        let compiled = try await renderer.compile(b.sequence, assets: b.project.assets, options: .preview)
        #expect(compiled.hasAudio)
        #expect(compiled.duration == RationalTime(540_000, 48000))  // the A1 music clip ends last

        try b.apply(.setClipOpacity(.init(clipId: .id(clip.id), after: .constant(0.5))))
        let u1 = try await renderer.update(compiled, to: b.sequence, assets: b.project.assets)
        #expect(!u1.isStructural)
        #expect(u1.compiled.structuralFingerprint == compiled.structuralFingerprint)
        #expect(u1.compiled.instructionFingerprint != compiled.instructionFingerprint)

        try b.apply(
            .trimClip(
                .init(clipId: .id(clip.id), edge: .tail, to: clip.start + Fixtures.frames(48), mode: .overwrite)))
        let u2 = try await renderer.update(u1.compiled, to: b.sequence, assets: b.project.assets)
        #expect(u2.isStructural)
        #expect(u2.compiled.structuralFingerprint != compiled.structuralFingerprint)

        let unchanged = try await renderer.update(u2.compiled, to: b.sequence, assets: b.project.assets)
        #expect(!unchanged.isStructural)
        #expect(unchanged.compiled.instructionFingerprint == u2.compiled.instructionFingerprint)
    }

    @Test func transitionDurationIsStructuralButKindIsNot() async throws {
        let renderer = FakeRenderer()
        let b = try Fixtures.builder("linked-transition-caption-undone")
        let transition = try #require(b.sequence.transitions.values.first)
        let compiled = try await renderer.compile(b.sequence, assets: b.project.assets, options: .gesture)
        #expect(!compiled.hasAudio)
        try b.apply(.updateTransition(.init(transitionId: .id(transition.id), kind: "wipe")))
        #expect(try await !renderer.update(compiled, to: b.sequence, assets: b.project.assets).isStructural)
        try b.apply(.updateTransition(.init(transitionId: .id(transition.id), duration: Fixtures.frames(8))))
        #expect(try await renderer.update(compiled, to: b.sequence, assets: b.project.assets).isStructural)
        #expect(renderer.calls.count == 3)
    }

    @Test @MainActor func playerItemReachesReadyToPlay() async throws {
        let renderer = FakeRenderer()
        let b = try Fixtures.builder("three-clips")
        let compiled = try await renderer.compile(b.sequence, assets: b.project.assets, options: .preview)
        let item = renderer.playerItem(for: compiled)
        #expect(item.seekingWaitsForVideoCompositionRendering)
        let player = AVPlayer(playerItem: item)
        let deadline = ContinuousClock.now + .seconds(20)
        while item.status == .unknown, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(item.status == .readyToPlay, "status \(item.status.rawValue) error \(String(describing: item.error))")
        #expect(player.currentItem === item)
        renderer.apply(compiled, to: item)
        #expect(renderer.calls.contains(.apply(compiledId: compiled.id)))
        #expect(renderer.calls.contains(.playerItem(compiledId: compiled.id)))
    }

    @Test func frameIsASolidImageOfTheRequestedSize() async throws {
        let renderer: any Renderer = FakeRenderer()
        let b = try Fixtures.builder("three-clips")
        let compiled = try await renderer.compile(b.sequence, assets: b.project.assets, options: .full)
        let image = try await renderer.frame(compiled, at: Fixtures.frames(30), size: CGSize(width: 64, height: 36))
        #expect(image.width == 64 && image.height == 36)
        let quarter = try await renderer.frame(compiled, at: .zero, size: nil)
        #expect(quarter.width == b.sequence.width / 4 && quarter.height == b.sequence.height / 4)
    }

    @Test func exportJobWritesAFileAndAReceipt() async throws {
        let renderer: any Renderer = FakeRenderer()
        let b = try Fixtures.builder("three-clips")
        let compiled = try await renderer.compile(b.sequence, assets: b.project.assets, options: .full)
        let dir = try TestMedia.Directory(prefix: "ExportTest")
        let url = dir.file("reel.mp4")
        let job = renderer.export(compiled, preset: .reel9x16, to: url)
        #expect(job.kind == .export && job.memoryClass == .medium)
        let runner: any JobRunner = FakeJobRunner()
        let handle = await runner.submit(job)
        let outcome = try await handle.wait()
        #expect(outcome.urls == [url])
        #expect(FileManager.default.fileExists(atPath: url.path))
        let receipt = try #require(try outcome.payload(as: ExportReceipt.self))
        #expect(receipt.preset == .reel9x16)
        #expect(receipt.sequenceId == b.sequenceId)
        #expect(receipt.outputURL == url)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    @Test func failureInjection() async throws {
        let renderer = FakeRenderer()
        renderer.fail(with: .sequenceEmpty)
        let b = try Fixtures.builder("empty")
        await #expect(throws: RenderError.sequenceEmpty) {
            try await renderer.compile(b.sequence, assets: [:], options: .preview)
        }
    }
}
