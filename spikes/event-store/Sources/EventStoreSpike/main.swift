// Driver: schema verification, idempotency/concurrency/undo checks, rebuild equality, observation, benchmarks.
import Foundation
import GRDB
import Synchronization

setvbuf(stdout, nil, _IONBF, 0)
func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
func timed<T>(_ body: () throws -> T) throws -> (T, Double) {
    let t0 = ContinuousClock.now; let r = try body(); return (r, seconds(ContinuousClock.now - t0))
}
func fileSize(_ p: String) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0 }
func mb(_ n: Int64) -> String { String(format: "%.2f MB", Double(n) / 1_048_576) }
func check(_ cond: Bool, _ msg: String) { print((cond ? "  PASS  " : "  FAIL  ") + msg) }

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.temporaryDirectory.appendingPathComponent("event-store-spike").path)
try? FileManager.default.removeItem(at: dir)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let dbPath = dir.appendingPathComponent("project.sqlite").path
func clip(_ id: String, track: String = "V1", start: Int64 = 0) -> Clip {
    Clip(clipId: id, trackId: track, assetId: "asset-1", start: .init(v: start, ts: 24000), in: .init(v: 0, ts: 24000), out: .init(v: 48048, ts: 24000))
}

// MARK: 1. Schema + SQLite feature check
print("== Schema ==")
let store = try ProjectStore(path: dbPath)
try store.pool.read { db in
    print("  sqlite_version() via GRDB: \(try String.fetchOne(db, sql: "SELECT sqlite_version()")!)")
    print("  journal_mode=\(try String.fetchOne(db, sql: "PRAGMA journal_mode")!) synchronous=\(try Int.fetchOne(db, sql: "PRAGMA synchronous")!) foreign_keys=\(try Int.fetchOne(db, sql: "PRAGMA foreign_keys")!) busy_timeout=\(try Int.fetchOne(db, sql: "PRAGMA busy_timeout")!) user_version=\(try Int.fetchOne(db, sql: "PRAGMA user_version")!)")
    let strict = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND sql LIKE '%) STRICT'")!
    check(strict == 6, "STRICT accepted on all \(strict) tables")
    let gen = try Row.fetchOne(db, sql: "SELECT hidden FROM pragma_table_xinfo('events') WHERE name='clip_id'")!
    check(gen["hidden"] as Int == 2, "clip_id is a VIRTUAL generated column (hidden=\(gen["hidden"] as Int))")
    let pidx = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name='events_clip_idx'")!
    check(pidx.contains("WHERE clip_id IS NOT NULL"), "partial index on generated column created")
}
try store.pool.write { db in
    // STRICT type enforcement: text into INTEGER must fail.
    do { try db.execute(sql: "INSERT INTO projection_state (name, last_seq) VALUES ('x', 'not-an-int')"); check(false, "STRICT rejected wrong type") }
    catch let e as DatabaseError { check(e.resultCode == .SQLITE_CONSTRAINT, "STRICT rejected wrong type (\(e.extendedResultCode))") }
    try db.execute(sql: "DELETE FROM projection_state WHERE name = 'x'")
}

