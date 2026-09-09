import Contracts
import Foundation

/// The local checks of `Publisher.validate` (docs/research/11-youtube-upload.md section 3, section 5,
/// section 8), as pure functions: hard violations throw `PublishError.invalidRequest`, everything else
/// is a warning string. Never alters the request (developer policy III.C.3).
public enum YouTubeValidation {
    public static let titleMaxCharacters = 100
    public static let descriptionMaxBytes = 5000
    public static let tagsMaxCharacters = 500
    public static let captionNameMaxCharacters = 150
    public static let thumbnailMaxBytes = 2 << 20
    /// Square or vertical up to three minutes is a Short.
    public static let shortMaxSeconds = 180.0
    /// Over 15 minutes needs a phone-verified channel.
    public static let verifiedChannelSeconds = 900.0

    /// Every rule; returns the warnings.
    public static func validate(_ request: PublishRequest, fileManager: FileManager = .default) throws -> [String] {
        try checkTitle(request.title)
        try checkDescription(request.description)
        try checkTags(request.tags)
        try checkPublishAt(request.publishAt, privacy: request.privacy)
        try checkCategory(request.categoryId)
        for track in request.captions { try checkCaption(track) }
        try checkThumbnail(request.thumbnail, fileManager: fileManager)
        guard fileManager.fileExists(atPath: request.fileURL.path) else {
            throw PublishError.fileMissing(request.fileURL)
        }
        return shapeWarnings(width: request.width, height: request.height, durationSeconds: request.durationSeconds)
            + durationWarnings(durationSeconds: request.durationSeconds)
    }

    // MARK: Hard rules

    /// 1 to 100 characters, no `<` or `>`.
    public static func checkTitle(_ title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PublishError.invalidRequest("title is empty") }
        guard title.count <= titleMaxCharacters else {
            throw PublishError.invalidRequest(
                "title is \(title.count) characters; YouTube allows \(titleMaxCharacters)")
        }
        guard !title.contains("<"), !title.contains(">") else {
            throw PublishError.invalidRequest("title may not contain < or >")
        }
    }

    /// At most 5,000 bytes of UTF-8 (emoji and CJK count 3 to 4 each), no `<` or `>`.
    public static func checkDescription(_ description: String) throws {
        let bytes = description.utf8.count
        guard bytes <= descriptionMaxBytes else {
            throw PublishError.invalidRequest("description is \(bytes) bytes; YouTube allows \(descriptionMaxBytes)")
        }
        guard !description.contains("<"), !description.contains(">") else {
            throw PublishError.invalidRequest("description may not contain < or >")
        }
    }

    /// At most 500 characters counting a comma between tags and quotes around a tag with a space.
    public static func checkTags(_ tags: [String]) throws {
        let length = tagsLength(tags)
        guard length <= tagsMaxCharacters else {
            throw PublishError.invalidRequest("tags total \(length) characters; YouTube allows \(tagsMaxCharacters)")
        }
    }

    /// The length YouTube charges: tag characters, plus 2 for each tag containing a space (its quotes),
    /// plus one comma between tags.
    public static func tagsLength(_ tags: [String]) -> Int {
        guard !tags.isEmpty else { return 0 }
        let characters = tags.reduce(0) { $0 + $1.count + ($1.contains(" ") ? 2 : 0) }
        return characters + tags.count - 1
    }

    /// `publishAt` needs `private`.
    public static func checkPublishAt(_ publishAt: Date?, privacy: PublishPrivacy) throws {
        if publishAt != nil, privacy != .private {
            throw PublishError.invalidRequest("publishAt requires privacy private (requested \(privacy.rawValue))")
        }
    }

    /// A category id is a non-empty string of digits.
    public static func checkCategory(_ categoryId: String?) throws {
        guard let categoryId else { return }
        guard !categoryId.isEmpty, categoryId.allSatisfy(\.isNumber) else {
            throw PublishError.invalidRequest("categoryId must be a numeric id, not \"\(categoryId)\"")
        }
    }

    /// Name at most 150 characters, language non-empty.
    public static func checkCaption(_ track: PublishCaptionTrack) throws {
        guard !track.language.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PublishError.invalidRequest("caption track \"\(track.name)\" has no language")
        }
        guard track.name.count <= captionNameMaxCharacters else {
            throw PublishError.invalidRequest(
                "caption track name is \(track.name.count) characters; YouTube allows \(captionNameMaxCharacters)")
        }
    }

    /// Exists, at most 2 MB, JPEG or PNG by content.
    public static func checkThumbnail(_ thumbnail: PublishThumbnail?, fileManager: FileManager = .default) throws {
        guard let thumbnail else { return }
        guard let attributes = try? fileManager.attributesOfItem(atPath: thumbnail.fileURL.path),
            let size = (attributes[.size] as? NSNumber)?.intValue
        else { throw PublishError.invalidRequest("thumbnail file is missing: \(thumbnail.fileURL.path)") }
        guard size <= thumbnailMaxBytes else {
            throw PublishError.invalidRequest("thumbnail is \(size) bytes; YouTube allows \(thumbnailMaxBytes)")
        }
        guard thumbnailContentType(of: thumbnail.fileURL) != nil else {
            throw PublishError.invalidRequest("thumbnail must be a JPEG or PNG")
        }
    }

    /// `image/jpeg` or `image/png` from the file's magic bytes, nil for anything else.
    public static func thumbnailContentType(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 8) else {
            return nil
        }
        try? handle.close()
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        return nil
    }

    // MARK: Warnings

    /// Shorts are classified by shape and length (publish-plan.md D8).
    public static func shapeWarnings(width: Int?, height: Int?, durationSeconds: Double?) -> [String] {
        guard let width, let height, width > 0, height > 0 else { return [] }
        let portrait = height > width
        let squareOrVertical = height >= width
        guard let durationSeconds else { return [] }
        if portrait, durationSeconds > shortMaxSeconds {
            return [
                "Portrait export longer than 3:00: YouTube will show it as a long-form video with a vertical frame, not as a Short"
            ]
        }
        if squareOrVertical, durationSeconds <= shortMaxSeconds {
            return ["Square or vertical export up to 3:00: YouTube will classify it as a Short"]
        }
        return []
    }

    public static func durationWarnings(durationSeconds: Double?) -> [String] {
        guard let durationSeconds, durationSeconds > verifiedChannelSeconds else { return [] }
        return [
            "Longer than 15 minutes: the channel must be phone-verified (youtube.com/verify) or YouTube rejects it with reason length"
        ]
    }
}
