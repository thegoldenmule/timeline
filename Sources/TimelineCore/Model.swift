import Foundation

// MARK: - Project

/// The whole editable document. Dictionaries are keyed by id everywhere except `Sequence.tracks`,
/// whose order is meaningful, so a sorted-keys encoder yields a canonical JSON document.
public struct Project: Hashable, Sendable, Codable {
    public var id: ProjectID
    public var name: String
    /// Number of events applied so far (the stream version). Bumped by `evolve` once per event.
    public var version: Int64
    public var settings: ProjectSettings
    public var assets: [AssetID: Asset]
    public var sequences: [SequenceID: Sequence]
    public var activeSequenceId: SequenceID?

    public init(
        id: ProjectID, name: String, version: Int64 = 0, settings: ProjectSettings = ProjectSettings(),
        assets: [AssetID: Asset] = [:], sequences: [SequenceID: Sequence] = [:], activeSequenceId: SequenceID? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.settings = settings
        self.assets = assets
        self.sequences = sequences
        self.activeSequenceId = activeSequenceId
    }

    /// The state before `createProject`: the only state that accepts that command.
    public static let blank = Project(id: "00000000-0000-0000-0000-000000000000", name: "")

    /// True once `ProjectCreated` has been applied.
    public var isCreated: Bool { version > 0 || !sequences.isEmpty }

    public var activeSequence: Sequence? {
        guard let id = activeSequenceId else { return nil }
        return sequences[id]
    }
}

public enum BlendSpace: String, Codable, Hashable, Sendable, CaseIterable {
    case gamma
    case linear
}

public struct ProjectSettings: Hashable, Sendable, Codable {
    public var sampleRate: Int
    public var colorSpace: String
    public var blendSpace: BlendSpace
    public var alignment: AlignmentParameters

    public init(
        sampleRate: Int = 48000, colorSpace: String = "rec709", blendSpace: BlendSpace = .gamma,
        alignment: AlignmentParameters = AlignmentParameters()
    ) {
        self.sampleRate = sampleRate
        self.colorSpace = colorSpace
        self.blendSpace = blendSpace
        self.alignment = alignment
    }
}

/// Tunables for `AudioAlign`. Defaults are the values that worked in `spikes/audio-align/SPIKE.md`;
/// the ones marked "policy" are product choices the spike did not measure.
public struct AlignmentParameters: Hashable, Sendable, Codable {
    /// Bandpass applied to both signals before onset detection (RBJ Butterworth HP/LP), in Hz.
    public var bandpassLowHz: Double = 300
    public var bandpassHighHz: Double = 3000
    /// Sample rate of the decimated copy the coarse pass works on.
    public var envelopeSampleRate: Int = 8000
    /// STFT window and hop (samples at `envelopeSampleRate`): 512 / 128 gives 62.5 envelope frames per second.
    public var envelopeWindow: Int = 512
    public var envelopeHop: Int = 128
    /// Number of log-spaced onset bands between the bandpass edges.
    public var envelopeBands: Int = 24
    /// Running-median length for envelope detrending, seconds.
    public var envelopeMedianSeconds: Double = 1
    /// Energy floor as a fraction of mean overlap power, guarding NCC against silent stretches.
    public var energyFloorFraction: Double = 0.1
    /// Minimum overlap between the two signals for a lag to be considered, as a fraction of the
    /// shorter signal and as an absolute number of seconds (policy).
    public var minimumOverlapFraction: Double = 0.5
    public var minimumOverlapSeconds: Double = 10
    /// A lag is a coarse candidate when its NCC is at least this fraction of the best peak.
    public var candidateCutoffRatio: Double = 0.5
    /// Maximum number of coarse candidates carried into the fine pass.
    public var maxCandidates: Int = 5
    /// The "second peak" must be at least this far from the best peak, seconds.
    public var secondPeakExclusionSeconds: Double = 5
    /// Fine pass: GCC-PHAT window length and count, and the search radius around the coarse lag.
    public var fineWindowSeconds: Double = 10
    public var fineWindowCount: Int = 24
    public var fineSearchRadiusMs: Double = 100
    /// GCC-PHAT weighting exponent, epsilon (relative to max |G|), and spectral mask in Hz.
    public var phatRho: Double = 1
    public var phatEpsilon: Double = 1e-6
    public var phatBandLowHz: Double = 80
    public var phatBandHighHz: Double = 7000
    /// A fine window is an inlier when its residual against the drift fit is within this, ms.
    public var inlierToleranceMs: Double = 0.5
    /// Verification: a candidate is verified when at least this fraction of windows are inliers
    /// and the fit's median absolute deviation is under `maxFitMADMs`.
    public var minimumInlierFraction: Double = 0.6
    public var maxFitMADMs: Double = 0.5
    /// Drift below this magnitude is reported as zero (policy; the spike's residual was 0.1 ppm).
    public var driftFloorPpm: Double = 0.5
    /// Drift beyond this magnitude is rejected as implausible for consumer clocks (policy).
    public var maxDriftPpm: Double = 500
    /// Results under this confidence are reported as "no alignment" (policy; good cases scored 0.95-1.0).
    public var minConfidence: Double = 0.5
    /// FIR length for the full-rate to `envelopeSampleRate` decimation (Blackman-windowed sinc; spike: 127 taps).
    public var decimationFilterTaps: Int = 127
    /// FIR cutoff as a fraction of the envelope-rate Nyquist frequency (spike: 3.6 kHz of 4 kHz).
    public var decimationCutoffFraction: Double = 0.9
    /// Added to each STFT band power before the log so digital silence does not produce `log(0)`, in
    /// absolute band-power units of a unit-RMS signal (about -90 dB); only matters for silence.
    public var envelopeLogPowerFloor: Double = 1e-6
    /// The fine pass's "second peak" must be at least this far from the PHAT peak, ms (spike: 48 samples at 48 kHz).
    public var phatSecondPeakExclusionMs: Double = 1
    /// A fine window counts as an inlier only when its PHAT peak is at least this many times the best value
    /// more than `phatSecondPeakExclusionMs` away (measured: 1.8-2.8 for true alignments down to -10 dB SNR,
    /// 1.0-1.25 for false candidates and unrelated material).
    public var minimumPhatPeakRatio: Double = 1.5
    /// A candidate needs at least this many fine windows measured inside the reference to be verified (policy).
    public var minimumVerificationWindows: Int = 2
    /// Fewer fine windows than this cannot support a drift fit; drift is then reported as zero (policy).
    public var minimumWindowsForDriftFit: Int = 3
    /// Number of points the coarse correlation curve is max-pooled to for `AlignmentProof.correlation` (policy).
    public var proofCorrelationPoints: Int = 2048

