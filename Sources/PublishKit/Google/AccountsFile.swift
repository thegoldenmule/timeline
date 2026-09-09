import Contracts
import Foundation
import TimelineCore

/// `accounts.json`: the non-secret account records (publish-plan.md D14), per user and cross project, next
/// to the token file (`<TIMELINE_ROOT>/accounts.json`, else
/// `~/Library/Application Support/Timeline/accounts.json`). Written `0600` and atomically, like the
/// token file, though it never holds a token.
public struct AccountsFile: Sendable, Hashable {
    public static let fileName = "accounts.json"

    public let url: URL

    public init(url: URL) { self.url = url }

    /// `<root or TIMELINE_ROOT>/accounts.json`, else the Application Support file.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment, root: URL? = nil)
        -> URL
    {
        if let root { return root.appendingPathComponent(fileName) }
        if let path = environment["TIMELINE_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent(fileName)
        }
        return GoogleClientConfiguration.applicationSupportDirectory.appendingPathComponent(fileName)
    }

    public func load(fileManager: FileManager = .default) throws -> [ConnectedAccount] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        return try ProjectCodec.decode([ConnectedAccount].self, from: data)
    }

    public func save(_ accounts: [ConnectedAccount], fileManager: FileManager = .default) throws {
        try PrivateFile.write(try ProjectCodec.prettyEncoder.encode(accounts), to: url, fileManager: fileManager)
    }
}
