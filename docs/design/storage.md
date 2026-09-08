# Storage design: media library, per-project event store, projections

Status: draft for review, 2026-09-08. Scope: single user, single machine, no auth. Companion to `docs/research/README.md`; library and SQLite facts verified in `docs/research/09-storage-sqlite.md`; the schema, write path, undo, and rebuild were exercised in code with measurements on this machine in `spikes/event-store` (GRDB 7.11.1, SQLite 3.51.0, swift-uuidv7 0.6.2). Numbers below come from that run (release build, M4 Max, single run).

## 1. Principles

1. **Originals are immutable and live outside projects.** A project never contains media; it references media by content hash. Deleting a project never deletes footage.
2. **Everything derived is disposable.** Proxies, waveforms, transcripts, shot lists, alignment results live in a cache keyed by content hash and can be regenerated.
3. **The project is an append-only event log.** Every change, whether from the human or the agent, is a domain event. Projections are rebuildable from events at any time.
4. **One write path.** UI, agent tools, and scripts all issue commands to the same handler. The handler validates against current state, emits events, appends them, and updates projections in one SQLite transaction.
5. **Times are exact rationals**, never floats.

## 2. On-disk layout

```
~/Movies/Timeline/                      root, user-configurable
  Library/                              originals, imported by capture date, never modified
    2026/2026-09-08/
      IMG_4471.MOV
      IMG_4471.MOV.json                 sidecar: content hash, probe output, import provenance
      Screen Recording 2026-09-08 at 14.02.11.mov
      band-mix-v3.wav
  Cache/                                derived, content-addressed, safe to delete
    sha256/ab/cd/abcd...ef/
      probe.json
      proxy-540p.mp4
      thumbs/sheet-1fps.jpg, sheet-0.1fps.jpg
      peaks.json                        waveform peaks at 2-3 zoom levels
      onset-8k.f32                      onset envelope for audio alignment
      transcript.json                   words with start/end/confidence/speaker
      silence.json  shots.json  faces.json  ocr.json  loudness.json  beats.json
      descriptions.json  moments.json
    cache.sqlite                        index of the above + FTS5 over transcripts
  Projects/
    Band Rehearsal.tlproj/              directory package (UTI conforms to com.apple.package)
      manifest.json                     format version, app version, project id, library root hint
      project.sqlite                    events + projections (see section 4)
      project.sqlite-wal, -shm          present while open
      renders/                          exports produced from this project, with receipts
        2026-09-08T15-12-00 Reel 9x16.mp4
        2026-09-08T15-12-00 Reel 9x16.json
```

Import copies the original (move and reference-in-place are options) into `Library/YYYY/YYYY-MM-DD/` using the capture date from QuickTime metadata, falling back to file mtime. Name collisions get a numeric suffix. The sidecar JSON records the content hash, the original source path, the import time, and the ffprobe or AVAsset probe. Importing a file already in the library (same hash) is a no-op that returns the existing asset.

Content hash: SHA-256 over the full file via CryptoKit, streamed in 8 MiB chunks off the main actor. Measured on this machine at about 2.3 GB/s on one core, faster than the SSD, so BLAKE3 is not worth a dependency. `cache.sqlite` remembers `(volume UUID, APFS file content identifier, size, mtime) -> sha256` so already-indexed files are recognized instantly; the tuple is a hint, never an identity across volumes.

Why a `.tlproj` package rather than a bare `.sqlite` file: it leaves room for renders and future per-project files while still opening as one document in Finder. The package's UTI conforms to `com.apple.package`. Do not route the database through `NSDocument`'s whole-package rewrite path; open SQLite in place and use `FileWrapper` only for sidecars, the way `NSPersistentDocument` does.

Sync services are the main corruption risk: iCloud Drive and Dropbox copy `project.sqlite` mid-transaction or without its `-wal`. Detect synced locations (`isUbiquitousItemKey`, `~/Library/Mobile Documents`, Dropbox and Drive markers) and warn. If the user insists, open that project with `journal_mode=DELETE` and `synchronous=FULL` so there is one file to sync. Refuse network volumes. `Library/` and `Cache/` also stay on local disk.

