# Timeline model

Status: normative, 2026-09-08. This document defines the project document, its commands, its events, and the rules `TimelineCore` enforces. `docs/design/storage.md` persists this model; `docs/design/implementation-plan.md` builds it. Where another document disagrees with this one, this one wins.

## 1. Shape

```
Project {
  id, name, version,
  settings { sampleRate, colorSpace, blendSpace: gamma|linear, alignment: AlignmentParameters },
  assets:    { AssetID -> Asset },
  sequences: { SequenceID -> Sequence },
  activeSequenceId
}

Asset { id, contentHash, libraryPath, displayName, kind: video|audio|image,
        duration: Time, hasVideo, hasAudio, sampleRate?, frameDuration?, probe, offline: Bool }

Sequence { id, name, frameDuration: Time (e.g. 1001/24000), width, height,
           tracks: [Track]                       -- ordered; index 0 is the bottom video layer
           transitions: { TransitionID -> Transition },
           markers: { MarkerID -> Marker } }

Track { id, kind: video|audio|caption, name, muted, locked, solo, clips: { ClipID -> Clip } }

Clip { id, trackId, assetId?,                    -- nil for generated clips (title, colour, shape)
       linkGroupId?,                             -- clips from one asset share a group
       start: Time,                              -- position on the sequence timeline
       sourceIn: Time, sourceOut: Time,          -- source range, out exclusive
       speed: Rational (default 1/1),
       transform: Animatable<Transform>,         -- x, y, scale, rotation, anchor
       opacity:   Animatable<Double>,
       effects:   [Effect],                      -- ordered; params are Animatable
       audio:     { gain: Animatable<Double>, muted, pitchCorrected: Bool },
       label?, meta? }

Transition { id, trackId, leftClipId, rightClipId, kind, duration: Time,
             alignment: centered|startOnCut|endOnCut, params }

CaptionItem (a Clip on a caption track with assetId nil) adds
       { text, words: [{ text, t0, t1 }], style }

Marker { id, at: Time, label, colour }

Animatable<T> = { constant: T } | { keyframes: [{ t: Time (relative to clip start), value: T, easing }] }
Time = RationalTime { value: Int64, timescale: Int32 }
```

Dictionaries keyed by id, not arrays, everywhere except `tracks`, whose order is meaningful. A sorted-keys JSON encoder therefore yields a canonical document.

Version 1 implements `Animatable.constant` only and one sequence per project. The shapes exist now so that adding keyframes and sequences later changes no event payload and no fixture.

## 2. Time

- `RationalTime` is `CMTime` without flags. Arithmetic rescales exactly; mixed-timescale comparison cross-multiplies in 128-bit. Never rescale-and-store.
- Every sequence has a canonical `frameDuration`. On **video and caption tracks**, `decide` snaps `start` and the timeline edges implied by `sourceIn`/`sourceOut` to multiples of it. On **audio tracks**, times keep the asset's sample-rate timescale so audio alignment can place a clip to the sample; the frame-boundary invariant does not apply there.
- A clip's timeline duration is `(sourceOut - sourceIn) / speed`, rounded to the frame on video tracks. Overlap checks, ripple, and the compiler all use this value.
- Durations are stored, never end times, except `sourceOut`, which is exclusive.

## 3. Invariants (checked after every transaction)

1. No two clips on the same track overlap in timeline time, except the overlap a `Transition` introduces, which the compiler creates and the model never stores.
2. `0 <= sourceIn < sourceOut <= asset.duration` for asset-backed clips.
3. Video- and caption-track times are on frame boundaries of their sequence.
4. Every `Transition` references two clips on its track that are adjacent (`left.start + left.duration == right.start`) and both have enough source media beyond the cut: `left.sourceOut + leftHandle <= asset.duration` and `right.sourceIn - rightHandle >= 0`, where the handles follow from `duration` and `alignment` (centered: `duration/2` each; `startOnCut`: all on the right clip; `endOnCut`: all on the left clip).
5. All members of a link group keep the relative offsets they were created with: moving, trimming, splitting, or removing one moves, trims, splits, or removes all of them unless the command says `unlinked: true`.
6. Clips on a locked track are not mutated, and ripple skips locked tracks.
7. Ids are unique across the project; an id referenced by a clip, transition, or link group exists.

