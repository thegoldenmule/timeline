import AppKit
import Contracts
import ContractsTestSupport
import Foundation
import PublishKit
import TimelineCore
import TimelineUI

/// Opens Google's authorization URL in the default browser. The redirect comes back on PublishKit's
/// own loopback listener, so this is all the app has to do (publish-plan.md D1). AppKit lives here, not
/// in PublishKit, so an `ASWebAuthenticationSession` presenter can replace it once the app is bundled.
struct WorkspaceAuthorizationPresenter: AuthorizationPresenter {
    @MainActor func open(_ authorizationURL: URL) async throws {
        guard NSWorkspace.shared.open(authorizationURL) else {
            throw AccountError.protocolError("the default browser could not open \(authorizationURL.host() ?? "the URL")")
        }
    }
}

/// Which publishing stack `AppServices.boot` builds (publish-plan.md 4.5).
enum PublishingMode: Sendable {
    /// Load `GoogleClientConfiguration`; a missing client leaves the publisher out and the account
    /// provider unconfigured, so Settings shows the setup hint and `publish_youtube` is hidden.
    case auto
    /// The real `GoogleAccountProvider` and `YouTubePublisher` over `FakeYouTubeServer`, with a file token
    /// store in the library root and a presenter that completes the loopback callback itself (the
    /// headless check, or `TIMELINE_PUBLISHING=fake` for the window).
    case fake
    /// No accounts, no publisher.
    case off

    /// `TIMELINE_PUBLISHING=fake|off`, else `.auto`.
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> PublishingMode
    {
        switch environment["TIMELINE_PUBLISHING"]?.lowercased() {
        case "fake": .fake
        case "off": .off
        default: .auto
        }
    }
}

/// The publishing half of the composition root: the Google account provider, the YouTube publisher,
/// and how they were built, for the window's Settings and the integration notes.
struct PublishingServices: Sendable {
    enum State: Sendable, Equatable {
        /// A real OAuth client; `clientId` is what the console issued.
        case configured(clientId: String, audited: Bool)
        /// No client found; the hint says where to put one.
        case notConfigured(hint: String)
        case fake
        case off

        var isConfigured: Bool {
            if case .configured = self { return true }
            return self == .fake
        }
    }

    /// The Google provider; present in every mode but `.off` (unconfigured under `.auto` without a
    /// client, so the account view shows the setup hint and `account_status` answers `configured: false`).
    let accounts: (any AccountProvider)?
    /// Present only when uploads can actually happen (`.configured` or `.fake`), which is what hides
    /// `publish_youtube` and `publish_status` otherwise.
    let publisher: (any Publisher)?
    let state: State
    /// Where the refresh tokens live, for the log and the docs.
    let tokenStoreDescription: String
    /// The in-process Google under `.fake`, so the headless check can arm faults and read what it saw.
    let fakeServer: FakeYouTubeServer?
    /// The chunk size the fake publisher uploads with (the check asserts the drop and resume by chunk).
    let uploadOptions: UploadOptions

    /// The notices the account view shows (publish-plan.md 4.5): both stay on until the OAuth
    /// verification and the compliance audit of section 7 are done.
    static let accountNotices = [AccountText.unverifiedApp, AccountText.testingExpiry]

    /// The 5 MiB the check uploads, in 1 MiB chunks, with backoff and processing polls in milliseconds.
    static let fakeUploadOptions = UploadOptions(
        chunkBytes: 1 << 20, backoffUnit: .milliseconds(5), maxBackoff: .milliseconds(20),
        processingPollInitial: .milliseconds(5), processingPollMaximum: .milliseconds(20))

    static let off = PublishingServices(
        accounts: nil, publisher: nil, state: .off, tokenStoreDescription: "none", fakeServer: nil,
        uploadOptions: UploadOptions())

    /// Builds the stack for `mode` over the library `layout`.
    static func make(
        mode: PublishingMode, layout: LibraryLayout, environment: [String: String] = ProcessInfo.processInfo.environment,
        log: AppLog
    ) async throws -> PublishingServices {
        switch mode {
        case .off:
            log.log("Publishing disabled (TIMELINE_PUBLISHING=off)")
            return .off
        case .fake:
            return await makeFake(layout: layout, log: log)
        case .auto:
            return try makeReal(layout: layout, environment: environment, log: log)
        }
    }

