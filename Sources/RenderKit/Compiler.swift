import AVFoundation
import Contracts
import CoreMedia
import Foundation
import TimelineCore

/// Sequence to AVFoundation (timeline-model.md section 9). Two passes: `structure` builds the composition and
/// remembers where every clip landed; `instructions` and `audioMix` derive the per-frame table and the mix
/// from a sequence plus a structure, so an instructions-only update never touches the composition.
struct SequenceCompiler: Sendable {
    let layout: LibraryLayout
    let sources: SourceCache

    /// Composition track ids: video pairs from 1, audio from 10001, the filler at 30000.
    static let videoTrackBase: CMPersistentTrackID = 1
    static let audioTrackBase: CMPersistentTrackID = 10001
    static let fillerTrackID: CMPersistentTrackID = 30000

    // MARK: Structure

    func structure(_ sequence: Sequence, assets: [AssetID: Asset], options: RenderOptions) async throws
        -> CompositionStructure
    {
        let duration = SequenceCompiler.duration(of: sequence)
        guard duration.isPositive else { throw RenderError.sequenceEmpty }

        // Resolve every referenced asset once: online sources are loaded, offline ones become slates.
        var loaded: [AssetID: MediaSource] = [:]
        var offline: [Asset] = []
        var stills: [AssetID: URL] = [:]
        for asset in referencedAssets(sequence, assets: assets) {
            let url = layout.url(for: asset)
            guard !asset.offline, FileManager.default.fileExists(atPath: url.path) else {
                offline.append(asset)
                continue
            }
            if asset.kind == .image {
                stills[asset.id] = url
                continue
            }
            do {
                loaded[asset.id] = try await sources.source(for: url)
            } catch {
                offline.append(asset)
            }
        }
        let fillerURL = try await FillerMedia.url()
        let filler = try await sources.source(for: fillerURL)
        guard let fillerTrack = filler.videoTrack else { throw RenderKitError.filler("no video track") }

        let composition = AVMutableComposition()
        var tracks: [CompositionTrackInfo] = []
        var videoPlacements: [ClipID: VideoPlacement] = [:]
        var audioPlacements: [ClipID: AudioPlacement] = [:]
        var compositionTracks: [CMPersistentTrackID: AVMutableCompositionTrack] = [:]
        var trackInfoIndex: [CMPersistentTrackID: Int] = [:]

        func compositionTrack(
            id: CMPersistentTrackID, mediaType: AVMediaType, role: CompositionTrackInfo.Role, modelTrack: TrackID?,
            slot: Int
        ) throws -> AVMutableCompositionTrack {
            if let t = compositionTracks[id] { return t }
            guard let t = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: id) else {
                throw RenderKitError.trackInsertFailed("cannot add \(mediaType.rawValue) track \(id)")
            }
            compositionTracks[id] = t
            trackInfoIndex[id] = tracks.count
            tracks.append(
                CompositionTrackInfo(trackID: id, role: role, modelTrackId: modelTrack, slot: slot, segments: []))
            return t
        }

        func insert(
            _ sourceTrack: AVAssetTrack, sourceRange: TimeRange, into track: AVMutableCompositionTrack,
            at start: RationalTime, timelineDuration: RationalTime
        ) throws {
            let range = CMTimeRange(sourceRange)
            do {
                try track.insertTimeRange(range, of: sourceTrack, at: CMTime(start))
            } catch {
                throw RenderKitError.trackInsertFailed("\(sourceTrack.trackID) \(sourceRange): \(error)")
            }
            let target = CMTime(timelineDuration)
            if CMTimeCompare(range.duration, target) != 0 {
                track.scaleTimeRange(CMTimeRange(start: CMTime(start), duration: range.duration), toDuration: target)
            }
        }

        func record(_ segment: SegmentInfo, on id: CMPersistentTrackID) {
            guard let i = trackInfoIndex[id] else { return }
            tracks[i].segments.append(segment)
        }

