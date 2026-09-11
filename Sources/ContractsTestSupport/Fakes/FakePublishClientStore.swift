import Contracts
import Foundation

/// A `PublishClientStore` in memory: `save` and `importJSON` keep whatever they are given, `remove`
/// drops it, and `failNext` makes the next call throw, for the panel's error row. `importJSON` reads
/// nothing from disk — it stores `importedClientId` under the file's name.
public actor FakePublishClientStore: PublishClientStore {
    public nonisolated let destinationPath: String
    public private(set) var client: PublishClient?
    public private(set) var saves: [String] = []
    public private(set) var imports: [URL] = []
    public private(set) var removals = 0
    public private(set) var failNext: PublishClientError?
    /// What `importJSON` pretends the chosen file holds.
    public var importedClientId = "imported.apps.googleusercontent.com"

    public init(client: PublishClient? = nil, destinationPath: String = "/tmp/google-oauth-client.json") {
        self.client = client
        self.destinationPath = destinationPath
    }

    public func current() -> PublishClient? { client }

    @discardableResult
    public func save(clientId: String, clientSecret: String?, audited: Bool) throws -> PublishClient {
        try throwIfArmed()
        saves.append(clientId)
        let client = PublishClient(
            clientId: clientId, hasSecret: !(clientSecret?.isEmpty ?? true), audited: audited,
            source: destinationPath, isEditable: true)
        self.client = client
        return client
    }

    @discardableResult
    public func importJSON(at url: URL) throws -> PublishClient {
        try throwIfArmed()
        imports.append(url)
        let client = PublishClient(
            clientId: importedClientId, hasSecret: true, audited: false, source: destinationPath, isEditable: true)
        self.client = client
        return client
    }

    public func remove() throws {
        try throwIfArmed()
        removals += 1
        client = nil
    }

    /// The next call throws this once.
    public func setFailNext(_ error: PublishClientError?) { failNext = error }

    public func setImportedClientId(_ id: String) { importedClientId = id }

    private func throwIfArmed() throws {
        if let error = failNext {
            failNext = nil
            throw error
        }
    }
}
