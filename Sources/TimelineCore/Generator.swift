import Foundation

/// SplitMix64: a tiny deterministic generator for seeded tests and fixtures.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Builds projects by running commands through `decide`, so everything it produces is valid by
/// construction. Keeps the event log and the history fold, which fixtures and tests reuse.
public final class ProjectBuilder {
    public private(set) var project: Project
    public private(set) var history: History
    public let ids: any IDGenerator
    public let clock: any Clock
    public var actor: Actor = .human
    private var commandCounter: UInt64 = 0

    public init(
        project: Project = .blank, history: History = History(), ids: any IDGenerator = SequentialIDGenerator(),
        clock: any Clock = FixedClock(step: 1)
    ) {
        self.project = project
        self.history = history
        self.ids = ids
        self.clock = clock
    }

    public var events: [DomainEvent] { history.allEvents }

    /// A fresh command envelope for `operation`.
    public func command(_ operation: Command.Operation, expectedVersion: Int64? = nil, label: String? = nil) -> Command
    {
        commandCounter += 1
        return Command(
            commandId: CommandID(minting: ids), actor: actor, expectedVersion: expectedVersion, label: label,
            operation: operation)
    }

    /// Decides, folds, and records `command` as one transaction.
    @discardableResult
    public func apply(_ command: Command) throws(EditorError) -> [DomainEvent] {
        let events = try decide(project, command, ids: ids, clock: clock, history: history)
        guard !events.isEmpty else { return [] }
        evolve(&project, events)
        history.append(Transaction(events: events, label: command.effectiveLabel))
        return events
    }

    @discardableResult
    public func apply(_ operation: Command.Operation, label: String? = nil) throws(EditorError) -> [DomainEvent] {
        try apply(command(operation, label: label))
    }

    // MARK: Convenience

    public var sequence: Sequence {
        guard let s = project.activeSequence ?? project.sequences.values.first else {
            preconditionFailure("Project has no sequence")
        }
        return s
    }

    public var sequenceId: SequenceID { sequence.id }
    public var videoTracks: [Track] { sequence.tracks.filter { $0.kind == .video } }
    public var audioTracks: [Track] { sequence.tracks.filter { $0.kind == .audio } }
    public var captionTracks: [Track] { sequence.tracks.filter { $0.kind == .caption } }

    public func clip(_ id: ClipID) -> Clip? { sequence.clip(id) }

    @discardableResult
    public func createProject(
        name: String = "Untitled", sequenceName: String = "Sequence 1",
        frameDuration: RationalTime = RationalTime(1001, 24000),
        width: Int = 1920, height: Int = 1080
    ) throws(EditorError) -> SequenceID {
        try apply(
            .createProject(
                .init(
                    name: name,
                    sequence: .init(name: sequenceName, frameDuration: frameDuration, width: width, height: height))))
        return sequenceId
    }

    @discardableResult
    public func addTracks(_ kind: TrackKind, count: Int) throws(EditorError) -> [TrackID] {
        var result: [TrackID] = []
        for _ in 0..<count {
            let id: TrackID = TrackID(minting: ids)
            try apply(.addTrack(.init(id: id, sequenceId: .id(sequenceId), kind: kind)))
            result.append(id)
        }
        return result
    }

    @discardableResult
    public func importAsset(
        name: String, duration: RationalTime, hasVideo: Bool = true, hasAudio: Bool = true, sampleRate: Int? = 48000,
        frameDuration: RationalTime? = RationalTime(1001, 24000), contentHash: String? = nil
    ) throws(EditorError) -> AssetID {
        let id = AssetID(minting: ids)
        let kind: AssetKind = hasVideo ? .video : .audio
        let hash = contentHash ?? "sha256-" + id.rawValue.replacingOccurrences(of: "-", with: "")
        try apply(
            .importAsset(
                .init(
                    id: id, contentHash: hash, libraryPath: "2026/2026-09-08/\(name)", displayName: name, kind: kind,
                    duration: duration, hasVideo: hasVideo, hasAudio: hasAudio, sampleRate: hasAudio ? sampleRate : nil,
                    frameDuration: hasVideo ? frameDuration : nil,
                    probe: Probe(
                        codec: hasVideo ? "hvc1" : "aac", width: hasVideo ? 1920 : nil, height: hasVideo ? 1080 : nil)))
        )
        return id
    }

