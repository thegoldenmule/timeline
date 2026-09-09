import Contracts
import Foundation
import TimelineCore

/// Helpers shared by the tool handlers: input decoding, project resolution, and the common output
/// shapes (`{ version, changedIds, warnings, txnId }`).
enum ToolSupport {
    /// Decodes `input[key]` as `T` through the project codec, with a readable error.
    static func decode<T: Decodable>(_ input: ToolInput, _ key: String, as type: T.Type) throws -> T? {
        guard let value = input[key], !value.isNull else { return nil }
        do {
            return try value.decoded(as: type)
        } catch {
            throw ToolError.invalidInput("\(key): \(describe(error))")
        }
    }

    static func require<T: Decodable>(_ input: ToolInput, _ key: String, as type: T.Type) throws -> T {
        guard let value = try decode(input, key, as: type) else {
            throw ToolError.invalidInput("\(key) is required")
        }
        return value
    }

    static func string(_ input: ToolInput, _ key: String) -> String? { input[key]?.stringValue }

    static func requireString(_ input: ToolInput, _ key: String) throws -> String {
        guard let s = string(input, key), !s.isEmpty else { throw ToolError.invalidInput("\(key) is required") }
        return s
    }

    static func describe(_ error: any Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, let context):
                return "missing \(path(context.codingPath + [key]))"
            case .typeMismatch(let type, let context):
                return "\(path(context.codingPath)) should be \(type): \(context.debugDescription)"
            case .valueNotFound(let type, let context):
                return "\(path(context.codingPath)) needs a \(type)"
            case .dataCorrupted(let context):
                return "\(path(context.codingPath)) \(context.debugDescription)"
            @unknown default:
                return String(describing: decoding)
            }
        }
        return (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        let s = keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        return s.isEmpty ? "value" : s.replacingOccurrences(of: ".[", with: "[")
    }

    // MARK: Project resolution

    struct Resolved {
        var store: any ProjectStore
        var project: Project
        var projectId: ProjectID
    }

    static func resolve(_ input: ToolInput, _ context: ToolContext) async throws -> Resolved {
        let store = try await context.store(for: input)
        let project = await store.state()
        return Resolved(store: store, project: project, projectId: project.id)
    }

    /// The sequence `input.sequenceId` names, else the active one, else the only one.
    static func sequence(_ input: ToolInput, in project: Project) throws -> Sequence {
        if let id = string(input, "sequenceId") {
            guard let s = project.sequences[SequenceID(id)] else { throw EditorError.notFound(id: id) }
            return s
        }
        if let s = project.activeSequence { return s }
        if project.sequences.count == 1, let s = project.sequences.values.first { return s }
        throw ToolError.invalidInput("The project has no active sequence; pass sequenceId")
    }

    static func asset(_ id: String, in project: Project) throws -> Asset {
        guard let asset = project.assets[AssetID(id)] else { throw EditorError.notFound(id: id) }
        return asset
    }

    /// Where an asset's file lives, through the library layout when one is configured.
    static func mediaURL(for asset: Asset, context: ToolContext) -> URL {
        (context.services.mediaLibrary?.layout ?? LibraryLayout.default).url(for: asset)
    }

    static func mediaReference(for asset: Asset, context: ToolContext) -> MediaReference {
        MediaReference(url: mediaURL(for: asset, context: context), contentHash: asset.contentHash)
    }

    // MARK: Commands

    /// The command envelope for a mutating tool: `commandId` from the input or minted, `expectedVersion`
    /// from the input (agents supply it; the schema requires it where the plan says so).
    static func command(
        _ operation: Command.Operation, input: ToolInput, context: ToolContext, requireExpectedVersion: Bool = false
    ) throws -> Command {
        let expected = input["expectedVersion"]?.intValue.map(Int64.init)
        if requireExpectedVersion, expected == nil {
            throw ToolError.invalidInput("expectedVersion is required; read it with project_describe")
        }
        let id = string(input, "commandId") ?? UUIDv7Generator().next()
        return Command(
            commandId: CommandID(id), actor: context.actor, expectedVersion: expected, label: string(input, "label"),
            operation: operation)
    }

    /// Applies `command` and returns the mutating-tool result. A stale rejection whose `changedSince`
    /// the decider could not fill is completed from the store before it is returned.
    static func apply(_ command: Command, to store: any ProjectStore, extra: [String: JSONValue] = [:]) async throws
        -> ToolOutput
    {
        do {
            let result = try await store.apply(command)
            return try applied(result, projectId: await store.projectId, extra: extra)
        } catch EditorError.staleVersion(let current, nil) {
            let since = await store.changedSince(command.expectedVersion ?? current)
            throw EditorError.staleVersion(current: current, changedSince: since)
        }
    }

    static func applied(_ result: CommandResult, projectId: ProjectID, extra: [String: JSONValue] = [:]) throws
        -> ToolOutput
    {
        var o: [String: JSONValue] = [
            "version": .number(Double(result.version)),
            "changedIds": .array(result.changedIds.sorted().map { .string($0) }),
            "warnings": .array(result.warnings.map { .string($0) }),
            "status": .string(result.status.rawValue),
            "commandId": .string(result.commandId.rawValue),
            "projectId": .string(projectId.rawValue),
        ]
        if let txn = result.txnId { o["txnId"] = .string(txn.rawValue) }
        for (k, v) in extra { o[k] = v }
        let text: String
        switch result.status {
        case .applied: text = "Applied; version \(result.version), changed \(result.changedIds.count) entities."
        case .noop: text = "Nothing changed; version \(result.version)."
        case .replayed: text = "Already applied (same commandId); version \(result.version)."
        }
        return ToolOutput(structured: .object(o), text: text)
    }

    /// The `{ version, changedIds, warnings, txnId }` output schema every mutating tool shares.
    static var mutationOutputSchema: [String: JSONValue] {
        [
            "version": Schema.integer("Project version after the call; pass it as expectedVersion next time."),
            "changedIds": Schema.array("Ids of every entity the call touched.", items: Schema.string("Entity id.")),
            "warnings": Schema.array("Non-fatal notes.", items: Schema.string("Warning.")),
            "txnId": Schema.string("Transaction id (undo target); absent for a no-op."),
            "status": Schema.enum("applied, noop, or replayed (idempotent retry).", ["applied", "noop", "replayed"]),
            "commandId": Schema.string("The idempotency key used."),
            "projectId": Schema.string("The project the call addressed."),
        ]
    }

    /// Common input properties: `projectId` and, for mutating tools, `expectedVersion` and `commandId`.
    static func inputProperties(mutating: Bool, _ extra: [String: JSONValue]) -> [String: JSONValue] {
        var p = extra
        p["projectId"] = Schema.string("Project to address; defaults to the frontmost project.")
        if mutating {
            p["expectedVersion"] = Schema.integer(
                "The project version you last read. A different current version rejects the call with staleVersion and a changedSince diff.",
                minimum: 0)
            p["commandId"] = Schema.string(
                "Idempotency key (any unique string). Retrying with the same commandId returns the stored result and applies nothing twice."
            )
            p["label"] = Schema.string("Undo-history label (optional).")
        }
        return p
    }

    // MARK: Time and JSON helpers

    static func json<T: Encodable>(_ value: T) -> JSONValue { (try? JSONValue(encoding: value)) ?? .null }

    static func seconds(_ t: RationalTime) -> JSONValue { .number((t.seconds * 1000).rounded() / 1000) }

    static func timeJSON(_ t: RationalTime) -> JSONValue {
        .object(["v": .number(Double(t.value)), "ts": .number(Double(t.timescale)), "seconds": seconds(t)])
    }

    /// Timeline range of a clip within its sequence.
    static func range(of clip: Clip, in sequence: Sequence) -> TimeRange {
        TimeRange(start: clip.start, end: sequence.end(of: clip))
    }

    static func overlaps(_ a: TimeRange, _ b: TimeRange) -> Bool { a.start < b.end && b.start < a.end }

    static func duration(of sequence: Sequence) -> RationalTime {
        var end = RationalTime.zero
        for track in sequence.tracks {
            for clip in track.clips.values { end = RationalTime.max(end, sequence.end(of: clip)) }
        }
        return end
    }
}
