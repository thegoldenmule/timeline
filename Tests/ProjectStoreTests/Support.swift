import Contracts
import ContractsTestSupport
import Foundation
import GRDB
import Testing
import TimelineCore

@testable import ProjectStore

/// Where a test store lives. Every behaviour test runs against both.
enum Backend: String, CaseIterable, Sendable {
    case memory
    case disk
}

/// A temp directory removed when the value goes away.
final class TempDir: Sendable {
    let url: URL

    init(_ name: String = "store") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectStoreTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A store under test plus what keeps it alive.
struct TestStore {
    let store: SQLiteProjectStore
    let dir: TempDir?
    /// The fixture's generators, continued by the store (so ids match `FakeProjectStore(builder:)`).
    let ids: any IDGenerator
    let clock: any Clock

    /// A fresh command envelope from a separate deterministic generator.
    static let commandIds = SequentialIDGenerator(start: 900_000)

    func command(
        _ operation: Command.Operation, actor: Actor = .human, expectedVersion: Int64? = nil, label: String? = nil
    ) -> Command {
        Command(
            commandId: CommandID(minting: Self.commandIds), actor: actor, expectedVersion: expectedVersion,
            label: label, operation: operation)
    }

    @discardableResult
    func apply(
        _ operation: Command.Operation, actor: Actor = .human, expectedVersion: Int64? = nil, label: String? = nil
    ) async throws(EditorError) -> CommandResult {
        try await store.apply(command(operation, actor: actor, expectedVersion: expectedVersion, label: label))
    }
}

enum Stores {
    /// A blank store on `backend` with deterministic ids and clock.
    static func blank(
        _ backend: Backend, ids: any IDGenerator = SequentialIDGenerator(start: 1),
        clock: any Clock = FixedClock(step: 1), options: SQLiteProjectStore.Options = .init()
    ) throws -> TestStore {
        switch backend {
        case .memory:
            return TestStore(
                store: try SQLiteProjectStore.inMemory(ids: ids, clock: clock, options: options), dir: nil, ids: ids,
                clock: clock)
        case .disk:
            let dir = TempDir()
            let store = try SQLiteProjectStore(
                databaseAt: dir.file("project.sqlite").path, url: nil, ids: ids, clock: clock, options: options)
            return TestStore(store: store, dir: dir, ids: ids, clock: clock)
        }
    }

    /// A store loaded with a named fixture's log, continuing the fixture's ids and clock, like
    /// `FakeProjectStore(builder:)`.
    static func fixture(
        _ name: String = "three-clips", on backend: Backend, options: SQLiteProjectStore.Options = .init()
    ) async throws -> TestStore {
        let builder = try Fixtures.builder(name)
        let t = try blank(backend, ids: builder.ids, clock: builder.clock, options: options)
        try await t.store.importEvents(builder.events, labels: labels(of: builder.history))
        return t
    }

    static func labels(of history: History) -> [TransactionID: String] {
        Dictionary(uniqueKeysWithValues: history.transactions.map { ($0.id, $0.label) })
    }

    /// The fake loaded with the same fixture, for side-by-side comparison.
    static func fake(_ name: String = "three-clips") throws -> FakeProjectStore {
        try Fixtures.store(name)
    }
}

extension SQLiteProjectStore {
    /// Every row of `table` ordered by its columns, for byte-for-byte projection comparisons.
    nonisolated func rows(_ table: String, orderBy: String) throws -> [Row] {
        try writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(orderBy)") }
    }

    nonisolated func scalar<T: DatabaseValueConvertible & StatementColumnConvertible>(
        _ sql: String, _ arguments: StatementArguments = []
    ) throws -> T? {
        try writer.read { db in try T.fetchOne(db, sql: sql, arguments: arguments) }
    }

    /// The stored `project_state.state` text.
    nonisolated func storedStateJSON() throws -> String? {
        try scalar("SELECT state FROM project_state WHERE id = 1")
    }

    /// A snapshot of every projection: the state text, every query table, and history.
    nonisolated func projectionSnapshot() throws -> ProjectionSnapshot {
        ProjectionSnapshot(
            state: try storedStateJSON() ?? "",
            assets: try rows("assets", orderBy: "asset_id"),
            sequences: try rows("sequences", orderBy: "sequence_id"),
            tracks: try rows("tracks", orderBy: "track_id"),
            clips: try rows("clips", orderBy: "clip_id"),
            transitions: try rows("transitions", orderBy: "transition_id"),
            markers: try rows("markers", orderBy: "marker_id"),
            history: try rows("history", orderBy: "first_seq"),
            projectionState: try rows("projection_state", orderBy: "name"))
    }
}

struct ProjectionSnapshot: Equatable {
    var state: String
    var assets: [Row]
    var sequences: [Row]
    var tracks: [Row]
    var clips: [Row]
    var transitions: [Row]
    var markers: [Row]
    var history: [Row]
    var projectionState: [Row]
}

extension Fixtures {
    static func opacity(_ clip: Clip, _ value: Double) -> Command.Operation {
        .setClipOpacity(.init(clipId: .id(clip.id), after: .constant(value)))
    }

