import Contracts
import Foundation
import GRDB
import TimelineCore

// The `RenderLedger` and `PublishLedger` of Contracts/Ledgers.swift over the `renders` and `publishes`
// tables (storage.md section 5, publish-plan.md section 4.2). Both tables hold operational rows: never an
// event, never a projection. Recording never bumps the project version or publishes a `ProjectChange`;
// `rebuildProjections` leaves the rows alone; `backup` and `saveAs` carry them with the database.

extension SQLiteProjectStore: RenderLedger, PublishLedger {
    // MARK: RenderLedger

    /// A new `queued` row; `id` nil mints one, `projectVersion` nil records the current version.
    public func recordRender(id: String?, sequenceId: SequenceID, preset: ExportPreset, projectVersion: Int64?)
        throws -> RenderRecord
    {
        try recordRender(
            id: id, sequenceId: sequenceId, preset: preset, projectVersion: projectVersion, status: .queued
        )
        .record()
    }

    /// Sets the status (terminal states stamp `completedAt`); nil `outputURL`, `outputHash`, and `receipt`
    /// leave the stored values alone. `output_path` is stored absolute.
    public func updateRender(
        _ id: String, status: RenderStatus, outputURL: URL?, outputHash: String?, receipt: ExportReceipt?
    ) throws -> RenderRecord {
        try updateRender(
            id, status: RenderRow.Status(status), outputPath: outputURL?.standardizedFileURL.path,
            outputHash: outputHash, receipt: receipt
        ).record()
    }

    /// Every render, newest first (`requested_at`, then id, descending).
    public func renders() throws -> [RenderRecord] {
        try renderRows().map { try $0.record() }
    }

    public func render(_ id: String) throws -> RenderRecord? {
        try renderRow(id)?.record()
    }

    // MARK: PublishLedger

    /// A new `queued` row linked to `request.renderId`. An unknown render throws `ProjectStoreError.storage`
    /// before an id or a timestamp is minted (the fake behaves the same; the row's foreign key backs the
    /// check up); `projectVersion` nil copies the render row's; `bytesTotal` is the file's size when it is
    /// readable.
    public func recordPublish(id: String?, request: PublishRequest, projectVersion: Int64?) throws -> PublishRecord {
        if isClosed { throw ProjectStoreError.closed }
        let requestJSON = try JSONColumn.encode(request)
        let bytesTotal = Self.fileSize(of: request.fileURL)
        let ids = self.ids
        let clock = self.clock
        do {
            return try writer.write { db in
                guard let render = try RenderRow.fetchOne(db, key: request.renderId) else {
                    throw ProjectStoreError.storage(Self.noRender(request.renderId))
                }
                let row = PublishRow(
                    publishId: id ?? ids.next(), renderId: request.renderId, destination: request.destination,
                    accountId: request.accountId, requestedAt: Schema.timestamp(clock.now()), completedAt: nil,
                    status: .queued, request: requestJSON, session: nil, bytesTotal: bytesTotal, bytesSent: nil,
                    remoteId: nil, remoteUrl: nil, projectVersion: projectVersion ?? render.projectVersion,
                    receipt: nil, error: nil)
                try row.insert(db)
                return try row.record()
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
            throw ProjectStoreError.storage(Self.noRender(request.renderId))
        }
    }

    /// Applies `update` to the row inside one transaction: nil fields are left alone, `clearsSession` drops
    /// the capability URL, a terminal status stamps `completedAt`. An unknown id throws.
    public func updatePublish(_ id: String, _ update: PublishUpdate) throws -> PublishRecord {
        if isClosed { throw ProjectStoreError.closed }
        let sessionJSON = try update.session.map { try JSONColumn.encode($0) }
        let receiptJSON = try update.receipt.map { try JSONColumn.encode($0) }
        let completedAt = update.status?.isTerminal == true ? Schema.timestamp(clock.now()) : nil
        return try writer.write { db in
            guard var row = try PublishRow.fetchOne(db, key: id) else {
                throw ProjectStoreError.storage("No publish with id \(id)")
            }
            if let status = update.status { row.status = status }
            if let sessionJSON { row.session = sessionJSON }
            if update.clearsSession { row.session = nil }
            if let bytesSent = update.bytesSent { row.bytesSent = bytesSent }
            if let remoteId = update.remoteId { row.remoteId = remoteId }
            if let remoteURL = update.remoteURL { row.remoteUrl = remoteURL.absoluteString }
            if let receiptJSON { row.receipt = receiptJSON }
            if let error = update.error { row.error = error }
            if let completedAt { row.completedAt = completedAt }
            try row.update(db)
            return try row.record()
        }
    }

    /// Every publish, newest first (`requested_at`, then id, descending).
    public func publishes() throws -> [PublishRecord] {
        try publishRows().map { try $0.record() }
    }

    public func publish(_ id: String) throws -> PublishRecord? {
        if isClosed { throw ProjectStoreError.closed }
        return try writer.read { db in try PublishRow.fetchOne(db, key: id)?.record() }
    }

    /// The publishes of one render, newest first (through `publishes_render_idx`).
    public func publishes(forRender renderId: String) throws -> [PublishRecord] {
        if isClosed { throw ProjectStoreError.closed }
        return try writer.read { db in
            try PublishRow.fetchAll(
                db, sql: "SELECT * FROM publishes WHERE render_id = ? ORDER BY requested_at DESC, publish_id DESC",
                arguments: [renderId]
            ).map { try $0.record() }
        }
    }

    /// Every `publishes` row, newest first; the row-level companion of `renderRows()`.
    public func publishRows() throws -> [PublishRow] {
        if isClosed { throw ProjectStoreError.closed }
        return try writer.read { db in
            try PublishRow.fetchAll(db, sql: "SELECT * FROM publishes ORDER BY requested_at DESC, publish_id DESC")
        }
    }

    private static func noRender(_ id: String) -> String { "No render with id \(id)" }

    /// The size of a readable local file, nil for anything else.
    private nonisolated static func fileSize(of url: URL) -> Int64? {
        guard url.isFileURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }
}

// MARK: - Rows to records

/// The JSON columns: `ProjectCodec`'s canonical encoder, as text.
enum JSONColumn {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try ProjectCodec.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try ProjectCodec.decode(type, from: Data(text.utf8))
    }
}

