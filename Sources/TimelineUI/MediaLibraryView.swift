import Contracts
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import TimelineCore

/// The library panel's state machine: the open project's live assets merged with everything the catalog
/// found in other projects and in the library itself, filtered by kind and scope, ranked by the search
/// field, and turned into drag payloads. Nothing here applies a command — a row leaves through
/// `LibraryDragItem` and the app decides what to import and insert
/// (`docs/plans/media-library.md` section 2.6).
@MainActor @Observable
public final class MediaLibraryModel {
    public enum KindFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
        case all
        case video
        case audio
        case image

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: "All"
            case .video: "Video"
            case .audio: "Audio"
            case .image: "Images"
            }
        }

        var assetKind: AssetKind? {
            switch self {
            case .all: nil
            case .video: .video
            case .audio: .audio
            case .image: .image
            }
        }
    }

    public enum Scope: String, Hashable, Sendable, CaseIterable, Identifiable {
        case thisProject
        case allProjects

        public var id: String { rawValue }

        public var title: String { self == .thisProject ? "This project" : "All projects" }
    }

    /// One row: the item, plus what the panel needs to draw and to refuse a drag.
    public struct Row: Identifiable, Hashable, Sendable {
        public var item: CatalogItem
        /// The open project already holds this content hash, so a drop adds a clip and no command.
        public var isInProject: Bool
        /// The file is not where it should be; the row is badged and cannot be dragged.
        public var isOffline: Bool
        /// Where the file should be, resolved against the owning project's library root.
        public var url: URL
        /// The search score, for tests and for a stable order.
        public var score: Int

        public var id: String { item.id }
        public var asset: Asset { item.asset }

        /// Nil for an item that belongs to the open project or to no project at all.
        public var foreignProjectName: String? { item.projectId == nil ? nil : item.projectName }
    }

    /// How the three searchable fields are weighted against each other (`conventions.md`).
    public struct FieldWeights: Hashable, Sendable {
        public var displayName = 1.0
        public var projectName = 0.6
        /// The directory part of `libraryPath`, so a date folder or a card name is searchable.
        public var folder = 0.5

        public init() {}

        public static let `default` = FieldWeights()
    }

    public let viewModel: TimelineViewModel
    public let catalog: any MediaCatalog
    /// This machine's root, used for items whose project recorded no root hint.
    public let layout: LibraryLayout
    public let thumbnails: LibraryThumbnailCache
    public var weights = FieldWeights.default

    public var query = ""
    public var kindFilter = KindFilter.all
    public var scope = Scope.allProjects
    public var selection: Set<String> = []

    /// Items from every project but the open one, plus library media, as of the last load.
    public private(set) var catalogItems: [CatalogItem] = []
    public private(set) var projects: [CatalogProject] = []
    /// Content hashes whose file was not where the catalog said; recomputed on each load.
    public private(set) var missingHashes: Set<String> = []
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    public private(set) var loadCount = 0
    /// Bumped when a poster lands, so a row that drew a placeholder redraws with the picture.
    public private(set) var posterGeneration = 0

    /// Injected so a test can describe a machine where a file is missing without touching the disk.
    private let fileExists: @Sendable (URL) -> Bool

    public init(
        viewModel: TimelineViewModel, catalog: any MediaCatalog, layout: LibraryLayout = .default,
        thumbnails: (any ThumbnailProvider)? = nil,
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.viewModel = viewModel
        self.catalog = catalog
        self.layout = layout
        self.thumbnails = LibraryThumbnailCache(thumbnails: thumbnails)
        self.fileExists = fileExists
        self.thumbnails.onUpdate = { [weak self] in self?.posterGeneration += 1 }
    }

    // MARK: Loading

    /// Rescans the catalog and re-reads it. The open project is always excluded: its database churns
    /// while it is edited, and its assets come straight from the live document.
    public func load(rescan: Bool = true) async {
        isLoading = true
        defer { isLoading = false }
        do {
            if rescan { _ = try await catalog.refresh() }
            projects = try await catalog.projects()
            catalogItems = try await catalog.items(excluding: [viewModel.project.id])
            missingHashes = Set(
                catalogItems.filter { !fileExists($0.url(defaultRoot: layout.root)) }.map(\.contentHash))
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        loadCount += 1
    }

    // MARK: Rows

    /// The open project's assets as catalog items. These come from the live document, never the catalog,
    /// so the panel is never stale about the project being edited.
    public var openProjectItems: [CatalogItem] {
        let project = viewModel.project
        return project.assets.values.map {
            CatalogItem(
                asset: $0, projectId: project.id, projectName: project.name, libraryRoot: layout.root)
        }
    }

    /// Every item in scope, filtered by kind and query, best match first.
    public var rows: [Row] {
        let hashes = Set(viewModel.project.assets.values.map(\.contentHash))
        let items = scope == .thisProject ? openProjectItems : openProjectItems + catalogItems
        var rows: [Row] = []
        rows.reserveCapacity(items.count)
        for item in items {
            // Media the open project holds is not library-only, however recently the catalog was scanned.
            if item.projectId == nil, hashes.contains(item.contentHash) { continue }
            guard kindFilter.assetKind == nil || item.asset.kind == kindFilter.assetKind else { continue }
            guard let score = score(item) else { continue }
            let url = item.url(defaultRoot: layout.root)
            rows.append(
                Row(
                    item: item, isInProject: hashes.contains(item.contentHash),
                    isOffline: item.asset.offline || missingHashes.contains(item.contentHash), url: url,
                    score: score))
        }
        return rows.sorted(by: MediaLibraryModel.isOrderedBefore)
    }

    /// The best of the three fields, weighted. A row matches when any of them does.
    func score(_ item: CatalogItem) -> Int? {
        var best: Int?
        func consider(_ text: String?, _ weight: Double) {
            guard let text, !text.isEmpty, let score = FuzzyMatch.score(query, in: text) else { return }
            let weighted = Int((Double(score) * weight).rounded())
            if best == nil || weighted > best! { best = weighted }
        }
        consider(item.asset.displayName, weights.displayName)
        consider(item.projectName, weights.projectName)
        consider(MediaLibraryModel.folder(of: item.asset.libraryPath), weights.folder)
        return best
    }

    /// The directory part of a library path, which is the date folder for a copied original.
    static func folder(of libraryPath: String) -> String {
        let components = libraryPath.split(separator: "/").dropLast()
        return components.joined(separator: "/")
    }

    /// Score, then recency, then name, then hash: a total order, so two loads list the same way.
    static func isOrderedBefore(_ a: Row, _ b: Row) -> Bool {
        if a.score != b.score { return a.score > b.score }
        let left = a.item.addedAt ?? .distantPast
        let right = b.item.addedAt ?? .distantPast
        if left != right { return left > right }
        if a.asset.displayName != b.asset.displayName { return a.asset.displayName < b.asset.displayName }
        if a.asset.contentHash != b.asset.contentHash { return a.asset.contentHash < b.asset.contentHash }
        return a.id < b.id
    }

    // MARK: Dragging and inserting

    /// The payload for a drag or an insert, or nil when the row's file is missing.
    public func dragItem(for row: Row) -> LibraryDragItem? {
        guard !row.isOffline else { return nil }
        return LibraryDragItem(row.asset, projectId: row.item.projectId, url: row.url)
    }

    /// The rows named by `ids` (a selection), in list order, skipping any that cannot be dragged.
    public func dragItems(_ ids: Set<String>) -> [LibraryDragItem] {
        rows.filter { ids.contains($0.id) }.compactMap { dragItem(for: $0) }
    }

    public func payload(_ ids: Set<String>) -> LibraryDragPayload { LibraryDragPayload(items: dragItems(ids)) }

    /// The poster frame for a row, or nil while it is being fetched (the row draws a placeholder).
    public func poster(for row: Row, height: Int = 36) -> CGImage? {
        _ = posterGeneration  // observed, so a landed fetch redraws the row
        guard !row.isOffline else { return nil }
        return thumbnails.poster(
            for: MediaReference(url: row.url, contentHash: row.asset.contentHash), kind: row.asset.kind,
            duration: row.asset.duration, height: height)
    }
}

