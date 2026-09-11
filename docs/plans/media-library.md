# Media library panel and import rework

Status: plan, 2026-09-09. Companion to `docs/design/integration.md` ("Drag and drop"), `docs/design/storage.md`
sections 2 and 11, and `docs/design/conventions.md`. Nothing here changes `timeline-model.md`: adding an
asset to a project stays exactly one `importAsset` command on the one write path.

## 0. Decisions taken before implementation

The plan below left eight questions open. These are the answers it was implemented against:

1. **The window-wide drop (preview, sidebar, status bar) becomes library-only.** Only a drop on the
   timeline creates clips; section 2.7's table is normative.
2. **Library media that no project references is listed**, as `projectId == nil` items read from
   `CacheIndex.allMedia`, merged into the panel by `CompositeMediaCatalog`.
3. **The panel is a leading (left) pane** of `EditorView`'s `HSplitView`, toggled from the toolbar
   with ⌥⌘L.
4. **Project discovery is every `.tlproj` under the projects directory plus every package ever opened,
   created, or forked** (through `register(packageAt:)`). No machine-wide Spotlight hunt.
5. **Rows only**, no list/grid toggle.
6. **No `library_search` agent tool.** The catalog is a window feature; the agent keeps `media_import`.
7. **No "Remove from project"** action. Removing an asset stays an editing operation on the timeline.
8. This document lives in `docs/plans/` so the plan is on record next to the design docs.

## 1. Current behaviour

**Import always lands a clip on the timeline.** `MediaImporter.importFiles(_:at:)`
(`Sources/TimelineApp/MediaImporter.swift`) submits one `MediaLibrary.importJob` per file, records the
asset with `importAsset` unless the project already holds that content hash (`record`), and then
unconditionally adds a clip: `document.insertClip(for:at:)` when a `TimelineDropTarget` was supplied,
`document.appendClip(for:)` when one was not. There is no path through this type that stops at the
library.

Three surfaces call it, all through `AppModel.importFiles(_:at:)` (`Sources/TimelineApp/Views.swift`):

| Surface | Entry point | Today |
|---|---|---|
| Import toolbar button | `AppModel.presentImportPanel()` | `importFiles(panel.urls)` with no target → appended at `sequenceEnd` |
| Timeline drop | `TimelineMetalView.performDragOperation` → `TimelineViewModel.dropMedia` → `onDropMedia` | imported and rippled in at the drop target, back to back |
| Window-wide drop (preview, sidebar, status bar) | `EditorView.dropDestination(for: URL.self)` → `AppModel.dropFiles` | imported and inserted at the playhead on the first matching track |

**The drop code itself is already the shape we want.** `TimelineViewModel.dropTarget(at:)` is pure
geometry over view points; `updateDrop`/`endDrop`/`dropMedia` are an `NSDraggingInfo`-free state
machine; `TimelineMetalView` registers only `.fileURL`, reads URLs off the pasteboard in `fileURLs(_:)`,
gates the operation in `dragOperation(_:)`, and drops in `performDragOperation`. **The timeline drop
keeps working unchanged as combined import+insert** — the only edit it needs is a second pasteboard type
and a second callback for library drags. Everything else (the snapped drop indicator drawn by
`TimelineSceneBuilder.addDropIndicator` and the placement rules in `ProjectDocument.insertClip`) is
untouched.

**There is no library panel.** The window is one `HSplitView`: preview + timeline + status bar on the
left, a `VSplitView` sidebar on the right holding inspector, approvals, jobs, publishes, history, last
tool, MCP, and the assistant panel. Nothing lists the project's assets, let alone another project's.

**There is no cross-project index.** `OpenProjects` (`AppServices.swift`) is the *open* documents only —
`ProjectDirectory`, what tools resolve `projectId` against. Packages are discovered by the user through
`NSOpenPanel`. `Cache/cache.sqlite` (MediaKit's `CacheIndex`) knows every content hash the machine has
imported and even stores the `Asset` as imported (`media.asset`), but it has no notion of which project
uses it.

**What already does the right thing.** The `media_import` tool (`Sources/AgentKit/Tools/MediaTools.swift`)
imports into the library and applies `importAsset` and never adds a clip — the agent path needs no
change. `Decide.importAsset` rejects a second asset with the same content hash in one project, which is
why `MediaImporter.record` looks the hash up first.

## 2. Design

### 2.1 Principle: duplication is a command, not a file copy

storage.md section 1: originals are immutable, live outside projects, and are referenced by content
hash; a fork shares the library. So "duplicate an asset from another project into this one" is *already*
an `importAsset` command carrying that asset's hash, `libraryPath`, and probe. The file only moves when
the source project referenced a file outside this machine's `Library/` (`ImportMode.reference` leaves
`libraryPath` absolute) and we want it copied in.

