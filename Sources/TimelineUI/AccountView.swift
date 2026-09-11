import Contracts
import Foundation
import Observation
import SwiftUI
import TimelineCore

/// The texts the account view shows; public so the app and the tests can reference the same strings.
public enum AccountText {
    /// The scope set of publish-plan.md D2, what `AccountsModel.connect` requests by default.
    public static let youtubeScopes = ["openid", "email", "https://www.googleapis.com/auth/youtube.force-ssl"]

    /// D3: where the app looks for an OAuth client.
    public static let setup = "Add a Google OAuth client to enable publishing"
    public static let setupPaths =
        "Set TIMELINE_GOOGLE_CLIENT_ID (and optionally TIMELINE_GOOGLE_CLIENT_SECRET), or point "
        + "TIMELINE_GOOGLE_CLIENT_JSON at the console's client_secret_*.json, or put google-oauth-client.json "
        + "under TIMELINE_ROOT or in ~/Library/Application Support/Timeline."

    /// D12: the consent sentence shown next to the connect button.
    public static let consent =
        "Timeline uses YouTube API Services. Connecting means you agree to the YouTube Terms of Service "
        + "and the Google Privacy Policy."
    public static let connectButton = "Connect YouTube..."
    public static let waiting = "Waiting for the browser..."
    public static let manageAccess = "Manage access"
    /// Open question 6.6: the channel is whichever one was picked on the consent screen.
    public static let brandChannels =
        "The channel is the one chosen on Google's consent screen. To publish to a different brand channel, "
        + "disconnect and connect again, choosing that channel."

    /// 10 §4: shown while the OAuth consent screen has not passed verification.
    public static let unverifiedApp = "This app is not verified by Google yet; the consent screen shows a warning"
    /// 10 §4 and section 7: shown while the Google Cloud project is in Testing status.
    public static let testingExpiry =
        "While the Google Cloud project is in Testing, the connection expires after 7 days"

    public static let youtubeTermsURL = URL(string: "https://www.youtube.com/t/terms")!
    public static let googlePrivacyURL = URL(string: "https://policies.google.com/privacy")!
    public static let manageAccessURL = URL(string: "https://myaccount.google.com/permissions")!
}

/// The connected accounts of one `AccountProvider`, with connect, reconnect, and disconnect. Follows the
/// provider's `changes` stream once started; the list is also refreshed after every call the model
/// makes itself, so a provider without a stream still shows the right thing.
@MainActor @Observable
public final class AccountsModel {
    public let provider: any AccountProvider
    /// What `connect` and `reconnect` request (`Publisher.requiredScopes` in the app).
    public let scopes: [String]
    /// Notices the app passes in (`AccountText.unverifiedApp`, `AccountText.testingExpiry`); the UI does
    /// not know the Cloud project's status.
    public var notices: [String]
    public private(set) var accounts: [ConnectedAccount] = []
    public private(set) var isConnecting = false
    public private(set) var error: String?
    private var subscription: Task<Void, Never>?

    public init(provider: any AccountProvider, scopes: [String] = AccountText.youtubeScopes, notices: [String] = []) {
        self.provider = provider
        self.scopes = scopes
        self.notices = notices
    }

    public var isConfigured: Bool { provider.isConfigured }

    /// Loads the accounts and follows the provider's changes.
    public func start() async {
        guard subscription == nil else { return }
        let stream = provider.changes
        subscription = Task { [weak self] in
            for await list in stream {
                guard let self else { return }
                self.accounts = list
            }
        }
        accounts = await provider.accounts()
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
    }

    public func account(_ id: String) -> ConnectedAccount? { accounts.first { $0.id == id } }

    /// Opens the browser flow through the provider; shows "Waiting for the browser..." until it returns.
    public func connect() async {
        await connect(loginHint: nil)
    }

    /// `connect` again with the account's email as the login hint, for a `reauthorizationRequired` account.
    public func reconnect(_ id: String) async {
        await connect(loginHint: account(id)?.email)
    }

