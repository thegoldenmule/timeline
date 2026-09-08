// Pure core: no I/O. Mirrors storage.md sections 6 to 9 at the smallest useful size.
import Foundation

struct RationalTime: Codable, Hashable, Sendable {
    var v: Int64
    var ts: Int32
}

struct Clip: Codable, Hashable, Sendable {
    var clipId: String
    var trackId: String
    var assetId: String?
    var start: RationalTime
    var `in`: RationalTime
    var out: RationalTime
}

struct Track: Codable, Hashable, Sendable {
    var trackId: String
    var kind: String
    var position: Int
    var name: String
}

/// Dictionaries keyed by id so the canonical (sorted-keys) JSON is order independent.
struct Project: Codable, Hashable, Sendable {
    var version: Int64 = 0
    var tracks: [String: Track] = [:]
    var clips: [String: Clip] = [:]
}

struct Placement: Codable, Hashable, Sendable { var trackId: String; var start: RationalTime }
struct TrimState: Codable, Hashable, Sendable { var start: RationalTime; var `in`: RationalTime; var out: RationalTime }

enum Command: Sendable {
    case addClip(Clip)
    case moveClip(clipId: String, to: Placement)
    case trimClip(clipId: String, edge: String, to: TrimState)
    case removeClip(clipId: String)
    case undo(txnId: String)

    var name: String {
        switch self {
        case .addClip: "addClip"
        case .moveClip: "moveClip"
        case .trimClip: "trimClip"
        case .removeClip: "removeClip"
        case .undo: "undo"
        }
    }
    var args: String {
        switch self {
        case .addClip(let c): (try? canonicalJSON(c)) ?? "{}"
        case .moveClip(let id, let p): (try? canonicalJSON(["clipId": AnyEnc(id), "to": AnyEnc(p)])) ?? "{}"
        case .trimClip(let id, let e, let t): (try? canonicalJSON(["clipId": AnyEnc(id), "edge": AnyEnc(e), "to": AnyEnc(t)])) ?? "{}"
        case .removeClip(let id): (try? canonicalJSON(["clipId": id])) ?? "{}"
        case .undo(let t): (try? canonicalJSON(["txnId": t])) ?? "{}"
        }
    }
}

// Payload shapes, one Codable struct per event type (section 7).
struct ClipMovedPayload: Codable, Sendable { var clipId: String; var before: Placement; var after: Placement }
struct ClipTrimmedPayload: Codable, Sendable { var clipId: String; var edge: String; var before: TrimState; var after: TrimState }
struct ClipRemovedPayload: Codable, Sendable { var clipId: String; var snapshot: Clip }
struct TransactionUndonePayload: Codable, Sendable { var targetTxnId: String }

enum Event: Sendable, Equatable {
    case clipAdded(Clip)
    case clipMoved(ClipMovedPayload)
    case clipTrimmed(ClipTrimmedPayload)
    case clipRemoved(ClipRemovedPayload)
    case transactionUndone(TransactionUndonePayload)

    var type: String {
        switch self {
        case .clipAdded: "ClipAdded"
        case .clipMoved: "ClipMoved"
        case .clipTrimmed: "ClipTrimmed"
        case .clipRemoved: "ClipRemoved"
        case .transactionUndone: "TransactionUndone"
        }
    }
    var clipId: String? {
        switch self {
        case .clipAdded(let c): c.clipId
        case .clipMoved(let p): p.clipId
        case .clipTrimmed(let p): p.clipId
        case .clipRemoved(let p): p.clipId
        case .transactionUndone: nil
        }
    }
    func payloadJSON() throws -> String {
        switch self {
        case .clipAdded(let p): try canonicalJSON(p)
        case .clipMoved(let p): try canonicalJSON(p)
        case .clipTrimmed(let p): try canonicalJSON(p)
        case .clipRemoved(let p): try canonicalJSON(p)
        case .transactionUndone(let p): try canonicalJSON(p)
        }
    }
    static func decode(type: String, payload: String) throws -> Event {
        let d = Data(payload.utf8), dec = JSONDecoder()
        switch type {
        case "ClipAdded": return .clipAdded(try dec.decode(Clip.self, from: d))
        case "ClipMoved": return .clipMoved(try dec.decode(ClipMovedPayload.self, from: d))
        case "ClipTrimmed": return .clipTrimmed(try dec.decode(ClipTrimmedPayload.self, from: d))
        case "ClipRemoved": return .clipRemoved(try dec.decode(ClipRemovedPayload.self, from: d))
        case "TransactionUndone": return .transactionUndone(try dec.decode(TransactionUndonePayload.self, from: d))
        default: throw CoreError.unknownEventType(type)
        }
    }
}