That means the whole cross-project story reuses `MediaLibrary.importJob(url:mode:)`, which is idempotent
by hash (`FileMediaLibrary.performImport`): re-importing a file already in the library returns the
*existing* `Asset` with the same `AssetID` and `alreadyInLibrary = true`, and relinks it if the copy went
missing. `MediaImporter.record` then either finds the project's existing asset by hash or applies
`importAsset`. **No new import machinery, no new command, no new event.**

### 2.2 New types and where they live

| Type | Target | Role |
|---|---|---|
| `CatalogProject`, `CatalogItem`, `MediaCatalog` | `Contracts` (new `Sources/Contracts/MediaCatalog.swift`) | the only Contracts change (see 2.3) |
| `FakeMediaCatalog` | `ContractsTestSupport` | in-memory catalog for TimelineUI and app tests |
| `SQLiteMediaCatalog` | `ProjectStore` (new `Sources/ProjectStore/MediaCatalog.swift`) | scans `.tlproj` packages, caches rows in `Cache/projects.sqlite` |
| `CacheIndex.allMedia(limit:)` | `MediaKit` (existing `CacheIndex.swift`) | library rows that belong to no project |
| `FuzzyMatch` | `TimelineUI` (new `Sources/TimelineUI/FuzzySearch.swift`) | pure scorer |
| `LibraryDragItem`, `LibraryDragPayload` | `TimelineUI` (`TimelineDrop.swift`) | the drag payload both the panel and the Metal view speak |
| `LibraryThumbnailCache` | `TimelineUI` (new file) | `CGImage` poster frames for rows, same miss/dedup/evict shape as `TimelineMediaCache` |
| `MediaLibraryModel`, `MediaLibraryView`, `MediaLibraryRow` | `TimelineUI` (new `Sources/TimelineUI/MediaLibraryView.swift`) | panel state machine + SwiftUI, the `InspectorDraft` + `InspectorView` file pattern |
| `CompositeMediaCatalog` | `TimelineApp` (new `Sources/TimelineApp/MediaCatalog.swift`) | merges the ProjectStore catalog with MediaKit's library-only rows; composition stays in the composition root |

Module rules hold: TimelineUI imports only `TimelineCore` + `Contracts`, ProjectStore never imports
MediaKit, and only `TimelineApp` sees both.

### 2.3 The Contracts change

One additive file, its own commit, with the fake updated in the same commit
(`conventions.md`, "Ownership and branches"), and a note appended to `docs/design/contracts-notes.md`.

```swift
/// A project the catalog knows about, whether or not it is open.
public struct CatalogProject: Hashable, Sendable, Codable, Identifiable {
    public var id: ProjectID
    public var name: String
    public var url: URL?          // the .tlproj package
    public var modifiedAt: Date?  // project.sqlite mtime, for "recent projects first"
    public var isReadable: Bool   // false when the package is gone or unreadable
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
    public var id: String { "\(projectId?.rawValue ?? "library")/\(asset.id.rawValue)" }
}

/// Everything importable on this machine, across projects (docs/design/storage.md sections 2 and 11).
/// Read-only: the catalog never opens a project for writing and never applies a command.
public protocol MediaCatalog: Sendable {
    func projects() async throws -> [CatalogProject]
    /// Items from every known project, newest project first. `excluding` skips projects whose live
    /// state the caller already has (the open document).
    func items(excluding: Set<ProjectID>) async throws -> [CatalogItem]
    /// Re-reads packages whose database changed since the last scan. Returns the number rescanned.
    @discardableResult func refresh() async throws -> Int
    /// Remembers a package outside the library root so it stays browsable after it is closed.
    func register(packageAt url: URL) async
}
```

Nothing else in `Contracts` changes. `LibraryLayout`, `MediaReference`, `ImportResult`, `MediaLibrary`,
`ThumbnailProvider`, and `Command.Operation.ImportAsset` are all reused unmodified — in particular
`LibraryLayout.url(forLibraryPath:)` is exactly the "relative to my root, absolute if referenced"
resolver a foreign item needs once you construct the layout from `item.libraryRoot`.