## 4. Edit semantics

**Modes.** Insert, remove, and trim commands carry `mode: overwrite | ripple`. Overwrite changes only the addressed clips and leaves gaps or overwrites neighbours as a flat editor would (an overwrite that would overlap a neighbour trims the neighbour). Ripple shifts every clip that starts at or after the edit point on every unlocked track of the sequence by the change in duration, keeping cross-track sync, and does the same for transitions and markers at or after the point. `rippleScope: sequence | track` narrows ripple to the addressed track when the user asks for it. Default mode is `ripple` for the agent's tools and for the UI's trim and delete gestures, `overwrite` for drag-to-move.

**Linking.** Adding an asset that has both video and audio creates two clips, one per matching track, sharing a `linkGroupId`; `link: none` on the command adds only the requested track's clip. `linkClips` and `unlinkClips` change groups explicitly. Group-aware commands split at the same source time on every member.

**Transitions.** A transition is an object between two adjacent clips on one track (Final Cut style). `decide` rejects a transition whose handles do not exist and reports the largest duration that would fit, so the agent can retry. Removing or moving either clip removes the transition (recorded as an event in the same transaction). The compiler realizes a transition by extending both clips into the overlap on alternating composition tracks; the model keeps them adjacent.

**Gestures.** The UI previews a drag, trim, or scrub locally and commits **one** command when the gesture ends. Agents batch operations into one `timeline_apply`. The event log records intent-sized steps, not frames; a store-side coalescer is a fallback, not the plan.

**Locked tracks.** Commands addressing a locked track's clips are rejected with `trackLocked`; unlocking is itself a command and event, so the agent can never bypass a lock silently. A locked track cannot be removed either.

**Mute and solo.** Both are project state, both are one command, both are undone like any other edit. A track is silent when it is muted, or when some *other* track **of its own kind** is soloed — so soloing an audio track silences the other audio tracks and leaves the picture and the captions alone. Solo is additive: any number of tracks may be soloed, and every non-soloed track of a kind that has one falls silent. An explicit mute outranks the track's own solo. `Sequence.silence(of:)` is the single definition, returning `.muted` or `.solo` so the compiler and the UI can never disagree about which it is; `SequenceCompiler` drops a silent track's layers, captions, and audio gain, and export reports every silent track as a warning on the receipt.

**Offline assets.** An asset whose `libraryPath` is missing is marked `offline`; the compiler renders a slate for its clips rather than failing, and export proceeds with a warning listing offline assets.

## 5. Commands

Commands are requests; `decide(state, command) throws -> [Event]` turns them into facts or rejects them. Every command has `commandId` (idempotency key), `actor`, and an optional `expectedVersion`. The UI omits `expectedVersion` (its commands are in-process and always apply to the latest state); agent tools supply it and receive a `ChangedSince` diff on conflict. Commands that create entities accept an optional client-supplied id; inside a batch, later operations may reference an earlier operation's created id as `{ "$ref": <index> }`, resolved by the handler before `decide` runs.

