import Contracts
import Foundation
import TimelineCore

/// `timeline_apply`, `timeline_cut`, `transition_add`, `caption_add`, `undo`, `redo`: the write side. Every one goes
/// through `ProjectStore.apply` with the context's actor, an idempotency key, and the caller's
/// `expectedVersion`; a stale version comes back as `{ error: "staleVersion", changedSince }`.
enum ApplyTools {
    static let mutationOutput = Schema.object(
        "Result of a mutation.", properties: ToolSupport.mutationOutputSchema,
        required: ["version", "changedIds", "warnings", "status", "commandId"], additionalProperties: true)

    static let timelineApply = Tool(
        name: "timeline_apply",
        description:
            "Applies one or more timeline operations atomically as a single undo step. ops[] are Command.Operation JSON objects discriminated by `type` (see the schema's $defs/op_*); later ops may reference an id created by an earlier op in the same batch as { \"$ref\": index }. Pass the expectedVersion you read with project_describe: if the project changed since, the call is rejected with error staleVersion and a changedSince diff; re-read, recompute, and retry with a NEW commandId. Retrying the same commandId is safe: it returns the stored result. Times are { v, ts } rationals in the sequence timescale. undo and redo must be the only op in the batch.",
        inputSchema: Schema.withDefs(
            Schema.object(
                "Apply request.",
                properties: ToolSupport.inputProperties(
                    mutating: true,
                    [
                        "ops": Schema.array(
                            "Operations, applied in order inside one transaction.", items: OperationSchemas.operation,
                            minItems: 1)
                    ]), required: ["ops", "expectedVersion"]),
            OperationSchemas.defs),
        outputSchema: mutationOutput,
        annotations: ToolAnnotations(title: "Apply timeline operations", idempotent: true),
        examples: [
            .object([
                "expectedVersion": 12, "commandId": "move-clip-1",
                "ops": [
                    [
                        "type": "moveClip", "clipId": "00000000-0000-7000-8000-00000000001a",
                        "to": ["start": ["v": 48048, "ts": 24000]], "mode": "overwrite",
                    ]
                ],
            ]),
            .object([
                "expectedVersion": 12, "commandId": "split-and-dissolve-1",
                "ops": [
                    [
                        "type": "splitClip", "clipId": "00000000-0000-7000-8000-00000000001a",
                        "at": ["v": 48048, "ts": 24000],
                    ],
                    [
                        "type": "addTransition", "leftClipId": "00000000-0000-7000-8000-00000000001a",
                        "rightClipId": ["$ref": 0], "kind": "dissolve", "duration": ["v": 12012, "ts": 24000],
                    ],
                ],
            ]),
            .object(["expectedVersion": 13, "ops": [["type": "undo"]]]),
        ]
    ) { input, context in
        guard case .array(let rawOps) = input["ops"] ?? .null, !rawOps.isEmpty else {
            throw ToolError.invalidInput("ops must be a non-empty array")
        }
        let ops: [Command.Operation]
        do {
            ops = try JSONValue.array(rawOps).decoded(as: [Command.Operation].self)
        } catch {
            throw ToolError.invalidInput("ops: \(ToolSupport.describe(error))")
        }
        let operation: Command.Operation = ops.count == 1 ? ops[0] : .batch(ops)
        let command = try ToolSupport.command(operation, input: input, context: context, requireExpectedVersion: true)
        let store = try await context.store(for: input)
        return try await ToolSupport.apply(command, to: store, extra: ["opCount": .number(Double(ops.count))])
    }

