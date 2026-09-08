import AVFoundation
import CoreGraphics

/// Synthetic media: solid color, 16-bit frame-counter barcode strip along the top
/// (bit i at x = i*32..i*32+31, y = 0..23, white = 1), and a sine tone.
enum Media {
    static let width = 1280, height = 720, fps: Int32 = 30, sampleRate = 44100.0

    static func frameIndex(fromBarcodeIn px: Pixels) -> Int {
        var v = 0
        for i in 0..<16 { if px.luma(x: i * 32 + 16, y: 12) > 128 { v |= 1 << (15 - i) } }
        return v
    }

    static func makeClip(url: URL, color: (CGFloat, CGFloat, CGFloat), toneHz: Double, seconds: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000])
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "spike", code: 1) }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let samplesPerFrame = Int(sampleRate) / Int(fps)  // 1470
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
            for i in 0..<16 {  // CG origin is bottom-left; strip lives at the top of the frame
                let bit = (f >> (15 - i)) & 1
                ctx.setFillColor(gray: bit == 1 ? 1 : 0, alpha: 1)
                ctx.fill(CGRect(x: i * 32, y: height - 24, width: 32, height: 24))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))

            var pcm = [Float32](repeating: 0, count: samplesPerFrame)
            for i in 0..<samplesPerFrame {
                pcm[i] = Float32(0.3 * sin(2 * .pi * toneHz * Double(sampleCursor + i) / sampleRate))
            }
            sampleCursor += samplesPerFrame
            var block: CMBlockBuffer?
            let byteCount = samplesPerFrame * 4
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
            _ = pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount) }
            var sb: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(sampleCursor - samplesPerFrame), timescale: CMTimeScale(sampleRate)),
                decodeTimeStamp: .invalid)
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

/// BGRA8 pixel dump of a CGImage or CVPixelBuffer for assertions.
struct Pixels {
    let w: Int, h: Int, data: [UInt8]
    init(_ img: CGImage) {
        let w = img.width, h = img.height
        self.w = w; self.h = h
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        data = buf
    }
    init(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb), base = CVPixelBufferGetBaseAddress(pb)!
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { memcpy(&buf[y * w * 4], base + y * stride, w * 4) }
        self.w = w; self.h = h; data = buf
    }
    /// (r,g,b) at top-left-origin coordinates
    func rgb(x: Int, y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4; return (Int(data[i + 2]), Int(data[i + 1]), Int(data[i]))
    }
    func luma(x: Int, y: Int) -> Int { let c = rgb(x: x, y: y); return (c.0 * 299 + c.1 * 587 + c.2 * 114) / 1000 }
    /// Mean rgb over a rect (top-left origin), sampled every 4 px.
    func mean(_ r: CGRect) -> (Int, Int, Int) {
        var s = (0, 0, 0), n = 0
        for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 4) { for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 4) {
            let c = rgb(x: x, y: y); s.0 += c.0; s.1 += c.1; s.2 += c.2; n += 1 } }
        return (s.0 / n, s.1 / n, s.2 / n)
    }
}