### 2.4 How the cross-project index is discovered, stored, and refreshed

**Discovered.** The union of

1. every `*.tlproj` directory directly under `layout.projectsDir` (`FileManager.contentsOfDirectory`), and
2. every package path in the registry table, written by `register(packageAt:)` whenever the app opens,
   creates, or forks a project (so a package the user keeps outside `~/Movies/Timeline/Projects` is
   remembered after the first open).

A recursive or Spotlight-wide hunt for `.tlproj` files is deliberately *not* done.

**Read.** For each package: `ProjectPackage(url:).validate()` then `readManifest()` for `projectId` and
`libraryRootHint`, then a **read-only** GRDB connection (`Configuration.readonly = true`, no migrator,
no recovery) on `project.sqlite`:

```sql
SELECT json_extract(state, '$.name') FROM project_state WHERE id = 1;   -- the name, without decoding 1.5 MB
SELECT * FROM assets;                                                    -- decoded as ProjectStore.AssetRow
```

`assets` is a live-rows-only projection, and `AssetRow` already carries everything `Asset` needs, so
`SQLiteMediaCatalog` reuses that record type and adds an `AssetRow.asset() throws -> Asset` counterpart
to the existing `init(_ asset:)`.

**Stored.** A new `Cache/projects.sqlite`, owned by ProjectStore, with its own migrator. It is *not*
folded into `cache.sqlite`: contracts-notes.md already records that two GRDB migrators over one file
collide, and MediaKit's `CacheIndex` owns that file. Like everything under `Cache/`, deleting it loses
nothing that a rescan cannot rebuild (except registrations of out-of-root packages, which come back on
the next open).

```sql
CREATE TABLE projects (
  project_id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
  library_root TEXT, db_size INTEGER NOT NULL, db_mtime TEXT NOT NULL,
  scanned_at TEXT NOT NULL, readable INTEGER NOT NULL DEFAULT 1
) STRICT;
CREATE TABLE project_assets (          -- columns mirror the assets projection
  project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
  asset_id TEXT NOT NULL, content_hash TEXT NOT NULL, display_name TEXT NOT NULL, kind TEXT NOT NULL,
  library_path TEXT NOT NULL, duration_v INTEGER NOT NULL, duration_ts INTEGER NOT NULL CHECK (duration_ts > 0),
  has_video INTEGER NOT NULL, has_audio INTEGER NOT NULL, offline INTEGER NOT NULL, probe TEXT,
  PRIMARY KEY (project_id, asset_id)
) STRICT;
CREATE INDEX project_assets_hash_idx ON project_assets(content_hash);
```

**Refreshed.** `refresh()` compares each package's `project.sqlite` `(size, mtime)` against the stored
row and re-reads only what changed; a package that vanished is marked `readable = 0` and its items drop
out. Called on first panel appearance, from a Refresh button in the panel header, and after
`AppModel.open` / `presentForkPanel`. The **open** project is always excluded (`items(excluding:)`):
its `project.sqlite` churns constantly and its live assets come straight from `document.project.assets`,
so the panel is never stale about the project you are editing.

### 2.5 Fuzzy search

Pure and in memory, over the catalog snapshot the panel already holds (a machine with twenty projects of
five hundred assets is ten thousand rows; scoring is sub-millisecond, and the alternative — FTS5 across
foreign databases — buys nothing and cannot rank the way a filename matcher should).

`FuzzyMatch.score(_ query: String, in candidate: String) -> Int?` in `TimelineUI`:

- Both sides normalized once with `folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive])`.
- Empty query returns `0` (everything matches).
- Left-to-right subsequence scan; `nil` if any query character is unmatched.
- Per matched character `+16`; `+24` when it is adjacent to the previous match (contiguity); `+18` when
  it sits at a word boundary (index 0, or preceded by one of `space - _ . /`, or a lower→upper
  camel-case transition).
- `−4` per unmatched character before the first match, capped at `−40`; `−6` per gap between matched
  runs; `−1` per trailing unmatched character, capped at `−20` (so a shorter name wins a tie).
- No magic numbers loose in the code: the weights live in a `FuzzyMatch.Weights` value with the
  defaults above (`conventions.md`, "No magic numbers for tunables").

