// PublishKit: Google account connection and YouTube publishing. See docs/design/publish-plan.md.
//
// `GoogleAccountProvider` (OAuth 2.0 with PKCE, a loopback redirect opened by an injected
// `AuthorizationPresenter`, a Keychain or 0600-file token store) implements `Contracts.AccountProvider`;
// `YouTubePublisher` (resumable chunked upload with resume, processing poll, thumbnail, captions,
// playlist) implements `Contracts.Publisher`. Everything talks to Google's real URLs through an injected
// `URLSession`, so tests hand in `FakeYouTubeServer.sessionConfiguration()`.
import Foundation

/// Errors PublishKit raises before a `Contracts` error applies: a malformed client file, a response the
/// module cannot decode.
public enum PublishKitError: Error, Hashable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): "Invalid Google client configuration: \(detail)"
        case .decoding(let detail): "Could not decode a response: \(detail)"
        }
    }
}

/// RFC 4648 section 5 base64url without padding, the form PKCE and JWTs use.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

extension Date {
    /// Truncated to whole milliseconds, the precision `ProjectCodec` stores, so a record kept in memory
    /// equals the one read back from `accounts.json`.
    var millisecondPrecision: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }
}

/// Date forms the Google APIs use: RFC 3339 with milliseconds (`status.publishAt`,
/// `recordingDetails.recordingDate`).
enum GoogleDates {
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func format(_ date: Date) -> String { style.format(date) }

    static func parse(_ string: String) -> Date? {
        (try? style.parse(string)) ?? (try? Date.ISO8601FormatStyle().parse(string))
    }
}

/// `application/x-www-form-urlencoded` bodies for the token and revoke endpoints.
enum FormEncoding {
    static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ fields: [(String, String)]) -> Data {
        Data(
            fields.map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }.joined(separator: "&").utf8)
    }
}

/// Writes a file only its owner can read: `0600`, atomic replace, parent directories created.
enum PrivateFile {
    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path]) }
        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The POSIX mode of an existing file, or nil when it does not exist.
    static func mode(of url: URL, fileManager: FileManager = .default) throws -> Int? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    /// True when anyone but the owner may read the file.
    static func isReadableByOthers(_ mode: Int) -> Bool { mode & 0o077 != 0 }
}
