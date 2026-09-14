import AppKit
import Contracts
import Foundation
import Observation
import SwiftUI
import TimelineCore

// MARK: - Draft

/// What the sheet edits. `publishId` is minted once per sheet presentation and is the idempotency key
/// of the publish (publish-plan.md D10); `madeForKids` is explicit here because the human path must
/// declare the audience (ToS 9.1, D9), while the agent path leaves `PublishRequest.madeForKids` nil.
public struct PublishDraft: Hashable, Sendable, Codable {
    public var publishId: String
    public var renderId: String?
    public var accountId: String?
    public var title: String
    public var description: String
    public var tags: [String]
    public var categoryId: String?
    public var privacy: PublishPrivacy
    /// Only meaningful while `privacy == .private`; the model clears it otherwise.
    public var publishAt: Date?
    public var madeForKids: Bool
    public var containsSyntheticMedia: Bool
    /// The sequence time of the thumbnail frame; nil means no thumbnail.
    public var thumbnailAt: RationalTime?
    public var captionTrackIds: [TrackID]
    public var notifySubscribers: Bool
    public var playlistId: String?

    public init(
        publishId: String, renderId: String? = nil, accountId: String? = nil, title: String = "",
        description: String = "", tags: [String] = [], categoryId: String? = PublishCategory.defaultId,
        privacy: PublishPrivacy = .private, publishAt: Date? = nil, madeForKids: Bool = false,
        containsSyntheticMedia: Bool = false, thumbnailAt: RationalTime? = nil, captionTrackIds: [TrackID] = [],
        notifySubscribers: Bool = false, playlistId: String? = nil
    ) {
        self.publishId = publishId
        self.renderId = renderId
        self.accountId = accountId
        self.title = title
        self.description = description
        self.tags = tags
        self.categoryId = categoryId
        self.privacy = privacy
        self.publishAt = publishAt
        self.madeForKids = madeForKids
        self.containsSyntheticMedia = containsSyntheticMedia
        self.thumbnailAt = thumbnailAt
        self.captionTrackIds = captionTrackIds
        self.notifySubscribers = notifySubscribers
        self.playlistId = playlistId
    }
}

/// One of YouTube's assignable video categories (the US list, 11 §3; open question 6.10 keeps it static).
public struct PublishCategory: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// "People & Blogs", YouTube's own default.
    public static let defaultId = "22"

    public static let assignable: [PublishCategory] = [
        PublishCategory(id: "1", name: "Film & Animation"),
        PublishCategory(id: "2", name: "Autos & Vehicles"),
        PublishCategory(id: "10", name: "Music"),
        PublishCategory(id: "15", name: "Pets & Animals"),
        PublishCategory(id: "17", name: "Sports"),
        PublishCategory(id: "19", name: "Travel & Events"),
        PublishCategory(id: "20", name: "Gaming"),
        PublishCategory(id: "22", name: "People & Blogs"),
        PublishCategory(id: "23", name: "Comedy"),
        PublishCategory(id: "24", name: "Entertainment"),
        PublishCategory(id: "25", name: "News & Politics"),
        PublishCategory(id: "26", name: "Howto & Style"),
        PublishCategory(id: "27", name: "Education"),
        PublishCategory(id: "28", name: "Science & Technology"),
        PublishCategory(id: "29", name: "Nonprofits & Activism"),
    ]
}

/// The texts of the sheet, shared with the tests and the app.
public enum PublishText {
    /// YouTube API Terms 9.1: shown under the Upload button (D12); the card repeats it as its last row.
    public static let certification =
        "By clicking Upload you certify that the content you are uploading complies with the YouTube Terms of Service"
    public static let exportFirst = "Export first: the sheet publishes a finished render"
    public static let madeForKidsHelp =
        "Required by law (COPPA): say whether this video is made for kids. Videos for kids lose personalised ads, "
        + "comments, and notifications. You can change the audience in YouTube Studio."
    public static let syntheticMediaHelp =
        "Turn this on when realistic content was meaningfully altered or generated with AI: a real person "
        + "saying or doing something they did not, altered footage of a real event or place, or a realistic "
        + "scene that did not happen. Not needed for scripts, captions, colour, clearly unrealistic "
        + "animation, or production help like brightness and background blur."
    public static let scheduleHelp = "Scheduling keeps the video private until the date; it needs Private privacy."
    public static let noCaptionTracks = "The project has no caption tracks"
}

