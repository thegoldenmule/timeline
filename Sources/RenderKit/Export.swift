import AVFoundation
import Contracts
import CoreMedia
import Foundation
import TimelineCore

/// How an `ExportPreset` maps onto `AVAssetExportSession`: the preset name, the container, and the video
/// composition to export with (re-sized, re-timed, and forced to SDR when the policy says so). Presets carry
/// no bitrate or audio-codec control, so those fields are recorded in the receipt and reported as warnings
/// when they cannot be honoured.
public struct ExportSettings: Sendable, Hashable {
    public var presetName: String
    public var fileType: AVFileType
    public var renderSize: CGSize
    public var frameDuration: CMTime
    /// True when the export writes 10-bit HLG.
    public var hdr: Bool
    public var warnings: [String]

    public static func resolve(_ preset: ExportPreset, for payload: RenderPayload) -> ExportSettings {
        var warnings: [String] = []
        var hdr: Bool
        switch preset.hdr {
        case .toneMapToSDR: hdr = false
        case .auto, .preserve: hdr = payload.isHDR
        }
        if preset.videoCodec == .hevcHLG10, !payload.isHDR {
            warnings.append("HEVC HLG requested but not every source is HDR; exporting SDR HEVC instead")
            hdr = false
        }
        if preset.videoCodec != .hevcHLG10, preset.videoCodec != .proRes422, preset.videoCodec != .proRes4444, hdr,
            preset.hdr != .preserve
        {
            // H.264 / HEVC SDR presets: tone-map unless the preset explicitly preserves.
            hdr = false
        }
        let presetName: String
        var fileType: AVFileType = preset.container == .mp4 ? .mp4 : .mov
        switch preset.videoCodec {
        case .h264:
            presetName = AVAssetExportPresetHighestQuality
        case .hevc, .hevcHLG10:
            presetName = AVAssetExportPresetHEVCHighestQuality
        case .proRes422:
            presetName = AVAssetExportPresetAppleProRes422LPCM
            if fileType != .mov {
                warnings.append("ProRes needs a QuickTime container; writing .mov")
                fileType = .mov
            }
        case .proRes4444:
            presetName = AVAssetExportPresetAppleProRes4444LPCM
            if fileType != .mov {
                warnings.append("ProRes needs a QuickTime container; writing .mov")
                fileType = .mov
            }
        }
        if hdr, preset.videoCodec == .h264 {
            warnings.append("H.264 cannot carry HLG; exporting SDR")
            hdr = false
        }
        switch preset.videoQuality {
        case .bitrate(let bps):
            warnings.append("Bitrate \(bps) b/s is advisory: AVAssetExportSession presets choose their own rate")
        case .quality:
            break
        }
        let isProRes = preset.videoCodec == .proRes422 || preset.videoCodec == .proRes4444
        switch preset.audioCodec {
        case .aac where isProRes: warnings.append("ProRes presets write LPCM audio, not AAC")
        case .pcm where !isProRes: warnings.append("H.264/HEVC presets write AAC audio, not PCM")
        case .alac: warnings.append("ALAC is not available through AVAssetExportSession presets")
        default: break
        }
        if preset.loudnessTargetLUFS != nil {
            warnings.append("Loudness normalisation is not applied by this exporter")
        }
        let size: CGSize
        switch preset.size {
        case .matchSequence: size = payload.renderSize
        case .fixed(let w, let h): size = CGSize(width: w, height: h)
        }
        let frameDuration: CMTime
        switch preset.frameRate {
        case .matchSequence: frameDuration = payload.frameDuration
        case .fixed(let rate): frameDuration = CMTime(value: rate.den, timescale: Int32(clamping: rate.num))
        }
        return ExportSettings(
            presetName: presetName, fileType: fileType, renderSize: size, frameDuration: frameDuration, hdr: hdr,
            warnings: warnings)
    }
}

extension AVFoundationRenderer {
    public func export(_ compiled: Compiled, preset: ExportPreset, to url: URL) -> Job {
        let sequenceId = compiled.sequenceId
        let duration = compiled.duration
        return Job(kind: .export, memoryClass: .medium, label: "Export \(preset.name)") { context in
            guard let payload = compiled.renderPayload else { throw RenderKitError.notARenderKitPayload }
            let started = Date()
            let settings = ExportSettings.resolve(preset, for: payload)
            var warnings = settings.warnings
            for asset in payload.offlineAssets {
                warnings.append("Offline asset rendered as a slate: \(asset.displayName)")
            }
            context.report(JobProgress(fraction: 0, stage: "prepare"))
            try context.checkCancellation()

            // A fresh video composition for the export size, frame rate, and dynamic range; same table.
            let table = payload.instructions
            let videoComposition: AVVideoComposition
            if settings.hdr == payload.isHDR, settings.renderSize == payload.renderSize,
                settings.frameDuration == payload.frameDuration
            {
                videoComposition = payload.videoComposition
            } else {
                let retagged = settings.hdr == payload.isHDR ? table : table.retagged(hdr: settings.hdr)
                videoComposition = SequenceCompiler.videoComposition(
                    retagged, renderSize: settings.renderSize, frameDuration: settings.frameDuration, hdr: settings.hdr)
            }

            guard let session = AVAssetExportSession(asset: payload.composition, presetName: settings.presetName)
            else { throw RenderKitError.exportSessionUnavailable(settings.presetName) }
            session.videoComposition = videoComposition
            session.audioMix = payload.audioMix
            session.shouldOptimizeForNetworkUse = settings.fileType == .mp4
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let states = session.states(updateInterval: 0.25)
            let progress = Task {
                for await state in states {
                    if case .exporting(let p) = state {
                        context.report(JobProgress(fraction: p.fractionCompleted, stage: "encode"))
                    }
                }
            }
            defer { progress.cancel() }
            let exporter = ExportSessionBox(session)
            try await withTaskCancellationHandler {
                try await exporter.session.export(to: url, as: settings.fileType)
            } onCancel: {
                exporter.session.cancelExport()
            }
            try context.checkCancellation()
            context.report(.done)
            let receipt = ExportReceipt(
                preset: preset, sequenceId: sequenceId, projectVersion: nil, outputURL: url,
                durationSeconds: duration.seconds, startedAt: started, finishedAt: Date(), warnings: warnings)
            return try JobOutcome(urls: [url], encoding: receipt, warnings: warnings)
        }
    }
}

/// `AVAssetExportSession` is not Sendable; the cancellation handler only calls `cancelExport`, which is
/// documented as safe from any thread.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

extension InstructionTable {
    /// The same table with every instruction's dynamic range flag replaced (export policy).
    func retagged(hdr: Bool) -> InstructionTable {
        InstructionTable(
            instructions.map {
                RenderInstruction(
                    timeRange: $0.timeRange, layers: $0.layers, transitions: $0.transitions, captions: $0.captions,
                    blendSpace: $0.blendSpace, hdr: hdr, sequenceSize: $0.sequenceSize)
            })
    }
}
