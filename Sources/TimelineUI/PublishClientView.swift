import Contracts
import Foundation
import Observation
import SwiftUI
import TimelineCore
import UniformTypeIdentifiers

/// The texts of the client card; public so the app and the tests reference the same strings.
public enum PublishClientText {
    public static let title = "Google OAuth client"
    /// Shown above the fields when no client is set: the two steps that are not in this window.
    public static let intro =
        "Publishing needs an OAuth client of type \"Desktop app\" from your own Google Cloud project, with "
        + "the YouTube Data API v3 enabled. Create one in the Cloud console, then paste its id here or "
        + "choose the client_secret_*.json the console downloads."
    public static let consoleLabel = "Open the Google Cloud console"
    public static let consoleURL = URL(string: "https://console.cloud.google.com/apis/credentials")!
    public static let setupGuide = "The full checklist is in docs/design/publish-setup.md"
    public static let clientIdField = "Client ID"
    public static let clientIdPrompt = "000000000000-xxxxxxxx.apps.googleusercontent.com"
    public static let clientSecretField = "Client secret (optional)"
    public static let secretNote =
        "A Desktop client's secret is not confidential, but the app sends it when the token endpoint asks for it."
    public static let chooseFile = "Choose client_secret_*.json..."
    public static let save = "Save client"
    public static let replace = "Replace..."
    public static let remove = "Remove"
    public static let cancel = "Cancel"
    public static let secretHeld = "Client secret held"
    public static let noSecret = "No client secret"
    public static let auditedNote = "The Cloud project has passed the compliance audit: public uploads stay public"
}

/// The OAuth client behind a `PublishClientStore`: what is set, and the save, import, and remove the
/// panel offers. `onChange` is how the app hears that the stack should be reconfigured.
@MainActor @Observable
public final class PublishClientModel {
    public let store: any PublishClientStore
    public private(set) var client: PublishClient?
    public private(set) var error: String?
    public private(set) var isWorking = false
    /// True while the fields are shown: always when no client is set, and after "Replace...".
    public private(set) var isEditing = false
    public var clientId = ""
    public var clientSecret = ""
    /// Called after the stored client changed, so the composition root can install it.
    public var onChange: (@MainActor () async -> Void)?

    public init(store: any PublishClientStore) {
        self.store = store
    }

    public var destinationPath: String { store.destinationPath }

    /// True when the client may be replaced here; false while the environment sets it.
    public var isEditable: Bool { client?.isEditable ?? true }

    public func load() async {
        client = await store.current()
        isEditing = client == nil
    }

    public func beginEditing() {
        clientId = ""
        clientSecret = ""
        error = nil
        isEditing = true
    }

    public func cancelEditing() {
        error = nil
        isEditing = client != nil ? false : true
    }

    public func save() async {
        let id = clientId
        let secret = clientSecret
        let audited = client?.audited ?? false
        await perform { try await self.store.save(clientId: id, clientSecret: secret, audited: audited) }
    }

    public func importJSON(at url: URL) async {
        await perform { try await self.store.importJSON(at: url) }
    }

    public func remove() async {
        await perform {
            try await self.store.remove()
            return nil
        }
    }

    /// A failure from a surface the model does not own (the file importer).
    public func report(_ error: any Error) { self.error = error.localizedDescription }

    /// Runs one store call, then re-reads what is in effect and tells the app.
    private func perform(_ work: @escaping () async throws -> PublishClient?) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            _ = try await work()
        } catch {
            self.error = (error as? PublishClientError)?.message ?? error.localizedDescription
            return
        }
        clientId = ""
        clientSecret = ""
        await load()
        await onChange?()
    }
}

/// The client card of the Publishes panel and of Settings: the client in effect with Replace and
/// Remove, or the fields and the file chooser that set one.
public struct PublishClientView: View {
    @Bindable private var model: PublishClientModel
    @State private var choosingFile = false

    public init(model: PublishClientModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.controlGap) {
            Label(PublishClientText.title, systemImage: "key").font(PanelTheme.sectionTitle)
            if let client = model.client, !model.isEditing {
                configured(client)
            } else {
                editor
            }
            if let error = model.error {
                Text(error).font(PanelTheme.caption).foregroundStyle(PanelTheme.danger)
                    .accessibilityIdentifier("client-error")
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): Task { await model.importJSON(at: url) }
            case .failure(let error): model.report(error)
            }
        }
        .task { await model.load() }
        .accessibilityIdentifier("publish-client")
    }

    /// The client in effect: its id, where it came from, and what may be done to it.
    private func configured(_ client: PublishClient) -> some View {
        VStack(alignment: .leading, spacing: PanelTheme.hairGap) {
            Text(client.clientId).font(PanelTheme.monoSmall).textSelection(.enabled).lineLimit(1)
                .truncationMode(.middle)
            Text(client.source).font(PanelTheme.detail).foregroundStyle(.secondary).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Text(client.hasSecret ? PublishClientText.secretHeld : PublishClientText.noSecret)
                .font(PanelTheme.detail).foregroundStyle(.secondary)
            if client.audited {
                Text(PublishClientText.auditedNote).font(PanelTheme.detail).foregroundStyle(.secondary)
            }
            if client.isEditable {
                HStack(spacing: PanelTheme.controlGap) {
                    Button(PublishClientText.replace) { model.beginEditing() }
                    Button(PublishClientText.remove, role: .destructive) { Task { await model.remove() } }
                }
                .font(PanelTheme.caption)
                .disabled(model.isWorking)
                .padding(.top, PanelTheme.hairGap)
            }
        }
    }

    /// The fields, the file chooser, and where the client will be written.
    private var editor: some View {
        VStack(alignment: .leading, spacing: PanelTheme.controlGap) {
            Text(PublishClientText.intro).font(PanelTheme.caption).foregroundStyle(.secondary)
            Link(PublishClientText.consoleLabel, destination: PublishClientText.consoleURL).font(PanelTheme.caption)
            TextField(
                PublishClientText.clientIdField, text: $model.clientId,
                prompt: Text(PublishClientText.clientIdPrompt)
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await model.save() } }
            .accessibilityIdentifier("client-id-field")
            SecureField(PublishClientText.clientSecretField, text: $model.clientSecret)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("client-secret-field")
            HStack(spacing: PanelTheme.controlGap) {
                Button(PublishClientText.save) { Task { await model.save() } }
                    .disabled(model.isWorking || model.clientId.isEmpty)
                Button(PublishClientText.chooseFile) { choosingFile = true }.disabled(model.isWorking)
                if model.client != nil {
                    Button(PublishClientText.cancel) { model.cancelEditing() }
                }
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            .font(PanelTheme.caption)
            Text("Stored at \(model.destinationPath)").font(PanelTheme.detail).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Text(PublishClientText.secretNote).font(PanelTheme.detail).foregroundStyle(.secondary)
            Text(PublishClientText.setupGuide).font(PanelTheme.detail).foregroundStyle(.secondary)
        }
    }
}
