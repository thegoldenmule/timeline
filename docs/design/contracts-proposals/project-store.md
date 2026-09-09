# ProjectStore: Contracts proposals and implementation notes

Status: written while implementing `Sources/ProjectStore`, 2026-09-08. Nothing here has been applied to
`Contracts`; the module works without it. `storage.md` and `timeline-model.md` still win where they disagree.

## 1. Proposal: `ArtifactCache` protocol (for MediaKit)

`ProjectStore.CacheDatabase` implements `Cache/cache.sqlite` (storage.md section 11). MediaKit cannot import
`ProjectStore` (sibling rule), so the App should hand it the cache through a `Contracts` protocol. Proposed
addition to `Sources/Contracts/MediaLibrary.swift` (plus a `FakeArtifactCache` in `ContractsTestSupport`):

```swift
/// The content-addressed index of derived artifacts (storage.md section 11). Keys are content hashes;
/// `paramsHash` is `AnalysisCacheKey.paramsHash`. Implementations: `ProjectStore.CacheDatabase`.
public protocol ArtifactCache: Sendable {
    /// Remembers that the file with this identity tuple hashes to `contentHash`.
    func rememberMedia(
        contentHash: String, size: Int64, volume: String?, fileId: Int64?, mtime: Date?, libraryPath: String?,
        probe: Probe?) async throws
    /// The hash of an already-indexed file, by `(volume, APFS file id, size, mtime)`; a hint, never an identity.
    func lookupHash(volume: String?, fileId: Int64, size: Int64, mtime: Date) async throws -> String?
    /// The path of an artifact, if one exists for this hash, kind, and parameter hash.
    func artifact(contentHash: String, kind: String, paramsHash: String) async throws -> ArtifactRecord?
    func recordArtifact(contentHash: String, kind: String, paramsHash: String, path: String, summary: JSONValue?)
        async throws
    /// Replaces the indexed words of a transcript.
    func indexTranscript(contentHash: String, words: [TranscriptWord]) async throws
    /// FTS5 search restricted to the given hashes (the `transcript_search` tool).
    func searchTranscript(_ query: String, contentHashes: [String], limit: Int) async throws -> [TranscriptHit]
    func alignment(referenceHash: String, targetHash: String, paramsHash: String) async throws -> Alignment?
    func recordAlignment(referenceHash: String, targetHash: String, _ alignment: Alignment) async throws
}

public struct ArtifactRecord: Hashable, Sendable, Codable {
    public var contentHash: String, kind: String, paramsHash: String, path: String, createdAt: Date
    public var summary: JSONValue?
}

public struct TranscriptHit: Hashable, Sendable, Codable {
    public var contentHash: String, word: String, t0: RationalTime, t1: RationalTime
    public var speaker: String?
}
```

`CacheDatabase` already has these methods with synchronous signatures and its own `ArtifactRecord`,
`TranscriptEntry`, `TranscriptHit`, and `AlignmentRecord` types; conforming is a rename plus an `async` wrapper.
Its `alignment(...)` returns a row (`offset`, `driftPPM`, `confidence`, `status`, candidates JSON) rather than a
full `Alignment`; if MediaKit wants the `Alignment` back, `AlignmentProof` needs to be stored too (it is not,
because it is large and derivable).

## 2. Decisions taken inside the module (no Contracts change)

- **`readonlyBusyMode` is not public in GRDB 7.11.** The writer gets `busyMode = .timeout(5)`; readers keep
  `DatabasePool`'s 10 s default. `PRAGMA busy_timeout` reports 10000 on a reader connection.
- **In-memory stores.** `DatabasePool` cannot be in-memory, so the store holds `any DatabaseWriter`:
  `DatabasePool` for `.tlproj` packages, `DatabaseQueue(":memory:")` for `SQLiteProjectStore.inMemory`, and a
  `DatabaseQueue` for the DELETE-journal fallback (a pool's readers would fight the writer over the journal mode).
- **`commands.received_at` reads the injected `Clock` once per command**, before `decide`. With a stepping
  `FixedClock` this drifts event timestamps by one tick per command relative to `FakeProjectStore`; the parity
  test compares events modulo `occurredAt`. The clock is wrapped so `occurredAt` is rounded to milliseconds,
  which is what the ISO-8601 column holds, so events read back equal the events decided.
- **History labels across a rebuild.** `history.label` is the command's `effectiveLabel`, which is not derivable
  from events (`"Trim clip"` for a ripple trim that emitted `ClipTrimmed` plus `ClipMoved`s). `rebuildProjections`
  reads the labels from the `history` rows before truncating them, falls back to `commands.args` (until pruned),
  then to `Transaction.defaultLabel`. Rebuild is therefore a pure function of the log plus the stored labels.
- **`live` on undo/redo marker rows is 1**; the column is meaningful for edit rows only, and the incremental path
  updates the target's row from the fold after every marker (a recompute, not a pointer table).
- **`importEvents(_:labels:)`** appends an existing log (fixtures, migration) through the incremental projection
  path with no `commands` rows. It is how the tests load `ProjectBuilder` logs and the 10,000-event fixture.
- **`backup(to:)` / `saveAs(to:)`** mark the copy's `session` row `closed` after `VACUUM INTO`, so a copy opens
  without an integrity check. `saveAs` does not copy `renders/`.
- **Recovery also rebuilds when `project_state.version` disagrees with `MAX(stream_version)`**, on top of the
  `projection_state.last_seq` comparisons in storage.md section 12.
- **`decide` already runs `Invariants.check`;** the store runs it again on the folded state as the second line
  of defence storage.md section 6 step 5 asks for. On a small project that is not measurable.

## 3. Measured (release, M4 Max, single run, `swift test -c release --filter ProjectStoreTests`)

| Measurement | Result |
|---|---|
| 1,000 `setClipOpacity` commands on the three-clips fixture, in-memory | 0.18 ms per command |
| Same, on disk (WAL, `synchronous=NORMAL`) | 0.31 ms per command |
| Pure fold of the 10,007-event fixture (`evolve`, decoded events in memory) | 7.4 ms |
| Decoding those 10,007 rows from SQLite (`events(since: 0)`) | 200 ms |
| Open + load of the fixture after a clean close (migrate, checks, load state, load history) | 290 ms |
| `rebuildProjections()` on the fixture (decode + fold + bulk query tables + history + state) | 378 ms |
| `integrity_check` / `VACUUM INTO` on the fixture file | 32 ms / 17 ms |
| Debounced `project_state` write on the small fixture | 0.2 ms |

Decoding dominates: Foundation's `JSONDecoder` on the richer `Clip` snapshots costs about 20 µs per event, four
times the spike's simpler payloads. Open loads the whole log for the in-memory `History`; a lazy history (load
transactions on the first undo) would bring open close to the 39 ms the spike measured.
