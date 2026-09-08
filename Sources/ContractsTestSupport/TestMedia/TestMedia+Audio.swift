// Audio generators, the PCM sample-buffer plumbing shared with the video writer, and a reader for assertions.
import AVFoundation
import Foundation

extension TestMedia {
    public static let defaultSampleRate = 48000.0
    /// Peak amplitude of generated tones.
    public static let toneAmplitude: Float = 0.5
    /// Peak amplitude of a transient click and its exponential decay time constant in seconds.
    public static let clickAmplitude: Float = 0.9
    public static let clickDecaySeconds = 0.001
    public static let clickFrequency = 3000.0

    // MARK: Generators

    /// An audio-only sine tone: `.caf` (32-bit float LPCM) for `.pcm`, `.wav` (16-bit) for `.pcm16`, `.m4a` for
    /// `.aac`.
    public static func tone(
        frequency: Double = 440, sampleRate: Double = defaultSampleRate, duration: Double = 2, channels: Int = 1,
        codec: AudioCodec = .pcm, in directory: URL? = nil, name: String? = nil
    ) async throws -> Clip {
        let samples = toneSamples(frequency: frequency, sampleRate: sampleRate, duration: duration, channels: channels)
        let url = try outputURL(in: directory, name: name, defaultName: "tone", ext: codec.fileExtension)
        try await writeAudio(to: url, samples: samples, sampleRate: sampleRate, channels: channels, codec: codec)
        var d = audioDescription(
            frames: samples.count / channels, sampleRate: sampleRate, channels: channels, codec: codec)
        d.toneFrequency = frequency
        return Clip(url: url, description: d)
    }

    /// Silence with a short click at each of `clickTimes` (seconds). Each click starts at the nearest sample with
    /// a full-amplitude first sample (`clickAmplitude`), then decays exponentially; the exact sample indices are
    /// in `Description.clickSamples`. Written as 32-bit float `.caf` unless `codec` says otherwise.
    public static func transients(
        clickTimes: [Double], duration: Double = 2, sampleRate: Double = defaultSampleRate, channels: Int = 1,
        codec: AudioCodec = .pcm, in directory: URL? = nil, name: String? = nil
    ) async throws -> Clip {
        let (samples, clickSamples) = transientSamples(
            clickTimes: clickTimes, sampleRate: sampleRate, duration: duration, channels: channels)
        let url = try outputURL(in: directory, name: name, defaultName: "clicks", ext: codec.fileExtension)
        try await writeAudio(to: url, samples: samples, sampleRate: sampleRate, channels: channels, codec: codec)
        var d = audioDescription(
            frames: samples.count / channels, sampleRate: sampleRate, channels: channels, codec: codec)
        d.clickTimes = clickTimes
        d.clickSamples = clickSamples
        return Clip(url: url, description: d)
    }

    // MARK: Sample synthesis

    /// Interleaved float tone samples, identical in every channel.
    static func toneSamples(frequency: Double, sampleRate: Double, duration: Double, channels: Int) -> [Float] {
        let frames = max(1, Int((duration * sampleRate).rounded()))
        var out = [Float](repeating: 0, count: frames * channels)
        let w = 2 * Double.pi * frequency / sampleRate
        out.withUnsafeMutableBufferPointer { p in
            for i in 0..<frames {
                let v = Float(sin(w * Double(i))) * toneAmplitude
                for c in 0..<channels { p[i * channels + c] = v }
            }
        }
        return out
    }

    /// Silence with exponentially decaying cosine bursts; returns the samples and each click's start sample.
    static func transientSamples(clickTimes: [Double], sampleRate: Double, duration: Double, channels: Int)
        -> (samples: [Float], clickSamples: [Int])
    {
        let frames = max(1, Int((duration * sampleRate).rounded()))
        var out = [Float](repeating: 0, count: frames * channels)
        let tau = clickDecaySeconds * sampleRate
        let burst = Int(tau * 8)  // -70 dB
        let w = 2 * Double.pi * clickFrequency / sampleRate
        var starts: [Int] = []
        out.withUnsafeMutableBufferPointer { p in
            for t in clickTimes {
                let s = Int((t * sampleRate).rounded())
                starts.append(s)
                guard s >= 0, s < frames else { continue }
                for k in 0..<min(burst, frames - s) {
                    let v = Float(cos(w * Double(k)) * exp(-Double(k) / tau)) * clickAmplitude
                    for c in 0..<channels { p[(s + k) * channels + c] += v }
                }
            }
        }
        return (out, starts)
    }

    static func audioDescription(frames: Int, sampleRate: Double, channels: Int, codec: AudioCodec) -> Description {
        var d = Description(duration: Double(frames) / sampleRate, hasVideo: false, hasAudio: true)
        d.sampleRate = sampleRate
        d.channels = channels
        d.audioCodec = codec
        return d
    }

