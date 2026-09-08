import Contracts
import Foundation
import TimelineCore

/// The initial tool set (docs/research/README.md "Tool surface"): every tool takes `projectId`
/// (default: the frontmost project), every mutating tool returns `{ version, changedIds, warnings,
/// txnId }`, and the expensive ones are gated by the approval policy inside their handlers.
public enum EditorTools {
    /// Every tool, in the order the server lists them.
    public static var all: [Tool] {
        [
            ProjectTools.projectList, ProjectTools.projectDescribe, ProjectTools.timelineQuery,
            ApplyTools.timelineApply, ApplyTools.transitionAdd, ApplyTools.captionAdd,
            AlignTools.alignAudio,
            MediaTools.mediaImport, MediaTools.mediaAnalyze, MediaTools.transcriptSearch, MediaTools.lookAt,
            RenderTools.renderPreview, RenderTools.renderExport,
            ApplyTools.undo, ApplyTools.redo,
        ]
    }

    public static var names: [String] { all.map(\.name) }

    /// The service each tool needs beyond the project store, by tool name.
    static let requiredService: [String: @Sendable (ToolServices) -> Bool] = [
        "align_audio": { $0.hasAligner }, "media_import": { $0.hasMediaLibrary }, "media_analyze": { $0.hasAnalyzer },
        "transcript_search": { $0.hasAnalyzer }, "look_at": { $0.hasThumbnails }, "render_preview": { $0.hasRenderer },
        "render_export": { $0.hasRenderer },
    ]

    /// A registry with the standard tools registered. Tools whose service is missing from
    /// `context.services` are left out so the model never sees a tool that can only answer
    /// `serviceUnavailable`; pass `includeUnavailable: true` to register every tool regardless.
    public static func standard(
        context: ToolContext, includeUnavailable: Bool = false, clock: any Clock = SystemClock()
    ) async -> EditorToolRegistry {
        let registry = EditorToolRegistry(clock: clock)
        await register(into: registry, services: context.services, includeUnavailable: includeUnavailable)
        return registry
    }

    /// Registers the standard tools into any registry.
    public static func register(
        into registry: any ToolRegistry, services: ToolServices? = nil, includeUnavailable: Bool = true
    ) async {
        for tool in all {
            if !includeUnavailable, let services, let available = requiredService[tool.name], !available(services) { continue }
            await registry.register(tool)
        }
    }
}

extension ToolServices {
    var hasAligner: Bool { aligner != nil && jobRunner != nil }
    var hasMediaLibrary: Bool { mediaLibrary != nil && jobRunner != nil }
    var hasAnalyzer: Bool { analyzer != nil }
    var hasThumbnails: Bool { thumbnails != nil }
    var hasRenderer: Bool { renderer != nil }
}
