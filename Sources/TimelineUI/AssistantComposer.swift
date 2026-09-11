import AppKit
import Contracts
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import TimelineCore
import UniformTypeIdentifiers

/// One file staged for the next assistant message. Nothing is imported and no command is applied: the
/// message names the path and the assistant decides for itself whether to import it
/// (`docs/design/integration.md`, the assistant panel).
public struct AssistantAttachment: Identifiable, Hashable, Sendable {
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

    /// The caption under the name: what the assistant is being handed, in the fewest words that still say it.
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

/// What the human is about to say to the assistant: the draft text and the files staged with it. Held by the
/// app across sessions, so attachments survive a session that finishes and the next message starts a new
/// one. Staging is deliberately inert — `MediaImporter` is never reached from here.
@MainActor @Observable
public final class AssistantComposer {
    public var draft = ""
    public private(set) var attachments: [AssistantAttachment] = []
    /// A drag is over the assistant panel. The whole panel is the target — the transcript as much as the
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

    /// Stages library rows. A row whose file has gone missing is still staged, badged, so the assistant hears
    /// about it rather than the drop failing silently. Returns how many were new.
    @discardableResult
    public func add(libraryItems: [LibraryDragItem]) -> Int {
        add(
            libraryItems.compactMap { item in
                guard let url = item.url else { return nil }
                return AssistantAttachment(
                    url: url, displayName: item.displayName, kind: item.kind, duration: item.duration,
                    contentHash: item.contentHash, isInProject: item.assetId != nil && item.projectId == nil,
                    isMissing: !fileExists(url))
            })
    }

    /// Stages files dropped from the Finder or chosen in the attach panel. Anything is allowed: the assistant
    /// reads scripts and notes as happily as it imports media.
    @discardableResult
    public func add(urls: [URL]) -> Int {
        var staged: [AssistantAttachment] = []
        var rows: [LibraryDragItem] = []
        for url in urls {
            if let row = resolve?(url) {
                rows.append(row)
            } else {
                staged.append(
                    AssistantAttachment(url: url, kind: MediaFileTypes.kind(of: url), isMissing: !fileExists(url)))
            }
        }
        return add(libraryItems: rows) + add(staged)
    }

    @discardableResult
    private func add(_ staged: [AssistantAttachment]) -> Int {
        var added = 0
        for attachment in staged where !attachments.contains(where: { $0.id == attachment.id }) {
            attachments.append(attachment)
            added += 1
        }
        return added
    }

    public func remove(_ id: AssistantAttachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    public func removeAllAttachments() {
        attachments.removeAll()
    }

    // MARK: Sending

    /// The message the assistant receives: what was typed, then the staged paths under a line that says
    /// plainly that nothing was imported.
    public static func message(draft: String, attachments: [AssistantAttachment]) -> String {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return text }
        let header =
            "Attached \(attachments.count) file\(attachments.count == 1 ? "" : "s") — staged in the app, not "
            + "imported. Import them yourself if you need them:"
        let lines = attachments.map(\.messageLine).joined(separator: "\n")
        return text.isEmpty ? "\(header)\n\(lines)" : "\(text)\n\n\(header)\n\(lines)"
    }

    public var message: String { AssistantComposer.message(draft: draft, attachments: attachments) }

    /// The message to send, clearing the composer. Nil when there was nothing to send.
    public func take() -> String? {
        guard canSend else { return nil }
        let text = message
        draft = ""
        attachments.removeAll()
        return text
    }

    // MARK: Dropping

    /// The types the assistant panel accepts, as raw pasteboard types. Not `UTType`, and not SwiftUI's
    /// `onDrop`: `LibraryDragPayload.contentType` is exported by the process but declared in no
    /// Info.plist (an SPM executable has none), so the system resolves neither its identifier nor any
    /// conformance — `UTType(LibraryDragPayload.typeIdentifier)` is nil and it reports no conformance to
    /// `.data`. SwiftUI's drop machinery then quietly registers nothing and the pane never highlights.
    /// AppKit takes the raw type, which is what `TimelineMetalView` has always done.
    public static let dropTypes: [NSPasteboard.PasteboardType] = [LibraryDragPayload.pasteboardType, .fileURL]

