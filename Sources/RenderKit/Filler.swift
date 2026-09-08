import AVFoundation
import CoreVideo
import Foundation
import Synchronization

/// A tiny black video file the compiler inserts wherever a composition track needs a segment without a real
/// source: slates for offline assets, generated clips, stills, and the filler track that pins the composition's
/// duration to the sequence duration (an empty time range cannot be added to the end of a track, and a video
/// composition only covers times the composition has media for). Generated once per process into the temp
/// directory; never decoded unless an instruction asks for its track, which none does.
enum FillerMedia {
    static let size = 64
    static let frameRate: Int32 = 30
    static let seconds = 2.0
    static var duration: CMTime { CMTime(value: Int64(seconds * Double(frameRate)), timescale: frameRate) }

    private static let state = Mutex<Task<URL, any Error>?>(nil)

    static func url() async throws -> URL {
        let task = state.withLock { existing -> Task<URL, any Error> in
            if let existing { return existing }
            let task = Task { try await write() }
            existing = task
            return task
        }
        return try await task.value
    }

    private static func write() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RenderKit-filler-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("black.mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size,
            ])
        guard writer.canAdd(input) else { throw RenderKitError.filler("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RenderKitError.filler(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(frameRate))
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard let pool = adaptor.pixelBufferPool else { throw RenderKitError.filler("no pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw RenderKitError.filler("no buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(f), timescale: frameRate)) else {
                throw RenderKitError.filler(writer.error?.localizedDescription ?? "append")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RenderKitError.filler(writer.error?.localizedDescription ?? "finishWriting")
        }
        return url
    }
}

/// Failures inside RenderKit that are not `RenderError`s from the contract.
public enum RenderKitError: Error, Sendable, Hashable {
    case filler(String)
    case sourceUnavailable(URL)
    case trackInsertFailed(String)
    case exportSessionUnavailable(String)
    case frameUnavailable(String)
    case notARenderKitPayload
}
