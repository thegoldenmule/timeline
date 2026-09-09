import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@Suite("Media catalog contract")
struct MediaCatalogTests {
    private let band = Fixtures.asset(id: "asset-band", name: "band.wav", contentHash: "sha256-band", hasVideo: false)
    private let cam = Fixtures.asset(id: "asset-cam", name: "cam.mov", contentHash: "sha256-cam")

    @Test func catalogItemIdentifiesAnAssetByProjectAndAsset() {
        let mine = Fixtures.catalogItem(cam, projectId: "project-1", projectName: "Rehearsal")
        let theirs = Fixtures.catalogItem(cam, projectId: "project-2", projectName: "Gig")
        // The same file in two projects is two browsable rows, so a list cannot collapse them.
        #expect(mine.id == "project-1/asset-cam")
        #expect(theirs.id == "project-2/asset-cam")
        #expect(mine.id != theirs.id)
        #expect(mine.contentHash == theirs.contentHash)
        // Media no project references is attributed to the library.
        #expect(Fixtures.catalogItem(cam).id == "library/asset-cam")
    }

    @Test func catalogItemsResolveTheirFileAgainstTheOwningLibraryRoot() {
        let mine = URL(fileURLWithPath: "/Users/me/Movies/Timeline", isDirectory: true)
        let theirs = URL(fileURLWithPath: "/Volumes/Scratch/Timeline", isDirectory: true)
        let foreign = Fixtures.catalogItem(cam, projectId: "project-2", libraryRoot: theirs)
        #expect(foreign.url(defaultRoot: mine).path == "/Volumes/Scratch/Timeline/Library/2026/2026-09-08/cam.mov")
        // No root hint means this machine's root.
        let local = Fixtures.catalogItem(cam, projectId: "project-1")
        #expect(local.url(defaultRoot: mine).path == "/Users/me/Movies/Timeline/Library/2026/2026-09-08/cam.mov")
        // A referenced original keeps its absolute path whichever root reads it.
        var referenced = cam
        referenced.libraryPath = "/Users/me/Downloads/outside.mov"
        let item = Fixtures.catalogItem(referenced, projectId: "project-2", libraryRoot: theirs)
        #expect(item.url(defaultRoot: mine).path == "/Users/me/Downloads/outside.mov")
    }

    @Test func catalogDTOsRoundTripThroughJSON() throws {
        let project = CatalogProject(
            id: "project-1", name: "Rehearsal", url: URL(fileURLWithPath: "/tmp/Rehearsal.tlproj"),
            modifiedAt: Fixtures.fixtureDate, isReadable: false, unreadableReason: "database is locked")
        let item = Fixtures.catalogItem(
            band, projectId: "project-1", projectName: "Rehearsal",
            libraryRoot: URL(fileURLWithPath: "/tmp/Timeline"), addedAt: Fixtures.fixtureDate)
        #expect(try ProjectCodec.decode(CatalogProject.self, from: ProjectCodec.encode(project)) == project)
        #expect(try ProjectCodec.decode(CatalogItem.self, from: ProjectCodec.encode(item)) == item)
    }

    @Test func fakeCatalogExcludesTheProjectsTheCallerAlreadyHas() async throws {
        let catalog = FakeMediaCatalog(
            projects: [
                Fixtures.catalogProject("project-1", name: "Rehearsal"),
                Fixtures.catalogProject("project-2", name: "Gig"),
                CatalogProject(id: "project-3", name: "Moved", isReadable: false, unreadableReason: "no package"),
            ],
            items: [
                Fixtures.catalogItem(cam, projectId: "project-1", projectName: "Rehearsal"),
                Fixtures.catalogItem(band, projectId: "project-2", projectName: "Gig"),
                Fixtures.catalogItem(band, projectId: "project-3", projectName: "Moved"),
                Fixtures.catalogItem(band),
            ])
        let catalogProtocol: any MediaCatalog = catalog
        #expect(try await catalogProtocol.projects().count == 3)
        // Nothing excluded: everything but the unreadable project's items, library media included.
        #expect(
            try await catalogProtocol.items().map(\.id) == [
                "project-1/asset-cam", "project-2/asset-band", "library/asset-band",
            ])
        // The open project's items come from its live document, so the catalog leaves them out.
        #expect(
            try await catalogProtocol.items(excluding: ["project-1"]).map(\.id)
                == ["project-2/asset-band", "library/asset-band"])
        #expect(try await catalogProtocol.refresh() == 3)
        await catalogProtocol.register(packageAt: URL(fileURLWithPath: "/tmp/Outside.tlproj"))
        #expect(await catalog.registered.map(\.lastPathComponent) == ["Outside.tlproj"])
        #expect(await catalog.refreshCount == 1)
    }
}
