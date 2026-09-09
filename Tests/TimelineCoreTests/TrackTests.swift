import Foundation
import Testing
import TimelineCore

@Suite("Track mute and solo") struct TrackTests {
    /// A sequence of the given tracks, each named after its index so failures read.
    func sequence(_ tracks: [Track]) -> Sequence {
        Sequence(id: "s", name: "S", frameDuration: fd24, width: 1920, height: 1080, tracks: tracks)
    }

    func track(_ id: TrackID, _ kind: TrackKind, muted: Bool = false, solo: Bool = false) -> Track {
        Track(id: id, kind: kind, name: id.rawValue, muted: muted, locked: false, solo: solo)
    }

    @Test func aTrackWithNoMuteAndNoSoloAnywhereIsActive() {
        let seq = sequence([track("v1", .video), track("a1", .audio), track("c1", .caption)])
        #expect(seq.tracks.allSatisfy { seq.silence(of: $0) == nil })
        #expect(seq.tracks.allSatisfy { seq.isActive($0) })
        #expect(TrackKind.allCases.allSatisfy { !seq.hasSolo($0) })
    }

    @Test func mutingATrackSilencesOnlyThatTrack() {
        let seq = sequence([track("a1", .audio, muted: true), track("a2", .audio)])
        #expect(seq.silence(of: seq.tracks[0]) == .muted)
        #expect(seq.silence(of: seq.tracks[1]) == nil)
    }

    @Test func soloSilencesTheOtherTracksOfItsKindAndLeavesOtherKindsAlone() {
        let seq = sequence([
            track("v1", .video), track("a1", .audio), track("a2", .audio, solo: true), track("c1", .caption),
        ])
        #expect(seq.hasSolo(.audio))
        #expect(!seq.hasSolo(.video) && !seq.hasSolo(.caption))
        #expect(seq.silence(of: seq.tracks[1]) == .solo)
        #expect(seq.isActive(seq.tracks[2]))
        // The video and caption tracks are untouched: soloing A2 must not black out the picture.
        #expect(seq.isActive(seq.tracks[0]) && seq.isActive(seq.tracks[3]))
    }

    @Test func soloIsAdditiveAcrossSeveralTracks() {
        let seq = sequence([
            track("a1", .audio), track("a2", .audio, solo: true), track("a3", .audio, solo: true),
        ])
        #expect(seq.silence(of: seq.tracks[0]) == .solo)
        #expect(seq.isActive(seq.tracks[1]) && seq.isActive(seq.tracks[2]))
    }

    @Test func anExplicitMuteOutranksItsOwnSolo() {
        let seq = sequence([track("a1", .audio, muted: true, solo: true), track("a2", .audio)])
        #expect(seq.silence(of: seq.tracks[0]) == .muted)
        // A2 is still silenced by A1's solo even though A1 itself is not heard.
        #expect(seq.silence(of: seq.tracks[1]) == .solo)
    }

    @Test func soloOnTheOnlyTrackOfItsKindSilencesNothing() {
        let seq = sequence([track("v1", .video, solo: true), track("a1", .audio)])
        #expect(seq.tracks.allSatisfy { seq.isActive($0) })
    }

    @Test func aTrackWrittenBeforeSoloDecodesUnsoloed() throws {
        let json = """
            {"id":"a1","kind":"audio","name":"A1","muted":true,"locked":false,"clips":{}}
            """
        let track = try ProjectCodec.decode(Track.self, from: Data(json.utf8))
        #expect(track.muted && !track.solo)
        // And the field round-trips once it is written.
        var soloed = track
        soloed.solo = true
        #expect(try ProjectCodec.decode(Track.self, from: ProjectCodec.encode(soloed)) == soloed)
    }
}
