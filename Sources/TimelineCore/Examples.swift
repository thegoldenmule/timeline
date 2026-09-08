import Foundation

extension ProjectFixtures {
    static let fd = RationalTime(1001, 24000)
    static let exampleDate = Date(timeIntervalSince1970: 1_788_825_600)

    static func f(_ n: Int64) -> RationalTime { RationalTime.frames(n, of: fd) }

    static var exampleClip: Clip {
        Clip(
            id: "clip-1", trackId: "track-v1", assetId: "asset-1", linkGroupId: "group-1", start: f(24),
            sourceIn: f(48),
            sourceOut: f(144), label: "Wide shot")
    }

    static var exampleCaption: Clip {
        Clip(
            id: "caption-1", trackId: "track-c1", start: f(24), sourceIn: .zero, sourceOut: f(36), text: "Hello there",
            words: [
                CaptionWord(text: "Hello", t0: .zero, t1: f(12)), CaptionWord(text: "there", t0: f(14), t1: f(30)),
            ],
            style: CaptionStyle(fontSize: 42))
    }

    static var exampleAsset: Asset {
        Asset(
            id: "asset-1", contentHash: "sha256-0123abcd", libraryPath: "2026/2026-09-08/IMG_1575.MOV",
            displayName: "IMG_1575.MOV", kind: .video, duration: f(720), hasVideo: true, hasAudio: true,
            sampleRate: 48000,
            frameDuration: fd,
            probe: Probe(
                codec: "hvc1", width: 1080, height: 1920, fps: Rational(24000, 1001), colorPrimaries: "bt2020",
                transfer: "arib-std-b67", rotation: 90, capturedAt: exampleDate,
                extra: ["gps": ["lat": 40.7, "lon": -74.0]]))
    }

    static var exampleTransition: Transition {
        Transition(
            id: "transition-1", trackId: "track-v1", leftClipId: "clip-1", rightClipId: "clip-2", kind: "dissolve",
            duration: f(12), alignment: .centered, params: ["curve": "easeInOut"])
    }

    static var exampleTrack: Track {
        Track(id: "track-v1", kind: .video, name: "V1", clips: ["clip-1": exampleClip])
    }

    static var exampleEffect: Effect {
        Effect(id: "effect-1", kind: "blur", params: ["radius": .constant(4), "mix": .constant(0.5)])
    }

