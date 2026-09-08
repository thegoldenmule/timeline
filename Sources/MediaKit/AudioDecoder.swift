import AVFoundation
import Contracts
import Foundation

/// Streamed PCM decode of one audio track through `AVAssetReader`: mono Float32 chunks at the track's native
/// sample rate, a few thousand frames at a time, so a two-hour file is never resident. Every consumer in
/// MediaKit (peaks, silence, onset envelope, transcription input) goes through here so they agree on which track
/// is decoded (`MediaProbe.primaryAudioTrackIndex`) and on how channels fold down (average).
enum AudioDecoder {
    struct Info: Sendable {
        var sampleRate: Double
        var channels: Int
        var trackID: Int32
        /// Presentation time of the first decoded frame, in source samples.
        var firstSample: Int64
        var framesDecoded: Int64
    }

    /// Decodes and hands mono chunks to `sink`. `range` limits decoding (used for high-zoom peaks). Returns the
    /// format and how many frames were decoded; throws `AnalysisError.noAudioTrack` when there is none.
    static func readMono(
        url: URL, range: CMTimeRange? = nil, sink: (_ samples: UnsafeBufferPointer<Float>) throws -> Void,
        configure: ((_ sampleRate: Double) throws -> Void)? = nil
    ) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AnalysisError.noAudioTrack }
        var infos: [AudioTrackInfo] = []
        for track in tracks {
            guard let format = try await track.load(.formatDescriptions).first else { continue }
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            infos.append(
                AudioTrackInfo(
                    trackID: track.trackID, codec: MediaProbe.fourCC(CMFormatDescriptionGetMediaSubType(format)),
                    channels: Int(asbd?.mChannelsPerFrame ?? 0), sampleRate: Int(asbd?.mSampleRate ?? 0),
                    isPrimary: false))
        }
        guard let index = MediaProbe.primaryAudioTrackIndex(infos) else { throw AnalysisError.noAudioTrack }
        let track = tracks.first { $0.trackID == infos[index].trackID } ?? tracks[0]
        let sampleRate = infos[index].sampleRate > 0 ? Double(infos[index].sampleRate) : 48000
        let channels = max(infos[index].channels, 1)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AnalysisError.failed("AVAssetReader: \(error.localizedDescription)")
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.failed("cannot add audio output") }
        reader.add(output)
        if let range { reader.timeRange = range }
        guard reader.startReading() else {
            throw AnalysisError.failed("startReading: \(reader.error?.localizedDescription ?? "unknown")")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        try configure?(sampleRate)

        var info = Info(sampleRate: sampleRate, channels: channels, trackID: track.trackID, firstSample: 0, framesDecoded: 0)
        var sawFirst = false
        var mono: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            if !sawFirst {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                info.firstSample = pts.isNumeric ? Int64((pts.seconds * sampleRate).rounded()) : 0
                sawFirst = true
            }
            let length = CMBlockBufferGetDataLength(block)
            let floats = length / MemoryLayout<Float>.size
            let frames = floats / channels
            guard frames > 0 else { continue }
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
            var interleaved = [Float](repeating: 0, count: floats)
            try interleaved.withUnsafeMutableBytes { raw in
                let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                guard status == kCMBlockBufferNoErr else { throw AnalysisError.failed("CMBlockBufferCopyDataBytes \(status)") }
            }
            if channels == 1 {
                try interleaved.withUnsafeBufferPointer { try sink(UnsafeBufferPointer(rebasing: $0[0..<frames])) }
            } else {
                let scale = 1 / Float(channels)
                interleaved.withUnsafeBufferPointer { src in
                    mono.withUnsafeMutableBufferPointer { dst in
                        for f in 0..<frames {
                            var acc: Float = 0
                            let base = f * channels
                            for c in 0..<channels { acc += src[base + c] }
                            dst[f] = acc * scale
                        }
                    }
                }
                try mono.withUnsafeBufferPointer { try sink(UnsafeBufferPointer(rebasing: $0[0..<frames])) }
            }
            info.framesDecoded += Int64(frames)
        }
        if reader.status == .failed {
            throw AnalysisError.failed("decode: \(reader.error?.localizedDescription ?? "unknown")")
        }
        return info
    }

    /// Writes the primary track as a mono Float32 CAF (the transcription input for multi-track files).
    static func extractMono(url: URL, to output: URL) async throws -> Info {
        let inspection = try await MediaProbe.inspect(url)
        guard inspection.hasAudio, let rate = inspection.sampleRate else { throw AnalysisError.noAudioTrack }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1) else {
            throw AnalysisError.failed("unsupported sample rate \(rate)")
        }
        try? FileManager.default.removeItem(at: output)
        let file = try AVAudioFile(
            forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        return try await readMono(url: url) { samples in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                let base = samples.baseAddress
            else { throw AnalysisError.failed("buffer allocation failed") }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            buffer.floatChannelData?[0].update(from: base, count: samples.count)
            try file.write(from: buffer)
        }
    }
}
