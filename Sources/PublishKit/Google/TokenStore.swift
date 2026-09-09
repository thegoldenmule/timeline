import Contracts
import Foundation
import Security
import TimelineCore

/// The secret half of a connected account: the refresh token and what it was granted for. Access tokens
/// live in memory only (publish-plan.md D4).
public struct StoredCredential: Sendable, Codable, Hashable {
    public var accountId: String
    public var refreshToken: String
    public var scopes: [String]
    public var clientId: String
    public var grantedAt: Date

    public init(accountId: String, refreshToken: String, scopes: [String], clientId: String, grantedAt: Date) {
        self.accountId = accountId
        self.refreshToken = refreshToken
        self.scopes = scopes
        self.clientId = clientId
        self.grantedAt = grantedAt
    }
}

/// Where refresh tokens live. `KeychainTokenStore` for the signed `.app`, `FileTokenStore` for the
/// unbundled binary and tests; `TokenStoreSelection.resolve` picks one.
public protocol TokenStore: Sendable {
    func load(accountId: String) async throws -> StoredCredential?
    func save(_ credential: StoredCredential) async throws
    func delete(accountId: String) async throws
    func list() async throws -> [StoredCredential]
}

// MARK: - Keychain

/// One generic-password item per account: service `com.thegoldenmule.timeline.google-oauth`, account =
/// the Google `sub`, data = the JSON credential. Uses the data-protection keychain
/// (`kSecUseDataProtectionKeychain`, `AfterFirstUnlockThisDeviceOnly`) and falls back to the legacy
/// file-based keychain when the process lacks the entitlement (`errSecMissingEntitlement`), which is what
/// an unsigned binary gets (docs/research/10-google-account-auth.md section 2, Keychain).
public struct KeychainTokenStore: TokenStore {
    public static let defaultService = "com.thegoldenmule.timeline.google-oauth"

    public let service: String
    /// Try the data-protection keychain first; false goes straight to the legacy keychain.
    public let preferDataProtection: Bool

    public init(service: String = defaultService, preferDataProtection: Bool = true) {
        self.service = service
        self.preferDataProtection = preferDataProtection
    }

    public func load(accountId: String) throws -> StoredCredential? {
        var query = baseQuery(dataProtection: preferDataProtection)
        query[kSecAttrAccount as String] = accountId
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement, preferDataProtection {
            query = baseQuery(dataProtection: false)
            query[kSecAttrAccount as String] = accountId
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try ProjectCodec.decode(StoredCredential.self, from: data)
        case errSecItemNotFound: return nil
        default: throw AccountError.storage(Self.describe(status))
        }
    }

    public func save(_ credential: StoredCredential) throws {
        let data = try ProjectCodec.encode(credential)
        var status = add(credential.accountId, data: data, dataProtection: preferDataProtection)
        if status == errSecMissingEntitlement, preferDataProtection {
            status = add(credential.accountId, data: data, dataProtection: false)
        }
        guard status == errSecSuccess else { throw AccountError.storage(Self.describe(status)) }
    }

    public func delete(accountId: String) throws {
        var query = baseQuery(dataProtection: preferDataProtection)
        query[kSecAttrAccount as String] = accountId
        var status = SecItemDelete(query as CFDictionary)
        if status == errSecMissingEntitlement, preferDataProtection {
            query = baseQuery(dataProtection: false)
            query[kSecAttrAccount as String] = accountId
            status = SecItemDelete(query as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccountError.storage(Self.describe(status))
        }
    }

    public func list() throws -> [StoredCredential] {
        var query = baseQuery(dataProtection: preferDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement, preferDataProtection {
            query = baseQuery(dataProtection: false)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            let items = (result as? [Data]) ?? (result as? Data).map { [$0] } ?? []
            return try items.map { try ProjectCodec.decode(StoredCredential.self, from: $0) }
        case errSecItemNotFound: return []
        default: throw AccountError.storage(Self.describe(status))
        }
    }

    private func add(_ accountId: String, data: Data, dataProtection: Bool) -> OSStatus {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecAttrAccount as String] = accountId
        let update: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return updated }
        guard updated == errSecItemNotFound else { return updated }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Timeline: Google account \(accountId)"
        if dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        return "Keychain: \(message) (\(status))"
    }
}

// MARK: - File

/// A `0600` JSON file of credentials, written atomically; refuses to read a file anyone else can read.
/// For the unbundled binary and for tests (publish-plan.md D4).
public actor FileTokenStore: TokenStore {
    public static let fileName = "google-tokens.json"

    public nonisolated let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load(accountId: String) throws -> StoredCredential? {
        try readAll().first { $0.accountId == accountId }
    }

    public func save(_ credential: StoredCredential) throws {
        var all = try readAll()
        all.removeAll { $0.accountId == credential.accountId }
        all.append(credential)
        try writeAll(all)
    }

    public func delete(accountId: String) throws {
        var all = try readAll()
        all.removeAll { $0.accountId == accountId }
        try writeAll(all)
    }

    public func list() throws -> [StoredCredential] { try readAll() }

    private func readAll() throws -> [StoredCredential] {
        guard let mode = try PrivateFile.mode(of: url, fileManager: fileManager) else { return [] }
        guard !PrivateFile.isReadableByOthers(mode) else {
            throw AccountError.storage(
                "\(url.path) is readable by others (mode \(String(mode, radix: 8))); fix it with chmod 600")
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        return try ProjectCodec.decode([StoredCredential].self, from: data)
    }

    private func writeAll(_ credentials: [StoredCredential]) throws {
        try PrivateFile.write(try ProjectCodec.encode(credentials), to: url, fileManager: fileManager)
    }
}

// MARK: - Selection

/// Which store a process should use (publish-plan.md D4): `TIMELINE_TOKEN_STORE=keychain|file` wins,
/// else an `.app` bundle means the Keychain, else the file at `<TIMELINE_ROOT>/google-tokens.json` or
/// `~/Library/Application Support/Timeline/google-tokens.json`.
public enum TokenStoreSelection: Sendable, Hashable {
    case keychain
    case file(URL)

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment, bundleURL: URL = Bundle.main.bundleURL,
        root: URL? = nil
    ) -> TokenStoreSelection {
        let fileURL = defaultFileURL(environment: environment, root: root)
        switch environment["TIMELINE_TOKEN_STORE"]?.lowercased() {
        case "keychain": return .keychain
        case "file": return .file(fileURL)
        default: return bundleURL.pathExtension == "app" ? .keychain : .file(fileURL)
        }
    }

    /// `<root or TIMELINE_ROOT>/google-tokens.json`, else the Application Support file.
    public static func defaultFileURL(environment: [String: String], root: URL? = nil) -> URL {
        if let root { return root.appendingPathComponent(FileTokenStore.fileName) }
        if let path = environment["TIMELINE_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent(FileTokenStore.fileName)
        }
        return GoogleClientConfiguration.applicationSupportDirectory.appendingPathComponent(FileTokenStore.fileName)
    }

    public func makeStore() -> any TokenStore {
        switch self {
        case .keychain: KeychainTokenStore()
        case .file(let url): FileTokenStore(url: url)
        }
    }
}
