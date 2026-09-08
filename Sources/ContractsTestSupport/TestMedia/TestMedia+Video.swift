// Video generators and the shared AVAssetWriter pipeline (lifted from spikes/compositor Media.swift).
import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

extension TestMedia {
    public static let defaultSize = CGSize(width: 1280, height: 720)
    public static let defaultFrameDuration = CMTime(value: 1, timescale: 30)

    /// SMPTE-style 75% colour bars, left to right.
    public static let colorBarColors: [Color] = [
        Color(r: 0.75, g: 0.75, b: 0.75), Color(r: 0.75, g: 0.75, b: 0), Color(r: 0, g: 0.75, b: 0.75),
        Color(r: 0, g: 0.75, b: 0), Color(r: 0.75, g: 0, b: 0.75), Color(r: 0.75, g: 0, b: 0),
        Color(r: 0, g: 0, b: 0.75),
    ]

    // MARK: Generators

    /// A video-only clip of one solid colour.
    public static func solidColor(
        _ color: Color, size: CGSize = defaultSize, frameDuration: CMTime = defaultFrameDuration,
        duration: Double = 2, codec: VideoCodec = .h264, in directory: URL? = nil, name: String? = nil
    ) async throws -> Clip {
        let url = try outputURL(in: directory, name: name, defaultName: "solid", ext: "mov")
        let frames = frameCount(duration: duration, frameDuration: frameDuration)
        try await writeVideo(to: url, size: size, frameDuration: frameDuration, frameCount: frames, codec: codec) {
            ctx, _ in
            fill(ctx, color, size: size)
        }
        var d = videoDescription(size: size, frameDuration: frameDuration, frameCount: frames, codec: codec)
        d.color = color
        return Clip(url: url, description: d)
    }

    /// Vertical SMPTE-style colour bars (`colorBarColors`), so scaling and cropping are visible.
    public static func colorBars(
        size: CGSize = defaultSize, frameDuration: CMTime = defaultFrameDuration, duration: Double = 2,
        codec: VideoCodec = .h264, in directory: URL? = nil, name: String? = nil
    ) async throws -> Clip {
        let url = try outputURL(in: directory, name: name, defaultName: "bars", ext: "mov")
        let frames = frameCount(duration: duration, frameDuration: frameDuration)
        try await writeVideo(to: url, size: size, frameDuration: frameDuration, frameCount: frames, codec: codec) {
            ctx, _ in
            paintBars(ctx, size: size)
        }
        var d = videoDescription(size: size, frameDuration: frameDuration, frameCount: frames, codec: codec)
        d.bars = colorBarColors
        return Clip(url: url, description: d)
    }

    /// A solid background with every frame's index encoded in a `Barcode` strip; decode with `decodeFrameIndex`.
    public static func barcodeCounter(
        background: Color = .gray, size: CGSize = defaultSize, frameDuration: CMTime = defaultFrameDuration,
        duration: Double = 2, codec: VideoCodec = .h264, in directory: URL? = nil, name: String? = nil
    ) async throws -> Clip {
        let url = try outputURL(in: directory, name: name, defaultName: "barcode", ext: "mov")
        let frames = frameCount(duration: duration, frameDuration: frameDuration)
        try await writeVideo(to: url, size: size, frameDuration: frameDuration, frameCount: frames, codec: codec) {
            ctx, index in
            fill(ctx, background, size: size)
            Barcode.paint(index: index, into: ctx, size: size)
        }
        var d = videoDescription(size: size, frameDuration: frameDuration, frameCount: frames, codec: codec)
        d.color = background
        d.hasBarcode = true
        return Clip(url: url, description: d)
    }

    /// The audio track to mux into `videoWithAudio`.
    public enum AudioContent: Sendable, Equatable {
        case tone(frequency: Double)
        case transients(clickTimes: [Double])
    }