## 3. SQLite configuration

- **Library: GRDB 7.x** (MIT, Swift 6 language mode, links the system `libsqlite3`). `DatabasePool` per open project (one writer, concurrent readers), `DatabaseMigrator` for schema versions, `ValueObservation` to drive SwiftUI from projection tables (verified to deliver changes from a plain CLI process with `.async(onQueue:)` scheduling). `DatabaseMigrator` records applied migrations in its own `grdb_migrations` table and leaves `PRAGMA user_version` at 0; that table is the schema-version source of truth, and each migration also sets `user_version` for external tooling. SQLiteData and StructuredQueries are attractive but still 0.x; revisit at 1.0.
- **System SQLite is 3.51.0** on macOS 26.3 (verified): JSONB, STRICT, generated columns, RETURNING, upsert, FTS5, `VACUUM INTO` all available; runtime extensions are compiled out. Apple's build predates the 3.51.3 fix for a WAL-reset corruption bug, so run `integrity_check` after unclean shutdowns and keep the option of a custom SQLite build.
- Pragmas: `journal_mode=WAL` (set by `DatabasePool`), `synchronous=NORMAL` via `Configuration.prepareDatabase`, `foreign_keys=ON`, busy timeout 5 s on the writer and 10 s on readers (`busyMode` and `readonlyBusyMode`), `wal_checkpoint(TRUNCATE)` and `PRAGMA optimize` on idle and on close. The WAL stays under 5 MB under sustained editing thanks to the default autocheckpoint; truncation on close leaves an empty `-wal` file until the last connection closes, which is normal.
- All tables `STRICT`. **JSON payloads are stored as `TEXT`**, not JSONB: diffable in the CLI, portable, and GRDB's JSON helpers expect text. Hot fields get `VIRTUAL` generated columns with partial indexes, which the planner uses (`SEARCH events USING INDEX events_clip_idx`) at no measurable insert cost. JSONB buys nothing here: raw appends run at about 70,000 events per second with text payloads and three indexes, and the one serialization cost that matters (section 5) is Swift-side JSON encoding, not SQLite parsing.
- IDs are UUIDv7 (time-ordered, append-friendly indexes) via the `swift-uuidv7` package until Foundation's `UUID.version7` ships; stored as lowercase `TEXT` for debuggability. Switch to 16-byte `BLOB` only if index size becomes a concern.
- Backups via `VACUUM INTO` to a temp file then atomic rename, never by copying the live file. Save As is `VACUUM INTO`.
- The app process is the only writer. The agent's MCP tools call into the same process, so there is no multi-process write contention.

## 4. Schema: event store

```sql
-- Append-only. Never UPDATE or DELETE rows here.
CREATE TABLE events (
  seq            INTEGER PRIMARY KEY,           -- global order, autoincrement via rowid
  event_id       TEXT    NOT NULL UNIQUE,       -- UUIDv7 (time-ordered)
  stream_id      TEXT    NOT NULL,              -- 'project' for now; per-sequence streams later
  stream_version INTEGER NOT NULL,              -- 1..n within the stream
  type           TEXT    NOT NULL,              -- 'ClipTrimmed'
  schema_version INTEGER NOT NULL DEFAULT 1,    -- payload shape version for upcasting
  payload        TEXT    NOT NULL,              -- JSON
  occurred_at    TEXT    NOT NULL,              -- ISO-8601 UTC with ms
  actor          TEXT    NOT NULL,              -- 'human' | 'agent:<sessionId>' | 'system'
  txn_id         TEXT    NOT NULL,              -- groups events from one command; the undo unit
  command_id     TEXT    NOT NULL,              -- idempotency key supplied by the caller
  causation_id   TEXT,                          -- event_id that caused this (e.g. undo of X)
  metadata       TEXT,                          -- JSON: tool name, tool args hash, agent turn id
  -- indexed hot fields pulled from the payload without duplicating it
  clip_id        TEXT AS (json_extract(payload, '$.clipId')) VIRTUAL,
  UNIQUE (stream_id, stream_version)            -- optimistic concurrency
) STRICT;
CREATE INDEX events_clip_idx ON events(clip_id) WHERE clip_id IS NOT NULL;

CREATE INDEX events_type_idx ON events(type);
CREATE INDEX events_txn_idx  ON events(txn_id, seq);   -- covering: undo reads a txn's events index-only

-- Every accepted command, including ones that produced zero events.
-- Enables exactly-once semantics when an agent retries a tool call.
CREATE TABLE commands (
  command_id   TEXT PRIMARY KEY,
  received_at  TEXT NOT NULL,
  actor        TEXT NOT NULL,
  name         TEXT NOT NULL,                   -- 'trimClip'
  args         TEXT NOT NULL,                   -- JSON
  result       TEXT NOT NULL,                   -- JSON: { txnId, firstSeq, lastSeq, version, changedIds, warnings }
  status       TEXT NOT NULL CHECK (status IN ('applied','stale','invalid','noop'))
                                                -- stale = version conflict; invalid = failed validation
) STRICT;
```

