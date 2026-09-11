import Contracts
import Foundation

/// The OAuth client of type "Desktop app" (publish-plan.md D3). Never in the repo: it comes from the
/// environment or from a JSON file the Google Cloud console downloads, looked up in this order:
/// `TIMELINE_GOOGLE_CLIENT_ID` (+ optional `TIMELINE_GOOGLE_CLIENT_SECRET`), else
/// `TIMELINE_GOOGLE_CLIENT_JSON` (a path), else `<TIMELINE_ROOT>/google-oauth-client.json`, else
/// `~/Library/Application Support/Timeline/google-oauth-client.json`. The "secret" of a Desktop client is
/// not confidential but is sent when present to avoid `invalid_client`.
public struct GoogleClientConfiguration: Sendable, Hashable {
    public var clientId: String
    public var clientSecret: String?
    /// True once the Google Cloud project has passed the YouTube compliance audit (D6): public uploads
    /// stay public. From the file's top-level `"audited": true` or `TIMELINE_GOOGLE_AUDITED=1`.
    public var audited: Bool

    public init(clientId: String, clientSecret: String? = nil, audited: Bool = false) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.audited = audited
    }

    public static let fileName = "google-oauth-client.json"

    /// The candidate file locations, in lookup order, for the given environment.
    public static func fileCandidates(
        environment: [String: String], applicationSupport: URL = applicationSupportDirectory
    ) -> [URL] {
        var urls: [URL] = []
        if let path = environment["TIMELINE_GOOGLE_CLIENT_JSON"], !path.isEmpty {
            urls.append(URL(fileURLWithPath: path))
        }
        if let root = environment["TIMELINE_ROOT"], !root.isEmpty {
            urls.append(URL(fileURLWithPath: root).appendingPathComponent(fileName))
        }
        urls.append(applicationSupport.appendingPathComponent(fileName))
        return urls
    }

    /// Where the user should put a client: the sentence `AccountError.notConfigured` carries.
    public static func setupHint(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupport: URL = applicationSupportDirectory
    ) -> String {
        let paths = fileCandidates(environment: environment, applicationSupport: applicationSupport).map(\.path)
            .joined(separator: " or ")
        return "set TIMELINE_GOOGLE_CLIENT_ID (and TIMELINE_GOOGLE_CLIENT_SECRET), or place the console's client JSON "
            + "at \(paths) (see docs/design/publish-setup.md)"
    }

    /// `~/Library/Application Support/Timeline`.
    public static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Timeline", isDirectory: true)
    }

    /// Nil when nothing is configured; throws `PublishKitError.invalidConfiguration` for a file that exists
    /// but cannot be parsed.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default,
        applicationSupport: URL = applicationSupportDirectory
    ) throws -> GoogleClientConfiguration? {
        try resolve(environment: environment, fileManager: fileManager, applicationSupport: applicationSupport)?
            .configuration
    }

    /// Parses the console's `client_secret_*.json` (`{"installed": {...}}` or `{"web": {...}}`) or a flat
    /// `{"client_id", "client_secret", "audited"}` object.
    public static func parse(_ data: Data, source: String = "client JSON") throws -> GoogleClientConfiguration {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PublishKitError.invalidConfiguration("\(source) is not a JSON object")
        }
        let inner = (object["installed"] as? [String: Any]) ?? (object["web"] as? [String: Any]) ?? object
        guard let id = inner["client_id"] as? String, !id.isEmpty else {
            throw PublishKitError.invalidConfiguration("\(source) has no client_id")
        }
        let secret = (inner["client_secret"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let audited = (object["audited"] as? Bool) ?? (inner["audited"] as? Bool) ?? false
        return GoogleClientConfiguration(clientId: id, clientSecret: secret, audited: audited)
    }

    /// Where a loaded client came from, so the UI can say whether it may be replaced.
    public enum Source: Sendable, Hashable {
        /// `TIMELINE_GOOGLE_CLIENT_ID`, which outranks every file.
        case environment
        case file(URL)

        /// The caption the panel shows under the client id.
        public var description: String {
            switch self {
            case .environment: "TIMELINE_GOOGLE_CLIENT_ID (environment)"
            case .file(let url): url.path
            }
        }

        /// False for the environment: a file written under it would never be read.
        public var isEditable: Bool {
            if case .environment = self { return false }
            return true
        }
    }

    /// `load`, plus where the client came from. Nil when nothing is configured.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default,
        applicationSupport: URL = applicationSupportDirectory
    ) throws -> (configuration: GoogleClientConfiguration, source: Source)? {
        let audited = ["1", "true", "yes"].contains((environment["TIMELINE_GOOGLE_AUDITED"] ?? "").lowercased())
        if let id = environment["TIMELINE_GOOGLE_CLIENT_ID"], !id.isEmpty {
            let secret = environment["TIMELINE_GOOGLE_CLIENT_SECRET"].flatMap { $0.isEmpty ? nil : $0 }
            return (GoogleClientConfiguration(clientId: id, clientSecret: secret, audited: audited), .environment)
        }
        for url in fileCandidates(environment: environment, applicationSupport: applicationSupport)
        where fileManager.fileExists(atPath: url.path) {
            var configuration = try parse(Data(contentsOf: url), source: url.path)
            configuration.audited = configuration.audited || audited
            return (configuration, .file(url))
        }
        return nil
    }

    /// What the app writes when the client is typed or imported in the window: the flat form, which
    /// `parse` reads back and a human can read too.
    public func flatJSON() throws -> Data {
        var object: [String: Any] = ["client_id": clientId, "audited": audited]
        if let clientSecret { object["client_secret"] = clientSecret }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// The `PublishClient` the UI shows for this configuration.
    public func publishClient(source: Source) -> PublishClient {
        PublishClient(
            clientId: clientId, hasSecret: clientSecret != nil, audited: audited, source: source.description,
            isEditable: source.isEditable)
    }
}