| Command | Fields (abridged) | Notes |
|---|---|---|
| `createProject` | `name, settings, sequence: { name, frameDuration, width, height }` | first command of every project |
| `setProjectSettings`, `renameProject` | `after` | |
| `addSequence`, `setSequenceSettings`, `setActiveSequence` | | one sequence in v1 |
| `importAsset` | `id?, contentHash, libraryPath, displayName, kind, duration, probe` | issued by MediaKit after the copy and hash |
| `relinkAsset`, `removeAsset`, `restoreAsset`, `recordAssetAnalysis` | | |
| `addTrack`, `removeTrack`, `reorderTrack`, `renameTrack`, `setTrackMuted`, `setTrackLocked`, `setTrackSolo` | `sequenceId, ...` | `removeTrack` snapshots the track and its clips, so it undoes |
| `addClip` | `id?, sequenceId, trackId, assetId?, at, sourceIn, sourceOut, mode, link: auto\|none` | `auto` creates linked clips per asset track |
| `moveClip` | `clipId, to: { trackId?, start }, mode, unlinked?` | |
| `trimClip` | `clipId, edge: head\|tail, to: Time, mode, unlinked?` | `to` is the new timeline edge |
| `splitClip` | `clipId, at, newIds?, unlinked?` | one new id per group member |
| `joinClips` | `leftClipId, rightClipId` | same asset, contiguous source |
| `removeClip` | `clipId, mode, unlinked?` | |
| `setClipSpeed`, `setClipTransform`, `setClipOpacity`, `setClipAudio` | `clipId, after` | values are `Animatable` |
| `addEffect`, `updateEffect`, `removeEffect` | `clipId, effectId?, ...` | |
| `addTransition` | `id?, leftClipId, rightClipId, kind, duration, alignment, params` | rejected with `maxDuration` if handles are short |
| `updateTransition`, `removeTransition` | | |
| `linkClips`, `unlinkClips` | `clipIds` | |
| `addCaptionTrack`, `replaceCaptions`, `editCaption`, `setCaptionStyle` | | bulk replace from transcript is one command |
| `addMarker`, `moveMarker`, `removeMarker` | | |
| `undo` | `txnId?` | default: latest live transaction |
| `redo` | | latest undone transaction with no newer live one |

Rejections are typed (`EditorError`): `staleVersion(current, changedSince)`, `invalid(reason, suggestion?)`, `trackLocked`, `transitionHandles(maxDuration)`, `notFound(id)`, `alreadyUndone`, `nothingToRedo`.

## 6. Events

Facts in past tense, `<Aggregate><Verb>`. Every timeline event carries `sequenceId`. Payloads carry before and after values wherever the change is not otherwise invertible, so every transaction can be compensated without replaying the log.

| Event | Payload (abridged) |
|---|---|
| `ProjectCreated` | `{ name, settings, sequence }` |
| `ProjectSettingsChanged`, `ProjectRenamed` | `{ before, after }` |
| `SequenceAdded`, `SequenceSettingsChanged`, `ActiveSequenceChanged` | |
| `AssetImported` | `{ assetId, contentHash, libraryPath, displayName, kind, duration, probe }` |
| `AssetRelinked` | `{ assetId, before, after }` |
| `AssetRemoved`, `AssetRestored` | `{ assetId }` |
| `AssetAnalysisRecorded` | `{ assetId, kind, cacheKey, summary }` (data lives in the cache; the event records existence and hash) |
| `TrackAdded` | `{ sequenceId, trackId, kind, position, name }` |
| `TrackRemoved`, `TrackRestored` | `{ sequenceId, trackId, snapshot? }` |
| `TrackReordered`, `TrackRenamed`, `TrackMuteSet`, `TrackLockSet`, `TrackSoloSet` | `{ sequenceId, trackId, before, after }` |
| `ClipAdded` | `{ sequenceId, clipId, snapshot }` |
| `ClipRemoved` | `{ sequenceId, clipId, snapshot }` |
| `ClipMoved` | `{ sequenceId, clipId, before: { trackId, start }, after }` |
| `ClipTrimmed` | `{ sequenceId, clipId, edge, before: { start, sourceIn, sourceOut }, after }` |
| `ClipSplit` | `{ sequenceId, clipId, at, newClipId }` |
| `ClipsJoined` | `{ sequenceId, keptClipId, removedClipId, removedSnapshot }` |
| `ClipSpeedSet`, `ClipTransformSet`, `ClipOpacitySet`, `ClipAudioSet` | `{ sequenceId, clipId, before, after }` |
| `ClipEffectAdded`, `ClipEffectChanged`, `ClipEffectRemoved` | `{ sequenceId, clipId, effectId, before?, after? }` |
| `ClipsLinked`, `ClipsUnlinked` | `{ sequenceId, linkGroupId, clipIds }` |
| `TransitionAdded`, `TransitionChanged`, `TransitionRemoved` | `{ sequenceId, transitionId, before?, after? }` |
| `CaptionTrackAdded` | `{ sequenceId, trackId, language, style }` |
| `CaptionsReplaced` | `{ sequenceId, trackId, before: [items], after: [items] }` |
| `CaptionEdited`, `CaptionStyleSet` | `{ sequenceId, ..., before, after }` |
| `MarkerAdded`, `MarkerMoved`, `MarkerRemoved` | `{ sequenceId, markerId, ... }` |
| `TransactionUndone`, `TransactionRedone` | `{ targetTxnId }` marker, followed in the same transaction by the compensating or re-applied events |

