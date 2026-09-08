import AVFoundation
import CoreGraphics

/// Synthetic media (copied from spikes/compositor): solid colour, 16-bit frame-counter barcode strip along the top
/// (bit i at x = i*32..i*32+31, y = 0..23, white = 1), and a sine tone. Written with AVAssetWriter.
enum Media {
    static let width = 1280, height = 720, fps: Int32 = 30, sampleRate = 44100.0

    static func makeClip(url: URL, color: (CGFloat, CGFloat, CGFloat), toneHz: Double, seconds: Int, lpcm: Bool = false) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: lpcm
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000])
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "spike", code: 1) }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let samplesPerFrame = Int(sampleRate) / Int(fps)
        var sampleCursor = 0
        for f in 0..<(seconds * Int(fps)) {
            while !video.isReadyForMoreMediaData || !audio.isReadyForMoreMediaData { usleep(2000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { throw NSError(domain: "spike", code: 2) }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for i in 0..<16 {
                let bit = (f >> (15 - i)) & 1
                ctx.setFillColor(gray: bit == 1 ? 1 : 0, alpha: 1)
                ctx.fill(CGRect(x: i * 32, y: height - 24, width: 32, height: 24))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))

            var pcm = [Float32](repeating: 0, count: samplesPerFrame)
            for i in 0..<samplesPerFrame { pcm[i] = Float32(0.3 * sin(2 * .pi * toneHz * Double(sampleCursor + i) / sampleRate)) }
            sampleCursor += samplesPerFrame
            var block: CMBlockBuffer?
            let byteCount = samplesPerFrame * 4
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
            _ = pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount) }
            var sb: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(sampleCursor - samplesPerFrame), timescale: CMTimeScale(sampleRate)), decodeTimeStamp: .invalid)
            CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: fmt, sampleCount: samplesPerFrame, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
            audio.append(sb!)
        }
        video.markAsFinished(); audio.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if let e = writer.error { throw e }
    }
}

/// Cheap read of a composed BGRA frame: centre-region mean colour and the barcode frame index. No full copy.
struct Probe {
    let center: (Int, Int, Int)
    let frameIndex: Int
    init(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb), base = CVPixelBufferGetBaseAddress(pb)!
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = base.advanced(by: y * rowBytes + x * 4)
            return (Int(p.load(fromByteOffset: 2, as: UInt8.self)), Int(p.load(fromByteOffset: 1, as: UInt8.self)), Int(p.load(as: UInt8.self)))
        }
        var s = (0, 0, 0), n = 0
        for y in stride(from: 200, to: 500, by: 20) { for x in stride(from: 400, to: 880, by: 20) { let c = rgb(x, y); s.0 += c.0; s.1 += c.1; s.2 += c.2; n += 1 } }
        center = (s.0 / n, s.1 / n, s.2 / n)
        var v = 0
        for i in 0..<16 { let c = rgb(i * 32 + 16, 12); if (c.0 * 299 + c.1 * 587 + c.2 * 114) / 1000 > 128 { v |= 1 << (15 - i) } }
        frameIndex = v
    }
}
