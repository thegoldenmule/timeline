import Foundation
import TimelineCore

/// Hand-maintained JSON Schema for every `Command.Operation` (timeline-model.md section 5), the
/// `ops[]` items of `timeline_apply`. Shapes mirror the Codable encoding exactly: `{ "type": <name>,
/// ...fields }`, `RationalTime` as `{ "v", "ts" }`, ids as strings or `{ "$ref": n }` back-references
/// to an earlier operation of the same batch. A contract test checks every fixture operation from
/// `ProjectFixtures.exampleOperations()` against these.
public enum OperationSchemas {
    /// Shared definitions, referenced as `#/$defs/<name>`.
    public static let defs: [String: JSONValue] = [
        "time": Schema.object(
            "A rational time: value / timescale seconds. Sequence times use the sequence frame duration's timescale (24000 for 23.976 fps), audio uses the sample rate.",
            properties: [
                "v": Schema.integer("Numerator (ticks)."),
                "ts": Schema.integer("Timescale (ticks per second), positive.", minimum: 1),
            ], required: ["v", "ts"]),
        "rational": Schema.object(
            "An exact ratio.",
            properties: [
                "num": Schema.integer("Numerator."), "den": Schema.integer("Denominator, positive.", minimum: 1),
            ],
            required: ["num", "den"]),
        "id": Schema.string("An entity id (UUIDv7 string as returned by project_describe)."),
        "idOrRef": Schema.oneOf(
            "An entity id, or { \"$ref\": n } for the primary id created by operation n (0-based) earlier in the same batch.",
            [
                Schema.string("An existing entity id."),
                Schema.object(
                    "Back-reference to an id created earlier in this batch.",
                    properties: ["$ref": Schema.integer("0-based index of the creating operation.", minimum: 0)],
                    required: ["$ref"]),
            ]),
        "timeRange": Schema.object(
            "A half-open time range [start, end).",
            properties: [
                "start": Schema.ref("time", "Range start."), "end": Schema.ref("time", "Range end (exclusive)."),
            ],
            required: ["start", "end"]),
        "editMode": Schema.enum(
            "ripple shifts later clips to keep the timeline contiguous; overwrite leaves them in place.",
            ["ripple", "overwrite"]),
        "rippleScope": Schema.enum(
            "Which tracks a ripple shifts: the whole sequence (default) or only the edited track.",
            ["sequence", "track"]),
        "easing": Schema.enum("Interpolation from this keyframe to the next.", Easing.allCases.map(\.rawValue)),
        "animatableNumber": animatable(
            "A number that is constant or keyframed.", value: Schema.number("The value.")),
        "animatableTransform": animatable(
            "A transform that is constant or keyframed.", value: Schema.ref("transform", "The transform.")),
        "animatableAny": animatable(
            "An effect parameter that is constant or keyframed; values are effect-specific JSON.",
            value: Schema.any("Effect-specific value.")),
        "transform": Schema.object(
            "Position, scale and rotation of a clip in the sequence frame. Every field is required.",
            properties: [
                "x": Schema.number("Horizontal offset in pixels of the sequence frame."),
                "y": Schema.number("Vertical offset in pixels of the sequence frame."),
                "scale": Schema.number("Uniform scale, 1 is native size."),
                "rotation": Schema.number("Degrees clockwise."),
                "anchorX": Schema.number("Anchor in unit coordinates of the clip frame, 0.5 is the centre."),
                "anchorY": Schema.number("Anchor in unit coordinates of the clip frame, 0.5 is the centre."),
            ], required: ["x", "y", "scale", "rotation", "anchorX", "anchorY"]),
        "clipAudio": Schema.object(
            "Per-clip audio settings. Every field is required.",
            properties: [
                "gain": Schema.ref("animatableNumber", "Linear gain, 1 is unity."),
                "muted": Schema.bool("Mute the clip's audio."),
                "pitchCorrected": Schema.bool("Keep pitch when speed changes."),
            ], required: ["gain", "muted", "pitchCorrected"]),
        "captionWord": Schema.object(
            "One word with source-relative times.",
            properties: [
                "text": Schema.string("The word."),
                "t0": Schema.ref("time", "Word start, relative to the caption item's source domain."),
                "t1": Schema.ref("time", "Word end."),
            ], required: ["text", "t0", "t1"]),
        "captionStyle": Schema.object(
            "Caption styling. `extra` is required (use {} when empty).",
            properties: [
                "fontFamily": Schema.string("Font family name."),
                "fontSize": Schema.number("Font size in sequence pixels."),
                "color": Schema.string("Text colour, #rrggbb."),
                "backgroundColor": Schema.string("Background colour, #rrggbb or #rrggbbaa."),
                "position": Schema.string("Placement: bottom, center, top."),
                "extra": Schema.map("Renderer-specific extras.", values: Schema.any("Any JSON value.")),
            ], required: ["extra"]),
        "captionItem": Schema.object(
            "A caption item to place on a caption track.",
            properties: [
                "id": Schema.ref("id", "Client-supplied id for the new item (optional)."),
                "start": Schema.ref("time", "Timeline start."),
                "duration": Schema.ref("time", "Timeline duration."),
                "text": Schema.string("Caption text."),
                "words": Schema.array("Word timings (optional).", items: Schema.ref("captionWord")),
                "style": Schema.ref("captionStyle", "Item style override (optional)."),
            ], required: ["start", "duration", "text"]),
        "probe": Schema.object(
            "What the importer learned about a file. `extra` is required (use {} when empty).",
            properties: [
                "codec": Schema.string("FourCC or codec name, e.g. hvc1."),
                "width": Schema.integer("Pixel width."),
                "height": Schema.integer("Pixel height."),
                "fps": Schema.ref("rational", "Nominal frame rate."),
                "colorPrimaries": Schema.string("Colour primaries, e.g. bt2020."),
                "transfer": Schema.string("Transfer function, e.g. arib-std-b67 (HLG)."),
                "rotation": Schema.integer("Display rotation in degrees."),
                "capturedAt": Schema.string("ISO-8601 capture date."),
                "extra": Schema.map("QuickTime metadata and other extras.", values: Schema.any("Any JSON value.")),
            ], required: ["extra"]),
        "assetAnalysis": Schema.object(
            "A recorded derived artifact.",
            properties: [
                "kind": Schema.string("Analysis kind, e.g. transcript."),
                "cacheKey": Schema.string("<contentHash>/<kind>/<paramsHash>."),
                "summary": Schema.any("Small summary of the artifact."),
            ], required: ["kind", "cacheKey"]),
        "asset": Schema.object(
            "A full asset snapshot (as returned by project_describe level full).",
            properties: [
                "id": Schema.ref("id", "Asset id."),
                "contentHash": Schema.string("sha256-<hex>."),
                "libraryPath": Schema.string("Path relative to the library, or absolute for referenced files."),
                "displayName": Schema.string("File name shown in the UI."),
                "kind": Schema.enum("Media kind.", AssetKind.allCases.map(\.rawValue)),
                "duration": Schema.ref("time", "Media duration."),
                "hasVideo": Schema.bool("Has a video track."),
                "hasAudio": Schema.bool("Has an audio track."),
                "sampleRate": Schema.integer("Audio sample rate."),
                "frameDuration": Schema.ref("time", "Video frame duration."),
                "probe": Schema.ref("probe", "Probe data."),
                "offline": Schema.bool("True when the file is missing."),
                "analyses": Schema.map("Recorded analyses keyed by kind.", values: Schema.ref("assetAnalysis")),
            ],
            required: [
                "id", "contentHash", "libraryPath", "displayName", "kind", "duration", "hasVideo", "hasAudio",
                "probe", "offline", "analyses",
            ]),
        "alignmentParameters": alignmentParameters,
        "projectSettings": Schema.object(
            "Project-wide settings. Every field is required; read them first with project_describe.",
            properties: [
                "sampleRate": Schema.integer("Audio sample rate."),
                "colorSpace": Schema.string("Working colour space, e.g. rec709."),
                "blendSpace": Schema.enum("Dissolve blend space.", BlendSpace.allCases.map(\.rawValue)),
                "alignment": Schema.ref("alignmentParameters", "Audio alignment tunables."),
            ], required: ["sampleRate", "colorSpace", "blendSpace", "alignment"]),
        "sequenceSpec": Schema.object(
            "A new sequence.",
            properties: [
                "id": Schema.ref("id", "Client-supplied id (optional)."),
                "name": Schema.string("Sequence name."),
                "frameDuration": Schema.ref("time", "Frame duration, e.g. {v:1001, ts:24000}."),
                "width": Schema.integer("Frame width in pixels.", minimum: 1),
                "height": Schema.integer("Frame height in pixels.", minimum: 1),
            ], required: ["name", "frameDuration", "width", "height"]),
        "sequenceSettings": Schema.object(
            "Sequence settings a command can change. Every field is required.",
            properties: [
                "name": Schema.string("Sequence name."),
                "frameDuration": Schema.ref("time", "Frame duration."),
                "width": Schema.integer("Frame width in pixels.", minimum: 1),
                "height": Schema.integer("Frame height in pixels.", minimum: 1),
            ], required: ["name", "frameDuration", "width", "height"]),
        "operation": Schema.oneOf(
            "One timeline operation, discriminated by `type`.",
            Command.Operation.allTypeNames.map { Schema.ref("op_\($0)") }),
    ].merging(operationDefs) { a, _ in a }

