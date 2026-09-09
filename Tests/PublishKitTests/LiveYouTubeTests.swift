import Contracts
import ContractsTestSupport
import Foundation
import Synchronization
import Testing
import TimelineCore

@testable import PublishKit

/// The one opt-in live test (publish-plan.md 4.1, section 7): never in `make test`, never run by the
/// agents. Needs `TIMELINE_LIVE_YOUTUBE=1`, a client configuration (D3), and an account connected
/// through the file token store (`TIMELINE_TOKEN_STORE=file`, `TimelineApp --connect-google`). Uploads a
/// 2 s clip as private, with one SRT caption track and `notifySubscribers=false`, polls until
/// `processed`, sets a thumbnail tolerating `forbidden`, then deletes the video. Cost: one upload call
/// plus about 105 units. With `TIMELINE_LIVE_TRANSCRIPT_OUT` set, writes the scrubbed exchange there for
/// `Transcripts/`.
@Suite(.serialized) struct LiveYouTubeTests {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["TIMELINE_LIVE_YOUTUBE"] == "1" }

    @Test(.enabled(if: LiveYouTubeTests.isEnabled), .timeLimit(.minutes(10)))
    func uploadsAPrivateClipAndDeletesIt() async throws {
        let environment = ProcessInfo.processInfo.environment
        let configuration = try #require(try GoogleClientConfiguration.load(environment: environment))
        let selection = TokenStoreSelection.resolve(environment: environment)
        guard case .file = selection else {
            Issue.record("the live test needs TIMELINE_TOKEN_STORE=file")
            return
        }
        let transcript = LiveTranscript()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LiveTranscriptProtocol.self]
        LiveTranscriptProtocol.transcript = transcript
        let session = URLSession(configuration: sessionConfiguration)

        let provider = GoogleAccountProvider(
            configuration: configuration, tokenStore: selection.makeStore(),
            accountsFile: AccountsFile(url: AccountsFile.defaultURL(environment: environment)),
            presenter: FakeAuthorizationPresenter(mode: .ignore), session: session)
        let account = try #require(
            await provider.accounts().first, "connect an account first (TimelineApp --connect-google)")
        transcript.scrub(account.id, as: "<sub>")
        if let email = account.email { transcript.scrub(email, as: "<email>") }
        if let channel = account.channelId { transcript.scrub(channel, as: "<channelId>") }

        let directory = try temporaryDirectory("live")
        let clip = try await TestMedia.videoWithAudio(duration: 2, in: directory, name: "live")
        let stamp = Date.ISO8601FormatStyle().format(Date())
        var request = PublishRequest(
            accountId: account.id, renderId: "live-render", fileURL: clip.url,
            expectedContentHash: try FileHash.sha256(of: clip.url), title: "timeline-live-test \(stamp)",
            description: "Automated upload from the Timeline live test; deleted right after.", categoryId: "22",
            privacy: .private, notifySubscribers: false,
            captions: [PublishCaptionTrack(language: "en", name: "English", cues: Fixtures.captionCues)])
        request.thumbnail = PublishThumbnail(fileURL: try jpegFile(bytes: 20_000, in: directory))

        let quota = QuotaMeter(fileURL: QuotaMeter.fileURL(cacheDir: directory.appendingPathComponent("Cache")))
        let publisher = YouTubePublisher(
            accounts: provider, session: session, quota: quota, audited: configuration.audited,
            options: UploadOptions(chunkBytes: 1 << 20))
        let runner = FakeJobRunner()
        let log = EventLog()
        let job = publisher.publish(request, publishId: "live-\(UUID().uuidString)", resuming: nil) { log.append($0) }
        let handle = await runner.submit(job)
        var receipt: PublishReceipt?
        do {
            receipt = try (try await handle.wait()).payload(as: PublishReceipt.self)
        } catch {
            Issue.record("publish failed: \(error)")
        }
        if let receipt {
            transcript.scrub(receipt.remoteId, as: "<videoId>")
            #expect(receipt.privacy == .private && receipt.processingStatus == "processed")
            #expect(receipt.captionIds.count == 1)
            #expect(receipt.thumbnailSet || receipt.warnings.contains { $0.hasPrefix("Thumbnail not set") })
            let token = try await provider.accessToken(for: account.id, minimumLifetime: .seconds(60))
            try await YouTubeAPI(session: session).deleteVideo(token: token, videoId: receipt.remoteId)
        } else if let uploaded = log.uploaded {
            let token = try await provider.accessToken(for: account.id, minimumLifetime: .seconds(60))
            try? await YouTubeAPI(session: session).deleteVideo(token: token, videoId: uploaded.0)
        }
        for session in log.sessions { transcript.scrub(session.uploadURL.absoluteString, as: "<sessionURI>") }
        if let path = environment["TIMELINE_LIVE_TRANSCRIPT_OUT"], !path.isEmpty {
            try transcript.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Request/response pairs with tokens, emails, ids, and session URIs replaced.
final class LiveTranscript: Sendable {
    struct Entry: Codable, Sendable {
        var method: String
        var url: String
        var requestHeaders: [String: String]
        var requestBody: String?
        var status: Int
        var responseHeaders: [String: String]
        var responseBody: String?
    }

    private let entries = Mutex<[Entry]>([])
    private let replacements = Mutex<[(String, String)]>([])

    func scrub(_ value: String, as placeholder: String) {
        guard !value.isEmpty else { return }
        replacements.withLock { $0.append((value, placeholder)) }
    }

    func record(_ entry: Entry) { entries.withLock { $0.append(entry) } }

    func write(to url: URL) throws {
        let rules = replacements.withLock { $0 }
        func clean(_ text: String) -> String {
            var text = text
            for (value, placeholder) in rules { text = text.replacingOccurrences(of: value, with: placeholder) }
            text = text.replacingOccurrences(
                of: #"ya29\.[A-Za-z0-9._-]+"#, with: "<accessToken>", options: .regularExpression)
            text = text.replacingOccurrences(
                of: #"1//[A-Za-z0-9._-]+"#, with: "<refreshToken>", options: .regularExpression)
            text = text.replacingOccurrences(
                of: #"upload_id=[A-Za-z0-9._-]+"#, with: "upload_id=<uploadId>", options: .regularExpression)
            return text
        }
        let scrubbed = entries.withLock { $0 }.map { entry -> Entry in
            var entry = entry
            entry.url = clean(entry.url)
            entry.requestHeaders = entry.requestHeaders.mapValues {
                $0.hasPrefix("Bearer ") ? "Bearer <accessToken>" : clean($0)
            }
            entry.requestBody = entry.requestBody.map(clean)
            entry.responseHeaders = entry.responseHeaders.mapValues(clean)
            entry.responseBody = entry.responseBody.map(clean)
            return entry
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(scrubbed).write(to: url, options: [.atomic])
    }
}

/// Forwards every request to the network through a plain session and records the exchange (bodies
/// only when textual; chunk bodies are noted by size).
final class LiveTranscriptProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var transcript: LiveTranscript?
    private static let forwarder = URLSession(configuration: .ephemeral)

    override class func canInit(with request: URLRequest) -> Bool {
        URLProtocol.property(forKey: "live-transcript", in: request) == nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let original = request
        let mutable = (original as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: "live-transcript", in: mutable)
        var body = original.httpBody
        if body == nil, let stream = original.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
            mutable.httpBody = data
        }
        let forwarded = mutable as URLRequest
        let bodyText: String? = body.map { data in
            let type = original.value(forHTTPHeaderField: "Content-Type") ?? ""
            return type.contains("json") || type.contains("form") || type.contains("multipart")
                ? String(decoding: data, as: UTF8.self) : "<\(data.count) bytes>"
        }
        let task = Self.forwarder.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            var requestHeaders: [String: String] = [:]
            for (key, value) in original.allHTTPHeaderFields ?? [:] { requestHeaders[key] = value }
            Self.transcript?.record(
                LiveTranscript.Entry(
                    method: original.httpMethod ?? "GET", url: original.url?.absoluteString ?? "",
                    requestHeaders: requestHeaders, requestBody: bodyText, status: http.statusCode,
                    responseHeaders: headers, responseBody: data.map { String(decoding: $0, as: UTF8.self) }))
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if let data, !data.isEmpty { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        task.resume()
    }

    override func stopLoading() {}
}
