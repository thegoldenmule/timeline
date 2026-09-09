import AVFoundation
import Contracts
import CoreGraphics
import CoreMedia
import Foundation
import TimelineCore

/// The `Renderer` for the app: `Sequence` to `AVMutableComposition` + `AVVideoComposition.Configuration` +
/// `AVMutableAudioMix`, one custom compositor for preview, grabs, and export, and the update split from
/// spikes/preview-update (instructions-only edits replace `videoComposition`/`audioMix` on the live item;
/// structural edits get a new composition and item, never a mutated live one).
public final class AVFoundationRenderer: Renderer, Sendable {
    public let layout: LibraryLayout
    /// The project's `settings.blendSpace`; `RenderOptions.blendSpace` overrides it per compile.
    public let blendSpace: BlendSpace
    let compiler: SequenceCompiler

    public init(layout: LibraryLayout = .default, blendSpace: BlendSpace = .gamma) {
        self.layout = layout
        self.blendSpace = blendSpace
        compiler = SequenceCompiler(layout: layout, sources: SourceCache())
    }

    // MARK: Compile and update

    public func compile(_ sequence: Sequence, assets: [AssetID: Asset], options: RenderOptions) async throws -> Compiled
    {
        let structure = try await compiler.structure(sequence, assets: assets, options: options)
        return make(sequence, assets: assets, options: options, structure: structure)
    }

    public func update(_ compiled: Compiled, to sequence: Sequence, assets: [AssetID: Asset]) async throws
        -> RenderUpdate
    {
        guard let payload = compiled.renderPayload else { throw RenderKitError.notARenderKitPayload }
        let options = compiled.options
        let structural = RenderFingerprint.structural(sequence, assets: assets, layout: layout, audio: options.audio)
        if structural == compiled.structuralFingerprint {
            let next = make(sequence, assets: assets, options: options, structure: payload.structure)
            if next.hasAudio == compiled.hasAudio { return .instructionsOnly(next) }
        }
        return .structural(try await compile(sequence, assets: assets, options: options))
    }

    private func make(
        _ sequence: Sequence, assets: [AssetID: Asset], options: RenderOptions, structure: CompositionStructure
    ) -> Compiled {
        let blend = options.blendSpace ?? blendSpace
        let id = CompiledID(minting: UUIDv7Generator())
        let table = compiler.instructions(
            sequence, assets: assets, structure: structure, blendSpace: blend, compiledId: id)
        let renderSize = CGSize(width: sequence.width, height: sequence.height)
        let frameDuration = CMTime(sequence.frameDuration)
        let videoComposition = SequenceCompiler.videoComposition(
            table, renderSize: renderSize, frameDuration: frameDuration, hdr: structure.hdr)
        let audioMix = compiler.audioMix(sequence, structure: structure)
        let payload = RenderPayload(
            structure: structure, videoComposition: videoComposition, audioMix: audioMix, instructions: table,
            blendSpace: blend, renderSize: renderSize, frameDuration: frameDuration, sequence: sequence, assets: assets,
            options: options)
        return Compiled(
            id: id, sequenceId: sequence.id,
            structuralFingerprint: RenderFingerprint.structural(
                sequence, assets: assets, layout: layout, audio: options.audio),
            instructionFingerprint: RenderFingerprint.instruction(
                sequence, assets: assets, blendSpace: blend, quality: options.quality),
            duration: RationalTime(structure.duration), hasAudio: structure.hasAudio, options: options, payload: payload
        )
    }

    // MARK: Player items

    @MainActor public func playerItem(for compiled: Compiled) -> AVPlayerItem {
        guard let payload = compiled.renderPayload else {
            preconditionFailure("AVFoundationRenderer.playerItem needs a Compiled from this renderer")
        }
        let item = AVPlayerItem(asset: payload.composition)
        item.videoComposition = payload.videoComposition
        item.audioMix = payload.audioMix
        item.seekingWaitsForVideoCompositionRendering = true
        return item
    }

    @MainActor public func apply(_ compiled: Compiled, to item: AVPlayerItem) {
        guard let payload = compiled.renderPayload else { return }
        item.videoComposition = payload.videoComposition
        item.audioMix = payload.audioMix
    }

    // MARK: Frames

    public func frame(_ compiled: Compiled, at time: RationalTime, size: CGSize?) async throws -> CGImage {
        guard let payload = compiled.renderPayload else { throw RenderKitError.notARenderKitPayload }
        // Held in a `let` for the whole request: a temporary generator never completes (spikes/compositor).
        let generator = AVAssetImageGenerator(asset: payload.composition)
        generator.videoComposition = payload.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.dynamicRangePolicy = payload.isHDR ? .matchSource : .forceSDR
        if let size { generator.maximumSize = size }
        let result = try await generator.image(at: CMTime(time))
        return withExtendedLifetime(generator) { result.image }
    }
}