extension RenderRow.Status {
    init(_ status: RenderStatus) {
        switch status {
        case .queued: self = .queued
        case .running: self = .running
        case .done: self = .done
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }

    var ledgerStatus: RenderStatus {
        switch self {
        case .queued: .queued
        case .running: .running
        case .done: .done
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

extension RenderRow {
    /// The `RenderRecord` this row describes: `preset` and `receipt` through `ProjectCodec`, `output_path`
    /// as a file URL.
    func record() throws -> RenderRecord {
        RenderRecord(
            id: renderId, sequenceId: SequenceID(sequenceId),
            preset: try JSONColumn.decode(ExportPreset.self, preset), projectVersion: projectVersion,
            status: status.ledgerStatus, requestedAt: try Schema.date(requestedAt),
            completedAt: try completedAt.map { try Schema.date($0) },
            outputURL: outputPath.map { URL(fileURLWithPath: $0) }, outputHash: outputHash,
            receipt: try receipt.map { try JSONColumn.decode(ExportReceipt.self, $0) })
    }
}

extension PublishRow {
    /// The `PublishRecord` this row describes.
    func record() throws -> PublishRecord {
        PublishRecord(
            id: publishId, renderId: renderId, destination: destination, accountId: accountId, status: status,
            request: try JSONColumn.decode(PublishRequest.self, request),
            session: try session.map { try JSONColumn.decode(PublishSession.self, $0) },
            bytesTotal: bytesTotal, bytesSent: bytesSent, remoteId: remoteId,
            remoteURL: remoteUrl.flatMap { URL(string: $0) }, projectVersion: projectVersion,
            receipt: try receipt.map { try JSONColumn.decode(PublishReceipt.self, $0) }, error: error,
            requestedAt: try Schema.date(requestedAt), completedAt: try completedAt.map { try Schema.date($0) })
    }
}