    public init() {}

    /// Older documents lack the fields added after Phase 1; they decode with the defaults above.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ into: inout T) throws {
            if let value = try c.decodeIfPresent(T.self, forKey: key) { into = value }
        }
        try read(.bandpassLowHz, &bandpassLowHz)
        try read(.bandpassHighHz, &bandpassHighHz)
        try read(.envelopeSampleRate, &envelopeSampleRate)
        try read(.envelopeWindow, &envelopeWindow)
        try read(.envelopeHop, &envelopeHop)
        try read(.envelopeBands, &envelopeBands)
        try read(.envelopeMedianSeconds, &envelopeMedianSeconds)
        try read(.energyFloorFraction, &energyFloorFraction)
        try read(.minimumOverlapFraction, &minimumOverlapFraction)
        try read(.minimumOverlapSeconds, &minimumOverlapSeconds)
        try read(.candidateCutoffRatio, &candidateCutoffRatio)
        try read(.maxCandidates, &maxCandidates)
        try read(.secondPeakExclusionSeconds, &secondPeakExclusionSeconds)
        try read(.fineWindowSeconds, &fineWindowSeconds)
        try read(.fineWindowCount, &fineWindowCount)
        try read(.fineSearchRadiusMs, &fineSearchRadiusMs)
        try read(.phatRho, &phatRho)
        try read(.phatEpsilon, &phatEpsilon)
        try read(.phatBandLowHz, &phatBandLowHz)
        try read(.phatBandHighHz, &phatBandHighHz)
        try read(.inlierToleranceMs, &inlierToleranceMs)
        try read(.minimumInlierFraction, &minimumInlierFraction)
        try read(.maxFitMADMs, &maxFitMADMs)
        try read(.driftFloorPpm, &driftFloorPpm)
        try read(.maxDriftPpm, &maxDriftPpm)
        try read(.minConfidence, &minConfidence)
        try read(.decimationFilterTaps, &decimationFilterTaps)
        try read(.decimationCutoffFraction, &decimationCutoffFraction)
        try read(.envelopeLogPowerFloor, &envelopeLogPowerFloor)
        try read(.phatSecondPeakExclusionMs, &phatSecondPeakExclusionMs)
        try read(.minimumPhatPeakRatio, &minimumPhatPeakRatio)
        try read(.minimumVerificationWindows, &minimumVerificationWindows)
        try read(.minimumWindowsForDriftFit, &minimumWindowsForDriftFit)
        try read(.proofCorrelationPoints, &proofCorrelationPoints)
    }
}

