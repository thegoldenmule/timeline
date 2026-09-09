import AVFoundation
import Contracts
import CoreGraphics
import Foundation
import Synchronization
import TimelineCore

/// What the fake keeps inside a `Compiled`: the sequence it was compiled from and the synthetic file
/// its player item plays.
public struct FakeCompiledPayload: CompiledPayload {
    public var sequence: Sequence
    public var assets: [AssetID: Asset]
    public var mediaURL: URL?

    public init(sequence: Sequence, assets: [AssetID: Asset], mediaURL: URL?) {
        self.sequence = sequence
        self.assets = assets
        self.mediaURL = mediaURL
    }
}

/// Fingerprints that split a sequence the way RenderKit's compiler does. Structural: everything that
/// changes an `AVMutableComposition` track segment (track order and kind, clip placement, source range,
/// speed, asset identity and location, transition overlaps). Instruction: everything else.
public enum SequenceFingerprint {
    private struct Segment: Encodable {
        var clipId: ClipID
        var assetId: AssetID?
        var source: String?
        var start: RationalTime
        var sourceIn: RationalTime
        var sourceOut: RationalTime
        var speed: Rational
    }

    private struct TrackSegments: Encodable {
        var trackId: TrackID
        var kind: TrackKind
        var segments: [Segment]
    }

    private struct Overlap: Encodable {
        var transitionId: TransitionID
        var left: ClipID
        var right: ClipID
        var duration: RationalTime
        var alignment: TransitionAlignment
    }

    private struct Structure: Encodable {
        var frameDuration: RationalTime
        var width: Int
        var height: Int
        var tracks: [TrackSegments]
        var overlaps: [Overlap]
    }

    public static func structural(_ sequence: Sequence, assets: [AssetID: Asset]) -> String {
        let structure = Structure(
            frameDuration: sequence.frameDuration, width: sequence.width, height: sequence.height,
            tracks: sequence.tracks.map { track in
                TrackSegments(
                    trackId: track.id, kind: track.kind,
                    segments: track.clips.values.sorted { $0.start < $1.start }.map { clip in
                        let asset = clip.assetId.flatMap { assets[$0] }
                        return Segment(
                            clipId: clip.id, assetId: clip.assetId,
                            source: asset.map { "\($0.libraryPath)|\($0.offline)" }, start: clip.start,
                            sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: clip.speed)
                    })
            },
            overlaps: sequence.transitions.values.sorted { $0.id < $1.id }.map {
                Overlap(
                    transitionId: $0.id, left: $0.leftClipId, right: $0.rightClipId, duration: $0.duration,
                    alignment: $0.alignment)
            })
        return (try? StableHash.fnv1a(encoding: structure)) ?? "structure-unencodable"
    }

    /// Covers the whole sequence, so any edit changes it.
    public static func instruction(_ sequence: Sequence, assets: [AssetID: Asset]) -> String {
        struct Everything: Encodable {
            var sequence: Sequence
            var assets: [AssetID: Asset]
        }
        return (try? StableHash.fnv1a(encoding: Everything(sequence: sequence, assets: assets)))
            ?? "instruction-unencodable"
    }
}

/// A `Renderer` that records calls and returns real objects: `Compiled` tokens whose fingerprints make
/// `update` classify edits correctly, an `AVPlayerItem` over a synthetic clip generated once per fake,
/// solid-colour frames, and an export job that writes a tiny synthetic file.
public final class FakeRenderer: Renderer, Sendable {
    public enum Call: Sendable, Hashable {
        case compile(sequenceId: SequenceID, options: RenderOptions)
        case update(compiledId: CompiledID, structural: Bool)
        case playerItem(compiledId: CompiledID)
        case apply(compiledId: CompiledID)
        case frame(compiledId: CompiledID, at: RationalTime)
        case export(compiledId: CompiledID, preset: ExportPreset, url: URL)
    }

    private struct State {
        var calls: [Call] = []
        var directory: TestMedia.Directory?
        var media: [Bool: URL] = [:]
        var mediaDuration: Double
        var error: RenderError?
    }

    private let state: Mutex<State>

    /// - Parameter mediaDuration: length of the synthetic clip behind `playerItem`, seconds.
    public init(mediaDuration: Double = 2) {
        state = Mutex(State(mediaDuration: mediaDuration))
    }

