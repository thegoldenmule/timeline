# Conventions

Status: normative for Phase 0 onward, 2026-09-08. Companion to `implementation-plan.md`.

## Package layout

One Swift package at the repo root (`Package.swift`, swift-tools-version 6.2, macOS 26, Swift 6 language mode with `ExistentialAny`). Every target, product, and external dependency is declared there in Phase 0. Module agents never edit `Package.swift`; a needed change is a small, separate commit by the integration owner.

| Target | Kind | May import |
|---|---|---|
| `TimelineCore` | library | Foundation only |
| `Contracts` | library | `TimelineCore`, AVFoundation, CoreGraphics, CryptoKit |
| `ContractsTestSupport` | library | `TimelineCore`, `Contracts`, AVFoundation, CoreImage |
| `PublishKit` | library | `TimelineCore`, `Contracts`, swift-nio, Security, CryptoKit. Never AppKit: the browser opener is injected. |
| `ProjectStore`, `RenderKit`, `MediaKit`, `AudioAlign`, `AgentKit`, `TimelineUI` | library | `TimelineCore`, `Contracts`, their declared externals. Never a sibling. |
| `TimelineApp` | executable | everything (composition root) |
| `TimelineMCPProxy` (`timeline-mcp`) | executable | `AgentKit` |

Tests live in `Tests/<Target>Tests` and use Swift Testing (`import Testing`). `swift test --filter <Target>Tests` must pass in isolation. Shared JSON fixtures live in `Fixtures/` at the repo root and are copied into `TimelineCoreTests`' bundle; other modules read them via `Bundle.module` of `ContractsTestSupport` helpers.

## Ownership and branches

- One owner per module. Branch `module/<name>`; one git worktree per agent.
- Commit incrementally with simple one-line messages. Merges to `main` are done by the integration owner and are expected to be conflict-free because modules touch disjoint directories.
- `Contracts` and `TimelineCore` are frozen after Phase 0. To change them: propose the change as a small commit that also updates the fakes in `ContractsTestSupport`, get it merged to `main`, then every module rebases. Do not make a module depend on a `Contracts` change that has not merged.

## Code rules

- Zero Swift 6 warnings in every module is part of every definition of done.
- Isolation is declared on every protocol method: `@MainActor` for anything touching `AVPlayer`, `AVPlayerItem`, or views; `nonisolated async` for pure work; actors for stateful services.
- `RationalTime` is never stored rescaled; arithmetic rescales exactly and comparison cross-multiplies in 128-bit.
- Ids are UUIDv7 strings minted through `IDGenerator`; tests inject a deterministic generator and `Clock`.
- JSON: `RationalTime` encodes as `{ "v": Int64, "ts": Int32 }`; state documents are encoded with `[.sortedKeys, .withoutEscapingSlashes]` so they are canonical.
- No magic numbers for tunables: thresholds live in value types such as `AlignmentParameters`.
- SwiftUI chrome reads its spacing, radii, type, and colour from `PanelTheme` and builds its headers from `PanelChrome`; see `ui-style.md`. A literal padding, radius, or font in a panel is a review comment.
- `make lint` runs `swift format lint --strict`; `make format` fixes. `make test` runs everything; `./ci.sh` runs both.

## Media in tests

Never check media into the repo. `TestMedia` in `ContractsTestSupport` writes synthetic clips (colour bars, tone, transient pattern, barcode frame counter) into a temp directory with `AVAssetWriter`. Real footage lives in `~/Downloads` and is referenced from a local, uncommitted config only.
