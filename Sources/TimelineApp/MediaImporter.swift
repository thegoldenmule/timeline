import Contracts
import Foundation
import TimelineCore
import TimelineUI

/// The one import path behind the Import button, the timeline drop, and the window-wide drop: each file
/// goes through the library as a job (visible in the job list) and its asset is recorded with
/// `importAsset` unless the project already has that content hash. **Importing stops there.** Only a
/// drop on the timeline asks for a clip, and then the files land back to back from the drop time, in the
/// order dropped, as ripple inserts (docs/design/integration.md, "Drag and drop").
@MainActor
struct MediaImporter {
    let services: AppServices
    let document: ProjectDocument
    let jobs: JobCenter

    struct Outcome {
        /// The assets the files resolved to, in order.
        var assets: [Asset] = []
        /// The clip added for each asset (the video clip of a linked pair); empty for a library-only import.
        var clipIds: [ClipID] = []
        /// Files skipped because they are not media.
        var ignored: [URL] = []
    }

    /// Imports the media files among `urls` into the library and records their assets; non-media files
    /// are reported in `ignored`, never imported. Nothing reaches the timeline.
    @discardableResult
    func importFiles(_ urls: [URL]) async throws -> Outcome {
        try await resolveAssets(urls)
    }

    /// The timeline drop: the same import, then a clip per asset from `target`, back to back.
    @discardableResult
    func importFiles(_ urls: [URL], at target: TimelineDropTarget) async throws -> Outcome {
        var outcome = try await resolveAssets(urls)
        outcome.clipIds = try await insertClips(for: outcome.assets, at: target)
        return outcome
    }

    /// Imports the media files among `urls` through the library and records each one's asset.
    private func resolveAssets(_ urls: [URL]) async throws -> Outcome {
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
        for handle in handles {
            let result = try await handle.wait().payload(as: ImportResult.self)
            guard let result else { continue }
            outcome.assets.append(try await record(result))
        }
        return outcome
    }

    /// A clip per asset: at `target` back to back (the next starts where the last one ends, on the same
    /// track), or appended at the end of the sequence when there is no target.
    private func insertClips(for assets: [Asset], at target: TimelineDropTarget?) async throws -> [ClipID] {
        var clipIds: [ClipID] = []
        var cursor = target
        for asset in assets {
            if let at = cursor {
                let (added, clipId) = try await document.insertClip(for: asset, at: at)
                try await document.waitForVersion(added.version)
                clipIds.append(clipId)
                if let sequence = document.sequence, let clip = sequence.clip(clipId) {
                    cursor = TimelineDropTarget(trackId: at.trackId, at: sequence.end(of: clip))
                }
            } else {
                let (added, clipId) = try await document.appendClip(for: asset)
                try await document.waitForVersion(added.version)
                clipIds.append(clipId)
            }
        }
        return clipIds
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
