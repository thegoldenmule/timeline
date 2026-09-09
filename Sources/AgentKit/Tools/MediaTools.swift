import Contracts
import Foundation
import TimelineCore

/// `media_import`, `media_analyze`, `transcript_search`, `look_at`: the senses.
enum MediaTools {
    static let mediaImport = Tool(
        name: "media_import",
        description:
            "Imports a media file into the library (hash, copy or move or reference, probe) as a background job and records it in the project as an asset. A file already in the library by content hash is not copied again. Returns the asset and the new project version.",
        inputSchema: Schema.object(
            "Import request.",
            properties: ToolSupport.inputProperties(
                mutating: true,
                [
                    "url": Schema.string("file:// URL or absolute path of the media file."),
                    "mode": Schema.enum(
                        "copy (default) copies into the library, move moves it, reference leaves it in place.",
                        ImportMode.allCases.map(\.rawValue)),
                ]), required: ["url"]),
        outputSchema: Schema.object(
            "Import result.",
            properties: ToolSupport.mutationOutputSchema.merging([
                "asset": Schema.any("The asset summary as project_describe shows it."),
                "alreadyInLibrary": Schema.bool("True when the library already had this content."),
                "alreadyInProject": Schema.bool(
                    "True when the project already referenced this asset (no command applied)."),
                "libraryURL": Schema.string("Where the file lives now."),
            ]) { a, _ in a }, required: ["version", "asset", "alreadyInLibrary", "alreadyInProject"],
            additionalProperties: true),
        annotations: ToolAnnotations(title: "Import media", idempotent: true),
        examples: [
            .object(["url": "/Users/me/Downloads/IMG_1575.MOV"]),
            .object(["url": "file:///Users/me/Downloads/band-mix-v3.wav", "mode": "reference", "expectedVersion": 12]),
        ]
    ) { input, context in
        guard let library = context.services.mediaLibrary else { throw ToolError.serviceUnavailable("mediaLibrary") }
        guard let runner = context.services.jobRunner else { throw ToolError.serviceUnavailable("jobRunner") }
        let raw = try ToolSupport.requireString(input, "url")
        let url = raw.hasPrefix("file://") ? URL(string: raw) ?? URL(fileURLWithPath: raw) : URL(fileURLWithPath: raw)
        let mode = try ToolSupport.decode(input, "mode", as: ImportMode.self) ?? .copy
        let resolved = try await ToolSupport.resolve(input, context)
        let handle = await runner.submit(library.importJob(url: url, mode: mode))
        let outcome: JobOutcome
        do {
            outcome = try await handle.wait()
        } catch let error as MediaError {
            return .error(code: "mediaError", message: String(describing: error))
        }
        guard let result = try outcome.payload(as: ImportResult.self) else {
            return .error(code: "importFailed", message: "The import job returned no result")
        }
        var extra: [String: JSONValue] = [
            "asset": ProjectTools.assetSummary(result.asset), "alreadyInLibrary": .bool(result.alreadyInLibrary),
            "libraryURL": .string(result.libraryURL.path), "jobId": .string(handle.id.rawValue),
        ]
        let existing = resolved.project.assets.values.first { $0.contentHash == result.asset.contentHash }
        if let existing {
            extra["alreadyInProject"] = .bool(true)
            extra["asset"] = ProjectTools.assetSummary(existing)
            extra["version"] = .number(Double(resolved.project.version))
            extra["changedIds"] = .array([])
            extra["warnings"] = .array([.string("Asset already in the project; nothing applied.")])
            extra["status"] = .string("noop")
            extra["projectId"] = .string(resolved.projectId.rawValue)
            return ToolOutput(structured: .object(extra), text: "Already in project as \(existing.id.rawValue).")
        }
        extra["alreadyInProject"] = .bool(false)
        let command = try ToolSupport.command(.importAsset(result.operation), input: input, context: context)
        return try await ToolSupport.apply(command, to: resolved.store, extra: extra)
    }

    static let analysisKinds = ["transcript", "silence", "shots", "peaks", "onsetEnvelope"]

