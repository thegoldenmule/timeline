import Contracts
import Foundation
import Observation
import SwiftUI
import TimelineCore

/// Tracks `JobHandle`s for the job list: progress from each handle's stream, the outcome from its task.
@MainActor @Observable
public final class JobCenter {
    public enum State: Hashable, Sendable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    public struct Entry: Identifiable, Sendable {
        public var id: JobID
        public var kind: JobKind
        public var label: String
        public var progress: JobProgress = .indeterminate
        public var state: State = .running
        public var outcome: JobOutcome?

        public var isRunning: Bool { state == .running }
    }

    public private(set) var entries: [Entry] = []
    private var handles: [JobID: JobHandle] = [:]
    private var watchers: [JobID: Task<Void, Never>] = [:]

    public init() {}

    public var running: [Entry] { entries.filter(\.isRunning) }

    public func entry(_ id: JobID) -> Entry? { entries.first { $0.id == id } }

    /// Starts following `handle`.
    public func track(_ handle: JobHandle) {
        guard handles[handle.id] == nil else { return }
        handles[handle.id] = handle
        entries.append(Entry(id: handle.id, kind: handle.kind, label: handle.label))
        watchers[handle.id] = Task { [weak self] in
            for await p in handle.progress {
                guard let self else { return }
                self.update(handle.id) { $0.progress = p }
            }
            let result: Result<JobOutcome, any Error>
            do {
                result = .success(try await handle.wait())
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.update(handle.id) { e in
                switch result {
                case .success(let outcome):
                    e.state = .finished
                    e.outcome = outcome
                    e.progress = .done
                case .failure(let error):
                    e.state = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Submits `job` to `runner` and tracks the handle.
    @discardableResult
    public func submit(_ job: Job, to runner: any JobRunner) async -> JobHandle {
        let handle = await runner.submit(job)
        track(handle)
        return handle
    }

    public func cancel(_ id: JobID) {
        handles[id]?.cancel()
        update(id) { if $0.isRunning { $0.state = .cancelled } }
    }

    public func clearFinished() {
        entries.removeAll { !$0.isRunning }
        for id in handles.keys where entry(id) == nil {
            handles[id] = nil
            watchers[id]?.cancel()
            watchers[id] = nil
        }
    }

    /// Waits for every tracked job to end (tests).
    public func drain() async {
        for t in watchers.values { await t.value }
    }

    private func update(_ id: JobID, _ body: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        body(&entries[i])
    }
}

/// One job row: label, stage, progress bar, cancel.
public struct JobProgressView: View {
    public let entry: JobCenter.Entry
    public let onCancel: () -> Void

    public init(entry: JobCenter.Entry, onCancel: @escaping () -> Void) {
        self.entry = entry
        self.onCancel = onCancel
    }

    /// The stage line: a publish stage's raw value reads as "Uploading", other stages as given.
    public static func stateText(_ entry: JobCenter.Entry) -> String {
        switch entry.state {
        case .running:
            var s =
                entry.progress.stage.map { JobProgressView.stageLabel($0, kind: entry.kind) } ?? entry.progress.message
                ?? "Running"
            if let eta = entry.progress.etaSeconds { s += String(format: " · %.0f s left", eta) }
            return s
        case .finished: return entry.kind == .publish ? "Published" : "Done"
        case .failed(let message): return "Failed: \(message)"
        case .cancelled: return "Cancelled"
        }
    }

    public static func stageLabel(_ stage: String, kind: JobKind) -> String {
        guard kind == .publish, let publishStage = PublishStage(rawValue: stage) else { return stage }
        switch publishStage {
        case .verify: return "Verifying the file"
        case .session: return "Starting the upload"
        case .upload: return "Uploading"
        case .processing: return "Processing on YouTube"
        case .thumbnail: return "Setting the thumbnail"
        case .captions: return "Uploading captions"
        case .playlist: return "Adding to the playlist"
        }
    }

    private var stateText: String { JobProgressView.stateText(entry) }

    public var body: some View {
        HStack(spacing: PanelTheme.barInsetH) {
            VStack(alignment: .leading, spacing: PanelTheme.rowGap) {
                HStack {
                    Text(entry.label).font(PanelTheme.rowTitle).lineLimit(1)
                    Text(entry.kind.rawValue).font(PanelTheme.detail).foregroundStyle(.secondary)
                }
                if entry.isRunning, let fraction = entry.progress.fraction {
                    ProgressView(value: min(1, max(0, fraction)))
                } else if entry.isRunning {
                    ProgressView()
                }
                Text(stateText).font(PanelTheme.caption).foregroundStyle(.secondary).lineLimit(1)
                if entry.kind == .publish, entry.state == .finished, let outcome = entry.outcome {
                    PublishOutcomeView(outcome: outcome)
                }
            }
            Spacer()
            if entry.isRunning {
                Button(action: onCancel) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Cancel")
            }
        }
        .padding(.vertical, PanelTheme.rowGap)
        .accessibilityIdentifier("job-\(entry.id.rawValue)")
    }
}

/// All tracked jobs, running first.
public struct JobList: View {
    public let center: JobCenter

    public init(center: JobCenter) {
        self.center = center
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.rowGap) {
            HStack {
                Text("Jobs").font(PanelTheme.sectionTitle)
                Spacer()
                if center.entries.contains(where: { !$0.isRunning }) {
                    Button("Clear") { center.clearFinished() }.buttonStyle(.borderless).font(PanelTheme.caption)
                }
            }
            if center.entries.isEmpty {
                Text("No jobs").font(PanelTheme.caption).foregroundStyle(.secondary)
            }
            ForEach(center.entries.sorted { $0.isRunning && !$1.isRunning }) { entry in
                JobProgressView(entry: entry) { center.cancel(entry.id) }
            }
        }
        .padding(PanelTheme.panelInset)
    }
}
