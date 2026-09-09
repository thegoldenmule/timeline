import AVFoundation
import CoreMedia
import Foundation
import TimelineCore

/// One loaded source file: the `AVURLAsset` (kept alive: `AVAssetTrack.asset` is weak and `insertTimeRange`
/// fails with -12780 once it is gone, see spikes/preview-update), the video track and the audio track the
/// compiler uses, and what the compositor needs to know about the picture.
public final class MediaSource: @unchecked Sendable {
    public let url: URL
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack?
    let audioTrack: AVAssetTrack?
    public let duration: CMTime
    public let videoTrackID: CMPersistentTrackID?
    public let audioTrackID: CMPersistentTrackID?
    /// Natural (coded) size of the video track.
    public let naturalSize: CGSize
    /// The track's display matrix, in AVFoundation's top-left coordinate system.
    public let preferredTransform: CGAffineTransform
    /// `naturalSize` after `preferredTransform`: portrait iPhone footage is 2160x3840 here.
    public let displaySize: CGSize
    public let isHDR: Bool
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let yCbCrMatrix: String?
    /// The selected audio track's format (`kAudioFormatMPEG4AAC`, ...) and channel count.
    public let audioFormatID: AudioFormatID?
    public let audioChannels: Int?
    /// Every audio track's `(trackID, formatID, channels)`, so tests can prove the APAC track was skipped.
    public let audioCandidates: [AudioCandidate]

    public struct AudioCandidate: Sendable, Hashable {
        public var trackID: CMPersistentTrackID
        public var formatID: AudioFormatID
        public var channels: Int
    }

    init(url: URL) async throws {
        self.url = url
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.asset = asset
        let (tracks, duration) = try await asset.load(.tracks, .duration)
        self.duration = duration

        let video = tracks.first { $0.mediaType == .video }
        videoTrack = video
        videoTrackID = video?.trackID
        if let video {
            let (natural, transform, formats) = try await video.load(
                .naturalSize, .preferredTransform, .formatDescriptions)
            naturalSize = natural
            preferredTransform = transform
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            displaySize = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
            let format = formats.first
            colorPrimaries = format.flatMap { MediaSource.extension($0, kCMFormatDescriptionExtension_ColorPrimaries) }
            transferFunction = format.flatMap {
                MediaSource.extension($0, kCMFormatDescriptionExtension_TransferFunction)
            }
            yCbCrMatrix = format.flatMap { MediaSource.extension($0, kCMFormatDescriptionExtension_YCbCrMatrix) }
            isHDR = MediaSource.isHDRTransfer(transferFunction)
        } else {
            naturalSize = .zero
            preferredTransform = .identity
            displaySize = .zero
            colorPrimaries = nil
            transferFunction = nil
            yCbCrMatrix = nil
            isHDR = false
        }

        var candidates: [AudioCandidate] = []
        for track in tracks where track.mediaType == .audio {
            let formats = try await track.load(.formatDescriptions)
            guard let format = formats.first, let asbd = format.audioStreamBasicDescription else { continue }
            candidates.append(
                AudioCandidate(
                    trackID: track.trackID, formatID: asbd.mFormatID, channels: Int(asbd.mChannelsPerFrame)))
        }
        audioCandidates = candidates
        let chosen = MediaSource.selectAudio(candidates)
        audioTrack = chosen.flatMap { id in tracks.first { $0.trackID == id.trackID } }
        audioTrackID = chosen?.trackID
        audioFormatID = chosen?.formatID
        audioChannels = chosen?.channels
    }

    /// Prefer the stereo (or mono) AAC / PCM / ALAC track; never APAC (spatial) or anything exotic.
    /// docs/research/05-macos-platform.md: "explicitly map the first stereo AAC track; never `-map 0`".
    static func selectAudio(_ candidates: [AudioCandidate]) -> AudioCandidate? {
        let preferred: Set<AudioFormatID> = [
            kAudioFormatMPEG4AAC, kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatMPEG4AAC_HE,
            kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEGLayer3, kAudioFormatOpus, kAudioFormatFLAC,
        ]
        func score(_ c: AudioCandidate) -> Int {
            var s = 0
            if c.formatID == kAudioFormatAPAC { s += 100 }
            if !preferred.contains(c.formatID) { s += 10 }
            if c.channels > 2 { s += 1 }
            return s
        }
        return candidates.enumerated().min { (score($0.element), $0.offset) < (score($1.element), $1.offset) }?.element
    }

    static func isHDRTransfer(_ transfer: String?) -> Bool {
        guard let transfer else { return false }
        return transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    }

    static func `extension`(_ format: CMFormatDescription, _ key: CFString) -> String? {
        CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
    }
}

/// Loads each source file once per renderer and keeps it alive.
actor SourceCache {
    private var sources: [URL: MediaSource] = [:]
    private var loading: [URL: Task<MediaSource, any Error>] = [:]

    func source(for url: URL) async throws -> MediaSource {
        if let s = sources[url] { return s }
        if let task = loading[url] { return try await task.value }
        let task = Task { try await MediaSource(url: url) }
        loading[url] = task
        defer { loading[url] = nil }
        let source = try await task.value
        sources[url] = source
        return source
    }

    func invalidate(_ url: URL) {
        sources[url] = nil
    }
}
