import AVFoundation
import Accelerate
import Foundation

/// Mono float audio the aligner can stream sequentially (envelope pass) and read at known positions (fine
/// pass). Reads outside `0..<frameCount` are zero-padded. The aligner runs its blocking decode and DSP work on
/// a background queue, so sources must be safe to hand to another thread (not necessarily to use concurrently).
public protocol MonoAudioSource: Sendable {
    var sampleRate: Double { get }
    var frameCount: Int64 { get }
    /// The samples in `frames`, zero-padded where the range leaves the recording.
    func read(frames: Range<Int64>) throws -> [Float]
    /// Visits the whole recording once, in chunks of at most `chunkFrames`.
    func forEachChunk(chunkFrames: Int, _ body: (UnsafeBufferPointer<Float>) throws -> Void) throws
}

/// An in-memory recording, for tests and callers that already hold decoded audio.
public struct BufferAudioSource: MonoAudioSource, Sendable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var frameCount: Int64 { Int64(samples.count) }

    public func read(frames: Range<Int64>) throws -> [Float] {
        var out = [Float](repeating: 0, count: frames.count)
        let lo = max(0, frames.lowerBound), hi = min(Int64(samples.count), frames.upperBound)
        guard lo < hi else { return out }
        let dst = Int(lo - frames.lowerBound)
        out.replaceSubrange(dst..<(dst + Int(hi - lo)), with: samples[Int(lo)..<Int(hi)])
        return out
    }

    public func forEachChunk(chunkFrames: Int, _ body: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        try samples.withUnsafeBufferPointer { p in
            var start = 0
            while start < p.count {
                let end = min(p.count, start + chunkFrames)
                try body(UnsafeBufferPointer(rebasing: p[start..<end]))
                start = end
            }
        }
    }
}

/// The first audio track of a media file, decoded to mono float at its native sample rate through
/// `AVAssetReader`. Sequential streaming uses one reader over the whole track; positioned reads open a reader
/// limited to the requested time range, so the fine pass touches only the excerpts it needs.
///
/// `@unchecked Sendable`: the stored asset and track are immutable once loaded and every read creates its own
/// `AVAssetReader` as a local, so the object carries no mutable state between calls.
public final class AudioFileSource: MonoAudioSource, @unchecked Sendable {
    public let url: URL
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int64
    private let asset: AVURLAsset
    private let track: AVAssetTrack

    public static func open(url: URL) async throws -> AudioFileSource {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioAlignError.decodingFailed(url, error.localizedDescription)
        }
        guard let track = tracks.first else { throw AudioAlignError.noAudioTrack(url) }
        let (descriptions, timeRange) = try await track.load(.formatDescriptions, .timeRange)
        guard let asbd = descriptions.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }),
            asbd.mSampleRate > 0
        else {
            throw AudioAlignError.decodingFailed(url, "no audio format description")
        }
        let frames = Int64((timeRange.duration.seconds * asbd.mSampleRate).rounded())
        return AudioFileSource(
            url: url, asset: asset, track: track, sampleRate: asbd.mSampleRate,
            channelCount: max(1, Int(asbd.mChannelsPerFrame)), frameCount: frames)
    }

    private init(
        url: URL, asset: AVURLAsset, track: AVAssetTrack, sampleRate: Double, channelCount: Int, frameCount: Int64
    ) {
        self.url = url
        self.asset = asset
        self.track = track
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
    }

    private static var pcmSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private func makeReader(range: Range<Int64>?) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioAlignError.decodingFailed(url, "cannot add track output") }
        reader.add(output)
        if let range {
            let ts = CMTimeScale(sampleRate.rounded())
            reader.timeRange = CMTimeRange(
                start: CMTime(value: range.lowerBound, timescale: ts),
                end: CMTime(value: range.upperBound, timescale: ts))
        }
        guard reader.startReading() else {
            throw AudioAlignError.decodingFailed(url, reader.error?.localizedDescription ?? "startReading failed")
        }
        return (reader, output)
    }

    /// Copies a sample buffer's interleaved frames into `mono` (resized), averaging channels.
    private func mixdown(_ buffer: CMSampleBuffer, into mono: inout [Float], scratch: inout [Float]) -> Int64? {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        let frames = length / (4 * channelCount)
        guard frames > 0 else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let startFrame = CMTimeConvertScale(
            pts, timescale: CMTimeScale(sampleRate.rounded()), method: .roundHalfAwayFromZero
        )
        .value
        if channelCount == 1 {
            mono = [Float](repeating: 0, count: frames)
            mono.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: frames * 4, destination: raw.baseAddress!)
            }
        } else {
            scratch = [Float](repeating: 0, count: frames * channelCount)
            scratch.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            mono = [Float](repeating: 0, count: frames)
            scratch.withUnsafeBufferPointer { sp in
                for c in 0..<channelCount {
                    vDSP_vadd(mono, 1, sp.baseAddress! + c, vDSP_Stride(channelCount), &mono, 1, vDSP_Length(frames))
                }
            }
            var gain = 1 / Float(channelCount)
            vDSP_vsmul(mono, 1, &gain, &mono, 1, vDSP_Length(frames))
        }
        return startFrame
    }

    public func read(frames: Range<Int64>) throws -> [Float] {
        var out = [Float](repeating: 0, count: frames.count)
        let lo = max(0, frames.lowerBound), hi = min(frameCount, frames.upperBound)
        guard lo < hi else { return out }
        let (reader, output) = try makeReader(range: lo..<hi)
        var mono: [Float] = []
        var scratch: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let start = mixdown(buffer, into: &mono, scratch: &scratch) else { continue }
            // Trim to the requested range: the first buffer may begin before `lo`.
            let bufLo = max(start, frames.lowerBound), bufHi = min(start + Int64(mono.count), frames.upperBound)
            guard bufLo < bufHi else { continue }
            let srcStart = Int(bufLo - start), dstStart = Int(bufLo - frames.lowerBound), count = Int(bufHi - bufLo)
            out.replaceSubrange(dstStart..<(dstStart + count), with: mono[srcStart..<(srcStart + count)])
        }
        guard reader.status == .completed else {
            throw AudioAlignError.decodingFailed(url, reader.error?.localizedDescription ?? "read failed")
        }
        return out
    }

    /// Delivers exactly `chunkFrames` frames per call (the last chunk shorter), whatever buffer boundaries
    /// `AVAssetReader` chooses, so the envelope a file produces does not depend on I/O timing.
    public func forEachChunk(chunkFrames: Int, _ body: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        precondition(chunkFrames > 0)
        let (reader, output) = try makeReader(range: nil)
        var mono: [Float] = []
        var scratch: [Float] = []
        var pending: [Float] = []
        pending.reserveCapacity(2 * chunkFrames)
        do {
            while let buffer = output.copyNextSampleBuffer() {
                guard mixdown(buffer, into: &mono, scratch: &scratch) != nil else { continue }
                pending.append(contentsOf: mono)
                var start = 0
                while pending.count - start >= chunkFrames {
                    try pending.withUnsafeBufferPointer { p in
                        try body(UnsafeBufferPointer(rebasing: p[start..<(start + chunkFrames)]))
                    }
                    start += chunkFrames
                }
                if start > 0 { pending.removeFirst(start) }
            }
            if !pending.isEmpty { try pending.withUnsafeBufferPointer { try body($0) } }
        } catch {
            reader.cancelReading()
            throw error
        }
        guard reader.status == .completed else {
            throw AudioAlignError.decodingFailed(url, reader.error?.localizedDescription ?? "read failed")
        }
    }
}