// MARK: - Assets

public enum AssetKind: String, Codable, Hashable, Sendable, CaseIterable {
    case video
    case audio
    case image
}

/// What the importer learned about a file. Open-ended fields go in `extra`.
public struct Probe: Hashable, Sendable, Codable {
    public var codec: String?
    public var width: Int?
    public var height: Int?
    public var fps: Rational?
    public var colorPrimaries: String?
    public var transfer: String?
    public var rotation: Int?
    public var capturedAt: Date?
    public var extra: [String: JSONValue]

    public init(
        codec: String? = nil, width: Int? = nil, height: Int? = nil, fps: Rational? = nil,
        colorPrimaries: String? = nil, transfer: String? = nil, rotation: Int? = nil, capturedAt: Date? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.colorPrimaries = colorPrimaries
        self.transfer = transfer
        self.rotation = rotation
        self.capturedAt = capturedAt
        self.extra = extra
    }
}

/// A recorded derived artifact (transcript, peaks, shots, ...). The data lives in the cache.
public struct AssetAnalysis: Hashable, Sendable, Codable {
    public var kind: String
    public var cacheKey: String
    public var summary: JSONValue?

    public init(kind: String, cacheKey: String, summary: JSONValue? = nil) {
        self.kind = kind
        self.cacheKey = cacheKey
        self.summary = summary
    }
}

public struct Asset: Hashable, Sendable, Codable {
    public var id: AssetID
    public var contentHash: String
    public var libraryPath: String
    public var displayName: String
    public var kind: AssetKind
    public var duration: RationalTime
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var sampleRate: Int?
    public var frameDuration: RationalTime?
    public var probe: Probe
    public var offline: Bool
    /// Keyed by analysis kind.
    public var analyses: [String: AssetAnalysis]

    public init(
        id: AssetID, contentHash: String, libraryPath: String, displayName: String, kind: AssetKind,
        duration: RationalTime, hasVideo: Bool, hasAudio: Bool, sampleRate: Int? = nil,
        frameDuration: RationalTime? = nil, probe: Probe = Probe(), offline: Bool = false,
        analyses: [String: AssetAnalysis] = [:]
    ) {
        self.id = id
        self.contentHash = contentHash
        self.libraryPath = libraryPath
        self.displayName = displayName
        self.kind = kind
        self.duration = duration
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.sampleRate = sampleRate
        self.frameDuration = frameDuration
        self.probe = probe
        self.offline = offline
        self.analyses = analyses
    }
}

// MARK: - Sequence, tracks

public struct Sequence: Hashable, Sendable, Codable {
    public var id: SequenceID
    public var name: String
    /// Canonical frame duration, e.g. 1001/24000.
    public var frameDuration: RationalTime
    public var width: Int
    public var height: Int
    /// Ordered; index 0 is the bottom video layer.
    public var tracks: [Track]
    public var transitions: [TransitionID: Transition]
    public var markers: [MarkerID: Marker]

    public init(
        id: SequenceID, name: String, frameDuration: RationalTime, width: Int, height: Int, tracks: [Track] = [],
        transitions: [TransitionID: Transition] = [:], markers: [MarkerID: Marker] = [:]
    ) {
        self.id = id
        self.name = name
        self.frameDuration = frameDuration
        self.width = width
        self.height = height
        self.tracks = tracks
        self.transitions = transitions
        self.markers = markers
    }
}

public enum TrackKind: String, Codable, Hashable, Sendable, CaseIterable {
    case video
    case audio
    case caption

    /// Video and caption tracks snap to the sequence frame; audio tracks are sample accurate.
    public var isFrameAligned: Bool { self != .audio }
}

public struct Track: Hashable, Sendable, Codable {
    public var id: TrackID
    public var kind: TrackKind
    public var name: String
    public var muted: Bool
    public var locked: Bool
    public var clips: [ClipID: Clip]
    /// Caption tracks only: BCP-47 language tag and the default style for items without one.
    public var language: String?
    public var captionStyle: CaptionStyle?