    static func trimTail(_ clip: Clip, by frames: Int64 = 48, mode: EditMode = .overwrite) -> Command.Operation {
        .trimClip(.init(clipId: .id(clip.id), edge: .tail, to: clip.start + Fixtures.frames(frames), mode: mode))
    }
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

/// Awaits the first element of a stream that is not `nil`, with a timeout so a broken stream fails the
/// test instead of hanging it.
func firstValue<T: Sendable>(of stream: AsyncStream<T>, within timeout: Duration = .seconds(5)) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Fixture builders for the store tests.
enum LargeLog {
    /// A ProjectBuilder-driven log of at least `minimumEvents` events on a small live state (clips are
    /// retired once there are more than `maxClips`), covering adds with auto-linking, ripple trims,
    /// opacity, splits, transitions, markers, removals, undo, and redo.
    static func build(minimumEvents: Int = 10_000, maxClips: Int = 240) throws -> ProjectBuilder {
        let b = try Fixtures.builder("empty")
        let fd = Fixtures.frameDuration
        let v = b.videoTracks[0].id
        let cam = try b.importAsset(name: "cam.mov", duration: RationalTime.frames(720, of: fd))
        let cam2 = try b.importAsset(name: "cam2.mov", duration: RationalTime.frames(720, of: fd))
        var cursor = RationalTime.zero
        var live: [ClipID] = []
        var previous: ClipID?
        var i = 0
        while b.events.count < minimumEvents {
            i += 1
            let len = Int64(2 + (i * 7) % 40)
            let asset = i % 2 == 0 ? cam : cam2
            let clip = try b.addClip(
                track: v, asset: asset, at: cursor, sourceIn: RationalTime.frames(24, of: fd),
                sourceOut: RationalTime.frames(24 + len, of: fd), link: .auto, mode: .overwrite)
            live.append(clip)
            cursor = cursor + RationalTime.frames(len, of: fd)
            if i % 3 == 0, let p = previous, let pc = b.clip(p),
                b.sequence.duration(of: pc) > RationalTime.frames(2, of: fd)
            {
                // A ripple trim of the previous clip shifts this one (and its linked partner): ClipMoved.
                try b.apply(
                    .trimClip(
                        .init(
                            clipId: .id(p), edge: .tail, to: b.sequence.end(of: pc) - RationalTime.frames(1, of: fd),
                            mode: .ripple)))
                cursor = cursor - RationalTime.frames(1, of: fd)
            }
            if i % 4 == 0 {
                try b.apply(.setClipOpacity(.init(clipId: .id(clip), after: .constant(Double(i % 10) / 10))))
            }
            if i % 5 == 0, len >= 4, let c = b.clip(clip) {
                try b.apply(.splitClip(.init(clipId: .id(clip), at: c.start + RationalTime.frames(len / 2, of: fd))))
            }
            if i % 7 == 0 {
                try b.apply(.addMarker(.init(sequenceId: .id(b.sequenceId), at: cursor, label: "m\(i)", colour: "red")))
            }
            if i % 9 == 0, let left = previous, let l = b.clip(left), let r = b.clip(clip),
                b.sequence.end(of: l) == r.start
            {
                let max = Invariants.maxTransitionDuration(
                    left: l, right: r, alignment: .centered, in: b.sequence, assets: b.project.assets)
                if max.frameIndex(frameDuration: fd) >= 2 {
                    try b.apply(
                        .addTransition(
                            .init(
                                leftClipId: .id(left), rightClipId: .id(clip), kind: "dissolve",
                                duration: RationalTime.frames(2, of: fd))))
                }
            }
            if i % 6 == 0 {
                try b.apply(.undo(.init()))
                try b.apply(.redo)
            }
            if i % 11 == 0 {
                try b.apply(.undo(.init()))
            }
            while live.count > maxClips {
                let old = live.removeFirst()
                if b.clip(old) != nil {
                    try b.apply(.removeClip(.init(clipId: .id(old), mode: .overwrite)))
                }
            }
            previous = clip
        }
        return b
    }
}
