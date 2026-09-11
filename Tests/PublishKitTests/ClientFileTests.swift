import Contracts
import ContractsTestSupport
import Foundation
import Testing

@testable import PublishKit

/// `GoogleClientFile`: the store behind the Publishes panel's client card.
@Suite("Google client file")
struct ClientFileTests {
    /// A store over a temporary directory, reached as `TIMELINE_ROOT` so nothing touches the real
    /// Application Support directory.
    private func store(_ label: String, environment extra: [String: String] = [:]) throws -> (
        GoogleClientFile, URL
    ) {
        let directory = try temporaryDirectory(label)
        var environment = ["TIMELINE_ROOT": directory.path]
        environment.merge(extra) { _, new in new }
        return (
            GoogleClientFile(environment: environment, applicationSupport: directory.appendingPathComponent("unused")),
            directory
        )
    }

    @Test func savesTheTypedClientAndReadsItBack() async throws {
        let (store, directory) = try store("save")
        #expect(await store.current() == nil)
        let file = directory.appendingPathComponent("google-oauth-client.json")
        #expect(store.destinationPath == file.path)

        let saved = try await store.save(
            clientId: "  123-abc.apps.googleusercontent.com  ", clientSecret: " secret ", audited: false)
        #expect(saved.clientId == "123-abc.apps.googleusercontent.com")
        #expect(saved.hasSecret)
        #expect(saved.isEditable)
        #expect(saved.source == file.path)
        // Readable by the loader every other surface uses, and written the way the token file is.
        let loaded = try #require(
            try GoogleClientConfiguration.load(
                environment: ["TIMELINE_ROOT": directory.path], applicationSupport: directory))
        #expect(
            loaded == GoogleClientConfiguration(clientId: "123-abc.apps.googleusercontent.com", clientSecret: "secret"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)

        try await store.remove()
        #expect(await store.current() == nil)
    }

    @Test func rejectsSomethingThatIsNotAClientId() async throws {
        let (store, _) = try store("invalid")
        await #expect(throws: PublishClientError.self) {
            try await store.save(clientId: " ", clientSecret: nil, audited: false)
        }
        do {
            _ = try await store.save(clientId: "my-client", clientSecret: nil, audited: false)
            Issue.record("expected invalid")
        } catch let error as PublishClientError {
            #expect(error.message.contains("apps.googleusercontent.com"))
        }
        #expect(await store.current() == nil)
    }

    @Test func importsTheConsoleDownload() async throws {
        let (store, directory) = try store("import")
        let download = directory.appendingPathComponent("client_secret_123.json")
        try Data(
            #"{"installed":{"client_id":"123-abc.apps.googleusercontent.com","client_secret":"sec","redirect_uris":["http://localhost"]}}"#
                .utf8
        ).write(to: download)
        let imported = try await store.importJSON(at: download)
        #expect(imported.clientId == "123-abc.apps.googleusercontent.com")
        #expect(imported.hasSecret)
        #expect(!imported.audited)
        #expect(await store.current() == imported)

        // A file that is not a client is refused, and the stored one is left alone.
        let junk = directory.appendingPathComponent("junk.json")
        try Data("{}".utf8).write(to: junk)
        await #expect(throws: PublishClientError.self) { try await store.importJSON(at: junk) }
        #expect(await store.current() == imported)
    }

    @Test func theEnvironmentClientIsReportedAsNotEditable() async throws {
        let (store, _) = try store(
            "environment",
            environment: [
                "TIMELINE_GOOGLE_CLIENT_ID": "env-client.apps.googleusercontent.com", "TIMELINE_GOOGLE_AUDITED": "1",
            ])
        let current = try #require(await store.current())
        #expect(current.clientId == "env-client.apps.googleusercontent.com")
        #expect(current.audited)
        #expect(!current.isEditable)
        #expect(current.source.contains("TIMELINE_GOOGLE_CLIENT_ID"))
        // Writing a file under an environment client would be ignored, so it is refused instead.
        await #expect(throws: PublishClientError.self) {
            try await store.save(clientId: "other.apps.googleusercontent.com", clientSecret: nil, audited: false)
        }
        await #expect(throws: PublishClientError.self) { try await store.remove() }
    }

    @Test func reconfiguringTheProviderInstallsTheClientWithoutRebuildingIt() async throws {
        let directory = try temporaryDirectory("reconfigure")
        let provider = GoogleAccountProvider(
            configuration: nil, tokenStore: FileTokenStore(url: directory.appendingPathComponent("tokens.json")),
            accountsFile: AccountsFile(url: directory.appendingPathComponent("accounts.json")),
            presenter: FakeAuthorizationPresenter(mode: .ignore), session: URLSession(configuration: .ephemeral),
            cacheDir: directory, environment: ["TIMELINE_ROOT": directory.path])
        #expect(!provider.isConfigured)
        await provider.reconfigure(GoogleClientConfiguration(clientId: "new.apps.googleusercontent.com"))
        #expect(provider.isConfigured)
        #expect(await provider.configuration?.clientId == "new.apps.googleusercontent.com")
        await provider.reconfigure(nil)
        #expect(!provider.isConfigured)
        await #expect(throws: AccountError.self) {
            _ = try await provider.connect(scopes: Fixtures.publishScopes, loginHint: nil)
        }
    }
}
