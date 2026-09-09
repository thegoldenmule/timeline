import AppKit
import Contracts
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import TimelineCore
import UniformTypeIdentifiers

/// One file staged for the next agent message. Nothing is imported and no command is applied: the
/// message names the path and the agent decides for itself whether to import it
/// (`docs/design/integration.md`, the agent panel).
public struct AgentAttachment: Identifiable, Hashable, Sendable {
    /// The path, standardized, so the same file cannot be staged twice.
    public var id: String { url.path }
    public var url: URL
    public var displayName: String
    /// Nil when the file is not media the app recognises; the chip then draws a plain document.
    public var kind: AssetKind?
    /// Known for a library row, unknown for a file dragged in from the Finder.
    public var duration: RationalTime?
    public var contentHash: String?
    /// The open project already holds this content hash.
    public var isInProject: Bool
    /// The project the row came from, when it was not the open one.
    public var projectName: String?
    /// The file was not where the drop said it was; the chip is badged and the message says so.
    public var isMissing: Bool

    public init(
        url: URL, displayName: String? = nil, kind: AssetKind? = nil, duration: RationalTime? = nil,
        contentHash: String? = nil, isInProject: Bool = false, projectName: String? = nil, isMissing: Bool = false
    ) {
        self.url = url.standardizedFileURL
        self.displayName = displayName ?? self.url.lastPathComponent
        self.kind = kind
        self.duration = duration
        self.contentHash = contentHash
        self.isInProject = isInProject
        self.projectName = projectName
        self.isMissing = isMissing
    }