// MARK: 2/3. Write path, idempotency, concurrency, undo
print("== Write path ==")
let c1 = uuidv7()
let r1 = try store.apply(.addClip(clip("c1")), expectedVersion: 0, commandId: c1, actor: "human")
check(r1.status == "applied" && r1.version == 1 && r1.firstSeq == 1, "addClip applied -> \(r1)")
let r1b = try store.apply(.addClip(clip("c1")), expectedVersion: 0, commandId: c1, actor: "human")
check(r1b.replayed && r1b.txnId == r1.txnId && r1b.version == 1, "duplicate commandId returns stored result, appends nothing (replayed=\(r1b.replayed))")
let stale = try store.apply(.addClip(clip("c2")), expectedVersion: 0, commandId: uuidv7(), actor: "agent:s1")
check(stale.status == "rejected" && stale.version == 1, "stale expectedVersion rejected with currentVersion=\(stale.version)")
let r2 = try store.apply(.moveClip(clipId: "c1", to: .init(trackId: "V2", start: .init(v: 1001, ts: 24000))), expectedVersion: 1, commandId: uuidv7(), actor: "agent:s1")
check(r2.status == "applied" && r2.version == 2, "moveClip applied -> version \(r2.version)")
let noop = try store.apply(.moveClip(clipId: "c1", to: .init(trackId: "V2", start: .init(v: 1001, ts: 24000))), expectedVersion: 2, commandId: uuidv7(), actor: "human")
check(noop.status == "noop" && noop.version == 2, "no-change command recorded as noop, no version bump")
do { _ = try store.apply(.removeClip(clipId: "nope"), expectedVersion: 2, commandId: uuidv7(), actor: "human"); check(false, "validation error") }
catch let e as CoreError { check(true, "validation failure throws (\(e)); transaction rolled back") }
// Race: a second writer that also read version 2 tries to insert stream_version 3 after version 3 exists.
let r3 = try store.apply(.trimClip(clipId: "c1", edge: "tail", to: .init(start: .init(v: 1001, ts: 24000), in: .init(v: 0, ts: 24000), out: .init(v: 24024, ts: 24000))), expectedVersion: 2, commandId: uuidv7(), actor: "human")
do { try store.forceConflictingAppend(fromVersion: 2); check(false, "UNIQUE(stream_id, stream_version) race") }
catch let e as DatabaseError { check(e.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE, "UNIQUE(stream_id, stream_version) caught the race: \(e.extendedResultCode) \(e.message ?? "")") }
let countAfterRace = try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM events")! }
check(countAfterRace == 3, "conflicting txn rolled back; events count still 3")
// Undo of the trim (txn r3) then attempt double undo.
let u1 = try store.apply(.undo(txnId: r3.txnId!), expectedVersion: 3, commandId: uuidv7(), actor: "human")
check(u1.status == "applied" && u1.version == 5, "undo appended TransactionUndone + 1 compensating event -> version \(u1.version)")
let hist = try store.pool.read { try Row.fetchAll($0, sql: "SELECT txn_id, undone_by, undoes, label FROM history ORDER BY first_seq") }
check(hist[2]["undone_by"] as String? == u1.txnId && hist[3]["undoes"] as String? == r3.txnId, "history.undone_by / undoes linked")
do { _ = try store.apply(.undo(txnId: r3.txnId!), expectedVersion: 5, commandId: uuidv7(), actor: "human"); check(false, "double undo") }
catch let e as CoreError { check(true, "double undo rejected: \(e)") }
let st = try store.currentState()
check(st.clips["c1"]?.out.v == 48048 && st.clips["c1"]?.trackId == "V2", "state after undo: trim reverted, move kept")
let clipRow = try store.pool.read { try Row.fetchOne($0, sql: "SELECT * FROM clips WHERE clip_id = 'c1'")! }
check(clipRow["out_v"] as Int64 == 48048 && clipRow["track_id"] as String == "V2", "clips query table matches state")
let byClip = try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM events WHERE clip_id = 'c1'")! }
check(byClip == 4, "json_extract generated column queryable via partial index (\(byClip) events for c1)")
let plan = try store.pool.read { try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN SELECT seq FROM events WHERE clip_id = 'c1'").map { $0["detail"] as String }.joined(separator: "; ") }
print("  plan: \(plan)")

// MARK: 5. ValueObservation on clips
print("== ValueObservation ==")
let seen = Mutex<[Int]>([])
let sem = DispatchSemaphore(value: 0)
let obs = ValueObservation.tracking { try Int.fetchOne($0, sql: "SELECT count(*) FROM clips WHERE removed = 0")! }
let cancellable = obs.start(in: store.pool, scheduling: .async(onQueue: DispatchQueue(label: "obs")),
                            onError: { print("  observation error \($0)") },
                            onChange: { n in seen.withLock { $0.append(n) }; sem.signal() })
sem.wait()
_ = try store.apply(.addClip(clip("c2", start: 100)), expectedVersion: 5, commandId: uuidv7(), actor: "human")
_ = sem.wait(timeout: .now() + 2)
check(seen.withLock { $0 } == [1, 2], "observer saw clip counts \(seen.withLock { $0 }) (initial, then after apply)")
cancellable.cancel()

// MARK: 4. Rebuild equality on the small DB
print("== Rebuild (small) ==")
let rb = try store.rebuildProjections()
check(rb.stateEqual && rb.clipsEqual && rb.historyEqual, "rebuild byte-equal: state=\(rb.stateEqual) clips=\(rb.clipsEqual) history=\(rb.historyEqual) (\(rb.events) events)")
try store.close()

// MARK: 6. Benchmarks
print("== Benchmarks ==")
let benchPath = dir.appendingPathComponent("bench.sqlite").path
let bench = try ProjectStore(path: benchPath)
let N = 10_000
let (_, appendSecs) = try timed {
    for i in 0..<N {
        _ = try bench.apply(.addClip(clip("clip-\(String(format: "%05d", i))", track: "V\(i % 4 + 1)", start: Int64(i) * 48048)), expectedVersion: Int64(i), commandId: uuidv7(), actor: "human")
    }
}
print(String(format: "  append %d single-event commands (state grows to %d clips): %.3f s = %.0f cmd/s, %.2f ms/cmd", N, N, appendSecs, Double(N) / appendSecs, appendSecs / Double(N) * 1000))
let stateBytes = try bench.pool.read { try Int.fetchOne($0, sql: "SELECT length(state) FROM project_state")! }
let (bigState, decSecs) = try timed { try bench.currentState() }
let (_, encSecs) = try timed { _ = try canonicalJSON(bigState) }
let (_, encPlain) = try timed { _ = try JSONEncoder().encode(bigState) }
print(String(format: "  full-state JSON at 10k clips: decode %.1f ms, canonical (sortedKeys) encode %.1f ms, plain encode %.1f ms  <- per-command floor for the full-state projection", decSecs * 1000, encSecs * 1000, encPlain * 1000))
print("  project_state.state JSON size at 10k clips: \(mb(Int64(stateBytes))); db=\(mb(fileSize(benchPath))) wal=\(mb(fileSize(benchPath + "-wal")))")
// Append with a bounded state: add+remove pairs so state stays ~1 clip. Isolates the cost of the full-state rewrite.
let small = try ProjectStore(path: dir.appendingPathComponent("small.sqlite").path)
let (_, smallSecs) = try timed {
    for i in 0..<N {
        let id = "s\(i)"
        _ = try small.apply(i % 2 == 0 ? .addClip(clip(id)) : .removeClip(clipId: "s\(i - 1)"), expectedVersion: Int64(i), commandId: uuidv7(), actor: "human")
    }
}
print(String(format: "  append %d single-event commands (state stays tiny): %.3f s = %.0f cmd/s, %.2f ms/cmd", N, smallSecs, Double(N) / smallSecs, smallSecs / Double(N) * 1000))
try small.close()
// Raw event insert throughput without projections (the floor).
let raw = try ProjectStore(path: dir.appendingPathComponent("raw.sqlite").path)
let (_, rawSecs) = try timed {
    try raw.pool.write { db in
        _ = try ProjectStore.append(db, (0..<N).map { .clipAdded(clip("r\($0)")) }, fromVersion: 0, txnId: uuidv7(), commandId: uuidv7(), actor: "human")
    }
}
print(String(format: "  raw INSERT of %d events in one txn (floor): %.3f s = %.0f events/s", N, rawSecs, Double(N) / rawSecs))
try raw.close()
// Replay: pure fold only, then full rebuildProjections.
let (foldCount, foldSecs) = try timed {
    try bench.pool.read { db in
        var s = Project(); var n = 0
        let cur = try Row.fetchCursor(db, sql: "SELECT type, payload FROM events ORDER BY seq")
        while let row = try cur.next() { evolve(&s, try Event.decode(type: row["type"], payload: row["payload"])); n += 1 }
        return n
    }
}
print(String(format: "  replay %d events, pure fold (decode+evolve): %.3f s", foldCount, foldSecs))
let rb2 = try bench.rebuildProjections()
print(String(format: "  rebuildProjections %d events (fold + clips/history/state rewrite): %.3f s; byte-equal state=%@ clips=%@ history=%@", rb2.events, rb2.seconds, "\(rb2.stateEqual)", "\(rb2.clipsEqual)", "\(rb2.historyEqual)"))
// WAL on close
print("  before close: db=\(mb(fileSize(benchPath))) wal=\(mb(fileSize(benchPath + "-wal")))")
try bench.close()
print("  after close (wal_checkpoint TRUNCATE): db=\(mb(fileSize(benchPath))) wal=\(mb(fileSize(benchPath + "-wal"))) wal exists=\(FileManager.default.fileExists(atPath: benchPath + "-wal"))")
// Open + load
let (loaded, openSecs) = try timed { try ProjectStore(path: benchPath).currentState() }
print(String(format: "  open + migrate + load project_state (%d clips): %.1f ms", loaded.clips.count, openSecs * 1000))
let reopened = try ProjectStore(path: benchPath)
let (_, loadOnly) = try timed { try reopened.currentState() }
print(String(format: "  load project_state only: %.1f ms", loadOnly * 1000))
let copyPath = dir.appendingPathComponent("backup.sqlite").path
let (_, vacSecs) = try timed { try reopened.pool.writeWithoutTransaction { try $0.execute(sql: "VACUUM INTO ?", arguments: [copyPath]) } }
print(String(format: "  VACUUM INTO copy: %.1f ms, copy size %@", vacSecs * 1000, mb(fileSize(copyPath))))
let (ic, icSecs) = try timed { try reopened.pool.read { try String.fetchOne($0, sql: "PRAGMA integrity_check")! } }
print(String(format: "  integrity_check: %@ in %.1f ms", ic, icSecs * 1000))
try reopened.close()
print("done: \(dir.path)")
