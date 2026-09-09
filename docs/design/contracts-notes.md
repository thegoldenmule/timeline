# Contracts implementation notes

Status: decisions made while implementing the `Contracts` and `ContractsTestSupport` targets of `docs/design/implementation-plan.md` section 2, 2026-09-08. The plan and `timeline-model.md` still win where they disagree.

## Naming and shapes

- `Progress` is named `JobProgress`. Every client module imports Foundation, and Foundation exports `Progress`; the shadowing rule that lets `Sequence` win over the standard library does not apply to Foundation, so the plan's name was ambiguous in the first fake that used it.
- `ProjectStore.changes` is a synchronous `var` that returns a fresh `AsyncStream<ProjectChange>` on every access. Actors implement it `nonisolated` over `Contracts.Broadcaster`, which fans out to any number of subscribers with unbounded buffering, so a subscriber never has to hop onto the store's executor to start listening and never misses a change committed after the access. `ApprovalGate.requests` and `AgentSession.events` follow the same rule (the session's stream is one per session, not one per access).
- Opening is a separate protocol, `ProjectStoreOpening` (`open(at:)`, `create(at:name:settings:sequence:)`), returning `any ProjectStore`. A static requirement on `ProjectStore` would have forced a generic on every consumer; the App holds one opener per backend.
- `MediaLibrary.relink` takes the `Asset`, not an `AssetID`: the library has no project state, and the hash it verifies against lives on the asset. The caller issues `relinkAsset` with the returned asset's `libraryPath`.
- `MediaLibrary.importJob(url:mode:)` is the job form and `importAsset(url:mode:)` the inline form; the job's outcome payload is the `ImportResult` (asset plus the `ImportAsset` operation the caller issues). The library never applies commands.
- `Compiled.payload` is `any CompiledPayload`, a `Sendable` marker protocol the owning module downcasts. Value semantics throughout: `update` returns a new token and never mutates the old one, matching the "compositions handed to a player are frozen" rule.
- `Renderer.update` returns `RenderUpdate.instructionsOnly` when the structural fingerprint is unchanged, `.structural` otherwise; the returned `Compiled` is complete either way. The fake's `SequenceFingerprint` treats transition duration and alignment as structural (they change overlaps) and transition kind and params as instruction-only; RenderKit should keep that split.
- `JobHandle` carries the job's `Task` (`wait()` and `cancel()` are thin wrappers) and one progress stream per handle. `JobRunner.submit` is `async` so actor implementations need no `nonisolated` escape hatch; `Job.run` is a `@Sendable` closure receiving `any JobContext`.
- The analyzer family is one protocol, `MediaAnalyzer`. The implementation owns state every method shares (cache index, the five SpeechAnalyzer locale reservation slots, the memory budget), tools resolve a single service, and the fake is one object with fixtures per method.
- `ToolContext` is a struct (`projects`, `services`, `approvals`, `actor`, `sessionId`) with `store(for:)` resolving `projectId` or the frontmost project, and `checkApproval` filling in actor and session. `ToolServices` holds optionals so a partially wired app answers `ToolError.serviceUnavailable` instead of failing to construct.
- `ApprovalGate.check` consumes a granted token found in the input and returns `.granted`; otherwise it mints an `ApprovalRequest` and returns `.required`. `consume` is also public for handlers that check the token themselves. The user's answer is `ApprovalVerdict` (`approve` / `deny(reason:)`), distinct from the gate's `ApprovalDecision`.
- `ToolOutput.approvalRequired(_:)` emits `{ status: "approval_required", approvalToken, estimate, requestId, tool, summary }` with `isError == false`; `ToolOutput.editorError(_:)` emits `{ error: code, message, ...fields, hint }` with `isError == true`, the `ChangedSince` inline for `staleVersion`.
- Cache keys are `<contentHash>/<kind>/<paramsHash>` via `AnalysisCacheKey`; `paramsHash` is `v<version>-<fnv1a of the canonical parameter JSON>` from `StableHash` (FNV-1a, dependency-free). It is a fingerprint, not a content hash.

## Fakes

- `FakeProjectStore` wraps `decide` / `evolve` / `History` with a `seq`-numbered log, stored results and stored rejections per `commandId` (a retry of a rejected command gets the same rejection, as the store spec says), stale rejection with `ChangedSince` filled by `decide`, and one `ProjectChange` per transaction. `rebuildProjections` refolds the log and throws `FakeStoreError.rebuildMismatch` if state or history differ.
- `FakeRenderer` generates its synthetic clip on the first `compile` (colour bars, or barcode video plus a 440 Hz tone when the sequence has audio and `options.audio`), so `playerItem(for:)` needs a `Compiled` from the same fake; that mirrors the real API, where there is no player item without a compile. Frames are solid colours whose hue follows time; `export` writes a half-second clip and an `ExportReceipt`.
- `FakeMediaLibrary`'s content hash is `fake-<fnv1a of size + first MiB>`: content-derived (a moved file relinks) but not SHA-256 and never CryptoKit. Probing uses `AVURLAsset` on the real file; PNG/JPEG/HEIC/TIFF/GIF are images with a nominal 10 s duration.
- `FakeJobRunner.Mode.awaitCompletion` makes `submit` return a finished handle for deterministic tests; `.concurrent` is the real shape. Budgets are recorded, not enforced.
- `FakeAgentSession` pauses on `.approvalRequested` until `approve`, takes one follow-up script per `send`, and ends its stream when the script and every follow-up have replayed (or on `cancel`, which emits `.failed(.cancelled)`).
- `TestServices.make(fixture:)` wires every fake around a fixture store and builds a `ToolContext`; it is the walking skeleton's starting point.