    /// The library rows a drag is carrying (`LibraryDragPayload.items(on:)`: the in-process handoff
    /// first, the pasteboard second).
    public static func libraryItems(on pasteboard: NSPasteboard) -> [LibraryDragItem] {
        LibraryDragPayload.items(on: pasteboard)
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
        let items = AssistantComposer.libraryItems(on: pasteboard)
        LibraryDragPayload.endInFlight()
        if !items.isEmpty {
            add(libraryItems: items)
            return true
        }
        let urls = AssistantComposer.fileURLs(on: pasteboard)
        guard !urls.isEmpty else { return false }
        add(urls: urls)
        return true
    }

    // MARK: Drawing

    /// The poster for a chip, or nil while it is being fetched. Only a staged library row has one: a file
    /// from the Finder has no content hash, and the chip draws its kind instead.
    public func poster(for attachment: AssistantAttachment, height: Int = 32) -> CGImage? {
        _ = posterGeneration  // observed, so a landed fetch redraws the chip
        guard !attachment.isMissing, let hash = attachment.contentHash, let kind = attachment.kind else { return nil }
        return thumbnails.poster(
            for: MediaReference(url: attachment.url, contentHash: hash), kind: kind,
            duration: attachment.duration ?? .zero, height: height)
    }
}

/// The assistant's input: the staged attachments, the message field, and Send. Files dropped here are staged,
/// never imported — the library pane and the timeline are where a drop imports.
public struct AssistantComposerView: View {
    public let composer: AssistantComposer
    /// A turn is in flight; Send waits rather than queueing a second message.
    public var isBusy: Bool
    public var placeholder: String
    public var onSend: (String) -> Void
    /// Opens the app's file panel; nil hides the paperclip.
    public var onAttach: (() -> Void)?

    @FocusState private var isFocused: Bool

    public init(
        composer: AssistantComposer, isBusy: Bool = false, placeholder: String = "Message the assistant",
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
        VStack(alignment: .leading, spacing: PanelTheme.controlGap) {
            if !self.composer.attachments.isEmpty { attachmentStrip }
            HStack(alignment: .bottom, spacing: PanelTheme.controlGap) {
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
                    .help(isBusy ? "The assistant is working" : "Send (⌘↩)")
            }
        }
        .padding(PanelTheme.panelInset)
        .background(
            RoundedRectangle(cornerRadius: PanelTheme.bubbleRadius).fill(PanelTheme.fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PanelTheme.bubbleRadius)
                .strokeBorder(
                    isTargeted ? PanelTheme.borderActive : PanelTheme.borderIdle,
                    lineWidth: isTargeted ? PanelTheme.borderWidthActive : PanelTheme.borderWidth)
        )
        .padding(PanelTheme.panelInset)
    }

    private var isTargeted: Bool { composer.isDropTargeted }

