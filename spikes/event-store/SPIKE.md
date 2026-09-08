# Event-store spike (GRDB + SQLite, event-sourced project file)

Throwaway but inspectable code under `spikes/event-store/`. Run: `swift run -c release EventStoreSpike [output-dir]`.
Files: `Sources/EventStoreSpike/Core.swift` (pure core), `Store.swift` (schema + write path + rebuild), `main.swift` (checks + benchmarks). 604 lines total.

Machine: macOS 26.3, Apple M4 Max, Xcode toolchain Swift 6.3.3, swift-tools-version 6.2 (the `.macOS(.v26)` platform enum needs PackageDescription 6.2, not 6.0), Swift 6 language mode.

## Versions

| Item | Resolved |
|---|---|
| GRDB.swift | **7.11.1** (linked against the system `libsqlite3`, no custom SQLite) |
| swift-uuidv7 (mhayes853) | **0.6.2**, product `UUIDV7`; `UUIDV7().uuidString` works, no fallback generator needed |
| `SELECT sqlite_version()` through GRDB | **3.51.0** (matches the design's stated system SQLite) |
| Pragmas seen on a reader connection | `journal_mode=wal synchronous=1 (NORMAL) foreign_keys=1 busy_timeout=10000 user_version=0` |

Notes on the pragmas:
- `DatabasePool` turns on WAL itself; `synchronous=NORMAL` set via `Configuration.prepareDatabase`; `foreign_keys` is on by GRDB default (made explicit).
- `busy_timeout` reads 10000 not 5000: `Configuration.busyMode = .timeout(5)` applies to the writer, but `DatabasePool` defaults `readonlyBusyMode` to `.timeout(10)` for reader connections. Harmless; set `readonlyBusyMode` explicitly if the design wants one number.
- `user_version` stays 0: GRDB's `DatabaseMigrator` tracks applied migrations in its own `grdb_migrations` table, not in `PRAGMA user_version`. storage.md section 3 says "`PRAGMA user_version` owned by the migrator"; either accept `grdb_migrations` as the source of truth or set `user_version` manually in each migration.

## Schema features (all worked on system SQLite 3.51.0 through GRDB)

| Feature | Result |
|---|---|
| `STRICT` on all 6 tables | Accepted; inserting `'not-an-int'` into an INTEGER column fails with `SQLITE_CONSTRAINT_DATATYPE` (3091) |
| `clip_id TEXT AS (json_extract(payload,'$.clipId')) VIRTUAL` | Created; `pragma_table_xinfo` reports `hidden=2` (virtual generated) |
| Partial index `events_clip_idx ... WHERE clip_id IS NOT NULL` on the generated column | Created and used: `EXPLAIN QUERY PLAN` shows `SEARCH events USING INDEX events_clip_idx (clip_id=?)` |
| `UNIQUE (stream_id, stream_version)` | Enforced, see concurrency below |
| `INSERT ... RETURNING seq` | Works through `Int64.fetchOne(statement, arguments:)` on a cached statement; used for every event append |
| Upsert `ON CONFLICT(...) DO UPDATE SET ... = excluded.x` | Works; used for `project_state`, `clips`, `projection_state` |
| Self-referencing FKs on `history(undone_by, undoes)` with `foreign_keys=ON` | Works |
| `VACUUM INTO`, `wal_checkpoint(TRUNCATE)` (`db.checkpoint(.truncate)`), `PRAGMA optimize`, `integrity_check` | All work |

## Write-path behaviour observed

All in one `DatabasePool.write` transaction, in the order of storage.md section 6.

- **Idempotency.** Same `commandId` re-sent with the same args: the stored `commands.result` JSON is returned (`replayed=true`, same `txnId`, same version), nothing appended. The lookup happens before the version check, so a retried command whose original was accepted is not rejected as stale. Rejected and no-op commands are also recorded in `commands` (status `rejected` / `noop`), so a retry of a rejected command returns the rejection rather than being re-evaluated. If that is not wanted, do not record rejections (but then step 1 cannot make retries of rejections cheap).
- **Optimistic concurrency, application level.** `expectedVersion != project_state.version` returns `status: rejected, version: current` (no throw, no events). The spike does not compute `changedSince`; that is a `SELECT ... FROM events WHERE stream_version > ?` away.
- **Optimistic concurrency, constraint level.** Simulated race: after a command moved the stream from 2 to 3, a second writer that had also read version 2 tried to insert `stream_version = 3`. SQLite raised `SQLITE_CONSTRAINT_UNIQUE` (2067) `UNIQUE constraint failed: events.stream_id, events.stream_version`; GRDB rolled the transaction back; the event count stayed at 3. So the constraint is a real second line of defence even if two in-process handlers both pass step 3 (which cannot happen with a single `DatabasePool` writer, but would in a bug or a second process).
- **Validation failure** (`removeClip` of an unknown id) throws out of `pool.write`, which rolls back; nothing is written, including no `commands` row. Decide whether validation failures should be recorded as `rejected` too (they are not distinguishable from concurrency rejections in the current `status` CHECK).
- **No-op commands** (a move to the current position) produce zero events, no version bump, and a `commands` row with `status='noop'`.
- **Undo.** `undo(txnId)` loads T's events inside the same transaction, `decide` returns `[TransactionUndone{targetTxnId}] + T.events.reversed().flatMap(invert)`, appended under a new `txn_id`; `history.undone_by` on T and `history.undoes` on U are set. A second undo of T is rejected (`alreadyUndone`) by checking `undone_by`. State after undoing a trim that followed a move: trim reverted, move kept, and the `clips` row matches. Redo was not implemented (it is "undo the undo" per section 9 and needs no new machinery beyond skipping the marker's own inversion, which `invert(.transactionUndone) -> []` already does).
- **ValueObservation** on `SELECT count(*) FROM clips WHERE removed = 0` with `.async(onQueue:)` scheduling delivered the initial value and then a new value after one `apply` ([1, 2]). Works from a plain command-line process, no run loop needed.