// MARK: - Model

/// The state behind `PublishSheetView`: the newest done render, the connected accounts, the sequence's
/// caption tracks, the publisher's capabilities and quota, and the live validation of the draft.
@MainActor @Observable
public final class PublishSheetModel {
    public let renders: any RenderLedger
    public let publisher: any Publisher
    public let accounts: [ConnectedAccount]
    public let sequence: Sequence
    public let projectName: String
    public let playhead: RationalTime
    /// Where `request()` writes the thumbnail JPEG.
    public let thumbnailDirectory: URL
    /// Debounce for `validate` after an edit.
    public let validationDelay: Duration

    public var draft: PublishDraft {
        didSet { draftChanged(from: oldValue) }
    }
    public private(set) var renderRecords: [RenderRecord] = []
    /// The sequence's caption tracks with cues, in track order; the captions toggle lists them.
    public let captionTracks: [PublishCaptionTrack]
    public private(set) var capabilities: PublishCapabilities?
    public private(set) var quota: PublishQuota?
    /// From `Publisher.validate`: the soft findings (Shorts shape, ...).
    public private(set) var warnings: [String] = []
    /// From `Publisher.validate`: the hard violation, when there is one.
    public private(set) var validationError: String?
    public private(set) var isValidating = false
    public private(set) var isLoaded = false
    /// The thumbnail frame the app supplies (`Renderer.frame` at `draft.thumbnailAt`).
    public var thumbnailImage: CGImage?
    /// Called by the "Use current frame" button with the time to grab; the app wires `Renderer.frame`.
    public var frameGrabber: (@MainActor (RationalTime) async -> CGImage?)?
    private var validation: Task<Void, Never>?

