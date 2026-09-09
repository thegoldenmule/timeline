import AVFoundation
import Contracts
import ContractsTestSupport
import Foundation
import RenderKit
import Testing
import TimelineCore

/// Solo reaches the compiled output the same way mute does: the rule is `Sequence.silence(of:)` and the
/// compiler asks it rather than reading `muted` itself.
@Suite struct SoloTests {
    /// A 640x360 project with V1/V2 and A1/A2, one two-second clip of the same source on each track.
    struct Stage {
        let scene: Scene
        let v2: TrackID
        let a2: TrackID

        init(_ prefix: String) async throws {
            scene = try Scene(prefix, videoTracks: 2)
            v2 = scene.builder.videoTracks[1].id
            a2 = try scene.builder.addTracks(.audio, count: 1)[0]
            let media = try await scene.barcodeWithAudio(.gray, name: "av", seconds: 3)
            let asset = try scene.importClip(media)
            // V1 + A1 as a linked pair, then an unlinked copy on V2 and A2.
            try scene.add(asset, at: 0, count: 60, link: .auto)
            try scene.add(asset, at: 0, count: 60, track: v2)
            try scene.builder.addClip(
                track: a2, asset: asset, at: .zero, sourceIn: .zero, sourceOut: scene.frames(60))
        }

        var v1: TrackID { scene.video }
        var a1: TrackID { scene.audio }

        func compile() async throws -> RenderPayload {
            let compiled = try await scene.renderer().compile(
                scene.sequence, assets: scene.assets, options: .full)
            guard let payload = compiled.renderPayload else { throw RenderKitError.notARenderKitPayload }
            return payload
        }

        /// The mix volume AVFoundation reports for the composition track serving `track`.
        func gain(of track: TrackID, in payload: RenderPayload) throws -> Float {
            let info = try #require(payload.audioTracks.first { $0.modelTrackId == track })
            let params = try #require(payload.audioMix?.inputParameters.first { $0.trackID == info.trackID })
            var start: Float = -1
            var end: Float = -1
            var range = CMTimeRange.zero
            _ = params.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range)
            return start
        }

        /// Composition tracks whose layers reach the instruction at frame `n`.
        func layers(at n: Int64, in payload: RenderPayload) -> [CMPersistentTrackID] {
            payload.instructions.instruction(at: CMTime(scene.frames(n)))?.layers.compactMap(\.sourceTrackID) ?? []
        }
    }

    @Test func soloingAnAudioTrackSilencesItsPeerAndLeavesTheVideoAlone() async throws {
        let stage = try await Stage("RenderKitSolo")
        let before = try await stage.compile()
        #expect(try stage.gain(of: stage.a1, in: before) == 1)
        #expect(try stage.gain(of: stage.a2, in: before) == 1)
        let videoLayers = stage.layers(at: 10, in: before)
        #expect(videoLayers.count == 2)

        try stage.scene.builder.apply(.setTrackSolo(.init(trackId: .id(stage.a2), solo: true)))
        let after = try await stage.compile()
        #expect(try stage.gain(of: stage.a1, in: after) == 0, "A1 is silenced by A2's solo")
        #expect(try stage.gain(of: stage.a2, in: after) == 1)
        #expect(stage.layers(at: 10, in: after) == videoLayers, "an audio solo never touches the picture")
    }

    @Test func soloingAVideoTrackDropsTheOtherVideoLayersAndNotTheSound() async throws {
        let stage = try await Stage("RenderKitSoloVideo")
        let before = try await stage.compile()
        #expect(stage.layers(at: 10, in: before).count == 2)

        try stage.scene.builder.apply(.setTrackSolo(.init(trackId: .id(stage.v2), solo: true)))
        let after = try await stage.compile()
        #expect(stage.layers(at: 10, in: after).count == 1, "only V2 composites")
        #expect(try stage.gain(of: stage.a1, in: after) == 1)
        #expect(try stage.gain(of: stage.a2, in: after) == 1)
    }

    @Test func aTrackThatIsBothMutedAndSoloedIsStillSilent() async throws {
        let stage = try await Stage("RenderKitSoloMuted")
        try stage.scene.builder.apply(.setTrackSolo(.init(trackId: .id(stage.a2), solo: true)))
        try stage.scene.builder.apply(.setTrackMuted(.init(trackId: .id(stage.a2), muted: true)))
        let payload = try await stage.compile()
        #expect(try stage.gain(of: stage.a2, in: payload) == 0, "its own mute outranks its own solo")
        #expect(try stage.gain(of: stage.a1, in: payload) == 0, "and A1 is still silenced by the solo")
    }

    @Test func aSoloChangeIsAnInstructionsOnlyUpdate() async throws {
        let stage = try await Stage("RenderKitSoloUpdate")
        let renderer = stage.scene.renderer()
        let compiled = try await renderer.compile(stage.scene.sequence, assets: stage.scene.assets, options: .full)
        try stage.scene.builder.apply(.setTrackSolo(.init(trackId: .id(stage.a2), solo: true)))
        let update = try await renderer.update(compiled, to: stage.scene.sequence, assets: stage.scene.assets)
        #expect(!update.isStructural, "solo changes the mix and the table, never a composition segment")
        #expect(update.compiled.structuralFingerprint == compiled.structuralFingerprint)
    }

    @Test func exportWarnsAboutEverySilencedTrackAndSaysWhy() async throws {
        let stage = try await Stage("RenderKitSoloExport")
        try stage.scene.builder.apply(.setTrackMuted(.init(trackId: .id(stage.v2), muted: true)))
        try stage.scene.builder.apply(.setTrackSolo(.init(trackId: .id(stage.a2), solo: true)))
        let renderer = stage.scene.renderer()
        let compiled = try await renderer.compile(stage.scene.sequence, assets: stage.scene.assets, options: .full)
        let dir = try TestMedia.Directory(prefix: "RenderKitSoloExport")
        let outcome = try await FakeJobRunner().submit(
            renderer.export(compiled, preset: .h264_1080p, to: dir.file("silent.mp4"))
        ).wait()
        #expect(outcome.warnings.contains { $0.contains("V2") && $0.contains("muted") })
        #expect(outcome.warnings.contains { $0.contains("A1") && $0.contains("soloed") })
        #expect(!outcome.warnings.contains { $0.contains("A2") }, "the soloed track is the one you hear")
        let receipt = try #require(try outcome.payload(as: ExportReceipt.self))
        #expect(receipt.warnings == outcome.warnings)
    }
}