    /// Adds a clip in overwrite mode (positions are exact) and returns its id.
    @discardableResult
    public func addClip(
        track: TrackID, asset: AssetID?, at: RationalTime, sourceIn: RationalTime, sourceOut: RationalTime,
        link: LinkMode = .none, mode: EditMode = .overwrite, id: ClipID? = nil, linkedId: ClipID? = nil
    ) throws(EditorError) -> ClipID {
        let clipId = id ?? ClipID(minting: ids)
        try apply(
            .addClip(
                .init(
                    id: clipId, sequenceId: .id(sequenceId), trackId: .id(track), assetId: asset.map { .id($0) },
                    at: at,
                    sourceIn: sourceIn, sourceOut: sourceOut, mode: mode, link: link, linkedId: linkedId)))
        return clipId
    }
}

/// Random valid projects from a seed. Every clip is placed through `decide`, so the result satisfies
/// the invariants; the shape (tracks, clip counts, links, transitions, captions, markers) is tunable.
public struct ProjectGenerator: Sendable {
    public var seed: UInt64
    public var videoTracks: ClosedRange<Int> = 1...3
    public var audioTracks: ClosedRange<Int> = 1...2
    public var clipsPerTrack: ClosedRange<Int> = 0...6
    public var assetCount: ClosedRange<Int> = 1...4
    public var linkedClips = true
    public var transitions = true
    public var markers = true
    public var captions = true
    public var frameDuration = RationalTime(1001, 24000)

    public init(seed: UInt64) { self.seed = seed }

    public func generate() throws(EditorError) -> Project { try builder().project }

    /// The builder after generation, with the event log that produced the project.
    public func builder() throws(EditorError) -> ProjectBuilder {
        var rng = SeededRandom(seed: seed)
        let b = ProjectBuilder(ids: SequentialIDGenerator(millis: seed & 0xFFFF_FFFF_FFFF), clock: FixedClock(step: 1))
        try b.createProject(name: "Generated \(seed)", frameDuration: frameDuration)
        let fd = frameDuration
        let vTracks = try b.addTracks(.video, count: Int.random(in: videoTracks, using: &rng))
        let aTracks = try b.addTracks(.audio, count: Int.random(in: audioTracks, using: &rng))
        var assets: [(id: AssetID, duration: RationalTime, av: Bool)] = []
        for i in 0..<Int.random(in: assetCount, using: &rng) {
            let frames = Int64.random(in: 48...720, using: &rng)
            let av = i % 3 != 2
            let duration = av ? RationalTime.frames(frames, of: fd) : RationalTime(frames * 2000 + 17, 48000)
            let id = try b.importAsset(
                name: av ? "clip-\(i).mov" : "audio-\(i).wav", duration: duration, hasVideo: av, hasAudio: true)
            assets.append((id, duration, av))
        }
        // Per-track cursors in timeline time; linked pairs share a cursor across V and A.
        var cursors: [TrackID: RationalTime] = [:]
        for t in vTracks + aTracks { cursors[t] = .zero }
        for (vi, track) in vTracks.enumerated() {
            for _ in 0..<Int.random(in: clipsPerTrack, using: &rng) {
                let asset = assets[Int.random(in: 0..<assets.count, using: &rng)]
                guard asset.av else { continue }
                let total = asset.duration.frameIndex(frameDuration: fd)
                let len = Int64.random(in: 1...Swift.max(1, Swift.min(total, 96)), using: &rng)
                let inFrame = Int64.random(in: 0...(total - len), using: &rng)
                let gap = Int64.random(in: 0...12, using: &rng)
                let partner = vi < aTracks.count ? aTracks[vi] : nil
                let link = linkedClips && partner != nil && Bool.random(using: &rng)
                var at = cursors[track]! + RationalTime.frames(gap, of: fd)
                if link, let p = partner { at = RationalTime.max(at, cursors[p]!) }
                try b.addClip(
                    track: track, asset: asset.id, at: at, sourceIn: RationalTime.frames(inFrame, of: fd),
                    sourceOut: RationalTime.frames(inFrame + len, of: fd), link: link ? .auto : .none)
                let end = at + RationalTime.frames(len, of: fd)
                cursors[track] = end
                if link, let p = partner { cursors[p] = end }
            }
        }
        // Sample-accurate audio-only clips on the audio tracks.
        for track in aTracks {
            for _ in 0..<Int.random(in: clipsPerTrack, using: &rng) {
                let asset = assets[Int.random(in: 0..<assets.count, using: &rng)]
                let totalSamples = Int64((asset.duration * 48000).value / Int64(asset.duration.timescale))
                guard totalSamples > 4800 else { continue }
                let len = Int64.random(in: 2400...Swift.min(totalSamples, 96000), using: &rng)
                let inSample = Int64.random(in: 0...(totalSamples - len), using: &rng)
                let gap = Int64.random(in: 0...24000, using: &rng)
                let at = cursors[track]! + RationalTime(gap, 48000)
                try b.addClip(
                    track: track, asset: asset.id, at: at, sourceIn: RationalTime(inSample, 48000),
                    sourceOut: RationalTime(inSample + len, 48000), link: .none)
                cursors[track] = at + RationalTime(len, 48000)
            }
        }
        if transitions {
            for track in b.sequence.tracks {
                let clips = track.clips.values.sorted { $0.start < $1.start }
                for (left, right) in zip(clips, clips.dropFirst()) where b.sequence.end(of: left) == right.start {
                    guard Bool.random(using: &rng) else { continue }
                    let max = Invariants.maxTransitionDuration(
                        left: left, right: right, alignment: .centered, in: b.sequence, assets: b.project.assets)
                    let frames = max.frameIndex(frameDuration: fd)
                    guard frames >= 2 else { continue }
                    let duration = RationalTime.frames(Int64.random(in: 2...Swift.min(frames, 24), using: &rng), of: fd)
                    try b.apply(
                        .addTransition(
                            .init(
                                leftClipId: .id(left.id), rightClipId: .id(right.id), kind: "dissolve",
                                duration: duration)))
                }
            }
        }
        if captions {
            let trackId = TrackID(minting: b.ids)
            try b.apply(.addCaptionTrack(.init(id: trackId, sequenceId: .id(b.sequenceId), language: "en")))
            var items: [Command.Operation.CaptionInput] = []
            var cursor: Int64 = 0
            for i in 0..<Int.random(in: 0...5, using: &rng) {
                cursor += Int64.random(in: 0...24, using: &rng)
                let len = Int64.random(in: 12...48, using: &rng)
                items.append(
                    .init(
                        start: RationalTime.frames(cursor, of: fd), duration: RationalTime.frames(len, of: fd),
                        text: "Caption \(i)",
                        words: [CaptionWord(text: "Caption", t0: .zero, t1: RationalTime.frames(len / 2, of: fd))]))
                cursor += len
            }
            if !items.isEmpty { try b.apply(.replaceCaptions(.init(trackId: .id(trackId), items: items))) }
        }
        if markers {
            for i in 0..<Int.random(in: 0...3, using: &rng) {
                try b.apply(
                    .addMarker(
                        .init(
                            sequenceId: .id(b.sequenceId),
                            at: RationalTime.frames(Int64.random(in: 0...500, using: &rng), of: fd),
                            label: "Marker \(i)", colour: "red")))
            }
        }
        return b
    }
}

