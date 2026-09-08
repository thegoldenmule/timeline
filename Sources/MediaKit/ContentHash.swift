import Contracts
import CryptoKit
import Foundation

/// SHA-256 over the whole file, streamed in 8 MiB chunks (storage.md section 2). Runs wherever it is awaited
/// from, never on the main actor; yields between chunks so a long hash does not pin a cooperative thread, and
/// checks cancellation per chunk.
public enum ContentHash {
    public static let chunkSize = 8 << 20
    public static let prefix = "sha256-"

    /// `sha256-<64 hex digits>`.
    public static func sha256(of url: URL, progress: (@Sendable (_ bytesHashed: Int64) -> Void)? = nil)
        async throws -> String
    {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw MediaError.notFound(url) }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data: Data?
            do {
                data = try handle.read(upToCount: chunkSize)
            } catch {
                throw MediaError.unreadable(url, reason: error.localizedDescription)
            }
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
            total += Int64(data.count)
            progress?(total)
            await Task.yield()
        }
        return prefix + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of data: Data) -> String {
        prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// `(volume UUID, APFS file id, size, mtime)`: the hint `cache.sqlite` keeps so an already-indexed file is
/// recognised without re-hashing. A hint, never an identity across volumes (storage.md section 2).
public struct FileIdentity: Hashable, Sendable, Codable {
    public var volumeUUID: String
    public var fileID: Int64
    public var size: Int64
    public var modified: Date

    public init(volumeUUID: String, fileID: Int64, size: Int64, modified: Date) {
        self.volumeUUID = volumeUUID
        self.fileID = fileID
        self.size = size
        self.modified = modified
    }

    /// Reads the identity from disk; throws `MediaError.notFound` when the file is missing.
    public init(of url: URL) throws {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys),
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { throw MediaError.notFound(url) }
        volumeUUID = values.volumeUUIDString ?? "no-uuid"
        fileID = Int64(
            (attributes[.systemFileNumber] as? UInt64)
                ?? UInt64(truncatingIfNeeded: (attributes[.systemFileNumber] as? Int) ?? 0))
        size = Int64(values.fileSize ?? ((attributes[.size] as? Int) ?? 0))
        modified =
            values.contentModificationDate ?? (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
    }

    /// The modification time as the cache stores it (ISO-8601 with milliseconds), so equality is stable.
    var modifiedKey: String { Timestamps.string(modified) }
}
