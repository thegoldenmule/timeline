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

    /// Looks a dropped path up in the media library. A library drag reaches the pane as a bare file URL
    /// (its payload arrives empty, see `dropTypes`), and this is what gives the chip back its kind,
    /// duration, and poster rather than staging a nameless path.
    public var resolve: ((URL) -> LibraryDragItem?)?

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
        var staged: [AgentAttachment] = []
        var rows: [LibraryDragItem] = []
        for url in urls {
            if let row = resolve?(url) {
                rows.append(row)
            } else {
                staged.append(
                    AgentAttachment(url: url, kind: MediaFileTypes.kind(of: url), isMissing: !fileExists(url)))
            }
        }
        return add(libraryItems: rows) + add(staged)
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

    /// The types the agent pane accepts, as raw pasteboard types. Not `UTType`, and not SwiftUI's
    /// `onDrop`: `LibraryDragPayload.contentType` is exported by the process but declared in no
    /// Info.plist (an SPM executable has none), so the system resolves neither its identifier nor any
    /// conformance — `UTType(LibraryDragPayload.typeIdentifier)` is nil and it reports no conformance to
    /// `.data`. SwiftUI's drop machinery then quietly registers nothing and the pane never highlights.
    /// AppKit takes the raw type, which is what `TimelineMetalView` has always done.
    public static let dropTypes: [NSPasteboard.PasteboardType] = [LibraryDragPayload.pasteboardType, .fileURL]

    /// The library rows on a drag's pasteboard, if it carries the library type.
    public static func libraryItems(on pasteboard: NSPasteboard) -> [LibraryDragItem] {
        guard let data = pasteboard.data(forType: LibraryDragPayload.pasteboardType),
            let payload = try? LibraryDragPayload(data: data)
        else { return [] }
        return payload.items
    }

    /// The file URLs on a drag's pasteboard.
    public static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Whether a drag carrying this pasteboard has anything the pane would stage.
    public static func accepts(_ pasteboard: NSPasteboard) -> Bool {
        !libraryItems(on: pasteboard).isEmpty || !fileURLs(on: pasteboard).isEmpty
    }

    /// Stages everything on a dropped pasteboard. Library rows are read before file URLs: a row also
    /// offers a `.fileURL` representation so a drag to the Finder works, and only the library branch
    /// knows the duration, the kind, and which project the media came from. False when it held neither.
    @discardableResult
    public func stage(_ pasteboard: NSPasteboard) -> Bool {
        let items = AgentComposer.libraryItems(on: pasteboard)
        if !items.isEmpty {
            add(libraryItems: items)
            return true
        }
        let urls = AgentComposer.fileURLs(on: pasteboard)
        guard !urls.isEmpty else { return false }
        add(urls: urls)
        return true
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

/// Hosts the agent pane inside an AppKit view registered for the attachment types, so anything dropped
/// anywhere on the pane — a library row, a file from the Finder — is staged on `composer` and nothing is
/// imported.
///
/// Why an `NSHostingView` and not `onDrop` or a background view. `LibraryDragPayload.contentType` is
/// exported by the process but declared in no Info.plist (an SPM executable has none), so the system
/// resolves neither its identifier nor any conformance — `UTType(LibraryDragPayload.typeIdentifier)` is
/// nil and it reports no conformance to `.data` — and SwiftUI's drop machinery quietly registers nothing.
/// AppKit takes the raw pasteboard type, which is what `TimelineMetalView` has always done. But AppKit
/// finds a drag's destination by hit-testing the pointer and walking *up* the superview chain, so a
/// registered view merely sitting behind the content is never reached: it has to be the content's
/// ancestor, which is what this is.
public struct AgentDropHost<Content: View>: NSViewRepresentable {
    public let composer: AgentComposer
    public let content: Content

    public init(composer: AgentComposer, @ViewBuilder content: () -> Content) {
        self.composer = composer
        self.content = content()
    }

    public func makeNSView(context: Context) -> AgentDropTargetView {
        let view = AgentDropTargetView(composer: composer)
        view.install(NSHostingView(rootView: AnyView(decorated)))
        return view
    }

    public func updateNSView(_ view: AgentDropTargetView, context: Context) {
        view.composer = composer
        view.hosting?.rootView = AnyView(decorated)
    }

    /// The pane with its drag highlight, drawn inside the hosting view so it tracks `isDropTargeted`.
    private var decorated: some View {
        content
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
    /// See `AgentDropHost`.
    public func agentAttachmentTarget(_ composer: AgentComposer) -> some View {
        AgentDropHost(composer: composer) { self }
    }
}

/// The pane's drop target: an `NSView` registered for the attachment types that hosts the pane's own
/// content, so AppKit's hit-test-then-walk-up search for a drag destination reaches it from anywhere in
/// the pane. See `AgentDropHost`.
public final class AgentDropTargetView: NSView {
    public weak var composer: AgentComposer?
    var hosting: NSHostingView<AnyView>?

    public init(composer: AgentComposer?) {
        self.composer = composer
        super.init(frame: .zero)
        registerForDraggedTypes(AgentComposer.dropTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func install(_ view: NSHostingView<AnyView>) {
        hosting = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    public override var intrinsicContentSize: NSSize {
        hosting?.intrinsicContentSize ?? super.intrinsicContentSize
    }

    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard AgentComposer.accepts(sender.draggingPasteboard) else {
            composer?.isDropTargeted = false
            return []
        }
        composer?.isDropTargeted = true
        return .copy
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(sender) }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(sender) }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) { composer?.isDropTargeted = false }

    public override func draggingEnded(_ sender: any NSDraggingInfo) { composer?.isDropTargeted = false }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        composer?.isDropTargeted = false
        return composer?.stage(sender.draggingPasteboard) ?? false
    }
}