    private var attachmentStrip: some View {
        VStack(alignment: .leading, spacing: PanelTheme.rowGap) {
            // The count and Clear stay put; the chips themselves scroll when there are more than fit.
            HStack(spacing: PanelTheme.controlGap) {
                Text(
                    "\(composer.attachments.count) attachment\(composer.attachments.count == 1 ? "" : "s") · paths "
                        + "only, nothing is imported"
                )
                .font(PanelTheme.detail).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Clear") { composer.removeAllAttachments() }
                    .buttonStyle(.borderless).font(PanelTheme.detail).help("Remove every attachment")
            }
            ScrollView(.horizontal) {
                HStack(spacing: PanelTheme.controlGap) {
                    ForEach(composer.attachments) { attachment in
                        AssistantAttachmentChip(composer: composer, attachment: attachment) {
                            composer.remove(attachment.id)
                        }
                    }
                }
                .padding(.bottom, PanelTheme.hairGap)
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
struct AssistantAttachmentChip: View {
    /// See `MediaLibraryRow`: the poster is asked for in pixels, not points.
    @Environment(\.displayScale) private var displayScale
    let composer: AssistantComposer
    let attachment: AssistantAttachment
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: PanelTheme.controlGap) {
            poster
            VStack(alignment: .leading, spacing: PanelTheme.hairGap) {
                Text(attachment.displayName).font(PanelTheme.caption).lineLimit(1).truncationMode(.middle)
                Text(attachment.detail).font(PanelTheme.detail).foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Remove", systemImage: "xmark.circle.fill") { onRemove() }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .help("Take \(attachment.displayName) off the message")
        }
        .padding(.horizontal, PanelTheme.rowGap)
        .padding(.vertical, PanelTheme.hairGap)
        .frame(maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: PanelTheme.chipRadius).fill(PanelTheme.chipFill))
        .overlay(
            RoundedRectangle(cornerRadius: PanelTheme.chipRadius)
                .strokeBorder(
                    attachment.isMissing ? PanelTheme.warning : Color.clear, lineWidth: PanelTheme.borderWidth)
        )
        .onHover { isHovering = $0 }
        .help(attachment.isMissing ? "\(attachment.url.path) — the file is missing" : attachment.url.path)
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PanelTheme.posterRadius).fill(PanelTheme.bubbleFill)
            if let image = composer.poster(for: attachment, height: posterPixelHeight) {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol).font(PanelTheme.caption).foregroundStyle(
                    attachment.isMissing ? .orange : .secondary)
            }
        }
        .frame(width: PanelTheme.chipPosterSize.width, height: PanelTheme.chipPosterSize.height)
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.posterRadius))
    }

    /// A staged file's shape is not known — it may not even be in the library yet — so the chip asks
    /// for enough to cover the box whatever turns up.
    private var posterPixelHeight: Int {
        PosterGeometry.pixelHeight(box: PanelTheme.chipPosterSize, aspect: nil, displayScale: displayScale)
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

/// Hosts the assistant panel inside an AppKit view registered for the attachment types, so anything dropped
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
public struct AssistantDropHost<Content: View>: NSViewRepresentable {
    public let composer: AssistantComposer
    public let content: Content

    public init(composer: AssistantComposer, @ViewBuilder content: () -> Content) {
        self.composer = composer
        self.content = content()
    }

    public func makeNSView(context: Context) -> AssistantDropTargetView {
        let view = AssistantDropTargetView(composer: composer)
        view.install(NSHostingView(rootView: AnyView(decorated)))
        return view
    }

    public func updateNSView(_ view: AssistantDropTargetView, context: Context) {
        view.composer = composer
        view.hosting?.rootView = AnyView(decorated)
    }

    /// Take the panel's size rather than the content's ideal. Without this the transcript's longest
    /// line, or the composer's placeholder, sets an ideal width for the whole panel — and a column
    /// narrower than that clips its content on both edges instead of wrapping it.
    public func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: AssistantDropTargetView, context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    /// The pane with its drag highlight, drawn inside the hosting view so it tracks `isDropTargeted`.
    private var decorated: some View {
        content
            .overlay {
                if composer.isDropTargeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: PanelTheme.bubbleRadius)
                            .strokeBorder(PanelTheme.borderActive, lineWidth: PanelTheme.borderWidthActive)
                        Label("Attach to the message — not imported", systemImage: "paperclip")
                            .font(PanelTheme.caption).padding(PanelTheme.panelInset)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PanelTheme.bubbleRadius))
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// See `AssistantDropHost`.
    public func assistantAttachmentTarget(_ composer: AssistantComposer) -> some View {
        AssistantDropHost(composer: composer) { self }
    }
}

/// The pane's drop target: an `NSView` registered for the attachment types that hosts the pane's own
/// content, so AppKit's hit-test-then-walk-up search for a drag destination reaches it from anywhere in
/// the pane. See `AssistantDropHost`.
public final class AssistantDropTargetView: NSView {
    public weak var composer: AssistantComposer?
    var hosting: NSHostingView<AnyView>?

    public init(composer: AssistantComposer?) {
        self.composer = composer
        super.init(frame: .zero)
        registerForDraggedTypes(AssistantComposer.dropTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func install(_ view: NSHostingView<AnyView>) {
        hosting = view
        // The four constraints below are the only thing that should size this: left to itself the
        // hosting view installs its own min/ideal/max, which is how the panel came to be wider than
        // the column it lives in.
        view.sizingOptions = []
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard AssistantComposer.accepts(sender.draggingPasteboard) else {
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