    public var calls: [Call] { state.withLock { $0.calls } }
    public func reset() { state.withLock { $0.calls.removeAll() } }

    /// Makes every `compile`, `update`, and `frame` throw this until cleared.
    public func fail(with error: RenderError?) { state.withLock { $0.error = error } }

    // MARK: Renderer

    public func compile(_ sequence: Sequence, assets: [AssetID: Asset], options: RenderOptions) async throws -> Compiled
    {
        state.withLock { $0.calls.append(.compile(sequenceId: sequence.id, options: options)) }
        if let error = state.withLock({ $0.error }) { throw error }
        let hasAudio = options.audio && FakeRenderer.hasAudio(sequence, assets: assets)
        let url = try await mediaURL(hasAudio: hasAudio)
        return Compiled(
            sequenceId: sequence.id, structuralFingerprint: SequenceFingerprint.structural(sequence, assets: assets),
            instructionFingerprint: SequenceFingerprint.instruction(sequence, assets: assets),
            duration: FakeRenderer.duration(of: sequence), hasAudio: hasAudio, options: options,
            payload: FakeCompiledPayload(sequence: sequence, assets: assets, mediaURL: url))
    }

    public func update(_ compiled: Compiled, to sequence: Sequence, assets: [AssetID: Asset]) async throws
        -> RenderUpdate
    {
        if let error = state.withLock({ $0.error }) { throw error }
        let structural = SequenceFingerprint.structural(sequence, assets: assets)
        let hasAudio = compiled.options.audio && FakeRenderer.hasAudio(sequence, assets: assets)
        let url = try await mediaURL(hasAudio: hasAudio)
        let next = Compiled(
            sequenceId: sequence.id, structuralFingerprint: structural,
            instructionFingerprint: SequenceFingerprint.instruction(sequence, assets: assets),
            duration: FakeRenderer.duration(of: sequence), hasAudio: hasAudio, options: compiled.options,
            payload: FakeCompiledPayload(sequence: sequence, assets: assets, mediaURL: url))
        let isStructural = structural != compiled.structuralFingerprint || hasAudio != compiled.hasAudio
        state.withLock { $0.calls.append(.update(compiledId: compiled.id, structural: isStructural)) }
        return isStructural ? .structural(next) : .instructionsOnly(next)
    }

    @MainActor public func playerItem(for compiled: Compiled) -> AVPlayerItem {
        state.withLock { $0.calls.append(.playerItem(compiledId: compiled.id)) }
        let url =
            (compiled.payload as? FakeCompiledPayload)?.mediaURL
            ?? state.withLock { $0.media[compiled.hasAudio] ?? $0.media.values.first }
        guard let url else {
            preconditionFailure("FakeRenderer.playerItem needs a Compiled from this fake's compile")
        }
        let item = AVPlayerItem(url: url)
        item.seekingWaitsForVideoCompositionRendering = true
        return item
    }

    @MainActor public func apply(_ compiled: Compiled, to item: AVPlayerItem) {
        state.withLock { $0.calls.append(.apply(compiledId: compiled.id)) }
    }

    /// A solid frame whose hue follows `time / duration`, `size` or a quarter of the sequence size.
    public func frame(_ compiled: Compiled, at time: RationalTime, size: CGSize?) async throws -> CGImage {
        state.withLock { $0.calls.append(.frame(compiledId: compiled.id, at: time)) }
        if let error = state.withLock({ $0.error }) { throw error }
        try Task.checkCancellation()
        let sequence = (compiled.payload as? FakeCompiledPayload)?.sequence
        let fallback = CGSize(width: (sequence?.width ?? 1920) / 4, height: (sequence?.height ?? 1080) / 4)
        let fraction = compiled.duration.isPositive ? time.seconds / compiled.duration.seconds : 0
        return try SyntheticImages.solid(
            SyntheticImages.hue(fraction.truncatingRemainder(dividingBy: 1)), size: size ?? fallback)
    }

