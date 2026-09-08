import Contracts
import Foundation
import TimelineCore

/// `project_list`, `project_describe`, `timeline_query`: the read side.
enum ProjectTools {
    static let projectList = Tool(
        name: "project_list",
        description:
            "Lists the projects open in the editor with their current version and which one is frontmost. Call it first when you do not know a projectId; every other tool defaults to the frontmost project.",
        inputSchema: Schema.object("No arguments.", properties: [:]),
        outputSchema: Schema.object(
            "Open projects.",
            properties: [
                "projects": Schema.array(
                    "Open projects, frontmost first.",
                    items: Schema.object(
                        "One open project.",
                        properties: [
                            "projectId": Schema.string("Project id."),
                            "name": Schema.string("Project name."),
                            "version": Schema.integer("Current version (use as expectedVersion)."),
                            "activeSequenceId": Schema.string("Active sequence id."),
                            "isFrontmost": Schema.bool("True for the frontmost document."),
                            "url": Schema.string("The .tlproj path, when saved."),
                        ], required: ["projectId", "name", "version", "isFrontmost"])),
                "count": Schema.integer("Number of open projects."),
            ], required: ["projects", "count"]),
        annotations: .readOnly(title: "List open projects"), examples: [.object([:])]
    ) { _, context in
        let open = await context.projects.open().sorted { $0.isFrontmost && !$1.isFrontmost }
        let items: [JSONValue] = open.map { p in
            var o: [String: JSONValue] = [
                "projectId": .string(p.id.rawValue), "name": .string(p.name), "version": .number(Double(p.version)),
                "isFrontmost": .bool(p.isFrontmost),
            ]
            if let s = p.activeSequenceId { o["activeSequenceId"] = .string(s.rawValue) }
            if let u = p.url { o["url"] = .string(u.path) }
            return .object(o)
        }
        let text =
            open.isEmpty
            ? "No project is open."
            : open.map { "\($0.name) (\($0.id.rawValue)) v\($0.version)\($0.isFrontmost ? " [frontmost]" : "")" }
                .joined(separator: "\n")
        return ToolOutput(
            structured: .object(["projects": .array(items), "count": .number(Double(open.count))]), text: text)
    }

    static let projectDescribe = Tool(
        name: "project_describe",
        description:
            "Describes a project. level summary: name, version, settings, sequences and assets. level tracks: adds every track with its clips (id, start, end, asset, label, caption text), transitions and markers, optionally limited to a time range. level full: the complete project document as JSON (large). Read this before timeline_apply to get ids and the expectedVersion.",
        inputSchema: Schema.withDefs(
            Schema.object(
                "Describe request.",
                properties: ToolSupport.inputProperties(
                    mutating: false,
                    [
                        "level": Schema.enum("How much detail to return (default summary).", ["summary", "tracks", "full"]),
                        "sequenceId": Schema.string("Limit tracks/full to one sequence (default: the active one)."),
                        "range": Schema.ref("timeRange", "Only clips overlapping this timeline range (levels tracks and full)."),
                    ])),
            ["time": OperationSchemas.defs["time"]!, "timeRange": OperationSchemas.defs["timeRange"]!]),
        outputSchema: Schema.object(
            "Project description; `sequences[].tracks` is present at level tracks, `project` at level full.",
            properties: [
                "projectId": Schema.string("Project id."),
                "name": Schema.string("Project name."),
                "version": Schema.integer("Current version; pass it as expectedVersion."),
                "activeSequenceId": Schema.string("Active sequence id."),
                "settings": Schema.any("Project settings."),
                "sequences": Schema.array("Sequences.", items: Schema.any("Sequence summary, with tracks at level tracks.")),
                "assets": Schema.array("Assets.", items: Schema.any("Asset summary.")),
                "history": Schema.any("Undo/redo targets."),
                "project": Schema.any("The full project document (level full)."),
            ], required: ["projectId", "name", "version", "sequences", "assets"], additionalProperties: true),
        annotations: .readOnly(title: "Describe project"),
        examples: [
            .object([:]), .object(["level": "tracks"]),
            .object([
                "level": "tracks", "range": ["start": ["v": 0, "ts": 24000], "end": ["v": 240240, "ts": 24000]],
            ]),
            .object(["projectId": "00000000-0000-7000-8000-000000000003", "level": "full"]),
        ]
    ) { input, context in
        let resolved = try await ToolSupport.resolve(input, context)
        let project = resolved.project
        let level = ToolSupport.string(input, "level") ?? "summary"
        let range = try ToolSupport.decode(input, "range", as: TimeRange.self)
        let only = ToolSupport.string(input, "sequenceId").map { SequenceID($0) }
        var o: [String: JSONValue] = [
            "projectId": .string(project.id.rawValue), "name": .string(project.name),
            "version": .number(Double(project.version)), "settings": ToolSupport.json(project.settings),
            "assets": .array(project.assets.values.sorted { $0.id < $1.id }.map(assetSummary)),
            "sequences": .array(
                project.sequences.values.sorted { $0.id < $1.id }.filter { only == nil || $0.id == only }.map {
                    sequenceSummary($0, level: level, range: range, isActive: $0.id == project.activeSequenceId)
                }),
        ]
        if let active = project.activeSequenceId { o["activeSequenceId"] = .string(active.rawValue) }
        let history = await resolved.store.history()
        var h: [String: JSONValue] = [:]
        if let undo = history.latestLive { h["undo"] = ["txnId": .string(undo.id.rawValue), "label": .string(undo.label)] }
        if let redo = history.redoTarget { h["redo"] = ["txnId": .string(redo.id.rawValue), "label": .string(redo.label)] }
        o["history"] = .object(h)
        if level == "full" {
            var document = project
            if let range {
                for (sid, var sequence) in document.sequences {
                    for i in sequence.tracks.indices {
                        sequence.tracks[i].clips = sequence.tracks[i].clips.filter {
                            ToolSupport.overlaps(ToolSupport.range(of: $0.value, in: sequence), range)
                        }
                    }
                    document.sequences[sid] = sequence
                }
            }
            if let only { document.sequences = document.sequences.filter { $0.key == only } }
            o["project"] = ToolSupport.json(document)
        }
        let clipCount = project.sequences.values.reduce(0) { $0 + $1.tracks.reduce(0) { $0 + $1.clips.count } }
        let text =
            "\(project.name): version \(project.version), \(project.sequences.count) sequence(s), \(clipCount) clip(s), \(project.assets.count) asset(s)."
        return ToolOutput(structured: .object(o), text: text)
    }