    private static func makeReal(layout: LibraryLayout, environment: [String: String], log: AppLog) throws
        -> PublishingServices
    {
        var configuration: GoogleClientConfiguration?
        var loadError: String?
        do {
            configuration = try GoogleClientConfiguration.load(environment: environment)
        } catch {
            loadError = "\(error)"
            log.log("Publishing: the Google OAuth client could not be read: \(error)")
        }
        // Under TIMELINE_ROOT the token and account files sit in the root (tests, the check); otherwise in
        // Application Support, and the Keychain once the binary runs from an .app bundle (D4).
        let selection = TokenStoreSelection.resolve(environment: environment)
        let tokenStore = selection.makeStore()
        let tokenStoreDescription: String
        switch selection {
        case .keychain: tokenStoreDescription = "Keychain (\(KeychainTokenStore.defaultService))"
        case .file(let url): tokenStoreDescription = "file \(url.path)"
        }
        let session = URLSession(configuration: .ephemeral)
        let provider = GoogleAccountProvider(
            configuration: configuration, tokenStore: tokenStore,
            accountsFile: AccountsFile(url: AccountsFile.defaultURL(environment: environment)),
            presenter: WorkspaceAuthorizationPresenter(), session: session, cacheDir: layout.cacheDir,
            environment: environment)
        guard let configuration else {
            var hint = GoogleClientConfiguration.setupHint(environment: environment)
            if let loadError { hint = "\(loadError); \(hint)" }
            log.log("Publishing disabled: no Google OAuth client (see docs/design/publish-setup.md); \(hint)")
            return PublishingServices(
                accounts: provider, publisher: nil, state: .notConfigured(hint: hint),
                tokenStoreDescription: tokenStoreDescription, fakeServer: nil, uploadOptions: UploadOptions())
        }
        let quota = QuotaMeter(fileURL: QuotaMeter.fileURL(cacheDir: layout.cacheDir))
        let publisher = YouTubePublisher(
            accounts: provider, session: session, quota: quota, audited: configuration.audited)
        log.log(
            "Publishing: Google client \(configuration.clientId.prefix(12))..., tokens in \(tokenStoreDescription), "
                + (configuration.audited ? "audited" : "uploads forced private until the compliance audit"))
        return PublishingServices(
            accounts: provider, publisher: publisher,
            state: .configured(clientId: configuration.clientId, audited: configuration.audited),
            tokenStoreDescription: tokenStoreDescription, fakeServer: nil, uploadOptions: UploadOptions())
    }

    private static func makeFake(layout: LibraryLayout, log: AppLog) async -> PublishingServices {
        let server = FakeYouTubeServer()
        await server.seedFixtureAccount()
        let session = URLSession(configuration: server.sessionConfiguration())
        let tokenURL = layout.root.appendingPathComponent(FileTokenStore.fileName)
        let environment = ["TIMELINE_ROOT": layout.root.path]
        let provider = GoogleAccountProvider(
            configuration: GoogleClientConfiguration(clientId: "fake-client.apps.googleusercontent.com"),
            tokenStore: FileTokenStore(url: tokenURL),
            accountsFile: AccountsFile(url: AccountsFile.defaultURL(environment: environment, root: layout.root)),
            presenter: FakeAuthorizationPresenter(mode: .completeCallback, server: server), session: session,
            listenerTimeout: .seconds(10), cacheDir: layout.cacheDir, environment: environment)
        let quota = QuotaMeter(fileURL: QuotaMeter.fileURL(cacheDir: layout.cacheDir))
        let publisher = YouTubePublisher(
            accounts: provider, session: session, quota: quota, audited: false, options: fakeUploadOptions)
        log.log("Publishing: fake YouTube server \(server.id), tokens in file \(tokenURL.path)")
        return PublishingServices(
            accounts: provider, publisher: publisher, state: .fake, tokenStoreDescription: "file \(tokenURL.path)",
            fakeServer: server, uploadOptions: fakeUploadOptions)
    }
}
