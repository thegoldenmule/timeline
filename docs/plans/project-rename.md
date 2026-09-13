# Renaming a project

Status: plan, 2026-09-13. Companion to `docs/design/ui-style.md` and `docs/design/conventions.md`.
Nothing in `TimelineCore`, `ProjectStore`, or `RenderKit` changes: the command, the event, its inverse,
and its projection all exist. This is one sheet, one toolbar button, and a validator.

## 0. Context

A project's name is set once, at creation, from the file name typed into the New panel
(`AppModel.presentNewPanel`, `Sources/TimelineApp/Views.swift:196`, whose save panel opens on
`Untitled.tlproj`), handed to `ProjectDocument.create(at:name:using:)`, and written by the store's
`createProject`. Opening an existing package reads the stored name back, so the default project is
called "Untitled" for as long as it exists and renaming `Untitled.tlproj` in Finder does nothing to it.

The name is on screen twice: the window title,
`"\(document.project.name) — v\(document.version)"` (`Views.swift:371`), and every library row the open
project owns (`MediaLibraryModel.openProjectItems`, `Sources/TimelineUI/MediaLibraryView.swift:161`,
which stamps `projectName` from the live document). Nothing in the window can change it.

The write path is already there and already tested. `Command.Operation.renameProject`
(`Sources/TimelineCore/Command.swift:218`) reaches `decide` at `Decide.swift:159`, which emits
`ProjectRenamed(before:after:)` only when the name actually differs — a rename to the identical name
produces no events at all (`Tests/TimelineCoreTests/DecideTests.swift:43`). `label(forEventType:)`
already answers "Rename project" for it (`History.swift:85`), so the history panel needs nothing.
The only caller today is `ProjectDocument.fork(to:name:using:)` (`ProjectDocument.swift:115`), which
applies the rename as the fork's first transaction.

## 1. Decisions

1. **The surface is a toolbar button next to Fork, opening a sheet.** Reasons, in order:

   - *It belongs beside Fork.* Rename and Fork are the two answers to "this project is called the wrong
     thing", and they differ in exactly one way — Fork makes a new package with a new name, Rename
     changes the name of this one and leaves the package alone. Putting them side by side in the
     document group (New / Open / Fork / Rename / Import) is what makes that difference legible, and the
     sheet's one sentence of copy is where it gets said out loud.
   - *The inspector is clip-scoped.* `InspectorView` shows a clip's properties and a "No clip selected"
     empty state otherwise (`Sources/TimelineUI/InspectorView.swift`). A project field there would be
     hidden exactly when no clip is selected, which is most of the time, and would put a project fact in
     a panel whose every other row is about one clip.
   - *Click-to-edit on the title would lie.* The title is next to the window's proxy-icon position and
     reads as the document's file name; making it editable would strongly imply the `.tlproj` package
     renames with it, which is the one thing this feature must not suggest (decision 3).
   - *A File-menu command with ⌘⇧R is the one thing `ui-style.md` forbids here.* Keyboard says a plain
     ⌘-letter "belongs to a menu", and `TimelineWindowApp` declares no `.commands` at all. Adding a menu
     bar to hang one rename off is more chrome than the feature, and the ⌥⌘ space is reserved for panel
     toggles. **The rename gets no keyboard shortcut**; if a menu bar is ever added, `⌘⇧R` is where this
     goes and the toolbar button stays.

2. **The sheet validates; the core does not.** `decide` accepts any string. The trim, the empty
   rejection, and the length cap live in `ProjectRename` in `TimelineUI`, so they bind the human path
   and leave `renameProject` over MCP exactly as it is. A cap in `decide` would be a `Contracts`-adjacent
   change to a frozen module for a UI concern.

3. **The `.tlproj` package is never touched.** The project name and the package file name are separate
   facts, and the status bar keeps showing `document.url.lastPathComponent` (`Views.swift:541`) beside a
   window title that now says something else. The sheet says so in one line rather than leaving the user
   to discover it: *"The package on disk keeps its file name. Fork is how you make a differently named
   package."*

4. **An unchanged name closes the sheet and sends nothing.** Not an error, not a command, no transaction
   in the history. `ProjectRename.operation` is `nil` in that case, so the no-op is decided before the
   store is reached — `decide`'s own no-op (DecideTests:43) is the backstop, not the mechanism.

5. **The media catalog needs no refresh, and that is structural.** The library panel's rows for the open
   project come from `openProjectItems`, which builds each `CatalogItem` from `viewModel.project.name`
   on every read; `catalogItems` explicitly *excludes* the open project because "its database churns
   while it is edited". So the panel is fresh the moment the store's change lands, with no rescan, and
   the skeleton check asserts exactly that (section 4). The catalog's own `projects` row is stamp-based
   (`SQLiteMediaCatalog.refresh`, size and mtime of `project.sqlite`), so it picks the new name up on
   the next scan after the package is closed and its WAL is folded in — which
   `MediaCatalogTests.theProjectNameComesFromTheStateRowWithoutDecodingIt` already proves, at the layer
   that owns it. Nothing here has to call `refresh()`.

## 2. What is added

`PanelTheme` gains one token, `sheetWidth` 420: a sheet is not a panel and does not take its width from
`PanelLayoutModel`, and a literal frame in new chrome is a review comment. `ui-style.md` and `StyleTests`
record it beside the panel sizes.

