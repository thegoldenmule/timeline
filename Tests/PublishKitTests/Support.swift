import Contracts
import ContractsTestSupport
import Foundation
import Synchronization
import TimelineCore

@testable import PublishKit

let mib: Int64 = 1 << 20

/// A fresh temporary directory per test.
func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "publishkit-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A file of random bytes written through `FileHandle` in 1 MiB pieces (never `TestMedia`).
@discardableResult
func randomFile(bytes: Int64, in directory: URL, name: String = "export.mp4") throws -> URL {
    let url = directory.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var remaining = bytes
    while remaining > 0 {
        let count = Int(min(remaining, mib))
        var piece = Data(count: count)
        piece.withUnsafeMutableBytes { buffer in
            for i in stride(from: 0, to: buffer.count, by: 512) { buffer[i] = UInt8.random(in: 0...255) }
            if buffer.count > 0 { buffer[buffer.count - 1] = UInt8.random(in: 0...255) }
        }
        try handle.write(contentsOf: piece)
        remaining -= Int64(count)
    }
    return url
}

/// A JPEG-looking file (magic bytes then random data) for thumbnail tests.
func jpegFile(bytes: Int, in directory: URL, name: String = "thumb.jpg") throws -> URL {
    let url = directory.appendingPathComponent(name)
    var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
    data.append(Data(count: max(0, bytes - 4)))
    try data.write(to: url)
    return url
}

/// Records every backoff and poll interval instead of sleeping.
final class SleepRecorder: Sendable {
    private let slept = Mutex<[Duration]>([])
    var durations: [Duration] { slept.withLock { $0 } }
    var count: Int { durations.count }
    func sleeper() -> Sleeper { { [self] duration in slept.withLock { $0.append(duration) } } }
}

/// Records every `PublishEvent` a job emits.
final class EventLog: Sendable {
    private let all = Mutex<[PublishEvent]>([])
    var events: [PublishEvent] { all.withLock { $0 } }
    var sessions: [PublishSession] {
        events.compactMap {
            if case .session(let session) = $0 { return session }
            return nil
        }
    }
    var stages: [PublishStage] {
        events.compactMap {
            if case .stage(let stage) = $0 { return stage }
            return nil
        }
    }
    var uploaded: (String, URL)? {
        for event in events {
            if case .uploaded(let id, let url) = event { return (id, url) }
        }
        return nil
    }
    func append(_ event: PublishEvent) { all.withLock { $0.append(event) } }
}

/// An `AccountProvider` whose tokens the `FakeYouTubeServer` accepts: every `accessToken` call asks the
/// server for a fresh bearer bound to `sub`, so a 401 refresh is observable as `tokenRequests`.
actor ServerBackedAccounts: AccountProvider {
    nonisolated let kind: AccountProviderKind = .google
    nonisolated let isConfigured = true
    private let server: FakeYouTubeServer
    private let sub: String
    private let broadcaster = Broadcaster<[ConnectedAccount]>()
    private(set) var tokenRequests = 0
    private(set) var connected: [ConnectedAccount]
    private var reauthorizationReason: String?
    private var cached: AccessToken?

    init(server: FakeYouTubeServer, account: ConnectedAccount = Fixtures.connectedGoogleAccount) {
        self.server = server
        self.sub = account.id
        self.connected = [account]
    }

    func accounts() -> [ConnectedAccount] { connected }

    @MainActor func connect(scopes: [String], loginHint: String?) async throws -> ConnectedAccount {
        throw AccountError.protocolError("ServerBackedAccounts does not connect")
    }

    func disconnect(_ id: String) throws { connected.removeAll { $0.id == id } }

    func refresh(_ id: String) throws -> ConnectedAccount {
        guard let account = connected.first(where: { $0.id == id }) else { throw AccountError.notConnected(id) }
        return account
    }

    func accessToken(for id: String, minimumLifetime: Duration) async throws -> AccessToken {
        guard connected.contains(where: { $0.id == id }) else { throw AccountError.notConnected(id) }
        if let reason = reauthorizationReason { throw AccountError.reauthorizationRequired(reason) }
        if let cached, cached.isValid(for: minimumLifetime) { return cached }
        tokenRequests += 1
        let value = await server.issueAccessToken(for: sub)
        let token = AccessToken(
            value: value, expiresAt: Date().addingTimeInterval(FakeYouTubeServer.accessTokenLifetime),
            scopes: Fixtures.publishScopes)
        cached = token
        return token
    }

    func requireReauthorization(_ reason: String) { reauthorizationReason = reason }

    nonisolated var changes: AsyncStream<[ConnectedAccount]> { broadcaster.subscribe() }
}