        /// A filler segment covering `range` (slates, generated clips, stills, the duration pin).
        func insertFiller(
            into track: AVMutableCompositionTrack, id: CMPersistentTrackID, clip: ClipID?, range: TimeRange
        )
            throws
        {
            let need = range.duration
            let available = RationalTime(FillerMedia.duration)
            let sourceRange = TimeRange(start: .zero, end: RationalTime.min(need, available))
            try insert(fillerTrack, sourceRange: sourceRange, into: track, at: range.start, timelineDuration: need)
            record(
                SegmentInfo(
                    clipId: clip, sourceURL: nil, sourceTrackID: fillerTrack.trackID, sourceRange: sourceRange,
                    targetRange: range, speed: need.ratio(to: sourceRange.duration), isFiller: true), on: id)
        }

        // The filler track pins the duration (an empty range cannot end a track, and the video composition
        // must cover the audio-only tail).
        let fillerComp = try compositionTrack(
            id: SequenceCompiler.fillerTrackID, mediaType: .video, role: .filler, modelTrack: nil, slot: 0)
        try insertFiller(
            into: fillerComp, id: SequenceCompiler.fillerTrackID, clip: nil,
            range: TimeRange(start: .zero, end: duration))

        // Transition handles per clip: left clips extend their tail, right clips their head.
        var tailExtension: [ClipID: RationalTime] = [:]
        var headExtension: [ClipID: RationalTime] = [:]
        for transition in sequence.transitions.values {
            let handles = transition.handles
            tailExtension[transition.leftClipId] = handles.left
            headExtension[transition.rightClipId] = handles.right
        }

        var hdrSources: [Bool] = []
        var hasAudio = false
        var nextAudioTrackID = SequenceCompiler.audioTrackBase

