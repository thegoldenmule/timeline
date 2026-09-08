// Still images for image assets.
import CoreGraphics
import CoreImage
import Foundation

extension TestMedia {
    /// A solid-colour PNG.
    public static func still(
        _ color: Color = .blue, size: CGSize = CGSize(width: 640, height: 480), in directory: URL? = nil,
        name: String? = nil
    ) throws -> Clip {
        let url = try outputURL(in: directory, name: name, defaultName: "still", ext: "png")
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b, colorSpace: srgb) ?? .black)
            .cropped(to: CGRect(origin: .zero, size: size))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let data = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: srgb) else {
            throw Error.imageEncodingFailed
        }
        try data.write(to: url)
        var d = Description(duration: 0, hasVideo: false, hasAudio: false)
        d.size = size
        d.color = color
        return Clip(url: url, description: d)
    }
}
