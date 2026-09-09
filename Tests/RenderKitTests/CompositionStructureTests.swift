import AVFoundation
import Contracts
import ContractsTestSupport
import Foundation
import RenderKit
import Testing
import TimelineCore

/// Composition structure for the fixture projects: track counts, segment time ranges, transition overlap
/// handles, audio selection.
@Suite struct CompositionStructureTests {
    let fd = Fixtures.frameDuration
    func f(_ n: Int64) -> RationalTime { Fixtures.frames(n) }

    @Test func threeClipsAlternateTracksAndPinTheDuration() async throws {
        let lib = try await FixtureLibrary.get()
        let b = try Fixtures.builder("three-clips")
        let renderer = AVFoundationRenderer(layout: lib.layout)
        let compiled = try await renderer.compile(b.sequence, assets: b.project.assets, options: .full)
        let payload = try #require(compiled.renderPayload)

        #expect(compiled.duration == RationalTime(540_000, 48000), "the A1 music clip ends last")
        #expect(payload.duration == CMTime(value: 540_000, timescale: 48000))
        #expect(compiled.hasAudio)
        #expect(!payload.isHDR)
        #expect(payload.offlineAssets.isEmpty)

        let video = payload.videoTracks.sorted { $0.trackID < $1.trackID }
        #expect(video.count == 2, "one A/B pair for V1")
        let a = try #require(video.first { $0.slot == 0 })
        let bTrack = try #require(video.first { $0.slot == 1 })
        #expect(a.trackID == 1 && bTrack.trackID == 2)
        #expect(
            a.segments.map(\.targetRange) == [
                TimeRange(start: .zero, end: f(96)), TimeRange(start: f(144), end: f(264)),
            ])
        #expect(
            a.segments.map(\.sourceRange) == [
                TimeRange(start: f(24), end: f(120)), TimeRange(start: f(240), end: f(360)),
            ])
        #expect(bTrack.segments.map(\.targetRange) == [TimeRange(start: f(96), end: f(144))])
        #expect(bTrack.segments.map(\.sourceRange) == [TimeRange(start: .zero, end: f(48))])
        #expect(a.segments.allSatisfy { !$0.isFiller && $0.sourceURL?.lastPathComponent == "IMG_1575.MOV" })
        #expect(bTrack.segments[0].sourceURL?.lastPathComponent == "Screen Recording.mov")

        let filler = try #require(payload.tracks.first { $0.role == .filler })
        #expect(filler.segments.count == 1 && filler.segments[0].isFiller)
        #expect(filler.segments[0].targetRange == TimeRange(start: .zero, end: RationalTime(540_000, 48000)))

        let audio = payload.audioTracks
        #expect(audio.count == 1)
        #expect(
            audio[0].segments.map(\.targetRange) == [
                TimeRange(start: RationalTime(12000, 48000), end: RationalTime(540_000, 48000))
            ])
        #expect(audio[0].segments[0].sourceURL?.lastPathComponent == "band-mix-v3.wav")

        // The AVFoundation objects agree with the record.
        let composition = payload.composition
        #expect(composition.tracks(withMediaType: .video).count == 3)
        #expect(composition.tracks(withMediaType: .audio).count == 1)
        #expect(composition.duration == CMTime(value: 540_000, timescale: 48000))
        let trackA = try #require(composition.track(withTrackID: 1))
        let segments = trackA.segments.filter { !$0.isEmpty }
        #expect(segments.count == 2)
        #expect(segments[0].timeMapping.target == CMTimeRange(TimeRange(start: .zero, end: f(96))))
        #expect(segments[1].timeMapping.target == CMTimeRange(TimeRange(start: f(144), end: f(264))))
        #expect(payload.videoComposition.renderSize == CGSize(width: 1920, height: 1080))
        #expect(payload.videoComposition.frameDuration == CMTime(fd))
        #expect(payload.videoComposition.customVideoCompositorClass == TimelineCompositor.self)
        #expect(payload.videoComposition.colorPrimaries == AVVideoColorPrimaries_ITU_R_709_2)

        // Instructions: contiguous, covering [0, duration], one layer per clip, none during the audio tail.
        let table = payload.instructions
        #expect(table.instructions.first?.timeRange.start == .zero)
        #expect(table.duration == payload.duration)
        for (x, y) in zip(table.instructions, table.instructions.dropFirst()) {
            #expect(x.timeRange.end == y.timeRange.start)
        }
        #expect(table.instruction(at: CMTime(f(10)))?.layers.map(\.sourceTrackID) == [1])
        #expect(table.instruction(at: CMTime(f(100)))?.layers.map(\.sourceTrackID) == [2])
        #expect(table.instruction(at: CMTime(f(200)))?.layers.map(\.sourceTrackID) == [1])
        #expect(table.instruction(at: CMTime(value: 111, timescale: 10))?.layers.isEmpty == true)
        #expect(payload.audioMix?.inputParameters.count == 1)
    }

    @Test func transitionBecomesAnOverlapWithHandlesOnBothTracks() async throws {
        let lib = try await FixtureLibrary.get()
        let b = try Fixtures.builder("linked-transition-caption-undone")
        let renderer = AVFoundationRenderer(layout: lib.layout)
        let compiled = try await renderer.compile(b.sequence, assets: b.project.assets, options: .full)
        let payload = try #require(compiled.renderPayload)
        let transition = try #require(b.sequence.transitions.values.first)
        #expect(transition.duration == f(12) && transition.alignment == .centered)

        let video = payload.videoTracks.sorted { $0.trackID < $1.trackID }
        #expect(video.count == 2)
        let left = try #require(video[0].segments.first)
        let right = try #require(video[1].segments.first)
        // Cut at frame 96; centered 12-frame dissolve: 6 frames of handle each side.
        #expect(left.targetRange == TimeRange(start: .zero, end: f(102)))
        #expect(left.sourceRange == TimeRange(start: f(24), end: f(126)))
        #expect(right.targetRange == TimeRange(start: f(90), end: f(192)))
        #expect(right.sourceRange == TimeRange(start: f(234), end: f(336)))
        #expect(compiled.duration == f(192), "the ripple trim was undone")

        // Linked audio clips get the same overlap with a crossfade in the mix.
        let audio = payload.audioTracks.sorted { $0.trackID < $1.trackID }
        #expect(audio.count == 2)
        #expect(audio[0].segments.first?.targetRange == TimeRange(start: .zero, end: f(102)))
        #expect(audio[1].segments.first?.targetRange == TimeRange(start: f(90), end: f(192)))
        let mix = try #require(payload.audioMix)
        #expect(mix.inputParameters.count == 2)
        let fadeOut = try #require(mix.inputParameters.first { $0.trackID == audio[0].trackID })
        var start: Float = 0
        var end: Float = 0
        var range = CMTimeRange.zero
        #expect(fadeOut.getVolumeRamp(for: CMTime(f(96)), startVolume: &start, endVolume: &end, timeRange: &range))
        #expect(start == 1 && end == 0)
        #expect(range == CMTimeRange(TimeRange(start: f(90), end: f(102))))

        // The overlap instruction carries both layers and the transition.
        let table = payload.instructions
        let mid = try #require(table.instruction(at: CMTime(f(96))))
        #expect(mid.timeRange == CMTimeRange(TimeRange(start: f(90), end: f(102))))
        #expect(mid.layers.map(\.sourceTrackID) == [1, 2])
        let spec = try #require(mid.transitions[0])
        #expect(spec.kind == "dissolve" && spec.overlap == mid.timeRange)
        #expect(spec.progress(at: CMTime(f(96))) == 0.5)
        #expect(mid.containsTweening)
        #expect(table.instruction(at: CMTime(f(50)))?.layers.map(\.sourceTrackID) == [1])
        #expect(table.instruction(at: CMTime(f(150)))?.layers.map(\.sourceTrackID) == [2])

        // Captions: two items at 12..48 and 60..108 with resolved word times.
        let first = try #require(table.instruction(at: CMTime(f(20))))
        #expect(first.captions.count == 1)
        #expect(first.captions[0].text == "Hello there")
        #expect(first.captions[0].words.map(\.text) == ["Hello", "there"])
        #expect(first.captions[0].words[1].range == CMTimeRange(TimeRange(start: f(26), end: f(42))))
        #expect(first.captions[0].activeWord(at: CMTime(f(30))) == 1)
        #expect(first.captions[0].activeWord(at: CMTime(f(25))) == nil)
        #expect(table.instruction(at: CMTime(f(80)))?.captions.first?.style.fontSize == 42)
        #expect(table.instruction(at: CMTime(f(55)))?.captions.isEmpty == true)
    }

    @Test func offlineAssetsBecomeSlatesAndEmptySequencesThrow() async throws {
        let lib = try await FixtureLibrary.get()
        let b = try Fixtures.builder("three-clips")
        // Mark the screen recording offline: its clip becomes a slate on the filler source.
        let screen = try #require(b.project.assets.values.first { $0.displayName == "Screen Recording.mov" })
        var assets = b.project.assets
        assets[screen.id]?.offline = true
        let renderer = AVFoundationRenderer(layout: lib.layout)
        let compiled = try await renderer.compile(b.sequence, assets: assets, options: .gesture)
        let payload = try #require(compiled.renderPayload)
        #expect(payload.offlineAssets.map(\.id) == [screen.id])
        #expect(!compiled.hasAudio, "gesture options build video-only")
        #expect(payload.audioTracks.isEmpty && payload.audioMix == nil)
        let slate = try #require(payload.videoTracks.first { $0.slot == 1 }?.segments.first)
        #expect(slate.isFiller && slate.targetRange == TimeRange(start: f(96), end: f(144)))
        let layer = try #require(payload.instructions.instruction(at: CMTime(f(100)))?.layers.first)
        #expect(layer.content == .slate(label: "Screen Recording.mov"))

        // A missing file (not flagged offline) is a slate too, and the fingerprint says so.
        var missing = b.project.assets
        missing[screen.id]?.libraryPath = "2026/2026-09-08/gone.mov"
        let compiled2 = try await renderer.compile(b.sequence, assets: missing, options: .gesture)
        #expect(compiled2.renderPayload?.offlineAssets.map(\.id) == [screen.id])
        #expect(compiled2.structuralFingerprint != compiled.structuralFingerprint)

        let empty = try Fixtures.builder("empty")
        await #expect(throws: RenderError.sequenceEmpty) {
            try await renderer.compile(empty.sequence, assets: empty.project.assets, options: .preview)
        }
    }

    @Test func speedScalesTheSegmentAndSelectsThePitchAlgorithm() async throws {
        let scene = try Scene("RenderKitSpeed")
        let clip = try await scene.barcodeWithAudio(.gray, name: "av", seconds: 4)
        let asset = try scene.importClip(clip)
        let id = try scene.add(asset, at: 0, sourceIn: 0, count: 60, link: .auto)
        try scene.builder.apply(.setClipSpeed(.init(clipId: .id(id), after: Rational(2, 1))))
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .full)
        let payload = try #require(compiled.renderPayload)
        let v = try #require(payload.videoTracks.first?.segments.first)
        #expect(v.speed == Rational(2, 1))
        #expect(v.sourceRange == TimeRange(start: .zero, end: scene.frames(60)))
        #expect(v.targetRange == TimeRange(start: .zero, end: scene.frames(30)))
        let track = try #require(payload.composition.track(withTrackID: 1))
        let segment = try #require(track.segments.first)
        #expect(segment.timeMapping.source.duration == CMTime(value: 2, timescale: 1))
        #expect(segment.timeMapping.target.duration == CMTime(value: 1, timescale: 1))
        // Audio: a dedicated track for the speed-changed clip, spectral by default.
        let mix = try #require(payload.audioMix)
        #expect(mix.inputParameters.first?.audioTimePitchAlgorithm == .spectral)
        let audioClip = try #require(scene.builder.audioTracks[0].clips.values.first)
        try scene.builder.apply(
            .setClipAudio(
                .init(clipId: .id(audioClip.id), after: ClipAudio(gain: .constant(0.5), pitchCorrected: false))))
        let update = try await renderer.update(compiled, to: scene.sequence, assets: scene.assets)
        #expect(!update.isStructural, "the pitch algorithm is an audio-mix property")
        let mix2 = try #require(update.compiled.renderPayload?.audioMix)
        #expect(mix2.inputParameters.first?.audioTimePitchAlgorithm == .varispeed)
        var startVolume: Float = 0
        var endVolume: Float = 0
        var rampRange = CMTimeRange.zero
        _ = mix2.inputParameters.first?.getVolumeRamp(
            for: CMTime(value: 1, timescale: 2), startVolume: &startVolume, endVolume: &endVolume, timeRange: &rampRange
        )
        #expect(startVolume == 0.5 && endVolume == 0.5)
        // Frame 10 of the timeline is source frame 20.
        let image = try await renderer.frame(update.compiled, at: scene.frames(10), size: nil)
        #expect(TestMedia.decodeFrameIndex(from: image) == 20)
    }
}