/// Loads the JSON fixtures in `Fixtures/` and rebuilds the canonical ones from code, so a test can
/// prove the checked-in files match what the current model produces.
public enum ProjectFixtures {
    public static let names = ["empty", "three-clips", "linked-transition-caption-undone"]

    public static func url(
        _ name: String, extension ext: String = "json", subdirectory: String = "Fixtures", in bundle: Bundle
    )
        throws -> URL
    {
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(subdirectory)/\(name).\(ext)"])
        }
        return url
    }

    public static func load(_ name: String, from bundle: Bundle) throws -> Project {
        try ProjectCodec.decoder.decode(Project.self, from: Data(contentsOf: url(name, in: bundle)))
    }

    public static func loadEvents(_ name: String, from bundle: Bundle) throws -> [DomainEvent] {
        try ProjectCodec.decoder.decode(
            [DomainEvent].self, from: Data(contentsOf: url(name, extension: "events.json", in: bundle)))
    }

    /// Loads `Fixtures/events/<type>.json`.
    public static func loadEventExample(_ type: String, from bundle: Bundle) throws -> DomainEvent {
        try ProjectCodec.decoder.decode(
            DomainEvent.self, from: Data(contentsOf: url(type, subdirectory: "Fixtures/events", in: bundle)))
    }

    /// The builder for a named fixture; `events` is its log.
    public static func builder(for name: String) throws(EditorError) -> ProjectBuilder {
        switch name {
        case "empty": try empty()
        case "three-clips": try threeClips()
        case "linked-transition-caption-undone": try linkedTransitionCaptionUndone()
        default: throw .notFound(id: name)
        }
    }

    static func fresh() -> ProjectBuilder {
        ProjectBuilder(
            ids: SequentialIDGenerator(), clock: FixedClock(Date(timeIntervalSince1970: 1_788_825_600), step: 1))
    }

    /// A created project with one empty V1/A1 pair.
    public static func empty() throws(EditorError) -> ProjectBuilder {
        let b = fresh()
        try b.createProject(name: "Empty")
        try b.addTracks(.video, count: 1)
        try b.addTracks(.audio, count: 1)
        return b
    }

    /// Three unlinked video clips back to back on V1 from two assets, plus an audio clip on A1.
    public static func threeClips() throws(EditorError) -> ProjectBuilder {
        let b = fresh()
        let fd = RationalTime(1001, 24000)
        try b.createProject(name: "Three clips")
        let v = try b.addTracks(.video, count: 1)[0]
        let a = try b.addTracks(.audio, count: 1)[0]
        let cam = try b.importAsset(name: "IMG_1575.MOV", duration: RationalTime.frames(720, of: fd))
        let screen = try b.importAsset(
            name: "Screen Recording.mov", duration: RationalTime.frames(480, of: fd), hasAudio: false)
        let music = try b.importAsset(
            name: "band-mix-v3.wav", duration: RationalTime(48000 * 120, 48000), hasVideo: false)
        try b.addClip(
            track: v, asset: cam, at: .zero, sourceIn: RationalTime.frames(24, of: fd),
            sourceOut: RationalTime.frames(120, of: fd))
        try b.addClip(
            track: v, asset: screen, at: RationalTime.frames(96, of: fd), sourceIn: .zero,
            sourceOut: RationalTime.frames(48, of: fd))
        try b.addClip(
            track: v, asset: cam, at: RationalTime.frames(144, of: fd), sourceIn: RationalTime.frames(240, of: fd),
            sourceOut: RationalTime.frames(360, of: fd))
        try b.addClip(
            track: a, asset: music, at: RationalTime(12000, 48000), sourceIn: .zero,
            sourceOut: RationalTime(48000 * 11, 48000))
        return b
    }

    /// Two linked clips from one video+audio asset, a dissolve with handles between two video clips,
    /// a caption track with items, a marker, and a final transaction that was undone.
    public static func linkedTransitionCaptionUndone() throws(EditorError) -> ProjectBuilder {
        let b = fresh()
        let fd = RationalTime(1001, 24000)
        try b.createProject(name: "Linked, transition, captions, undone")
        let v = try b.addTracks(.video, count: 1)[0]
        _ = try b.addTracks(.audio, count: 1)[0]
        let cam = try b.importAsset(name: "IMG_1581.MOV", duration: RationalTime.frames(600, of: fd))
        let first = try b.addClip(
            track: v, asset: cam, at: .zero, sourceIn: RationalTime.frames(24, of: fd),
            sourceOut: RationalTime.frames(120, of: fd),
            link: .auto)
        let second = try b.addClip(
            track: v, asset: cam, at: RationalTime.frames(96, of: fd), sourceIn: RationalTime.frames(240, of: fd),
            sourceOut: RationalTime.frames(336, of: fd), link: .auto)
        try b.apply(
            .addTransition(
                .init(
                    leftClipId: .id(first), rightClipId: .id(second), kind: "dissolve",
                    duration: RationalTime.frames(12, of: fd))))
        let captions = TrackID(minting: b.ids)
        try b.apply(.addCaptionTrack(.init(id: captions, sequenceId: .id(b.sequenceId), language: "en")))
        try b.apply(
            .replaceCaptions(
                .init(
                    trackId: .id(captions),
                    items: [
                        .init(
                            start: RationalTime.frames(12, of: fd), duration: RationalTime.frames(36, of: fd),
                            text: "Hello there",
                            words: [
                                CaptionWord(text: "Hello", t0: .zero, t1: RationalTime.frames(12, of: fd)),
                                CaptionWord(
                                    text: "there", t0: RationalTime.frames(14, of: fd),
                                    t1: RationalTime.frames(30, of: fd)),
                            ]),
                        .init(
                            start: RationalTime.frames(60, of: fd), duration: RationalTime.frames(48, of: fd),
                            text: "and welcome",
                            style: CaptionStyle(fontSize: 42, color: "#ffffff")),
                    ])))
        try b.apply(
            .addMarker(
                .init(
                    sequenceId: .id(b.sequenceId), at: RationalTime.frames(48, of: fd), label: "Chorus", colour: "blue")
            ))
        try b.apply(
            .trimClip(.init(clipId: .id(second), edge: .tail, to: RationalTime.frames(180, of: fd), mode: .ripple)))
        try b.apply(.undo(.init()))
        return b
    }
}
