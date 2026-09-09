import AVFoundation
import Contracts
import ContractsTestSupport
import Foundation
import RenderKit
import Testing
import TimelineCore

/// `update` classifies edits exactly like `SequenceFingerprint` in ContractsTestSupport, reuses the frozen
/// composition for instruction-only edits, and never mutates a composition a player holds.
@Suite struct UpdateTests {
    struct Edit {
        var label: String
        var structural: Bool
        var apply: (ProjectBuilder) throws -> Void
    }

    @Test func classificationMatchesTheFakeRenderer() async throws {
        let lib = try await FixtureLibrary.get()
        let b = try Fixtures.builder("linked-transition-caption-undone")
        let renderer = AVFoundationRenderer(layout: lib.layout)
        let fake = FakeRenderer()
        let f = Fixtures.frames
        let first = try #require(Fixtures.firstVideoClip(in: b.project))
        let transition = try #require(b.sequence.transitions.values.first)
        let second = try #require(b.sequence.clip(transition.rightClipId))
        let caption = try #require(b.captionTracks[0].clips.values.min { $0.start < $1.start })
        let audioClip = try #require(b.audioTracks[0].clips.values.min { $0.start < $1.start })

        let edits: [Edit] = [
            Edit(label: "opacity", structural: false) {
                try $0.apply(.setClipOpacity(.init(clipId: .id(first.id), after: .constant(0.5))))
            },
            Edit(label: "transform", structural: false) {
                try $0.apply(.setClipTransform(.init(clipId: .id(first.id), after: .constant(Transform(scale: 0.8)))))
            },
            Edit(label: "effect", structural: false) {
                try $0.apply(.addEffect(.init(clipId: .id(first.id), kind: "invert")))
            },
            Edit(label: "transition kind", structural: false) {
                try $0.apply(.updateTransition(.init(transitionId: .id(transition.id), kind: "wipe")))
            },
            Edit(label: "transition params", structural: false) {
                try $0.apply(
                    .updateTransition(.init(transitionId: .id(transition.id), params: ["direction": .string("left")])))
            },
            Edit(label: "audio gain", structural: false) {
                try $0.apply(.setClipAudio(.init(clipId: .id(audioClip.id), after: ClipAudio(gain: .constant(0.3)))))
            },
            Edit(label: "audio mute", structural: false) {
                try $0.apply(.setClipAudio(.init(clipId: .id(audioClip.id), after: ClipAudio(muted: true))))
            },
            Edit(label: "track mute", structural: false) {
                try $0.apply(.setTrackMuted(.init(trackId: .id(b.videoTracks[0].id), muted: true)))
            },
            Edit(label: "caption text", structural: false) {
                try $0.apply(.editCaption(.init(clipId: .id(caption.id), text: "Changed")))
            },
            Edit(label: "transition duration", structural: true) {
                try $0.apply(.updateTransition(.init(transitionId: .id(transition.id), duration: f(8))))
            },
            Edit(label: "transition alignment", structural: true) {
                try $0.apply(.updateTransition(.init(transitionId: .id(transition.id), alignment: .startOnCut)))
            },
            Edit(label: "trim", structural: true) {
                try $0.apply(.trimClip(.init(clipId: .id(second.id), edge: .tail, to: f(180), mode: .overwrite)))
            },
            Edit(label: "split", structural: true) {
                try $0.apply(.splitClip(.init(clipId: .id(second.id), at: f(150))))
            },
            Edit(label: "move", structural: true) {
                try $0.apply(
                    .moveClip(
                        .init(clipId: .id(second.id), to: Command.Operation.MoveTarget(start: f(200)), mode: .overwrite)
                    ))
            },
        ]

        var compiled = try await renderer.compile(b.sequence, assets: b.project.assets, options: .preview)
        var fakeCompiled = try await fake.compile(b.sequence, assets: b.project.assets, options: .preview)
        let originalComposition = compiled.renderPayload?.composition
        for edit in edits {
            try edit.apply(b)
            let mine = try await renderer.update(compiled, to: b.sequence, assets: b.project.assets)
            let theirs = try await fake.update(fakeCompiled, to: b.sequence, assets: b.project.assets)
            #expect(
                mine.isStructural == theirs.isStructural, "\(edit.label): fake says structural=\(theirs.isStructural)")
            #expect(mine.isStructural == edit.structural, "\(edit.label)")
            #expect(
                mine.compiled.instructionFingerprint != compiled.instructionFingerprint,
                "\(edit.label) changes the instructions")
            if !mine.isStructural {
                #expect(mine.compiled.structuralFingerprint == compiled.structuralFingerprint)
                #expect(
                    mine.compiled.renderPayload?.composition === compiled.renderPayload?.composition,
                    "\(edit.label) reuses the composition")
                #expect(mine.compiled.renderPayload?.videoComposition !== compiled.renderPayload?.videoComposition)
            } else {
                #expect(mine.compiled.structuralFingerprint != compiled.structuralFingerprint)
                #expect(mine.compiled.renderPayload?.composition !== compiled.renderPayload?.composition)
            }
            #expect(mine.compiled.id != compiled.id)
            compiled = mine.compiled
            fakeCompiled = theirs.compiled
        }
        let unchanged = try await renderer.update(compiled, to: b.sequence, assets: b.project.assets)
        #expect(!unchanged.isStructural)
        #expect(unchanged.compiled.instructionFingerprint == compiled.instructionFingerprint)
        // The first composition was never mutated: it still has the original segments.
        let original = try #require(originalComposition)
        #expect(
            original.track(withTrackID: 2)?.segments.first { !$0.isEmpty }?.timeMapping.target.end == CMTime(f(192)))
    }

    @Test func audioOptionChangesAreStructuralAndGestureCompilesAreVideoOnly() async throws {
        let lib = try await FixtureLibrary.get()
        let b = try Fixtures.builder("three-clips")
        let renderer = AVFoundationRenderer(layout: lib.layout)
        let gesture = try await renderer.compile(b.sequence, assets: b.project.assets, options: .gesture)
        #expect(!gesture.hasAudio)
        #expect(gesture.renderPayload?.composition.tracks(withMediaType: .audio).isEmpty == true)
        let full = try await renderer.compile(b.sequence, assets: b.project.assets, options: .preview)
        #expect(full.hasAudio)
        #expect(full.structuralFingerprint != gesture.structuralFingerprint, "audio presence is part of the structure")
        // Removing the only audio clip flips hasAudio: structural, as in the fake.
        let music = try #require(b.audioTracks[0].clips.values.first)
        try b.apply(.removeClip(.init(clipId: .id(music.id), mode: .overwrite)))
        let update = try await renderer.update(full, to: b.sequence, assets: b.project.assets)
        #expect(update.isStructural && !update.compiled.hasAudio)
        #expect(update.compiled.duration == Fixtures.frames(264))
    }

    @Test @MainActor func applyReplacesTheLiveItemsCompositionWithoutANewItem() async throws {
        let scene = try Scene("RenderKitApply")
        let green = try scene.importClip(try await scene.solid(.green, name: "green"))
        let clip = try scene.add(green, at: 0, count: 60)
        let renderer = scene.renderer()
        let compiled = try await renderer.compile(scene.sequence, assets: scene.assets, options: .gesture)
        let item = renderer.playerItem(for: compiled)
        let output = bgraOutput()
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        #expect(await waitUntilReady(item))
        await item.seek(to: CMTime(scene.frames(10)), toleranceBefore: .zero, toleranceAfter: .zero)
        let before = try #require(await nextFrame(output, item: item))
        #expect(near(Pixels(before).mean(Pixels(before).centerRect), (0, 255, 0), tolerance: 3))
        try scene.builder.apply(.setClipOpacity(.init(clipId: .id(clip), after: .constant(0.5))))
        let update = try await renderer.update(compiled, to: scene.sequence, assets: scene.assets)
        #expect(!update.isStructural)
        renderer.apply(update.compiled, to: item)
        #expect(item.videoComposition != nil)
        let deadline = ContinuousClock.now + .seconds(5)
        var seen: (Int, Int, Int) = (0, 0, 0)
        while ContinuousClock.now < deadline {
            if let buffer = await nextFrame(output, item: item, timeout: .milliseconds(200)) {
                let px = Pixels(buffer)
                seen = px.mean(px.centerRect)
                if near(seen, (0, 128, 0), tolerance: 4) { break }
            }
        }
        #expect(near(seen, (0, 128, 0), tolerance: 4), "the live item re-rendered with the new opacity: \(seen)")
        #expect(player.currentItem === item, "no new item was needed")
    }
}
