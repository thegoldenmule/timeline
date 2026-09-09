import Foundation
import TimelineCore

/// A project the catalog knows about, whether or not it is open.
public struct CatalogProject: Hashable, Sendable, Codable, Identifiable {
    public var id: ProjectID
    public var name: String
    /// The `.tlproj` package, when the catalog found one.
    public var url: URL?
    /// `project.sqlite`'s modification time, so the panel can put recent projects first.
    public var modifiedAt: Date?
    /// False when the package is gone or its database refused a read-only open; its items drop out.
    public var isReadable: Bool
    /// Why it is unreadable, for the panel's project filter.
    public var unreadableReason: String?

    public init(
        id: ProjectID, name: String, url: URL? = nil, modifiedAt: Date? = nil, isReadable: Bool = true,
        unreadableReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.modifiedAt = modifiedAt
        self.isReadable = isReadable
        self.unreadableReason = unreadableReason
    }
}

/// One browsable piece of media: the asset as its owning project holds it, plus where it came from.
public struct CatalogItem: Hashable, Sendable, Codable, Identifiable {
    public var asset: Asset
    /// Nil for media in the library that no project references.
    public var projectId: ProjectID?
    public var projectName: String?
    /// The library root the owning project used (`manifest.libraryRootHint`), so `asset.libraryPath`
    /// resolves with `LibraryLayout(root:).url(for:)`. Nil means this machine's root.
    public var libraryRoot: URL?
    public var addedAt: Date?

    public init(
        asset: Asset, projectId: ProjectID? = nil, projectName: String? = nil, libraryRoot: URL? = nil,
        addedAt: Date? = nil
    ) {
        self.asset = asset
        self.projectId = projectId
        self.projectName = projectName
        self.libraryRoot = libraryRoot
        self.addedAt = addedAt
    }

    /// Unique across the catalog: the same file in two projects is two browsable items.
    public var id: String { "\(projectId?.rawValue ?? "library")/\(asset.id.rawValue)" }

    public var contentHash: String { asset.contentHash }

    /// Where the file should be, resolved against the owning project's library root rather than the
    /// reader's: a referenced original keeps its absolute path either way.
    public func url(defaultRoot: URL) -> URL {
        LibraryLayout(root: libraryRoot ?? defaultRoot).url(for: asset)
    }
}

/// Everything importable on this machine, across projects (docs/design/storage.md sections 2 and 11).
/// Read-only: the catalog never opens a project for writing and never applies a command, so browsing
/// another project cannot disturb it. Duplicating one of its items into the open project is an ordinary
/// import plus one `importAsset` on the open project's own write path.
public protocol MediaCatalog: Sendable {
    func projects() async throws -> [CatalogProject]

    /// Items from every known project, newest project first. `excluding` skips projects whose live state
    /// the caller already has (the open document), which is also why the panel is never stale about the
    /// project being edited.
    func items(excluding: Set<ProjectID>) async throws -> [CatalogItem]

    /// Re-reads packages whose database changed since the last scan. Returns the number rescanned.
    @discardableResult func refresh() async throws -> Int

    /// Remembers a package outside the projects directory so it stays browsable after it is closed.
    func register(packageAt url: URL) async
}

extension MediaCatalog {
    /// Every item the catalog knows, with nothing excluded.
    public func items() async throws -> [CatalogItem] { try await items(excluding: []) }
}
