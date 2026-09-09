import AVFoundation
import Contracts
import CoreGraphics
import CoreMedia
import Foundation
import TimelineCore

// The instruction table: what the compositor draws at every time. Built by `SequenceCompiler`, carried by
// `RenderPayload`, handed to AVFoundation as `AVVideoComposition.Configuration.instructions`.

/// What a layer's pixels come from.
public enum LayerContent: Sendable, Hashable {
    /// Frames from a composition track (`request.sourceFrame(byTrackID:)`).
    case source(trackID: CMPersistentTrackID)
    /// An offline asset: the compositor draws a slate with this label.
    case slate(label: String)
    /// An image asset drawn from disk (cached in the compositor).
    case still(URL)
    /// A generated clip (title, colour): solid black until generators exist.
    case generated
}

/// One clip's contribution to a frame, in sequence coordinates. Everything the compositor needs is here so
/// `startRequest` never looks anything up.
public struct LayerSpec: Sendable {
    public var clipId: ClipID
    /// Index of the model track (0 is the bottom video layer).
    public var trackIndex: Int
    public var content: LayerContent
    /// The source track's display matrix (top-left coordinates) and the sizes on both sides of it.
    public var sourceTransform: CGAffineTransform
    public var naturalSize: CGSize
    public var displaySize: CGSize
    /// Timeline start of the clip (`Animatable` keyframes are relative to it).
    public var clipStart: CMTime
    public var transform: Animatable<Transform>
    public var opacity: Animatable<Double>
    public var effects: [Effect]
    /// True when this layer is hidden (muted track): kept in the table so the fingerprints stay structural-only.
    public var hidden: Bool

    public init(
        clipId: ClipID, trackIndex: Int, content: LayerContent, sourceTransform: CGAffineTransform = .identity,
        naturalSize: CGSize = .zero, displaySize: CGSize = .zero, clipStart: CMTime, transform: Animatable<Transform>,
        opacity: Animatable<Double>, effects: [Effect] = [], hidden: Bool = false
    ) {
        self.clipId = clipId
        self.trackIndex = trackIndex
        self.content = content
        self.sourceTransform = sourceTransform
        self.naturalSize = naturalSize
        self.displaySize = displaySize
        self.clipStart = clipStart
        self.transform = transform
        self.opacity = opacity
        self.effects = effects
        self.hidden = hidden
    }

    public var sourceTrackID: CMPersistentTrackID? {
        if case .source(let id) = content { return id }
        return nil
    }
}

/// A transition realized over an overlap: `from` is the left clip's layer, `to` the right clip's.
public struct TransitionSpec: Sendable {
    public var transitionId: TransitionID
    public var trackIndex: Int
    public var kind: String
    public var params: [String: JSONValue]
    /// The whole overlap, which may span several instructions.
    public var overlap: CMTimeRange
    public var fromClip: ClipID
    public var toClip: ClipID

    public init(
        transitionId: TransitionID, trackIndex: Int, kind: String, params: [String: JSONValue], overlap: CMTimeRange,
        fromClip: ClipID, toClip: ClipID
    ) {
        self.transitionId = transitionId
        self.trackIndex = trackIndex
        self.kind = kind
        self.params = params
        self.overlap = overlap
        self.fromClip = fromClip
        self.toClip = toClip
    }

    /// 0 at the overlap start, 1 at its end.
    public func progress(at time: CMTime) -> Double {
        let d = overlap.duration.seconds
        guard d > 0 else { return 1 }
        return min(1, max(0, (time - overlap.start).seconds / d))
    }
}

/// A caption item with its word timing resolved to timeline times.
public struct CaptionSpec: Sendable {
    public struct Word: Sendable {
        public var text: String
        public var range: CMTimeRange
        public init(text: String, range: CMTimeRange) {
            self.text = text
            self.range = range
        }
    }

    public var clipId: ClipID
    public var text: String
    public var words: [Word]
    public var style: CaptionStyle
    public var timeRange: CMTimeRange

