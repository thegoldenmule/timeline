import AppKit
import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore
import UniformTypeIdentifiers

@testable import TimelineUI

/// The panel over a live document plus a catalog of other projects: what it lists, how it filters and
/// ranks, and what a row hands to a drop.
@MainActor
@Suite("Media library panel")
struct MediaLibraryTests {
    /// The library root every item in these tests resolves against.
    private static let root = URL(fileURLWithPath: "/tmp/TimelineLibraryTests", isDirectory: true)

    private func asset(
        _ name: String, hash: String, kind: AssetKind = .video, folder: String = "2026/2026-09-08",
        id: AssetID? = nil
    ) -> Asset {
        Asset(
            id: id ?? AssetID(hash), contentHash: hash, libraryPath: "\(folder)/\(name)", displayName: name,
            kind: kind, duration: Fixtures.frames(240), hasVideo: kind != .audio, hasAudio: kind != .image)
    }

    /// A model over the `three-clips` fixture and a catalog of foreign items; every file exists unless
    /// its hash is in `missing`.
    private func model(
        items: [CatalogItem] = [], projects: [CatalogProject] = [], missing: Set<String> = [],
        fixture: String = "three-clips"
    ) async throws -> (model: MediaLibraryModel, fixture: UIFixture, catalog: FakeMediaCatalog) {
        let f = try await UIFixture.make(fixture)
        let catalog = FakeMediaCatalog(projects: projects, items: items)
        let model = MediaLibraryModel(
            viewModel: f.viewModel, catalog: catalog, layout: LibraryLayout(root: MediaLibraryTests.root),
            fileExists: { url in !missing.contains(where: { url.lastPathComponent.contains($0) }) })
        await model.load()
        return (model, f, catalog)
    }

    @Test func theListShowsThisProjectsAssetsAndEveryOtherProjectsMedia() async throws {
        let (model, f, _) = try await self.model(
            items: [
                Fixtures.catalogItem(asset("gig.mov", hash: "sha256-gig"), projectId: "project-2", projectName: "Gig"),
                Fixtures.catalogItem(asset("loose.wav", hash: "sha256-loose", kind: .audio)),
            ],
            projects: [Fixtures.catalogProject("project-2", name: "Gig")])

        let names = model.rows.map(\.asset.displayName)
        #expect(Set(names) == ["IMG_1575.MOV", "Screen Recording.mov", "band-mix-v3.wav", "gig.mov", "loose.wav"])
        #expect(model.rows.count == f.viewModel.project.assets.count + 2)
        // Foreign media names its project; the open project's own rows and library-only media do not.
        #expect(model.rows.first { $0.asset.displayName == "gig.mov" }?.foreignProjectName == "Gig")
        #expect(model.rows.first { $0.asset.displayName == "loose.wav" }?.foreignProjectName == nil)
        // The open project's own media names no project: the human is already looking at it, and a
        // row that said so on every line was just noise down the panel.
        for row in model.rows where row.item.projectId == f.viewModel.project.id {
            #expect(row.foreignProjectName == nil)
        }
        #expect(model.rows.contains { $0.item.projectId == f.viewModel.project.id })
        #expect(model.rows.first { $0.asset.displayName == "IMG_1575.MOV" }?.item.projectId == f.viewModel.project.id)
        #expect(model.projects.map(\.name) == ["Gig"])
    }

    @Test func theKindFilterSplitsVideoAudioAndImages() async throws {
        let (model, _, _) = try await self.model(items: [
            Fixtures.catalogItem(asset("still.png", hash: "sha256-still", kind: .image), projectId: "project-2"),
            Fixtures.catalogItem(asset("gig.mov", hash: "sha256-gig"), projectId: "project-2"),
        ])

        model.kindFilter = .video
        #expect(model.rows.map(\.asset.displayName).sorted() == ["IMG_1575.MOV", "Screen Recording.mov", "gig.mov"])
        model.kindFilter = .audio
        #expect(model.rows.map(\.asset.displayName) == ["band-mix-v3.wav"])
        model.kindFilter = .image
        #expect(model.rows.map(\.asset.displayName) == ["still.png"])
        model.kindFilter = .all
        #expect(model.rows.count == 5)
    }

