import AgentKit
import AppKit
import Contracts
import ContractsTestSupport
import Foundation
import PublishKit
import Synchronization
import TimelineCore
import TimelineUI

/// Opens Google's authorization URL in the default browser. The redirect comes back on PublishKit's
/// own loopback listener, so this is all the app has to do (publish-plan.md D1). AppKit lives here, not
/// in PublishKit, so an `ASWebAuthenticationSession` presenter can replace it once the app is bundled.
struct WorkspaceAuthorizationPresenter: AuthorizationPresenter {
    @MainActor func open(_ authorizationURL: URL) async throws {
        guard NSWorkspace.shared.open(authorizationURL) else {
            throw AccountError.protocolError(
                "the default browser could not open \(authorizationURL.host() ?? "the URL")")
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
///
/// A reference type, and in `.auto` the provider and the publisher exist whether or not a client does,
/// because the client can now be set in the window (docs/plans/publish-client-setup.md): `apply` swaps
/// the client into the same two objects, so every snapshot that already holds them — the MCP host's
/// `ToolContext` above all — keeps working. Only `state` and the tool registrations change with it.
final class PublishingServices: Sendable {
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
    /// The YouTube publisher, present in every mode but `.off`. Without a client it has nothing to
    /// upload with, which is why `publish_youtube` and `publish_status` stay unregistered until `state`
    /// says configured.
    let publisher: (any Publisher)?
    /// Where a client typed or imported in the window is stored; nil under `.fake` and `.off`.
    let clientStore: GoogleClientFile?
    /// Where the refresh tokens live, for the log and the docs.
    let tokenStoreDescription: String
    /// The in-process Google under `.fake`, so the headless check can arm faults and read what it saw.
    let fakeServer: FakeYouTubeServer?
    /// The chunk size the fake publisher uploads with (the check asserts the drop and resume by chunk).
    let uploadOptions: UploadOptions
    private let stateBox: Mutex<State>

    /// How publishing is configured right now; `apply` moves it between `.configured` and `.notConfigured`.
    var state: State { stateBox.withLock { $0 } }

    init(
        accounts: (any AccountProvider)?, publisher: (any Publisher)?, state: State, tokenStoreDescription: String,
        fakeServer: FakeYouTubeServer?, uploadOptions: UploadOptions, clientStore: GoogleClientFile? = nil
    ) {
        self.accounts = accounts
        self.publisher = publisher
        self.clientStore = clientStore
        self.tokenStoreDescription = tokenStoreDescription
        self.fakeServer = fakeServer
        self.uploadOptions = uploadOptions
        self.stateBox = Mutex(state)
    }

    /// The notices the account view shows (publish-plan.md 4.5): both stay on until the OAuth
    /// verification and the compliance audit of section 7 are done.
    static let accountNotices = [AccountText.unverifiedApp, AccountText.testingExpiry]

    /// 256 KiB chunks (so the check's short export still spans several and a drop lands mid-file), with
    /// backoff and processing polls in milliseconds.
    static let fakeUploadOptions = UploadOptions(
        chunkBytes: 256 << 10, backoffUnit: .milliseconds(5), maxBackoff: .milliseconds(20),
        processingPollInitial: .milliseconds(5), processingPollMaximum: .milliseconds(20))

    static var off: PublishingServices {
        PublishingServices(
            accounts: nil, publisher: nil, state: .off, tokenStoreDescription: "none", fakeServer: nil,
            uploadOptions: UploadOptions())
    }

    /// Builds the stack for `mode` over the library `layout`.
    static func make(
        mode: PublishingMode, layout: LibraryLayout,
        environment: [String: String] = ProcessInfo.processInfo.environment,
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
        let clientStore = GoogleClientFile(environment: environment)
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
        let quota = QuotaMeter(fileURL: QuotaMeter.fileURL(cacheDir: layout.cacheDir))
        // Built even without a client: `apply` reconfigures the provider under it when one is saved in the
        // window, and the publisher asks the provider for a token per request, so there is nothing stale
        // to rebuild. `state` is what decides whether the publish tools are registered.
        let publisher = YouTubePublisher(
            accounts: provider, session: session, quota: quota, audited: configuration?.audited ?? false)
        let state: State
        if let configuration {
            state = .configured(clientId: configuration.clientId, audited: configuration.audited)
            log.log(
                "Publishing: Google client \(configuration.clientId.prefix(12))..., tokens in "
                    + tokenStoreDescription + ", "
                    + (configuration.audited ? "audited" : "uploads forced private until the compliance audit"))
        } else {
            var hint = GoogleClientConfiguration.setupHint(environment: environment)
            if let loadError { hint = "\(loadError); \(hint)" }
            state = .notConfigured(hint: hint)
            log.log(
                "Publishing: no Google OAuth client yet; set one in the Publishes panel or at "
                    + clientStore.destinationPath)
        }
        return PublishingServices(
            accounts: provider, publisher: publisher, state: state, tokenStoreDescription: tokenStoreDescription,
            fakeServer: nil, uploadOptions: UploadOptions(), clientStore: clientStore)
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

    // MARK: Reconfiguring

    /// Installs a client saved in the window: the provider and the publisher follow it in place, `state`
    /// moves, and the publish tools appear in (or leave) the registry, so nothing needs a relaunch.
    /// Pass nil for a client that was removed.
    func apply(
        _ configuration: GoogleClientConfiguration?, registry: (any ToolRegistry)?,
        environment: [String: String] = ProcessInfo.processInfo.environment, log: AppLog? = nil
    ) async {
        guard let provider = accounts as? GoogleAccountProvider else { return }
        await provider.reconfigure(configuration)
        (publisher as? YouTubePublisher)?.setAudited(configuration?.audited ?? false)
        stateBox.withLock {
            if let configuration {
                $0 = .configured(clientId: configuration.clientId, audited: configuration.audited)
            } else {
                $0 = .notConfigured(hint: GoogleClientConfiguration.setupHint(environment: environment))
            }
        }
        log?.log(
            configuration.map { "Publishing: Google client \($0.clientId.prefix(12))... set in the window" }
                ?? "Publishing: the Google OAuth client was removed")
        if let registry { await syncTools(in: registry) }
    }

    /// Registers or unregisters the two tools that need a client, to match `state`. `account_status` stays
    /// registered either way: reporting `configured: false` is the answer the agent needs.
    func syncTools(in registry: any ToolRegistry) async {
        await EditorTools.setRegistered(
            EditorTools.publishingToolNames, registered: state.isConfigured, in: registry)
    }
}