The `UNIQUE (stream_id, stream_version)` constraint is the concurrency guard. A command carries `expectedVersion`; the handler inserts events at `expectedVersion + 1 ...` inside a transaction, and a conflict fails the insert. The caller (agent or UI) gets a compact diff of what changed since its version and retries.

For now there is one stream, `project`. If projects grow to hold several sequences (a reel and a long cut from the same footage), each sequence becomes its own stream and `stream_version` gives per-sequence concurrency without global locks.

## 5. Schema: projections

Two read models, both rebuildable from `events`.

**The full state document.** A single row holding the entire `Project` value as JSON. This is what `TimelineCore` loads into memory and what the compiler consumes. Its cost scales with project size, not event count: at 10,000 clips the document is 1.5 MB and Foundation's `JSONEncoder` needs about 40 ms to write it and `JSONDecoder` 35 ms to read it, while at 1,000 clips both are a few milliseconds. Rewriting it inside every command transaction would therefore cap interactive editing at roughly 45 commands per second on a large project (a drag emitting one `ClipMoved` per frame would feel it), so the row is written on a debounce (about 250 ms after the last command) and on close, not per command. The authoritative state lives in memory while the project is open; `last_seq` records which events the row reflects, and `open` folds any newer events on top (a pure fold of 10,000 events takes 45 ms). With a tiny state the whole write path including this row costs 0.16 ms per command; the debounce is what keeps that true as projects grow.

```sql
CREATE TABLE project_state (
  id           INTEGER PRIMARY KEY CHECK (id = 1),
  version      INTEGER NOT NULL,                -- stream_version this state reflects
  last_seq     INTEGER NOT NULL,
  state        TEXT    NOT NULL                 -- JSON Project
) STRICT;
```

**Query tables.** Normalized rows for the UI, the agent's `timeline_query`, and reports. They exist so that "clips on track V2 between 10 s and 40 s" or "every clip using asset X" is a SQL query rather than a JSON scan.

