import Contracts
import Foundation
import MediaKit
import ProjectStore
import TimelineCore

/// The window's catalog: ProjectStore's scan of every `.tlproj` package on this machine, plus MediaKit's
/// cache index for originals in `Library/` that no project references. Neither module may import the
/// other (`conventions.md`), so the merge lives here, in the composition root.
///
/// The cache index also supplies `addedAt`: it is the only place that records when a file was first
/// seen, which is what puts recent media at the top of the panel.
struct CompositeMediaCatalog: MediaCatalog {
    let packages: SQLiteMediaCatalog
    let cache: CacheIndex
    /// How many library rows to consider; the cache index holds every file the machine ever imported.
    var libraryLimit = 5000

    func projects() async throws -> [CatalogProject] {
        try await packages.projects()
    }

    func items(excluding: Set<ProjectID>) async throws -> [CatalogItem] {
        // Every project's items, so a library row can tell whether some project already claims the file,
        // then the excluded projects are dropped from what is returned.
        let all = try await packages.items(excluding: [])
        let claimed = Set(all.map(\.contentHash))
        let rows = (try? cache.allMedia(limit: libraryLimit)) ?? []
        var firstSeen: [String: Date] = [:]
        for row in rows { firstSeen[row.contentHash] = row.firstSeen }

        var items = all.filter { $0.projectId.map { !excluding.contains($0) } ?? true }
        for index in items.indices { items[index].addedAt = firstSeen[items[index].contentHash] }
        for row in rows where !claimed.contains(row.contentHash) {
            guard let asset = row.asset else { continue }  // an analysed file that was never imported
            items.append(CatalogItem(asset: asset, addedAt: row.firstSeen))
        }
        return items
    }

    @discardableResult
    func refresh() async throws -> Int {
        try await packages.refresh()
    }

    func register(packageAt url: URL) async {
        await packages.register(packageAt: url)
    }
}