    /// A barcode video plus a tone or transient audio track in one .mov, for link-group and mux tests.
    public static func videoWithAudio(
        _ audio: AudioContent = .tone(frequency: 440), background: Color = .gray, size: CGSize = defaultSize,
        frameDuration: CMTime = defaultFrameDuration, duration: Double = 2, videoCodec: VideoCodec = .h264,
        sampleRate: Double = 48000, channels: Int = 1, audioCodec: AudioCodec = .aac, in directory: URL? = nil,
        name: String? = nil
    ) async throws -> Clip {
        let url = try outputURL(in: directory, name: name, defaultName: "av", ext: "mov")
        let frames = frameCount(duration: duration, frameDuration: frameDuration)
        let seconds = Double(frames) * frameDuration.seconds
        let samples: [Float]
        var clickSamples: [Int] = []
        switch audio {
        case .tone(let frequency):
            samples = toneSamples(frequency: frequency, sampleRate: sampleRate, duration: seconds, channels: channels)
        case .transients(let clickTimes):
            (samples, clickSamples) = transientSamples(
                clickTimes: clickTimes, sampleRate: sampleRate, duration: seconds, channels: channels)
        }
        let track = AudioTrack(samples: samples, sampleRate: sampleRate, channels: channels, codec: audioCodec)
        try await writeVideo(
            to: url, size: size, frameDuration: frameDuration, frameCount: frames, codec: videoCodec, audio: track
        ) { ctx, index in
            fill(ctx, background, size: size)
            Barcode.paint(index: index, into: ctx, size: size)
        }
        var d = videoDescription(size: size, frameDuration: frameDuration, frameCount: frames, codec: videoCodec)
        d.hasAudio = true
        d.sampleRate = sampleRate
        d.channels = channels
        d.audioCodec = audioCodec
        d.color = background
        d.hasBarcode = true
        switch audio {
        case .tone(let frequency): d.toneFrequency = frequency
        case .transients(let clickTimes):
            d.clickTimes = clickTimes
            d.clickSamples = clickSamples
        }
        return Clip(url: url, description: d)
    }

    // MARK: Painting

    static func frameCount(duration: Double, frameDuration: CMTime) -> Int {
        max(1, Int((duration / frameDuration.seconds).rounded()))
    }

    static func videoDescription(size: CGSize, frameDuration: CMTime, frameCount: Int, codec: VideoCodec)
        -> Description
    {
        var d = Description(duration: Double(frameCount) * frameDuration.seconds, hasVideo: true, hasAudio: false)
        d.size = size
        d.fps = 1 / frameDuration.seconds
        d.frameDuration = frameDuration
        d.frameCount = frameCount
        d.videoCodec = codec
        return d
    }

    static func fill(_ ctx: CGContext, _ color: Color, size: CGSize) {
        ctx.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
    }

