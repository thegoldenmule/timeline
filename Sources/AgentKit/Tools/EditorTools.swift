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
            ApplyTools.timelineApply, ApplyTools.timelineCut, ApplyTools.transitionAdd, ApplyTools.captionAdd,
            AlignTools.alignAudio,
            MediaTools.mediaImport, MediaTools.mediaAnalyze, MediaTools.transcriptSearch, MediaTools.lookAt,
            RenderTools.renderPreview, RenderTools.renderExport,
            PublishTools.publishYouTube, PublishTools.publishStatus, PublishTools.accountStatus,
            ApplyTools.undo, ApplyTools.redo,
        ]
    }

    public static var names: [String] { all.map(\.name) }

    /// The service each tool needs beyond the project store, by tool name.
    static let requiredService: [String: @Sendable (ToolServices) -> Bool] = [
        "align_audio": { $0.hasAligner }, "media_import": { $0.hasMediaLibrary }, "media_analyze": { $0.hasAnalyzer },
        "transcript_search": { $0.hasAnalyzer }, "look_at": { $0.hasThumbnails }, "render_preview": { $0.hasRenderer },
        "render_export": { $0.hasRenderer }, "publish_youtube": { $0.hasPublishing },
        "publish_status": { $0.hasPublisher }, "account_status": { $0.hasAccounts },
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

    /// The tools that need a publisher and an account provider. Unlike every other service, the Google
    /// OAuth client can be set while the app runs (docs/plans/publish-client-setup.md), so these two come
    /// and go through `setRegistered` rather than only at boot.
    public static let publishingToolNames = ["publish_youtube", "publish_status"]

    /// Adds or drops tools by name on a running registry. Names that are not part of `all` are ignored.
    public static func setRegistered(_ names: [String], registered: Bool, in registry: any ToolRegistry) async {
        for name in names {
            if registered {
                guard let tool = all.first(where: { $0.name == name }) else { continue }
                await registry.register(tool)
            } else {
                await registry.unregister(name)
            }
        }
    }

    /// Registers the standard tools into any registry.
    public static func register(
        into registry: any ToolRegistry, services: ToolServices? = nil, includeUnavailable: Bool = true
    ) async {
        for tool in all {
            if !includeUnavailable, let services, let available = requiredService[tool.name], !available(services) {
                continue
            }
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
    var hasPublisher: Bool { publishers[.youtube] != nil }
    var hasAccounts: Bool { !accounts.isEmpty }
    /// `publish_youtube` needs the publisher, the Google account provider, and a job runner.
    var hasPublishing: Bool { hasPublisher && accounts[.google] != nil && jobRunner != nil }
}
