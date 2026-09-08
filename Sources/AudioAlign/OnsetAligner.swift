import Contracts
import CryptoKit
import Foundation
import TimelineCore

/// The `AudioAligner` implementation: onset-envelope coarse correlation, GCC-PHAT fine pass, Theil-Sen drift,
/// drift-corrected second pass, fine-pass verification as the confidence signal.
///
/// Conventions
/// - `Alignment.offset` is the reference position of target sample 0 (positive: the target starts later),
///   expressed at `referenceSampleRate * AlignerDefaults.offsetTimescaleMultiplier` so the sub-sample residual of
///   the parabolic interpolation survives (48,000,000 per second for a 48 kHz reference).
/// - `driftPPM` is positive when the target clock runs fast: target time `t` maps to reference time
///   `offset + t / (1 + driftPPM * 1e-6)`. Correct it by resampling the target by `1 + driftPPM * 1e-6`.
/// - `AlignmentProof.windowOffsetsMs` are absolute reference positions of target sample 0 implied by each fine
///   window; the drift line through them is `fitInterceptMs - fitSlopePPM * 1e-3 * windowTimesSeconds`.
/// - Status: `aligned` for exactly one verified candidate, `ambiguous` for several (repeated material), `failed`
///   for none; `offset` is the best verified candidate's, nil on failure. Never a wrong confident answer.
/// - The blocking decode and DSP work runs on a global dispatch queue behind a continuation rather than on a
///   cooperative-pool thread, so many alignments (or an alignment next to a busy UI) never starve Swift
///   concurrency. Cancellation is cooperative: a `CancellationToken` tied to the calling task is checked between
///   stages, between streamed chunks, and between fine windows. Progress is reported through the optional
///   `progress` hook in 0...1.
public struct OnsetAligner: AudioAligner, Sendable {
    /// Folded into `parametersHash`; bump on any change that alters results for the same parameters.
    public static let version = "OnsetAligner/1"

    public var progress: (@Sendable (Double) -> Void)?

    public init(progress: (@Sendable (Double) -> Void)? = nil) {
        self.progress = progress
    }

    // MARK: AudioAligner

    public func align(
        reference: AudioSource, target: AudioSource, parameters: AlignmentParameters
    ) async throws -> Alignment {
        let started = ContinuousClock.now
        let referenceInput = try await Input.open(reference, parameters: parameters)
        let targetInput = try await Input.open(target, parameters: parameters)
        return try await run(reference: referenceInput, target: targetInput, parameters: parameters, started: started)
    }

    /// The same alignment over sources the caller already holds (decoded buffers, a custom reader), with
    /// optional precomputed envelopes.
    public func align(
        reference: any MonoAudioSource, referenceEnvelope: OnsetEnvelope? = nil, referenceHash: String? = nil,
        target: any MonoAudioSource, targetEnvelope: OnsetEnvelope? = nil, targetHash: String? = nil,
        parameters: AlignmentParameters
    ) async throws -> Alignment {
        try await run(
            reference: Input(source: reference, envelope: referenceEnvelope, hash: referenceHash, url: nil),
            target: Input(source: target, envelope: targetEnvelope, hash: targetHash, url: nil),
            parameters: parameters, started: .now)
    }

    // MARK: Envelopes

    /// Streams the first audio track of `url` through `OnsetEnvelopeBuilder`; the same code path MediaKit uses
    /// to produce its `onset-8k.f32` cache, so `AudioSource.envelope` and `AudioSource.file` agree.
    public func onsetEnvelope(url: URL, parameters: AlignmentParameters) async throws -> OnsetEnvelope {
        let source = try await AudioFileSource.open(url: url)
        let progress = progress
        return try await Self.blocking { token in
            try Self.onsetEnvelope(of: source, parameters: parameters, cancellation: token, progress: progress)
        }
    }

    /// The raw `[Float]` form of `onsetEnvelope(url:parameters:)`.
    public func onsetEnvelopeValues(url: URL, parameters: AlignmentParameters) async throws -> [Float] {
        try await onsetEnvelope(url: url, parameters: parameters).values
    }

