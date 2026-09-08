import Foundation
import MCP

/// In-memory fake project with optimistic concurrency + idempotent commands.
actor FakeProject {
    struct Clip: Codable, Sendable { var id: String; var track: String; var start: Int; var duration: Int }
    struct ApplyResult: Codable, Sendable { var version: Int; var changedIds: [String] }
    enum ApplyError: Error { case stale(current: Int), unknownClip(String), badOp(String) }

    private(set) var version = 1
    private var clips: [String: Clip] = [
        "c1": Clip(id: "c1", track: "V1", start: 0, duration: 90),
        "c2": Clip(id: "c2", track: "V1", start: 90, duration: 60),
        "a1": Clip(id: "a1", track: "A1", start: 0, duration: 150),
    ]
    private var applied: [String: ApplyResult] = [:]   // commandId -> result (idempotency)

    func describe() -> Value {
        let tracks = Set(clips.values.map(\.track)).sorted()
        return .object([
            "version": .int(version),
            "tracks": .array(tracks.map { .string($0) }),
            "clips": .array(clips.values.sorted { $0.start < $1.start }.map {
                .object(["id": .string($0.id), "track": .string($0.track), "start": .int($0.start), "duration": .int($0.duration)])
            }),
        ])
    }

    func apply(ops: [[String: Value]], baseVersion: Int, commandId: String) throws -> ApplyResult {
        if let prior = applied[commandId] { return prior }                       // idempotent retry
        guard baseVersion == version else { throw ApplyError.stale(current: version) }
        var next = clips
        var changed: [String] = []
        for op in ops {
            guard let id = op["clipId"]?.stringValue, var clip = next[id] else {
                throw ApplyError.unknownClip(op["clipId"]?.stringValue ?? "<missing>")
            }
            switch op["op"]?.stringValue {
            case "moveClip":
                guard let start = op["start"]?.intValue else { throw ApplyError.badOp("moveClip needs start") }
                clip.start = start
            case "trimClip":
                guard let duration = op["duration"]?.intValue else { throw ApplyError.badOp("trimClip needs duration") }
                clip.duration = duration
            default: throw ApplyError.badOp("unknown op \(op["op"]?.stringValue ?? "nil")")
            }
            next[id] = clip; changed.append(id)
        }
        clips = next; version += 1
        let result = ApplyResult(version: version, changedIds: changed)
        applied[commandId] = result
        return result
    }
}