    static let transitionAdd = Tool(
        name: "transition_add",
        description:
            "Adds a transition (dissolve, wipe, ...) across the cut between two adjacent clips on the same track. Duration can be given in frames of the sequence or as a rational time. If the clips lack source handles the call fails with transitionHandles and the longest duration that fits; retry with that.",
        inputSchema: Schema.withDefs(
            Schema.object(
                "Transition request.",
                properties: ToolSupport.inputProperties(
                    mutating: true,
                    [
                        "leftClipId": Schema.string("The outgoing clip."),
                        "rightClipId": Schema.string("The incoming clip (must start where the left one ends)."),
                        "kind": Schema.string("Transition kind: dissolve (default), wipe, dipToBlack, ..."),
                        "durationFrames": Schema.integer("Duration in sequence frames.", minimum: 1),
                        "duration": Schema.ref("time", "Duration as a rational time (alternative to durationFrames)."),
                        "alignment": Schema.enum(
                            "Where the overlap sits (default centered).", TransitionAlignment.allCases.map(\.rawValue)),
                        "params": Schema.map("Kind-specific parameters.", values: Schema.any("Any JSON value.")),
                        "transitionId": Schema.string("Client-supplied id for the new transition."),
                    ]), required: ["leftClipId", "rightClipId", "expectedVersion"]),
            ["time": OperationSchemas.defs["time"]!]),
        outputSchema: Schema.object(
            "Result with the new transition id.",
            properties: ToolSupport.mutationOutputSchema.merging(
                ["transitionId": Schema.string("Id of the transition added.")]) { a, _ in a },
            required: ["version", "changedIds", "warnings", "status"], additionalProperties: true),
        annotations: ToolAnnotations(title: "Add transition", idempotent: true),
        examples: [
            .object([
                "expectedVersion": 12, "leftClipId": "00000000-0000-7000-8000-00000000001a",
                "rightClipId": "00000000-0000-7000-8000-00000000001e", "kind": "dissolve", "durationFrames": 12,
            ])
        ]
    ) { input, context in
        let resolved = try await ToolSupport.resolve(input, context)
        let left = try ToolSupport.requireString(input, "leftClipId")
        let right = try ToolSupport.requireString(input, "rightClipId")
        let sequence = try ToolSupport.sequence(input, in: resolved.project)
        let duration: RationalTime
        if let frames = input["durationFrames"]?.intValue {
            duration = RationalTime.frames(Int64(frames), of: sequence.frameDuration)
        } else if let t = try ToolSupport.decode(input, "duration", as: RationalTime.self) {
            duration = t
        } else {
            throw ToolError.invalidInput("Give durationFrames or duration")
        }
        let id =
            ToolSupport.string(input, "transitionId").map { TransitionID($0) }
            ?? TransitionID(minting: UUIDv7Generator())
        let op = Command.Operation.addTransition(
            .init(
                id: id, leftClipId: .id(ClipID(left)), rightClipId: .id(ClipID(right)),
                kind: ToolSupport.string(input, "kind") ?? "dissolve", duration: duration,
                alignment: try ToolSupport.decode(input, "alignment", as: TransitionAlignment.self) ?? .centered,
                params: input["params"]?.objectValue ?? [:]))
        let command = try ToolSupport.command(op, input: input, context: context, requireExpectedVersion: true)
        return try await ToolSupport.apply(command, to: resolved.store, extra: ["transitionId": .string(id.rawValue)])
    }

