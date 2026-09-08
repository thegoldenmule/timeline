import AVFoundation
import Contracts
import CoreImage
import Foundation
import TimelineCore

/// One audio track as the probe saw it.
public struct AudioTrackInfo: Hashable, Sendable, Codable {
    public var trackID: Int32
    /// Four-character code: `aac `, `lpcm`, `apac`, ...
    public var codec: String
    public var channels: Int
    public var sampleRate: Int
    /// True for the track the editor plays and analyses: the first stereo-or-mono AAC/PCM track, never the
    /// Spatial Audio (`apac`) track.
    public var isPrimary: Bool
}

/// Everything `probe(url:)` learns, in the shape `Asset` needs plus the audio track list.
public struct MediaInspection: Sendable {
    public var kind: AssetKind
    public var duration: RationalTime
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var sampleRate: Int?
    public var frameDuration: RationalTime?
    public var probe: Probe
    public var audioTracks: [AudioTrackInfo]
    public var capturedAt: Date?

    public var primaryAudioTrackID: Int32? { audioTracks.first(where: \.isPrimary)?.trackID }
}

/// `AVURLAsset`-based probing. `Probe.rotation` follows the ffmpeg display-matrix convention (degrees,
/// counter-clockwise positive): a portrait iPhone clip whose preferred transform is `(0, 1, -1, 0)` reports -90.
/// The raw transform is kept under `extra["transform"]`.
public enum MediaProbe {
    /// The nominal duration given to still images, which have none of their own.
    public static let stillImageDuration = RationalTime(10, 1)