    public init(
        renders: any RenderLedger, publisher: any Publisher, accounts: [ConnectedAccount], sequence: Sequence,
        projectName: String, playhead: RationalTime, ids: any IDGenerator = UUIDv7Generator(),
        thumbnailDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "timeline-thumbnails", isDirectory: true),
        validationDelay: Duration = .milliseconds(300)
    ) {
        self.renders = renders
        self.publisher = publisher
        self.accounts = accounts
        self.sequence = sequence
        self.projectName = projectName
        self.playhead = playhead
        self.thumbnailDirectory = thumbnailDirectory
        self.validationDelay = validationDelay
        let tracks = CaptionCues.tracks(in: sequence)
        captionTracks = tracks
        let account = accounts.first { !$0.tokenStatus.needsReauthorization } ?? accounts.first
        draft = PublishDraft(
            publishId: ids.next(), accountId: account?.id, title: projectName, privacy: .private,
            thumbnailAt: playhead, captionTrackIds: tracks.compactMap(\.trackId))
    }

    /// Loads the render list, the capabilities, and the quota, selects the newest done render, and
    /// validates once.
    public func load() async {
        renderRecords = (try? await renders.renders()) ?? []
        if draft.renderId == nil || selectedRender == nil {
            draft.renderId = renderRecords.first { $0.status == .done && $0.outputURL != nil }?.id
        }
        capabilities = await publisher.capabilities()
        quota = await publisher.quota()
        isLoaded = true
        await validateNow()
    }

    // MARK: Derived state

    public var selectedRender: RenderRecord? { renderRecords.first { $0.id == draft.renderId } }
    public var selectedAccount: ConnectedAccount? { accounts.first { $0.id == draft.accountId } }
    /// Renders the picker offers: done, with an output file.
    public var publishableRenders: [RenderRecord] { renderRecords.filter { $0.status == .done && $0.outputURL != nil } }
    public var renderHint: String? { isLoaded && publishableRenders.isEmpty ? PublishText.exportFirst : nil }

    /// `publishAt` is only allowed for private uploads (D6).
    public var canSchedule: Bool { draft.privacy == .private }

    /// D6: the notice under the privacy control while the project is unaudited.
    public var forcedPrivateNotice: String? {
        guard let capabilities, !capabilities.publicUploadsAllowed else { return nil }
        return capabilities.note ?? PublishCapabilities.unauditedNote
    }

    /// "N uploads left today".
    public var uploadsRemainingText: String? {
        guard let quota else { return nil }
        let n = quota.uploadsRemaining
        return n == 1 ? "1 upload left today" : "\(n) uploads left today"
    }

    public var fileSize: Int64? {
        guard let url = selectedRender?.outputURL,
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    /// "Upload 80 MB to Skeleton Channel as private".
    public var summary: String {
        let size = fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "the render"
        let channel = selectedAccount.map(AccountRowView.connectedAs) ?? "no channel"
        return "Upload \(size) to \(channel) as \(draft.privacy.rawValue)"
    }

    public var canUpload: Bool {
        selectedRender != nil && selectedAccount != nil
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validationError == nil
            && !isValidating && (quota?.uploadsRemaining ?? 1) > 0
    }

    // MARK: Editing

    public func isCaptionTrackSelected(_ id: TrackID) -> Bool { draft.captionTrackIds.contains(id) }

    public func setCaptionTrack(_ id: TrackID, selected: Bool) {
        if selected {
            if !draft.captionTrackIds.contains(id) {
                draft.captionTrackIds = captionTracks.compactMap(\.trackId).filter {
                    $0 == id || draft.captionTrackIds.contains($0)
                }
            }
        } else {
            draft.captionTrackIds.removeAll { $0 == id }
        }
    }

    /// Grabs the frame at `draft.thumbnailAt` through `frameGrabber` (the app's `Renderer.frame`).
    public func grabThumbnail() async {
        guard let frameGrabber, let time = draft.thumbnailAt else { return }
        thumbnailImage = await frameGrabber(time)
    }

    private func draftChanged(from old: PublishDraft) {
        if draft.privacy != .private, draft.publishAt != nil {
            draft.publishAt = nil
            return
        }
        if draft != old { scheduleValidation() }
    }

    // MARK: Validation

    /// Validates after `validationDelay`, cancelling a validation already scheduled.
    public func scheduleValidation() {
        validation?.cancel()
        let delay = validationDelay
        validation = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.validateNow()
        }
    }

    /// Runs `Publisher.validate` on the current draft now.
    public func validateNow() async {
        validation?.cancel()
        validation = nil
        guard let request = try? request(writingThumbnail: false) else {
            warnings = []
            validationError = nil
            return
        }
        isValidating = true
        defer { isValidating = false }
        do {
            warnings = try await publisher.validate(request)
            validationError = nil
        } catch let error as PublishError {
            warnings = []
            validationError = error.message
        } catch {
            warnings = []
            validationError = error.localizedDescription
        }
    }

    // MARK: Request

    public enum RequestError: Error, Hashable, Sendable {
        case noRender
        case noAccount
        case thumbnailWriteFailed(String)
    }

    /// The `PublishRequest` for the draft: render file, hash and version from the ledger row, captions
    /// from the selected tracks, the thumbnail written as a JPEG next to the temporary files when a
    /// frame is held, `madeForKids` always set (the human declares it).
    public func request(writingThumbnail: Bool = true) throws -> PublishRequest {
        guard let render = selectedRender, let fileURL = render.outputURL else { throw RequestError.noRender }
        guard let account = selectedAccount else { throw RequestError.noAccount }
        var thumbnail: PublishThumbnail?
        if writingThumbnail, let image = thumbnailImage, let time = draft.thumbnailAt {
            thumbnail = PublishThumbnail(fileURL: try writeThumbnail(image), sourceTime: time)
        }
        let captions = captionTracks.filter { track in
            guard let id = track.trackId else { return false }
            return draft.captionTrackIds.contains(id)
        }
        let size: (width: Int, height: Int)
        if case .fixed(let w, let h) = render.preset.size {
            size = (w, h)
        } else {
            size = (sequence.width, sequence.height)
        }
        let playlist = draft.playlistId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PublishRequest(
            destination: publisher.destination, accountId: account.id, renderId: render.id, fileURL: fileURL,
            expectedContentHash: render.outputHash, projectVersion: render.projectVersion,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines), description: draft.description,
            tags: draft.tags, categoryId: draft.categoryId, language: captions.first?.language, privacy: draft.privacy,
            publishAt: draft.privacy == .private ? draft.publishAt : nil, madeForKids: draft.madeForKids,
            containsSyntheticMedia: draft.containsSyntheticMedia, notifySubscribers: draft.notifySubscribers,
            thumbnail: thumbnail, captions: captions, playlistId: playlist.flatMap { $0.isEmpty ? nil : $0 },
            durationSeconds: render.receipt?.durationSeconds, width: size.width, height: size.height)
    }

    private func writeThumbnail(_ image: CGImage) throws -> URL {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw RequestError.thumbnailWriteFailed("JPEG encoding failed")
        }
        do {
            try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
            let url = thumbnailDirectory.appendingPathComponent("\(draft.publishId).jpg")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw RequestError.thumbnailWriteFailed(error.localizedDescription)
        }
    }
}