```sql
CREATE TABLE assets (
  asset_id      TEXT PRIMARY KEY,
  content_hash  TEXT NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('video','audio','image')),
  library_path  TEXT NOT NULL,                  -- relative to Library root
  display_name  TEXT NOT NULL,
  duration_v    INTEGER NOT NULL, duration_ts INTEGER NOT NULL,   -- rational {value, timescale}
  has_video     INTEGER NOT NULL, has_audio INTEGER NOT NULL,
  probe         TEXT,                           -- JSON summary: codec, fps, size, color, rotation, captured_at, gps
  removed       INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE tracks (
  track_id   TEXT PRIMARY KEY,
  kind       TEXT NOT NULL CHECK (kind IN ('video','audio','caption')),
  position   INTEGER NOT NULL,                  -- z-order / display order
  name       TEXT NOT NULL,
  muted      INTEGER NOT NULL DEFAULT 0,
  locked     INTEGER NOT NULL DEFAULT 0,
  removed    INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE clips (
  clip_id     TEXT PRIMARY KEY,
  track_id    TEXT NOT NULL REFERENCES tracks(track_id),
  asset_id    TEXT REFERENCES assets(asset_id), -- NULL for generated clips (title, color)
  start_v     INTEGER NOT NULL, start_ts INTEGER NOT NULL,      -- timeline position
  in_v        INTEGER NOT NULL, in_ts    INTEGER NOT NULL,      -- source in point
  out_v       INTEGER NOT NULL, out_ts   INTEGER NOT NULL,      -- source out point, exclusive
  speed_num   INTEGER NOT NULL DEFAULT 1, speed_den INTEGER NOT NULL DEFAULT 1,
  props       TEXT,                             -- JSON: transform, effects, transitions, audio, label
  removed     INTEGER NOT NULL DEFAULT 0
) STRICT;
CREATE INDEX clips_track_start_idx ON clips(track_id, start_v) WHERE removed = 0;
CREATE INDEX clips_asset_idx ON clips(asset_id) WHERE removed = 0;

CREATE TABLE captions (
  caption_id  TEXT PRIMARY KEY,
  track_id    TEXT NOT NULL REFERENCES tracks(track_id),
  start_v INTEGER NOT NULL, start_ts INTEGER NOT NULL,
  end_v   INTEGER NOT NULL, end_ts   INTEGER NOT NULL,
  text        TEXT NOT NULL,
  words       TEXT,                             -- JSON [{text,t0,t1}]
  style       TEXT,
  removed     INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE markers (
  marker_id TEXT PRIMARY KEY, at_v INTEGER NOT NULL, at_ts INTEGER NOT NULL,
  label TEXT NOT NULL, color TEXT, removed INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE alignments (                       -- audio alignment facts, one per (reference, target)
  reference_asset TEXT NOT NULL, target_asset TEXT NOT NULL,
  offset_num INTEGER NOT NULL, offset_den INTEGER NOT NULL,   -- seconds as rational
  drift_ppm  REAL NOT NULL, confidence REAL NOT NULL,
  candidates TEXT, computed_at TEXT NOT NULL,
  PRIMARY KEY (reference_asset, target_asset)
) STRICT;

CREATE TABLE renders (
  render_id TEXT PRIMARY KEY, requested_at TEXT NOT NULL, completed_at TEXT,
  preset TEXT NOT NULL, output_path TEXT, output_hash TEXT,
  project_version INTEGER NOT NULL,             -- what was rendered
  status TEXT NOT NULL CHECK (status IN ('queued','running','done','failed','cancelled')),
  receipt TEXT                                  -- JSON: settings, duration, warnings
) STRICT;

-- Undo model, derived from events: one row per txn.
CREATE TABLE history (
  txn_id      TEXT PRIMARY KEY,
  first_seq   INTEGER NOT NULL, last_seq INTEGER NOT NULL,
  actor       TEXT NOT NULL,
  label       TEXT NOT NULL,                    -- 'Trim clip', 'Agent: add captions to V1'
  undone_by   TEXT REFERENCES history(txn_id),  -- set when a compensating txn reverts this one
  undoes      TEXT REFERENCES history(txn_id)   -- set on the compensating txn
) STRICT;

CREATE TABLE projection_state (
  name     TEXT PRIMARY KEY,                    -- 'project_state', 'query_tables', 'history'
  last_seq INTEGER NOT NULL
) STRICT;
```

Rows are soft-deleted (`removed = 1`) so that history queries and relinking still work; the in-memory `Project` simply omits removed items.

## 6. Write path