    /// The schema for one operation type (`#/$defs/op_<type>`), or nil for an unknown type.
    public static func schema(forType type: String) -> JSONValue? { operationDefs["op_\(type)"] }

    /// The `#/$defs/operation` union.
    public static var operation: JSONValue { Schema.ref("operation") }

    // MARK: Per-operation schemas

    static let operationDefs: [String: JSONValue] = {
        var d: [String: JSONValue] = [:]
        func op(_ type: String, _ description: String, _ properties: [String: JSONValue], required: [String]) {
            var props = properties
            props["type"] = Schema.const(type, "Operation type.")
            d["op_\(type)"] = Schema.object(description, properties: props, required: ["type"] + required)
        }
        let mode = Schema.ref("editMode", "Edit mode.")
        let scope = Schema.ref("rippleScope", "Ripple scope.")
        let unlinked = Schema.bool("Edit only this clip, not its link-group partners (default false).")

        op(
            "createProject", "Creates the project; only valid as the very first command.",
            [
                "id": Schema.ref("id", "Client-supplied project id (optional)."),
                "name": Schema.string("Project name."),
                "settings": Schema.ref("projectSettings", "Initial settings (optional)."),
                "sequence": Schema.ref("sequenceSpec", "The first sequence."),
            ], required: ["name", "sequence"])
        op(
            "setProjectSettings", "Replaces the project settings.",
            ["after": Schema.ref("projectSettings", "The new settings, complete.")], required: ["after"])
        op("renameProject", "Renames the project.", ["name": Schema.string("New name.")], required: ["name"])
        op(
            "addSequence", "Adds a sequence.",
            [
                "id": Schema.ref("id", "Client-supplied id (optional)."),
                "name": Schema.string("Sequence name."),
                "frameDuration": Schema.ref("time", "Frame duration."),
                "width": Schema.integer("Frame width.", minimum: 1),
                "height": Schema.integer("Frame height.", minimum: 1),
            ], required: ["name", "frameDuration", "width", "height"])
        op(
            "setSequenceSettings", "Changes a sequence's name, frame duration or size.",
            [
                "sequenceId": Schema.ref("idOrRef", "Sequence."),
                "after": Schema.ref("sequenceSettings", "New settings, complete."),
            ], required: ["sequenceId", "after"])
        op(
            "setActiveSequence", "Makes a sequence the active one.",
            ["sequenceId": Schema.ref("idOrRef", "Sequence.")], required: ["sequenceId"])
        op(
            "importAsset",
            "Records an asset that MediaKit already copied and hashed. Prefer the media_import tool, which does both.",
            [
                "id": Schema.ref("id", "Client-supplied asset id (optional)."),
                "contentHash": Schema.string("sha256-<hex> of the file."),
                "libraryPath": Schema.string("Path relative to the library, or absolute."),
                "displayName": Schema.string("File name."),
                "kind": Schema.enum("Media kind.", AssetKind.allCases.map(\.rawValue)),
                "duration": Schema.ref("time", "Media duration."),
                "hasVideo": Schema.bool("Has video."),
                "hasAudio": Schema.bool("Has audio."),
                "sampleRate": Schema.integer("Audio sample rate (optional)."),
                "frameDuration": Schema.ref("time", "Video frame duration (optional)."),
                "probe": Schema.ref("probe", "Probe data."),
            ], required: ["contentHash", "libraryPath", "displayName", "kind", "duration", "hasVideo", "hasAudio"])
        op(
            "relinkAsset", "Points an asset at a new file location.",
            [
                "assetId": Schema.ref("idOrRef", "Asset."),
                "libraryPath": Schema.string("New path."),
                "offline": Schema.bool("Mark offline (default false)."),
            ], required: ["assetId", "libraryPath"])
        op(
            "removeAsset", "Removes an unused asset from the project.", ["assetId": Schema.ref("idOrRef", "Asset.")],
            required: ["assetId"])
        op(
            "restoreAsset", "Re-inserts a removed asset from a snapshot.",
            ["asset": Schema.ref("asset", "The asset snapshot.")], required: ["asset"])
        op(
            "recordAssetAnalysis", "Records a derived artifact on an asset.",
            [
                "assetId": Schema.ref("idOrRef", "Asset."),
                "kind": Schema.string("Analysis kind, e.g. transcript."),
                "cacheKey": Schema.string("Cache key."),
                "summary": Schema.any("Small summary (optional)."),
            ], required: ["assetId", "kind", "cacheKey"])
        op(
            "addTrack", "Adds a video or audio track.",
            [
                "id": Schema.ref("id", "Client-supplied id (optional)."),
                "sequenceId": Schema.ref("idOrRef", "Sequence."),
                "kind": Schema.enum("Track kind.", TrackKind.allCases.map(\.rawValue)),
                "name": Schema.string("Track name (optional)."),
                "position": Schema.integer("Index in the track list; default is the end.", minimum: 0),
            ], required: ["sequenceId", "kind"])
        op(
            "removeTrack", "Removes a track and its clips.", ["trackId": Schema.ref("idOrRef", "Track.")],
            required: ["trackId"])
        op(
            "reorderTrack", "Moves a track to another index.",
            [
                "trackId": Schema.ref("idOrRef", "Track."), "position": Schema.integer("New index.", minimum: 0),
            ], required: ["trackId", "position"])
        op(
            "renameTrack", "Renames a track.",
            ["trackId": Schema.ref("idOrRef", "Track."), "name": Schema.string("New name.")],
            required: ["trackId", "name"])
        op(
            "setTrackMuted", "Mutes or unmutes a track.",
            ["trackId": Schema.ref("idOrRef", "Track."), "muted": Schema.bool("Muted.")],
            required: ["trackId", "muted"])
        op(
            "setTrackLocked", "Locks or unlocks a track; edits on a locked track are rejected.",
            ["trackId": Schema.ref("idOrRef", "Track."), "locked": Schema.bool("Locked.")],
            required: ["trackId", "locked"])
        op(
            "addClip",
            "Places a clip from an asset on a track. With link auto (default) a video+audio asset also creates the linked partner clip on the matching track.",
            [
                "id": Schema.ref("id", "Client-supplied clip id (optional)."),
                "sequenceId": Schema.ref("idOrRef", "Sequence."),
                "trackId": Schema.ref("idOrRef", "Target track."),
                "assetId": Schema.ref("idOrRef", "Asset (omit for generated clips)."),
                "at": Schema.ref("time", "Timeline position."),
                "sourceIn": Schema.ref("time", "Source in point."),
                "sourceOut": Schema.ref("time", "Source out point (exclusive)."),
                "mode": mode, "rippleScope": scope,
                "link": Schema.enum("auto creates linked partner clips; none adds only this clip.", ["auto", "none"]),
                "linkedId": Schema.ref("id", "Client id for the partner clip link auto creates (optional)."),
                "label": Schema.string("Clip label (optional)."),
            ], required: ["sequenceId", "trackId", "at", "sourceIn", "sourceOut"])
        op(
            "moveClip", "Moves a clip (and its link group) to a new start and optionally another track.",
            [
                "clipId": Schema.ref("idOrRef", "Clip."),
                "to": Schema.object(
                    "Destination.",
                    properties: [
                        "trackId": Schema.ref("idOrRef", "Destination track (optional; default same track)."),
                        "start": Schema.ref("time", "New timeline start."),
                    ], required: ["start"]),
                "mode": mode, "rippleScope": scope, "unlinked": unlinked,
            ], required: ["clipId", "to"])
        op(
            "trimClip", "Moves one edge of a clip to a new timeline position.",
            [
                "clipId": Schema.ref("idOrRef", "Clip."),
                "edge": Schema.enum("Which edge.", Edge.allCases.map(\.rawValue)),
                "to": Schema.ref("time", "New timeline position of the edge."),
                "mode": mode, "rippleScope": scope, "unlinked": unlinked,
            ], required: ["clipId", "edge", "to"])
        op(
            "splitClip",
            "Cuts a clip at a timeline time. The right-hand part gets a new id (the primary id for $ref); linked partners split too.",
            [
                "clipId": Schema.ref("idOrRef", "Clip."),
                "at": Schema.ref("time", "Timeline time of the cut."),
                "newIds": Schema.array(
                    "Client ids for the new right-hand clips: the addressed clip's first, then link-group members in track order (optional).",
                    items: Schema.ref("id")),
                "unlinked": unlinked,
            ], required: ["clipId", "at"])
        op(
            "joinClips", "Re-joins two adjacent clips from the same asset with contiguous source.",
            [
                "leftClipId": Schema.ref("idOrRef", "Left clip (kept)."),
                "rightClipId": Schema.ref("idOrRef", "Right clip (removed)."),
            ], required: ["leftClipId", "rightClipId"])
        op(
            "removeClip", "Removes a clip (and its link group).",
            [
                "clipId": Schema.ref("idOrRef", "Clip."), "mode": mode, "rippleScope": scope, "unlinked": unlinked,
            ], required: ["clipId"])
        op(
            "setClipSpeed", "Changes playback speed; duration changes accordingly.",
            [
                "clipId": Schema.ref("idOrRef", "Clip."),
                "after": Schema.ref("rational", "Speed ratio, {num:2,den:1} is 2x."),
                "mode": mode, "rippleScope": scope,
            ], required: ["clipId", "after"])
        op(
            "setClipTransform", "Sets a clip's transform.",
            [
                "clipId": Schema.ref("idOrRef", "Clip."),
                "after": Schema.ref("animatableTransform", "New transform."),
            ], required: ["clipId", "after"])
        op(
            "setClipOpacity", "Sets a clip's opacity.",
            [
                "clipId": Schema.ref("idOrRef", "Clip."),
                "after": Schema.ref("animatableNumber", "Opacity 0...1."),
            ], required: ["clipId", "after"])
        op(
            "setClipAudio", "Sets a clip's gain, mute and pitch correction.",
            ["clipId": Schema.ref("idOrRef", "Clip."), "after": Schema.ref("clipAudio", "New audio settings.")],
            required: ["clipId", "after"])
        op(
            "addEffect", "Adds an effect to a clip.",
            [
                "clipId": Schema.ref("idOrRef", "Clip."),
                "effectId": Schema.ref("id", "Client-supplied effect id (optional)."),
                "kind": Schema.string("Effect kind, e.g. blur."),
                "params": Schema.map("Parameters keyed by name.", values: Schema.ref("animatableAny")),
                "index": Schema.integer("Position in the clip's effect list; default is the end.", minimum: 0),
            ], required: ["clipId", "kind"])
        op(
            "updateEffect", "Changes an effect's kind, enabled flag or parameters.",
            [
                "clipId": Schema.ref("idOrRef", "Clip."),
                "effectId": Schema.ref("idOrRef", "Effect."),
                "kind": Schema.string("New kind (optional)."),
                "enabled": Schema.bool("Enable or disable (optional)."),
                "params": Schema.map("Replaces the whole parameter set (optional).", values: Schema.ref("animatableAny")),
            ], required: ["clipId", "effectId"])
        op(
            "removeEffect", "Removes an effect.",
            ["clipId": Schema.ref("idOrRef", "Clip."), "effectId": Schema.ref("idOrRef", "Effect.")],
            required: ["clipId", "effectId"])
        op(
            "addTransition",
            "Adds a transition across the cut between two adjacent clips on one track. Rejected with transitionHandles(maxDuration) when the clips lack source handles.",
            [
                "id": Schema.ref("id", "Client-supplied id (optional)."),
                "leftClipId": Schema.ref("idOrRef", "Outgoing clip."),
                "rightClipId": Schema.ref("idOrRef", "Incoming clip."),
                "kind": Schema.string("Transition kind, e.g. dissolve, wipe."),
                "duration": Schema.ref("time", "Transition duration."),
                "alignment": Schema.enum("Where the overlap sits relative to the cut.", TransitionAlignment.allCases.map(\.rawValue)),
                "params": Schema.map("Kind-specific parameters.", values: Schema.any("Any JSON value.")),
            ], required: ["leftClipId", "rightClipId", "kind", "duration"])
        op(
            "updateTransition", "Changes a transition.",
            [
                "transitionId": Schema.ref("idOrRef", "Transition."),
                "kind": Schema.string("New kind (optional)."),
                "duration": Schema.ref("time", "New duration (optional)."),
                "alignment": Schema.enum("New alignment (optional).", TransitionAlignment.allCases.map(\.rawValue)),
                "params": Schema.map("New parameters (optional).", values: Schema.any("Any JSON value.")),
            ], required: ["transitionId"])
        op(
            "removeTransition", "Removes a transition.", ["transitionId": Schema.ref("idOrRef", "Transition.")],
            required: ["transitionId"])
        op(
            "linkClips", "Puts clips in one link group so they move and trim together.",
            [
                "clipIds": Schema.array("Clips to link.", items: Schema.ref("idOrRef"), minItems: 2),
                "linkGroupId": Schema.ref("id", "Group to join (optional)."),
            ], required: ["clipIds"])
        op(
            "unlinkClips", "Removes clips from their link groups.",
            ["clipIds": Schema.array("Clips to unlink.", items: Schema.ref("idOrRef"), minItems: 1)],
            required: ["clipIds"])
        op(
            "addCaptionTrack", "Adds a caption track.",
            [
                "id": Schema.ref("id", "Client-supplied id (optional)."),
                "sequenceId": Schema.ref("idOrRef", "Sequence."),
                "name": Schema.string("Track name (optional)."),
                "language": Schema.string("BCP-47 language tag, e.g. en."),
                "style": Schema.ref("captionStyle", "Default style (optional)."),
            ], required: ["sequenceId", "language"])
        op(
            "replaceCaptions", "Replaces every caption item on a caption track in one step.",
            [
                "trackId": Schema.ref("idOrRef", "Caption track."),
                "items": Schema.array("The new items.", items: Schema.ref("captionItem")),
            ], required: ["trackId", "items"])
        op(
            "editCaption", "Changes a caption item's text or words.",
            [
                "clipId": Schema.ref("idOrRef", "Caption item."),
                "text": Schema.string("New text (optional)."),
                "words": Schema.array("New word timings (optional).", items: Schema.ref("captionWord")),
            ], required: ["clipId"])
        op(
            "setCaptionStyle", "Sets a track's default style or one item's override. Give exactly one of trackId or clipId.",
            [
                "trackId": Schema.ref("idOrRef", "Caption track (optional)."),
                "clipId": Schema.ref("idOrRef", "Caption item (optional)."),
                "style": Schema.ref("captionStyle", "The style; omit to clear an item override."),
            ], required: [])
        op(
            "addMarker", "Adds a marker.",
            [
                "id": Schema.ref("id", "Client-supplied id (optional)."),
                "sequenceId": Schema.ref("idOrRef", "Sequence."),
                "at": Schema.ref("time", "Timeline position."),
                "label": Schema.string("Label."),
                "colour": Schema.string("Colour name (optional)."),
            ], required: ["sequenceId", "at", "label"])
        op(
            "moveMarker", "Moves a marker.",
            ["markerId": Schema.ref("idOrRef", "Marker."), "to": Schema.ref("time", "New position.")],
            required: ["markerId", "to"])
        op("removeMarker", "Removes a marker.", ["markerId": Schema.ref("idOrRef", "Marker.")], required: ["markerId"])
        op(
            "undo", "Undoes a transaction (default: the latest live one). Not allowed inside a batch with other ops.",
            ["txnId": Schema.ref("id", "Transaction to undo (optional).")], required: [])
        op("redo", "Redoes the latest undone transaction. Not allowed inside a batch with other ops.", [:], required: [])
        op(
            "batch", "A nested batch; timeline_apply already batches ops[], so this is rarely needed.",
            ["operations": Schema.array("Operations, applied in order.", items: Schema.ref("operation"))],
            required: ["operations"])
        return d
    }()

