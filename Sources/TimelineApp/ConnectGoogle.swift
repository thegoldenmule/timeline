import Contracts
import Foundation
import PublishKit

/// `swift run TimelineApp --connect-google`: the connect flow without the window, for the live test and
/// for anyone at a terminal. Loads the OAuth client the way the app does (publish-plan.md D3), opens the
/// consent page in the default browser, waits for the loopback redirect, stores the refresh token in
/// the store `TokenStoreSelection` picks (the file store for this unbundled binary, unless
/// `TIMELINE_TOKEN_STORE=keychain`), and prints the connected channel. Exit 1 with the reason otherwise.
@MainActor
enum ConnectGoogleCommand {
    static func run(environment: [String: String] = ProcessInfo.processInfo.environment) async -> Bool {
        let configuration: GoogleClientConfiguration
        do {
            guard let loaded = try GoogleClientConfiguration.load(environment: environment) else {
                print("No Google OAuth client: \(GoogleClientConfiguration.setupHint(environment: environment))")
                return false
            }
            configuration = loaded
        } catch {
            print("The Google OAuth client could not be read: \(error)")
            return false
        }
        let selection = TokenStoreSelection.resolve(environment: environment)
        let storeDescription: String
        switch selection {
        case .keychain: storeDescription = "the Keychain (\(KeychainTokenStore.defaultService))"
        case .file(let url): storeDescription = url.path
        }
        let root = AppServices.configuredRoot
        let layout = LibraryLayout(root: root)
        let provider = GoogleAccountProvider(
            configuration: configuration, tokenStore: selection.makeStore(),
            accountsFile: AccountsFile(url: AccountsFile.defaultURL(environment: environment)),
            presenter: WorkspaceAuthorizationPresenter(), session: URLSession(configuration: .ephemeral),
            cacheDir: layout.cacheDir, environment: environment)
        let existing = await provider.accounts()
        if !existing.isEmpty {
            print("Already connected: \(existing.map(describe).joined(separator: ", "))")
        }
        print("Client \(configuration.clientId); opening the consent page in your browser (5 minutes to finish)...")
        do {
            let account = try await provider.connect(scopes: YouTubePublisher.scopes, loginHint: nil)
            print("Connected \(describe(account)); refresh token in \(storeDescription)")
            print("Run the app and check account_status, or Settings > YouTube in the window.")
            return true
        } catch let error as AccountError {
            print("Connect failed: \(error.message)")
            return false
        } catch {
            print("Connect failed: \(error)")
            return false
        }
    }

    private static func describe(_ account: ConnectedAccount) -> String {
        let channel = account.channelTitle ?? account.displayName ?? account.id
        let handle = account.channelHandle.map { " (\($0))" } ?? ""
        let email = account.email.map { " as \($0)" } ?? ""
        return "\(channel)\(handle)\(email)"
    }
}