    static let captionAdd = Tool(
        name: "caption_add",
        description:
            "Adds captions to the active sequence in one undo step. source transcript: transcribes the asset behind the video clips (assetId, or every video clip's asset) and places one caption per phrase segment with per-word timings, on trackId or a new caption track. source text: places the given items (start, duration, text) or, with only `text`, spreads its sentences evenly over the sequence. Returns the caption track id and item count.",
        inputSchema: Schema.withDefs(
            Schema.object(
                "Caption request.",
                properties: ToolSupport.inputProperties(
                    mutating: true,
                    [
                        "trackId": Schema.string(
                            "Existing caption track to replace the items of; omit to add a new track."),
                        "source": Schema.enum("Where captions come from.", ["transcript", "text"]),
                        "assetId": Schema.string(
                            "source transcript: the asset to transcribe (default: assets of the video clips)."),
                        "locale": Schema.string("source transcript: BCP-47 locale, default en-US."),
                        "text": Schema.string("source text: caption text, split into sentences."),
                        "items": Schema.array("source text: explicit caption items.", items: Schema.ref("captionItem")),
                        "style": Schema.ref("captionStyle", "Track default style (fontSize, color, position, ...)."),
                        "language": Schema.string("Language tag for a new track (default from the locale, else en)."),
                        "trackName": Schema.string("Name for a new track (default Captions)."),
                        "maxWordsPerCaption": Schema.integer(
                            "source transcript: split long segments (default 6).", minimum: 1),
                    ]), required: ["source", "expectedVersion"]),
            [
                "time": OperationSchemas.defs["time"]!, "captionItem": OperationSchemas.defs["captionItem"]!,
                "captionWord": OperationSchemas.defs["captionWord"]!,
                "captionStyle": OperationSchemas.defs["captionStyle"]!,
            ]),
        outputSchema: Schema.object(
            "Result with the caption track.",
            properties: ToolSupport.mutationOutputSchema.merging([
                "trackId": Schema.string("The caption track."), "itemCount": Schema.integer("Caption items placed."),
                "transcriptCacheKey": Schema.string("Cache key of the transcript used (source transcript)."),
            ]) { a, _ in a }, required: ["version", "changedIds", "warnings", "status", "trackId", "itemCount"],
            additionalProperties: true),
        annotations: ToolAnnotations(title: "Add captions", idempotent: true),
        examples: [
            .object([
                "expectedVersion": 12, "source": "transcript",
                "style": ["fontSize": 64, "position": "center", "extra": [:]],
                "maxWordsPerCaption": 4,
            ]),
            .object([
                "expectedVersion": 12, "source": "text",
                "items": [
                    ["start": ["v": 0, "ts": 24000], "duration": ["v": 48048, "ts": 24000], "text": "Hello there"]
                ],
            ]),
            .object(["expectedVersion": 12, "source": "text", "text": "Welcome back. Today we build a timeline."]),
        ]
    ) { input, context in
        let resolved = try await ToolSupport.resolve(input, context)
        let project = resolved.project
        let sequence = try ToolSupport.sequence(input, in: project)
        let source = try ToolSupport.requireString(input, "source")
        let style = try ToolSupport.decode(input, "style", as: CaptionStyle.self)
        var items: [Command.Operation.CaptionInput] = []
        var extra: [String: JSONValue] = [:]
        var language = ToolSupport.string(input, "language")
        switch source {
        case "text":
            if let explicit = try ToolSupport.decode(input, "items", as: [Command.Operation.CaptionInput].self) {
                items = explicit
            } else if let text = ToolSupport.string(input, "text") {
                let sentences = text.split(whereSeparator: { ".!?".contains($0) }).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                let total = ToolSupport.duration(of: sequence)
                guard !sentences.isEmpty, total.isPositive else {
                    throw ToolError.invalidInput("text is empty or the sequence has no duration")
                }
                let slot = (total / Int64(sentences.count)).floored(to: sequence.frameDuration)
                for (i, sentence) in sentences.enumerated() {
                    items.append(.init(start: slot * Int64(i), duration: slot, text: sentence))
                }
            } else {
                throw ToolError.invalidInput("source text needs items or text")
            }
        case "transcript":
            guard let analyzer = context.services.analyzer else { throw ToolError.serviceUnavailable("analyzer") }
            let locale = Locale(identifier: ToolSupport.string(input, "locale") ?? "en-US")
            let assetIds: [AssetID]
            if let id = ToolSupport.string(input, "assetId") {
                assetIds = [AssetID(id)]
            } else {
                var seen: [AssetID] = []
                for track in sequence.tracks where track.kind == .video {
                    for clip in track.clips.values.sorted(by: { $0.start < $1.start }) {
                        if let a = clip.assetId, project.assets[a]?.hasAudio == true, !seen.contains(a) {
                            seen.append(a)
                        }
                    }
                }
                assetIds = seen
            }
            guard !assetIds.isEmpty else { throw ToolError.invalidInput("No video clip with audio to transcribe") }
            let maxWords = input["maxWordsPerCaption"]?.intValue ?? 6
            var keys: [String] = []
            for assetId in assetIds {
                let asset = try ToolSupport.asset(assetId.rawValue, in: project)
                let transcript = try await analyzer.transcribe(
                    ToolSupport.mediaReference(for: asset, context: context), locale: locale,
                    options: TranscriptionOptions())
                keys.append(transcript.cacheKey)
                if language == nil { language = transcript.language }
                let clips = sequence.tracks.filter { $0.kind == .video }.flatMap { $0.clips.values }.filter {
                    $0.assetId == assetId
                }
                items += captions(from: transcript, clips: clips, in: sequence, maxWords: maxWords)
            }
            extra["transcriptCacheKey"] = .string(keys.joined(separator: ","))
        default:
            throw ToolError.invalidInput("source must be transcript or text")
        }
        items.sort { $0.start < $1.start }
        let trackId: TrackID
        let operation: Command.Operation
        if let existing = ToolSupport.string(input, "trackId") {
            trackId = TrackID(existing)
            var ops: [Command.Operation] = [.replaceCaptions(.init(trackId: .id(trackId), items: items))]
            if let style { ops.append(.setCaptionStyle(.init(trackId: .id(trackId), style: style))) }
            operation = ops.count == 1 ? ops[0] : .batch(ops)
        } else {
            trackId = TrackID(minting: UUIDv7Generator())
            operation = .batch([
                .addCaptionTrack(
                    .init(
                        id: trackId, sequenceId: .id(sequence.id),
                        name: ToolSupport.string(input, "trackName") ?? "Captions",
                        language: language ?? "en", style: style)),
                .replaceCaptions(.init(trackId: .ref(0), items: items)),
            ])
        }
        let command = try ToolSupport.command(operation, input: input, context: context, requireExpectedVersion: true)
        extra["trackId"] = .string(trackId.rawValue)
        extra["itemCount"] = .number(Double(items.count))
        return try await ToolSupport.apply(command, to: resolved.store, extra: extra)
    }