extension ClipMovedPayload: Equatable {}
extension ClipTrimmedPayload: Equatable {}
extension ClipRemovedPayload: Equatable {}
extension TransactionUndonePayload: Equatable {}

enum CoreError: Error {
    case clipExists(String), noSuchClip(String), unknownEventType(String), alreadyUndone(String), noSuchTxn(String)
}

/// `undoTarget` supplies the events of the transaction being undone (loaded by the store) so this stays pure.
func decide(_ state: Project, _ command: Command, undoTarget: [Event]? = nil) throws -> [Event] {
    switch command {
    case .addClip(let clip):
        guard state.clips[clip.clipId] == nil else { throw CoreError.clipExists(clip.clipId) }
        return [.clipAdded(clip)]
    case .moveClip(let id, let to):
        guard let c = state.clips[id] else { throw CoreError.noSuchClip(id) }
        let before = Placement(trackId: c.trackId, start: c.start)
        return before == to ? [] : [.clipMoved(.init(clipId: id, before: before, after: to))]
    case .trimClip(let id, let edge, let to):
        guard let c = state.clips[id] else { throw CoreError.noSuchClip(id) }
        let before = TrimState(start: c.start, in: c.in, out: c.out)
        return before == to ? [] : [.clipTrimmed(.init(clipId: id, edge: edge, before: before, after: to))]
    case .removeClip(let id):
        guard let c = state.clips[id] else { throw CoreError.noSuchClip(id) }
        return [.clipRemoved(.init(clipId: id, snapshot: c))]
    case .undo(let txnId):
        guard let target = undoTarget else { throw CoreError.noSuchTxn(txnId) }
        return [.transactionUndone(.init(targetTxnId: txnId))] + target.reversed().flatMap(invert)
    }
}

/// Pure signature from the design; the `inout` overload below is the workhorse so a replay loop does not
/// copy the whole `clips` dictionary per event (measured: O(n^2) fold without it).
func evolve(_ state: Project, _ event: Event) -> Project { var s = state; evolve(&s, event); return s }
func evolve(_ s: inout Project, _ event: Event) {
    switch event {
    case .clipAdded(let c): s.clips[c.clipId] = c
    case .clipMoved(let p): s.clips[p.clipId]?.trackId = p.after.trackId; s.clips[p.clipId]?.start = p.after.start
    case .clipTrimmed(let p):
        s.clips[p.clipId]?.start = p.after.start; s.clips[p.clipId]?.in = p.after.in; s.clips[p.clipId]?.out = p.after.out
    case .clipRemoved(let p): s.clips.removeValue(forKey: p.clipId)
    case .transactionUndone: break
    }
}

func invert(_ event: Event) -> [Event] {
    switch event {
    case .clipAdded(let c): [.clipRemoved(.init(clipId: c.clipId, snapshot: c))]
    case .clipRemoved(let p): [.clipAdded(p.snapshot)]
    case .clipMoved(let p): [.clipMoved(.init(clipId: p.clipId, before: p.after, after: p.before))]
    case .clipTrimmed(let p): [.clipTrimmed(.init(clipId: p.clipId, edge: p.edge, before: p.after, after: p.before))]
    case .transactionUndone: []   // marker only; redo is a separate compensating txn (section 9)
    }
}

// Canonical JSON: sorted keys, no escaped slashes, no whitespace. Byte-stable for the rebuild comparison.
private let canonicalEncoder: JSONEncoder = {
    let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
}()
func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try canonicalEncoder.encode(value), as: UTF8.self)
}
struct AnyEnc: Encodable {
    let encode: @Sendable (Encoder) throws -> Void
    init<T: Encodable & Sendable>(_ v: T) { encode = { try v.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
