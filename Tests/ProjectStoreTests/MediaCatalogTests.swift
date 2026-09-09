import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import ProjectStore

/// The catalog over real `.tlproj` packages: what it finds, what it reads out of them, and the one rule
/// it must never break — a foreign package is opened read-only and never written to.
@Suite("Cross-project media catalog")
struct MediaCatalogTests {
    /// A library root with a projects directory, and the packages a test wrote into it.
    struct Library {
        let dir: TempDir
        var layout: LibraryLayout { LibraryLayout(root: dir.url) }

        init() throws {
            dir = TempDir("catalog")
            try FileManager.default.createDirectory(at: layout.projectsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: layout.cacheDir, withIntermediateDirectories: true)
        }

        func catalog() throws -> SQLiteMediaCatalog { try SQLiteMediaCatalog(inMemoryFor: layout) }

        /// Creates a closed package holding `assets`, so the catalog reads a checkpointed database.
        @discardableResult
        func package(_ name: String, assets: [Asset], in directory: URL? = nil) async throws -> (
            url: URL, projectId: ProjectID
        ) {
            let url = (directory ?? layout.projectsDir).appendingPathComponent("\(name).tlproj", isDirectory: true)
            let opener = SQLiteProjectStoreOpener(libraryRootHint: layout.root.path)
            let store = try await opener.createStore(
                at: url, name: name, settings: ProjectSettings(),
                sequence: .init(name: "Sequence 1", frameDuration: RationalTime(1, 30), width: 1920, height: 1080))
            for asset in assets {
                _ = try await store.apply(Fixtures.command(.importAsset(Library.operation(for: asset))))
            }
            let id = await store.projectId
            try await store.close()
            return (url, id)
        }

        static func operation(for asset: Asset) -> Command.Operation.ImportAsset {
            .init(
                id: asset.id, contentHash: asset.contentHash, libraryPath: asset.libraryPath,
                displayName: asset.displayName, kind: asset.kind, duration: asset.duration, hasVideo: asset.hasVideo,
                hasAudio: asset.hasAudio, sampleRate: asset.sampleRate, frameDuration: asset.frameDuration,
                probe: asset.probe)
        }