    /// Caption items for the words of `transcript` that fall inside `clips`' source ranges, placed on
    /// the timeline where those clips show them, split into at most `maxWords` words each.
    static func captions(from transcript: Transcript, clips: [Clip], in sequence: Sequence, maxWords: Int)
        -> [Command.Operation.CaptionInput]
    {
        var items: [Command.Operation.CaptionInput] = []
        for clip in clips.sorted(by: { $0.start < $1.start }) {
            let words = transcript.words.filter { $0.t0 >= clip.sourceIn && $0.t0 < clip.sourceOut }
            guard !words.isEmpty else { continue }
            var groups: [[TranscriptWord]] = []
            for segment in transcript.segments {
                let inSegment = words.filter { segment.range.contains($0.t0) }
                if !inSegment.isEmpty { groups.append(inSegment) }
            }
            let grouped = Set(groups.flatMap { $0 })
            let leftovers = words.filter { !grouped.contains($0) }
            if !leftovers.isEmpty { groups.append(leftovers) }
            for group in groups.sorted(by: { ($0.first?.t0 ?? .zero) < ($1.first?.t0 ?? .zero) }) {
                for chunk in stride(from: 0, to: group.count, by: max(1, maxWords)).map({
                    Array(group[$0..<min($0 + maxWords, group.count)])
                }) {
                    guard let first = chunk.first, let last = chunk.last else { continue }
                    let start = (clip.start + ((first.t0 - clip.sourceIn) / clip.speed)).snapped(
                        to: sequence.frameDuration)
                    let end = RationalTime.min(
                        (clip.start + ((last.t1 - clip.sourceIn) / clip.speed)).ceiled(to: sequence.frameDuration),
                        sequence.end(of: clip))
                    let duration = RationalTime.max(end - start, sequence.frameDuration)
                    items.append(
                        .init(
                            start: start, duration: duration, text: chunk.map(\.text).joined(separator: " "),
                            words: chunk.map { CaptionWord(text: $0.text, t0: $0.t0 - first.t0, t1: $0.t1 - first.t0) })
                    )
                }
            }
        }
        return items
    }