        for (trackIndex, track) in sequence.tracks.enumerated() {
            let clips = track.clips.values.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            switch track.kind {
            case .caption:
                continue
            case .video:
                var previousOnSlot: [Int: RationalTime] = [:]
                for (index, clip) in clips.enumerated() {
                    let slot = index % 2
                    let compID = SequenceCompiler.videoTrackBase + CMPersistentTrackID(trackIndex * 2 + slot)
                    let comp = try compositionTrack(
                        id: compID, mediaType: .video, role: .video, modelTrack: track.id, slot: slot)
                    let end = sequence.end(of: clip)
                    var head = headExtension[clip.id] ?? .zero
                    var tail = tailExtension[clip.id] ?? .zero
                    // Never overlap the previous clip on the same slot, and never run past the next one there.
                    if let previousEnd = previousOnSlot[slot], clip.start - head < previousEnd {
                        head = RationalTime.max(.zero, clip.start - previousEnd)
                    }
                    if index + 2 < clips.count {
                        let next = clips[index + 2]
                        let nextStart = next.start - (headExtension[next.id] ?? .zero)
                        if end + tail > nextStart { tail = RationalTime.max(.zero, nextStart - end) }
                    }
                    let asset = clip.assetId.flatMap { assets[$0] }
                    let source = clip.assetId.flatMap { loaded[$0] }
                    if let asset {
                        // Handles may not exceed the media (invariant 4 guarantees it for stored transitions).
                        let headSource = head * clip.speed
                        let tailSource = tail * clip.speed
                        if clip.sourceIn - headSource < .zero { head = clip.sourceIn / clip.speed }
                        if clip.sourceOut + tailSource > asset.duration {
                            tail = RationalTime.max(.zero, (asset.duration - clip.sourceOut) / clip.speed)
                        }
                    }
                    let range = TimeRange(start: clip.start - head, end: end + tail)
                    previousOnSlot[slot] = range.end
                    let content: LayerContent
                    if let source, let videoTrack = source.videoTrack {
                        let sourceRange = TimeRange(
                            start: clip.sourceIn - head * clip.speed, end: clip.sourceOut + tail * clip.speed)
                        try insert(
                            videoTrack, sourceRange: sourceRange, into: comp, at: range.start,
                            timelineDuration: range.duration)
                        record(
                            SegmentInfo(
                                clipId: clip.id, sourceURL: source.url, sourceTrackID: videoTrack.trackID,
                                sourceRange: sourceRange, targetRange: range, speed: clip.speed, isFiller: false),
                            on: compID)
                        hdrSources.append(source.isHDR)
                        content = .source(trackID: compID)
                    } else {
                        try insertFiller(into: comp, id: compID, clip: clip.id, range: range)
                        if let asset, let still = stills[asset.id] {
                            content = .still(still)
                        } else if let asset {
                            content = .slate(label: asset.displayName)
                        } else {
                            content = .generated
                        }
                    }
                    videoPlacements[clip.id] = VideoPlacement(
                        clipId: clip.id, trackIndex: trackIndex, compositionTrackID: compID,
                        range: CMTimeRange(range), content: content, source: source)
                }
            case .audio:
                guard options.audio else { continue }
                var previousOnSlot: [Int: RationalTime] = [:]
                var sharedTracks: [Int: CMPersistentTrackID] = [:]
                for (index, clip) in clips.enumerated() {
                    guard let assetId = clip.assetId, let asset = assets[assetId], asset.hasAudio else { continue }
                    hasAudio = true
                    guard let source = loaded[assetId], let audioTrack = source.audioTrack else { continue }
                    let slot = index % 2
                    let end = sequence.end(of: clip)
                    var head = headExtension[clip.id] ?? .zero
                    var tail = tailExtension[clip.id] ?? .zero
                    if let previousEnd = previousOnSlot[slot], clip.start - head < previousEnd {
                        head = RationalTime.max(.zero, clip.start - previousEnd)
                    }
                    if index + 2 < clips.count {
                        let next = clips[index + 2]
                        let nextStart = next.start - (headExtension[next.id] ?? .zero)
                        if end + tail > nextStart { tail = RationalTime.max(.zero, nextStart - end) }
                    }
                    if clip.sourceIn - head * clip.speed < .zero { head = clip.sourceIn / clip.speed }
                    if clip.sourceOut + tail * clip.speed > asset.duration {
                        tail = RationalTime.max(.zero, (asset.duration - clip.sourceOut) / clip.speed)
                    }
                    let range = TimeRange(start: clip.start - head, end: end + tail)
                    previousOnSlot[slot] = range.end
                    // Speed-changed clips get a dedicated track so the pitch algorithm is per clip and an
                    // instructions-only property (FakeRenderer treats `audio` as instruction-only).
                    let compID: CMPersistentTrackID
                    let compSlot: Int
                    if clip.speed == .one {
                        if let id = sharedTracks[slot] {
                            compID = id
                        } else {
                            compID = nextAudioTrackID
                            nextAudioTrackID += 1
                            sharedTracks[slot] = compID
                        }
                        compSlot = slot
                    } else {
                        compID = nextAudioTrackID
                        nextAudioTrackID += 1
                        compSlot = 2 + index
                    }
                    let comp = try compositionTrack(
                        id: compID, mediaType: .audio, role: .audio, modelTrack: track.id, slot: compSlot)
                    let sourceRange = TimeRange(
                        start: clip.sourceIn - head * clip.speed, end: clip.sourceOut + tail * clip.speed)
                    try insert(
                        audioTrack, sourceRange: sourceRange, into: comp, at: range.start,
                        timelineDuration: range.duration)
                    record(
                        SegmentInfo(
                            clipId: clip.id, sourceURL: source.url, sourceTrackID: audioTrack.trackID,
                            sourceRange: sourceRange, targetRange: range, speed: clip.speed, isFiller: false),
                        on: compID)
                    let fadeIn = overlap(
                        forRightClip: clip, head: head, in: sequence, transitions: sequence.transitions)
                    let fadeOut = overlap(
                        forLeftClip: clip, tail: tail, in: sequence, transitions: sequence.transitions)
                    audioPlacements[clip.id] = AudioPlacement(
                        clipId: clip.id, compositionTrackID: compID, range: CMTimeRange(range), fadeIn: fadeIn,
                        fadeOut: fadeOut)
                }
            }
        }

