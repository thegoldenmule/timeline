import Contracts
import Foundation
import TimelineCore

/// Thin demo tools registered by the walking skeleton. They exist to prove the registry, the
/// `ToolContext`, the store, and the approval gate compose; AgentKit's real tools replace them in
/// Phase 2 (same names, hand-maintained schemas, `$ref` resolution, receipts in the project).
enum DemoTools {
    static var all: [Tool] { [projectDescribe, timelineApply, renderExport] }

    /// `project_describe { projectId?, level?: "summary" | "full" }`: the project's shape.
    static let projectDescribe = Tool(
        name: "project_describe",
        description: "Describes an open project: sequences, tracks, clip counts, assets, and the current version.",
        inputSchema: [
            "type": "object",
            "properties": [
                "projectId": ["type": "string"],
                "level": ["type": "string", "enum": ["summary", "full"]],
            ],
        ],
        outputSchema: ["type": "object"],
        annotations: .readOnly(title: "Describe project"),
        examples: [["level": "summary"]]
    ) { input, context in
        let store = try await context.store(for: input)
        let project = await store.state()
        if input["level"]?.stringValue == "full" {
            return try ToolOutput(encoding: project, text: "\(project.name) at version \(project.version)")
        }
        let summary = ProjectDescription(project)
        return try ToolOutput(encoding: summary, text: summary.text)
    }

    /// `timeline_apply { projectId?, op, expectedVersion?, commandId? }`: one command through the store.
    /// The `commandId` defaults to a hash of the input so a retry replays instead of re-applying.
    static let timelineApply = Tool(
        name: "timeline_apply",
        description: "Applies one timeline command (or a batch) to a project and returns the new version.",
        inputSchema: [
            "type": "object",
            "required": ["op"],
            "properties": [
                "projectId": ["type": "string"],
                "op": ["type": "object"],
                "expectedVersion": ["type": "integer"],
                "commandId": ["type": "string"],
            ],
        ],
        outputSchema: ["type": "object"],
        annotations: ToolAnnotations(title: "Apply command", idempotent: true),
        examples: [["op": ["type": "undo"]]]
    ) { input, context in
        guard let opValue = input["op"] else { throw ToolError.invalidInput("op is required") }
        let operation: Command.Operation
        do {
            operation = try opValue.decoded(as: Command.Operation.self)
        } catch {
            throw ToolError.invalidInput("op does not decode as a command: \(error)")
        }
        let store = try await context.store(for: input)
        let commandId = CommandID(input["commandId"]?.stringValue ?? "tool-\(input.argsHash)")
        let command = Command(
            commandId: commandId, actor: context.actor,
            expectedVersion: input["expectedVersion"]?.intValue.map(Int64.init), operation: operation)
        let result = try await store.apply(command)
        return try ToolOutput(encoding: result, text: "\(result.status.rawValue) at version \(result.version)")
    }

    /// `render_export { projectId?, preset, approvalToken? }`: the tool the standard policy gates. Without
    /// a token it answers `approval_required`; with a granted one it compiles the active sequence and runs
    /// the renderer's export job through the runner.
    static let renderExport = Tool(
        name: "render_export",
        description: "Exports the active sequence with a named preset. Requires approval.",
        inputSchema: [
            "type": "object",
            "required": ["preset"],
            "properties": [
                "projectId": ["type": "string"],
                "preset": ["type": "string"],
                "approvalToken": ["type": "string"],
            ],
        ],
        outputSchema: ["type": "object"],
        annotations: ToolAnnotations(title: "Export"),
        examples: [["preset": "reel9x16"]]
    ) { input, context in
        guard let presetName = input["preset"]?.stringValue, let preset = presets[presetName] else {
            throw ToolError.invalidInput("preset must be one of \(presets.keys.sorted().joined(separator: ", "))")
        }
        let store = try await context.store(for: input)
        let project = await store.state()
        guard let sequence = project.activeSequence else { throw ToolError.invalidInput("no active sequence") }
        let estimate = Estimate(seconds: FakeRendererDuration.seconds(of: sequence), bytes: 80 << 20)
        switch await context.checkApproval(tool: "render_export", input: input, estimate: estimate) {
        case .required(let request):
            return .approvalRequired(request)
        case .granted:
            guard let renderer = context.services.renderer else { throw ToolError.serviceUnavailable("renderer") }
            guard let runner = context.services.jobRunner else { throw ToolError.serviceUnavailable("jobRunner") }
            let compiled = try await renderer.compile(sequence, assets: project.assets, options: .full)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("TimelineSkeleton", isDirectory: true)
                .appendingPathComponent("\(preset.name).\(preset.fileExtension)")
            let outcome = try await runner.submit(renderer.export(compiled, preset: preset, to: url)).wait()
            guard let receipt = try outcome.payload(as: ExportReceipt.self) else {
                return .error(code: "export_failed", message: "The export job returned no receipt")
            }
            return try ToolOutput(encoding: receipt, text: "Exported \(preset.name) to \(url.path)")
        }
    }

