import Foundation
import Testing
import TimelineCore

let fd24 = RationalTime(1001, 24000)

func frames(_ n: Int64) -> RationalTime { RationalTime.frames(n, of: fd24) }

extension ProjectBuilder {
    /// Runs `operation` and returns the error it was rejected with, or nil if it was accepted.
    func rejection(_ operation: Command.Operation) -> EditorError? {
        do {
            try apply(operation)
            return nil
        } catch {
            return error
        }
    }

    var v1: TrackID { videoTracks[0].id }
    var a1: TrackID { audioTracks[0].id }

    func start(_ id: ClipID) -> RationalTime { clip(id)!.start }
    func end(_ id: ClipID) -> RationalTime { sequence.end(of: clip(id)!) }
}

/// A two-track project with one video+audio asset and helpers for the common layouts.
struct Scene {
    let b: ProjectBuilder
    let asset: AssetID
    let v: TrackID
    let a: TrackID

    init(assetFrames: Int64 = 600, videoTracks: Int = 1, audioTracks: Int = 1) throws(EditorError) {
        b = ProjectBuilder()
        try b.createProject()
        let vs = try b.addTracks(.video, count: videoTracks)
        let `as` = try b.addTracks(.audio, count: audioTracks)
        v = vs[0]
        a = `as`[0]
        asset = try b.importAsset(name: "cam.mov", duration: frames(assetFrames))
    }

    /// Adds an unlinked video clip of `length` frames at `at` frames reading source from `sourceIn` frames.
    @discardableResult
    func video(at: Int64, length: Int64, sourceIn: Int64 = 0, track: TrackID? = nil) throws(EditorError) -> ClipID {
        try b.addClip(
            track: track ?? v, asset: asset, at: frames(at), sourceIn: frames(sourceIn),
            sourceOut: frames(sourceIn + length))
    }

    /// Adds a linked V+A pair; returns the video clip id (its partner is found through the link group).
    @discardableResult
    func linked(at: Int64, length: Int64, sourceIn: Int64 = 0) throws(EditorError) -> ClipID {
        try b.addClip(
            track: v, asset: asset, at: frames(at), sourceIn: frames(sourceIn), sourceOut: frames(sourceIn + length),
            link: .auto)
    }

    func partner(of id: ClipID) -> Clip? {
        guard let g = b.clip(id)?.linkGroupId else { return nil }
        return b.sequence.members(of: g).first { $0.id != id }
    }
}