// MARK: - View

/// The Publish sheet: render and channel, title, description, tags, privacy with the forced-private
/// notice, schedule (private only), category, captions, thumbnail, the AI disclosure, the audience,
/// the summary line, the validation messages, and Upload with the certification sentence (D12).
public struct PublishSheetView: View {
    @Bindable public var model: PublishSheetModel
    public let onUpload: (PublishDraft) async -> Void
    public let onCancel: () -> Void
    @State private var isUploading = false
    @State private var submitError: String?

    public init(
        model: PublishSheetModel, onUpload: @escaping (PublishDraft) async -> Void, onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.onUpload = onUpload
        self.onCancel = onCancel
    }

    /// The same sheet handing over the built `PublishRequest` instead of the draft.
    public init(
        model: PublishSheetModel, onSubmit: @escaping (PublishRequest) async -> Void, onCancel: @escaping () -> Void
    ) {
        self.init(
            model: model,
            onUpload: { _ in
                if let request = try? model.request() { await onSubmit(request) }
            }, onCancel: onCancel)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                sourceSection
                detailsSection
                privacySection
                extrasSection
                declarationsSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(minWidth: 480)
        .task { if !model.isLoaded { await model.load() } }
    }

    private var sourceSection: some View {
        Section("Source") {
            if let hint = model.renderHint {
                Text(hint).foregroundStyle(.secondary).accessibilityIdentifier("publish-export-first")
            } else {
                Picker("Render", selection: $model.draft.renderId) {
                    ForEach(model.publishableRenders) { render in
                        Text(PublishSheetView.renderLabel(render)).tag(Optional(render.id))
                    }
                }
            }
            Picker("Channel", selection: $model.draft.accountId) {
                ForEach(model.accounts) { account in
                    Text(AccountRowView.connectedAs(account)).tag(Optional(account.id))
                }
            }
            if model.accounts.isEmpty {
                Text("Connect a YouTube channel in Settings first").foregroundStyle(.secondary)
            }
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            TextField("Title", text: $model.draft.title, prompt: Text("1 to 100 characters"))
            VStack(alignment: .leading) {
                Text("Description")
                TextEditor(text: $model.draft.description).frame(minHeight: 60)
            }
            TextField("Tags", text: tagsBinding, prompt: Text("comma separated"))
            Picker("Category", selection: $model.draft.categoryId) {
                ForEach(PublishCategory.assignable) { category in
                    Text(category.name).tag(Optional(category.id))
                }
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Picker("Privacy", selection: $model.draft.privacy) {
                ForEach(PublishPrivacy.allCases, id: \.self) { privacy in
                    Text(privacy.rawValue.capitalized).tag(privacy)
                }
            }
            .pickerStyle(.segmented)
            if let notice = model.forcedPrivateNotice {
                Label(notice, systemImage: "lock").font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("publish-forced-private")
            }
            if model.canSchedule {
                Toggle("Schedule", isOn: scheduleBinding)
                if let date = model.draft.publishAt {
                    DatePicker(
                        "Publish at",
                        selection: Binding(get: { date }, set: { model.draft.publishAt = $0 }), in: Date()...)
                }
                Text(PublishText.scheduleHelp).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Notify subscribers", isOn: $model.draft.notifySubscribers)
        }
    }

    private var extrasSection: some View {
        Section("Captions and thumbnail") {
            if model.captionTracks.isEmpty {
                Text(PublishText.noCaptionTracks).foregroundStyle(.secondary)
            }
            ForEach(model.captionTracks, id: \.trackId) { track in
                if let id = track.trackId {
                    Toggle(
                        "\(track.name) (\(track.language), \(track.cues.count) cues)",
                        isOn: Binding(
                            get: { model.isCaptionTrackSelected(id) },
                            set: { model.setCaptionTrack(id, selected: $0) }))
                }
            }
            HStack(alignment: .top, spacing: 10) {
                thumbnailPreview
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Thumbnail from a frame", isOn: thumbnailBinding)
                    if let time = model.draft.thumbnailAt {
                        Text(String(format: "Frame at %.1f s", time.seconds)).font(.caption).foregroundStyle(.secondary)
                        if model.frameGrabber != nil {
                            Button("Use current frame") { Task { await model.grabThumbnail() } }.font(.caption)
                        }
                    }
                }
            }
            TextField("Playlist id", text: playlistBinding, prompt: Text("optional"))
        }
    }

    private var declarationsSection: some View {
        Section("Declarations") {
            Toggle("Contains altered or synthetic media", isOn: $model.draft.containsSyntheticMedia)
            Text(PublishText.syntheticMediaHelp).font(.caption).foregroundStyle(.secondary)
            Toggle("Made for kids", isOn: $model.draft.madeForKids)
            Text(PublishText.madeForKidsHelp).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.summary).font(.subheadline).accessibilityIdentifier("publish-summary")
            if let remaining = model.uploadsRemainingText {
                Text(remaining).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.validationError {
                Label(error, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
            ForEach(model.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let submitError {
                Text(submitError).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PublishText.certification).font(.caption).foregroundStyle(.secondary)
                    Link("YouTube Terms of Service", destination: AccountText.youtubeTermsURL).font(.caption)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Upload", action: upload)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!model.canUpload || isUploading)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var thumbnailPreview: some View {
        if model.draft.thumbnailAt != nil, let image = model.thumbnailImage {
            Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 96, height: 54)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { model.draft.tags.joined(separator: ", ") },
            set: { text in
                model.draft.tags = text.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            })
    }

    private var scheduleBinding: Binding<Bool> {
        Binding(
            get: { model.draft.publishAt != nil },
            set: { on in model.draft.publishAt = on ? Date().addingTimeInterval(3600) : nil })
    }

    private var thumbnailBinding: Binding<Bool> {
        Binding(
            get: { model.draft.thumbnailAt != nil },
            set: { on in model.draft.thumbnailAt = on ? model.playhead : nil })
    }

    private var playlistBinding: Binding<String> {
        Binding(get: { model.draft.playlistId ?? "" }, set: { model.draft.playlistId = $0.isEmpty ? nil : $0 })
    }

    static func renderLabel(_ render: RenderRecord) -> String {
        let name = render.outputURL?.lastPathComponent ?? render.id
        return "\(name) · \(render.preset.name) · v\(render.projectVersion)"
    }

    private func upload() {
        guard !isUploading else { return }
        isUploading = true
        submitError = nil
        let draft = model.draft
        Task {
            await onUpload(draft)
            isUploading = false
        }
    }
}