        /// Every file in `url` with its size and modification date, for the "never writes" check.
        /// `project.sqlite-shm` is left out: SQLite maps the shared-memory index for *any* WAL reader,
        /// read-only connections included, which bumps its mtime without changing a byte of the database.
        static func snapshot(_ url: URL) -> [String: String] {
            var result: [String: String] = [:]
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let files =
                FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)?
                .compactMap { $0 as? URL } ?? []
            for file in files where file.lastPathComponent != "project.sqlite-shm" {
                let values = try? file.resourceValues(forKeys: Set(keys))
                result[file.lastPathComponent] =
                    "\(values?.fileSize ?? -1)/\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)"
            }
            return result
        }
    }

    private let cam = Fixtures.asset(id: "asset-cam", name: "cam.mov", contentHash: "sha256-cam")
    private let band = Fixtures.asset(id: "asset-band", name: "band.wav", contentHash: "sha256-band", hasVideo: false)
    private let gig = Fixtures.asset(id: "asset-gig", name: "gig.mov", contentHash: "sha256-gig")

    @Test func scanFindsEveryPackageUnderTheProjectsDirectoryWithItsAssets() async throws {
        let library = try Library()
        let rehearsal = try await library.package("Rehearsal", assets: [cam, band])
        let show = try await library.package("Show", assets: [gig])
        let catalog = try library.catalog()

        #expect(try await catalog.projects().isEmpty)
        #expect(try await catalog.refresh() == 2)
        let projects = try await catalog.projects()
        #expect(Set(projects.map(\.name)) == ["Rehearsal", "Show"])
        #expect(projects.allSatisfy { $0.isReadable && $0.unreadableReason == nil })
        #expect(Set(projects.map(\.id)) == [rehearsal.projectId, show.projectId])
        #expect(projects.compactMap { $0.url?.lastPathComponent }.sorted() == ["Rehearsal.tlproj", "Show.tlproj"])

        let items = try await catalog.items()
        #expect(items.count == 3)
        #expect(Set(items.map(\.asset.displayName)) == ["cam.mov", "band.wav", "gig.mov"])
        // Each item is attributed to the project that holds it, and its id is unique across projects.
        #expect(items.filter { $0.projectId == rehearsal.projectId }.count == 2)
        #expect(items.filter { $0.projectName == "Show" }.map(\.id) == ["\(show.projectId.rawValue)/asset-gig"])
        #expect(Set(items.map(\.id)).count == items.count)
        // A second refresh with nothing changed re-reads nothing.
        #expect(try await catalog.refresh() == 0)
    }

    @Test func assetsComeBackAsTheOwningProjectStoredThem() async throws {
        let library = try Library()
        let rehearsal = try await library.package("Rehearsal", assets: [cam])
        let catalog = try library.catalog()
        try await catalog.refresh()
        let item = try #require(try await catalog.items().first)

        #expect(item.asset.id == cam.id)
        #expect(item.asset.contentHash == cam.contentHash)
        #expect(item.asset.libraryPath == cam.libraryPath)
        #expect(item.asset.displayName == cam.displayName)
        #expect(item.asset.kind == cam.kind)
        #expect(item.asset.duration == cam.duration)
        #expect(item.asset.hasVideo == cam.hasVideo && item.asset.hasAudio == cam.hasAudio)
        #expect(item.asset.probe == cam.probe)
        #expect(!item.asset.offline)
        // The library root the owning project recorded, so the file resolves against *its* root.
        #expect(item.libraryRoot?.standardizedFileURL == library.layout.root.standardizedFileURL)
        #expect(item.url(defaultRoot: URL(fileURLWithPath: "/elsewhere")).path.hasPrefix(library.layout.root.path))
        #expect(item.projectId == rehearsal.projectId && item.projectName == "Rehearsal")
        // The assets projection has no columns for these, so browsing does not claim to know them.
        #expect(item.asset.sampleRate == nil && item.asset.frameDuration == nil)
    }

    @Test func theOpenProjectCanBeExcluded() async throws {
        let library = try Library()
        let rehearsal = try await library.package("Rehearsal", assets: [cam, band])
        let show = try await library.package("Show", assets: [gig])
        let catalog = try library.catalog()
        try await catalog.refresh()

        let others = try await catalog.items(excluding: [rehearsal.projectId])
        #expect(others.map(\.asset.displayName) == ["gig.mov"])
        #expect(others.allSatisfy { $0.projectId == show.projectId })
        // Excluding everything leaves nothing; the panel then shows the live document alone.
        #expect(try await catalog.items(excluding: [rehearsal.projectId, show.projectId]).isEmpty)
        // Excluding a project changes no stored row.
        #expect(try await catalog.projects().count == 2)
    }

    @Test func refreshRereadsOnlyPackagesWhoseDatabaseChanged() async throws {
        let library = try Library()
        let rehearsal = try await library.package("Rehearsal", assets: [cam])
        try await library.package("Show", assets: [gig])
        let catalog = try library.catalog()
        #expect(try await catalog.refresh() == 2)
        #expect(try await catalog.refresh() == 0)

        // One more asset in one package: only that package is re-read, and its items are replaced wholesale.
        let opener = SQLiteProjectStoreOpener(libraryRootHint: library.layout.root.path)
        let store = try await opener.openStore(at: rehearsal.url)
        _ = try await store.apply(Fixtures.command(.importAsset(Library.operation(for: band))))
        try await store.close()

        #expect(try await catalog.refresh() == 1)
        let items = try await catalog.items(excluding: [])
        #expect(
            items.filter { $0.projectId == rehearsal.projectId }.map(\.asset.displayName).sorted() == [
                "band.wav", "cam.mov",
            ])
        #expect(items.count == 3)
        #expect(try await catalog.refresh() == 0)
    }

    @Test func aPackageThatDisappearsDropsOutAndIsMarkedUnreadable() async throws {
        let library = try Library()
        let rehearsal = try await library.package("Rehearsal", assets: [cam])
        try await library.package("Show", assets: [gig])
        let catalog = try library.catalog()
        try await catalog.refresh()
        #expect(try await catalog.items().count == 2)

        try FileManager.default.removeItem(at: rehearsal.url)
        try await catalog.refresh()
        let projects = try await catalog.projects()
        let missing = try #require(projects.first { $0.id == rehearsal.projectId })
        #expect(!missing.isReadable)
        #expect(missing.unreadableReason?.isEmpty == false)
        // Its items are gone; the panel still lists it, greyed, with the reason.
        #expect(try await catalog.items().map(\.asset.displayName) == ["gig.mov"])
        #expect(projects.count == 2)
    }

    @Test func aPackageOutsideTheProjectsDirectoryIsFoundOnlyAfterRegistration() async throws {
        let library = try Library()
        let outside = TempDir("outside")
        let away = try await library.package("Away", assets: [gig], in: outside.url)
        let catalog = try library.catalog()

        #expect(try await catalog.refresh() == 0)
        #expect(try await catalog.items().isEmpty)

        await catalog.register(packageAt: away.url)
        #expect(try await catalog.refresh() == 1)
        #expect(try await catalog.items().map(\.projectId) == [away.projectId])
        // Registration is remembered, so the package stays browsable without a second register call.
        #expect(try await catalog.refresh() == 0)
        #expect(try await catalog.items().count == 1)
    }

    @Test func theProjectNameComesFromTheStateRowWithoutDecodingIt() async throws {
        let library = try Library()
        let rehearsal = try await library.package("Rehearsal", assets: [cam])
        let catalog = try library.catalog()
        try await catalog.refresh()
        #expect(try await catalog.projects().map(\.name) == ["Rehearsal"])

        // The manifest carries no name, so a rename can only show up if the state row was read.
        let opener = SQLiteProjectStoreOpener(libraryRootHint: library.layout.root.path)
        let store = try await opener.openStore(at: rehearsal.url)
        _ = try await store.apply(Fixtures.command(.renameProject(.init(name: "Band Rehearsal"))))
        try await store.close()

        try await catalog.refresh()
        #expect(try await catalog.projects().map(\.name) == ["Band Rehearsal"])
        #expect(try await catalog.items().map(\.projectName) == ["Band Rehearsal"])
    }

    @Test func catalogNeverWritesToAForeignPackage() async throws {
        let library = try Library()
        let rehearsal = try await library.package("Rehearsal", assets: [cam, band])
        let database = ProjectPackage(url: rehearsal.url).databaseURL
        let before = Library.snapshot(rehearsal.url)
        let bytes = try Data(contentsOf: database)
        #expect(before.keys.contains("project.sqlite"))

        let catalog = try library.catalog()
        try await catalog.refresh()
        _ = try await catalog.items()
        _ = try await catalog.projects()
        try await catalog.refresh()

        #expect(Library.snapshot(rehearsal.url) == before)
        #expect(try Data(contentsOf: database) == bytes)
    }
}
