import Contracts
import Foundation
import TimelineCore

/// An in-memory `MediaCatalog` seeded with projects and their items. Nothing is scanned or read from
/// disk, so a UI test can describe a machine with three projects in two lines.
public actor FakeMediaCatalog: MediaCatalog {
    public private(set) var storedProjects: [CatalogProject]
    public private(set) var storedItems: [CatalogItem]
    /// Packages handed to `register(packageAt:)`, in order.
    public private(set) var registered: [URL] = []
    public private(set) var refreshCount = 0
    /// Thrown by `projects()` and `items(excluding:)` when set, for the panel's error state.
    public var failure: (any Error)?

    public init(projects: [CatalogProject] = [], items: [CatalogItem] = []) {
        storedProjects = projects
        storedItems = items
    }

    public func projects() async throws -> [CatalogProject] {
        if let failure { throw failure }
        return storedProjects
    }

    public func items(excluding: Set<ProjectID>) async throws -> [CatalogItem] {
        if let failure { throw failure }
        let unreadable = Set(storedProjects.filter { !$0.isReadable }.map(\.id))
        return storedItems.filter { item in
            guard let id = item.projectId else { return true }
            return !excluding.contains(id) && !unreadable.contains(id)
        }
    }

    @discardableResult
    public func refresh() async throws -> Int {
        if let failure { throw failure }
        refreshCount += 1
        return storedProjects.count
    }

    public func register(packageAt url: URL) async {
        registered.append(url.standardizedFileURL)
    }

    // MARK: Seeding

    public func setProjects(_ projects: [CatalogProject]) { storedProjects = projects }

    public func setItems(_ items: [CatalogItem]) { storedItems = items }

    public func add(_ item: CatalogItem) { storedItems.append(item) }

    public func fail(with error: (any Error)?) { failure = error }
}