    public static func inspect(_ url: URL) async throws -> MediaInspection {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.notFound(url) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? Int64) ?? Int64((attributes?[.size] as? Int) ?? 0)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        let video: [AVAssetTrack]
        let audio: [AVAssetTrack]
        do {
            video = try await asset.loadTracks(withMediaType: .video)
            audio = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            if let still = try inspectStill(url, fileSize: fileSize, attributes: attributes) { return still }
            throw MediaError.unreadable(url, reason: error.localizedDescription)
        }
        if video.isEmpty && audio.isEmpty {
            if let still = try inspectStill(url, fileSize: fileSize, attributes: attributes) { return still }
            throw MediaError.unreadable(url, reason: "no audio or video tracks")
        }

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw MediaError.unreadable(url, reason: error.localizedDescription)
        }
        var probe = Probe()
        probe.extra["fileSize"] = .number(Double(fileSize))
        probe.extra["durationSeconds"] = .number(duration.seconds)
        var frameDuration: RationalTime?

        if let track = video.first {
            try await inspectVideo(track, into: &probe, frameDuration: &frameDuration)
        }

        var tracks: [AudioTrackInfo] = []
        for track in audio {
            guard let format = try await track.load(.formatDescriptions).first else { continue }
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            tracks.append(
                AudioTrackInfo(
                    trackID: track.trackID, codec: fourCC(CMFormatDescriptionGetMediaSubType(format)),
                    channels: Int(asbd?.mChannelsPerFrame ?? 0), sampleRate: Int(asbd?.mSampleRate ?? 0),
                    isPrimary: false))
        }
        if let primary = primaryAudioTrackIndex(tracks) { tracks[primary].isPrimary = true }
        var sampleRate: Int?
        if let primary = tracks.first(where: \.isPrimary) {
            sampleRate = primary.sampleRate
            probe.extra["audioCodec"] = .string(primary.codec)
            probe.extra["channels"] = .number(Double(primary.channels))
            probe.extra["sampleRate"] = .number(Double(primary.sampleRate))
            probe.extra["primaryAudioTrackID"] = .number(Double(primary.trackID))
            if probe.codec == nil { probe.codec = primary.codec }
        }
        if !tracks.isEmpty {
            probe.extra["audioTracks"] = .array(tracks.compactMap { try? JSONValue(encoding: $0) })
        }

        let capturedAt = await captureMetadata(asset, into: &probe)
        probe.capturedAt = capturedAt ?? (attributes?[.creationDate] as? Date)

        return MediaInspection(
            kind: video.isEmpty ? .audio : .video, duration: RationalTime(cmValue: duration.value, timescale: duration.timescale),
            hasVideo: !video.isEmpty, hasAudio: !audio.isEmpty, sampleRate: sampleRate, frameDuration: frameDuration,
            probe: probe, audioTracks: tracks, capturedAt: capturedAt)
    }

    /// The track the editor plays and analyses: prefer a non-spatial (not `apac`) track with at most two
    /// channels, in track order; otherwise the first track.
    public static func primaryAudioTrackIndex(_ tracks: [AudioTrackInfo]) -> Int? {
        if let i = tracks.firstIndex(where: { $0.codec != "apac" && $0.channels <= 2 }) { return i }
        if let i = tracks.firstIndex(where: { $0.codec != "apac" }) { return i }
        return tracks.isEmpty ? nil : 0
    }

    // MARK: Video

    private static func inspectVideo(_ track: AVAssetTrack, into probe: inout Probe, frameDuration: inout RationalTime?)
        async throws
    {
        let size = try await track.load(.naturalSize)
        let nominal = try await track.load(.nominalFrameRate)
        let minFrame = try await track.load(.minFrameDuration)
        let transform = try await track.load(.preferredTransform)
        let bitrate = try await track.load(.estimatedDataRate)
        probe.width = Int(size.width.rounded())
        probe.height = Int(size.height.rounded())
        if minFrame.isNumeric, minFrame.value > 0 {
            frameDuration = RationalTime(cmValue: minFrame.value, timescale: minFrame.timescale)
            probe.fps = Rational(Int64(minFrame.timescale), minFrame.value).reduced
        } else if nominal > 0 {
            probe.fps = Rational(Int64((Double(nominal) * 1000).rounded()), 1000).reduced
        }
        probe.extra["nominalFrameRate"] = .number(Double(nominal))
        if bitrate > 0 { probe.extra["bitrate"] = .number(Double(bitrate)) }
        probe.rotation = rotationDegrees(transform)
        probe.extra["transform"] = .array([transform.a, transform.b, transform.c, transform.d].map { .number($0) })
        if let format = try await track.load(.formatDescriptions).first {
            probe.codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
            let primaries = extensionString(format, kCMFormatDescriptionExtension_ColorPrimaries)
            let transfer = extensionString(format, kCMFormatDescriptionExtension_TransferFunction)
            let matrix = extensionString(format, kCMFormatDescriptionExtension_YCbCrMatrix)
            probe.colorPrimaries = primaries.map(colorName)
            probe.transfer = transfer.map(colorName)
            if let matrix { probe.extra["matrix"] = .string(colorName(matrix)) }
            if let depth = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
                as? Int
            {
                probe.extra["bitsPerComponent"] = .number(Double(depth))
            }
            if let full = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo)
                as? Bool
            {
                probe.extra["fullRange"] = .bool(full)
            }
            let hdrFormat: String? =
                switch transfer {
                case kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as CFString?: "hlg"
                case kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as CFString?: "pq"
                default: nil
                }
            probe.extra["hdr"] = .bool(hdrFormat != nil)
            if let hdrFormat { probe.extra["hdrFormat"] = .string(hdrFormat) }
            var dolbyVision = false
            if let atoms = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            {
                dolbyVision = atoms.keys.contains { $0 == "dvcC" || $0 == "dvvC" || $0 == "dvwC" }
            }
            probe.extra["dolbyVision"] = .bool(dolbyVision)
        }
    }

    /// Degrees, counter-clockwise positive (ffmpeg display-matrix convention), rounded to the nearest integer.
    static func rotationDegrees(_ t: CGAffineTransform) -> Int {
        let radians = atan2(Double(t.b), Double(t.a))
        var degrees = Int((-radians * 180 / .pi).rounded())
        if degrees <= -180 { degrees += 360 }
        if degrees > 180 { degrees -= 360 }
        return degrees
    }

    private static func extensionString(_ format: CMFormatDescription, _ key: CFString) -> String? {
        CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
    }

    /// Core Media colour tags rendered as ffprobe-style names, so probes read the same across tools.
    static func colorName(_ tag: String) -> String {
        switch tag as CFString {
        case kCMFormatDescriptionColorPrimaries_ITU_R_709_2, kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2:
            "bt709"
        case kCMFormatDescriptionColorPrimaries_ITU_R_2020, kCMFormatDescriptionTransferFunction_ITU_R_2020,
            kCMFormatDescriptionYCbCrMatrix_ITU_R_2020:
            "bt2020"
        case kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG: "arib-std-b67"
        case kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ: "smpte2084"
        case kCMFormatDescriptionColorPrimaries_P3_D65: "smpte432"
        case kCMFormatDescriptionColorPrimaries_DCI_P3: "smpte431"
        case kCMFormatDescriptionColorPrimaries_SMPTE_C, kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4: "smpte170m"
        case kCMFormatDescriptionColorPrimaries_EBU_3213: "bt470bg"
        case kCMFormatDescriptionTransferFunction_sRGB: "iec61966-2-1"
        case kCMFormatDescriptionTransferFunction_Linear: "linear"
        case kCMFormatDescriptionTransferFunction_SMPTE_240M_1995: "smpte240m"
        default: tag
        }
    }

    // MARK: Metadata

    /// Fills make, model, software, and GPS into `extra` and returns the capture date, if any.
    private static func captureMetadata(_ asset: AVURLAsset, into probe: inout Probe) async -> Date? {
        var captured: Date?
        if let item = try? await asset.load(.creationDate) {
            captured = try? await item.load(.dateValue)
            if captured == nil, let text = try? await item.load(.stringValue) { captured = parseQuickTimeDate(text) }
        }
        let items = (try? await asset.load(.metadata)) ?? []
        for item in items {
            guard let identifier = item.identifier else { continue }
            switch identifier {
            case .quickTimeMetadataMake, .commonIdentifierMake:
                if let s = try? await item.load(.stringValue) { probe.extra["make"] = .string(s) }
            case .quickTimeMetadataModel, .commonIdentifierModel:
                if let s = try? await item.load(.stringValue) { probe.extra["model"] = .string(s) }
            case .quickTimeMetadataSoftware, .commonIdentifierSoftware:
                if let s = try? await item.load(.stringValue) { probe.extra["software"] = .string(s) }
            case .quickTimeMetadataLocationISO6709, .commonIdentifierLocation:
                if let s = try? await item.load(.stringValue), let gps = parseISO6709(s) {
                    var object: [String: JSONValue] = ["lat": .number(gps.lat), "lon": .number(gps.lon)]
                    if let alt = gps.altitude { object["altitude"] = .number(alt) }
                    probe.extra["gps"] = .object(object)
                }
            case .quickTimeMetadataCreationDate, .commonIdentifierCreationDate:
                if captured == nil, let s = try? await item.load(.stringValue) { captured = parseQuickTimeDate(s) }
            default: continue
            }
        }
        return captured
    }

    /// `+38.5959-090.3353+151.361/` -> lat, lon, altitude.
    static func parseISO6709(_ text: String) -> (lat: Double, lon: Double, altitude: Double?)? {
        var numbers: [Double] = []
        var current = ""
        for ch in text {
            if ch == "+" || ch == "-" {
                if let v = Double(current) { numbers.append(v) }
                current = String(ch)
            } else if ch == "/" {
                break
            } else {
                current.append(ch)
            }
        }
        if let v = Double(current) { numbers.append(v) }
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : nil)
    }

    static func parseQuickTimeDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: text) { return d }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    // MARK: Stills

    private static func inspectStill(_ url: URL, fileSize: Int64, attributes: [FileAttributeKey: Any]?) throws
        -> MediaInspection?
    {
        guard let image = CIImage(contentsOf: url) else { return nil }
        let props = image.properties
        var probe = Probe(
            width: Int(image.extent.width), height: Int(image.extent.height),
            capturedAt: attributes?[.creationDate] as? Date)
        probe.codec = url.pathExtension.lowercased()
        probe.extra["fileSize"] = .number(Double(fileSize))
        if let colorModel = props[kCGImagePropertyColorModel as String] as? String {
            probe.extra["colorModel"] = .string(colorModel)
        }
        if let depth = props[kCGImagePropertyDepth as String] as? Int {
            probe.extra["bitsPerComponent"] = .number(Double(depth))
        }
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
            let original = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: original) { probe.capturedAt = d }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake as String] as? String { probe.extra["make"] = .string(make) }
            if let model = tiff[kCGImagePropertyTIFFModel as String] as? String {
                probe.extra["model"] = .string(model)
            }
        }
        return MediaInspection(
            kind: .image, duration: stillImageDuration, hasVideo: false, hasAudio: false, sampleRate: nil,
            frameDuration: nil, probe: probe, audioTracks: [], capturedAt: probe.capturedAt)
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