    static func assetSummary(_ a: Asset) -> JSONValue {
        var o: [String: JSONValue] = [
            "assetId": .string(a.id.rawValue), "displayName": .string(a.displayName), "kind": .string(a.kind.rawValue),
            "duration": ToolSupport.timeJSON(a.duration), "hasVideo": .bool(a.hasVideo), "hasAudio": .bool(a.hasAudio),
            "offline": .bool(a.offline), "analyses": .array(a.analyses.keys.sorted().map { .string($0) }),
            "libraryPath": .string(a.libraryPath),
        ]
        if let w = a.probe.width, let h = a.probe.height { o["size"] = .string("\(w)x\(h)") }
        if let fps = a.probe.fps { o["fps"] = .number((fps.doubleValue * 1000).rounded() / 1000) }
        if let sr = a.sampleRate { o["sampleRate"] = .number(Double(sr)) }
        if let codec = a.probe.codec { o["codec"] = .string(codec) }
        if let transfer = a.probe.transfer { o["transfer"] = .string(transfer) }
        return .object(o)
    }

    static func sequenceSummary(_ s: Sequence, level: String, range: TimeRange?, isActive: Bool) -> JSONValue {
        var o: [String: JSONValue] = [
            "sequenceId": .string(s.id.rawValue), "name": .string(s.name), "frameDuration": ToolSupport.timeJSON(s.frameDuration),
            "width": .number(Double(s.width)), "height": .number(Double(s.height)),
            "duration": ToolSupport.timeJSON(ToolSupport.duration(of: s)), "trackCount": .number(Double(s.tracks.count)),
            "isActive": .bool(isActive),
        ]
        if level != "summary" {
            o["tracks"] = .array(s.tracks.map { trackSummary($0, in: s, range: range) })
            o["transitions"] = .array(s.transitions.values.sorted { $0.id < $1.id }.map(transitionSummary))
            o["markers"] = .array(
                s.markers.values.sorted { $0.at < $1.at }.filter { marker in range.map { r in r.contains(marker.at) } ?? true }.map {
                    var m: [String: JSONValue] = [
                        "markerId": .string($0.id.rawValue), "at": ToolSupport.timeJSON($0.at), "label": .string($0.label),
                    ]
                    if let c = $0.colour { m["colour"] = .string(c) }
                    return .object(m)
                })
        }
        return .object(o)
    }