```
Command (from UI, MCP tool, or script)
  { commandId, expectedVersion, actor, name, args }
        |
        v
CommandHandler.apply(command) -- one SQLite transaction
  1. if commands[commandId] exists -> return stored result (idempotent retry)
  2. load Project from project_state (already in memory while open)
  3. if expectedVersion != state.version -> reject with { currentVersion, changedSince: diff }
  4. validate args against state (clip exists, times within asset, no overlap unless allowed)
  5. decide events: [DomainEvent]  (pure function in TimelineCore, no I/O)
  6. append events with stream_version = version+1..., same txn_id
  7. fold events into the in-memory Project (pure); schedule the debounced project_state write
  8. update query tables and history from the same events
  9. insert commands row with result (status applied | stale | invalid | noop)
  10. commit; publish { txnId, version, changedIds } to observers (UI, agent)
```

Steps 5 and 7 are the pure core: `decide(state, command) throws -> [Event]` and `evolve(state, event) -> state`. They are unit-tested without SQLite. The handler is a thin adapter around them. The store and the replay loop call an `inout` form, `evolve(&state, event)`: the value-returning form copies the clip dictionary on every event because the argument is not uniquely referenced, which turned a 45 ms fold of 10,000 events into 641 ms.

Idempotency: every command carries a `commandId` (UUIDv7) generated by the caller. Agent tool calls get one per invocation, so a retried tool call after a timeout returns the original result instead of applying twice. The lookup runs before the version check, so a retry of an already-applied command is not misreported as stale. Stale, invalid, and no-op outcomes are recorded too, so a retry of a rejected command returns the same rejection instead of being re-evaluated against a changed document; a caller that wants a fresh attempt uses a new `commandId`, which is what the MCP tool hint tells the agent to do. A single `DatabasePool` writer means two handlers cannot interleave in one process, but the `UNIQUE (stream_id, stream_version)` constraint was confirmed to reject a forced conflicting insert with `SQLITE_CONSTRAINT_UNIQUE` and roll the transaction back, so it stands as the second line of defence for bugs or a second process.

The `commands` table holds `args` and `result` JSON per command and was about 40% of the file in a 10,000-command run (14 MB total, roughly 1.4 KB per event all-in). Idempotency needs only a short window and the events already carry actor and tool metadata, so rows older than 30 days are pruned on open.

Batching: `timeline_apply({ ops: [...] })` is a single command that produces many events under one `txn_id`, so it is one undo step and one version bump.

## 7. Event catalog

Events are facts in past tense, named `<Aggregate><Verb>`. Payloads carry both before and after values where a change is not otherwise invertible, so any transaction can be compensated without replaying the whole log. IDs are UUIDv7 strings. Times are `{ "v": 12345, "ts": 48000 }`.

