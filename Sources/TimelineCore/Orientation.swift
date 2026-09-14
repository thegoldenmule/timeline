import Foundation

// MARK: - Display size and orientation

/// Which way round a frame is. Derived from a size; never stored.
public enum Orientation: String, Sendable, Hashable, Codable, CaseIterable {
    case portrait
    case landscape
    case square
}

/// A frame size in pixels, as it is *displayed*: a `Probe`'s encoded size with its display matrix
/// already applied, or a sequence's own frame. Purely derived, so it is safe to compute anywhere.
public struct FrameSize: Hashable, Sendable, Codable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var orientation: Orientation {
        if width > height { return .landscape }
        if width < height { return .portrait }
        return .square
    }

    /// Width divided by height, or 0 for a degenerate frame.
    public var aspectRatio: Double { height > 0 ? Double(width) / Double(height) : 0 }

    /// The aspect as a reduced integer ratio, e.g. "16:9", "9:16", "1:1". "0:0" for a degenerate frame.
    public var aspectLabel: String {
        let divisor = FrameSize.gcd(abs(width), abs(height))
        guard divisor > 0 else { return "\(width):\(height)" }
        return "\(width / divisor):\(height / divisor)"
    }

    /// "1920x1080", the spelling the tools and the UI both use.
    public var description: String { "\(width)x\(height)" }

    /// The axes swapped: the same frame stood on its end.
    public var transposed: FrameSize { FrameSize(width: height, height: width) }

    /// True when the two frames have the same shape, so one fills the other with no bars.
    /// Compared as integers (`w1 * h2 == w2 * h1`) to keep it exact.
    public func fills(_ other: FrameSize) -> Bool {
        guard width > 0, height > 0, other.width > 0, other.height > 0 else { return false }
        return width * other.height == other.width * height
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}

extension Probe {
    /// True when the display matrix stands the encoded frame on its end (±90°, ±270°).
    ///
    /// `rotation` is in degrees, counter-clockwise positive (the ffmpeg display-matrix convention
    /// `MediaProbe.rotationDegrees` writes): a clip shot in portrait on an iPhone probes as *landscape*
    /// 3840x2160 with `rotation == -90`. A nil or unrecognised rotation is treated as upright.
    public var swapsDisplayAxes: Bool {
        guard let rotation else { return false }
        return abs(rotation) % 180 == 90
    }

    /// The encoded size with the display matrix applied: axes swapped at ±90°.
    ///
    /// Nil when the probe carries no usable size (audio, or a file that failed to inspect). This is the
    /// only correct way to ask how a clip is framed — `width`/`height` alone answer it backwards for
    /// every rotated phone clip.
    public var displaySize: FrameSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let size = FrameSize(width: width, height: height)
        return swapsDisplayAxes ? size.transposed : size
    }

    /// The encoded size as probed, with no rotation applied. Report it, never frame from it.
    public var encodedSize: FrameSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return FrameSize(width: width, height: height)
    }

    /// Which way round the clip is once displayed. Nil when the probe carries no usable size.
    public var orientation: Orientation? { displaySize?.orientation }
}

extension SequenceSettings {
    /// The frame these settings describe. Settings carry the same width and height a sequence does.
    public var frameSize: FrameSize { FrameSize(width: width, height: height) }

    public var orientation: Orientation { frameSize.orientation }
}

extension Sequence {
    /// The sequence's own frame. Sequence sizes are stored as displayed, so no rotation is involved.
    public var frameSize: FrameSize { FrameSize(width: width, height: height) }

    public var orientation: Orientation { frameSize.orientation }

    /// The aspect as a reduced integer ratio, e.g. "16:9".
    public var aspectLabel: String { frameSize.aspectLabel }
}

extension Asset {
    /// The asset's display size, when it is visual and its probe carries a usable one. Audio probes
    /// carry no size, and a still image is framed exactly like a video clip, so this is simply the
    /// probe's own answer.
    public var displaySize: FrameSize? { probe.displaySize }

    public var orientation: Orientation? { displaySize?.orientation }
}