    public init(
        id: TrackID, kind: TrackKind, name: String, muted: Bool = false, locked: Bool = false,
        clips: [ClipID: Clip] = [:], language: String? = nil, captionStyle: CaptionStyle? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.muted = muted
        self.locked = locked
        self.clips = clips
        self.language = language
        self.captionStyle = captionStyle
    }
}

// MARK: - Clips

public enum Easing: String, Codable, Hashable, Sendable, CaseIterable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case hold
}

public struct Keyframe<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    /// Relative to the clip start.
    public var t: RationalTime
    public var value: Value
    public var easing: Easing

    public init(t: RationalTime, value: Value, easing: Easing = .linear) {
        self.t = t
        self.value = value
        self.easing = easing
    }
}

/// A constant or keyframed value. Version 1 produces only `.constant`; the keyframe shape exists
/// so adding animation later changes no payload. Encodes as `{ "constant": v }` or `{ "keyframes": [...] }`.
public enum Animatable<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    case constant(Value)
    case keyframes([Keyframe<Value>])

    public var constantValue: Value? {
        if case .constant(let v) = self { return v }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case constant
        case keyframes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.constant) {
            self = .constant(try c.decode(Value.self, forKey: .constant))
        } else if c.contains(.keyframes) {
            self = .keyframes(try c.decode([Keyframe<Value>].self, forKey: .keyframes))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "Animatable needs constant or keyframes"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .constant(let v): try c.encode(v, forKey: .constant)
        case .keyframes(let k): try c.encode(k, forKey: .keyframes)
        }
    }
}

public struct Transform: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var scale: Double
    /// Degrees, clockwise.
    public var rotation: Double
    /// Anchor in unit coordinates of the clip's frame; 0.5/0.5 is the centre.
    public var anchorX: Double
    public var anchorY: Double

    public init(
        x: Double = 0, y: Double = 0, scale: Double = 1, rotation: Double = 0, anchorX: Double = 0.5,
        anchorY: Double = 0.5
    ) {
        self.x = x
        self.y = y
        self.scale = scale
        self.rotation = rotation
        self.anchorX = anchorX
        self.anchorY = anchorY
    }

    public static let identity = Transform()
}

public struct Effect: Hashable, Sendable, Codable {
    public var id: EffectID
    public var kind: String
    public var enabled: Bool
    public var params: [String: Animatable<JSONValue>]

    public init(id: EffectID, kind: String, enabled: Bool = true, params: [String: Animatable<JSONValue>] = [:]) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.params = params
    }
}

public struct ClipAudio: Hashable, Sendable, Codable {
    public var gain: Animatable<Double>
    public var muted: Bool
    public var pitchCorrected: Bool

    public init(gain: Animatable<Double> = .constant(1), muted: Bool = false, pitchCorrected: Bool = true) {
        self.gain = gain
        self.muted = muted
        self.pitchCorrected = pitchCorrected
    }
}

public struct CaptionWord: Hashable, Sendable, Codable {
    public var text: String
    /// Source-relative times (the clip's `sourceIn`..`sourceOut` domain).
    public var t0: RationalTime
    public var t1: RationalTime

    public init(text: String, t0: RationalTime, t1: RationalTime) {
        self.text = text
        self.t0 = t0
        self.t1 = t1
    }
}

public struct CaptionStyle: Hashable, Sendable, Codable {
    public var fontFamily: String?
    public var fontSize: Double?
    public var color: String?
    public var backgroundColor: String?
    public var position: String?
    public var extra: [String: JSONValue]

    public init(
        fontFamily: String? = nil, fontSize: Double? = nil, color: String? = nil, backgroundColor: String? = nil,
        position: String? = nil, extra: [String: JSONValue] = [:]
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.color = color
        self.backgroundColor = backgroundColor
        self.position = position
        self.extra = extra
    }
}

/// The caption fields of a clip on a caption track, as one value for events.
public struct CaptionItem: Hashable, Sendable, Codable {
    public var text: String
    public var words: [CaptionWord]
    public var style: CaptionStyle?

    public init(text: String, words: [CaptionWord] = [], style: CaptionStyle? = nil) {
        self.text = text
        self.words = words
        self.style = style
    }
}