    /// Writes a half-second synthetic clip to `url` and returns an `ExportReceipt` as the payload.
    public func export(_ compiled: Compiled, preset: ExportPreset, to url: URL) -> Job {
        state.withLock { $0.calls.append(.export(compiledId: compiled.id, preset: preset, url: url)) }
        let sequenceId = compiled.sequenceId
        let duration = compiled.duration.seconds
        return Job(kind: .export, memoryClass: .medium, label: "Export \(preset.name)") { context in
            let started = Date()
            context.report(JobProgress(fraction: 0, stage: "encode"))
            try context.checkCancellation()
            let scratch = try TestMedia.Directory(prefix: "FakeExport")
            let clip = try await TestMedia.solidColor(
                .blue, size: CGSize(width: 320, height: 180), duration: 0.5, in: scratch.url, name: "export")
            try context.checkCancellation()
            context.report(JobProgress(fraction: 0.5, stage: "encode"))
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: clip.url, to: url)
            scratch.cleanup()
            context.report(.done)
            let receipt = ExportReceipt(
                preset: preset, sequenceId: sequenceId, projectVersion: nil, outputURL: url,
                durationSeconds: duration, startedAt: started, finishedAt: Date(),
                outputHash: try FileHash.sha256(of: url))
            return try JobOutcome(urls: [url], encoding: receipt)
        }
    }

    // MARK: Helpers

    static func hasAudio(_ sequence: Sequence, assets: [AssetID: Asset]) -> Bool {
        sequence.tracks.contains { track in
            track.clips.values.contains { clip in
                guard let id = clip.assetId, let asset = assets[id] else { return false }
                return asset.hasAudio && (track.kind == .audio || track.kind == .video)
            }
        }
    }

    static func duration(of sequence: Sequence) -> RationalTime {
        var end = RationalTime.zero
        for track in sequence.tracks {
            for clip in track.clips.values { end = RationalTime.max(end, sequence.end(of: clip)) }
        }
        return end
    }

    /// The synthetic clip for `hasAudio`, generated on first use and kept for the life of the fake.
    private func mediaURL(hasAudio: Bool) async throws -> URL {
        if let url = state.withLock({ $0.media[hasAudio] }) { return url }
        let (dir, seconds) = try state.withLock { s -> (URL, Double) in
            if s.directory == nil { s.directory = try TestMedia.Directory(prefix: "FakeRenderer") }
            return (s.directory!.url, s.mediaDuration)
        }
        let clip =
            hasAudio
            ? try await TestMedia.videoWithAudio(.tone(frequency: 440), duration: seconds, in: dir, name: "av")
            : try await TestMedia.colorBars(duration: seconds, in: dir, name: "bars")
        state.withLock { $0.media[hasAudio] = clip.url }
        return clip.url
    }
}

/// Tiny CoreGraphics helpers for the fakes' images.
public enum SyntheticImages {
    public struct RGB: Sendable, Hashable {
        public var r: Double
        public var g: Double
        public var b: Double
        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    public enum Error: Swift.Error { case contextFailed }

    /// A saturated colour at `fraction` of the hue circle.
    public static func hue(_ fraction: Double) -> RGB {
        let h = (fraction - fraction.rounded(.down)) * 6
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(h) {
        case 0: return RGB(r: 1, g: x, b: 0)
        case 1: return RGB(r: x, g: 1, b: 0)
        case 2: return RGB(r: 0, g: 1, b: x)
        case 3: return RGB(r: 0, g: x, b: 1)
        case 4: return RGB(r: x, g: 0, b: 1)
        default: return RGB(r: 1, g: 0, b: x)
        }
    }

    public static func context(size: CGSize) throws -> CGContext {
        guard
            let ctx = CGContext(
                data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Error.contextFailed }
        return ctx
    }

    public static func solid(_ color: RGB, size: CGSize) throws -> CGImage {
        let ctx = try context(size: size)
        ctx.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: CGSize(width: ctx.width, height: ctx.height)))
        guard let image = ctx.makeImage() else { throw Error.contextFailed }
        return image
    }

    /// A horizontal gradient from `from` to `to`.
    public static func gradient(from: RGB, to: RGB, size: CGSize) throws -> CGImage {
        let ctx = try context(size: size)
        let colors = [
            CGColor(srgbRed: from.r, green: from.g, blue: from.b, alpha: 1),
            CGColor(srgbRed: to.r, green: to.g, blue: to.b, alpha: 1),
        ]
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 1])
        else { throw Error.contextFailed }
        ctx.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: ctx.width, y: 0), options: [.drawsAfterEndLocation])
        guard let image = ctx.makeImage() else { throw Error.contextFailed }
        return image
    }
}
