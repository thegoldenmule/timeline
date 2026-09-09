import Contracts
import Foundation
import Testing
import TimelineCore

@testable import PublishKit

@Suite struct TokenStoreTests {
    private let credential = StoredCredential(
        accountId: "sub-1", refreshToken: "1//0g-secret", scopes: ["openid"], clientId: "id-1",
        grantedAt: Date(timeIntervalSince1970: 1_788_825_600))

    @Test func fileStoreWritesMode0600AndRoundTrips() async throws {
        let directory = try temporaryDirectory("tokens")
        let url = directory.appendingPathComponent("nested/google-tokens.json")
        let store = FileTokenStore(url: url)
        #expect(try await store.load(accountId: "sub-1") == nil)
        #expect(try await store.list().isEmpty)
        try await store.save(credential)
        let mode = try #require(try PrivateFile.mode(of: url))
        #expect(mode & 0o777 == 0o600)
        #expect(try await store.load(accountId: "sub-1") == credential)
        var second = credential
        second.accountId = "sub-2"
        try await store.save(second)
        #expect(try await store.list().map(\.accountId) == ["sub-1", "sub-2"])
        var updated = credential
        updated.refreshToken = "1//0g-rotated"
        try await store.save(updated)
        #expect(try await store.load(accountId: "sub-1")?.refreshToken == "1//0g-rotated")
        try await store.delete(accountId: "sub-1")
        #expect(try await store.load(accountId: "sub-1") == nil)
        #expect(try await FileTokenStore(url: url).list().map(\.accountId) == ["sub-2"])
        #expect(try PrivateFile.mode(of: url).map { $0 & 0o777 } == 0o600)
        // No temporary file is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == ["google-tokens.json"])
    }

    @Test func fileStoreRefusesAWorldReadableFile() async throws {
        let directory = try temporaryDirectory("tokens-mode")
        let url = directory.appendingPathComponent("google-tokens.json")
        let store = FileTokenStore(url: url)
        try await store.save(credential)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        do {
            _ = try await store.load(accountId: "sub-1")
            Issue.record("expected a storage error")
        } catch AccountError.storage(let detail) {
            #expect(detail.contains("readable by others") && detail.contains("644"))
        }
        await #expect(throws: AccountError.self) { _ = try await store.list() }
        await #expect(throws: AccountError.self) { try await store.save(credential) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try await store.load(accountId: "sub-1") == credential)
    }

    @Test func selectionPrefersTheEnvironmentThenTheBundle() throws {
        let bundle = URL(fileURLWithPath: "/Applications/Timeline.app")
        let binary = URL(fileURLWithPath: "/tmp/.build/debug/TimelineApp")
        let root = URL(fileURLWithPath: "/tmp/root")
        #expect(
            TokenStoreSelection.resolve(environment: ["TIMELINE_TOKEN_STORE": "file"], bundleURL: bundle) != .keychain)
        #expect(
            TokenStoreSelection.resolve(environment: ["TIMELINE_TOKEN_STORE": "keychain"], bundleURL: binary)
                == .keychain)
        #expect(TokenStoreSelection.resolve(environment: [:], bundleURL: bundle) == .keychain)
        #expect(
            TokenStoreSelection.resolve(environment: [:], bundleURL: binary, root: root)
                == .file(root.appendingPathComponent("google-tokens.json")))
        #expect(
            TokenStoreSelection.resolve(environment: ["TIMELINE_ROOT": "/tmp/env-root"], bundleURL: binary)
                == .file(URL(fileURLWithPath: "/tmp/env-root").appendingPathComponent("google-tokens.json")))
        let fallback = TokenStoreSelection.resolve(environment: [:], bundleURL: binary)
        guard case .file(let url) = fallback else {
            Issue.record("expected the file store")
            return
        }
        #expect(url.path.hasSuffix("Library/Application Support/Timeline/google-tokens.json"))
        #expect(url.path.contains("/Cache/") == false)
        #expect(TokenStoreSelection.keychain.makeStore() is KeychainTokenStore)
        #expect(fallback.makeStore() is FileTokenStore)
    }

    /// The Keychain cannot be exercised the way a bundled app does from an unsigned test binary (the
    /// data-protection keychain needs an entitlement; the legacy keychain may prompt), so this runs only
    /// on request, against the legacy keychain under a unique service name that it deletes afterwards.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TIMELINE_KEYCHAIN_TESTS"] == "1"))
    func keychainStoreRoundTrips() throws {
        let store = KeychainTokenStore(
            service: "com.thegoldenmule.timeline.tests.\(UUID().uuidString)", preferDataProtection: false)
        defer { try? store.delete(accountId: "sub-1") }
        #expect(try store.load(accountId: "sub-1") == nil)
        try store.save(credential)
        #expect(try store.load(accountId: "sub-1") == credential)
        var rotated = credential
        rotated.refreshToken = "1//0g-rotated"
        try store.save(rotated)
        #expect(try store.load(accountId: "sub-1")?.refreshToken == "1//0g-rotated")
        #expect(try store.list().map(\.accountId) == ["sub-1"])
        try store.delete(accountId: "sub-1")
        #expect(try store.load(accountId: "sub-1") == nil)
        try store.delete(accountId: "sub-1")
    }
}