    // MARK: Writer plumbing

    static func audioOutputSettings(codec: AudioCodec, sampleRate: Double, channels: Int) -> [String: Any] {
        switch codec {
        case .pcm, .pcm16:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: codec == .pcm ? 32 : 16, AVLinearPCMIsFloatKey: codec == .pcm,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ]
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128_000,
            ]
        }
    }

    /// Float32 interleaved PCM format description for the writer inputs.
    static func pcmFormat(sampleRate: Double, channels: Int) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw Error.sampleBufferFailed(status) }
        return format
    }

    /// A sample buffer holding interleaved frames `frames` of `samples`, timed at `frames.lowerBound`.
    static func pcmSampleBuffer(
        _ samples: [Float], frames: Range<Int>, channels: Int, sampleRate: Double, format: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let byteCount = frames.count * channels * 4
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { throw Error.sampleBufferFailed(status) }
        status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!.advanced(by: frames.lowerBound * channels * 4), blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else { throw Error.sampleBufferFailed(status) }
        let timescale = CMTimeScale(sampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: CMTime(value: CMTimeValue(frames.lowerBound), timescale: timescale),
            decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: frames.count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw Error.sampleBufferFailed(status) }
        return buffer
    }

    /// Writes interleaved float samples to an audio-only file whose container follows `codec.fileExtension`.
    static func writeAudio(to url: URL, samples: [Float], sampleRate: Double, channels: Int, codec: AudioCodec)
        async throws
    {
        guard channels == 1 || channels == 2 else {
            throw Error.unsupportedParameters("channels must be 1 or 2, got \(channels)")
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: codec.fileType)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: audioOutputSettings(codec: codec, sampleRate: sampleRate, channels: channels))
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Error.writerFailed("cannot add audio input for \(codec)") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Error.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        let format = try pcmFormat(sampleRate: sampleRate, channels: channels)
        let totalFrames = samples.count / channels
        let chunk = 8192
        var cursor = 0
        while cursor < totalFrames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            let end = min(totalFrames, cursor + chunk)
            let buffer = try pcmSampleBuffer(
                samples, frames: cursor..<end, channels: channels, sampleRate: sampleRate, format: format)
            guard input.append(buffer) else {
                throw Error.writerFailed(writer.error?.localizedDescription ?? "append audio at \(cursor)")
            }
            cursor = end
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Error.writerFailed(writer.error?.localizedDescription ?? "finishWriting: \(writer.status.rawValue)")
        }
    }

    // MARK: Reading back

    /// Decoded audio for assertions: interleaved float samples.
    public struct AudioSamples: Sendable {
        public var samples: [Float]
        public var sampleRate: Double
        public var channels: Int

        public var frameCount: Int { samples.count / max(channels, 1) }

        /// One channel, de-interleaved.
        public func channel(_ index: Int) -> [Float] {
            stride(from: index, to: samples.count, by: channels).map { samples[$0] }
        }

        public var rms: Float {
            guard !samples.isEmpty else { return 0 }
            var acc: Double = 0
            for s in samples { acc += Double(s) * Double(s) }
            return Float((acc / Double(samples.count)).squareRoot())
        }

        /// Frequency estimate from zero crossings of `channel(0)`, good enough to identify a sine tone.
        public var zeroCrossingFrequency: Double {
            let x = channel(0)
            guard x.count > 2 else { return 0 }
            var crossings = 0
            var first = -1
            var last = -1
            for i in 1..<x.count where (x[i - 1] < 0) != (x[i] < 0) {
                if first < 0 { first = i }
                last = i
                crossings += 1
            }
            guard crossings > 1, last > first else { return 0 }
            return Double(crossings - 1) / 2 * sampleRate / Double(last - first)
        }
    }

    /// Decodes the first audio track of `url` to interleaved 32-bit float PCM at its native sample rate.
    public static func readAudio(url: URL) async throws -> AudioSamples {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Error.unsupportedParameters("no audio track in \(url.lastPathComponent)")
        }
        let descriptions = try await track.load(.formatDescriptions)
        var sampleRate = 0.0
        var channels = 1
        if let asbd = descriptions.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) {
            sampleRate = asbd.mSampleRate
            channels = Int(asbd.mChannelsPerFrame)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        guard reader.startReading() else {
            throw Error.writerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        guard reader.status == .completed else {
            throw Error.writerFailed(reader.error?.localizedDescription ?? "reading failed")
        }
        return AudioSamples(samples: samples, sampleRate: sampleRate, channels: channels)
    }
}

extension TestMedia.AudioCodec {
    public var fileExtension: String {
        switch self {
        case .pcm: "caf"
        case .pcm16: "wav"
        case .aac: "m4a"
        }
    }

    var fileType: AVFileType {
        switch self {
        case .pcm: .caf
        case .pcm16: .wav
        case .aac: .m4a
        }
    }
}
