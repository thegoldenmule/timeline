import Contracts
import Foundation
import Synchronization
import TimelineCore

/// Returns a configured `Alignment` (default: `Alignment.fixture`), records calls, honours cancellation.
public final class FakeAudioAligner: AudioAligner, Sendable {
    public struct Call: Sendable, Hashable {
        public var reference: AudioSource
        public var target: AudioSource
        public var parameters: AlignmentParameters
    }

    private struct State {
        var calls: [Call] = []
        var result: Alignment
        var error: (any Error)?
        var delay: Duration?
    }

    private let state: Mutex<State>

    public init(result: Alignment = .fixture, delay: Duration? = nil) {
        state = Mutex(State(result: result, delay: delay))
    }

    public var calls: [Call] { state.withLock { $0.calls } }
    public func setResult(_ alignment: Alignment) { state.withLock { $0.result = alignment } }
    public func fail(with error: (any Error)?) { state.withLock { $0.error = error } }

    public func align(reference: AudioSource, target: AudioSource, parameters: AlignmentParameters) async throws
        -> Alignment
    {
        state.withLock { $0.calls.append(Call(reference: reference, target: target, parameters: parameters)) }
        try Task.checkCancellation()
        if let delay = state.withLock({ $0.delay }) { try await Task.sleep(for: delay) }
        if let error = state.withLock({ $0.error }) { throw error }
        var result = state.withLock { $0.result }
        result.referenceHash = reference.contentHash ?? result.referenceHash
        result.targetHash = target.contentHash ?? result.targetHash
        return result
    }
}

extension Alignment {
    /// The spike's +10 dB case: aligned at 7.345 s, 23 ppm drift, one verified candidate.
    public static let fixture: Alignment = {
        let offset = RationalTime(352_560, 48000)  // 7.345 s
        let candidate = AlignmentCandidate(
            offset: offset, driftPPM: 23.1, confidence: 0.98, verified: true, coarseScore: 0.376, inlierFraction: 1,
            fitMADMs: 0.001)
        let proof = AlignmentProof(
            correlation: [0.02, 0.05, 0.376, 0.06, 0.03], correlationLagStartSeconds: 7.0,
            correlationLagStepSeconds: 0.128, windowTimesSeconds: [0, 10, 20, 30],
            windowOffsetsMs: [7345.0, 7344.77, 7344.54, 7344.31], windowInliers: [true, true, true, true],
            fitSlopePPM: 23.1, fitInterceptMs: 7345.0)
        return Alignment(
            status: .aligned, offset: offset, driftPPM: 23.1, confidence: 0.98, candidates: [candidate], proof: proof,
            referenceHash: "sha256-camera", targetHash: "sha256-render", parametersHash: "fake-v1",
            elapsedSeconds: 0.7)
    }()

    /// The -15 dB case: no verified candidate, no offset.
    public static let failedFixture = Alignment(
        status: .failed, offset: nil, driftPPM: 0, confidence: 0, candidates: [], proof: nil, referenceHash: nil,
        targetHash: nil, parametersHash: "fake-v1", elapsedSeconds: 0.7)
}