    /// The caption under the name: what the agent is being handed, in the fewest words that still say it.
    public var detail: String {
        var parts: [String] = []
        if let kind { parts.append(kind.rawValue) } else { parts.append(url.pathExtension.lowercased()) }
        if let duration, duration.isPositive {
            parts.append(Timecode.label(seconds: duration.seconds, interval: 1, frameDuration: RationalTime(1, 1)))
        }
        if isMissing { parts.append("missing") } else if let projectName { parts.append(projectName) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The line this attachment contributes to the sent message.
    public var messageLine: String {
        var notes: [String] = []
        if let kind { notes.append(kind.rawValue) }
        if let duration, duration.isPositive { notes.append(String(format: "%.2fs", duration.seconds)) }
        if let contentHash { notes.append("sha256 \(contentHash.prefix(12))") }
        if isInProject { notes.append("already in this project") }
        if isMissing { notes.append("FILE NOT FOUND") }
        let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"
        return "- \(url.path)\(suffix)"
    }
}

/// What the human is about to say to the agent: the draft text and the files staged with it. Held by the
/// app across sessions, so attachments survive a session that finishes and the next message starts a new
/// one. Staging is deliberately inert — `MediaImporter` is never reached from here.
@MainActor @Observable
public final class AgentComposer {
    public var draft = ""
    public private(set) var attachments: [AgentAttachment] = []
    /// A drag is over the agent pane. The whole pane is the target — the transcript as much as the
    /// message box — and the box draws the highlight wherever in the pane the pointer is.
    public var isDropTargeted = false
    /// Posters for the chips, on the same cache the library panel uses, so a file both panes show is
    /// fetched once.
    public let thumbnails: LibraryThumbnailCache
    /// Bumped when a poster lands, so a chip that drew a placeholder redraws with the picture.
    public private(set) var posterGeneration = 0

    private let fileExists: @Sendable (URL) -> Bool

    public init(
        thumbnails: (any ThumbnailProvider)? = nil,
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.thumbnails = LibraryThumbnailCache(thumbnails: thumbnails)
        self.fileExists = fileExists
        self.thumbnails.onUpdate = { [weak self] in self?.posterGeneration += 1 }
    }

    public var isEmpty: Bool { attachments.isEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A message with attachments and no text is worth sending: the paths are the message.
    public var canSend: Bool { !isEmpty }

    // MARK: Staging

    /// Stages library rows. A row whose file has gone missing is still staged, badged, so the agent hears
    /// about it rather than the drop failing silently. Returns how many were new.
    @discardableResult
    public func add(libraryItems: [LibraryDragItem]) -> Int {
        add(
            libraryItems.compactMap { item in
                guard let url = item.url else { return nil }
                return AgentAttachment(
                    url: url, displayName: item.displayName, kind: item.kind, duration: item.duration,
                    contentHash: item.contentHash, isInProject: item.assetId != nil && item.projectId == nil,
                    isMissing: !fileExists(url))
            })
    }

    /// Stages files dropped from the Finder or chosen in the attach panel. Anything is allowed: the agent
    /// reads scripts and notes as happily as it imports media.
    @discardableResult
    public func add(urls: [URL]) -> Int {
        add(
            urls.map { url in
                AgentAttachment(url: url, kind: MediaFileTypes.kind(of: url), isMissing: !fileExists(url))
            })
    }

    @discardableResult
    private func add(_ staged: [AgentAttachment]) -> Int {
        var added = 0
        for attachment in staged where !attachments.contains(where: { $0.id == attachment.id }) {
            attachments.append(attachment)
            added += 1
        }
        return added
    }

    public func remove(_ id: AgentAttachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    public func removeAllAttachments() {
        attachments.removeAll()
    }

    // MARK: Sending

    /// The message the agent receives: what was typed, then the staged paths under a line that says
    /// plainly that nothing was imported.
    public static func message(draft: String, attachments: [AgentAttachment]) -> String {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return text }
        let header =
            "Attached \(attachments.count) file\(attachments.count == 1 ? "" : "s") — staged in the app, not "
            + "imported. Import them yourself if you need them:"
        let lines = attachments.map(\.messageLine).joined(separator: "\n")
        return text.isEmpty ? "\(header)\n\(lines)" : "\(text)\n\n\(header)\n\(lines)"
    }

    public var message: String { AgentComposer.message(draft: draft, attachments: attachments) }

    /// The message to send, clearing the composer. Nil when there was nothing to send.
    public func take() -> String? {
        guard canSend else { return nil }
        let text = message
        draft = ""
        attachments.removeAll()
        return text
    }

    // MARK: Dropping

    /// The types the agent pane accepts: a library row's own payload, and any file.
    public static let dropTypes = [LibraryDragPayload.typeIdentifier, UTType.fileURL.identifier]

    /// Reads a drop: library rows carry their own payload, everything else arrives as a file URL. Returns
    /// false when the drop held neither, so the pane refuses it rather than swallowing it.
    @discardableResult
    public func stage(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(LibraryDragPayload.typeIdentifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: LibraryDragPayload.typeIdentifier) { data, _ in
                    guard let data, let payload = try? LibraryDragPayload(data: data) else { return }
                    Task { @MainActor [weak self] in self?.add(libraryItems: payload.items) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor [weak self] in self?.add(urls: [url]) }
                }
            }
        }
        return handled
    }

    // MARK: Drawing

    /// The poster for a chip, or nil while it is being fetched. Only a staged library row has one: a file
    /// from the Finder has no content hash, and the chip draws its kind instead.
    public func poster(for attachment: AgentAttachment, height: Int = 32) -> CGImage? {
        _ = posterGeneration  // observed, so a landed fetch redraws the chip
        guard !attachment.isMissing, let hash = attachment.contentHash, let kind = attachment.kind else { return nil }
        return thumbnails.poster(
            for: MediaReference(url: attachment.url, contentHash: hash), kind: kind,
            duration: attachment.duration ?? .zero, height: height)
    }
}

/// The agent's input: the staged attachments, the message field, and Send. Files dropped here are staged,
/// never imported — the library pane and the timeline are where a drop imports.
public struct AgentComposerView: View {
    public let composer: AgentComposer
    /// A turn is in flight; Send waits rather than queueing a second message.
    public var isBusy: Bool
    public var placeholder: String
    public var onSend: (String) -> Void
    /// Opens the app's file panel; nil hides the paperclip.
    public var onAttach: (() -> Void)?