    /// One example of every operation type, with every field populated where sensible.
    public static func exampleOperations() -> [Command.Operation] {
        [
            .createProject(
                .init(
                    id: "project-1", name: "Band Rehearsal", settings: ProjectSettings(),
                    sequence: .init(id: "sequence-1", name: "Sequence 1", frameDuration: fd, width: 1920, height: 1080))
            ),
            .setProjectSettings(.init(after: ProjectSettings(sampleRate: 44100, blendSpace: .linear))),
            .renameProject(.init(name: "Reel")),
            .addSequence(.init(id: "sequence-2", name: "Reel 9x16", frameDuration: fd, width: 1080, height: 1920)),
            .setSequenceSettings(
                .init(
                    sequenceId: "sequence-1", after: .init(name: "Main", frameDuration: fd, width: 3840, height: 2160))),
            .setActiveSequence(.init(sequenceId: "sequence-1")),
            .importAsset(
                .init(
                    id: "asset-1", contentHash: "sha256-0123abcd", libraryPath: "2026/2026-09-08/IMG_1575.MOV",
                    displayName: "IMG_1575.MOV", kind: .video, duration: f(720), hasVideo: true, hasAudio: true,
                    sampleRate: 48000, frameDuration: fd, probe: exampleAsset.probe)),
            .relinkAsset(.init(assetId: "asset-1", libraryPath: "2026/2026-09-09/IMG_1575.MOV", offline: false)),
            .removeAsset(.init(assetId: "asset-1")),
            .restoreAsset(.init(asset: exampleAsset)),
            .recordAssetAnalysis(
                .init(
                    assetId: "asset-1", kind: "transcript", cacheKey: "sha256-0123abcd/transcript/v1",
                    summary: ["words": 812])),
            .addTrack(.init(id: "track-v2", sequenceId: "sequence-1", kind: .video, name: "Overlay", position: 1)),
            .removeTrack(.init(trackId: "track-v2")),
            .reorderTrack(.init(trackId: "track-v2", position: 0)),
            .renameTrack(.init(trackId: "track-v2", name: "Titles")),
            .setTrackMuted(.init(trackId: "track-a1", muted: true)),
            .setTrackLocked(.init(trackId: "track-a1", locked: true)),
            .addClip(
                .init(
                    id: "clip-1", sequenceId: "sequence-1", trackId: "track-v1", assetId: "asset-1", at: f(24),
                    sourceIn: f(48), sourceOut: f(144), mode: .ripple, rippleScope: .sequence, link: .auto,
                    linkedId: "clip-1-audio", label: "Wide shot")),
            .moveClip(
                .init(clipId: "clip-1", to: .init(trackId: "track-v2", start: f(48)), mode: .overwrite, unlinked: false)
            ),
            .trimClip(
                .init(clipId: "clip-1", edge: .tail, to: f(96), mode: .ripple, rippleScope: .track, unlinked: false)),
            .splitClip(.init(clipId: "clip-1", at: f(60), newIds: ["clip-3", "clip-3-audio"], unlinked: false)),
            .joinClips(.init(leftClipId: "clip-1", rightClipId: "clip-3")),
            .removeClip(.init(clipId: "clip-1", mode: .ripple, rippleScope: .sequence, unlinked: false)),
            .setClipSpeed(.init(clipId: "clip-1", after: Rational(2, 1), mode: .ripple)),
            .setClipTransform(
                .init(clipId: "clip-1", after: .constant(Transform(x: 10, y: -10, scale: 1.5, rotation: 90)))),
            .setClipOpacity(
                .init(
                    clipId: "clip-1",
                    after: .keyframes([.init(t: .zero, value: 0, easing: .easeIn), .init(t: f(12), value: 1)]))),
            .setClipAudio(
                .init(clipId: "clip-1", after: ClipAudio(gain: .constant(0.8), muted: false, pitchCorrected: true))),
            .addEffect(
                .init(clipId: "clip-1", effectId: "effect-1", kind: "blur", params: exampleEffect.params, index: 0)),
            .updateEffect(
                .init(
                    clipId: "clip-1", effectId: "effect-1", kind: "blur", enabled: false,
                    params: ["radius": .constant(8)])),
            .removeEffect(.init(clipId: "clip-1", effectId: "effect-1")),
            .addTransition(
                .init(
                    id: "transition-1", leftClipId: "clip-1", rightClipId: "clip-2", kind: "dissolve", duration: f(12),
                    alignment: .centered, params: ["curve": "easeInOut"])),
            .updateTransition(
                .init(transitionId: "transition-1", kind: "wipe", duration: f(8), alignment: .startOnCut, params: [:])),
            .removeTransition(.init(transitionId: "transition-1")),
            .linkClips(.init(clipIds: ["clip-1", "clip-1-audio"], linkGroupId: "group-1")),
            .unlinkClips(.init(clipIds: ["clip-1", "clip-1-audio"])),
            .addCaptionTrack(
                .init(
                    id: "track-c1", sequenceId: "sequence-1", name: "Captions", language: "en",
                    style: CaptionStyle(fontSize: 42))),
            .replaceCaptions(
                .init(
                    trackId: "track-c1",
                    items: [
                        .init(
                            id: "caption-1", start: f(24), duration: f(36), text: "Hello there",
                            words: exampleCaption.words ?? []),
                        .init(
                            id: "caption-2", start: f(72), duration: f(48), text: "and welcome",
                            style: CaptionStyle(color: "#ffffff")),
                    ])),
            .editCaption(.init(clipId: "caption-1", text: "Hello, there", words: exampleCaption.words)),
            .setCaptionStyle(
                .init(
                    trackId: "track-c1", style: CaptionStyle(fontFamily: "Helvetica", fontSize: 48, position: "bottom"))
            ),
            .addMarker(.init(id: "marker-1", sequenceId: "sequence-1", at: f(48), label: "Chorus", colour: "blue")),
            .moveMarker(.init(markerId: "marker-1", to: f(60))),
            .removeMarker(.init(markerId: "marker-1")),
            .undo(.init(txnId: "txn-1")),
            .redo,
            .batch([
                .splitClip(.init(clipId: "clip-1", at: f(60))),
                .addTransition(.init(leftClipId: "clip-1", rightClipId: .ref(0), kind: "dissolve", duration: f(8))),
            ]),
        ]
    }