    static func trackSummary(_ t: Track, in s: Sequence, range: TimeRange?) -> JSONValue {
        let clips = t.clips.values.sorted { $0.start < $1.start }.filter { clip in
            range.map { r in ToolSupport.overlaps(ToolSupport.range(of: clip, in: s), r) } ?? true
        }
        var o: [String: JSONValue] = [
            "trackId": .string(t.id.rawValue), "kind": .string(t.kind.rawValue), "name": .string(t.name),
            "muted": .bool(t.muted), "locked": .bool(t.locked), "clipCount": .number(Double(t.clips.count)),
            "clips": .array(clips.map { clipSummary($0, in: s) }),
        ]
        if let l = t.language { o["language"] = .string(l) }
        if let style = t.captionStyle { o["captionStyle"] = ToolSupport.json(style) }
        return .object(o)
    }

    static func clipSummary(_ c: Clip, in s: Sequence) -> JSONValue {
        let end = s.end(of: c)
        var o: [String: JSONValue] = [
            "clipId": .string(c.id.rawValue), "trackId": .string(c.trackId.rawValue), "start": ToolSupport.timeJSON(c.start),
            "end": ToolSupport.timeJSON(end), "duration": ToolSupport.timeJSON(end - c.start),
            "sourceIn": ToolSupport.timeJSON(c.sourceIn), "sourceOut": ToolSupport.timeJSON(c.sourceOut),
            "speed": ToolSupport.json(c.speed),
        ]
        if let a = c.assetId { o["assetId"] = .string(a.rawValue) }
        if let g = c.linkGroupId { o["linkGroupId"] = .string(g.rawValue) }
        if let l = c.label { o["label"] = .string(l) }
        if let t = c.text { o["text"] = .string(t) }
        if !c.effects.isEmpty { o["effects"] = .array(c.effects.map { .string("\($0.id.rawValue):\($0.kind)") }) }
        if c.audio.muted { o["muted"] = .bool(true) }
        return .object(o)
    }

    static func transitionSummary(_ t: Transition) -> JSONValue {
        .object([
            "transitionId": .string(t.id.rawValue), "trackId": .string(t.trackId.rawValue),
            "leftClipId": .string(t.leftClipId.rawValue), "rightClipId": .string(t.rightClipId.rawValue),
            "kind": .string(t.kind), "duration": ToolSupport.timeJSON(t.duration), "alignment": .string(t.alignment.rawValue),
        ])
    }