    static let mediaAnalyze = Tool(
        name: "media_analyze",
        description:
            "Runs analyses on an asset (transcript, silence, shots, peaks, onsetEnvelope) as background jobs and records each result on the asset. Transcription may require approval: the result then has status approval_required with an approvalToken; retry the same call with approvalToken once the user approved. Returns the results' summaries (transcript text and word count, silence ranges, shots) and the new project version.",
        inputSchema: Schema.object(
            "Analyze request.",
            properties: ToolSupport.inputProperties(
                mutating: true,
                [
                    "assetId": Schema.string("The asset to analyze."),
                    "kinds": Schema.array(
                        "Analyses to run.", items: Schema.enum("Analysis kind.", analysisKinds), minItems: 1),
                    "locale": Schema.string("Transcription locale, BCP-47 (default en-US)."),
                    "approvalToken": Schema.string("Token from a previous approval_required result, once granted."),
                ]), required: ["assetId", "kinds"]),
        outputSchema: Schema.object(
            "Analysis results, or an approval_required envelope.",
            properties: ToolSupport.mutationOutputSchema.merging([
                "results": Schema.any("Per-kind summaries keyed by kind."),
                "status": Schema.string("applied, noop, replayed, or approval_required."),
                "approvalToken": Schema.string("Present when approval is required."),
                "estimate": Schema.any("Estimated cost when approval is required."),
            ]) { a, _ in a }, required: ["status"], additionalProperties: true),
        annotations: ToolAnnotations(title: "Analyze media", idempotent: true),
        examples: [
            .object(["assetId": "00000000-0000-7000-8000-00000000000e", "kinds": ["transcript", "silence"]]),
            .object([
                "assetId": "00000000-0000-7000-8000-00000000000e", "kinds": ["transcript"], "locale": "en-US",
                "approvalToken": "tok-1", "expectedVersion": 12,
            ]),
        ]
    ) { input, context in
        guard let analyzer = context.services.analyzer else { throw ToolError.serviceUnavailable("analyzer") }
        guard let runner = context.services.jobRunner else { throw ToolError.serviceUnavailable("jobRunner") }
        let resolved = try await ToolSupport.resolve(input, context)
        let asset = try ToolSupport.asset(try ToolSupport.requireString(input, "assetId"), in: resolved.project)
        let kinds = (input["kinds"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !kinds.isEmpty, kinds.allSatisfy({ analysisKinds.contains($0) }) else {
            throw ToolError.invalidInput("kinds must be a non-empty subset of \(analysisKinds.joined(separator: ", "))")
        }
        if kinds.contains("transcript") {
            // SpeechAnalyzer runs about 65x realtime (spikes/speech); the estimate is what the card shows.
            let estimate = Estimate(seconds: (asset.duration.seconds / 65).rounded(.up), usd: 0)
            if case .required(let request) = await context.checkApproval(
                tool: "media_analyze", input: input, estimate: estimate)
            {
                return .approvalRequired(request)
            }
        }
        let media = ToolSupport.mediaReference(for: asset, context: context)
        let locale = Locale(identifier: ToolSupport.string(input, "locale") ?? "en-US")
        let parameters = resolved.project.settings.alignment
        var results: [String: JSONValue] = [:]
        var ops: [Command.Operation] = []
        for kind in kinds {
            let job = Job(
                kind: kind == "transcript" ? .transcription : .analysis,
                memoryClass: kind == "transcript" ? .medium : .small,
                label: "\(kind) \(asset.displayName)"
            ) { jobContext in
                jobContext.report(JobProgress(fraction: 0, stage: kind))
                let payload: JSONValue
                switch kind {
                case "transcript":
                    let t = try await analyzer.transcribe(media, locale: locale, options: TranscriptionOptions())
                    payload = try JSONValue(encoding: t)
                case "silence":
                    payload = try JSONValue(
                        encoding: try await analyzer.detectSilence(media, parameters: SilenceParameters()))
                case "shots":
                    payload = try JSONValue(
                        encoding: try await analyzer.detectShots(media, parameters: ShotParameters()))
                case "peaks":
                    let peaks = try await analyzer.waveformPeaks(media, samplesPerPixel: 4800)
                    payload = .object([
                        "count": .number(Double(peaks.count)), "hop": .number(Double(peaks.hop)),
                        "sampleRate": .number(Double(peaks.sampleRate)),
                        "cacheKey": .string(
                            AnalysisCacheKey.make(contentHash: media.contentHash, kind: .peaks, paramsHash: "spp4800")),
                    ])
                default:
                    let e = try await analyzer.onsetEnvelope(media, parameters: parameters)
                    payload = .object([
                        "frameCount": .number(Double(e.frameCount)), "sampleRate": .number(Double(e.sampleRate)),
                        "hop": .number(Double(e.hop)), "cacheKey": .string(e.cacheKey),
                    ])
                }
                jobContext.report(.done)
                return JobOutcome(payload: payload)
            }
            let outcome: JobOutcome
            do {
                outcome = try await runner.submit(job).wait()
            } catch let error as AnalysisError {
                return .error(code: "analysisFailed", message: "\(kind): \(String(describing: error))")
            }
            let payload = outcome.payload ?? .null
            let (summary, cacheKey) = summarize(kind: kind, payload: payload)
            results[kind] = summary
            ops.append(
                .recordAssetAnalysis(
                    .init(
                        assetId: .id(asset.id),
                        kind: kind == "onsetEnvelope" ? AnalysisKind.onsetEnvelope.rawValue : kind, cacheKey: cacheKey,
                        summary: summary)))
        }
        let command = try ToolSupport.command(ops.count == 1 ? ops[0] : .batch(ops), input: input, context: context)
        return try await ToolSupport.apply(
            command, to: resolved.store, extra: ["results": .object(results), "assetId": .string(asset.id.rawValue)])
    }

    /// A small summary the project stores next to the cache key, and the cache key itself.
    static func summarize(kind: String, payload: JSONValue) -> (JSONValue, String) {
        let cacheKey = payload["cacheKey"]?.stringValue ?? "unknown/\(kind)/unknown"
        switch kind {
        case "transcript":
            let words = payload["words"]?.arrayValue ?? []
            let text = words.compactMap { $0["text"]?.stringValue }.joined(separator: " ")
            return (
                .object([
                    "words": .number(Double(words.count)), "language": payload["language"] ?? .null,
                    "engine": payload["engine"] ?? .null, "text": .string(String(text.prefix(2000))),
                    "cacheKey": .string(cacheKey),
                ]), cacheKey
            )
        case "silence":
            let ranges = payload["ranges"]?.arrayValue ?? []
            return (
                .object([
                    "ranges": .array(ranges), "count": .number(Double(ranges.count)), "cacheKey": .string(cacheKey),
                ]), cacheKey
            )
        case "shots":
            let shots = payload["shots"]?.arrayValue ?? []
            return (
                .object(["shots": .array(shots), "count": .number(Double(shots.count)), "cacheKey": .string(cacheKey)]),
                cacheKey
            )
        default:
            return (payload, cacheKey)
        }
    }

    static let transcriptSearch = Tool(
        name: "transcript_search",
        description:
            "Searches the transcripts of the project's assets for a word or phrase (case-insensitive, whole words in order). Returns each hit's media time range and where that moment appears on the timeline (clip and sequence time), so you can cut to it. Assets without a recorded transcript are transcribed on demand when assetId is given.",
        inputSchema: Schema.object(
            "Search request.",
            properties: ToolSupport.inputProperties(
                mutating: false,
                [
                    "query": Schema.string("Word or phrase to find."),
                    "assetId": Schema.string("Limit to one asset (transcribing it if needed)."),
                    "locale": Schema.string("Locale for on-demand transcription (default en-US)."),
                    "limit": Schema.integer("Maximum hits (default 50).", minimum: 1),
                ]), required: ["query"]),
        outputSchema: Schema.object(
            "Search hits.",
            properties: [
                "query": Schema.string("The query."),
                "hits": Schema.array(
                    "Hits in media order.",
                    items: Schema.object(
                        "One hit.",
                        properties: [
                            "assetId": Schema.string("Asset."), "t0": Schema.any("Media start time."),
                            "t1": Schema.any("Media end time."), "text": Schema.string("Matched words."),
                            "context": Schema.string("Surrounding words."),
                            "confidence": Schema.number("Minimum word confidence of the match."),
                            "placements": Schema.array(
                                "Where the moment sits on the timeline.",
                                items: Schema.object(
                                    "Timeline placement.",
                                    properties: [
                                        "sequenceId": Schema.string("Sequence."), "clipId": Schema.string("Clip."),
                                        "trackId": Schema.string("Track."), "at": Schema.any("Timeline time of t0."),
                                    ], required: ["sequenceId", "clipId", "at"])),
                        ], required: ["assetId", "t0", "t1", "text"])),
                "count": Schema.integer("Number of hits."),
                "searchedAssets": Schema.array("Assets searched.", items: Schema.string("Asset id.")),
            ], required: ["query", "hits", "count"]),
        annotations: .readOnly(title: "Search transcript"),
        examples: [
            .object(["query": "welcome"]),
            .object(["query": "video editor", "assetId": "00000000-0000-7000-8000-00000000000e", "limit": 5]),
        ]
    ) { input, context in
        guard let analyzer = context.services.analyzer else { throw ToolError.serviceUnavailable("analyzer") }
        let resolved = try await ToolSupport.resolve(input, context)
        let project = resolved.project
        let query = try ToolSupport.requireString(input, "query").lowercased()
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !terms.isEmpty else { throw ToolError.invalidInput("query has no words") }
        let limit = input["limit"]?.intValue ?? 50
        let locale = Locale(identifier: ToolSupport.string(input, "locale") ?? "en-US")
        let assets: [Asset]
        if let id = ToolSupport.string(input, "assetId") {
            assets = [try ToolSupport.asset(id, in: project)]
        } else {
            assets = project.assets.values.filter { $0.analyses["transcript"] != nil && $0.hasAudio }.sorted {
                $0.id < $1.id
            }
        }
        func normalize(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var hits: [JSONValue] = []
        for asset in assets {
            let transcript = try await analyzer.transcribe(
                ToolSupport.mediaReference(for: asset, context: context), locale: locale,
                options: TranscriptionOptions())
            let words = transcript.words
            guard words.count >= terms.count else { continue }
            for i in 0...(words.count - terms.count) {
                let window = Array(words[i..<(i + terms.count)])
                guard zip(window, terms).allSatisfy({ normalize($0.text) == $1 }) else { continue }
                let lo = max(0, i - 3)
                let hi = min(words.count, i + terms.count + 3)
                var placements: [JSONValue] = []
                for sequence in project.sequences.values.sorted(by: { $0.id < $1.id }) {
                    for track in sequence.tracks {
                        for clip in track.clips.values where clip.assetId == asset.id {
                            guard let t0 = window.first?.t0, t0 >= clip.sourceIn, t0 < clip.sourceOut else { continue }
                            let at = clip.start + ((t0 - clip.sourceIn) / clip.speed)
                            placements.append(
                                .object([
                                    "sequenceId": .string(sequence.id.rawValue), "clipId": .string(clip.id.rawValue),
                                    "trackId": .string(track.id.rawValue), "at": ToolSupport.timeJSON(at),
                                ]))
                        }
                    }
                }
                hits.append(
                    .object([
                        "assetId": .string(asset.id.rawValue), "t0": ToolSupport.timeJSON(window.first!.t0),
                        "t1": ToolSupport.timeJSON(window.last!.t1),
                        "text": .string(window.map(\.text).joined(separator: " ")),
                        "context": .string(words[lo..<hi].map(\.text).joined(separator: " ")),
                        "confidence": .number(window.map(\.confidence).min() ?? 1), "placements": .array(placements),
                    ]))
                if hits.count >= limit { break }
            }
            if hits.count >= limit { break }
        }
        return ToolOutput(
            structured: .object([
                "query": .string(query), "hits": .array(hits), "count": .number(Double(hits.count)),
                "searchedAssets": .array(assets.map { .string($0.id.rawValue) }),
                "projectId": .string(project.id.rawValue),
            ]),
            text: hits.isEmpty
                ? "No hits for \"\(query)\" in \(assets.count) asset(s)." : "\(hits.count) hit(s) for \"\(query)\".")
    }

    static let lookAt = Tool(
        name: "look_at",
        description:
            "Shows you frames of an asset: one thumbnail per timestamp, laid out as a labelled contact sheet image (cell #n is timestamps[n]). Use it to check content, framing, or what a shot looks like before cutting. Timestamps are media times.",
        inputSchema: Schema.withDefs(
            Schema.object(
                "Look request.",
                properties: ToolSupport.inputProperties(
                    mutating: false,
                    [
                        "assetId": Schema.string("The asset to look at."),
                        "timestamps": Schema.array(
                            "Media times to grab, in order.", items: Schema.ref("time"), minItems: 1),
                        "height": Schema.integer("Cell height in pixels (default 180).", minimum: 32, maximum: 1080),
                        "columns": Schema.integer("Cells per row (default 3).", minimum: 1),
                    ]), required: ["assetId", "timestamps"]),
            ["time": OperationSchemas.defs["time"]!]),
        outputSchema: Schema.object(
            "Contact sheet layout; the image itself is an image content block.",
            properties: [
                "assetId": Schema.string("Asset."),
                "frames": Schema.array(
                    "One entry per cell.",
                    items: Schema.object(
                        "A cell.",
                        properties: [
                            "index": Schema.integer("Cell index, top-left first."),
                            "time": Schema.any("Media time grabbed."),
                        ], required: ["index", "time"])),
                "columns": Schema.integer("Cells per row."), "rows": Schema.integer("Rows."),
                "width": Schema.integer("Sheet width in pixels."), "height": Schema.integer("Sheet height in pixels."),
            ], required: ["assetId", "frames", "columns", "rows"]),
        annotations: ToolAnnotations(title: "Look at frames", readOnly: true, idempotent: false),
        examples: [
            .object([
                "assetId": "00000000-0000-7000-8000-00000000000e",
                "timestamps": [["v": 0, "ts": 24000], ["v": 120120, "ts": 24000], ["v": 240240, "ts": 24000]],
            ])
        ]
    ) { input, context in
        guard let thumbnails = context.services.thumbnails else { throw ToolError.serviceUnavailable("thumbnails") }
        let resolved = try await ToolSupport.resolve(input, context)
        let asset = try ToolSupport.asset(try ToolSupport.requireString(input, "assetId"), in: resolved.project)
        let times = try ToolSupport.require(input, "timestamps", as: [RationalTime].self)
        guard !times.isEmpty, times.count <= 24 else { throw ToolError.invalidInput("Give 1 to 24 timestamps") }
        let height = input["height"]?.intValue ?? 180
        let media = ToolSupport.mediaReference(for: asset, context: context)
        var frames: [Thumbnail] = []
        for t in times {
            guard let thumb = try await thumbnails.thumbnail(for: media, at: t, height: height) else { continue }
            frames.append(thumb)
        }
        guard !frames.isEmpty else { return .error(code: "noFrames", message: "No frames could be generated") }
        let sheet = try ToolImages.contactSheet(frames, columns: input["columns"]?.intValue ?? 3)
        let png = try ToolImages.png(sheet.image)
        return ToolOutput(
            structured: .object([
                "assetId": .string(asset.id.rawValue),
                "frames": .array(
                    frames.enumerated().map {
                        .object(["index": .number(Double($0.offset)), "time": ToolSupport.timeJSON($0.element.time)])
                    }),
                "columns": .number(Double(sheet.columns)), "rows": .number(Double(sheet.rows)),
                "width": .number(Double(sheet.image.width)), "height": .number(Double(sheet.image.height)),
            ]),
            text: "\(frames.count) frame(s) of \(asset.displayName) as a \(sheet.columns)x\(sheet.rows) contact sheet.",
            images: [ToolImage(data: png)])
    }
}
