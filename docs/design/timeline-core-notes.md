# TimelineCore implementation notes

Status: decisions made while implementing `docs/design/timeline-model.md`, 2026-09-08. Each bullet resolves a point the model document leaves open or states abstractly; the model document still wins where they disagree.

## Shapes and naming

- `Operation` is nested as `Command.Operation` rather than a top-level type, because Foundation exports an `Operation` class and every client module imports Foundation. `Sequence`, `Clock`, and `Actor` are top level: the Swift shadowing rule lets a non-stdlib module's declaration win over the standard library's, verified in the test target.
- Every reference to an existing entity inside an operation is a `Ref<ID>` (`.id` or `.ref(n)`), including `sequenceId`. `$ref` resolves to the *primary* id an earlier batch operation created: the addressed clip's id for `addClip` and `splitClip` (the auto-linked partner and the other members' halves take `linkedId` / `newIds`), the transition, marker, effect, track, asset, or link group otherwise.
- `ClipSplit` carries the new clip's snapshot (`newClip`) and a `clipSchema`, and `ClipsJoined` carries the removed clip's snapshot, so `invert` is stateless in both directions. `TrackRemoved` and `TrackRestored` are the other snapshot-bearing events.
- Caption items are `Clip`s on caption tracks with `text`, `words`, and `style` flattened onto the clip (matches the `clips.text` column); `CaptionItem` is the same triple as one value for events. Caption tracks carry `language` and a default `captionStyle`; `setCaptionStyle` targets either the track or one item. Word times are source-relative (the clip's `sourceIn..sourceOut` domain), so a split partitions words by `t0`.
- `Project.blank` is the only state that accepts `createProject`; `ProjectCreated` carries the project id and the first (trackless) sequence. `addSequence` is accepted by the codec but rejected by `decide` in this version, since there is no `SequenceRemoved` event to make it undoable.
- `Project.version` counts events, not transactions (`evolve` bumps it once per event), matching `stream_version` in storage. `decide` checks `expectedVersion` against it and, when the supplied `History` is complete, fills the `ChangedSince` of the `staleVersion` error itself; otherwise the store fills it in.
- `removeAsset` is a hard delete with a snapshot (`AssetRemoved { assetId, snapshot }`), rejected while any clip uses the asset. `restoreAsset { asset }` re-inserts a snapshot the caller has (the event log or the Library sidecar). That keeps `invert(AssetImported)` exact.
- `AlignmentParameters` defaults come from `spikes/audio-align/SPIKE.md`; the fields marked "policy" in the source (`minimumOverlapSeconds`, `driftFloorPpm`, `maxDriftPpm`, `minConfidence`) are product choices the spike did not measure.
- `JSONValue.number` is a `Double`; integral values encode as integers so `{ "v": 1001 }` round-trips through an upcaster unchanged. Values above 2^53 lose precision, which no time value in this model reaches.

## Time and snapping

- `RationalTime` arithmetic is exact: same timescale, else the least common multiple, else the fully reduced fraction. If the exact value cannot be represented at all (`Int64` value or `Int32` timescale) it traps; media timescales never reach that.
- Equality and ordering cross-multiply, so `1/2 == 2/4`; `hash` uses the reduced form to stay consistent.
- Frame snapping rounds half up; `floored`/`ceiled` are the other variants. On video and caption tracks `decide` snaps `start`, and on `addClip` also `sourceIn`/`sourceOut`. Trims compute `sourceIn`/`sourceOut` exactly from the snapped timeline edge (`start + (to - start) * speed`), so at speed 1 they stay frame aligned and at other speeds the implied timeline edge is exact.
- Invariant 3 is checked as: `start` is frame aligned on video and caption tracks, and the timeline duration `(sourceOut - sourceIn) / speed` rounded to the nearest frame is positive. Source times are not required to be frame aligned at speeds other than 1, because the timeline edge, not the source edge, is what the invariant protects.

## Edit semantics

- Ripple point and delta: tail trim ripples from the clip's old end by the change; head trim in ripple mode keeps the clip's `start` (content slides) and ripples from the new head position; remove ripples from the removed clip's end by its negative duration; `setClipSpeed` ripples from the old end by the duration change; `addClip` and `moveClip` in ripple mode are inserts: any clip spanning the insert point on a ripple track is split there, then everything at or after the point shifts right by the inserted duration. A ripple move leaves the vacated gap open.
- Ripple shifts markers only with `rippleScope: sequence`; a track-scoped ripple leaves sequence markers alone.
- Overwrite: the placed range is cleared by trimming a neighbour's head or tail, removing a neighbour that is fully covered, or splitting one that spans the range.
- Link groups: every group-aware command fans out to the members on unlocked tracks (a locked member track rejects the whole command with `trackLocked`); `unlinked: true` acts on the addressed clip alone and leaves it in the group. `setClipSpeed` always applies to the whole group. A split of a group creates a new group for the right halves; an unlinked split keeps the new half in the original group.
- Auto-linking on `addClip` pairs V*n* with A*n* (same ordinal), falling back to the first unlocked track of the other kind; if none exists only the addressed clip is added. Effects, transforms, opacity, and audio settings are per clip and do not fan out.
- Transitions: `moveClip` and `removeClip` drop the transitions attached to the addressed clips first; every clip-mutating command then sweeps the sequence and removes any transition whose clips are no longer adjacent or whose handles no longer fit, all inside the same transaction. A split moves a tail transition onto the right half; a join moves it back. Generated clips (no asset) have unlimited handles. Caption tracks take no transitions.
- `linkClips` accepts clips that are ungrouped or already in one common group and reports only the clips that joined; clips from two different groups are rejected with the suggestion to unlink first.
- `importAsset` rejects a duplicate content hash (the existing id is in the suggestion) rather than silently returning the existing asset; MediaKit's "already in the library" no-op happens before the command is issued.
- `setSequenceSettings` rejects a frame-rate change while any video or caption clip exists.

## Undo, redo, history

- `undo` targets the latest live edit transaction; naming an older live transaction is rejected with `invalid`, an undone one with `alreadyUndone`, and the project creation transaction is never undoable. Compensating events carry `causationId` pointing at the event they invert and are checked against the current state first (`invalid` on drift).
- The `History` fold keeps a live stack and a redo stack: an edit appends to live and empties redo; an undo moves its target from live to redo; a redo moves it back. Undone transactions orphaned by a later edit stay in `undone` but never re-enter the redo stack.
- `decide` runs `Invariants.check` on the resulting state and rejects with the invariant's error, so the store's own check is a second line of defence.
