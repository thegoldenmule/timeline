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

        /// The segmented control is symbols only: four words do not fit the narrowest the panel goes.
        public var symbolName: String {
            switch self {
            case .all: "square.grid.2x2"
            case .video: "film"
            case .audio: "waveform"
            case .image: "photo"
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
        /// The open project, so a row of its own media does not announce a project the human is
        /// already looking at.
        public var openProjectId: ProjectID?

        public var id: String { item.id }
        public var asset: Asset { item.asset }

        /// Nil for an item that belongs to the open project or to no project at all.
        public var foreignProjectName: String? {
            guard let projectId = item.projectId, projectId != openProjectId else { return nil }
            return item.projectName
        }
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
                    score: score, openProjectId: viewModel.project.id))
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

    /// The row for a path, if the library knows one. A drag that arrives as a bare file URL — which is
    /// what a library drag looks like once its promised payload comes back empty — is still a library row,
    /// and this is what recovers its duration, kind, and poster.
    public func dragItem(forPath path: String) -> LibraryDragItem? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let row = rows.first(where: { $0.url.standardizedFileURL.path == wanted }) else { return nil }
        return dragItem(for: row)
    }

    /// The rows named by `ids` (a selection), in list order, skipping any that cannot be dragged.
    public func dragItems(_ ids: Set<String>) -> [LibraryDragItem] {
        rows.filter { ids.contains($0.id) }.compactMap { dragItem(for: $0) }
    }

    public func payload(_ ids: Set<String>) -> LibraryDragPayload { LibraryDragPayload(items: dragItems(ids)) }

    /// The item provider a row's drag carries. It registers two things: the payload's bytes under the
    /// library type, and the file itself under `public.file-url`.
    ///
    /// The file URL is not a nicety. Everything a drag hands over goes through SwiftUI's provider
    /// bridge, which promises the bytes and resolves them asynchronously — by the time a drop asks
    /// `pasteboard.data(forType:)` it gets **zero bytes**, whatever the payload was, so both the timeline
    /// and the assistant panel refused every drop. The file URL is a type AppKit carries itself, so a drop
    /// always has at least the path to work with: the assistant stages it (a path is all it wanted) and
    /// the timeline imports it, which for library media is a content-hash hit and inserts the asset it
    /// already has.
    public func dragProvider(_ ids: Set<String>) -> NSItemProvider {
        let items = dragItems(ids)
        // The rows go across in-process, because nothing registered here can be relied on to have
        // resolved by the time a drop reads the pasteboard (`LibraryDragPayload.inFlight`).
        LibraryDragPayload.inFlight = LibraryDragPayload(items: items)
        // `NSItemProvider(contentsOf:)` is the canonical file drag; it is what another application gets.
        let provider = items.first?.url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        if let data = try? LibraryDragPayload(items: items).data() {
            provider.registerDataRepresentation(
                forTypeIdentifier: LibraryDragPayload.typeIdentifier, visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

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
/// onto the timeline (and onto the assistant panel, which stages the path instead of importing); Return and
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
        VStack(spacing: PanelTheme.controlGap) {
            filters(model: $model)
            if let error = model.lastError {
                Text(error).font(PanelTheme.caption).foregroundStyle(PanelTheme.danger).lineLimit(2)
                    .padding(.horizontal, PanelTheme.panelInset)
            }
            list(model: $model)
        }
        // The same gutter the composer and the inspector use, so the three line up across the window.
        .padding(.top, PanelTheme.panelInset)
        .task { await model.load() }
    }

    /// Search, then the kind filter. Scope is not here — it is a view option, so it lives in the panel
    /// header's controls (`MediaLibraryControls`), which keeps this to two rows at any panel width.
    private func filters(model: Bindable<MediaLibraryModel>) -> some View {
        VStack(spacing: PanelTheme.controlGap) {
            // Not `.searchable`: the panel is a plain column, not a navigation column. Hand-built
            // rather than `.roundedBorder` so it carries the magnifier and a clear button.
            HStack(spacing: PanelTheme.controlGap) {
                Image(systemName: "magnifyingglass").font(PanelTheme.caption).foregroundStyle(.secondary)
                TextField("Search media", text: model.query).textFieldStyle(.plain)
                if !self.model.query.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { self.model.query = "" }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.tertiary)
                        .help("Clear the search")
                }
            }
            .padding(.horizontal, PanelTheme.controlGap)
            .padding(.vertical, PanelTheme.rowGap)
            .background(RoundedRectangle(cornerRadius: PanelTheme.chipRadius).fill(PanelTheme.fieldFill))
            .overlay(
                RoundedRectangle(cornerRadius: PanelTheme.chipRadius)
                    .strokeBorder(PanelTheme.borderIdle, lineWidth: PanelTheme.borderWidth))

            // Sized to its content and pinned to the gutter: a segmented control stretched across the
            // panel gives four icons a great deal of room they do not need, and centred it reads as
            // having been dropped there. `SymbolSegmentedPicker` rather than SwiftUI's, because these
            // segments are icons and icons need a tooltip each.
            SymbolSegmentedPicker(
                selection: model.kindFilter,
                items: MediaLibraryModel.KindFilter.allCases.map {
                    .init(value: $0, symbolName: $0.symbolName, title: $0.title)
                }
            )
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, PanelTheme.panelInset)
    }

    private func list(model: Bindable<MediaLibraryModel>) -> some View {
        let rows = self.model.rows
        return Group {
            if rows.isEmpty {
                // A row, not a centred panel-wide state: the library's list starts under its filters
                // and a big block in the middle of it lines up with nothing else in the window.
                List {
                    VStack(alignment: .leading, spacing: PanelTheme.hairGap) {
                        Text(self.model.query.isEmpty ? "No media" : "No matches").foregroundStyle(.secondary)
                        Text(
                            self.model.query.isEmpty
                                ? "Import files to add them to the library"
                                : "Nothing matches “\(self.model.query)”"
                        )
                        .font(PanelTheme.detail).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, PanelTheme.hairGap)
                    .selectionDisabled()
                }
                .listStyle(.inset)
                .contentMargins(.top, PanelTheme.rowGap, for: .scrollContent)
            } else {
                List(rows, selection: model.selection) { row in
                    MediaLibraryRow(model: self.model, row: row)
                        .contentShape(.rect)
                        // No tap gesture on a row, ever. A `TapGesture` — `onTapGesture(count: 2)`,
                        // simultaneous or not — consumes the row's mouse-down, and the row then neither
                        // selects nor starts its drag: the panel looks dead and nothing can be dragged out
                        // of it. Return and the context menu insert instead.
                        .onDrag {
                            self.model.dragProvider(dragged(row))
                        } preview: {
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
                // Without this the first row is drawn hard against the filters above and comes out
                // clipped along its top edge.
                .contentMargins(.top, PanelTheme.rowGap, for: .scrollContent)
                .onKeyPress(.return) {
                    let items = self.model.dragItems(self.model.selection)
                    guard !items.isEmpty else { return .ignored }
                    onInsert(items)
                    return .handled
                }
            }
        }
        // Both branches must fill the panel: a body that sizes to its content would leave the column
        // short the moment a filter matched nothing.
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

/// The library panel header's controls: which projects to list, a rescan, and the import panel. They
/// live here rather than in the app so the panel's chrome is all in one file.
public struct MediaLibraryControls: View {
    public let model: MediaLibraryModel
    public var onImport: () -> Void

    public init(model: MediaLibraryModel, onImport: @escaping () -> Void) {
        self.model = model
        self.onImport = onImport
    }

    public var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Scope", selection: $model.scope) {
                ForEach(MediaLibraryModel.Scope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(
                systemName: self.model.scope == .allProjects
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which projects to list")
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await self.model.load() } }
            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(self.model.isLoading)
            .help("Rescan the library")
        Button("Import…", systemImage: "square.and.arrow.down") { onImport() }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .help("Import files into the library")
    }
}

/// One row: poster, name, and a caption line naming the duration, the kind, and — for media the open
/// project does not own — the project it came from.
struct MediaLibraryRow: View {
    let model: MediaLibraryModel
    let row: MediaLibraryModel.Row
    /// 2 on every Retina Mac. The poster is asked for in pixels, so this is what turns the row's point
    /// height into the height the picture actually has to be.
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: PanelTheme.sectionGap) {
            poster
            VStack(alignment: .leading, spacing: PanelTheme.hairGap) {
                Text(row.asset.displayName).lineLimit(1).truncationMode(.middle)
                HStack(spacing: PanelTheme.rowGap) {
                    Text(Timecode.label(seconds: row.asset.duration.seconds, interval: 1, frameDuration: second))
                    Text(row.asset.kind.rawValue)
                    if let project = row.foreignProjectName { Text("· \(project)") }
                }
                .font(PanelTheme.detail).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if row.isOffline {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(PanelTheme.warning).help(
                    "The file is missing")
            } else if row.isInProject {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help("Already in this project")
            }
        }
        .padding(.vertical, PanelTheme.hairGap)
    }

    private var second: RationalTime { RationalTime(1, 1) }

    private var posterPixelHeight: Int {
        PosterGeometry.pixelHeight(
            box: PanelTheme.posterSize, aspect: row.asset.displayAspectRatio, displayScale: displayScale)
    }

    /// What a row draws where its poster will go.
    static func placeholderSymbol(_ kind: AssetKind) -> String {
        switch kind {
        case .audio: "waveform"
        case .image: "photo"
        default: "film"
        }
    }

    @ViewBuilder private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PanelTheme.posterRadius).fill(PanelTheme.chipFill)
            if let image = model.poster(for: row, height: posterPixelHeight) {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                // Audio never has a poster; everything else draws its own kind until the fetch lands.
                Image(systemName: MediaLibraryRow.placeholderSymbol(row.asset.kind)).foregroundStyle(.secondary)
            }
        }
        .frame(width: PanelTheme.posterSize.width, height: PanelTheme.posterSize.height)
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.posterRadius))
    }
}