    static let timelineCut = Tool(
        name: "timeline_cut",
        description: """
            Cuts (splits) clips at one timeline time, the way the editor's razor does. Give the time and \
            the tool works out which clips to split: by default every clip that the time falls strictly \
            inside, on every unlocked track; narrow it with trackIds or clipIds. Clips whose edge already \
            sits at that time are skipped rather than failing, so the same cut is safe to issue twice. \
            Linked clips split together unless unlinked is true, and a clip whose link group reaches a \
            locked track is skipped instead of failing the whole call. Caption items are cut too, with \
            their words divided at the point. The time is snapped to the sequence frame on video and \
            caption tracks and kept sample-exact on audio, and the response reports where each cut \
            actually landed. Everything is one transaction, so one undo takes it all back. To cut and \
            then remove in a single undo step, use timeline_apply instead: this tool issues its own \
            command and cannot be part of a timeline_apply batch.
            """,
        inputSchema: Schema.withDefs(
            Schema.object(
                "Cut request.",
                properties: ToolSupport.inputProperties(
                    mutating: true,
                    [
                        "sequenceId": Schema.string("Sequence to cut in (default: the active one)."),
                        "at": Schema.ref("time", "Timeline time of the cut (alternative to atFrames)."),
                        "atFrames": Schema.integer(
                            "Timeline time of the cut, in sequence frames (alternative to at).", minimum: 0),
                        "trackIds": Schema.array(
                            "Cut only on these tracks. Mutually exclusive with clipIds; omit both to cut every "
                                + "unlocked track.", items: Schema.string("A track id.")),
                        "clipIds": Schema.array(
                            "Cut only these clips. Mutually exclusive with trackIds.",
                            items: Schema.string("A clip id.")),
                        "unlinked": Schema.bool(
                            "Cut the addressed clips alone, leaving their linked partners whole (default false)."),
                    ]), required: ["expectedVersion"]),
            ["time": OperationSchemas.defs["time"]!]),
        outputSchema: Schema.object(
            "Result with one row per cut made.",
            properties: ToolSupport.mutationOutputSchema.merging([
                "cuts": Schema.array(
                    "The cuts made, in timeline order.",
                    items: Schema.object(
                        "One cut.",
                        properties: [
                            "clipId": Schema.string("The clip that was cut; it keeps the left-hand part."),
                            "newClipId": Schema.string("The right-hand part, which starts at the cut."),
                            "trackId": Schema.string("The track the cut clip is on."),
                            "at": Schema.ref("time", "Where the cut landed, after snapping."),
                        ], required: ["clipId", "newClipId", "trackId", "at"])),
                "cutCount": Schema.integer("How many clips were cut."),
                "skipped": Schema.array(
                    "Clips considered and passed over, with why.",
                    items: Schema.object(
                        "One skipped clip.",
                        properties: [
                            "clipId": Schema.string("The clip."),
                            "trackId": Schema.string("Its track."),
                            "reason": Schema.enum(
                                "Why it was not cut: the time is on its edge or outside it, its link group "
                                    + "reaches a locked track, or another member of its group is being cut instead.",
                                ["notInside", "lockedPartner", "linkedDuplicate"]),
                        ], required: ["clipId", "trackId", "reason"])),
            ]) { a, _ in a },
            required: ["version", "changedIds", "warnings", "status", "cuts", "cutCount"],
            additionalProperties: true),
        annotations: ToolAnnotations(title: "Cut clips at a time", idempotent: true),
        examples: [
            .object(["expectedVersion": 12, "atFrames": 96, "commandId": "cut-at-96"]),
            .object([
                "expectedVersion": 12, "at": .object(["v": 96096, "ts": 24000]),
                "clipIds": .array([.string("00000000-0000-7000-8000-00000000001a")]), "unlinked": true,
            ]),
        ]
    ) { input, context in
        let resolved = try await ToolSupport.resolve(input, context)
        let sequence = try ToolSupport.sequence(input, in: resolved.project)
        let unlinked = input["unlinked"]?.boolValue ?? false

        let at: RationalTime
        switch (input["atFrames"]?.intValue, try ToolSupport.decode(input, "at", as: RationalTime.self)) {
        case (let frames?, nil): at = RationalTime.frames(Int64(frames), of: sequence.frameDuration)
        case (nil, let time?): at = time
        case (nil, nil): throw ToolError.invalidInput("Give at or atFrames")
        default: throw ToolError.invalidInput("Give at or atFrames, not both")
        }

        let trackIds = input["trackIds"]?.arrayValue?.compactMap(\.stringValue)
        let clipIds = input["clipIds"]?.arrayValue?.compactMap(\.stringValue)
        if trackIds != nil && clipIds != nil {
            throw ToolError.invalidInput("Give trackIds or clipIds, not both")
        }

        let plan = CutPlan(in: sequence, at: at, trackIds: trackIds, clipIds: clipIds, unlinked: unlinked)
        let extra: [String: JSONValue] = [
            "cuts": .array(plan.cuts.map(\.json)), "cutCount": .number(Double(plan.cuts.count)),
            "skipped": .array(plan.skipped.map(\.json)),
        ]
        let ops = plan.cuts.map { cut in
            Command.Operation.splitClip(
                .init(clipId: .id(cut.clipId), at: cut.at, newIds: [cut.newClipId], unlinked: unlinked))
        }
        // An empty plan still goes to the store as an empty batch, which decides to nothing and comes back
        // `noop`. Short-circuiting here would look tidier and would quietly skip the `expectedVersion`
        // check and the `commandId` replay, so a stale caller would be told "nothing to cut" instead of
        // what changed underneath them.
        let command = try ToolSupport.command(
            ops.count == 1 ? ops[0] : .batch(ops), input: input, context: context, requireExpectedVersion: true)
        var out = try await ToolSupport.apply(command, to: resolved.store, extra: extra)
        if plan.cuts.isEmpty, !out.isError {
            out.text = "Nothing to cut at \(ToolSupport.seconds(at)) s: no clip has that time strictly inside it."
        }
        return out
    }