`MediaLibraryModel` scores each item as the max over three weighted fields — `asset.displayName` ×1.0,
`projectName` ×0.6, the directory part of `asset.libraryPath` ×0.5 — so "band wav" finds the mix in the
Band Rehearsal project. Ordering: score descending, then `addedAt` descending, then `displayName`, then
`contentHash` (a total order, so tests are deterministic).

### 2.6 Duplicating a foreign asset, end to end

Dragging (or Return, or "Add to project") a `CatalogItem` whose `projectId` is not the open project runs
`MediaImporter.insert(_ items:at:)`:

1. **Already in this project?** `document.project.assets.values.first { $0.contentHash == item.contentHash }`
   — the exact check `MediaImporter.record` already does. Hit → no job, no command, straight to
   `insertClip`. This is also the fast path for the project's own items.
2. **Resolve the file.** `services.mediaLibrary.locate(contentHash:)` first (cache row, then known paths
   re-verified by identity), falling back to
   `LibraryLayout(root: item.libraryRoot ?? services.layout.root).url(for: item.asset)`.
3. **Import.** `jobs.submit(services.mediaLibrary.importJob(url: resolved, mode: .copy))` — the same job
   the Import button and the timeline drop use, so it shows in the job list with progress. A file
   already under `Library/` is recognized by its identity hint and **not copied again**
   (`alreadyInLibrary = true`, same `AssetID`); a file the foreign project referenced from outside gets
   copied into `Library/YYYY/YYYY-MM-DD/` with a sidecar, which is the desired "duplicate into my
   project" behaviour.
4. **Command.** `MediaImporter.record(result)` applies exactly one `.importAsset(result.operation)`
   labelled `Import <displayName>`, or reuses the project's existing asset. `Decide.importAsset` is the
   backstop against a duplicate hash.
5. **Clip (only when the caller asked for one).** `document.insertClip(for:at:)` at the drop target, or
   `appendClip` for "Insert at playhead"/end.

Copy versus reference: always `.copy`, matching every other import path in the app. `mode` is not
exposed in the panel; the agent keeps `media_import`'s `mode` argument.

Failure modes, all surfaced in the status-bar error line and as an item badge:

| Situation | Behaviour |
|---|---|
| Source project moved or deleted | Its items disappear on the next `refresh()`; `readable = 0`. Items whose file is still in `Library/` remain, attributed to the library (`projectId == nil`). |
| File offline (`locate` nil and the path does not exist) | Row shows an "offline" badge, drag disabled, context menu offers **Locate…** → `NSOpenPanel` → `mediaLibrary.importAsset(url:mode:.copy)`; a `MediaError.hashMismatch` is reported as "That file is not <name>". |
| Foreign package unreadable (hot WAL, corrupt) | Skipped with `readable = 0`; the panel's project filter shows it greyed with the reason. No repair is attempted — the catalog never writes to a foreign package. |
| Import job fails | The job list shows the failure; nothing is applied. |

### 2.7 Import stops touching the timeline

`MediaImporter` splits into three entry points, sharing one private `resolveAssets`:

```swift
func importFiles(_ urls: [URL]) async throws -> Outcome                                  // library + importAsset only
func importFiles(_ urls: [URL], at target: TimelineDropTarget) async throws -> Outcome   // the above, then insert
func insert(_ items: [LibraryDragItem], at target: TimelineDropTarget?) async throws -> Outcome
```

`Outcome` keeps its shape (`assets`, `clipIds`, `ignored`); `clipIds` is empty for the library-only
form. The back-to-back cursor logic moves into the insert helper unchanged.

Resulting surface behaviour:

| Surface | New behaviour |
|---|---|
| Import toolbar button / `presentImportPanel` | library only; the panel scrolls the new items into view and selects them |
| Timeline drop | **unchanged**: import + ripple insert at the drop target, back to back |
| Window-wide drop (preview, sidebar, status bar) | library only |
| Library panel drag onto the timeline | duplicate-if-needed + place at the drop target, refused when the range is not free on the track (and on the linked audio's track) |
| Library panel Return / "Insert at playhead" | duplicate-if-needed + insert at the playhead (no double-click: a row tap gesture breaks selection and dragging) |
| `media_import` tool | unchanged (already library-only) |

### 2.8 The panel

**Where.** A third pane on the leading edge of `EditorView`'s existing `HSplitView`,
`minWidth: 220, idealWidth: 280, maxWidth: 420`, before the preview/timeline column. Toggled by a
toolbar `Button("Library", systemImage: "rectangle.stack")` in the first `ToolbarItemGroup` next to
Import, with `.keyboardShortcut("l", modifiers: [.command, .option])`; the flag is
`@AppStorage("showsLibrary")` on `AppModel`, default on. *(Superseded by `docs/plans/panels.md`: the
library is one of four panels now, its width and collapsed flag live in `PanelLayoutModel` under
`panel.library.*`, and `showsLibrary` is migrated once and then inert.)*

**Header.** Search `TextField` (`.roundedBorder`, `.searchable` is not used because the pane is not a
`NavigationSplitView` column) · a segmented `Picker` for kind — All / Video / Audio / Images, mapping to
`AssetKind` · a scope `Picker` — This project / All projects · a Refresh button · an Import… button
calling the same `presentImportPanel`. *(Refresh and Import moved into the shared `PanelHeader`'s
controls slot; see `docs/plans/panels.md`.)*

**Rows.** A `List` of `MediaLibraryRow`: a 64×36 thumbnail, the display name
(`.lineLimit(1).truncationMode(.middle)`), and a caption line with `mm:ss`, kind, and — when `projectId`
is not the open project — the owning project's name. Badges: "in project" when the hash is already in
`document.project.assets`, "offline" when unresolvable. Empty states use `ContentUnavailableView`, as
`ContentView` already does. `.contextMenu`: Insert at playhead · Add to project · Reveal in Finder ·
Copy content hash.

**Thumbnails.** `LibraryThumbnailCache` wraps the injected `any ThumbnailProvider` — the same
`AVThumbnailProvider` the timeline uses, so posters come from the content-addressed sprite sheets
already in `Cache/` and cost nothing for media the timeline has drawn. It mirrors `TimelineMediaCache`'s
contract: a miss returns nil, starts one deduplicated task, stores the `CGImage`, and calls `onUpdate`;
oldest-first eviction past `capacity`. Poster time is `min(duration / 2, 1 s)`, deterministic so the key
is stable. It calls the existing `ThumbnailProvider.thumbnail(for:at:height:)` extension with a
`MediaReference` built from the item's resolved URL and hash. Audio items get a `waveform` SF Symbol;
drawing real peaks through `WaveformProvider` is a follow-up.

**Drag out.** In `TimelineDrop.swift`:

```swift
public struct LibraryDragItem: Codable, Hashable, Sendable {
    public var contentHash: String
    public var displayName: String
    public var kind: AssetKind
    public var duration: RationalTime
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var assetId: AssetID?
    public var projectId: ProjectID?
    /// Where the catalog last saw the file; the app re-resolves by hash first.
    public var url: URL?
}

public struct LibraryDragPayload: Codable, Hashable, Sendable, Transferable {
    public var items: [LibraryDragItem]
    public static let typeIdentifier = "com.thegoldenmule.timeline.library-item"
    public static let contentType = UTType(exportedAs: typeIdentifier, conformingTo: .data)
    public static let pasteboardType = NSPasteboard.PasteboardType(typeIdentifier)
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)   // JSONEncoder, [.sortedKeys]
    }
}
```

`TimelineMetalView` gains the type and one branch, leaving the file path untouched:

- `registerForDraggedTypes([.fileURL, LibraryDragPayload.pasteboardType])`.
- a `libraryItems(_ sender:) -> [LibraryDragItem]` sibling of `fileURLs(_:)` reading
  `draggingPasteboard.data(forType:)` and decoding.
- `dragOperation(_:)`: library items first, then the existing media-URL guard; both call
  `viewModel.updateDrop(at:)`, so the snapped indicator and row highlight are identical for either drag.
- `performDragOperation`: `viewModel.dropLibraryItems(items, at:)` when the library type is present,
  else the unchanged `viewModel.dropMedia(urls, at:)`.

`TimelineViewModel` gains `onDropLibraryItems: (([LibraryDragItem], TimelineDropTarget) -> Void)?` beside
`onDropMedia` and `dropLibraryItems(_:at:) -> Bool` beside `dropMedia`. `AppModel.install(_:)` wires
both.

Checking the library type **before** file URLs matters: rows may also offer a `.fileURL` representation
so a drag to Finder works, and the library branch is the one that knows about cross-project attribution.

## 3. Ordered steps

Each step builds, lints, passes its target's tests, and is one commit with a one-line message.

1. **`Contracts`: the media catalog protocol and DTOs.**
   `Sources/Contracts/MediaCatalog.swift`, `Sources/ContractsTestSupport/Fakes/FakeMediaCatalog.swift`,
   `docs/design/contracts-notes.md`. Tests: `Tests/ContractsTests/MediaCatalogTests.swift`.
2. **`ProjectStore`: `SQLiteMediaCatalog` over `Cache/projects.sqlite`.**
   `Sources/ProjectStore/MediaCatalog.swift`, `Sources/ProjectStore/QueryRows.swift` (`AssetRow.asset()`),
   `Sources/ProjectStore/ProjectStore.swift` (module header bullet).
   Tests: `Tests/ProjectStoreTests/MediaCatalogTests.swift`.
3. **`MediaKit`: library rows that belong to no project.**
   `Sources/MediaKit/CacheIndex.swift` (`allMedia(limit:)`). Tests: `Tests/MediaKitTests/CatalogTests.swift`.
4. **`TimelineUI`: the fuzzy matcher.** `Sources/TimelineUI/FuzzySearch.swift`.
   Tests: `Tests/TimelineUITests/FuzzySearchTests.swift`.
5. **`TimelineUI`: the library drag payload and the timeline's second drop type.**
   `Sources/TimelineUI/TimelineDrop.swift`, `TimelineViewModel.swift`, `TimelineMetalView.swift`.
   Tests appended to `Tests/TimelineUITests/DropTests.swift`.
6. **`TimelineUI`: `LibraryThumbnailCache`.** `Sources/TimelineUI/LibraryThumbnailCache.swift`.
   Tests: `Tests/TimelineUITests/LibraryThumbnailCacheTests.swift`.
7. **`TimelineUI`: the panel model and view.** `Sources/TimelineUI/MediaLibraryView.swift`.
   Tests: `Tests/TimelineUITests/MediaLibraryTests.swift`.
8. **`TimelineApp`: import stops adding clips.** `Sources/TimelineApp/MediaImporter.swift`,
   `Sources/TimelineApp/Views.swift`, `Sources/TimelineApp/SkeletonCheck.swift`.
9. **`TimelineApp`: the library-item insert path.** `Sources/TimelineApp/MediaImporter.swift`
   (`insert(_:at:)`), `Sources/TimelineApp/Views.swift` (`AppModel.insertLibraryItems`, `install`).
10. **`TimelineApp`: wire the catalog and show the panel.**
    `Sources/TimelineApp/MediaCatalog.swift`, `Sources/TimelineApp/AppServices.swift`,
    `Sources/TimelineApp/Views.swift`.
11. **`TimelineApp`: the headless check covers it.** `Sources/TimelineApp/SkeletonCheck.swift` — a
    `library` step between `import` and `edit`.
12. **Docs.** `docs/design/integration.md`, `docs/design/storage.md`, `docs/design/contracts-notes.md`.

## 4. Test plan

Swift Testing throughout, `@Suite("…")` with sentence-shaped `@Test func` names, `#expect` / `#require`,
`UIFixture.make` and `eventually` from `Tests/TimelineUITests/UITestSupport.swift`, `TempDir` / `Stores`
from `Tests/ProjectStoreTests/Support.swift`, `TestMedia` and `Fixtures` from `ContractsTestSupport`.
No media in the repo.

**`Tests/ContractsTests/MediaCatalogTests.swift`** — `@Suite("Media catalog contract")`
- `catalogItemIdentifiesAnAssetByProjectAndAsset`
- `catalogItemsResolveTheirFileAgainstTheOwningLibraryRoot`
- `catalogDTOsRoundTripThroughJSON`
- `fakeCatalogExcludesTheProjectsTheCallerAlreadyHas`

**`Tests/ProjectStoreTests/MediaCatalogTests.swift`** — `@Suite("Cross-project media catalog")`
- `scanFindsEveryPackageUnderTheProjectsDirectoryWithItsAssets`
- `assetsComeBackAsTheOwningProjectStoredThem`
- `theOpenProjectCanBeExcluded`
- `refreshRereadsOnlyPackagesWhoseDatabaseChanged`
- `aPackageThatDisappearsDropsOutAndIsMarkedUnreadable`
- `aPackageOutsideTheProjectsDirectoryIsFoundOnlyAfterRegistration`
- `theProjectNameComesFromTheStateRowWithoutDecodingIt`
- `catalogNeverWritesToAForeignPackage`

**`Tests/MediaKitTests/CatalogTests.swift`** — `@Suite("Cache index listing")`
- `allMediaListsEveryImportedFileWithItsAsset`
- `allMediaHonoursTheLimitAndOrdersNewestFirst`

**`Tests/TimelineUITests/FuzzySearchTests.swift`** — `@Suite("Fuzzy search")`
- `everyQueryCharacterMustMatchInOrder`
- `aPrefixMatchOutranksAMidWordMatch`
- `contiguousMatchesOutrankScatteredOnes`
- `wordBoundariesAreWorthMoreThanInteriorCharacters`
- `theShorterNameWinsATie`
- `matchingIgnoresCaseAndDiacritics`
- `anEmptyQueryMatchesEverythingWithScoreZero`

**`Tests/TimelineUITests/MediaLibraryTests.swift`** — `@Suite("Media library panel")`
- `theListShowsThisProjectsAssetsAndEveryOtherProjectsMedia`
- `theKindFilterSplitsVideoAudioAndImages`
- `searchRanksAcrossProjectsAndSurvivesAKindFilter`
- `itemsAlreadyInTheOpenProjectAreBadgedByContentHash`
- `thisProjectScopeHidesForeignItems`
- `theOpenProjectsItemsComeFromTheLiveDocumentNotTheCatalog`
- `anItemWhoseFileIsMissingIsMarkedOfflineAndCannotBeDragged`
- `orderingIsTotalAndDeterministic`
- `dragPayloadCarriesTheHashAndTheOwningProject`

**`Tests/TimelineUITests/LibraryThumbnailCacheTests.swift`** — `@Suite("Library thumbnails")`
- `aMissStartsOneFetchAndCallsBackWhenItLands`
- `twoRequestsForTheSameItemShareOneFetch`
- `theCacheEvictsOldestFirstPastItsCapacity`
- `audioItemsNeverHitTheThumbnailProvider`

**Appended to `Tests/TimelineUITests/DropTests.swift`**
- `metalViewRegistersForFileAndLibraryDrags`
- `droppingLibraryItemsHandsThemToTheCallbackAtTheSnappedTarget`
- `aLibraryDragDrawsTheSameIndicatorAsAFileDrag`
- `aDragCarryingBothTypesIsTreatedAsALibraryDrag`
- `anEmptyLibraryPayloadIsRefusedAndLeavesNoIndicator`

**Existing** `LayoutTests`, `RenderTests`, `GestureTests`, `DropTests` must stay green.

**Headless check (`make e2e`)**, new `library` step after `import`, asserting in one line: the catalog
sees the skeleton project with its 4 assets; a second package created and closed contributes its asset to
`items(excluding:)`; inserting that foreign item through `MediaImporter.insert` applies exactly one
`importAsset` (version +1, `alreadyInLibrary == true`, no second copy under `Library/`) and lands one
clip at the target; inserting it again applies nothing and reuses the asset; and the Import button path
(`importFiles(urls)` with no target) leaves every track empty.

## 5. Risks

- **Custom `UTType` without an Info.plist.** `TimelineApp` is an SPM executable with no bundle, so an
  *exported* type declaration has nowhere to live. `UTType(exportedAs:conformingTo:)` registers
  dynamically at runtime and drag-and-drop inside one process works, but this is the one piece that
  cannot be fully proven by a unit test. Mitigation: `dragPayloadCarriesTheHashAndTheOwningProject`
  round-trips through a real `NSPasteboardItem`, and `TimelineMetalView` reads the raw
  `NSPasteboard.PasteboardType` rather than relying on `UTType` conformance resolution. If SwiftUI's
  `.draggable` misbehaves, fall back to `NSItemProvider.registerDataRepresentation` with the same
  identifier.
- **Read-only opens of a foreign `project.sqlite`.** A hot WAL may refuse a read-only connection. Catch
  and mark `readable = 0` with the reason; never recover or write to someone else's package.
- **Two SQLite files under `Cache/`** is deliberate; say so in storage.md.
- **Scan cost at launch**, mitigated by the `(size, mtime)` short-circuit and by never scanning the open
  project.
- **`MediaImporter.Outcome.clipIds` becoming empty** silently breaks callers that assumed a clip. Only
  `AppModel` and `SkeletonCheck` call it; both are updated in step 8.
- **Behaviour change for muscle memory.** Worth a one-line status-bar note after a library-only import
  ("Imported 3 files into the library").
