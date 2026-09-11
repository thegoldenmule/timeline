import CoreGraphics
import Foundation
import TimelineCore

/// How big a poster picture has to be to fill the box a row draws it in.
public enum PosterGeometry {
    /// The narrowest picture a poster box is expected to hold — a phone's portrait video. Used when
    /// the shape of the media is not known, so the box is covered whatever turns up.
    public static let narrowestAspect: CGFloat = 9.0 / 16.0

    /// The height, in pixels, that covers `box` under `.fill` without the picture being blown up.
    ///
    /// `.fill` scales a picture until it covers *both* sides of the box, so the binding constraint for
    /// anything narrower than the box is the width, not the height. A 9:16 frame scaled to a 64x36 pt
    /// box's height is 20 pt wide — under a third of the box — and `.fill` then magnifies it three
    /// times over. Asking by the box's height alone is what made every portrait clip soft.
    public static func pixelHeight(box: CGSize, aspect: CGFloat?, displayScale: CGFloat) -> Int {
        let shape = max(aspect ?? narrowestAspect, 0.01)
        let needed = max(box.height, box.width / shape)
        return Int((needed * max(1, displayScale)).rounded())
    }
}

extension Asset {
    /// The shape the picture has once it is the right way up. `AVAssetImageGenerator` applies the
    /// track's preferred transform, so a clip shot on a phone held upright draws as 1080x1920 however
    /// its stored dimensions and rotation describe it.
    public var displayAspectRatio: CGFloat? {
        guard let width = probe.width, let height = probe.height, width > 0, height > 0 else { return nil }
        let turn = ((probe.rotation ?? 0) % 360 + 360) % 360
        let upright = turn == 90 || turn == 270
        return upright
            ? CGFloat(height) / CGFloat(width)
            : CGFloat(width) / CGFloat(height)
    }
}
