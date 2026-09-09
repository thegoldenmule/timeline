import Contracts
import CoreGraphics
import Foundation
import TimelineCore

/// `render_preview` and `render_export`: the output side. Export is gated by the approval policy.
enum RenderTools {
    static let renderPreview = Tool(
        name: "render_preview",
        description:
            "Renders composed frames of a sequence so you can see the result of your edits: one frame at `at`, or up to `count` frames evenly spaced over `range`, returned as a labelled contact sheet image. Preview quality, video only.",
        inputSchema: Schema.withDefs(
            Schema.object(
                "Preview request.",
                properties: ToolSupport.inputProperties(
                    mutating: false,
                    [
                        "sequenceId": Schema.string("Sequence (default: the active one)."),
                        "at": Schema.ref("time", "One timeline time to render."),
                        "range": Schema.ref("timeRange", "Timeline range to sample (alternative to at)."),
                        "count": Schema.integer(
                            "Frames across the range (default 4, max 12).", minimum: 1, maximum: 12),
                        "width": Schema.integer(
                            "Frame width in pixels (default 480; height follows the sequence aspect).", minimum: 64,
                            maximum: 1920),
                    ])),
            ["time": OperationSchemas.defs["time"]!, "timeRange": OperationSchemas.defs["timeRange"]!]),
        outputSchema: Schema.object(
            "Which frames were rendered; the image is an image content block.",
            properties: [
                "sequenceId": Schema.string("Sequence rendered."),
                "frames": Schema.array(
                    "Cells in order.",
                    items: Schema.object(
                        "A cell.",
                        properties: ["index": Schema.integer("Cell index."), "time": Schema.any("Timeline time.")],
                        required: ["index", "time"])),
                "columns": Schema.integer("Cells per row."), "rows": Schema.integer("Rows."),
                "version": Schema.integer("Project version rendered."),
            ], required: ["sequenceId", "frames", "version"]),
        annotations: ToolAnnotations(title: "Render preview", readOnly: true, idempotent: true),
        examples: [
            .object(["at": ["v": 24024, "ts": 24000]]),
            .object([
                "range": ["start": ["v": 0, "ts": 24000], "end": ["v": 240240, "ts": 24000]], "count": 6, "width": 320,
            ]),
        ]
    ) { input, context in
        guard let renderer = context.services.renderer else { throw ToolError.serviceUnavailable("renderer") }
        let resolved = try await ToolSupport.resolve(input, context)
        let sequence = try ToolSupport.sequence(input, in: resolved.project)
        var times: [RationalTime] = []
        if let at = try ToolSupport.decode(input, "at", as: RationalTime.self) {
            times = [at]
        } else if let range = try ToolSupport.decode(input, "range", as: TimeRange.self) {
            let count = max(1, min(input["count"]?.intValue ?? 4, 12))
            let span = range.end - range.start
            for i in 0..<count {
                let t = count == 1 ? range.start : range.start + span * Int64(i) / Int64(count - 1)
                times.append(
                    RationalTime.min(t, range.end - sequence.frameDuration).floored(to: sequence.frameDuration))
            }
        } else {
            times = [.zero]
        }
        let width = input["width"]?.intValue ?? 480
        let size = CGSize(width: width, height: max(1, width * sequence.height / max(1, sequence.width)))
        let compiled = try await renderer.compile(sequence, assets: resolved.project.assets, options: .gesture)
        var thumbs: [Thumbnail] = []
        for t in times {
            let image = try await renderer.frame(compiled, at: t, size: size)
            thumbs.append(Thumbnail(time: t, image: image))
        }
        let sheet = try ToolImages.contactSheet(thumbs, columns: min(3, thumbs.count))
        return ToolOutput(
            structured: .object([
                "sequenceId": .string(sequence.id.rawValue),
                "frames": .array(
                    thumbs.enumerated().map {
                        .object(["index": .number(Double($0.offset)), "time": ToolSupport.timeJSON($0.element.time)])
                    }),
                "columns": .number(Double(sheet.columns)), "rows": .number(Double(sheet.rows)),
                "version": .number(Double(resolved.project.version)), "projectId": .string(resolved.projectId.rawValue),
            ]), text: "Rendered \(thumbs.count) frame(s) of \(sequence.name).",
            images: [ToolImage(data: try ToolImages.png(sheet.image))])
    }

    static let presetNames = ["hevcHLG4K", "h264_1080p", "reel9x16", "proRes"]

    static func preset(named name: String) -> ExportPreset? {
        switch name {
        case "hevcHLG4K": .hevcHLG4K
        case "h264_1080p": .h264_1080p
        case "reel9x16": .reel9x16
        case "proRes": .proRes
        default: ExportPreset.builtIn.first { $0.name == name }
        }
    }

