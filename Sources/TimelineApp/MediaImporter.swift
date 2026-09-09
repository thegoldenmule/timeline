import Contracts
import Foundation
import TimelineCore
import TimelineUI

/// The one import path behind the Import button, the timeline drop, and the window-wide drop: each
/// file goes through the library as a job (visible in the job list), its asset is recorded with
/// `importAsset` unless the project already has that content hash, and a clip for it lands on the
/// timeline. With a `TimelineDropTarget` the files land back to back from the drop time, in the order
/// dropped, as ripple inserts (docs/design/integration.md, "Drag and drop"); without one each is
/// appended at the end of the sequence.
@MainActor
struct MediaImporter {
    let services: AppServices
    let document: ProjectDocument
    let jobs: JobCenter

    struct Outcome {
        /// The assets the files resolved to, in order.
        var assets: [Asset] = []
        /// The clip added for each file (the video clip of a linked pair).
        var clipIds: [ClipID] = []
        /// Files skipped because they are not media.
        var ignored: [URL] = []
    }

    /// Imports the media files among `urls`; non-media files are reported in `ignored`, never imported.
    @discardableResult
    func importFiles(_ urls: [URL], at target: TimelineDropTarget?) async throws -> Outcome {
        var outcome = Outcome()
        outcome.ignored = urls.filter { !MediaFileTypes.isMedia($0) }
        let media = MediaFileTypes.mediaURLs(urls)
        guard !media.isEmpty else { return outcome }
        // Every job is submitted up front so the list shows them all and the runner admits them in order.
        var handles: [JobHandle] = []
        for url in media {
            handles.append(
                await jobs.submit(services.mediaLibrary.importJob(url: url, mode: .copy), to: services.jobRunner))
        }
        var cursor = target
        for handle in handles {
            let result = try await handle.wait().payload(as: ImportResult.self)
            guard let result else { continue }
            let asset = try await record(result)
            outcome.assets.append(asset)
            if let at = cursor {
                let (added, clipId) = try await document.insertClip(for: asset, at: at)
                try await document.waitForVersion(added.version)
                outcome.clipIds.append(clipId)
                // The next file starts where this one ends (the clip's timeline duration, frame-rounded on
                // video tracks), on the same track.
                if let sequence = document.sequence, let clip = sequence.clip(clipId) {
                    cursor = TimelineDropTarget(trackId: at.trackId, at: sequence.end(of: clip))
                }
            } else {
                let (added, clipId) = try await document.appendClip(for: asset)
                try await document.waitForVersion(added.version)
                outcome.clipIds.append(clipId)
            }
        }
        return outcome
    }

    /// The project's asset for an import: the existing one with the same content hash, else the
    /// `importAsset` command the library prepared.
    private func record(_ result: ImportResult) async throws -> Asset {
        if let existing = document.project.assets.values.first(where: { $0.contentHash == result.asset.contentHash }) {
            return existing
        }
        let applied = try await document.apply(
            .importAsset(result.operation), label: "Import \(result.asset.displayName)")
        try await document.waitForVersion(applied.version)
        return document.project.assets[result.asset.id] ?? result.asset
    }
}