    static func paintBars(_ ctx: CGContext, size: CGSize) {
        let n = colorBarColors.count
        let barWidth = size.width / CGFloat(n)
        for (i, c) in colorBarColors.enumerated() {
            ctx.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            let x0 = (CGFloat(i) * barWidth).rounded(.down)
            let x1 = (CGFloat(i + 1) * barWidth).rounded(.up)
            ctx.fill(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height))
        }
    }

    // MARK: Writer

    struct AudioTrack {
        var samples: [Float]  // interleaved
        var sampleRate: Double
        var channels: Int
        var codec: AudioCodec
    }

    static let bgraBitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func videoOutputSettings(codec: VideoCodec, size: CGSize) -> [String: Any] {
        let width = Int(size.width)
        let height = Int(size.height)
        switch codec {
        case .h264:
            return [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: sdrColorProperties,
            ]
        case .hevc:
            return [
                AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: sdrColorProperties,
            ]
        case .proRes422:
            return [
                AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: sdrColorProperties,
            ]
        case .hevcHLG10:
            return [
                AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
                // kVTProfileLevel_HEVC_Main10_AutoLevel from VideoToolbox, spelled out to avoid the import.
                AVVideoCompressionPropertiesKey: ["ProfileLevel": "HEVC_Main10_AutoLevel"],
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
                ],
            ]
        }
    }

    static let sdrColorProperties: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    /// Writes `frameCount` frames painted by `paint(context, frameIndex)` (bottom-left origin, sRGB BGRA8) and
    /// an optional interleaved audio track, interleaving audio and video appends frame by frame.
    static func writeVideo(
        to url: URL, size: CGSize, frameDuration: CMTime, frameCount: Int, codec: VideoCodec,
        audio: AudioTrack? = nil, paint: (CGContext, Int) -> Void
    ) async throws {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw Error.unsupportedParameters("size must be positive and even, got \(width)x\(height)")
        }
        guard frameDuration.isNumeric, frameDuration.seconds > 0 else {
            throw Error.unsupportedParameters("frameDuration must be positive")
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings(codec: codec, size: size))
        video.expectsMediaDataInRealTime = false
        let sourceFormat = codec.isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: sourceFormat,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(video) else { throw Error.writerFailed("cannot add video input for \(codec)") }
        writer.add(video)

        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if let audio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioOutputSettings(
                    codec: audio.codec, sampleRate: audio.sampleRate, channels: audio.channels))
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw Error.writerFailed("cannot add audio input") }
            writer.add(input)
            audioInput = input
            audioFormat = try pcmFormat(sampleRate: audio.sampleRate, channels: audio.channels)
        }

        guard writer.startWriting() else {
            throw Error.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        // Scratch BGRA canvas. For SDR codecs the pool buffer is the canvas; for HLG we paint here and let
        // Core Image convert into the 10-bit pool buffer.
        var scratch: CVPixelBuffer?
        if codec.isHDR {
            let status = CVPixelBufferCreate(
                nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &scratch)
            guard status == kCVReturnSuccess, scratch != nil else { throw Error.pixelBufferUnavailable }
        }
        let ciContext = codec.isHDR ? CIContext(options: [.cacheIntermediates: false]) : nil
        let hlgSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        for f in 0..<frameCount {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard let pool = adaptor.pixelBufferPool else { throw Error.pixelBufferUnavailable }
            var pooled: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pooled)
            guard let pooled else { throw Error.pixelBufferUnavailable }
            let canvas = scratch ?? pooled

            CVPixelBufferLockBaseAddress(canvas, [])
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(canvas), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(canvas), space: srgbSpace, bitmapInfo: bgraBitmapInfo)
            {
                paint(ctx, f)
            }
            CVPixelBufferUnlockBaseAddress(canvas, [])

            if codec.isHDR, let ciContext, let hlgSpace {
                tagHLG(pooled)
                let image = CIImage(cvPixelBuffer: canvas, options: [.colorSpace: srgbSpace])
                ciContext.render(image, to: pooled, bounds: image.extent, colorSpace: hlgSpace)
            }
            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(f))
            guard adaptor.append(pooled, withPresentationTime: pts) else {
                throw Error.writerFailed(writer.error?.localizedDescription ?? "append video frame \(f)")
            }

            if let audio, let audioInput, let audioFormat {
                let frameSamples = Int64(audio.sampleRate) * frameDuration.value
                let start = Int(frameSamples * Int64(f) / Int64(frameDuration.timescale))
                let end = min(
                    audio.samples.count / audio.channels,
                    Int(frameSamples * Int64(f + 1) / Int64(frameDuration.timescale)))
                if end > start {
                    while !audioInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                    let buffer = try pcmSampleBuffer(
                        audio.samples, frames: start..<end, channels: audio.channels, sampleRate: audio.sampleRate,
                        format: audioFormat)
                    guard audioInput.append(buffer) else {
                        throw Error.writerFailed(writer.error?.localizedDescription ?? "append audio at frame \(f)")
                    }
                }
            }
        }
        video.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Error.writerFailed(writer.error?.localizedDescription ?? "finishWriting: \(writer.status.rawValue)")
        }
    }

    static func tagHLG(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }
}