## Rebuild

`rebuildProjections()` deletes `project_state`, `clips`, `history`, `projection_state` and folds all events by `seq`, regrouping by `txn_id` for history. Compared against the incrementally maintained copies captured before truncation:

- `project_state.state` JSON: **byte-equal** (6-event DB and 10,000-event DB), using `JSONEncoder` with `[.sortedKeys, .withoutEscapingSlashes]` and `Project.clips`/`tracks` as dictionaries keyed by id (so the encoder's key sort gives order independence for free).
- `clips` rows and `history` rows: equal as GRDB `Row` arrays in both runs.

## Benchmarks (release build, M4 Max, WAL, synchronous=NORMAL)

| Measurement | Result |
|---|---|
| Append 10,000 single-event commands, one `apply` (one transaction) each, state grows to 10k clips | 220.3 s total, **45 commands/s, 22.0 ms/command** (dominated by re-encoding the full-state JSON; see below) |
| Same, but state stays tiny (alternating add/remove) | 1.59 s total, **6,298 commands/s, 0.16 ms/command** |
| Raw `INSERT ... RETURNING seq` of 10,000 events in one transaction, no projections (floor) | 0.143 s, **69,770 events/s** |
| Full-state JSON at 10k clips (1.52 MB) | decode 35.5 ms; encode 40.2 ms with `sortedKeys`, 33.2 ms plain |
| DB file size after 10k events + projections | 14.27 MB main file, WAL 4.80 MB at that moment |
| Replay 10,000 events, pure fold (decode payload + `evolve`) | **45 ms** |
| `rebuildProjections()` on 10,000 events (fold + `clips`/`history` writes + state rewrite) | 1.78 s (cached statements); byte-equal state, clips, history |
| WAL before close / after `wal_checkpoint(TRUNCATE)` | 3.52 MB / 0 bytes (empty `-wal` file remains until last connection closes) |
| Open + migrate + load `project_state` (10k clips) | 39.4 ms (34.4 ms of it is decoding the state JSON) |
| `VACUUM INTO` copy of the 14.3 MB file | 19.3 ms, copy is 12.43 MB |
| `PRAGMA integrity_check` | ok, 27.0 ms |

Reading the numbers:
- **Raw event append is not the bottleneck.** 10k inserts in one transaction run at ~70k events/s with `RETURNING seq`, TEXT JSON payloads and three indexes including the `json_extract` generated-column partial index. Generated columns and TEXT JSON are fast enough; no reason to consider JSONB for `payload`.
- **One command per transaction with a tiny state costs ~0.16 ms** (~6.3k commands/s) including the `commands` row, the `clips` upsert, `history` insert, and a full-state rewrite. That is the realistic interactive editing cost while a project is small.
- **The full-state document is the cost that grows.** With 10k clips the state is 1.52 MB and Foundation's `JSONEncoder` takes ~40 ms to produce it with `sortedKeys` (33 ms without; sorting is not the main cost), `JSONDecoder` ~35 ms to read it. The 10k growing-state run averaged 22 ms/command purely from this encode. This contradicts section 5's "rewriting it per command is cheap": at 1k clips it is ~4 ms (fine), at 10k clips it dominates and will be felt as latency during scrubbing-style edits (e.g. a drag emitting a `ClipMoved` per frame).
- **Replay** of 10k events as a pure fold (decode + evolve) is 45 ms after fixing an accidental O(n²) in `evolve` (see friction). `rebuildProjections` including the per-txn `clips`/`history` writes is 1.78 s (1.9 s before switching projection writes to `cachedStatement`). The remaining cost is ~20k per-row upserts/inserts at ~80 µs each plus a `history` UPDATE per undo; batching the `clips` projection into a single `INSERT ... SELECT` from the final state, rather than per-txn upserts, would bring rebuild close to the 45 ms fold. Section 12's "well under a second" holds for the fold, not yet for the query tables.
- **Open + load** of a 10k-clip project: ~39 ms, of which ~35 ms is decoding the 1.5 MB state JSON. Migration check, WAL open and pragmas are ~4 ms.
- **WAL.** The WAL grew to 3.5 to 4.8 MB during the run (SQLite's default 1000-page autocheckpoint keeps it bounded). `wal_checkpoint(TRUNCATE)` on close left a 0-byte `-wal` file (the file remains, empty, until the last connection closes; that is normal).
- **`VACUUM INTO`** of a 14.3 MB database: ~20 ms, producing a 12.4 MB copy (freelist pages dropped). `integrity_check`: 27 ms. Both are cheap enough to run on every save/close.
- **Disk.** 10k events + projections = 14.3 MB, i.e. ~1.4 KB/event all-in. The events table itself is roughly half; `commands` (which duplicates args and result JSON per command) is a large part of the rest.

## Swift 6 concurrency friction

- Minor. `ProjectStore` is a `final class: Sendable` holding a `DatabasePool` (Sendable) and a `Mutex<Project?>` from `Synchronization` for the in-memory state. `pool.write { db in ... }` closures are synchronous and non-`@Sendable`, so capturing a non-Sendable `Command` or local `var` is fine.
- `DatabaseMigrator` as a `static let` compiled without complaint (it is Sendable).
- `JSONEncoder` is Sendable in this SDK, so a global canonical encoder needs no `nonisolated(unsafe)` (the compiler warns if you add it).
- `ValueObservation.start(onChange:)` requires a `@Sendable` closure; collecting results needs `Mutex` or an actor, not a captured `var`.
- Not GRDB-specific but bit me: a `CustomStringConvertible` whose `description` is `"\(self)"` recurses infinitely and segfaults the process with no output (exit 139). Removed.
- Performance trap in the pure core: `func evolve(_ state: Project, _ e: Event) -> Project { var s = state; ...; return s }` called as `state = evolve(state, e)` copies the whole `clips` dictionary on every event because `state` is not uniquely referenced inside the function. 10k-event fold: 641 ms with the copy, 45 ms with an `inout` overload. Keep the pure signature for tests but make the store and the replay loop use `evolve(&state, e)`.

## Recommended changes to storage.md

1. **Full-state projection cadence (section 5, 6 step 7).** Do not rewrite `project_state` on every command once the project is non-trivial. Options, in order of preference: (a) keep the authoritative `Project` in memory and write `project_state` on a debounce (e.g. 250 ms idle) and on close, with `last_seq` telling `open` how many events to fold on top after a crash; (b) snapshot every N events; (c) both. Recovery cost is bounded by the 45 ms/10k-event fold. Measured: 40 ms encode (33 ms without sortedKeys) + 35 ms decode per 1.5 MB at 10k clips with Foundation JSON.
2. **Faster JSON for the state document.** If per-command rewrite is kept, the encoder is the bottleneck, not SQLite. Measure `swift-foundation`'s newer encoder path, or a hand-rolled streaming writer. JSONB for `project_state.state` would not help: the cost is Swift-side serialization, not SQLite parsing. Drop the "JSONB if measured to matter" clause for `project_state`; the measurement says no.
3. **`RationalTime` encoding.** `{ "v": Int64, "ts": Int32 }` in JSON and `x_v INTEGER, x_ts INTEGER` in query tables worked with zero friction; STRICT `INTEGER` holds Int64. Keep it. Consider a `CHECK (x_ts > 0)` on the query tables. Do not store as a string like `"48048/24000"`: it would defeat `json_extract` → generated-column indexing on time fields if you ever want `start_v` as a generated column.
4. **`commands` table size.** It stores `args` and `result` JSON for every command, ~40% of the file in this run. Either compress/omit `args` for human UI commands (they are recoverable from the events), or add a retention policy (drop `commands` rows older than N days; idempotency only needs a short window).
5. **Migrator versioning (section 3).** Replace "`PRAGMA user_version` owned by the migrator" with "GRDB's `grdb_migrations` table owned by `DatabaseMigrator`", or explicitly set `user_version` in each migration for tooling that reads it.
6. **`busy_timeout`.** Specify writer 5 s and reader 10 s (GRDB pool default), or set `readonlyBusyMode` too.
7. **`status` CHECK on `commands`.** Add a way to distinguish `rejected` (version conflict) from validation failures, or state that validation failures are thrown and not recorded. The spike records conflicts and no-ops, throws on validation.
8. **Index choices.** `events_clip_idx` (partial, on the generated column) is used by the planner and cost nothing measurable on insert. `events_type_idx` and `events_txn_idx` are both needed (undo loads by `txn_id`; rebuild groups by it). Consider making `events_txn_idx` cover `(txn_id, seq)` so undo reads are index-only. No composite on `(stream_id, stream_version)` beyond the UNIQUE is required; SQLite uses the UNIQUE's autoindex.
9. **Clips soft-delete and byte-equal rebuild.** Soft-deleted `clips` rows keep their last values in both incremental and rebuild paths, so the `Row`-equality check passed; keep the rule "projection writes are a pure function of (state after txn, events in txn)" written down, because it is what makes the equality test meaningful.
10. **Section 12 claim** "tens of thousands of events replay well under a second": true for the fold (45 ms/10k); the query-table projection is 1.78 s/10k with per-row upserts and needs batching to match. State the numbers.

## Not done / left out

- No `tracks`/`assets` tables and no FK from `clips.track_id` (kept the schema to the six tables the task listed). Redo, `causation_id`, `metadata`, `changedSince` diff, upcasters, and multi-stream were not exercised.
- Benchmarks are single-run, not averaged.