/// A seeded fake server, a server-backed account provider, a memory-only quota meter, and a publisher
/// with 1 MiB chunks, millisecond backoff, and a recording sleeper.
struct PublishHarness {
    let server: FakeYouTubeServer
    let accounts: ServerBackedAccounts
    let quota: QuotaMeter
    let sleeps: SleepRecorder
    let options: UploadOptions
    let runner: FakeJobRunner
    let directory: URL
    let publisher: YouTubePublisher

    init(label: String, chunkBytes: Int64 = mib, maxAttempts: Int = 10, audited: Bool = false, quotaFile: URL? = nil)
        async throws
    {
        server = FakeYouTubeServer()
        await server.seedFixtureAccount()
        accounts = ServerBackedAccounts(server: server)
        quota = QuotaMeter(fileURL: quotaFile)
        sleeps = SleepRecorder()
        options = UploadOptions(
            chunkBytes: chunkBytes, maxAttempts: maxAttempts, backoffUnit: .milliseconds(1), maxBackoff: .seconds(64))
        runner = FakeJobRunner()
        directory = try temporaryDirectory(label)
        publisher = YouTubePublisher(
            accounts: accounts, session: URLSession(configuration: server.sessionConfiguration()), quota: quota,
            audited: audited, options: options, sleep: sleeps.sleeper())
    }

    /// A second publisher over the same server, accounts, and quota (a "relaunch").
    func relaunchedPublisher() -> YouTubePublisher {
        YouTubePublisher(
            accounts: accounts, session: URLSession(configuration: server.sessionConfiguration()), quota: quota,
            options: options, sleep: sleeps.sleeper())
    }

    /// `Fixtures.publishRequest` over a random file of `bytes`, with the file's real hash.
    func request(bytes: Int64 = 5 * mib, captions: Bool = true, name: String = "export.mp4") throws -> PublishRequest {
        let url = try randomFile(bytes: bytes, in: directory, name: name)
        var request = Fixtures.publishRequest(renderId: "render-1", fileURL: url)
        request.expectedContentHash = try FileHash.sha256(of: url)
        if !captions { request.captions = [] }
        return request
    }

    struct Run {
        var job: Job
        var handle: JobHandle
        var events: EventLog
        var context: FakeJobContext?

        func receipt() async throws -> PublishReceipt {
            let outcome = try await handle.wait()
            guard let receipt = try outcome.payload(as: PublishReceipt.self) else {
                throw PublishError.uploadFailed(status: 0, reason: "no receipt in the outcome")
            }
            return receipt
        }
    }

    /// Submits a publish job; `onEvent` runs before the log records the event.
    func submit(
        _ request: PublishRequest, publishId: String = "publish-1", resuming: PublishSession? = nil,
        publisher: YouTubePublisher? = nil, onEvent: (@Sendable (PublishEvent) async -> Void)? = nil
    ) async -> Run {
        let log = EventLog()
        let job = (publisher ?? self.publisher).publish(request, publishId: publishId, resuming: resuming) { event in
            await onEvent?(event)
            log.append(event)
        }
        let handle = await runner.submit(job)
        return Run(job: job, handle: handle, events: log, context: await runner.contexts[job.id])
    }

    /// Runs a publish to completion and returns the receipt with the event log.
    func publish(
        _ request: PublishRequest, publishId: String = "publish-1", resuming: PublishSession? = nil,
        onEvent: (@Sendable (PublishEvent) async -> Void)? = nil
    ) async throws -> (PublishReceipt, EventLog) {
        let run = await submit(request, publishId: publishId, resuming: resuming, onEvent: onEvent)
        return (try await run.receipt(), run.events)
    }
}

extension PublishError {
    var isQuotaExceeded: Bool {
        if case .quotaExceeded = self { return true }
        return false
    }
}