### `Sources/TimelineUI/ProjectRenameView.swift`

```swift
public enum ProjectRenameText {          // the copy, shared with the app and the tests
    public static let title = "Rename project"
    public static let field = "Project name"
    public static let packageNote =
        "The package on disk keeps its file name. Fork is how you make a differently named package."
    public static let emptyError = "A project name cannot be blank"
    public static func tooLongError(_ max: Int) -> String
    public static let rename = "Rename"
    public static let cancel = "Cancel"
}

/// What the sheet edits: the name in the store and the one being typed.
public struct ProjectRename: Hashable, Sendable {
    public static let maximumLength = 120
    public let current: String
    public var name: String

    public var trimmed: String            // surrounding whitespace and newlines removed
    public var isUnchanged: Bool          // trimmed == current
    public var validationError: String?   // blank, or longer than the cap
    public var canSubmit: Bool            // no validation error (an unchanged name may be submitted)
    public var operation: Command.Operation?  // nil when invalid or unchanged
}

public struct ProjectRenameSheet: View { ... }
```

`trimmed` is what gets stored, so `"  Reel  "` renames to `"Reel"` and `"   "` is blank. The cap is 120
characters: long enough for any real title, short enough that the window title and a library row stay
one line. `canSubmit` allows the unchanged name deliberately — Return on a sheet you opened by mistake
should close it, not sit there disabled.

The sheet is a `VStack` at `PanelTheme.pageInset` — one field does not want `PublishSheetView`'s
grouped `Form`, whose section cards would be chrome around a single row — holding the title, the field,
a character counter once the name is past half the cap, the package note, the validation or submit
error, and Cancel / Rename on the default and cancel actions. Every number and font is a `PanelTheme`
token (`ui-style.md`): this is new chrome, so the rule applies from the first line.

### `Sources/TimelineApp/Views.swift`

- `AppModel.renaming: ProjectRename?` — non-nil while the sheet is up, the same shape as
  `publish.sheet`.
- `presentRenameSheet()` seeds it from `document.project.name`.
- `commitRename(_:) async -> String?` applies `.renameProject` through `document.apply`, clears
  `lastCommandError` and the sheet on success, and on an `EditorError` — `staleVersion` included — sets
  `lastCommandError` (so the status bar shows it exactly like every other failed action) *and* returns
  the message so the sheet can keep the typed name on screen instead of throwing it away. This is
  `perform`'s behaviour with one addition; `perform` itself returns nothing, so it cannot feed a sheet
  that has to stay open.
- One `Button("Rename", systemImage: "pencil")` in the first `ToolbarItemGroup`, after Fork, disabled
  without a document, and a second `.sheet` on `EditorView` beside the publish one.

Nothing else in `Views.swift` moves. The Export button and `exportReel()` are untouched.

## 3. Tests

`Tests/TimelineUITests/RenameTests.swift`, over `UIFixture`/`FakeProjectStore`:

- trimming, blank and whitespace-only rejection, the cap boundary at 120 and 121, and a name that
  differs from the current one only by surrounding whitespace reading as unchanged;
- `operation` nil for unchanged and for invalid, and carrying the trimmed name otherwise;
- applying it through `viewModel.apply` renames the project, files one transaction labelled "Rename
  project", and undo puts the old name back;
- a store that rejects the command leaves `viewModel.lastError` set and the name alone.

## 4. The skeleton check

A sub-step **11b**, right after Fork, because Fork is what it has to be told apart from. On the reopened
original, it renames "Skeleton" to "Skeleton renamed" through a real `ProjectRename` and asserts: the
name changed, exactly one transaction was added, its history label is "Rename project", the package is
still at `Skeleton.tlproj` and still on disk, a second rename to the same name yields no operation and
no new version, a whitespace-only name is refused by the validator, and a `MediaLibraryModel` over the
document reports the new name for all five of the open project's rows *without a rescan*.

It does **not** assert a catalog rescan, and the reason is worth writing down. `SQLiteMediaCatalog.scan`
upserts on `ON CONFLICT(project_id)`, and a fork carries the original's project id — so in a library
that holds both, the two packages share one `projects` row and the last one scanned wins, with
`discoveredPackages()` returning a `Set` so the order is not even stable. The skeleton check has a fork
by the time it gets here, which makes any assertion about that row a coin flip. The rescan behaviour is
already covered at the layer that owns it, by
`MediaCatalogTests.theProjectNameComesFromTheStateRowWithoutDecodingIt`.

## 5. Left out

- No keyboard shortcut and no menu bar (decision 1).
- No rename of the package on disk, and no offer to (decision 3). Fork already covers "I want a file
  called that".
- No inline editing of the window title, and no change to the status bar's file name.
- No fix for the fork/project-id collision in the catalog (section 4). It is a pre-existing bug —
  a fork and its original share one catalog row — that a rename only makes visible, and fixing it means
  changing the `projects` table's key, which is a `ProjectStore` change with its own migration.
- No rename from the library panel's project list: that list is not rendered anywhere yet
  (`MediaLibraryModel.projects` is loaded and unused), and renaming a project that is not open would
  mean opening its store behind the user's back.