    @Test func searchRanksAcrossProjectsAndSurvivesAKindFilter() async throws {
        let (model, _, _) = try await self.model(items: [
            Fixtures.catalogItem(
                asset("mixdown.wav", hash: "sha256-mix", kind: .audio), projectId: "project-2",
                projectName: "Band Rehearsal")
        ])

        // The name matches directly.
        model.query = "band"
        #expect(model.rows.map(\.asset.displayName) == ["band-mix-v3.wav", "mixdown.wav"])
        // The second row only matches through its project name, which is weighted lower.
        let byName = try #require(model.rows.first)
        let byProject = try #require(model.rows.last)
        #expect(byName.score > byProject.score)
        // The folder is searchable too, so a date finds everything copied that day.
        model.query = "2026-09-08"
        #expect(model.rows.count == 4)
        // A kind filter narrows the same ranking rather than resetting it.
        model.query = "band"
        model.kindFilter = .audio
        #expect(model.rows.map(\.asset.displayName) == ["band-mix-v3.wav", "mixdown.wav"])
        model.kindFilter = .video
        #expect(model.rows.isEmpty)
        // Nothing matches: an empty list, not an unfiltered one.
        model.kindFilter = .all
        model.query = "zzz"
        #expect(model.rows.isEmpty)
    }

    @Test func itemsAlreadyInTheOpenProjectAreBadgedByContentHash() async throws {
        let f = try await UIFixture.make("three-clips")
        let mine = try #require(f.viewModel.project.assets.values.first { $0.displayName == "IMG_1575.MOV" })
        // The same file, imported into another project under a different asset id and name.
        let theirs = Asset(
            id: "asset-theirs", contentHash: mine.contentHash, libraryPath: mine.libraryPath,
            displayName: "camera A.mov", kind: .video, duration: mine.duration, hasVideo: true, hasAudio: true)
        let catalog = FakeMediaCatalog(items: [
            Fixtures.catalogItem(theirs, projectId: "project-2", projectName: "Gig"),
            Fixtures.catalogItem(asset("gig.mov", hash: "sha256-gig"), projectId: "project-2", projectName: "Gig"),
        ])
        let model = MediaLibraryModel(
            viewModel: f.viewModel, catalog: catalog, layout: LibraryLayout(root: MediaLibraryTests.root),
            fileExists: { _ in true })
        await model.load()

        let badged = try #require(model.rows.first { $0.asset.displayName == "camera A.mov" })
        #expect(badged.isInProject, "the hash is already in this project, so a drop needs no importAsset")
        #expect(badged.item.projectId == "project-2", "it is still attributed to the project it came from")
        #expect(model.rows.first { $0.asset.displayName == "gig.mov" }?.isInProject == false)
        #expect(model.rows.allSatisfy { $0.item.projectId == f.viewModel.project.id ? $0.isInProject : true })
    }

    @Test func thisProjectScopeHidesForeignItems() async throws {
        let (model, f, _) = try await self.model(items: [
            Fixtures.catalogItem(asset("gig.mov", hash: "sha256-gig"), projectId: "project-2", projectName: "Gig"),
            Fixtures.catalogItem(asset("loose.wav", hash: "sha256-loose", kind: .audio)),
        ])

        model.scope = .thisProject
        #expect(model.rows.count == f.viewModel.project.assets.count)
        #expect(model.rows.allSatisfy { $0.item.projectId == f.viewModel.project.id })
        model.scope = .allProjects
        #expect(model.rows.count == f.viewModel.project.assets.count + 2)
    }

    @Test func theOpenProjectsItemsComeFromTheLiveDocumentNotTheCatalog() async throws {
        let f = try await UIFixture.make("three-clips")
        let mine = try #require(f.viewModel.project.assets.values.first { $0.displayName == "IMG_1575.MOV" })
        var stale = mine
        stale.displayName = "stale name.mov"
        let catalog = FakeMediaCatalog(items: [
            Fixtures.catalogItem(stale, projectId: f.viewModel.project.id, projectName: "Three clips")
        ])
        let model = MediaLibraryModel(
            viewModel: f.viewModel, catalog: catalog, layout: LibraryLayout(root: MediaLibraryTests.root),
            fileExists: { _ in true })
        await model.load()

        // The catalog was asked to leave the open project out, so its stale row never appears.
        #expect(!model.rows.contains { $0.asset.displayName == "stale name.mov" })
        #expect(model.rows.contains { $0.asset.displayName == "IMG_1575.MOV" })
        #expect(model.catalogItems.isEmpty)
        #expect(model.rows.count == f.viewModel.project.assets.count)
    }

    @Test func anItemWhoseFileIsMissingIsMarkedOfflineAndCannotBeDragged() async throws {
        let (model, _, _) = try await self.model(
            items: [
                Fixtures.catalogItem(asset("gone.mov", hash: "sha256-gone"), projectId: "project-2"),
                Fixtures.catalogItem(asset("gig.mov", hash: "sha256-gig"), projectId: "project-2"),
            ], missing: ["gone.mov"])

        let gone = try #require(model.rows.first { $0.asset.displayName == "gone.mov" })
        let here = try #require(model.rows.first { $0.asset.displayName == "gig.mov" })
        #expect(gone.isOffline && !here.isOffline)
        #expect(model.dragItem(for: gone) == nil)
        #expect(model.dragItem(for: here) != nil)
        #expect(model.poster(for: gone) == nil)
        // A selection spanning both drags only what can be resolved.
        #expect(model.dragItems([gone.id, here.id]).map(\.displayName) == ["gig.mov"])
    }

