import Contracts
import CoreGraphics
import Foundation
import Observation
import TimelineCore
import TimelineUI

/// The Publish sheet's back end: turns a `PublishDraft` into `publish_youtube` input and calls it through
/// `ToolConsole`, so the approval card is the human's confirmation (the same gate round trip an agent
/// takes; no second dialog), then finds the job the tool submitted with `jobRunner.handle(for:)` and
/// tracks it in the `JobCenter`, whose finished row shows `PublishOutcomeView`. Also owns the account
/// model for Settings and the publish history of the open project.
@MainActor @Observable
final class PublishConsole {
    let services: AppServices
    let tools: ToolConsole
    let jobs: JobCenter
    /// Settings > Accounts; nil when publishing is switched off.
    let accounts: AccountsModel?
    /// The open project's `publishes` ledger, for the history section and Resume.
    private(set) var history: PublishHistoryModel?
    /// The done renders of the open project, newest first; the Publish button needs one.
    private(set) var doneRenders: [RenderRecord] = []
    /// The sheet's model while it is presented.
    var sheet: PublishSheetModel?
    private(set) var lastOutput: ToolOutput?
    private(set) var error: String?
    private(set) var isPublishing = false
    private weak var document: ProjectDocument?

    init(services: AppServices, tools: ToolConsole, jobs: JobCenter) {
        self.services = services
        self.tools = tools
        self.jobs = jobs
        if let provider = services.accounts {
            accounts = AccountsModel(
                provider: provider, scopes: services.publisher?.requiredScopes ?? AccountText.youtubeScopes,
                notices: PublishingServices.accountNotices)
        } else {
            accounts = nil
        }
    }

    /// True when a publisher exists (a Google client is configured, or the fake is in use).
    var isAvailable: Bool { services.publisher != nil && services.accounts != nil }

    var connectedAccounts: [ConnectedAccount] {
        (accounts?.accounts ?? []).filter { !$0.tokenStatus.needsReauthorization }
    }

    var canPublish: Bool {
        isAvailable && !connectedAccounts.isEmpty && !doneRenders.isEmpty && !isPublishing && document != nil
    }

    /// Why the Publish button is disabled, for its tooltip.
    var hint: String {
        if !isAvailable {
            return services.publishing.state == .off
                ? "Publishing is switched off" : "Add a Google OAuth client to enable publishing (Settings)"
        }
        if connectedAccounts.isEmpty { return "Connect a YouTube channel in Settings first" }
        if doneRenders.isEmpty { return "Export first: the sheet publishes a finished render" }
        return "Publish the newest export to YouTube"
    }

    /// Follows the account provider; call once after boot.
    func start() async {
        await accounts?.start()
    }

    /// Points the history and the render list at `document` (nil when the window has no project).
    func attach(_ document: ProjectDocument?) async {
        self.document = document
        history = document?.publishLedger.map { PublishHistoryModel(ledger: $0) }
        await refresh()
    }

    /// Re-reads the render and publish ledgers (after an export, a publish, a resume).
    func refresh() async {
        guard let document else {
            doneRenders = []
            return
        }
        let renders = (try? await document.renderLedger?.renders()) ?? []
        doneRenders = renders.filter { $0.status == .done && $0.outputURL != nil }
        await history?.load()
    }

    /// Builds the sheet's model over the open project and the app's renderer for the thumbnail preview.
    func presentSheet() {
        guard let document, let publisher = services.publisher, let renders = document.renderLedger,
            let sequence = document.sequence
        else { return }
        let model = PublishSheetModel(
            renders: renders, publisher: publisher, accounts: connectedAccounts, sequence: sequence,
            projectName: document.project.name, playhead: document.viewModel.playhead,
            thumbnailDirectory: services.layout.cacheDir.appendingPathComponent("publish", isDirectory: true))
        if let compiled = document.compiled {
            let renderer = services.renderer
            model.frameGrabber = { time in
                try? await renderer.frame(compiled, at: time, size: CGSize(width: 640, height: 360))
            }
            Task { await model.grabThumbnail() }
        }
        sheet = model
    }

    func dismissSheet() { sheet = nil }

    /// The sheet's Upload: the draft becomes `publish_youtube` input, the card on the approval stack is
    /// the click that certifies, and the job the tool submits is tracked for the job list.
    func upload(_ draft: PublishDraft) async {
        sheet = nil
        await publish(PublishConsole.input(for: draft))
    }

    /// Resume for a `failed` or `cancelled` row: the same tool with the row's `publishId` (D10).
    func resume(publishId: String) async {
        guard let record = history?.records.first(where: { $0.id == publishId }) else { return }
        await publish(
            ToolInput([
                "publishId": .string(publishId), "renderId": .string(record.renderId),
                "title": .string(record.request.title), "waitSeconds": 0,
            ]))
    }

    private func publish(_ input: ToolInput) async {
        guard !isPublishing else { return }
        isPublishing = true
        error = nil
        defer { isPublishing = false }
        do {
            let output = try await tools.call("publish_youtube", input: input)
            lastOutput = output
            if output.isError {
                error = output.structured?["message"]?.stringValue ?? output.text ?? "publish_youtube failed"
            } else if let jobId = output.structured?["jobId"]?.stringValue,
                let handle = await services.jobRunner.handle(for: JobID(rawValue: jobId))
            {
                jobs.track(handle)
                Task { [weak self] in
                    _ = try? await handle.wait()
                    await self?.refresh()
                }
            }
        } catch {
            self.error = "\(error)"
        }
        await refresh()
    }

    /// `publish_youtube` input for a draft. `madeForKids` is not sent: the tool has no such property
    /// (publish-plan.md D9), so the audience is set in YouTube Studio after the upload; the sheet's toggle
    /// stays on the draft for the day the tool takes it. `waitSeconds` 0 so the call answers with the job
    /// id at once and the job list shows the upload.
    static func input(for draft: PublishDraft) -> ToolInput {
        var arguments: [String: JSONValue] = [
            "publishId": .string(draft.publishId), "title": .string(draft.title),
            "privacy": .string(draft.privacy.rawValue), "containsSyntheticMedia": .bool(draft.containsSyntheticMedia),
            "notifySubscribers": .bool(draft.notifySubscribers), "waitSeconds": 0,
        ]
        if let renderId = draft.renderId { arguments["renderId"] = .string(renderId) }
        if let accountId = draft.accountId { arguments["accountId"] = .string(accountId) }
        if !draft.description.isEmpty { arguments["description"] = .string(draft.description) }
        if !draft.tags.isEmpty { arguments["tags"] = .array(draft.tags.map { .string($0) }) }
        if let categoryId = draft.categoryId { arguments["categoryId"] = .string(categoryId) }
        if let publishAt = draft.publishAt, draft.privacy == .private, let json = try? JSONValue(encoding: publishAt) {
            arguments["publishAt"] = json
        }
        if let at = draft.thumbnailAt, let json = try? JSONValue(encoding: at) { arguments["thumbnailAt"] = json }
        if !draft.captionTrackIds.isEmpty {
            arguments["captionTrackIds"] = .array(draft.captionTrackIds.map { .string($0.rawValue) })
        }
        return ToolInput(arguments)
    }
}