    static let presets: [String: ExportPreset] = [
        "reel9x16": .reel9x16, "h264_1080p": .h264_1080p, "hevcHLG4K": .hevcHLG4K, "proRes": .proRes,
    ]
}

/// A rough export duration estimate: the sequence length, what the approval card shows.
enum FakeRendererDuration {
    static func seconds(of sequence: Sequence) -> Double {
        var end = RationalTime.zero
        for track in sequence.tracks {
            for clip in track.clips.values { end = RationalTime.max(end, sequence.end(of: clip)) }
        }
        return end.seconds
    }
}

/// The `project_describe` summary payload.
struct ProjectDescription: Encodable {
    struct TrackSummary: Encodable {
        var id: TrackID
        var kind: TrackKind
        var name: String
        var clipCount: Int
        var muted: Bool
        var locked: Bool
    }

    struct SequenceSummary: Encodable {
        var id: SequenceID
        var name: String
        var frameDuration: RationalTime
        var width: Int
        var height: Int
        var durationSeconds: Double
        var tracks: [TrackSummary]
        var transitionCount: Int
        var markerCount: Int
    }

    var projectId: ProjectID
    var name: String
    var version: Int64
    var activeSequenceId: SequenceID?
    var assetCount: Int
    var assets: [String]
    var sequences: [SequenceSummary]

    init(_ project: Project) {
        projectId = project.id
        name = project.name
        version = project.version
        activeSequenceId = project.activeSequenceId
        assetCount = project.assets.count
        assets = project.assets.values.map(\.displayName).sorted()
        sequences = project.sequences.values.sorted { $0.id < $1.id }.map { sequence in
            SequenceSummary(
                id: sequence.id, name: sequence.name, frameDuration: sequence.frameDuration, width: sequence.width,
                height: sequence.height, durationSeconds: FakeRendererDuration.seconds(of: sequence),
                tracks: sequence.tracks.map {
                    TrackSummary(
                        id: $0.id, kind: $0.kind, name: $0.name, clipCount: $0.clips.count, muted: $0.muted,
                        locked: $0.locked)
                },
                transitionCount: sequence.transitions.count, markerCount: sequence.markers.count)
        }
    }

    var text: String {
        let tracks = sequences.first?.tracks.map { "\($0.name) (\($0.clipCount) clips)" }.joined(separator: ", ") ?? ""
        return "\(name) v\(version): \(assetCount) assets; \(tracks)"
    }
}

/// What the fake runtime replays: one turn that reads the project, then asks to export, which the gate
/// holds for approval. The app executes the announced tool calls through the registry (the shape a
/// Messages-API runtime has, where the client runs the tools), so the approval is a real gate round-trip.
enum DemoAgentScript {
    static let describeCallId = "call-describe"
    static let exportCallId = "call-export"

    static let events: [AgentEvent] = [
        .turnStarted(index: 1),
        .assistantText("Looking at the project before exporting."),
        .toolCall(id: describeCallId, name: "project_describe", input: ["level": "summary"]),
        .toolResult(id: describeCallId, output: ["status": "see app-side execution"], isError: false),
        .assistantText("Three clips on V1 and a music bed on A1. Exporting a vertical reel."),
        .toolCall(id: exportCallId, name: "render_export", input: ["preset": "reel9x16"]),
        .approvalRequested(
            ApprovalRequest(
                id: "scripted-approval", token: "scripted-token", tool: "render_export",
                inputSummary: "render_export(preset=reel9x16)", estimate: Estimate(seconds: 11, bytes: 80 << 20),
                requestedAt: Date(timeIntervalSince1970: 1_788_825_600), actor: .agent(sessionId: "fake-session-1"),
                sessionId: "fake-session-1")),
        .toolResult(id: exportCallId, output: ["status": "exported"], isError: false),
        .assistantText("Exported the reel."),
        .finished(
            result: "Exported Reel 9:16.", cost: CostReport(usd: 0.03, inputTokens: 1200, outputTokens: 180, turns: 1)),
    ]
}
