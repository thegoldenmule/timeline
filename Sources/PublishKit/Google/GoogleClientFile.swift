import Contracts
import Foundation

/// The `PublishClientStore` behind Settings and the Publishes panel: reads whichever client
/// `GoogleClientConfiguration.resolve` finds, and writes the flat form to the first of the file
/// candidates (`TIMELINE_GOOGLE_CLIENT_JSON`, then `<TIMELINE_ROOT>/`, then Application Support) with
/// mode 0600. A client set through `TIMELINE_GOOGLE_CLIENT_ID` outranks every file, so `save` refuses
/// with `notEditable` rather than writing something the app would then ignore.
public actor GoogleClientFile: PublishClientStore {
    private let environment: [String: String]
    private let applicationSupport: URL
    private let fileManager: FileManager

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupport: URL = GoogleClientConfiguration.applicationSupportDirectory,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.applicationSupport = applicationSupport
        self.fileManager = fileManager
    }

    /// Where `save` and `importJSON` write.
    public nonisolated var destinationURL: URL {
        GoogleClientConfiguration.fileCandidates(environment: environment, applicationSupport: applicationSupport)[0]
    }

    public nonisolated var destinationPath: String { destinationURL.path }

    /// True while `TIMELINE_GOOGLE_CLIENT_ID` is set: nothing this store writes would be read.
    public nonisolated var isEnvironmentOverridden: Bool {
        !(environment["TIMELINE_GOOGLE_CLIENT_ID"] ?? "").isEmpty
    }

    // MARK: PublishClientStore

    public func current() -> PublishClient? {
        guard let resolved = resolved() else { return nil }
        return resolved.configuration.publishClient(source: resolved.source)
    }

    /// The configuration itself, for the app's `PublishingServices`.
    public func configuration() -> GoogleClientConfiguration? { resolved()?.configuration }

    @discardableResult
    public func save(clientId: String, clientSecret: String?, audited: Bool) throws -> PublishClient {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw PublishClientError.invalid("Enter the client id from the Cloud console") }
        guard id.contains(".apps.googleusercontent.com") else {
            throw PublishClientError.invalid(
                "That does not look like a Google client id; it ends in .apps.googleusercontent.com")
        }
        let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try write(
            GoogleClientConfiguration(
                clientId: id, clientSecret: (secret?.isEmpty ?? true) ? nil : secret, audited: audited))
    }

    @discardableResult
    public func importJSON(at url: URL) throws -> PublishClient {
        // A file the user picked in an open panel: read it through the security scope when there is one,
        // which is what an App Sandbox build will need and an unsandboxed one ignores.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PublishClientError.storage(
                "\(url.lastPathComponent) could not be read: \(error.localizedDescription)")
        }
        let configuration: GoogleClientConfiguration
        do {
            configuration = try GoogleClientConfiguration.parse(data, source: url.lastPathComponent)
        } catch let error as PublishKitError {
            throw PublishClientError.invalid(error.localizedDescription)
        }
        return try write(configuration)
    }

    public func remove() throws {
        guard !isEnvironmentOverridden else { throw PublishClientError.notEditable(Self.environmentNote) }
        for url in GoogleClientConfiguration.fileCandidates(
            environment: environment, applicationSupport: applicationSupport)
        where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw PublishClientError.storage("\(url.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: -

    /// What the panel says when the environment holds the client.
    public static let environmentNote =
        "TIMELINE_GOOGLE_CLIENT_ID sets the client for this process; unset it to manage the client here"

    private func resolved() -> (configuration: GoogleClientConfiguration, source: GoogleClientConfiguration.Source)? {
        try? GoogleClientConfiguration.resolve(
            environment: environment, fileManager: fileManager, applicationSupport: applicationSupport)
    }

    private func write(_ configuration: GoogleClientConfiguration) throws -> PublishClient {
        guard !isEnvironmentOverridden else { throw PublishClientError.notEditable(Self.environmentNote) }
        let url = destinationURL
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try configuration.flatJSON().write(to: url, options: [.atomic])
            // Atomic writes land as a fresh file, so the mode goes on afterwards: the client secret is not
            // confidential, but the file sits next to the token store and should read the same way.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw PublishClientError.storage("\(url.path): \(error.localizedDescription)")
        }
        return configuration.publishClient(source: .file(url))
    }
}