    @FocusState private var isFocused: Bool

    public init(
        composer: AgentComposer, isBusy: Bool = false, placeholder: String = "Message the agent",
        onSend: @escaping (String) -> Void, onAttach: (() -> Void)? = nil
    ) {
        self.composer = composer
        self.isBusy = isBusy
        self.placeholder = placeholder
        self.onSend = onSend
        self.onAttach = onAttach
    }

    public var body: some View {
        @Bindable var composer = composer
        VStack(alignment: .leading, spacing: 6) {
            if !self.composer.attachments.isEmpty { attachmentStrip }
            HStack(alignment: .bottom, spacing: 6) {
                if let onAttach {
                    Button("Attach files", systemImage: "paperclip") { onAttach() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Stage files for the next message")
                }
                TextField(placeholder, text: $composer.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .onSubmit(send)
                Button("Send", systemImage: isBusy ? "ellipsis" : "arrow.up.circle.fill") { send() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.title3)
                    .disabled(!self.composer.canSend || isBusy)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(isBusy ? "The agent is working" : "Send (⌘↩)")
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isTargeted ? 2 : 1)
        )
        .padding(8)
    }

    private var isTargeted: Bool { composer.isDropTargeted }

    private var attachmentStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The count and Clear stay put; the chips themselves scroll when there are more than fit.
            HStack(spacing: 6) {
                Text(
                    "\(composer.attachments.count) attachment\(composer.attachments.count == 1 ? "" : "s") · paths "
                        + "only, nothing is imported"
                )
                .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Clear") { composer.removeAllAttachments() }
                    .buttonStyle(.borderless).font(.caption2).help("Remove every attachment")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(composer.attachments) { attachment in
                        AgentAttachmentChip(composer: composer, attachment: attachment) {
                            composer.remove(attachment.id)
                        }
                    }
                }
                .padding(.bottom, 2)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 46)
        }
    }

    private func send() {
        guard !isBusy, let message = composer.take() else { return }
        onSend(message)
    }

}

/// One staged file: its poster or kind, its name, and the button that unstages it.
struct AgentAttachmentChip: View {
    let composer: AgentComposer
    let attachment: AgentAttachment
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            poster
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName).font(.caption).lineLimit(1).truncationMode(.middle)
                Text(attachment.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Remove", systemImage: "xmark.circle.fill") { onRemove() }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
        }
        .padding(.leading, 3)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(attachment.isMissing ? Color.orange : Color.clear, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .help(attachment.isMissing ? "\(attachment.url.path) — the file is missing" : attachment.url.path)
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.quinary)
            if let image = composer.poster(for: attachment) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol).font(.caption).foregroundStyle(attachment.isMissing ? .orange : .secondary)
            }
        }
        .frame(width: 40, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var symbol: String {
        if attachment.isMissing { return "exclamationmark.triangle" }
        switch attachment.kind {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case nil: return "doc"
        }
    }
}

/// Makes a whole view the agent's attachment target: anything dropped on it — a library row, a file from
/// the Finder — is staged on `composer` and nothing is imported. Put it on the pane, not on the message
/// box: a clip dragged at the transcript is aimed at the agent just as squarely as one dragged at the
/// field.
public struct AgentAttachmentTarget: ViewModifier {
    public let composer: AgentComposer

    public init(composer: AgentComposer) { self.composer = composer }

    public func body(content: Content) -> some View {
        @Bindable var composer = composer
        content
            .onDrop(of: AgentComposer.dropTypes, isTargeted: $composer.isDropTargeted) { providers in
                composer.stage(providers)
            }
            .overlay {
                if composer.isDropTargeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                        Label("Attach to the message — not imported", systemImage: "paperclip")
                            .font(.caption).padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// See `AgentAttachmentTarget`.
    public func agentAttachmentTarget(_ composer: AgentComposer) -> some View {
        modifier(AgentAttachmentTarget(composer: composer))
    }
}
