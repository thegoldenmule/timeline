import Contracts
import ContractsTestSupport
import Foundation
import GRDB
import Testing
import TimelineCore

@testable import ProjectStore

/// The `publishes` ledger of publish-plan.md section 4.2 and the `RenderLedger` / `PublishLedger`
/// conformances, against both SQLite backends and, for the shared scenario, the fake as well.
@Suite struct PublishesTests {
    /// A fixture store plus its ledgers reached the way a tool reaches them: through the existentials.
    private struct Ledgers {
        let t: TestStore
        let renders: any RenderLedger
        let publishes: any PublishLedger
        let sequenceId: SequenceID
        let version: Int64
    }

    private func ledgers(_ backend: Backend) async throws -> Ledgers {
        let t = try await Stores.fixture(on: backend)
        let base: any ProjectStore = t.store
        let state = await t.store.state()
        return Ledgers(
            t: t, renders: try #require(base as? any RenderLedger), publishes: try #require(base as? any PublishLedger),
            sequenceId: try #require(state.activeSequenceId), version: state.version)
    }

    /// A real export file of `bytes` bytes, so `bytesTotal` has something to read.
    private func exportFile(in dir: TempDir, bytes: Int = 1234) throws -> URL {
        let url = dir.file("export.mp4")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    private var uploadSession: PublishSession {
        PublishSession(
            uploadURL: URL(
                string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=SECRET")!,
            totalBytes: 1234, bytesConfirmed: 512, startedAt: Fixtures.fixtureDate)
    }

    // MARK: Rows

    @Test(arguments: Backend.allCases) func publishesTableHoldsRowsOutsideTheEvents(_ backend: Backend) async throws {
        let l = try await ledgers(backend)
        let dir = TempDir("exports")
        let fileURL = try exportFile(in: dir)
        let changes = l.t.store.changes
        let watcher = Task { await changes.first { _ in true } }
        let eventsBefore = try await l.t.store.events(since: 0).count
        try await l.t.store.flush()  // the fixture import left a debounced state write pending

        let render = try await l.renders.recordRender(
            id: nil, sequenceId: l.sequenceId, preset: .h264_1080p, projectVersion: nil)
        var request = Fixtures.publishRequest(renderId: render.id, fileURL: fileURL)
        request.projectVersion = nil
        let publish = try await l.publishes.recordPublish(id: nil, request: request, projectVersion: nil)
        #expect(publish.status == .queued && publish.completedAt == nil)
        #expect(publish.renderId == render.id && publish.destination == .youtube && publish.accountId == "sub-1")
        #expect(publish.request == request, "the request round-trips through the JSON column")
        #expect(publish.projectVersion == l.version, "nil copies the render row's version")
        #expect(publish.bytesTotal == 1234, "bytesTotal is read from the file")
        #expect(publish.session == nil && publish.bytesSent == nil && publish.receipt == nil && publish.error == nil)
        #expect(try await l.publishes.publish(publish.id) == publish)
        #expect(try await l.publishes.publishes() == [publish])

        // A missing file leaves bytesTotal nil; an explicit version wins over the render's.
        let missing = try await l.publishes.recordPublish(
            id: "p-missing", request: Fixtures.publishRequest(renderId: render.id), projectVersion: 7)
        #expect(missing.bytesTotal == nil && missing.projectVersion == 7 && missing.id == "p-missing")

        // Every status, in one write each: only the terminal ones stamp completed_at.
        for status in PublishStatus.allCases {
            let row = try await l.publishes.recordPublish(
                id: "p-\(status.rawValue)", request: request, projectVersion: nil)
            let updated = try await l.publishes.updatePublish(row.id, PublishUpdate(status: status))
            #expect(updated.status == status, "\(status)")
            #expect((updated.completedAt != nil) == status.isTerminal, "\(status)")
            let stored: String? = try l.t.store.scalar(
                "SELECT completed_at FROM publishes WHERE publish_id = ?", [row.id])
            #expect((stored != nil) == status.isTerminal, "\(status)")
            #expect(try await l.publishes.publish(row.id) == updated)
        }
        // An update without a status leaves status and completed_at alone.
        let partial = try await l.publishes.updatePublish(publish.id, PublishUpdate(bytesSent: 12, error: "later"))
        #expect(partial.status == .queued && partial.completedAt == nil)
        #expect(partial.bytesSent == 12 && partial.error == "later")

        // Operational rows: no event, no version bump, no ProjectChange.
        #expect(await l.t.store.version() == l.version)
        #expect(try await l.t.store.events(since: 0).count == eventsBefore)
        #expect(!(await l.t.store.isStateWritePending), "the ledger never dirties the state row")
        watcher.cancel()
        #expect(await watcher.value == nil, "ledgers never publish a ProjectChange")

        // STRICT and CHECKed, like every other table.
        let strict = #expect(throws: DatabaseError.self) {
            try l.t.store.writer.write { db in
                try db.execute(
                    sql: "UPDATE publishes SET bytes_total = 'many' WHERE publish_id = ?", arguments: [publish.id])
            }
        }
        #expect(strict?.extendedResultCode == .SQLITE_CONSTRAINT_DATATYPE)
        let check = #expect(throws: DatabaseError.self) {
            try l.t.store.writer.write { db in
                try db.execute(
                    sql: "UPDATE publishes SET status = 'sent' WHERE publish_id = ?", arguments: [publish.id])
            }
        }
        #expect(check?.extendedResultCode == .SQLITE_CONSTRAINT_CHECK)
        try await l.t.store.close()
    }

    @Test(arguments: Backend.allCases) func publishRowsLinkToRendersAndRefuseUnknownRenders(_ backend: Backend)
        async throws
    {
        let l = try await ledgers(backend)
        // Without a version to copy, the lookup refuses the unknown render.
        await #expect(throws: ProjectStoreError.storage("No render with id render-1")) {
            _ = try await l.publishes.recordPublish(
                id: nil, request: Fixtures.publishRequest(renderId: "render-1"), projectVersion: nil)
        }
        // With one, the insert reaches SQLite and the foreign key refuses it; it surfaces the same way.
        await #expect(throws: ProjectStoreError.storage("No render with id render-1")) {
            _ = try await l.publishes.recordPublish(
                id: nil, request: Fixtures.publishRequest(renderId: "render-1"), projectVersion: 3)
        }
        #expect(try await l.publishes.publishes().isEmpty, "nothing was written")
        // The constraint itself, for a row written behind the store's back.
        let forged = #expect(throws: DatabaseError.self) {
            try l.t.store.writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO publishes (publish_id, render_id, destination, account_id, requested_at, status,
                          request, project_version)
                        VALUES ('p-forged', 'render-1', 'youtube', 'sub-1', '2026-09-09T00:00:00.000Z', 'queued', '{}', 1)
                        """)
            }
        }
        #expect(forged?.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY)

        let a = try await l.renders.recordRender(
            id: "r-a", sequenceId: l.sequenceId, preset: .h264_1080p, projectVersion: nil)
        let b = try await l.renders.recordRender(
            id: "r-b", sequenceId: l.sequenceId, preset: .reel9x16, projectVersion: nil)
        let p1 = try await l.publishes.recordPublish(
            id: "p-1", request: Fixtures.publishRequest(renderId: a.id), projectVersion: nil)
        let p2 = try await l.publishes.recordPublish(
            id: "p-2", request: Fixtures.publishRequest(renderId: a.id), projectVersion: nil)
        let p3 = try await l.publishes.recordPublish(
            id: "p-3", request: Fixtures.publishRequest(renderId: b.id), projectVersion: nil)
        #expect(try await l.publishes.publishes(forRender: a.id) == [p2, p1])
        #expect(try await l.publishes.publishes(forRender: b.id) == [p3])
        #expect(try await l.publishes.publishes(forRender: "nope").isEmpty)
        #expect(try await l.publishes.publishes() == [p3, p2, p1])
        #expect(try await l.publishes.publish("missing") == nil)
        #expect(try await l.renders.render("missing") == nil)
        await #expect(throws: ProjectStoreError.storage("No publish with id missing")) {
            _ = try await l.publishes.updatePublish("missing", PublishUpdate(status: .done))
        }
        await #expect(throws: ProjectStoreError.storage("No render with id missing")) {
            _ = try await l.renders.updateRender(
                "missing", status: .done, outputURL: nil, outputHash: nil, receipt: nil)
        }
        try await l.t.store.close()
    }

    @Test(arguments: Backend.allCases) func publishesForRenderAreNewestFirst(_ backend: Backend) async throws {
        let l = try await ledgers(backend)
        let a = try await l.renders.recordRender(
            id: "r-a", sequenceId: l.sequenceId, preset: .h264_1080p, projectVersion: nil)
        let b = try await l.renders.recordRender(
            id: "r-b", sequenceId: l.sequenceId, preset: .h264_1080p, projectVersion: nil)
        var ids: [String] = []
        for i in 1...4 {
            let render = i == 3 ? b : a
            ids.append(
                try await l.publishes.recordPublish(
                    id: "p-\(i)", request: Fixtures.publishRequest(renderId: render.id), projectVersion: nil
                ).id)
        }
        // The fixture clock steps one second per call, so requested_at orders them.
        let all = try await l.publishes.publishes()
        #expect(all.map(\.id) == ["p-4", "p-3", "p-2", "p-1"])
        #expect(all.map(\.requestedAt) == all.map(\.requestedAt).sorted(by: >))
        #expect(try await l.publishes.publishes(forRender: a.id).map(\.id) == ["p-4", "p-2", "p-1"])
        #expect(try await l.publishes.publishes(forRender: b.id).map(\.id) == ["p-3"])
        // The per-render query uses its index.
        let plan: [String] = try await l.t.store.writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM publishes WHERE render_id = 'r-a'")
                .map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("publishes_render_idx") })
        try await l.t.store.close()

        // Equal timestamps fall back to the id, descending, like `renders()`.
        let frozen = try Stores.blank(backend, clock: FixedClock(step: 0))
        let base: any ProjectStore = frozen.store
        let renders = try #require(base as? any RenderLedger)
        let publishes = try #require(base as? any PublishLedger)
        _ = try await renders.recordRender(id: "r", sequenceId: "seq", preset: .proRes, projectVersion: 0)
        for id in ["p-b", "p-c", "p-a"] {
            _ = try await publishes.recordPublish(
                id: id, request: Fixtures.publishRequest(renderId: "r"), projectVersion: nil)
        }
        #expect(try await publishes.publishes().map(\.id) == ["p-c", "p-b", "p-a"])
        #expect(try await publishes.publishes(forRender: "r").map(\.id) == ["p-c", "p-b", "p-a"])
        #expect(Set(try await publishes.publishes().map(\.requestedAt)).count == 1)
        try await frozen.store.close()
    }

    @Test(arguments: Backend.allCases) func clearsSessionRemovesTheCapabilityURL(_ backend: Backend) async throws {
        let l = try await ledgers(backend)
        let render = try await l.renders.recordRender(
            id: "r-1", sequenceId: l.sequenceId, preset: .h264_1080p, projectVersion: nil)
        let publish = try await l.publishes.recordPublish(
            id: "p-1", request: Fixtures.publishRequest(renderId: render.id), projectVersion: nil)
        let session = uploadSession
        let uploading = try await l.publishes.updatePublish(
            publish.id, PublishUpdate(status: .uploading, session: session, bytesSent: 512))
        #expect(uploading.session == session && uploading.bytesSent == 512 && uploading.status == .uploading)
        let storedSession: String? = try l.t.store.scalar("SELECT session FROM publishes WHERE publish_id = 'p-1'")
        #expect(storedSession?.contains("upload_id=SECRET") == true, "the session column is where the URL lives")

        let remoteURL = URL(string: "https://youtu.be/fake-video-1")!
        let processing = try await l.publishes.updatePublish(
            publish.id, PublishUpdate(status: .processing, remoteId: "fake-video-1", remoteURL: remoteURL))
        #expect(processing.session == session, "nil leaves the session alone")
        #expect(processing.remoteId == "fake-video-1" && processing.remoteURL == remoteURL)

        let done = try await l.publishes.updatePublish(
            publish.id, PublishUpdate(status: .done, clearsSession: true, receipt: Fixtures.publishReceipt()))
        #expect(done.session == nil && done.receipt == Fixtures.publishReceipt() && done.completedAt != nil)
        #expect(!done.isResumable)
        #expect(try await l.publishes.publish(publish.id) == done)
        let cleared: String? = try l.t.store.scalar("SELECT session FROM publishes WHERE publish_id = 'p-1'")
        #expect(cleared == nil)
        // Nothing left in the row mentions the capability URL.
        let rowText: [Row] = try l.t.store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM publishes WHERE publish_id = 'p-1'")
        }
        #expect(!rowText.description.contains("upload_id"))
        #expect(!rowText.description.contains("googleapis.com/upload"))

        // A failed upload keeps its session so it can resume; clearsSession beats a session in the same update.
        let failed = try await l.publishes.recordPublish(
            id: "p-2", request: Fixtures.publishRequest(renderId: render.id), projectVersion: nil)
        let kept = try await l.publishes.updatePublish(
            failed.id, PublishUpdate(status: .failed, session: session, error: "network"))
        #expect(kept.isResumable && kept.session == session && kept.error == "network")
        let dropped = try await l.publishes.updatePublish(
            failed.id, PublishUpdate(status: .cancelled, session: session, clearsSession: true))
        #expect(dropped.session == nil && !dropped.isResumable)
        try await l.t.store.close()
    }

    // MARK: Conformance

    @Test(arguments: Backend.allCases) func renderLedgerConformanceThroughTheExistential(_ backend: Backend)
        async throws
    {
        let l = try await ledgers(backend)
        let changes = l.t.store.changes
        let watcher = Task { await changes.first { _ in true } }

        let render = try await l.renders.recordRender(
            id: nil, sequenceId: l.sequenceId, preset: .h264_1080p, projectVersion: nil)
        #expect(render.status == .queued && render.projectVersion == l.version && render.completedAt == nil)
        #expect(render.sequenceId == l.sequenceId && render.preset == .h264_1080p)
        #expect(render.outputURL == nil && render.outputHash == nil && render.receipt == nil)
        let running = try await l.renders.updateRender(
            render.id, status: .running, outputURL: nil, outputHash: nil, receipt: nil)
        #expect(running.status == .running && running.completedAt == nil)

        let url = URL(fileURLWithPath: "/tmp/Exports/three-clips-h264_1080p.mp4")
        let receipt = ExportReceipt(
            preset: .h264_1080p, sequenceId: l.sequenceId, projectVersion: l.version, outputURL: url,
            durationSeconds: 12, startedAt: Fixtures.fixtureDate, finishedAt: Fixtures.fixtureDate,
            warnings: ["asset offline"], outputHash: "sha256-abc")
        let done = try await l.renders.updateRender(
            render.id, status: .done, outputURL: url, outputHash: "sha256-abc", receipt: receipt)
        #expect(done.status == .done && done.completedAt != nil)
        #expect(done.outputURL == url && done.outputHash == "sha256-abc" && done.receipt == receipt)
        #expect(try await l.renders.render(render.id) == done)
        #expect(try await l.renders.render("missing") == nil)
        // Later nils leave the stored output and receipt alone.
        let again = try await l.renders.updateRender(
            render.id, status: .done, outputURL: nil, outputHash: nil, receipt: nil)
        #expect(again.outputURL == url && again.outputHash == "sha256-abc" && again.receipt == receipt)

        // The row underneath: output_path absolute, preset and receipt as ProjectCodec JSON.
        let row = try #require(try await l.t.store.renderRow(render.id))
        #expect(row.outputPath == "/tmp/Exports/three-clips-h264_1080p.mp4")
        #expect(row.status == .done && row.projectVersion == l.version)
        #expect(try ProjectCodec.decode(ExportPreset.self, from: Data(row.preset.utf8)) == .h264_1080p)
        #expect(try ProjectCodec.decode(ExportReceipt.self, from: Data(try #require(row.receipt).utf8)) == receipt)
        #expect(try row.record() == again)

        let older = try await l.renders.recordRender(
            id: "r-explicit", sequenceId: l.sequenceId, preset: .reel9x16, projectVersion: 3)
        #expect(older.id == "r-explicit" && older.projectVersion == 3)
        #expect(try await l.renders.renders().map(\.id) == ["r-explicit", render.id], "newest first")
        #expect(try await l.t.store.renderRows().map(\.renderId) == ["r-explicit", render.id])
        for status in RenderStatus.allCases {
            let r = try await l.renders.recordRender(
                id: nil, sequenceId: l.sequenceId, preset: .proRes, projectVersion: nil)
            let u = try await l.renders.updateRender(
                r.id, status: status, outputURL: nil, outputHash: nil, receipt: nil)
            #expect((u.completedAt != nil) == status.isTerminal && u.status == status, "\(status)")
        }

        #expect(await l.t.store.version() == l.version)
        watcher.cancel()
        #expect(await watcher.value == nil)
        try await l.t.store.close()
        await #expect(throws: ProjectStoreError.closed) { _ = try await l.renders.renders() }
    }

    @Test(arguments: Backend.allCases) func publishLedgerConformanceThroughTheExistential(_ backend: Backend)
        async throws
    {
        let l = try await ledgers(backend)
        let base: any ProjectStore = l.t.store
        #expect(base as? any ProjectStoreCopying != nil, "Fork's cast still works alongside the ledgers")
        let render = try await l.renders.recordRender(
            id: "r-1", sequenceId: l.sequenceId, preset: .h264_1080p, projectVersion: nil)
        let request = Fixtures.publishRequest(renderId: render.id)
        let publish = try await l.publishes.recordPublish(id: nil, request: request, projectVersion: nil)
        #expect(publish.id.isCanonicalUUID, "nil mints from the store's generator")
        #expect(publish.request == request && publish.projectVersion == l.version)
        let explicit = try await l.publishes.recordPublish(id: "p-explicit", request: request, projectVersion: 7)
        #expect(explicit.id == "p-explicit" && explicit.projectVersion == 7)
        #expect(try await l.publishes.publishes().map(\.id) == ["p-explicit", publish.id])
        #expect(try await l.publishes.publishes(forRender: render.id).map(\.id) == ["p-explicit", publish.id])
        #expect(try await l.publishes.publish(publish.id) == publish)
        let done = try await l.publishes.updatePublish(
            publish.id,
            PublishUpdate(
                status: .done, remoteId: "fake-video-1", remoteURL: URL(string: "https://youtu.be/fake-video-1"),
                receipt: Fixtures.publishReceipt()))
        #expect(done.status == .done && done.completedAt != nil && done.receipt == Fixtures.publishReceipt())
        #expect(try await l.publishes.publish(publish.id) == done)
        // The same rows through the store's own row-level accessor.
        let rows = try await l.t.store.publishRows()
        #expect(rows.map(\.publishId) == ["p-explicit", publish.id])
        #expect(rows[1].status == .done && rows[1].remoteId == "fake-video-1")
        #expect(try rows.map { try $0.record() } == [explicit, done])
        try await l.t.store.close()
        await #expect(throws: ProjectStoreError.closed) { _ = try await l.publishes.publishes() }
        await #expect(throws: ProjectStoreError.closed) {
            _ = try await l.publishes.recordPublish(id: nil, request: request, projectVersion: nil)
        }
    }

    // MARK: Migration, copies, rebuild

    @Test func v1DatabaseMigratesToV2WithABackup() async throws {
        let dir = TempDir("v1")
        let package = ProjectPackage(url: dir.file("Old.tlproj"))
        try package.createDirectories()
        let builder = try Fixtures.builder("three-clips")

        // A database as the v1 app left it: only "v1" applied, a project in it, one finished render.
        var v1 = DatabaseMigrator()
        v1.registerMigration("v1") { db in
            try db.execute(sql: Schema.v1)
            try db.execute(sql: "PRAGMA user_version = 1")
        }
        let queue = try DatabaseQueue(
            path: package.databaseURL.path, configuration: Schema.configuration(journal: .wal, label: "v1"))
        try v1.migrate(queue)
        let oldRender = RenderRow(
            renderId: "r-old", requestedAt: "2026-09-01T10:00:00.000Z", completedAt: "2026-09-01T10:01:00.000Z",
            sequenceId: builder.sequenceId.rawValue,
            preset: String(decoding: try ProjectCodec.encode(ExportPreset.h264_1080p), as: UTF8.self),
            outputPath: "/tmp/Exports/old.mp4", outputHash: "sha256-old", projectVersion: 3, status: .done,
            receipt: nil)
        let transactions = Transaction.group(builder.events, labels: Stores.labels(of: builder.history))
        let hadPublishes = try await queue.write { db in
            // Today's projection writer fills `tracks.solo`, which v1 has no column for, so the column is
            // borrowed for the write and dropped again: the file this test opens is genuinely at v1.
            try db.execute(sql: Schema.v3)
            _ = try WritePath.importTransactions(db, transactions, state: .blank, history: History())
            try db.execute(sql: "ALTER TABLE tracks DROP COLUMN solo")
            try oldRender.insert(db)
            return try db.tableExists("publishes")
        }
        #expect(!hadPublishes)
        try queue.close()
        try package.writeManifest(
            ProjectManifest(projectId: builder.project.id, libraryRootHint: nil, createdAt: Fixtures.fixtureDate))
        let backups = {
            (try? FileManager.default.contentsOfDirectory(atPath: package.url.path))?
                .filter { $0.hasPrefix("project.sqlite.pre-migration-") && $0.hasSuffix(".bak") } ?? []
        }
        #expect(backups().isEmpty)

        // Opening through the opener migrates: the table appears, the rows survive, a backup was taken first.
        let opener = SQLiteProjectStoreOpener(ids: builder.ids, clock: builder.clock)
        let store = try await opener.openStore(at: package.url)
        #expect(try store.scalar("PRAGMA user_version") == Schema.currentUserVersion)
        let migrations: [String] = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(migrations == ["v1", "v2", "v3"])
        #expect(await store.state() == builder.project)
        #expect(try await store.renderRow("r-old") == oldRender)
        let record = try #require(try await store.render("r-old"))
        #expect(record.status == .done && record.outputURL == URL(fileURLWithPath: "/tmp/Exports/old.mp4"))
        #expect(record.outputHash == "sha256-old" && record.projectVersion == 3 && record.completedAt != nil)
        #expect(try await store.publishes().isEmpty)
        let publish = try await store.recordPublish(
            id: "p-new", request: Fixtures.publishRequest(renderId: "r-old"), projectVersion: nil)
        #expect(publish.projectVersion == 3, "copied from the v1 render row")
        #expect(backups().count == 1)
        let backup = try DatabaseQueue(path: package.url.appendingPathComponent(try #require(backups().first)).path)
        let (backupVersion, backupHasPublishes, backupRenders): (Int?, Bool, Int?) = try await backup.read { db in
            (
                try Int.fetchOne(db, sql: "PRAGMA user_version"), try db.tableExists("publishes"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM renders")
            )
        }
        try backup.close()
        #expect(backupVersion == 1 && !backupHasPublishes && backupRenders == 1, "the backup is the v1 file")
        try await store.close()

        // A second open has nothing to migrate and takes no second backup.
        let again = try await opener.openStore(at: package.url)
        #expect(backups().count == 1)
        #expect(try await again.publishes().map(\.id) == ["p-new"])
        try await again.close()
    }

    @Test func saveAsCarriesPublishes() async throws {
        let t = try await Stores.fixture(on: .disk)
        let dir = try #require(t.dir)
        let state = await t.store.state()
        let sequenceId = try #require(state.activeSequenceId)
        let render = try await t.store.recordRender(
            id: "r-1", sequenceId: sequenceId, preset: .h264_1080p, projectVersion: nil)
        let done = try await t.store.updateRender(
            render.id, status: .done, outputURL: dir.file("out.mp4"), outputHash: "sha256-abc", receipt: nil)
        let request = Fixtures.publishRequest(renderId: render.id, fileURL: dir.file("out.mp4"))
        let queued = try await t.store.recordPublish(id: "p-1", request: request, projectVersion: nil)
        let published = try await t.store.updatePublish(
            "p-1",
            PublishUpdate(
                status: .done, clearsSession: true, remoteId: "fake-video-1",
                remoteURL: URL(string: "https://youtu.be/fake-video-1"), receipt: Fixtures.publishReceipt()))
        let interrupted = try await t.store.updatePublish(
            try await t.store.recordPublish(id: "p-2", request: request, projectVersion: nil).id,
            PublishUpdate(status: .failed, session: uploadSession, bytesSent: 512, error: "network"))
        #expect(queued.status == .queued && interrupted.isResumable)

        // Save As: a fork's history shows the parent's renders and uploads.
        let copy = dir.file("Copy.tlproj")
        try await t.store.saveAs(to: copy)
        let opener = SQLiteProjectStoreOpener(ids: t.ids, clock: t.clock)
        let opened = try await opener.openStore(at: copy)
        #expect(await opened.state() == state)
        #expect(try await opened.renders() == [done])
        #expect(try await opened.publishes() == [interrupted, published])
        #expect(try await opened.publishes(forRender: "r-1") == [interrupted, published])
        #expect(try await opened.publishRows() == (try await t.store.publishRows()))
        // The copy is its own ledger from here on.
        _ = try await opened.updatePublish("p-2", PublishUpdate(status: .cancelled, clearsSession: true))
        #expect(try await t.store.publish("p-2") == interrupted)
        try await opened.close()

        // Backup: the same rows, through VACUUM INTO.
        let backup = dir.file("nested/backup.sqlite")
        try await t.store.backup(to: backup)
        let queue = try DatabaseQueue(path: backup.path)
        let rows = try await queue.read { db in
            try PublishRow.fetchAll(db, sql: "SELECT * FROM publishes ORDER BY publish_id")
        }
        try queue.close()
        #expect(rows.map(\.publishId) == ["p-1", "p-2"])
        #expect(try rows.map { try $0.record() } == [published, interrupted])
        try await t.store.close()
    }

    @Test(arguments: Backend.allCases) func rebuildLeavesPublishesAlone(_ backend: Backend) async throws {
        #expect(!Schema.queryTablesInDeleteOrder.contains("renders"))
        #expect(!Schema.queryTablesInDeleteOrder.contains("publishes"))
        let l = try await ledgers(backend)
        let render = try await l.renders.recordRender(
            id: "r-1", sequenceId: l.sequenceId, preset: .h264_1080p, projectVersion: nil)
        let request = Fixtures.publishRequest(renderId: render.id)
        _ = try await l.publishes.recordPublish(id: "p-1", request: request, projectVersion: nil)
        _ = try await l.publishes.updatePublish("p-1", PublishUpdate(status: .uploading, session: uploadSession))
        _ = try await l.publishes.recordPublish(id: "p-2", request: request, projectVersion: nil)
        let renders = try await l.renders.renders()
        let publishes = try await l.publishes.publishes()
        try await l.t.store.flush()
        let before = try l.t.store.projectionSnapshot()
        let state = await l.t.store.state()

        try await l.t.store.rebuildProjections()
        #expect(await l.t.store.state() == state)
        #expect(try l.t.store.projectionSnapshot() == before)
        #expect(try await l.renders.renders() == renders)
        #expect(try await l.publishes.publishes() == publishes)
        #expect(try await l.publishes.publish("p-1")?.session == uploadSession, "a resumable session survives")

        // And the same after a projection bug is recovered on open (disk only: it reopens the file).
        if backend == .disk, let dir = l.t.dir {
            try await l.t.store.flush()
            try await l.t.store.close()
            let queue = try DatabaseQueue(path: dir.file("project.sqlite").path)
            try await queue.write { db in
                try db.execute(sql: "DELETE FROM clips; DELETE FROM history")
                try db.execute(
                    sql: "UPDATE projection_state SET last_seq = 1 WHERE name IN ('query_tables', 'history')")
            }
            try queue.close()
            let reopened = try SQLiteProjectStore(
                databaseAt: dir.file("project.sqlite").path, ids: l.t.ids, clock: l.t.clock)
            #expect(reopened.recovery.projectionsRebuilt)
            #expect(try await reopened.renders() == renders)
            #expect(try await reopened.publishes() == publishes)
            try await reopened.close()
        } else {
            try await l.t.store.close()
        }
    }

    @Test(arguments: Backend.allCases) func receiptJSONNeverContainsTheUploadURL(_ backend: Backend) async throws {
        let l = try await ledgers(backend)
        let render = try await l.renders.recordRender(
            id: "r-1", sequenceId: l.sequenceId, preset: .h264_1080p, projectVersion: nil)
        let publish = try await l.publishes.recordPublish(
            id: "p-1", request: Fixtures.publishRequest(renderId: render.id), projectVersion: nil)
        _ = try await l.publishes.updatePublish(publish.id, PublishUpdate(status: .uploading, session: uploadSession))
        let receipt = Fixtures.publishReceipt(publishId: publish.id)
        let done = try await l.publishes.updatePublish(
            publish.id,
            PublishUpdate(
                status: .done, clearsSession: true, remoteId: receipt.remoteId, remoteURL: receipt.remoteURL,
                receipt: receipt))
        #expect(done.receipt == receipt && done.session == nil)

        let uploadURL = uploadSession.uploadURL.absoluteString
        let columns: Row = try #require(
            try l.t.store.writer.read { db in
                try Row.fetchOne(db, sql: "SELECT request, session, receipt FROM publishes WHERE publish_id = 'p-1'")
            })
        let receiptJSON: String = try #require(columns["receipt"])
        #expect(try ProjectCodec.decode(PublishReceipt.self, from: Data(receiptJSON.utf8)) == receipt)
        #expect(!receiptJSON.contains(uploadURL) && !receiptJSON.contains("upload_id"))
        #expect(!receiptJSON.contains("uploadURL") && !receiptJSON.contains("session"), "a receipt has no such fields")
        #expect(receiptJSON.contains("https://youtu.be/"), "the public URL is what a receipt carries")
        let requestJSON: String = try #require(columns["request"])
        #expect(!requestJSON.contains(uploadURL) && !requestJSON.contains("upload_id"))
        #expect((columns["session"] as String?) == nil)
        // What a tool would hand back: the whole record, encoded.
        let recordJSON = String(decoding: try ProjectCodec.encode(done), as: UTF8.self)
        #expect(!recordJSON.contains(uploadURL) && !recordJSON.contains("upload_id"))
        try await l.t.store.close()
    }

    // MARK: Shared scenario

    /// Where the shared scenario runs: the fake, and SQLite on both backends.
    enum LedgerHost: String, CaseIterable, Sendable {
        case fake
        case memory
        case disk
    }

    /// One transcript of the ledgers' observable behaviour, so the three implementations can be compared.
    private static func scenario(_ store: any ProjectStore, fileURL: URL) async throws -> [String] {
        let renders = try #require(store as? any RenderLedger)
        let publishes = try #require(store as? any PublishLedger)
        let state = await store.state()
        let sequenceId = try #require(state.activeSequenceId)
        let version = state.version
        let changes = store.changes
        let watcher = Task { await changes.first { _ in true } }
        var log: [String] = []
        func note(_ line: String) { log.append(line) }

        let render = try await renders.recordRender(
            id: nil, sequenceId: sequenceId, preset: .h264_1080p, projectVersion: nil)
        note("render \(render.id) \(render.status) v\(render.projectVersion) done=\(render.completedAt != nil)")
        let outputURL = URL(fileURLWithPath: "/tmp/Exports/scenario.mp4")
        let receipt = ExportReceipt(
            preset: .h264_1080p, sequenceId: sequenceId, projectVersion: version, outputURL: outputURL,
            durationSeconds: 12, startedAt: Fixtures.fixtureDate, finishedAt: Fixtures.fixtureDate,
            outputHash: "sha256-abc")
        let done = try await renders.updateRender(
            render.id, status: .done, outputURL: outputURL, outputHash: "sha256-abc", receipt: receipt)
        note(
            "render \(done.status) done=\(done.completedAt != nil) \(done.outputURL?.path ?? "-") \(done.outputHash ?? "-")"
        )
        note("render receipt=\(done.receipt == receipt) fetched=\(try await renders.render(render.id) == done)")
        let older = try await renders.recordRender(
            id: "r-explicit", sequenceId: sequenceId, preset: .reel9x16, projectVersion: 3)
        note("renders \(try await renders.renders().map(\.id)) \(older.projectVersion)")

        do {
            _ = try await publishes.recordPublish(
                id: nil, request: Fixtures.publishRequest(renderId: "nope"), projectVersion: nil)
            note("unknown render accepted")
        } catch {
            note("unknown render refused")
        }
        var request = Fixtures.publishRequest(renderId: render.id, fileURL: fileURL)
        request.projectVersion = nil
        let publish = try await publishes.recordPublish(id: nil, request: request, projectVersion: nil)
        note("publish \(publish.id) \(publish.status) v\(publish.projectVersion) bytes=\(publish.bytesTotal ?? -1)")
        note("publish request=\(publish.request == request) render=\(publish.renderId == render.id)")
        let session = PublishSession(
            uploadURL: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=abc")!,
            totalBytes: 1234, bytesConfirmed: 100, startedAt: Fixtures.fixtureDate)
        let uploading = try await publishes.updatePublish(
            publish.id, PublishUpdate(status: .uploading, session: session, bytesSent: 100))
        note("uploading \(uploading.status) session=\(uploading.session == session) sent=\(uploading.bytesSent ?? -1)")
        let finished = try await publishes.updatePublish(
            publish.id,
            PublishUpdate(
                status: .done, clearsSession: true, remoteId: "fake-video-1",
                remoteURL: URL(string: "https://youtu.be/fake-video-1"), receipt: Fixtures.publishReceipt()))
        note("done \(finished.status) session=\(finished.session == nil) done=\(finished.completedAt != nil)")
        note("done receipt=\(finished.receipt == Fixtures.publishReceipt()) \(finished.remoteId ?? "-")")
        for status in PublishStatus.allCases {
            let p = try await publishes.recordPublish(id: "p-\(status.rawValue)", request: request, projectVersion: 5)
            let u = try await publishes.updatePublish(p.id, PublishUpdate(status: status))
            note("\(status) v\(u.projectVersion) done=\(u.completedAt != nil)")
        }
        do {
            _ = try await publishes.updatePublish("missing", PublishUpdate(status: .done))
            note("unknown publish accepted")
        } catch {
            note("unknown publish refused")
        }
        note("publishes \(try await publishes.publishes().map(\.id))")
        note("forRender \(try await publishes.publishes(forRender: render.id).map(\.id))")
        note("forOther \(try await publishes.publishes(forRender: "r-explicit").map(\.id))")
        note(
            "fetched=\(try await publishes.publish(publish.id) == finished) missing=\(try await publishes.publish("x") == nil)"
        )
        note(
            "version \(await store.version() == version) events \(try await store.events(since: 0).count == Int(version))"
        )
        watcher.cancel()
        note("change=\(await watcher.value != nil)")
        try await store.rebuildProjections()
        note("after rebuild \(try await publishes.publishes().count) \(try await renders.renders().count)")
        try await store.close()
        return log
    }

    @Test(arguments: LedgerHost.allCases) func ledgerScenarioAgreesAcrossImplementations(_ host: LedgerHost)
        async throws
    {
        let dir = TempDir("scenario")
        let fileURL = try exportFile(in: dir)
        let expected = try await Self.scenario(Stores.fake(), fileURL: fileURL)
        let transcript: [String]
        switch host {
        case .fake:
            transcript = expected
        case .memory:
            transcript = try await Self.scenario(Stores.fixture(on: .memory).store, fileURL: fileURL)
        case .disk:
            let t = try await Stores.fixture(on: .disk)
            transcript = try await Self.scenario(t.store, fileURL: fileURL)
        }
        #expect(transcript == expected)
        #expect(transcript.contains("unknown render refused") && transcript.contains("unknown publish refused"))
        #expect(transcript.contains { $0.hasPrefix("publish ") && $0.contains("bytes=1234") })
        #expect(transcript.contains("change=false"))
        #expect(transcript.count == 24)
    }
}