    static let undo = Tool(
        name: "undo",
        description:
            "Undoes the latest live transaction (or txnId). Undo is linear across the human and the agent: check history with project_describe before undoing something you did not do.",
        inputSchema: Schema.object(
            "Undo request.",
            properties: ToolSupport.inputProperties(
                mutating: true, ["txnId": Schema.string("Transaction to undo (default: latest live).")])),
        outputSchema: mutationOutput, annotations: ToolAnnotations(title: "Undo", destructive: true, idempotent: true),
        examples: [.object([:]), .object(["expectedVersion": 12, "txnId": "00000000-0000-7000-8000-000000000020"])]
    ) { input, context in
        let op = Command.Operation.undo(.init(txnId: ToolSupport.string(input, "txnId").map { TransactionID($0) }))
        let command = try ToolSupport.command(op, input: input, context: context)
        return try await ToolSupport.apply(command, to: try await context.store(for: input))
    }

    static let redo = Tool(
        name: "redo",
        description: "Redoes the latest undone transaction that has not been orphaned by a newer edit.",
        inputSchema: Schema.object("Redo request.", properties: ToolSupport.inputProperties(mutating: true, [:])),
        outputSchema: mutationOutput, annotations: ToolAnnotations(title: "Redo", idempotent: true),
        examples: [.object([:]), .object(["expectedVersion": 13])]
    ) { input, context in
        let command = try ToolSupport.command(.redo, input: input, context: context)
        return try await ToolSupport.apply(command, to: try await context.store(for: input))
    }
}

