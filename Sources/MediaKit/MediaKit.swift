// MediaKit: media library import, hashing, probe, relink, thumbnails, peaks, onset envelopes, transcription,
// silence, shots, and the cache index. See docs/design/implementation-plan.md (MediaKit row) and
// docs/design/storage.md sections 1, 2, and 11.
import Contracts
import Foundation
import TimelineCore

public enum MediaKit {
    /// Builds the `recordAssetAnalysis` operation the app issues once an analysis has produced its cache key
    /// (the `cacheKey` on a `Transcript`, `SilenceRanges`, `ShotList`, `OnsetEnvelope`, or `WaveformPeaks` result).
    public static func analysisOperation(
        for assetId: AssetID, kind: AnalysisKind, cacheKey: String, summary: JSONValue? = nil
    ) -> Command.Operation {
        .recordAssetAnalysis(.init(assetId: .id(assetId), kind: kind.rawValue, cacheKey: cacheKey, summary: summary))
    }

    public static func analysisOperation(
        for asset: Asset, kind: AnalysisKind, cacheKey: String, summary: JSONValue? = nil
    ) -> Command.Operation {
        analysisOperation(for: asset.id, kind: kind, cacheKey: cacheKey, summary: summary)
    }

    /// `v<version>-<fnv1a of the canonical parameter JSON>`, the `params_hash` column of the artifacts table and
    /// the last segment of an `AnalysisCacheKey`. Bumping a generator's version invalidates every artifact it made.
    static func paramsHash<P: Encodable>(version: Int, parameters: P) throws -> String {
        "v\(version)-\(try StableHash.fnv1a(encoding: parameters))"
    }
}

/// ISO-8601 UTC with milliseconds, the timestamp format of every cache row (storage.md section 4).
enum Timestamps {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ string: String) -> Date? { formatter.date(from: string) }
}

extension RationalTime {
    /// Media time from a Core Media time without rescaling; invalid or indefinite times become zero.
    init(cmValue value: Int64, timescale: Int32) {
        self.init(value: value, timescale: timescale > 0 ? timescale : 1)
    }
}