    public func disconnect(_ id: String) async {
        error = nil
        do {
            try await provider.disconnect(id)
            accounts = await provider.accounts()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func connect(loginHint: String?) async {
        guard !isConnecting else { return }
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            _ = try await provider.connect(scopes: scopes, loginHint: loginHint)
            accounts = await provider.accounts()
        } catch is CancellationError {
            error = AccountError.cancelled.message
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Settings > Accounts: the unconfigured hint, the connect button with its consent sentence, one row
/// per connected account, the notices, and the brand-channel help text.
public struct AccountView: View {
    public let model: AccountsModel

    public init(model: AccountsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.cardInset) {
            if !model.isConfigured {
                Label(AccountText.setup, systemImage: "key").font(PanelTheme.sectionTitle)
                Text(AccountText.setupPaths).font(PanelTheme.caption).foregroundStyle(.secondary).textSelection(
                    .enabled)
            } else {
                ForEach(model.accounts) { account in
                    AccountRowView(
                        account: account, isConnecting: model.isConnecting,
                        onReconnect: { Task { await model.reconnect(account.id) } },
                        onDisconnect: { Task { await model.disconnect(account.id) } })
                }
                if model.accounts.isEmpty {
                    Text("No YouTube channel is connected").font(PanelTheme.rowTitle).foregroundStyle(.secondary)
                }
                HStack(spacing: PanelTheme.sectionGap) {
                    Button(AccountText.connectButton) { Task { await model.connect() } }
                        .disabled(model.isConnecting)
                    if model.isConnecting {
                        ProgressView().controlSize(.small)
                        Text(AccountText.waiting).font(PanelTheme.caption).foregroundStyle(.secondary)
                    }
                }
                consentText
                ForEach(model.notices, id: \.self) { notice in
                    Label(notice, systemImage: "exclamationmark.triangle").font(PanelTheme.caption).foregroundStyle(
                        PanelTheme.warning)
                }
                Text(AccountText.brandChannels).font(PanelTheme.caption).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error).font(PanelTheme.caption).foregroundStyle(PanelTheme.danger).accessibilityIdentifier(
                    "account-error")
            }
        }
        .padding(PanelTheme.cardInset)
        .task { await model.start() }
    }

    private var consentText: some View {
        VStack(alignment: .leading, spacing: PanelTheme.hairGap) {
            Text(AccountText.consent).font(PanelTheme.caption).foregroundStyle(.secondary)
            HStack(spacing: PanelTheme.cardInset) {
                Link("YouTube Terms of Service", destination: AccountText.youtubeTermsURL)
                Link("Google Privacy Policy", destination: AccountText.googlePrivacyURL)
            }
            .font(PanelTheme.caption)
        }
    }
}

/// One connected account: avatar, "Connected as" channel and handle, email, token status, and the
/// Disconnect, Reconnect, and Manage access actions.
public struct AccountRowView: View {
    public let account: ConnectedAccount
    public let isConnecting: Bool
    public let onReconnect: () -> Void
    public let onDisconnect: () -> Void

    public init(
        account: ConnectedAccount, isConnecting: Bool = false, onReconnect: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) {
        self.account = account
        self.isConnecting = isConnecting
        self.onReconnect = onReconnect
        self.onDisconnect = onDisconnect
    }

    /// "Skeleton Channel (@skeleton)", falling back to the display name, the email, then the id.
    public static func connectedAs(_ account: ConnectedAccount) -> String {
        let name = account.channelTitle ?? account.displayName ?? account.email ?? account.id
        if let handle = account.channelHandle { return "\(name) (\(handle))" }
        return name
    }

    public static func statusText(_ status: AccountTokenStatus) -> String {
        switch status {
        case .valid: "Connected"
        case .expired: "Connected (token refreshes on next use)"
        case .reauthorizationRequired(let reason): "Reconnect required: \(reason)"
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: PanelTheme.barInsetH) {
            avatar
            VStack(alignment: .leading, spacing: PanelTheme.hairGap) {
                Text("Connected as \(AccountRowView.connectedAs(account))").font(PanelTheme.rowTitle)
                if let email = account.email { Text(email).font(PanelTheme.caption).foregroundStyle(.secondary) }
                Text(AccountRowView.statusText(account.tokenStatus))
                    .font(PanelTheme.caption)
                    .foregroundStyle(account.tokenStatus.needsReauthorization ? .orange : .secondary)
                Link(AccountText.manageAccess, destination: AccountText.manageAccessURL).font(PanelTheme.caption)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: PanelTheme.controlGap) {
                if account.tokenStatus.needsReauthorization {
                    Button("Reconnect", action: onReconnect).disabled(isConnecting)
                }
                Button("Disconnect", role: .destructive, action: onDisconnect)
            }
        }
        .padding(PanelTheme.panelInset)
        .background(PanelTheme.cardMaterial, in: RoundedRectangle(cornerRadius: PanelTheme.bubbleRadius))
        .accessibilityIdentifier("account-\(account.id)")
    }

    @ViewBuilder private var avatar: some View {
        if let url = account.avatarURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle").resizable().foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle").resizable().foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
        }
    }
}
