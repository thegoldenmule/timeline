import Foundation

/// Schema evolution on read. Old event rows are never rewritten; `upcast` lifts a payload from the
/// version it was written at to the current one, applying one registered step per version, then
/// recursing into embedded clip snapshots by their own `clipSchema`.
public enum Upcaster {
    /// Version stamped on every event `decide` produces.
    public static let currentSchemaVersion = 1
    /// Version stamped on every embedded clip snapshot.
    public static let currentClipSchema = 1

    public typealias Step = @Sendable (JSONValue) -> JSONValue

    /// Where embedded clip snapshots live inside a payload, by event type.
    public enum Embedded: Sendable {
        case clip(key: String)
        case clips(key: String)
        case track(key: String)
    }

    public struct Registry: Sendable {
        /// `eventSteps[type][from]` lifts a payload from version `from` to `from + 1`.
        var eventSteps: [String: [Int: Step]] = [:]
        /// `clipSteps[from]` lifts a clip snapshot from clip schema `from` to `from + 1`.
        var clipSteps: [Int: Step] = [:]
        var embedded: [String: [Embedded]] = Upcaster.standardEmbedded

        public init() {}

        public mutating func register(type: String, from version: Int, step: @escaping Step) {
            eventSteps[type, default: [:]][version] = step
        }

        public mutating func registerClip(from version: Int, step: @escaping Step) {
            clipSteps[version] = step
        }

        public mutating func registerEmbedded(type: String, _ locations: [Embedded]) {
            embedded[type] = locations
        }

        /// The registry with every historical step this build knows about.
        public static let standard: Registry = {
            var r = Registry()
            // v0 ClipTrimmed carried `from`/`to`; v1 renamed them to `before`/`after`.
            r.register(type: "ClipTrimmed", from: 0) { payload in
                var p = payload
                if let from = p["from"] {
                    p["before"] = from
                    p["from"] = nil
                }
                if let to = p["to"] {
                    p["after"] = to
                    p["to"] = nil
                }
                return p
            }
            // Clip schema 0 stored the source range as `in`/`out`; schema 1 as `sourceIn`/`sourceOut`.
            r.registerClip(from: 0) { clip in
                var c = clip
                if let v = c["in"] {
                    c["sourceIn"] = v
                    c["in"] = nil
                }
                if let v = c["out"] {
                    c["sourceOut"] = v
                    c["out"] = nil
                }
                return c
            }
            return r
        }()
    }

    /// Which payload keys hold clip snapshots, per event type.
    public static let standardEmbedded: [String: [Embedded]] = [
        "ClipAdded": [.clip(key: "snapshot")],
        "ClipRemoved": [.clip(key: "snapshot")],
        "ClipSplit": [.clip(key: "newClip")],
        "ClipsJoined": [.clip(key: "removedSnapshot")],
        "CaptionsReplaced": [.clips(key: "before"), .clips(key: "after")],
        "TrackRemoved": [.track(key: "snapshot")],
        "TrackRestored": [.track(key: "snapshot")],
    ]

    /// Lifts `payload` (the fields of an event of `type`, written at `version`) to the current schema.
    public static func upcast(type: String, version: Int, payload: JSONValue, registry: Registry = .standard)
        -> JSONValue
    {
        var p = payload
        if version < currentSchemaVersion, let steps = registry.eventSteps[type] {
            for v in version..<currentSchemaVersion {
                if let step = steps[v] { p = step(p) }
            }
        }
        guard let locations = registry.embedded[type] else { return p }
        let clipSchema = p["clipSchema"]?.intValue ?? currentClipSchema
        guard clipSchema < currentClipSchema else { return p }
        for location in locations {
            switch location {
            case .clip(let key):
                if let clip = p[key] { p[key] = upcastClip(clip, from: clipSchema, registry: registry) }
            case .clips(let key):
                if let clips = p[key]?.arrayValue {
                    p[key] = .array(clips.map { upcastClip($0, from: clipSchema, registry: registry) })
                }
            case .track(let key):
                if var track = p[key], let clips = track["clips"]?.objectValue {
                    track["clips"] = .object(clips.mapValues { upcastClip($0, from: clipSchema, registry: registry) })
                    p[key] = track
                }
            }
        }
        p["clipSchema"] = .number(Double(currentClipSchema))
        return p
    }

    /// Lifts one clip snapshot from clip schema `version` to the current one.
    public static func upcastClip(_ clip: JSONValue, from version: Int, registry: Registry = .standard) -> JSONValue {
        var c = clip
        guard version < currentClipSchema else { return c }
        for v in version..<currentClipSchema {
            if let step = registry.clipSteps[v] { c = step(c) }
        }
        return c
    }
}