    /// Streams any `MonoAudioSource` through the builder in `AlignerDefaults.streamingChunkFrames` chunks,
    /// checking for cancellation between chunks.
    public static func onsetEnvelope(
        of source: any MonoAudioSource, parameters: AlignmentParameters, cancellation: CancellationToken? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> OnsetEnvelope {
        var builder = try OnsetEnvelopeBuilder(inputSampleRate: source.sampleRate, parameters: parameters)
        let total = Double(max(1, source.frameCount))
        var consumed: Int64 = 0
        let token = cancellation ?? CancellationToken()
        try source.forEachChunk(chunkFrames: AlignerDefaults.streamingChunkFrames) { chunk in
            try token.check()
            builder.append(chunk)
            consumed += Int64(chunk.count)
            progress?(min(1, Double(consumed) / total))
        }
        return builder.finish()
    }

    // MARK: Parameters hash

    /// SHA-256 of `version`, a NUL byte, and the canonical JSON (`sortedKeys`) of the parameters, hex-encoded.
    public static func parametersHash(_ parameters: AlignmentParameters) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        // Encoding a struct of numbers with a non-conforming-float strategy cannot fail.
        let json = (try? encoder.encode(parameters)) ?? Data()
        var hasher = SHA256()
        hasher.update(data: Data(version.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: json)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Inputs

    struct Input: Sendable {
        var source: any MonoAudioSource
        var envelope: OnsetEnvelope?
        var hash: String?
        var url: URL?

        static func open(_ audio: AudioSource, parameters: AlignmentParameters) async throws -> Input {
            switch audio {
            case .file(let url, let hash):
                return Input(source: try await AudioFileSource.open(url: url), envelope: nil, hash: hash, url: url)
            case .envelope(let envelopeURL, let audioURL, let hash):
                let envelope = try OnsetEnvelope.read(from: envelopeURL, parameters: parameters)
                return Input(
                    source: try await AudioFileSource.open(url: audioURL), envelope: envelope, hash: hash, url: audioURL
                )
            }
        }
    }

    /// A candidate after the fine pass, with the data behind its proof.
    struct Evaluated {
        var candidate: AlignmentCandidate
        var windows: [FineWindow]
        var fit: LineFit?
    }

    // MARK: Pipeline

    private func report(_ fraction: Double) {
        progress?(max(0, min(1, fraction)))
    }

    private static func validateFineParameters(_ p: AlignmentParameters) throws {
        guard p.fineWindowSeconds > 0 else { throw AudioAlignError.invalidParameters("fineWindowSeconds") }
        guard p.fineWindowCount >= 1 else { throw AudioAlignError.invalidParameters("fineWindowCount") }
        guard p.fineSearchRadiusMs > 0 else { throw AudioAlignError.invalidParameters("fineSearchRadiusMs") }
        guard p.inlierToleranceMs > 0, p.maxFitMADMs > 0 else {
            throw AudioAlignError.invalidParameters("inlierToleranceMs and maxFitMADMs must be positive")
        }
        guard p.maxCandidates >= 1 else { throw AudioAlignError.invalidParameters("maxCandidates") }
    }

    /// Runs `body` on a global queue and suspends the caller; cancelling the calling task cancels the token.
    static func blocking<T: Sendable>(
        _ body: @Sendable @escaping (CancellationToken) throws -> T
    ) async throws -> T {
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try body(token) })
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    private func run(
        reference: Input, target: Input, parameters p: AlignmentParameters, started: ContinuousClock.Instant
    ) async throws -> Alignment {
        try OnsetEnvelopeBuilder.validate(p)
        try Self.validateFineParameters(p)
        return try await Self.blocking { token in
            try pipeline(reference: reference, target: target, parameters: p, started: started, token: token)
        }
    }

    private func pipeline(
        reference: Input, target: Input, parameters p: AlignmentParameters, started: ContinuousClock.Instant,
        token: CancellationToken
    ) throws -> Alignment {
        let fsRef = reference.source.sampleRate
        let frameRate = OnsetEnvelope.frameRate(for: p)

        // 1. Envelopes (streamed; the long reference is never resident).
        report(0)
        let referenceEnvelope: OnsetEnvelope
        if let envelope = reference.envelope {
            referenceEnvelope = envelope
        } else {
            referenceEnvelope = try Self.onsetEnvelope(of: reference.source, parameters: p, cancellation: token) {
                report(0.55 * $0)
            }
        }
        try token.check()
        let targetEnvelope: OnsetEnvelope
        if let envelope = target.envelope {
            targetEnvelope = envelope
        } else {
            targetEnvelope = try Self.onsetEnvelope(of: target.source, parameters: p, cancellation: token) {
                report(0.55 + 0.1 * $0)
            }
        }
        guard referenceEnvelope.frameCount > 0 else { throw AudioAlignError.inputTooShort(reference.url) }
        guard targetEnvelope.frameCount > 0 else { throw AudioAlignError.inputTooShort(target.url) }
        try token.check()

        // 2. Coarse pass.
        let coarse = CoarsePass.correlate(
            reference: referenceEnvelope.values, target: targetEnvelope.values, frameRate: frameRate, parameters: p)
        report(0.7)
        try token.check()

        // 3. Fine pass per candidate.
        let targetFramesAtReference = Int(Double(target.source.frameCount) * fsRef / target.source.sampleRate)
        let windowSamples = min(Int(p.fineWindowSeconds * fsRef), targetFramesAtReference)
        var fine: FinePass?
        if windowSamples >= 2 { fine = FinePass(sampleRate: fsRef, windowSamples: windowSamples, parameters: p) }
        var evaluated: [Evaluated] = []
        for (index, candidate) in coarse.candidates.enumerated() {
            try token.check()
            let coarseStart = Int((Double(candidate.lagFrames) / frameRate * fsRef).rounded())
            if let fine {
                evaluated.append(
                    try evaluate(
                        candidate: candidate, coarseStart: coarseStart, fine: fine, reference: reference.source,
                        target: target.source, targetFramesAtReference: targetFramesAtReference, parameters: p,
                        token: token))
            } else {
                evaluated.append(
                    Evaluated(
                        candidate: Self.candidate(
                            offsetSamples: Double(coarseStart), sampleRate: fsRef, driftPPM: 0, confidence: 0,
                            verified: false, coarseScore: Double(candidate.ncc), inlierFraction: 0, fitMADMs: .nan),
                        windows: [], fit: nil))
            }
            report(0.7 + 0.3 * Double(index + 1) / Double(coarse.candidates.count))
        }
        evaluated.sort { lhs, rhs in
            if lhs.candidate.verified != rhs.candidate.verified { return lhs.candidate.verified }
            if lhs.candidate.confidence != rhs.candidate.confidence {
                return lhs.candidate.confidence > rhs.candidate.confidence
            }
            return lhs.candidate.coarseScore > rhs.candidate.coarseScore
        }

        // 4. Verdict and proof.
        let verifiedCount = evaluated.filter { $0.candidate.verified }.count
        let status: Alignment.Status = verifiedCount == 0 ? .failed : (verifiedCount == 1 ? .aligned : .ambiguous)
        let best = evaluated.first
        let proof = Self.proof(coarse: coarse, frameRate: frameRate, best: best, sampleRate: fsRef, parameters: p)
        report(1)
        let elapsed = ContinuousClock.now - started
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return Alignment(
            status: status, offset: status == .failed ? nil : best?.candidate.offset,
            driftPPM: status == .failed ? 0 : best?.candidate.driftPPM ?? 0,
            confidence: status == .failed ? 0 : best?.candidate.confidence ?? 0,
            candidates: evaluated.map(\.candidate), proof: proof, referenceHash: reference.hash,
            targetHash: target.hash, parametersHash: Self.parametersHash(p), elapsedSeconds: elapsedSeconds)
    }

    /// Fine pass for one coarse candidate: PHAT windows, Theil-Sen fit, verification, then a drift-corrected
    /// second pass when the first one verified and found drift worth correcting.
    private func evaluate(
        candidate: CoarseCandidate, coarseStart: Int, fine: FinePass, reference: any MonoAudioSource,
        target: any MonoAudioSource, targetFramesAtReference: Int, parameters p: AlignmentParameters,
        token: CancellationToken
    ) throws -> Evaluated {
        let fsRef = reference.sampleRate
        let starts = Self.windowStarts(
            targetFrames: targetFramesAtReference, windowSamples: fine.windowSamples, count: p.fineWindowCount)
        let tolerance = p.inlierToleranceMs / 1000 * fsRef

        func pass(driftPPM: Double) throws -> (windows: [FineWindow], fit: LineFit) {
            var windows: [FineWindow] = []
            windows.reserveCapacity(starts.count)
            let ratio = (1 + driftPPM * 1e-6) * target.sampleRate / fsRef
            for w in starts {
                try token.check()
                let referenceStart = coarseStart + w - fine.radius
                let referenceEnd = referenceStart + fine.windowSamples + 2 * fine.radius
                // A window whose reference excerpt leaves the recording measures zero-padding, not audio.
                guard referenceStart >= 0, Int64(referenceEnd) <= reference.frameCount else { continue }
                let referenceExcerpt = try reference.read(frames: Int64(referenceStart)..<Int64(referenceEnd))
                let targetExcerpt = try Self.targetExcerpt(target, start: w, count: fine.windowSamples, ratio: ratio)
                let m = fine.measure(reference: referenceExcerpt, target: targetExcerpt)
                windows.append(
                    FineWindow(
                        targetTimeSeconds: (Double(w) + Double(fine.windowSamples) / 2) / fsRef,
                        offsetSamples: Double(coarseStart) + m.lag - Double(fine.radius), peak: m.peak, ratio: m.ratio))
            }
            let fit = theilSen(
                x: windows.map(\.targetTimeSeconds), y: windows.map(\.offsetSamples),
                valid: windows.map { $0.ratio >= AlignerDefaults.minimumPhatPeakRatio }, inlierTolerance: tolerance,
                fitSlope: windows.count >= AlignerDefaults.minimumWindowsForDriftFit)
            return (windows, fit)
        }

        var (windows, fit) = try pass(driftPPM: 0)
        var driftPPM = -fit.slope / fsRef * 1e6
        var verdict = Self.verify(fit: fit, driftPPM: driftPPM, sampleRate: fsRef, parameters: p)
        if verdict.verified, abs(driftPPM) >= p.driftFloorPpm {
            // Pass 2: undo the estimated drift so the PHAT peaks are no longer smeared inside a window.
            let corrected = try pass(driftPPM: driftPPM)
            let residualPPM = -corrected.fit.slope / fsRef * 1e6
            windows = corrected.windows
            fit = corrected.fit
            driftPPM = ((1 + driftPPM * 1e-6) * (1 + residualPPM * 1e-6) - 1) * 1e6
            verdict = Self.verify(fit: fit, driftPPM: driftPPM, sampleRate: fsRef, parameters: p)
        }
        let reportedDrift = abs(driftPPM) < p.driftFloorPpm ? 0 : driftPPM
        return Evaluated(
            candidate: Self.candidate(
                offsetSamples: fit.intercept, sampleRate: fsRef, driftPPM: reportedDrift,
                confidence: verdict.confidence, verified: verdict.verified, coarseScore: Double(candidate.ncc),
                inlierFraction: fit.inlierFraction, fitMADMs: fit.mad / fsRef * 1000),
            windows: windows, fit: fit)
    }

    /// Confidence is the fine-pass verification signal: inlier fraction (windows whose PHAT peak is unambiguous
    /// and whose offset sits on the drift line) weighted by how far the fit's MAD sits under `maxFitMADMs`. The
    /// coarse peak ratio plays no part (it collapses long before the alignment does).
    static func verify(
        fit: LineFit, driftPPM: Double, sampleRate: Double, parameters p: AlignmentParameters
    ) -> (verified: Bool, confidence: Double) {
        guard fit.count >= AlignerDefaults.minimumVerificationWindows, fit.intercept.isFinite, fit.mad.isFinite
        else { return (false, 0) }
        let madMs = fit.mad / sampleRate * 1000
        let confidence = fit.inlierFraction * max(0, 1 - madMs / p.maxFitMADMs)
        let verified =
            fit.inlierFraction >= p.minimumInlierFraction && madMs < p.maxFitMADMs && confidence >= p.minConfidence
            && abs(driftPPM) <= p.maxDriftPpm
        return (verified, confidence)
    }

    /// Up to `count` window starts of `windowSamples` spread evenly over the target.
    static func windowStarts(targetFrames: Int, windowSamples: Int, count: Int) -> [Int] {
        guard windowSamples > 0, targetFrames >= windowSamples else { return [] }
        let n = max(1, min(count, targetFrames / windowSamples))
        guard n > 1 else { return [0] }
        let hop = Double(targetFrames - windowSamples) / Double(n - 1)
        return (0..<n).map { Int((Double($0) * hop).rounded()) }
    }

    /// `count` target samples starting at `start`, both in the reference-rate, drift-corrected domain: output
    /// `j` is the target's native signal at position `j * ratio`, Hermite-interpolated from just the native
    /// samples that excerpt needs.
    static func targetExcerpt(_ target: any MonoAudioSource, start: Int, count: Int, ratio: Double) throws
        -> [Float]
    {
        if ratio == 1 { return try target.read(frames: Int64(start)..<Int64(start + count)) }
        let p0 = Double(start) * ratio, p1 = Double(start + count - 1) * ratio
        let lo = Int64(p0.rounded(.down)) - 1, hi = Int64(p1.rounded(.up)) + 3
        let native = try target.read(frames: lo..<hi)
        return hermiteResample(native, start: p0 - Double(lo), ratio: ratio, count: count)
    }

    static func offsetTime(samples: Double, sampleRate: Double) -> RationalTime {
        let rate = sampleRate.rounded()
        let multiplier = Double(AlignerDefaults.offsetTimescaleMultiplier)
        if rate * multiplier <= Double(Int32.max) {
            return RationalTime(value: Int64((samples * multiplier).rounded()), timescale: Int32(rate * multiplier))
        }
        return RationalTime(value: Int64(samples.rounded()), timescale: Int32(rate))
    }

    static func candidate(
        offsetSamples: Double, sampleRate: Double, driftPPM: Double, confidence: Double, verified: Bool,
        coarseScore: Double, inlierFraction: Double, fitMADMs: Double
    ) -> AlignmentCandidate {
        AlignmentCandidate(
            offset: offsetTime(samples: offsetSamples.isFinite ? offsetSamples : 0, sampleRate: sampleRate),
            driftPPM: driftPPM, confidence: confidence, verified: verified, coarseScore: coarseScore,
            inlierFraction: inlierFraction, fitMADMs: fitMADMs)
    }

    static func proof(
        coarse: CoarseResult, frameRate: Double, best: Evaluated?, sampleRate: Double, parameters p: AlignmentParameters
    ) -> AlignmentProof {
        let (pooled, bucket) = CoarsePass.pooled(coarse.ncc, points: AlignerDefaults.proofCorrelationPoints)
        let windows = best?.windows ?? []
        let fit = best?.fit
        return AlignmentProof(
            correlation: pooled, correlationLagStartSeconds: Double(coarse.lagStart) / frameRate,
            correlationLagStepSeconds: Double(bucket) / frameRate,
            windowTimesSeconds: windows.map(\.targetTimeSeconds),
            windowOffsetsMs: windows.map { $0.offsetSamples / sampleRate * 1000 },
            windowInliers: fit?.inliers ?? [], fitSlopePPM: best?.candidate.driftPPM ?? 0,
            fitInterceptMs: (fit?.intercept ?? 0) / sampleRate * 1000)
    }
}