## Phase 2 folding of the module proposals (2026-09-08)

The proposals in `contracts-proposals/` were reviewed by the integration owner. Everything accepted is additive; every existing test stays green (the JSON fixtures were regenerated with `TIMELINE_WRITE_FIXTURES` because `AlignmentParameters` gained fields).

Accepted:

- **`AgentFailure.unavailable`** (agent-kit.md 1) moved into `Contracts/AgentRuntime.swift`; AgentKit's private extension was removed so the code string has one owner.
- **`ApprovalGate.status(of:)` and `ApprovalTokenStatus`** (agent-kit.md 2), with a protocol extension defaulting to `.unknown` so existing gates still conform. `FakeApprovalGate` and the app's `StandardApprovalGate` implement it; the app's `ApprovalWait` polls it so a card answered from any surface resumes the caller. AgentKit's `RecordingApprovalGate` still uses its own bookkeeping; adopting `status(of:)` in the `/approval` hook is the follow-up that closes the gap the proposal describes.
- **`AgentEvent.approvalRequested` carries the gate's request** (app.md 1): doc comments on the case and on `AgentSession.approve`, no type change. `ClaudeCodeSession` already forwards the gate's `requests` stream; the app's fallback loop forwards the request it decodes from the tool's `approval_required` output (same `id` and `token`).
- **`ProjectStore.version` counts events** (app.md 2, the sentence form): added to the protocol's rule list. `ProjectChange.eventCount` was not added.
- **`AlignmentParameters` additions** (audio-align.md): `decimationFilterTaps`, `decimationCutoffFraction`, `envelopeLogPowerFloor`, `phatSecondPeakExclusionMs`, `minimumPhatPeakRatio`, `minimumVerificationWindows`, `minimumWindowsForDriftFit`, `proofCorrelationPoints`, with the proposal's defaults, in `TimelineCore.Model`. A custom `init(from:)` decodes older documents that lack them. `AudioAlign` reads them instead of `AlignerDefaults`, which keeps only the two implementation choices (`offsetTimescaleMultiplier`, `streamingChunkFrames`); `OnsetAligner.parametersHash` therefore changes for the same defaults, invalidating cached alignments once. AgentKit's `alignmentParameters` schema lists the new fields (it is `additionalProperties: false` and every field is required).
- **Doc comments on `AlignmentCandidate.offset` / `driftPPM` and `AlignmentProof`** (audio-align.md), as proposed.

Rejected or deferred:

- **`ArtifactCache` protocol** (project-store.md 1): not needed. MediaKit's `CacheIndex` implements `Cache/cache.sqlite` itself (the same schema plus `media.asset` and `file_hints`), and the app hands that one index to the library, the analyzer, and both providers. `ProjectStore.CacheDatabase` is unused by the app; two migrators over one file would collide, so the app must never open both. Revisit if a second module needs the artifact index without importing MediaKit.
- **`OnsetEnvelopeProducer`** (audio-align.md, optional): not needed. MediaKit streams its own `onset-8k` envelope (`MediaKit/OnsetEnvelope.swift`) and the aligner's `AudioSource.file` path decodes on its own; the app never bridges the two.
- **`ToolReceipt.projectId` on rejected calls** (agent-kit.md 3): deferred, low value; the receipt keeps the tool, session, and args hash.
- **`ProjectChange.eventCount`** (app.md 2): deferred in favour of the doc sentence.

Module fixes made while integrating (each minimal, tests green):

- `AudioAlign.OnsetAligner.candidate` and the proof's `fitInterceptMs` replace non-finite values with 0: a candidate whose fit had no residuals carried `NaN` in `fitMADMs`, and `JSONEncoder` refuses `NaN`, so `align_audio` threw instead of answering. The tests that referenced `AlignerDefaults` now read `AlignmentParameters()`.
- `MediaKit.MediaProbe` truncates `Probe.capturedAt` to whole seconds. File creation dates carry nanoseconds, the project codec stores milliseconds, and the in-memory `Project` after `importAsset` differed from the one decoded from the event log on reopen.
- `AgentKit.OperationSchemas.alignmentParameters` lists the eight new fields (see above).