    static let timelineQuery = Tool(
        name: "timeline_query",
        description:
            "Finds entities in a project by filter: clips, transitions, markers, tracks, assets, or history (transactions). Filter by sequence, track, track kind, asset, time range, or text. Cheaper than project_describe when you need one thing.",
        inputSchema: Schema.withDefs(
            Schema.object(
                "Query request.",
                properties: ToolSupport.inputProperties(
                    mutating: false,
                    [
                        "filter": Schema.object(
                            "What to return and how to narrow it.",
                            properties: [
                                "kind": Schema.enum(
                                    "Entity kind to return.", ["clips", "transitions", "markers", "tracks", "assets", "history"]),
                                "sequenceId": Schema.string("Sequence (default: the active one)."),
                                "trackId": Schema.string("Only this track."),
                                "trackKind": Schema.enum("Only tracks of this kind.", TrackKind.allCases.map(\.rawValue)),
                                "assetId": Schema.string("Only clips of this asset."),
                                "clipId": Schema.string("Only this clip."),
                                "range": Schema.ref("timeRange", "Only entities overlapping this timeline range."),
                                "textContains": Schema.string("Case-insensitive substring of label, caption text, or name."),
                                "limit": Schema.integer("Maximum results (default 200).", minimum: 1),
                            ], required: ["kind"])
                    ]), required: ["filter"]),
            ["time": OperationSchemas.defs["time"]!, "timeRange": OperationSchemas.defs["timeRange"]!]),
        outputSchema: Schema.object(
            "Query results.",
            properties: [
                "kind": Schema.string("The kind queried."),
                "results": Schema.array("Matching entities.", items: Schema.any("Entity summary.")),
                "count": Schema.integer("Number of results returned."),
                "version": Schema.integer("Project version the results reflect."),
                "sequenceId": Schema.string("Sequence searched (for timeline kinds)."),
            ], required: ["kind", "results", "count", "version"]),
        annotations: .readOnly(title: "Query timeline"),
        examples: [
            .object(["filter": ["kind": "clips", "trackKind": "video"]]),
            .object(["filter": ["kind": "clips", "range": ["start": ["v": 0, "ts": 24000], "end": ["v": 48048, "ts": 24000]]]]),
            .object(["filter": ["kind": "assets", "textContains": "IMG"]]),
            .object(["filter": ["kind": "history", "limit": 10]]),
        ]
    ) { input, context in
        let resolved = try await ToolSupport.resolve(input, context)
        let project = resolved.project
        guard case .object(let filter) = input["filter"] ?? .null else { throw ToolError.invalidInput("filter is required") }
        let kind = filter["kind"]?.stringValue ?? "clips"
        let limit = filter["limit"]?.intValue ?? 200
        let text = filter["textContains"]?.stringValue?.lowercased()
        let range = try filter["range"].map { try $0.decoded(as: TimeRange.self) }
        func matchesText(_ candidates: [String?]) -> Bool {
            guard let text else { return true }
            return candidates.contains { $0?.lowercased().contains(text) ?? false }
        }
        var results: [JSONValue] = []
        var sequenceId: SequenceID?
        switch kind {
        case "assets":
            results = project.assets.values.sorted { $0.id < $1.id }
                .filter { matchesText([$0.displayName, $0.libraryPath]) }
                .filter { asset in filter["assetId"]?.stringValue.map { id in id == asset.id.rawValue } ?? true }
                .map(assetSummary)
        case "history":
            let history = await resolved.store.history()
            results = history.transactions.reversed().map { t in
                .object([
                    "txnId": .string(t.id.rawValue), "label": .string(t.label), "actor": .string(t.actor.description),
                    "kind": .string(t.kind.rawValue), "live": .bool(history.isLive(t.id)),
                    "eventCount": .number(Double(t.events.count)),
                    "changedIds": .array(changedIds(of: t.events).sorted().map { .string($0) }),
                ])
            }
        default:
            let sequence = try ToolSupport.sequence(ToolInput(["sequenceId": filter["sequenceId"] ?? .null]), in: project)
            sequenceId = sequence.id
            let tracks = sequence.tracks.filter { t in
                (filter["trackId"]?.stringValue.map { $0 == t.id.rawValue } ?? true)
                    && (filter["trackKind"]?.stringValue.map { $0 == t.kind.rawValue } ?? true)
            }
            switch kind {
            case "tracks":
                results = tracks.filter { matchesText([$0.name]) }.map { t in
                    .object([
                        "trackId": .string(t.id.rawValue), "kind": .string(t.kind.rawValue), "name": .string(t.name),
                        "muted": .bool(t.muted), "locked": .bool(t.locked), "clipCount": .number(Double(t.clips.count)),
                    ])
                }
            case "clips":
                let wantedAsset = filter["assetId"]?.stringValue
                let wantedClip = filter["clipId"]?.stringValue
                var clips: [Clip] = tracks.flatMap { Array($0.clips.values) }
                clips = clips.filter { clip in wantedAsset == nil || wantedAsset == clip.assetId?.rawValue }
                clips = clips.filter { clip in wantedClip == nil || wantedClip == clip.id.rawValue }
                if let range {
                    clips = clips.filter { clip in ToolSupport.overlaps(ToolSupport.range(of: clip, in: sequence), range) }
                }
                clips = clips.filter { clip in matchesText([clip.label, clip.text]) }
                clips.sort { a, b in a.start == b.start ? a.id.rawValue < b.id.rawValue : a.start < b.start }
                results = clips.map { clipSummary($0, in: sequence) }
            case "transitions":
                let trackIds = Set(tracks.map(\.id))
                results = sequence.transitions.values.filter { trackIds.contains($0.trackId) }
                    .filter { matchesText([$0.kind]) }.sorted { $0.id < $1.id }.map(transitionSummary)
            case "markers":
                results = sequence.markers.values.sorted { $0.at < $1.at }
                    .filter { marker in range.map { r in r.contains(marker.at) } ?? true }.filter { matchesText([$0.label]) }
                    .map { m in
                        .object(["markerId": .string(m.id.rawValue), "at": ToolSupport.timeJSON(m.at), "label": .string(m.label)])
                    }
            default:
                throw ToolError.invalidInput("Unknown filter.kind \(kind)")
            }
        }
        let limited = Array(results.prefix(limit))
        var o: [String: JSONValue] = [
            "kind": .string(kind), "results": .array(limited), "count": .number(Double(limited.count)),
            "version": .number(Double(project.version)), "projectId": .string(project.id.rawValue),
        ]
        if let sequenceId { o["sequenceId"] = .string(sequenceId.rawValue) }
        return ToolOutput(structured: .object(o), text: "\(limited.count) \(kind) (of \(results.count)) at version \(project.version).")
    }
}