    /// One example of every event payload type.
    public static func examplePayloads() -> [EventPayload] {
        let clip = exampleClip
        var clip2 = clip
        clip2.id = "clip-2"
        clip2.start = f(120)
        clip2.sourceIn = f(300)
        clip2.sourceOut = f(400)
        clip2.linkGroupId = nil
        var right = clip
        right.id = "clip-3"
        right.start = f(60)
        right.sourceIn = f(84)
        right.linkGroupId = "group-2"
        let caption = exampleCaption
        var caption2 = caption
        caption2.id = "caption-2"
        caption2.start = f(72)
        caption2.text = "and welcome"
        caption2.words = []
        let sequence = Sequence(id: "sequence-1", name: "Sequence 1", frameDuration: fd, width: 1920, height: 1080)
        return [
            .projectCreated(
                .init(projectId: "project-1", name: "Band Rehearsal", settings: ProjectSettings(), sequence: sequence)),
            .projectSettingsChanged(
                .init(before: ProjectSettings(), after: ProjectSettings(sampleRate: 44100, blendSpace: .linear))),
            .projectRenamed(.init(before: "Band Rehearsal", after: "Reel")),
            .sequenceAdded(
                .init(sequenceId: "sequence-2", name: "Reel 9x16", frameDuration: fd, width: 1080, height: 1920)),
            .sequenceSettingsChanged(
                .init(
                    sequenceId: "sequence-1", before: SequenceSettings(sequence),
                    after: .init(name: "Main", frameDuration: fd, width: 3840, height: 2160))),
            .activeSequenceChanged(.init(before: "sequence-1", after: "sequence-2")),
            .assetImported(.init(exampleAsset)),
            .assetRelinked(
                .init(
                    assetId: "asset-1",
                    before: AssetLocation(libraryPath: "2026/2026-09-08/IMG_1575.MOV", offline: true),
                    after: AssetLocation(libraryPath: "2026/2026-09-09/IMG_1575.MOV", offline: false))),
            .assetRemoved(.init(assetId: "asset-1", snapshot: exampleAsset)),
            .assetRestored(.init(assetId: "asset-1", snapshot: exampleAsset)),
            .assetAnalysisRecorded(
                .init(
                    assetId: "asset-1", kind: "transcript", cacheKey: "sha256-0123abcd/transcript/v1",
                    summary: ["words": 812],
                    before: AssetAnalysis(kind: "transcript", cacheKey: "sha256-0123abcd/transcript/v0", summary: nil))),
            .trackAdded(
                .init(sequenceId: "sequence-1", trackId: "track-v2", kind: .video, position: 1, name: "Overlay")),
            .trackRemoved(.init(sequenceId: "sequence-1", trackId: "track-v1", position: 0, snapshot: exampleTrack)),
            .trackRestored(.init(sequenceId: "sequence-1", trackId: "track-v1", position: 0, snapshot: exampleTrack)),
            .trackReordered(.init(sequenceId: "sequence-1", trackId: "track-v2", before: 1, after: 0)),
            .trackRenamed(.init(sequenceId: "sequence-1", trackId: "track-v2", before: "Overlay", after: "Titles")),
            .trackMuteSet(.init(sequenceId: "sequence-1", trackId: "track-a1", before: false, after: true)),
            .trackLockSet(.init(sequenceId: "sequence-1", trackId: "track-a1", before: false, after: true)),
            .clipAdded(.init(sequenceId: "sequence-1", clipId: "clip-1", snapshot: clip)),
            .clipRemoved(.init(sequenceId: "sequence-1", clipId: "clip-1", snapshot: clip)),
            .clipMoved(
                .init(
                    sequenceId: "sequence-1", clipId: "clip-1",
                    before: ClipPlacement(trackId: "track-v1", start: f(24)),
                    after: ClipPlacement(trackId: "track-v2", start: f(48)))),
            .clipTrimmed(
                .init(
                    sequenceId: "sequence-1", clipId: "clip-1", edge: .tail, before: ClipRange(clip),
                    after: ClipRange(start: f(24), sourceIn: f(48), sourceOut: f(120)))),
            .clipSplit(
                .init(
                    sequenceId: "sequence-1", clipId: "clip-1", at: f(60), newClipId: "clip-3", before: ClipRange(clip),
                    after: ClipRange(start: f(24), sourceIn: f(48), sourceOut: f(84)), newClip: right)),
            .clipsJoined(
                .init(
                    sequenceId: "sequence-1", keptClipId: "clip-1", removedClipId: "clip-3",
                    keptBefore: ClipRange(start: f(24), sourceIn: f(48), sourceOut: f(84)), keptAfter: ClipRange(clip),
                    removedSnapshot: right)),
            .clipSpeedSet(.init(sequenceId: "sequence-1", clipId: "clip-1", before: .one, after: Rational(2, 1))),
            .clipTransformSet(
                .init(
                    sequenceId: "sequence-1", clipId: "clip-1", before: .constant(.identity),
                    after: .constant(Transform(x: 10, y: -10, scale: 1.5, rotation: 90)))),
            .clipOpacitySet(
                .init(
                    sequenceId: "sequence-1", clipId: "clip-1", before: .constant(1),
                    after: .keyframes([.init(t: .zero, value: 0, easing: .easeIn), .init(t: f(12), value: 1)]))),
            .clipAudioSet(
                .init(
                    sequenceId: "sequence-1", clipId: "clip-1", before: ClipAudio(),
                    after: ClipAudio(gain: .constant(0.8), muted: true))),
            .clipEffectAdded(
                .init(sequenceId: "sequence-1", clipId: "clip-1", effectId: "effect-1", index: 0, after: exampleEffect)),
            .clipEffectChanged(
                .init(
                    sequenceId: "sequence-1", clipId: "clip-1", effectId: "effect-1", before: exampleEffect,
                    after: Effect(id: "effect-1", kind: "blur", enabled: false, params: ["radius": .constant(8)]))),
            .clipEffectRemoved(
                .init(sequenceId: "sequence-1", clipId: "clip-1", effectId: "effect-1", index: 0, before: exampleEffect)
            ),
            .clipsLinked(.init(sequenceId: "sequence-1", linkGroupId: "group-1", clipIds: ["clip-1", "clip-1-audio"])),
            .clipsUnlinked(
                .init(sequenceId: "sequence-1", linkGroupId: "group-1", clipIds: ["clip-1", "clip-1-audio"])),
            .transitionAdded(.init(sequenceId: "sequence-1", transitionId: "transition-1", after: exampleTransition)),
            .transitionChanged(
                .init(
                    sequenceId: "sequence-1", transitionId: "transition-1", before: exampleTransition,
                    after: Transition(
                        id: "transition-1", trackId: "track-v1", leftClipId: "clip-1", rightClipId: "clip-2",
                        kind: "wipe",
                        duration: f(8), alignment: .startOnCut))),
            .transitionRemoved(
                .init(sequenceId: "sequence-1", transitionId: "transition-1", before: exampleTransition)),
            .captionTrackAdded(
                .init(
                    sequenceId: "sequence-1", trackId: "track-c1", name: "Captions", position: 2, language: "en",
                    style: CaptionStyle(fontSize: 42))),
            .captionsReplaced(
                .init(sequenceId: "sequence-1", trackId: "track-c1", before: [caption], after: [caption, caption2])),
            .captionEdited(
                .init(
                    sequenceId: "sequence-1", clipId: "caption-1", before: caption.caption!,
                    after: CaptionItem(text: "Hello, there", words: caption.words ?? [], style: caption.style))),
            .captionStyleSet(
                .init(
                    sequenceId: "sequence-1", trackId: "track-c1", clipId: "caption-1",
                    before: CaptionStyle(fontSize: 42),
                    after: CaptionStyle(fontFamily: "Helvetica", fontSize: 48, position: "bottom"))),
            .markerAdded(
                .init(
                    sequenceId: "sequence-1", markerId: "marker-1",
                    after: Marker(id: "marker-1", at: f(48), label: "Chorus", colour: "blue"))),
            .markerMoved(.init(sequenceId: "sequence-1", markerId: "marker-1", before: f(48), after: f(60))),
            .markerRemoved(
                .init(
                    sequenceId: "sequence-1", markerId: "marker-1",
                    before: Marker(id: "marker-1", at: f(60), label: "Chorus", colour: "blue"))),
            .transactionUndone(.init(targetTxnId: "txn-1")),
            .transactionRedone(.init(targetTxnId: "txn-1")),
        ]
    }

    /// One full example event per type, keyed by type name, with a stable envelope.
    public static func exampleEvents() -> [String: DomainEvent] {
        var result: [String: DomainEvent] = [:]
        for (i, payload) in examplePayloads().enumerated() {
            let n = String(format: "%03d", i + 1)
            result[payload.typeName] = DomainEvent(
                eventId: EventID("00000000-0000-7000-8000-000000000\(n)"), txnId: "txn-2", commandId: "command-2",
                actor: .agent(sessionId: "session-1"), occurredAt: exampleDate.addingTimeInterval(Double(i)),
                causationId: payload.isHistoryMarker ? nil : "00000000-0000-7000-8000-000000000000",
                metadata: ["tool": "timeline_apply"], payload: payload)
        }
        return result
    }
}