public struct Clip: Hashable, Sendable, Codable {
    public var id: ClipID
    public var trackId: TrackID
    /// Nil for generated clips (titles, colour, shapes) and caption items.
    public var assetId: AssetID?
    /// Clips created together from one asset share a group.
    public var linkGroupId: LinkGroupID?
    /// Position on the sequence timeline.
    public var start: RationalTime
    /// Source range; `sourceOut` is exclusive.
    public var sourceIn: RationalTime
    public var sourceOut: RationalTime
    public var speed: Rational
    public var transform: Animatable<Transform>
    public var opacity: Animatable<Double>
    /// Ordered.
    public var effects: [Effect]
    public var audio: ClipAudio
    /// Caption items only.
    public var text: String?
    public var words: [CaptionWord]?
    public var style: CaptionStyle?
    public var label: String?
    public var meta: [String: JSONValue]?

    public init(
        id: ClipID, trackId: TrackID, assetId: AssetID? = nil, linkGroupId: LinkGroupID? = nil, start: RationalTime,
        sourceIn: RationalTime, sourceOut: RationalTime, speed: Rational = .one,
        transform: Animatable<Transform> = .constant(.identity), opacity: Animatable<Double> = .constant(1),
        effects: [Effect] = [], audio: ClipAudio = ClipAudio(), text: String? = nil, words: [CaptionWord]? = nil,
        style: CaptionStyle? = nil, label: String? = nil, meta: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.trackId = trackId
        self.assetId = assetId
        self.linkGroupId = linkGroupId
        self.start = start
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
        self.speed = speed
        self.transform = transform
        self.opacity = opacity
        self.effects = effects
        self.audio = audio
        self.text = text
        self.words = words
        self.style = style
        self.label = label
        self.meta = meta
    }

    /// Source duration, before speed.
    public var sourceDuration: RationalTime { sourceOut - sourceIn }

    /// Timeline duration `(sourceOut - sourceIn) / speed`, rounded to the frame when `frameDuration` is
    /// given (video and caption tracks), exact otherwise (audio tracks).
    public func duration(frameDuration: RationalTime?) -> RationalTime {
        let raw = sourceDuration / speed
        guard let fd = frameDuration else { return raw }
        return raw.snapped(to: fd)
    }

    /// The caption fields as one value, if this is a caption item.
    public var caption: CaptionItem? {
        get {
            guard let text else { return nil }
            return CaptionItem(text: text, words: words ?? [], style: style)
        }
        set {
            text = newValue?.text
            words = newValue?.words
            style = newValue?.style
        }
    }
}

/// Where a clip sits: track and start. Used by `ClipMoved`.
public struct ClipPlacement: Hashable, Sendable, Codable {
    public var trackId: TrackID
    public var start: RationalTime

    public init(trackId: TrackID, start: RationalTime) {
        self.trackId = trackId
        self.start = start
    }
}

/// The three values a trim changes. Used by `ClipTrimmed` and `ClipSplit`.
public struct ClipRange: Hashable, Sendable, Codable {
    public var start: RationalTime
    public var sourceIn: RationalTime
    public var sourceOut: RationalTime

    public init(start: RationalTime, sourceIn: RationalTime, sourceOut: RationalTime) {
        self.start = start
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
    }

    public init(_ clip: Clip) {
        self.init(start: clip.start, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut)
    }
}

// MARK: - Transitions and markers

public enum TransitionAlignment: String, Codable, Hashable, Sendable, CaseIterable {
    case centered
    case startOnCut
    case endOnCut
}

public struct Transition: Hashable, Sendable, Codable {
    public var id: TransitionID
    public var trackId: TrackID
    public var leftClipId: ClipID
    public var rightClipId: ClipID
    public var kind: String
    public var duration: RationalTime
    public var alignment: TransitionAlignment
    public var params: [String: JSONValue]

    public init(
        id: TransitionID, trackId: TrackID, leftClipId: ClipID, rightClipId: ClipID, kind: String,
        duration: RationalTime, alignment: TransitionAlignment = .centered, params: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.trackId = trackId
        self.leftClipId = leftClipId
        self.rightClipId = rightClipId
        self.kind = kind
        self.duration = duration
        self.alignment = alignment
        self.params = params
    }

    /// Timeline handles needed on each side of the cut.
    public var handles: (left: RationalTime, right: RationalTime) {
        switch alignment {
        case .centered: (duration / 2, duration / 2)
        case .startOnCut: (.zero, duration)
        case .endOnCut: (duration, .zero)
        }
    }
}

public struct Marker: Hashable, Sendable, Codable {
    public var id: MarkerID
    public var at: RationalTime
    public var label: String
    public var colour: String?

    public init(id: MarkerID, at: RationalTime, label: String, colour: String? = nil) {
        self.id = id
        self.at = at
        self.label = label
        self.colour = colour
    }
}
