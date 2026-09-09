// RenderKit: the AVFoundation compiler, compositor, preview update, and export.
// See docs/design/implementation-plan.md (RenderKit row) and docs/design/timeline-model.md section 9.
import AVFoundation
import CoreMedia
import Foundation
import TimelineCore

/// What `RenderKit.probe` learned about a file: enough to assert an export's codec, size, colour tags,
/// duration, and track kinds.
public struct MediaProbe: Sendable, Hashable {
    public struct TrackInfo: Sendable, Hashable {
        public var trackID: CMPersistentTrackID
        /// `video`, `audio`, `metadata`, `timecode`, or the raw media type.
        public var kind: String
        /// Four-character code of the format (`hvc1`, `avc1`, `apcn`, `aac `, `lpcm`, `apac`).
        public var codec: String
        public var channels: Int?
        public var sampleRate: Double?
    }

    public var codec: String?
    /// Display size after the track's transform.
    public var width: Int?
    public var height: Int?
    public var naturalWidth: Int?
    public var naturalHeight: Int?
    /// Degrees, from the display matrix.
    public var rotation: Int
    public var duration: RationalTime
    public var frameRate: Double?
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var yCbCrMatrix: String?
    public var bitDepth: Int?
    public var isHDR: Bool
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var audioCodec: String?
    public var audioChannels: Int?
    public var audioSampleRate: Double?
    public var tracks: [TrackInfo]
}

public enum RenderKit {
    /// Reads codec, size, colour tags, duration, and track kinds from a file.
    public static func probe(_ url: URL) async throws -> MediaProbe {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (tracks, duration) = try await asset.load(.tracks, .duration)
        var probe = MediaProbe(
            rotation: 0, duration: RationalTime(exactly: duration) ?? .zero, isHDR: false, hasVideo: false,
            hasAudio: false, tracks: [])
        for track in tracks {
            let formats = try await track.load(.formatDescriptions)
            let format = formats.first
            let codec = format.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
            var info = MediaProbe.TrackInfo(trackID: track.trackID, kind: track.mediaType.rawValue, codec: codec)
            switch track.mediaType {
            case .video:
                info.kind = "video"
                let (natural, transform, fps) = try await track.load(
                    .naturalSize, .preferredTransform, .nominalFrameRate)
                let rect = CGRect(origin: .zero, size: natural).applying(transform)
                if !probe.hasVideo {
                    probe.hasVideo = true
                    probe.codec = codec
                    probe.naturalWidth = Int(natural.width)
                    probe.naturalHeight = Int(natural.height)
                    probe.width = Int(abs(rect.width).rounded())
                    probe.height = Int(abs(rect.height).rounded())
                    probe.rotation = Int((atan2(Double(transform.b), Double(transform.a)) * 180 / .pi).rounded())
                    probe.frameRate = fps > 0 ? Double(fps) : nil
                    if let format {
                        probe.colorPrimaries = MediaSource.extension(
                            format, kCMFormatDescriptionExtension_ColorPrimaries)
                        probe.transferFunction = MediaSource.extension(
                            format, kCMFormatDescriptionExtension_TransferFunction)
                        probe.yCbCrMatrix = MediaSource.extension(format, kCMFormatDescriptionExtension_YCbCrMatrix)
                        probe.bitDepth =
                            CMFormatDescriptionGetExtension(
                                format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
                        probe.isHDR = MediaSource.isHDRTransfer(probe.transferFunction)
                    }
                }
            case .audio:
                info.kind = "audio"
                if let asbd = format?.audioStreamBasicDescription {
                    info.channels = Int(asbd.mChannelsPerFrame)
                    info.sampleRate = asbd.mSampleRate
                    info.codec = fourCC(asbd.mFormatID)
                }
                if !probe.hasAudio {
                    probe.hasAudio = true
                    probe.audioCodec = info.codec
                    probe.audioChannels = info.channels
                    probe.audioSampleRate = info.sampleRate
                }
            case .metadata: info.kind = "metadata"
            case .timecode: info.kind = "timecode"
            default: break
            }
            probe.tracks.append(info)
        }
        return probe
    }

    public static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }
}
