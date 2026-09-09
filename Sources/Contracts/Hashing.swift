import CryptoKit
import Foundation

/// Streamed SHA-256 (`sha256-<64 lowercase hex>`, MediaKit's `ContentHash` form), 8 MiB reads, so
/// RenderKit's receipts, `render_export`, PublishKit's verify stage, and the fakes agree on one form.
public enum FileHash {
    public static let prefix = "sha256-"

    /// Default read size: 8 MiB.
    public static let defaultBufferSize = 8 << 20

    public static func sha256(of url: URL, bufferSize: Int = defaultBufferSize) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty { hasher.update(data: chunk) }
        return format(hasher.finalize())
    }

    public static func sha256(of data: Data) -> String { format(SHA256.hash(data: data)) }

    private static func format(_ digest: SHA256.Digest) -> String {
        prefix + digest.map { String(format: "%02x", $0) }.joined()
    }
}