| Type | Payload (abridged) |
|---|---|
| `ProjectCreated` | `{ name, settings: { frameRate: {num,den}, width, height, sampleRate, colorSpace, blendSpace: gamma\|linear, alignment?: AlignmentParameters } }` |
| `ProjectSettingsChanged` | `{ before, after }` |
| `ProjectRenamed` | `{ before, after }` |
| `AssetImported` | `{ assetId, contentHash, libraryPath, displayName, kind, duration, probe }` |
| `AssetRelinked` | `{ assetId, before: libraryPath, after: libraryPath }` |
| `AssetRemoved` / `AssetRestored` | `{ assetId }` |
| `AssetAnalysisRecorded` | `{ assetId, kind: transcript\|shots\|silence\|..., cacheKey, summary }` (the data lives in Cache; the event records that it exists and its hash) |
| `TrackAdded` | `{ trackId, kind, position, name }` |
| `TrackRemoved` / `TrackRestored` | `{ trackId }` |
| `TrackReordered` | `{ trackId, before: position, after: position }` |
| `TrackRenamed`, `TrackMuteSet`, `TrackLockSet` | `{ trackId, before, after }` |
| `ClipAdded` | `{ clipId, trackId, assetId?, start, in, out, props }` |
| `ClipRemoved` | `{ clipId, snapshot }` (full clip so undo is a `ClipAdded`) |
| `ClipMoved` | `{ clipId, before: {trackId,start}, after: {trackId,start} }` |
| `ClipTrimmed` | `{ clipId, edge: head\|tail, before: {start,in,out}, after: {start,in,out} }` |
| `ClipSplit` | `{ clipId, at, newClipId }` |
| `ClipsJoined` | `{ keptClipId, removedClipId, removedSnapshot }` |
| `ClipSpeedSet` | `{ clipId, before, after }` |
| `ClipTransformSet` | `{ clipId, before, after }` |
| `ClipAudioSet` | `{ clipId, before, after }` (gain, fades, mute) |
| `ClipEffectAdded` / `ClipEffectChanged` / `ClipEffectRemoved` | `{ clipId, effectId, before?, after? }` |
| `ClipTransitionSet` / `ClipTransitionCleared` | `{ clipId, edge, before?, after? }` |
| `CaptionTrackAdded` | `{ trackId, language, style }` |
| `CaptionsReplaced` | `{ trackId, before: [items], after: [items] }` (bulk, from transcript) |
| `CaptionEdited` | `{ captionId, before, after }` |
| `CaptionStyleSet` | `{ trackId, before, after }` |
| `MarkerAdded` / `MarkerMoved` / `MarkerRemoved` | `{ markerId, ... }` |
| `AudioAlignmentComputed` | `{ referenceAssetId, targetAssetId, offset, driftPpm, confidence, candidates, method }` |
| `AudioAlignmentApplied` | `{ alignmentRef, clipId, before: {start}, after: {start}, driftCorrectedAssetId? }` |
| `RenderRequested` / `RenderCompleted` / `RenderFailed` | `{ renderId, preset, projectVersion, outputPath?, outputHash?, error? }` |
| `TransactionUndone` / `TransactionRedone` | `{ targetTxnId }` (marker event; the compensating events follow in the same txn) |

Schema evolution: `schema_version` on each row plus upcaster functions `upcast(type, version, payload) -> payload@latest` applied on read. Old events are never rewritten.

## 8. In-memory model and time

`TimelineCore.Project` is a `Sendable` value type mirroring the JSON in `project_state`, with `clips` and `tracks` as dictionaries keyed by id so that a sorted-keys encoder yields a canonical, order-independent document. Times are `RationalTime { value: Int64, timescale: Int32 }` (the shape of `CMTime` without flags), encoded as `{ "v": ..., "ts": ... }` in JSON and as two `INTEGER` columns (with `CHECK (x_ts > 0)`) in query tables; never as a `"48048/24000"` string, which would defeat `json_extract` generated columns on time fields. A single project-wide timescale was rejected: it forces lossy rounding as soon as 23.976 fps video meets 48 kHz audio or a 29.97 clip lands in a 25 fps sequence. Instead each sequence has a canonical frame duration (for example `1001/24000`) and `decide` snaps edit points to it, so projections compare with integer arithmetic; audio offsets from alignment keep their sample-rate timescale. Mixed-rate comparisons cross-multiply in 128-bit, never rescale-and-store. Persist durations rather than end times where a range is stored, matching OTIO and FCPXML semantics. Conversion to `CMTime` happens only in `RenderKit`.

## 9. Undo and redo

Undo never deletes events. Undo of transaction T appends a new transaction U containing a `TransactionUndone { targetTxnId: T }` marker followed by compensating events computed from T's payloads (each event type has `invert(event) -> [Event]`, made possible by the before/after payloads). `history.undone_by` links T to U. Redo of T appends another compensating transaction that reverts U.

The undo stack shown to the human is `history` filtered to `actor = 'human'` plus agent transactions that the human chooses to see, ordered by `first_seq`, excluding rows already undone. Agent transactions are labelled with the tool name and are undoable as units, which is what makes the agent safe to let loose: one keystroke reverts an entire agent turn.

## 10. Agent concurrency

The human and the agent share one write path and one version counter. An agent tool call carries the `expectedVersion` it last saw. If the human edited in between, the command is rejected with a diff, the agent re-reads, and retries with a new `commandId`. This is optimistic locking, deliberately simpler than a CRDT; concurrent edits are seconds apart, not simultaneous.