Not events: audio alignment results (derived data, cached by content hashes and parameters), render jobs (operational, in the `renders` table), and agent tool receipts (in `commands`). A finished export must not bump the project version and make a mid-turn agent stale.

Ripple is not an event type; a ripple command emits one `ClipMoved` (or `TransitionChanged`, `MarkerMoved`) per shifted item under one transaction.

Schema evolution: `schemaVersion` per event plus `upcast(type, version, payload) -> payload@latest` on read. Embedded snapshots (`ClipAdded`, `ClipRemoved`, `ClipsJoined`, `CaptionsReplaced`) carry their own `clipSchema` version so one clip-shape change is one upcaster, applied recursively. Old rows are never rewritten.

## 7. Undo and redo

Undo is **linear across all actors**. The undo target is the latest live transaction, whether the human or the agent produced it; an agent turn is one transaction and therefore one undo step. Selective undo of an older transaction is not offered: compensating events are only valid when the current value still equals the transaction's `after`, and the general case requires conflict resolution the product does not need.

- `undo` appends transaction U: `TransactionUndone { targetTxnId: T }` followed by `invert` of T's events in reverse order. `invert` is defined per event type from the before/after payloads. Before appending, `decide` checks each compensating event's precondition against current state and rejects with `invalid` if anything drifted; with linear undo this is a safety net, not a feature.
- `redo` appends transaction R: `TransactionRedone { targetTxnId: T }` followed by T's original events re-applied (equivalently, the inverse of U).
- History is derived by folding the transaction sequence: a transaction is *live* unless the most recent undo/redo marker targeting it is an undo; the redo stack is the set of undone transactions newer than the last live non-marker transaction. Any new non-marker transaction empties the redo stack (the undone transactions stay in the log as facts; they are simply no longer reachable). `history` in storage is a projection of this fold, not a mutable pointer table.
- Undoing a transaction that removed a transition or a link restores it because those removals are events with snapshots inside the same transaction.

## 8. Concurrency between human and agent

One writer, one version counter, one command path. Agent commands carry `expectedVersion`; the UI's do not. On conflict the agent receives:

```
ChangedSince { fromVersion, toVersion,
               transactions: [{ txnId, actor, label, changedIds, events: [{ type, ids, summary }] }] }
```

and retries with a new `commandId`. Optimistic locking, not CRDTs: edits are seconds apart, never simultaneous.

## 9. What the compiler consumes

`RenderKit` reads a `Sequence` plus the assets it references and produces an `AVMutableComposition`, an `AVVideoComposition.Configuration`, and an `AVMutableAudioMix`. It realizes transitions as overlaps on alternating composition tracks, applies `speed` with `scaleTimeRange` and the audio pitch algorithm implied by `pitchCorrected`, evaluates `Animatable` values per frame, renders captions with Core Text inside the compositor, honours `blendSpace`, and substitutes a slate for offline assets. It never writes to the model. Compositions handed to a player are immutable: an instruction-only change (transform, opacity, effect parameter, caption, transition curve) is applied by replacing the live item's video composition and audio mix, and a structural change (any edit that alters a track's segments) produces a new player item. That split is why the model separates clip placement from clip properties.