    public init(clipId: ClipID, text: String, words: [Word], style: CaptionStyle, timeRange: CMTimeRange) {
        self.clipId = clipId
        self.text = text
        self.words = words
        self.style = style
        self.timeRange = timeRange
    }

    /// Index of the word being spoken at `time`, if any.
    public func activeWord(at time: CMTime) -> Int? {
        // Words are few and sorted; a linear scan is cheaper than the bookkeeping of a binary search here.
        words.firstIndex { $0.range.containsTime(time) }
    }
}

/// One entry of the instruction table. Immutable; AVFoundation holds these across isolation domains.
public final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening: Bool
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    /// Bottom to top. During a transition both of the track's clips are here, adjacent, left clip first.
    public let layers: [LayerSpec]
    /// Keyed by model track index.
    public let transitions: [Int: TransitionSpec]
    public let captions: [CaptionSpec]
    public let blendSpace: BlendSpace
    public let hdr: Bool
    public let sequenceSize: CGSize
    /// The `Compiled` this table belongs to; compositors record the ids they served, for diagnostics.
    public let compiledId: CompiledID

    public init(
        timeRange: CMTimeRange, layers: [LayerSpec], transitions: [Int: TransitionSpec], captions: [CaptionSpec],
        blendSpace: BlendSpace, hdr: Bool, sequenceSize: CGSize, compiledId: CompiledID = "unassigned"
    ) {
        self.timeRange = timeRange
        self.layers = layers
        self.transitions = transitions
        self.captions = captions
        self.blendSpace = blendSpace
        self.hdr = hdr
        self.sequenceSize = sequenceSize
        self.compiledId = compiledId
        var ids: [CMPersistentTrackID] = []
        for layer in layers {
            if let id = layer.sourceTrackID, !ids.contains(id) { ids.append(id) }
        }
        requiredSourceTrackIDs = ids.map { NSNumber(value: $0) }
        let animated = layers.contains { layer in
            if case .keyframes = layer.transform { return true }
            if case .keyframes = layer.opacity { return true }
            return false
        }
        containsTweening = !transitions.isEmpty || !captions.isEmpty || animated
        super.init()
    }

    public var sourceTrackIDs: [CMPersistentTrackID] {
        (requiredSourceTrackIDs ?? []).map { CMPersistentTrackID(truncating: $0 as! NSNumber) }
    }
}

/// The instruction table with O(log n) lookup by time. AVFoundation does its own lookup before `startRequest`;
/// this is for everything else that asks "what is on screen at t" (the inspector, tests, the preview player).
public struct InstructionTable: Sendable {
    public let instructions: [RenderInstruction]
    private let starts: [CMTime]

    public init(_ instructions: [RenderInstruction]) {
        self.instructions = instructions
        starts = instructions.map(\.timeRange.start)
    }

    public var count: Int { instructions.count }
    public var isEmpty: Bool { instructions.isEmpty }
    public var duration: CMTime { instructions.last?.timeRange.end ?? .zero }

    /// The instruction whose half-open range contains `time`; the last one for `time == duration`.
    public func instruction(at time: CMTime) -> RenderInstruction? {
        guard !instructions.isEmpty else { return nil }
        // Binary search for the last start <= time.
        var lo = 0
        var hi = instructions.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        let index = lo - 1
        guard index >= 0 else { return nil }
        let candidate = instructions[index]
        guard time < candidate.timeRange.end || (index == instructions.count - 1 && time == candidate.timeRange.end)
        else { return nil }
        return candidate
    }

    /// Every instruction overlapping `range`.
    public func instructions(in range: CMTimeRange) -> ArraySlice<RenderInstruction> {
        guard !instructions.isEmpty else { return [] }
        var lo = 0
        var hi = instructions.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if instructions[mid].timeRange.end <= range.start { lo = mid + 1 } else { hi = mid }
        }
        let first = lo
        var last = first
        while last < instructions.count, instructions[last].timeRange.start < range.end { last += 1 }
        return instructions[first..<last]
    }
}