Every agent tool invocation is also recorded in `commands` with the tool name and argument hash in `metadata`, so "what did the agent do and why" is answerable from the project alone.

## 11. Cache database

`Cache/cache.sqlite` indexes derived artifacts by content hash and is shared across projects.

```sql
CREATE TABLE media (
  content_hash TEXT PRIMARY KEY, size INTEGER NOT NULL, apfs_file_id INTEGER, mtime TEXT,
  library_path TEXT, probe TEXT, first_seen TEXT NOT NULL
) STRICT;
CREATE TABLE artifacts (
  content_hash TEXT NOT NULL REFERENCES media(content_hash),
  kind TEXT NOT NULL,                           -- 'proxy-540p', 'peaks', 'onset-8k', 'transcript', ...
  params_hash TEXT NOT NULL,                    -- hash of generator version + parameters
  path TEXT NOT NULL, created_at TEXT NOT NULL, summary TEXT,
  PRIMARY KEY (content_hash, kind, params_hash)
) STRICT;
CREATE VIRTUAL TABLE transcript_words USING fts5(content_hash UNINDEXED, t0 UNINDEXED, t1 UNINDEXED, speaker UNINDEXED, word);
```

`transcript_search` in the agent's tool set is an FTS5 query filtered to the content hashes present in the current project. Deleting the Cache directory loses nothing that cannot be regenerated; `AssetAnalysisRecorded` events tell the app what to regenerate.

## 12. Rebuild and recovery

`rebuildProjections()` truncates `project_state`, the query tables, and `history`, then folds all events in `seq` order. This is the recovery path for any projection bug and the migration path when a projection schema changes: add a migration that drops and recreates the projection tables, replay. The fold itself is fast (45 ms for 10,000 events, decode included) and the rebuilt `project_state` was byte-equal to the incrementally maintained one at 6 and at 10,000 events, as were the `clips` and `history` rows. What is not fast is writing the query tables one upsert per transaction during replay (1.8 s for 10,000 events at about 80 microseconds per row), so rebuild writes `clips`, `captions`, and `markers` in bulk from the final state, and only `history` is derived per transaction. The rule that makes the equality test meaningful: projection writes are a pure function of the state after a transaction and the events in it.

Measured maintenance costs on a 14 MB project: open, migrate, and load the 10,000-clip state in 39 ms (35 ms of it JSON decoding); `VACUUM INTO` in 19 ms; `integrity_check` in 27 ms. All three are cheap enough to run on every open and close.

Corruption defense: `PRAGMA integrity_check` on open when the previous session did not close cleanly; a `VACUUM INTO` backup before any migration; the Library sidecars allow rebuilding `assets` even if a project file is lost.

## 13. Testing the store

- `decide` and `evolve` are pure: property tests that for every command, `evolve*(state, decide(state, cmd))` satisfies invariants (no overlaps per track, `in < out <= duration`, times on frame boundaries), and that `invert` composed with the original is identity.
- Round trip: `Project -> JSONB -> Project` equality; every event type has a fixture JSON per `schema_version` and an upcaster test.
- Store tests run against an in-memory SQLite: append with stale `expectedVersion` is rejected; duplicate `commandId` returns the stored result and appends nothing; `rebuildProjections()` reproduces `project_state` byte-for-byte.
- A golden project fixture (a few hundred events) replayed in CI guards against event-schema drift.

## 14. Open decisions

1. **Per-sequence streams.** Deferred until a project needs more than one sequence.
2. **Event payload size for bulk operations.** `CaptionsReplaced` with thousands of words could be large; acceptable as a text payload, but cap at a few MB and split otherwise.
Resolved 2026-09-08: Swift SQLite library is GRDB 7.x (section 3). Cache location is `~/Movies/Timeline/Cache`; `~/Library/Caches` is not used because macOS purges it under disk pressure. Import copies originals into `Library/` by default, with move and reference-in-place (relink by content hash) as options.