    static let renderExport = Tool(
        name: "render_export",
        description:
            "Exports a sequence to a file with a preset (hevcHLG4K, h264_1080p, reel9x16, proRes, or a full ExportPreset object). Always requires approval: the first call returns status approval_required with an approvalToken and an estimate; the user approves in the app; retry the identical call with approvalToken added. Runs as a background job and returns the output path and receipt when done.",
        inputSchema: Schema.object(
            "Export request.",
            properties: ToolSupport.inputProperties(
                mutating: false,
                [
                    "sequenceId": Schema.string("Sequence (default: the active one)."),
                    "preset": Schema.anyOf(
                        "A built-in preset name or a complete ExportPreset object.",
                        [
                            Schema.enum("Built-in preset.", presetNames),
                            Schema.object("Full preset.", properties: [:], additionalProperties: true),
                        ]),
                    "outputPath": Schema.string(
                        "Destination file path (default: ~/Movies/Timeline/Exports/<sequence>-<preset>.<ext>)."),
                    "approvalToken": Schema.string("Token from the approval_required result, once granted."),
                ]), required: ["preset"]),
        outputSchema: Schema.object(
            "Export result or approval_required envelope.",
            properties: [
                "status": Schema.string("done or approval_required."),
                "outputPath": Schema.string("Where the file was written."),
                "durationSeconds": Schema.number("Sequence duration exported."),
                "preset": Schema.any("The preset used."),
                "receipt": Schema.any("The ExportReceipt."),
                "jobId": Schema.string("Export job id."),
                "version": Schema.integer("Project version exported."),
                "approvalToken": Schema.string("Present when approval is required."),
                "estimate": Schema.any("Estimated seconds and bytes when approval is required."),
            ], required: ["status"], additionalProperties: true),
        annotations: ToolAnnotations(
            title: "Export", readOnly: false, destructive: false, idempotent: false, openWorld: true),
        examples: [
            .object(["preset": "reel9x16"]),
            .object(["preset": "h264_1080p", "outputPath": "/Users/me/Movies/reel.mp4", "approvalToken": "tok-1"]),
        ]
    ) { input, context in
        guard let renderer = context.services.renderer else { throw ToolError.serviceUnavailable("renderer") }
        guard let runner = context.services.jobRunner else { throw ToolError.serviceUnavailable("jobRunner") }
        let resolved = try await ToolSupport.resolve(input, context)
        let sequence = try ToolSupport.sequence(input, in: resolved.project)
        let chosen: ExportPreset
        if let name = ToolSupport.string(input, "preset") {
            guard let p = RenderTools.preset(named: name) else {
                throw ToolError.invalidInput(
                    "Unknown preset \(name); use one of \(presetNames.joined(separator: ", "))")
            }
            chosen = p
        } else {
            chosen = try ToolSupport.require(input, "preset", as: ExportPreset.self)
        }
        let preset = chosen
        let duration = ToolSupport.duration(of: sequence)
        // Roughly realtime for hardware HEVC/H.264 on this class of machine; bytes from the bitrate.
        var bytes: Int64?
        if case .bitrate(let bps) = preset.videoQuality { bytes = Int64(Double(bps) / 8 * duration.seconds) }
        let estimate = Estimate(seconds: duration.seconds.rounded(.up), usd: 0, bytes: bytes)
        if case .required(let request) = await context.checkApproval(
            tool: "render_export", input: input, estimate: estimate)
        {
            return .approvalRequired(request)
        }
        let outputURL: URL
        if let path = ToolSupport.string(input, "outputPath") {
            outputURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            let name = "\(sequence.name)-\(preset.name)".replacingOccurrences(of: "/", with: "-")
            outputURL = LibraryLayout.default.root.appendingPathComponent("Exports/\(name).\(preset.fileExtension)")
        }
        let compiled = try await renderer.compile(sequence, assets: resolved.project.assets, options: .full)
        let handle = await runner.submit(renderer.export(compiled, preset: preset, to: outputURL))
        let outcome: JobOutcome
        do {
            outcome = try await handle.wait()
        } catch let error as RenderError {
            return .error(code: "renderFailed", message: String(describing: error))
        } catch let error as JobError {
            return .error(code: "jobFailed", message: error.message)
        }
        var receipt = try outcome.payload(as: ExportReceipt.self)
        receipt?.projectVersion = resolved.project.version
        var o: [String: JSONValue] = [
            "status": .string("done"), "outputPath": .string((outcome.urls.first ?? outputURL).path),
            "durationSeconds": .number(duration.seconds), "preset": ToolSupport.json(preset),
            "jobId": .string(handle.id.rawValue), "version": .number(Double(resolved.project.version)),
            "projectId": .string(resolved.projectId.rawValue), "warnings": .array(outcome.warnings.map { .string($0) }),
        ]
        if let receipt { o["receipt"] = ToolSupport.json(receipt) }
        return ToolOutput(
            structured: .object(o), text: "Exported \(sequence.name) with \(preset.name) to \(outputURL.path).")
    }
}
