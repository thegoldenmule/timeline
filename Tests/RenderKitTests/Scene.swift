import AVFoundation
import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import RenderKit
import TimelineCore

/// A small 30 fps project over synthetic clips written into a scratch library, for the frame and
/// latency tests.
final class Scene {
    let library: ScratchLibrary
    let builder: ProjectBuilder
    let video: TrackID
    let audio: TrackID
    let frameDuration: RationalTime
    let size: CGSize

    static let fps = CMTime(value: 1, timescale: 30)

    init(
        _ prefix: String, width: Int = 640, height: Int = 360, frameDuration: RationalTime = RationalTime(1, 30),
        videoTracks: Int = 1
    ) throws {
        library = try ScratchLibrary(prefix: prefix)
        builder = ProjectBuilder()
        self.frameDuration = frameDuration
        size = CGSize(width: width, height: height)
        try builder.createProject(name: prefix, frameDuration: frameDuration, width: width, height: height)
        let v = try builder.addTracks(.video, count: videoTracks)
        video = v[0]
        audio = try builder.addTracks(.audio, count: 1)[0]
    }

    var sequence: Sequence { builder.sequence }
    var assets: [AssetID: Asset] { builder.project.assets }

    func frames(_ n: Int64) -> RationalTime { RationalTime.frames(n, of: frameDuration) }

    func renderer(blendSpace: BlendSpace = .gamma) -> AVFoundationRenderer {
        AVFoundationRenderer(layout: library.layout, blendSpace: blendSpace)
    }

    // MARK: Media

    func solid(_ color: TestMedia.Color, name: String, seconds: Double = 3, codec: TestMedia.VideoCodec = .h264)
        async throws -> TestMedia.Clip
    {
        try await TestMedia.solidColor(
            color, size: size, frameDuration: Scene.fps, duration: seconds, codec: codec, in: library.media, name: name)
    }

    func barcode(_ background: TestMedia.Color, name: String, seconds: Double = 3) async throws -> TestMedia.Clip {
        try await TestMedia.barcodeCounter(
            background: background, size: size, frameDuration: Scene.fps, duration: seconds, in: library.media,
            name: name)
    }

    func barcodeWithAudio(_ background: TestMedia.Color, name: String, seconds: Double = 3, frequency: Double = 440)
        async throws -> TestMedia.Clip
    {
        try await TestMedia.videoWithAudio(
            .tone(frequency: frequency), background: background, size: size, frameDuration: Scene.fps,
            duration: seconds,
            in: library.media, name: name)
    }

    // MARK: Editing

    @discardableResult
    func importClip(_ clip: TestMedia.Clip) throws -> AssetID {
        try builder.importClip(clip, frameDuration: frameDuration)
    }

    /// Adds `asset` on V1 at frame `at`, playing source frames `sourceIn..<sourceIn + count`.
    @discardableResult
    func add(
        _ asset: AssetID, at: Int64, sourceIn: Int64 = 0, count: Int64, link: LinkMode = .none, track: TrackID? = nil
    ) throws -> ClipID {
        try builder.addClip(
            track: track ?? video, asset: asset, at: frames(at), sourceIn: frames(sourceIn),
            sourceOut: frames(sourceIn + count),
            link: link)
    }

    @discardableResult
    func transition(
        _ left: ClipID, _ right: ClipID, kind: String = "dissolve", frames count: Int64,
        alignment: TransitionAlignment = .centered, params: [String: JSONValue] = [:]
    ) throws -> TransitionID {
        let id = TransitionID(minting: builder.ids)
        try builder.apply(
            .addTransition(
                .init(
                    id: id, leftClipId: .id(left), rightClipId: .id(right), kind: kind, duration: frames(count),
                    alignment: alignment, params: params)))
        return id
    }

    /// A caption track with one item.
    @discardableResult
    func caption(
        _ text: String, at: Int64, count: Int64, words: [(String, Int64, Int64)] = [], style: CaptionStyle? = nil
    ) throws -> TrackID {
        let track = TrackID(minting: builder.ids)
        try builder.apply(.addCaptionTrack(.init(id: track, sequenceId: .id(builder.sequenceId), language: "en")))
        try builder.apply(
            .replaceCaptions(
                .init(
                    trackId: .id(track),
                    items: [
                        .init(
                            start: frames(at), duration: frames(count), text: text,
                            words: words.map { CaptionWord(text: $0.0, t0: frames($0.1), t1: frames($0.2)) },
                            style: style)
                    ])))
        return track
    }
}

/// Region of the caption band in a top-left frame of `size`: the middle of the bottom fifth.
func captionBand(_ size: CGSize) -> CGRect {
    CGRect(x: size.width * 0.3, y: size.height * 0.8, width: size.width * 0.4, height: size.height * 0.15)
}

/// First frame the output delivers for the item's current time, polled at 1 ms.
@MainActor
func nextFrame(_ output: AVPlayerItemVideoOutput, item: AVPlayerItem, timeout: Duration = .seconds(5)) async
    -> CVPixelBuffer?
{
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let now = item.currentTime()
        if output.hasNewPixelBuffer(forItemTime: now),
            let buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil)
        {
            return buffer
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return nil
}

func bgraOutput() -> AVPlayerItemVideoOutput {
    AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
}