    static func animatable(_ description: String, value: JSONValue) -> JSONValue {
        Schema.oneOf(
            description,
            [
                Schema.object(
                    "A constant value.", properties: ["constant": value], required: ["constant"]),
                Schema.object(
                    "Keyframes relative to the clip start.",
                    properties: [
                        "keyframes": Schema.array(
                            "Keyframes in time order.",
                            items: Schema.object(
                                "One keyframe.",
                                properties: [
                                    "t": Schema.ref("time", "Time relative to the clip start."),
                                    "value": value,
                                    "easing": Schema.ref("easing", "Easing to the next keyframe."),
                                ], required: ["t", "value", "easing"]))
                    ], required: ["keyframes"]),
            ])
    }

    static let alignmentParameters: JSONValue = {
        let fields: [(String, String, Bool)] = [
            ("bandpassLowHz", "Bandpass low edge before onset detection, Hz.", false),
            ("bandpassHighHz", "Bandpass high edge, Hz.", false),
            ("envelopeSampleRate", "Sample rate of the decimated copy the coarse pass uses.", true),
            ("envelopeWindow", "STFT window in samples at envelopeSampleRate.", true),
            ("envelopeHop", "STFT hop in samples.", true),
            ("envelopeBands", "Log-spaced onset bands between the bandpass edges.", true),
            ("envelopeMedianSeconds", "Running-median length for detrending, seconds.", false),
            ("energyFloorFraction", "Energy floor as a fraction of mean overlap power.", false),
            ("minimumOverlapFraction", "Minimum overlap as a fraction of the shorter signal.", false),
            ("minimumOverlapSeconds", "Minimum overlap in seconds.", false),
            ("candidateCutoffRatio", "Coarse candidate cutoff as a fraction of the best peak.", false),
            ("maxCandidates", "Maximum coarse candidates carried into the fine pass.", true),
            ("secondPeakExclusionSeconds", "Minimum distance of the second peak from the best, seconds.", false),
            ("fineWindowSeconds", "GCC-PHAT window length, seconds.", false),
            ("fineWindowCount", "Number of fine windows.", true),
            ("fineSearchRadiusMs", "Fine search radius around the coarse lag, ms.", false),
            ("phatRho", "GCC-PHAT weighting exponent.", false),
            ("phatEpsilon", "GCC-PHAT epsilon relative to max |G|.", false),
            ("phatBandLowHz", "GCC-PHAT spectral mask low edge, Hz.", false),
            ("phatBandHighHz", "GCC-PHAT spectral mask high edge, Hz.", false),
            ("inlierToleranceMs", "Inlier tolerance against the drift fit, ms.", false),
            ("minimumInlierFraction", "Minimum inlier fraction for verification.", false),
            ("maxFitMADMs", "Maximum fit median absolute deviation, ms.", false),
            ("driftFloorPpm", "Drift below this magnitude is reported as zero, ppm.", false),
            ("maxDriftPpm", "Drift beyond this magnitude is rejected, ppm.", false),
            ("minConfidence", "Results under this confidence are reported as no alignment.", false),
        ]
        var props: [String: JSONValue] = [:]
        for (name, description, isInteger) in fields {
            props[name] = isInteger ? Schema.integer(description) : Schema.number(description)
        }
        return Schema.object(
            "AudioAlign tunables (docs: spikes/audio-align). Every field is required; copy them from project_describe and change what you need.",
            properties: props, required: fields.map(\.0))
    }()
}