/// Which clips a cut at one time would split, and which it passes over. The same three rules the
/// editor's razor applies, in one place: `decide` snaps the point to the sequence frame on video and
/// caption tracks *before* it validates and then throws if the result is not strictly inside the clip,
/// and a batch has no per-operation recovery — so one clip resolved wrong takes every other cut in the
/// call down with it.
struct CutPlan {
    struct Cut {
        var clipId: ClipID
        var newClipId: ClipID
        var trackId: TrackID
        /// Where the cut lands after snapping, which is not always where it was asked for.
        var at: RationalTime

        var json: JSONValue {
            .object([
                "clipId": .string(clipId.rawValue), "newClipId": .string(newClipId.rawValue),
                "trackId": .string(trackId.rawValue), "at": ToolSupport.timeJSON(at),
            ])
        }
    }

    struct Skip {
        enum Reason: String {
            /// The snapped point sits on the clip's edge or outside it entirely.
            case notInside
            /// Its link group reaches a locked track, which would reject the whole command.
            case lockedPartner
            /// Another member of its link group is being cut, which takes this one with it.
            case linkedDuplicate
        }

        var clipId: ClipID
        var trackId: TrackID
        var reason: Reason

        var json: JSONValue {
            .object([
                "clipId": .string(clipId.rawValue), "trackId": .string(trackId.rawValue),
                "reason": .string(reason.rawValue),
            ])
        }
    }

    var cuts: [Cut] = []
    var skipped: [Skip] = []

    init(
        in sequence: Sequence, at: RationalTime, trackIds: [String]?, clipIds: [String]?, unlinked: Bool,
        ids: any IDGenerator = UUIDv7Generator()
    ) {
        let wantedTracks = trackIds.map { Set($0.map { TrackID($0) }) }
        let wantedClips = clipIds.map { Set($0.map { ClipID($0) }) }
        var candidates: [(clip: Clip, track: Track)] = []
        for track in sequence.tracks where !track.locked {
            if let wantedTracks, !wantedTracks.contains(track.id) { continue }
            for clip in track.clips.values {
                if let wantedClips, !wantedClips.contains(clip.id) { continue }
                candidates.append((clip, track))
            }
        }
        candidates.sort { ($0.clip.start, $0.clip.id) < ($1.clip.start, $1.clip.id) }

        var seenGroups: Set<LinkGroupID> = []
        for (clip, track) in candidates {
            // `decide` snaps first and validates second, so this is the point it will actually test.
            let t = track.kind.isFrameAligned ? at.snapped(to: sequence.frameDuration) : at
            guard clip.start < t, t < sequence.end(of: clip) else {
                skipped.append(Skip(clipId: clip.id, trackId: track.id, reason: .notInside))
                continue
            }
            if !unlinked, let group = clip.linkGroupId {
                let members = sequence.members(of: group)
                if members.contains(where: { sequence.track($0.trackId)?.locked == true }) {
                    skipped.append(Skip(clipId: clip.id, trackId: track.id, reason: .lockedPartner))
                    continue
                }
                if seenGroups.contains(group) {
                    skipped.append(Skip(clipId: clip.id, trackId: track.id, reason: .linkedDuplicate))
                    continue
                }
                seenGroups.insert(group)
            }
            // One id, for the addressed clip's own right-hand part. `decide` mints the rest positionally
            // for the other group members, in an order this side must not try to predict.
            cuts.append(Cut(clipId: clip.id, newClipId: ClipID(minting: ids), trackId: track.id, at: t))
        }
    }
}