        let hdr = !hdrSources.isEmpty && hdrSources.allSatisfy { $0 }
        guard let frozen = composition.copy() as? AVComposition else {
            throw RenderKitError.trackInsertFailed("composition copy failed")
        }
        return CompositionStructure(
            composition: frozen, tracks: tracks, videoPlacements: videoPlacements, audioPlacements: audioPlacements,
            duration: CMTime(duration), hdr: hdr, hasAudio: options.audio && hasAudio, offlineAssets: offline,
            sources: loaded, filler: filler)
    }

    /// The overlap a transition puts on the right clip's head (its fade-in), in timeline time.
    private func overlap(
        forRightClip clip: Clip, head: RationalTime, in sequence: Sequence,
        transitions: [TransitionID: Transition]
    ) -> CMTimeRange? {
        guard let t = transitions.values.first(where: { $0.rightClipId == clip.id }),
            let left = sequence.clip(t.leftClipId)
        else { return nil }
        let start = clip.start - head
        let end = sequence.end(of: left) + t.handles.left
        guard end > start else { return nil }
        return CMTimeRange(TimeRange(start: start, end: end))
    }

    private func overlap(
        forLeftClip clip: Clip, tail: RationalTime, in sequence: Sequence, transitions: [TransitionID: Transition]
    ) -> CMTimeRange? {
        guard let t = transitions.values.first(where: { $0.leftClipId == clip.id }),
            let right = sequence.clip(t.rightClipId)
        else { return nil }
        let start = right.start - t.handles.right
        let end = sequence.end(of: clip) + tail
        guard end > start else { return nil }
        return CMTimeRange(TimeRange(start: start, end: end))
    }

    // MARK: Instructions

    func instructions(
        _ sequence: Sequence, assets: [AssetID: Asset], structure: CompositionStructure, blendSpace: BlendSpace
    ) -> InstructionTable {
        let size = CGSize(width: sequence.width, height: sequence.height)
        let duration = structure.duration

        // Per video track: placements in start order, with transitions between neighbours.
        struct Placed {
            var clip: Clip
            var placement: VideoPlacement
            var transitionToNext: Transition?
        }
        var perTrack: [[Placed]] = []
        var trackMuted: [Bool] = []
        var captions: [CaptionSpec] = []
        var boundaries: [CMTime] = [.zero, duration]
        for track in sequence.tracks {
            var placed: [Placed] = []
            trackMuted.append(track.muted)
            let clips = track.clips.values.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            switch track.kind {
            case .video:
                for clip in clips {
                    guard let p = structure.videoPlacements[clip.id] else { continue }
                    placed.append(Placed(clip: clip, placement: p, transitionToNext: nil))
                    boundaries.append(p.range.start)
                    boundaries.append(p.range.end)
                }
                for i in placed.indices.dropLast() {
                    let left = placed[i].clip
                    let right = placed[i + 1].clip
                    if let t = sequence.transitions.values.first(where: {
                        $0.leftClipId == left.id && $0.rightClipId == right.id
                    }) {
                        placed[i].transitionToNext = t
                    }
                }
            case .caption:
                guard !track.muted else { break }
                for clip in clips {
                    guard let item = clip.caption else { continue }
                    let start = clip.start
                    let end = sequence.end(of: clip)
                    let range = CMTimeRange(TimeRange(start: start, end: end))
                    let words = item.words.map { w in
                        let t0 = start + (w.t0 - clip.sourceIn) / clip.speed
                        let t1 = start + (w.t1 - clip.sourceIn) / clip.speed
                        return CaptionSpec.Word(text: w.text, range: CMTimeRange(TimeRange(start: t0, end: t1)))
                    }
                    let style = SequenceCompiler.resolve(item.style, over: track.captionStyle)
                    captions.append(
                        CaptionSpec(clipId: clip.id, text: item.text, words: words, style: style, timeRange: range))
                    boundaries.append(range.start)
                    boundaries.append(range.end)
                }
            case .audio:
                break
            }
            perTrack.append(placed)
        }

        let times = boundaries.filter { $0 >= .zero && $0 <= duration }.sorted().reduce(into: [CMTime]()) {
            if $0.last != $1 { $0.append($1) }
        }
        var cursors = [Int](repeating: 0, count: perTrack.count)
        var captionCursor = 0
        let sortedCaptions = captions.sorted { $0.timeRange.start < $1.timeRange.start }
        var instructions: [RenderInstruction] = []
        instructions.reserveCapacity(times.count)

        for (t0, t1) in zip(times, times.dropFirst()) {
            let range = CMTimeRange(start: t0, end: t1)
            var layers: [LayerSpec] = []
            var transitions: [Int: TransitionSpec] = [:]
            for trackIndex in perTrack.indices {
                let placed = perTrack[trackIndex]
                guard !placed.isEmpty, !trackMuted[trackIndex] else { continue }
                while cursors[trackIndex] < placed.count, placed[cursors[trackIndex]].placement.range.end <= t0 {
                    cursors[trackIndex] += 1
                }
                var i = cursors[trackIndex]
                var active: [Placed] = []
                while i < placed.count, placed[i].placement.range.start < t1 {
                    active.append(placed[i])
                    i += 1
                }
                guard !active.isEmpty else { continue }
                for p in active {
                    layers.append(SequenceCompiler.layer(for: p.clip, placement: p.placement))
                }
                if active.count == 2, let t = active[0].transitionToNext, t.rightClipId == active[1].clip.id {
                    let overlap = CMTimeRange(
                        start: active[1].placement.range.start, end: active[0].placement.range.end)
                    transitions[trackIndex] = TransitionSpec(
                        transitionId: t.id, trackIndex: trackIndex, kind: t.kind, params: t.params, overlap: overlap,
                        fromClip: active[0].clip.id, toClip: active[1].clip.id)
                }
            }
            while captionCursor < sortedCaptions.count, sortedCaptions[captionCursor].timeRange.end <= t0 {
                captionCursor += 1
            }
            var activeCaptions: [CaptionSpec] = []
            var c = captionCursor
            while c < sortedCaptions.count, sortedCaptions[c].timeRange.start < t1 {
                if sortedCaptions[c].timeRange.end > t0 { activeCaptions.append(sortedCaptions[c]) }
                c += 1
            }
            instructions.append(
                RenderInstruction(
                    timeRange: range, layers: layers, transitions: transitions, captions: activeCaptions,
                    blendSpace: blendSpace, hdr: structure.hdr, sequenceSize: size))
        }
        return InstructionTable(instructions)
    }

    static func layer(for clip: Clip, placement: VideoPlacement) -> LayerSpec {
        LayerSpec(
            clipId: clip.id, trackIndex: placement.trackIndex, content: placement.content,
            sourceTransform: placement.source?.preferredTransform ?? .identity,
            naturalSize: placement.source?.naturalSize ?? .zero, displaySize: placement.source?.displaySize ?? .zero,
            clipStart: CMTime(clip.start), transform: clip.transform, opacity: clip.opacity, effects: clip.effects)
    }

    static func resolve(_ style: CaptionStyle?, over base: CaptionStyle?) -> CaptionStyle {
        var out = base ?? CaptionStyle()
        guard let style else { return out }
        if let v = style.fontFamily { out.fontFamily = v }
        if let v = style.fontSize { out.fontSize = v }
        if let v = style.color { out.color = v }
        if let v = style.backgroundColor { out.backgroundColor = v }
        if let v = style.position { out.position = v }
        out.extra.merge(style.extra) { $1 }
        return out
    }

    // MARK: Audio mix

    func audioMix(_ sequence: Sequence, structure: CompositionStructure) -> AVAudioMix? {
        guard structure.hasAudio, !structure.audioPlacements.isEmpty else { return nil }
        let mutableTracks = structure.composition.tracks(withMediaType: .audio)
        var byTrack: [CMPersistentTrackID: [(Clip, AudioPlacement, Bool)]] = [:]
        for track in sequence.tracks where track.kind == .audio {
            for clip in track.clips.values {
                guard let p = structure.audioPlacements[clip.id] else { continue }
                byTrack[p.compositionTrackID, default: []].append((clip, p, track.muted))
            }
        }
        var parameters: [AVMutableAudioMixInputParameters] = []
        for compTrack in mutableTracks {
            guard let entries = byTrack[compTrack.trackID] else { continue }
            let params = AVMutableAudioMixInputParameters(track: compTrack)
            var algorithm: AVAudioTimePitchAlgorithm = .spectral
            for (clip, placement, trackMuted) in entries.sorted(by: { $0.1.range.start < $1.1.range.start }) {
                let gain = Float(
                    clip.audio.muted || trackMuted ? 0 : SequenceCompiler.value(of: clip.audio.gain, at: 0))
                if clip.speed != .one { algorithm = clip.audio.pitchCorrected ? .spectral : .varispeed }
                if let fadeIn = placement.fadeIn {
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain, timeRange: fadeIn)
                } else {
                    params.setVolume(gain, at: placement.range.start)
                }
                if let fadeOut = placement.fadeOut {
                    params.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0, timeRange: fadeOut)
                }
            }
            params.audioTimePitchAlgorithm = algorithm
            parameters.append(params)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix.copy() as? AVAudioMix
    }

    // MARK: Video composition

    static func videoComposition(
        _ table: InstructionTable, renderSize: CGSize, frameDuration: CMTime, hdr: Bool
    ) -> AVVideoComposition {
        var configuration = AVVideoComposition.Configuration(
            customVideoCompositorClass: hdr ? HDRTimelineCompositor.self : TimelineCompositor.self,
            frameDuration: frameDuration, instructions: table.instructions, renderSize: renderSize)
        if hdr {
            configuration.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            configuration.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
            configuration.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
            configuration.perFrameHDRDisplayMetadataPolicy = .propagate
        } else {
            configuration.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            configuration.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            configuration.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        return AVVideoComposition(configuration: configuration)
    }

    // MARK: Helpers

    static func duration(of sequence: Sequence) -> RationalTime {
        var end = RationalTime.zero
        for track in sequence.tracks {
            for clip in track.clips.values { end = RationalTime.max(end, sequence.end(of: clip)) }
        }
        return end
    }

    func referencedAssets(_ sequence: Sequence, assets: [AssetID: Asset]) -> [Asset] {
        var seen: Set<AssetID> = []
        var out: [Asset] = []
        for track in sequence.tracks {
            for clip in track.clips.values {
                guard let id = clip.assetId, !seen.contains(id), let asset = assets[id] else { continue }
                seen.insert(id)
                out.append(asset)
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Evaluates a `Double` animatable at `t` seconds from the clip start (linear between keyframes).
    static func value(of animatable: Animatable<Double>, at seconds: Double) -> Double {
        switch animatable {
        case .constant(let v): return v
        case .keyframes(let keys):
            guard let first = keys.first else { return 1 }
            guard seconds > first.t.seconds else { return first.value }
            for (a, b) in zip(keys, keys.dropFirst()) where seconds < b.t.seconds {
                let span = b.t.seconds - a.t.seconds
                let p = span > 0 ? (seconds - a.t.seconds) / span : 1
                return a.value + (b.value - a.value) * SequenceCompiler.ease(p, a.easing)
            }
            return keys.last!.value
        }
    }

    static func value(of animatable: Animatable<Transform>, at seconds: Double) -> Transform {
        switch animatable {
        case .constant(let v): return v
        case .keyframes(let keys):
            guard let first = keys.first else { return .identity }
            guard seconds > first.t.seconds else { return first.value }
            for (a, b) in zip(keys, keys.dropFirst()) where seconds < b.t.seconds {
                let span = b.t.seconds - a.t.seconds
                let p = span > 0 ? SequenceCompiler.ease((seconds - a.t.seconds) / span, a.easing) : 1
                func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * p }
                return Transform(
                    x: mix(a.value.x, b.value.x), y: mix(a.value.y, b.value.y),
                    scale: mix(a.value.scale, b.value.scale),
                    rotation: mix(a.value.rotation, b.value.rotation), anchorX: mix(a.value.anchorX, b.value.anchorX),
                    anchorY: mix(a.value.anchorY, b.value.anchorY))
            }
            return keys.last!.value
        }
    }

    static func ease(_ p: Double, _ easing: Easing) -> Double {
        switch easing {
        case .linear: p
        case .easeIn: p * p
        case .easeOut: 1 - (1 - p) * (1 - p)
        case .easeInOut: p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        case .hold: 0
        }
    }
}
