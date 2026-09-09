import Foundation
import TimelineCore

public enum RenderStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case queued
    case running
    case done
    case failed
    case cancelled

    public var isTerminal: Bool { self == .done || self == .failed || self == .cancelled }
}

/// A `renders` row (storage.md section 5): operational, never an event.
public struct RenderRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var sequenceId: SequenceID
    public var preset: ExportPreset
    public var projectVersion: Int64
    public var status: RenderStatus
    public var requestedAt: Date
    public var completedAt: Date?
    public var outputURL: URL?
    /// "sha256-<64 hex>", the same form as `Asset.contentHash` (`FileHash.sha256(of:)`).
    public var outputHash: String?
    public var receipt: ExportReceipt?

    public init(
        id: String, sequenceId: SequenceID, preset: ExportPreset, projectVersion: Int64, status: RenderStatus,
        requestedAt: Date, completedAt: Date? = nil, outputURL: URL? = nil, outputHash: String? = nil,
        receipt: ExportReceipt? = nil
    ) {
        self.id = id
        self.sequenceId = sequenceId
        self.preset = preset
        self.projectVersion = projectVersion
        self.status = status
        self.requestedAt = requestedAt
        self.completedAt = completedAt
        self.outputURL = outputURL
        self.outputHash = outputHash
        self.receipt = receipt
    }
}

/// Stores that keep the render ledger. `SQLiteProjectStore` and `FakeProjectStore` adopt it; a tool
/// reaches it with `store as? any RenderLedger`, the way Fork reaches `ProjectStoreCopying`.
///
/// Rules both ledgers keep (tested on the fake and on SQLite): an unknown id throws; `done`, `failed`,
/// and `cancelled` set `completedAt`; recording never bumps the project version or publishes a
/// `ProjectChange`; `renders()` is newest first (`requestedAt`, then id, descending).
public protocol RenderLedger: ProjectStore {
    /// A new `queued` row. `id` nil mints one from the store's generator; `projectVersion` nil records the
    /// current version.
    func recordRender(id: String?, sequenceId: SequenceID, preset: ExportPreset, projectVersion: Int64?) async throws
        -> RenderRecord
    /// Sets the status; nil `outputURL`, `outputHash`, and `receipt` leave the stored values alone.
    func updateRender(_ id: String, status: RenderStatus, outputURL: URL?, outputHash: String?, receipt: ExportReceipt?)
        async throws -> RenderRecord
    /// Newest first.
    func renders() async throws -> [RenderRecord]
    func render(_ id: String) async throws -> RenderRecord?
}

/// Stores that keep the publish ledger (the `publishes` table next to `renders`).
///
/// Rules: an unknown id throws; `recordPublish` with a `renderId` the render ledger does not know
/// throws; `projectVersion` nil copies the render row's version; `bytesTotal` is filled from the file
/// size when the file is readable; `done`, `failed`, and `cancelled` set `completedAt`; recording never
/// bumps the project version or publishes a `ProjectChange`; `publishes()` and `publishes(forRender:)`
/// are newest first.
public protocol PublishLedger: ProjectStore {
    func recordPublish(id: String?, request: PublishRequest, projectVersion: Int64?) async throws -> PublishRecord
    func updatePublish(_ id: String, _ update: PublishUpdate) async throws -> PublishRecord
    /// Newest first.
    func publishes() async throws -> [PublishRecord]
    func publish(_ id: String) async throws -> PublishRecord?
    /// Newest first.
    func publishes(forRender renderId: String) async throws -> [PublishRecord]
}
