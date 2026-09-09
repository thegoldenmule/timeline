import Contracts
import Foundation
import TimelineCore

/// The two fingerprints `Renderer.update` diffs. Structural covers exactly what changes a composition track
/// segment (the same split as `SequenceFingerprint` in ContractsTestSupport, plus whether the file exists,
/// because a missing file becomes a slate); instruction covers the whole sequence.
///
/// Hashed with `Hasher`, not the canonical JSON encoder: a `Compiled` is an in-memory token compared only
/// against tokens from the same process, and JSON-encoding a 200-clip sequence cost 10 ms of a 10 ms budget.
enum RenderFingerprint {
    private struct Segment: Hashable {
        var clipId: ClipID
        var linkGroupId: LinkGroupID?
        var assetId: AssetID?
        var source: String?
        var start: RationalTime
        var sourceIn: RationalTime
        var sourceOut: RationalTime
        var speed: Rational
    }

    private struct TrackSegments: Hashable {
        var trackId: TrackID
        var kind: TrackKind
        var segments: [Segment]
    }

    private struct Overlap: Hashable {
        var transitionId: TransitionID
        var left: ClipID
        var right: ClipID
        var duration: RationalTime
        var alignment: TransitionAlignment
    }

    private struct Structure: Hashable {
        var frameDuration: RationalTime
        var width: Int
        var height: Int
        var audio: Bool
        var tracks: [TrackSegments]
        var overlaps: [Overlap]
    }

    static func structural(_ sequence: Sequence, assets: [AssetID: Asset], layout: LibraryLayout, audio: Bool) -> String
    {
        var presence: [AssetID: Bool] = [:]
        func present(_ asset: Asset) -> Bool {
            if let p = presence[asset.id] { return p }
            let p = FileManager.default.fileExists(atPath: layout.url(for: asset).path)
            presence[asset.id] = p
            return p
        }
        let structure = Structure(
            frameDuration: sequence.frameDuration, width: sequence.width, height: sequence.height, audio: audio,
            tracks: sequence.tracks.map { track in
                TrackSegments(
                    trackId: track.id, kind: track.kind,
                    segments: track.clips.values.sorted { ($0.start, $0.id) < ($1.start, $1.id) }.map { clip in
                        let asset = clip.assetId.flatMap { assets[$0] }
                        return Segment(
                            clipId: clip.id, linkGroupId: clip.linkGroupId, assetId: clip.assetId,
                            source: asset.map { "\($0.libraryPath)|\($0.offline || !present($0))|\($0.kind.rawValue)" },
                            start: clip.start, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: clip.speed)
                    })
            },
            overlaps: sequence.transitions.values.sorted { $0.id < $1.id }.map {
                Overlap(
                    transitionId: $0.id, left: $0.leftClipId, right: $0.rightClipId, duration: $0.duration,
                    alignment: $0.alignment)
            })
        var hasher = Hasher()
        hasher.combine(structure)
        return "s" + hex(hasher.finalize())
    }

    static func instruction(
        _ sequence: Sequence, assets: [AssetID: Asset], blendSpace: BlendSpace, quality: RenderQuality
    ) -> String {
        var hasher = Hasher()
        hasher.combine(sequence)
        hasher.combine(assets)
        hasher.combine(blendSpace)
        hasher.combine(quality)
        return "i" + hex(hasher.finalize())
    }

    private static func hex(_ value: Int) -> String {
        String(UInt(bitPattern: value), radix: 16)
    }
}