/// The media library pane: search, kind and scope filters, and one row per browsable file. Rows drag
/// onto the timeline (and onto the agent pane, which stages the path instead of importing); Return and
/// the context menu insert the selection at the playhead without a drag.
public struct MediaLibraryView: View {
    public let model: MediaLibraryModel
    /// Insert these items at the playhead (double-click, Return, or the context menu).
    public var onInsert: ([LibraryDragItem]) -> Void
    /// Open the import panel; the files land in the library, not on the timeline.
    public var onImport: () -> Void

    public init(
        model: MediaLibraryModel, onInsert: @escaping ([LibraryDragItem]) -> Void, onImport: @escaping () -> Void
    ) {
        self.model = model
        self.onInsert = onInsert
        self.onImport = onImport
    }

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            header(model: $model)
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).padding(.horizontal, 8)
            }
            list(model: $model)
        }
        .padding(.top, 6)
        .task { await model.load() }
    }

    private func header(model: Bindable<MediaLibraryModel>) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                // Not `.searchable`: the pane is a plain split-view column, not a navigation column.
                TextField("Search media", text: model.query).textFieldStyle(.roundedBorder)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await self.model.load() } }
                    .labelStyle(.iconOnly).disabled(self.model.isLoading)
                Button("Import…", systemImage: "square.and.arrow.down") { onImport() }
                    .labelStyle(.iconOnly)
            }
            Picker("Kind", selection: model.kindFilter) {
                ForEach(MediaLibraryModel.KindFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker("Scope", selection: model.scope) {
                ForEach(MediaLibraryModel.Scope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        .padding(.horizontal, 8)
    }

    private func list(model: Bindable<MediaLibraryModel>) -> some View {
        let rows = self.model.rows
        return Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    self.model.query.isEmpty ? "No media" : "No matches",
                    systemImage: "rectangle.stack",
                    description: Text(
                        self.model.query.isEmpty
                            ? "Import files to add them to the library" : "Nothing matches “\(self.model.query)”"))
            } else {
                List(rows, selection: model.selection) { row in
                    MediaLibraryRow(model: self.model, row: row)
                        .contentShape(.rect)
                        // No tap gesture on a row, ever. A `TapGesture` — `onTapGesture(count: 2)`,
                        // simultaneous or not — consumes the row's mouse-down, and the row then neither
                        // selects nor starts its drag: the panel looks dead and nothing can be dragged out
                        // of it. Return and the context menu insert instead.
                        .draggable(self.model.payload(dragged(row))) {
                            Label(row.asset.displayName, systemImage: "film")
                        }
                        .contextMenu {
                            Button("Insert at playhead") { insert([row]) }
                            Button("Add to project") { insert([row]) }
                                .disabled(row.isInProject)
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                                .disabled(row.isOffline)
                            Button("Copy content hash") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(row.asset.contentHash, forType: .string)
                            }
                        }
                }
                .listStyle(.inset)
                .onKeyPress(.return) {
                    let items = self.model.dragItems(self.model.selection)
                    guard !items.isEmpty else { return .ignored }
                    onInsert(items)
                    return .handled
                }
            }
        }
        // Both branches must fill the pane. `List` does on its own but `ContentUnavailableView` sizes to
        // its content, so without this the pane collapses to the empty state's intrinsic size the moment a
        // filter matches nothing — and the split view hands the slack to its siblings, resizing the window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A drag that starts on a selected row carries the whole selection; otherwise just that row.
    private func dragged(_ row: MediaLibraryModel.Row) -> Set<String> {
        model.selection.contains(row.id) ? model.selection : [row.id]
    }

    private func insert(_ rows: [MediaLibraryModel.Row]) {
        let items = rows.compactMap { model.dragItem(for: $0) }
        guard !items.isEmpty else { return }
        onInsert(items)
    }
}

/// One row: poster, name, and a caption line naming the duration, the kind, and — for media the open
/// project does not own — the project it came from.
struct MediaLibraryRow: View {
    let model: MediaLibraryModel
    let row: MediaLibraryModel.Row

    var body: some View {
        HStack(spacing: 8) {
            poster
            VStack(alignment: .leading, spacing: 2) {
                Text(row.asset.displayName).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(Timecode.label(seconds: row.asset.duration.seconds, interval: 1, frameDuration: second))
                    Text(row.asset.kind.rawValue)
                    if let project = row.foreignProjectName { Text("· \(project)") }
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if row.isOffline {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("The file is missing")
            } else if row.isInProject {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help("Already in this project")
            }
        }
        .padding(.vertical, 2)
    }

    private var second: RationalTime { RationalTime(1, 1) }

    @ViewBuilder private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary)
            if let image = model.poster(for: row) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                // Audio never has a poster, and a video's is drawn as soon as the fetch lands.
                Image(systemName: row.asset.kind == .audio ? "waveform" : "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