    @Test func orderingIsTotalAndDeterministic() async throws {
        // Two files with the same name in two projects, differing only in content hash.
        let earlier = Date(timeIntervalSince1970: 1_788_000_000)
        let (model, _, _) = try await self.model(items: [
            Fixtures.catalogItem(
                asset("take.mov", hash: "sha256-bbb", id: "asset-b"), projectId: "project-3", projectName: "Late",
                addedAt: earlier),
            Fixtures.catalogItem(
                asset("take.mov", hash: "sha256-aaa", id: "asset-a"), projectId: "project-2", projectName: "Early",
                addedAt: earlier),
            Fixtures.catalogItem(
                asset("take.mov", hash: "sha256-ccc", id: "asset-c"), projectId: "project-4", projectName: "Newest",
                addedAt: earlier.addingTimeInterval(60)),
        ])

        model.query = "take"
        let hashes = model.rows.map(\.asset.contentHash)
        // Equal scores: newest first, then name, then content hash.
        #expect(hashes == ["sha256-ccc", "sha256-aaa", "sha256-bbb"])
        #expect(model.rows.map(\.id) == model.rows.map(\.id))
        await model.load()
        #expect(model.rows.map(\.asset.contentHash) == hashes, "a second load lists the same way")
    }

    @Test func libraryOnlyMediaTheOpenProjectAlreadyHoldsIsNotListedTwice() async throws {
        let f = try await UIFixture.make("three-clips")
        let mine = try #require(f.viewModel.project.assets.values.first { $0.displayName == "band-mix-v3.wav" })
        // The cache index knows the file too, and no scanned project claims it yet.
        let catalog = FakeMediaCatalog(items: [
            Fixtures.catalogItem(mine), Fixtures.catalogItem(asset("loose.wav", hash: "sha256-loose", kind: .audio)),
        ])
        let model = MediaLibraryModel(
            viewModel: f.viewModel, catalog: catalog, layout: LibraryLayout(root: MediaLibraryTests.root),
            fileExists: { _ in true })
        await model.load()

        #expect(model.rows.filter { $0.asset.contentHash == mine.contentHash }.count == 1)
        #expect(model.rows.first { $0.asset.contentHash == mine.contentHash }?.item.projectId == f.viewModel.project.id)
        #expect(model.rows.contains { $0.asset.displayName == "loose.wav" }, "library-only media still lists")
    }

    @Test func dragPayloadCarriesTheHashAndTheOwningProject() async throws {
        let (model, _, _) = try await self.model(items: [
            Fixtures.catalogItem(
                asset("gig.mov", hash: "sha256-gig"), projectId: "project-2", projectName: "Gig",
                libraryRoot: URL(fileURLWithPath: "/Volumes/Scratch/Timeline", isDirectory: true))
        ])
        let row = try #require(model.rows.first { $0.asset.displayName == "gig.mov" })
        let item = try #require(model.dragItem(for: row))

        #expect(item.contentHash == "sha256-gig")
        #expect(item.projectId == "project-2")
        #expect(item.assetId == row.asset.id)
        #expect(item.kind == .video && item.hasVideo && item.duration == row.asset.duration)
        // Resolved against the owning project's root, not this machine's.
        #expect(item.url?.path == "/Volumes/Scratch/Timeline/Library/2026/2026-09-08/gig.mov")

        // Through a real pasteboard, which is the one part `UTType(exportedAs:)` cannot be unit-tested on.
        let board = NSPasteboard(name: NSPasteboard.Name("timeline-library-tests-\(UUID().uuidString)"))
        board.clearContents()
        board.setData(try model.payload([row.id]).data(), forType: LibraryDragPayload.pasteboardType)
        let data = try #require(board.data(forType: LibraryDragPayload.pasteboardType))
        #expect(try LibraryDragPayload(data: data).items == [item])

        // ...and through the provider a real drag carries, which is not the same thing. Everything
        // registered on a provider is promised through SwiftUI's bridge and resolved asynchronously, so a
        // drop reading `data(forType:)` gets zero bytes however the payload was registered. The drag
        // therefore also carries the file itself, a type AppKit writes to the pasteboard directly, and
        // that is what both the timeline and the agent pane fall back to.
        let provider = model.dragProvider([row.id])
        defer { LibraryDragPayload.endInFlight() }
        #expect(provider.registeredTypeIdentifiers.contains(LibraryDragPayload.typeIdentifier))
        #expect(provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier))
        // ...and the rows go across in-process, which is what a drop actually reads.
        #expect(LibraryDragPayload.inFlight?.items == [item])
    }
}
