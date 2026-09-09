import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

/// A raw `URLSession` client for the fake, shaped like the requests PublishKit will make.
private struct Client {
    let server: FakeYouTubeServer
    let session: URLSession
    var token: String

    init(_ server: FakeYouTubeServer, token: String) {
        self.server = server
        self.session = URLSession(configuration: server.sessionConfiguration())
        self.token = token
    }

    func request(
        _ method: String, _ url: String, headers: [String: String] = [:], body: Data? = nil, bearer: Bool = true
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        if bearer { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        return request
    }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, JSONValue?) {
        let (data, response) = try await session.data(for: request)
        let json = data.isEmpty ? nil : try? ProjectCodec.decode(JSONValue.self, from: data)
        return (response as! HTTPURLResponse, json)
    }

    func upload(_ request: URLRequest, _ data: Data) async throws -> (HTTPURLResponse, JSONValue?) {
        let (body, response) = try await session.upload(for: request, from: data)
        let json = body.isEmpty ? nil : try? ProjectCodec.decode(JSONValue.self, from: body)
        return (response as! HTTPURLResponse, json)
    }

    func form(_ fields: [String: String]) -> Data {
        Data(
            fields.sorted { $0.key < $1.key }.map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value)"
            }.joined(separator: "&").utf8)
    }

    func startUpload(total: Int64, privacy: String = "private", part: String = "snippet,status") async throws -> URL {
        let metadata: JSONValue = [
            "snippet": ["title": "Band rehearsal", "categoryId": "22"],
            "status": ["privacyStatus": .string(privacy), "containsSyntheticMedia": false],
        ]
        let (response, _) = try await send(
            request(
                "POST", "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=\(part)",
                headers: [
                    "Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Length": String(total),
                    "X-Upload-Content-Type": "video/mp4",
                ], body: try ProjectCodec.encode(metadata)))
        #expect(response.statusCode == 200)
        return try #require(response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)))
    }

    func chunk(_ url: URL, _ data: Data, start: Int64, total: Int64) async throws -> (HTTPURLResponse, JSONValue?) {
        try await upload(
            request(
                "PUT", url.absoluteString,
                headers: [
                    "Content-Type": "video/mp4",
                    "Content-Range": "bytes \(start)-\(start + Int64(data.count) - 1)/\(total)",
                ]), data)
    }

    func status(_ url: URL, total: Int64) async throws -> HTTPURLResponse {
        try await upload(request("PUT", url.absoluteString, headers: ["Content-Range": "bytes */\(total)"]), Data()).0
    }
}

private func randomData(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        for i in stride(from: 0, to: buffer.count, by: 4096) { buffer[i] = UInt8.random(in: 0...255) }
    }
    return data
}

private let mib = 1 << 20

@Suite struct FakeYouTubeServerTests {
    private func seededClient() async -> Client {
        let server = FakeYouTubeServer()
        await server.seedFixtureAccount()
        let token = await server.issueAccessToken(for: "sub-1")
        return Client(server, token: token)
    }

    @Test func resumableProtocolWithARawURLSession() async throws {
        let client = await seededClient()
        let server = client.server
        let total = Int64(3 * mib)
        let file = randomData(Int(total))
        let upload = try await client.startUpload(total: total)
        #expect(upload.host() == "www.googleapis.com" && upload.query()?.contains("upload_id=fake-upload-1") == true)
        #expect(await server.uploadsUsed == 1)

        // Nothing stored yet: 308 without Range.
        let empty = try await client.status(upload, total: total)
        #expect(empty.statusCode == 308 && empty.value(forHTTPHeaderField: "Range") == nil)

        // A chunk at the wrong offset, and a non-final chunk that is not a multiple of 256 KiB, are rejected.
        let wrongOffset = try await client.chunk(
            upload, file.subdata(in: mib..<(2 * mib)), start: Int64(mib), total: total)
        #expect(wrongOffset.0.statusCode == 400 && wrongOffset.1?["error"]?["errors"]?[0]?["reason"] == "invalid")
        let ragged = try await client.chunk(upload, file.subdata(in: 0..<(mib + 10)), start: 0, total: total)
        #expect(ragged.0.statusCode == 400)

        for i in 0..<3 {
            let range = (i * mib)..<((i + 1) * mib)
            let (response, json) = try await client.chunk(
                upload, file.subdata(in: range), start: Int64(range.lowerBound), total: total)
            if i < 2 {
                #expect(response.statusCode == 308)
                #expect(response.value(forHTTPHeaderField: "Range") == "bytes=0-\(range.upperBound - 1)")
                let status = try await client.status(upload, total: total)
                #expect(
                    status.statusCode == 308
                        && status.value(forHTTPHeaderField: "Range") == "bytes=0-\(range.upperBound - 1)")
            } else {
                #expect(response.statusCode == 201)
                #expect(json?["id"] == "fake-video-1" && json?["kind"] == "youtube#video")
                #expect(
                    json?["status"]?["uploadStatus"] == "uploaded" && json?["status"]?["privacyStatus"] == "private")
                #expect(json?["snippet"]?["title"] == "Band rehearsal")
            }
        }
        let complete = try await client.status(upload, total: total)
        #expect(complete.statusCode == 200)
        #expect(await server.chunkRequests.count == 5)
        #expect(await server.statusQueries.count == 4)
        #expect(await !server.hasOverlappingChunks)
        #expect(await server.sessions["fake-upload-1"]?.videoId == "fake-video-1")

        // Processing: two polls of uploaded/processing, then processed.
        var states: [String] = []
        for _ in 0..<3 {
            let (_, json) = try await client.send(
                client.request(
                    "GET", "https://www.googleapis.com/youtube/v3/videos?part=status,processingDetails&id=fake-video-1")
            )
            states.append(json?["items"]?[0]?["status"]?["uploadStatus"]?.stringValue ?? "?")
            if states.count < 3 {
                #expect(json?["items"]?[0]?["processingDetails"]?["processingStatus"] == "processing")
            } else {
                #expect(json?["items"]?[0]?["processingDetails"]?["processingStatus"] == "succeeded")
            }
        }
        #expect(states == ["uploaded", "uploaded", "processed"])

        // Thumbnail, captions (multipart/related), playlist item, delete.
        let thumbnail = try await client.upload(
            client.request(
                "POST", "https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=fake-video-1",
                headers: ["Content-Type": "image/jpeg"]), randomData(20_000))
        #expect(thumbnail.0.statusCode == 200 && thumbnail.1?["items"]?[0]?["default"]?["url"] != nil)
        #expect(await server.thumbnails["fake-video-1"] == 20_000)

        let srt = "1\r\n00:00:01,001 --> 00:00:02,502\r\nHello there\r\n\r\n"
        let multipart = Data(
            """
            --b\r
            Content-Type: application/json; charset=UTF-8\r
            \r
            {"snippet":{"videoId":"fake-video-1","language":"en","name":"English","isDraft":false}}\r
            --b\r
            Content-Type: application/octet-stream\r
            \r
            \(srt)\r
            --b--\r

            """.utf8)
        let captionRequest = client.request(
            "POST", "https://www.googleapis.com/upload/youtube/v3/captions?uploadType=multipart&part=snippet",
            headers: ["Content-Type": "multipart/related; boundary=b"])
        let caption = try await client.upload(captionRequest, multipart)
        #expect(caption.0.statusCode == 200 && caption.1?["id"] == "fake-caption-1")
        #expect(caption.1?["snippet"]?["language"] == "en" && caption.1?["snippet"]?["name"] == "English")
        #expect(await server.captions(forVideo: "fake-video-1").first?.body == srt)
        let duplicate = try await client.upload(captionRequest, multipart)
        #expect(duplicate.0.statusCode == 409)

        let playlist = try await client.send(
            client.request(
                "POST", "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet",
                headers: ["Content-Type": "application/json"],
                body: try ProjectCodec.encode(
                    JSONValue.object([
                        "snippet": [
                            "playlistId": "PL-1", "resourceId": ["kind": "youtube#video", "videoId": "fake-video-1"],
                        ]
                    ]))))
        #expect(playlist.0.statusCode == 200 && playlist.1?["snippet"]?["playlistId"] == "PL-1")
        #expect(await server.playlistItems.map(\.videoId) == ["fake-video-1"])

        let deleted = try await client.send(
            client.request("DELETE", "https://www.googleapis.com/youtube/v3/videos?id=fake-video-1"))
        #expect(deleted.0.statusCode == 204)
        let gone = try await client.send(
            client.request("GET", "https://www.googleapis.com/youtube/v3/videos?part=status&id=fake-video-1"))
        #expect(gone.1?["items"]?.arrayValue?.isEmpty == true)
        // 3 videos.list + 50 thumbnail + 400 + 400 captions + 50 playlist + 50 delete + 1 videos.list
        #expect(await server.unitsUsed == 3 + 50 + 400 + 400 + 50 + 50 + 1)
        #expect(await server.requests.allSatisfy { $0.host == "www.googleapis.com" && $0.hasBearer })
    }

    @Test func dropConnectionKeepsGranularityAlignedBytes() async throws {
        let client = await seededClient()
        let server = client.server
        let total = Int64(3 * mib)
        let file = randomData(Int(total))
        let upload = try await client.startUpload(total: total)
        await server.dropConnection(afterBytes: Int64(mib + 300 * 1024))

        let first = try await client.chunk(upload, file.subdata(in: 0..<mib), start: 0, total: total)
        #expect(first.0.statusCode == 308)
        await #expect(throws: URLError.self) {
            _ = try await client.chunk(upload, file.subdata(in: mib..<(2 * mib)), start: Int64(mib), total: total)
        }
        let kept = Int64(mib + 256 * 1024)
        #expect(await server.sessions["fake-upload-1"]?.bytesConfirmed == kept)
        let status = try await client.status(upload, total: total)
        #expect(status.statusCode == 308 && status.value(forHTTPHeaderField: "Range") == "bytes=0-\(kept - 1)")

        let resume = try await client.chunk(
            upload, file.subdata(in: Int(kept)..<(Int(kept) + mib)), start: kept, total: total)
        #expect(resume.0.statusCode == 308)
        let final = try await client.chunk(
            upload, file.subdata(in: (Int(kept) + mib)..<Int(total)), start: kept + Int64(mib), total: total)
        #expect(final.0.statusCode == 201 && final.1?["id"] == "fake-video-1")
        #expect(await server.statusQueries.count == 1)
        #expect(await !server.hasOverlappingChunks)
        let dropped = await server.requests.filter(\.dropped)
        #expect(dropped.count == 1 && dropped[0].bodyBytes == mib + 300 * 1024 - mib)
    }

    @Test func statusQueryAfterExpiryIs404() async throws {
        let client = await seededClient()
        let total = Int64(mib)
        let upload = try await client.startUpload(total: total)
        _ = try await client.chunk(upload, randomData(256 * 1024), start: 0, total: total)
        await client.server.expireSession()
        #expect(try await client.status(upload, total: total).statusCode == 404)
        let chunk = try await client.chunk(upload, randomData(256 * 1024), start: 256 * 1024, total: total)
        #expect(chunk.0.statusCode == 404)
        let again = try await client.startUpload(total: total)
        #expect(again != upload)
        #expect(try await client.status(again, total: total).statusCode == 308)
        #expect(await client.server.uploadsUsed == 2)
    }

    @Test func tokenEndpointExchangesRefreshesAndRevokes() async throws {
        let server = FakeYouTubeServer()
        let seededRefresh = await server.seedAccount(
            sub: "sub-7", email: "seven@example.com", channelId: "UC-7", channelTitle: "Seven", handle: "@seven")
        await server.seedAccount(sub: "sub-8", email: "eight@example.com", noChannel: true)
        var client = Client(server, token: "")
        let code = await server.issueAuthorizationCode(for: "sub-7", scopes: Fixtures.publishScopes)

        let missing = try await client.send(
            client.request(
                "POST", "https://oauth2.googleapis.com/token",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: client.form(["grant_type": "authorization_code", "code": code, "client_id": "id"]), bearer: false)
        )
        #expect(missing.0.statusCode == 400 && missing.1?["error"] == "invalid_request")

        let exchange = try await client.send(
            client.request(
                "POST", "https://oauth2.googleapis.com/token",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: client.form([
                    "grant_type": "authorization_code", "code": code, "code_verifier": "v", "client_id": "id.apps",
                    "redirect_uri": "http://127.0.0.1:1234/callback",
                ]), bearer: false))
        #expect(
            exchange.0.statusCode == 200 && exchange.1?["token_type"] == "Bearer" && exchange.1?["expires_in"] == 3599)
        let access = try #require(exchange.1?["access_token"]?.stringValue)
        let refresh = try #require(exchange.1?["refresh_token"]?.stringValue)
        #expect(
            exchange.1?["scope"]
                == "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/youtube.force-ssl"
        )
        let idToken = try #require(exchange.1?["id_token"]?.stringValue)
        let payload = try #require(idToken.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first)
        var base64 = String(payload).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let claims = try ProjectCodec.decode(JSONValue.self, from: try #require(Data(base64Encoded: base64)))
        #expect(claims["sub"] == "sub-7" && claims["email"] == "seven@example.com" && claims["aud"] == "id.apps")
        // A code is single-use.
        let reused = try await client.send(
            client.request(
                "POST", "https://oauth2.googleapis.com/token",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: client.form([
                    "grant_type": "authorization_code", "code": code, "code_verifier": "v", "client_id": "id.apps",
                    "redirect_uri": "http://127.0.0.1:1234/callback",
                ]), bearer: false))
        #expect(reused.0.statusCode == 400 && reused.1?["error"] == "invalid_grant")

        client.token = access
        let channels = try await client.send(
            client.request("GET", "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true"))
        #expect(channels.0.statusCode == 200 && channels.1?["items"]?[0]?["id"] == "UC-7")
        #expect(channels.1?["items"]?[0]?["snippet"]?["customUrl"] == "@seven")
        let userinfo = try await client.send(client.request("GET", "https://openidconnect.googleapis.com/v1/userinfo"))
        #expect(userinfo.1?["sub"] == "sub-7" && userinfo.1?["email"] == "seven@example.com")

        let refreshed = try await client.send(
            client.request(
                "POST", "https://oauth2.googleapis.com/token",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: client.form(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": "id.apps"]),
                bearer: false))
        #expect(refreshed.0.statusCode == 200 && refreshed.1?["refresh_token"] == nil)
        let newAccess = try #require(refreshed.1?["access_token"]?.stringValue)
        #expect(newAccess != access)

        await server.revokeRefreshToken(sub: "sub-7")
        let revokedRefresh = try await client.send(
            client.request(
                "POST", "https://oauth2.googleapis.com/token",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: client.form(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": "id.apps"]),
                bearer: false))
        #expect(revokedRefresh.0.statusCode == 400 && revokedRefresh.1?["error"] == "invalid_grant")
        client.token = newAccess
        #expect(
            try await client.send(client.request("GET", "https://www.googleapis.com/youtube/v3/channels?mine=true")).0
                .statusCode == 401)

        let revoke = try await client.send(
            client.request("POST", "https://oauth2.googleapis.com/revoke?token=\(seededRefresh)", bearer: false))
        #expect(revoke.0.statusCode == 200)
        let revokeAgain = try await client.send(
            client.request("POST", "https://oauth2.googleapis.com/revoke?token=\(seededRefresh)", bearer: false))
        #expect(revokeAgain.0.statusCode == 400)

        // A no-channel account, a fake-code from the presenter, and a scope override.
        await server.setGrantedScopes(["openid", "email"])
        let presenterCode = try await client.send(
            client.request(
                "POST", "https://oauth2.googleapis.com/token",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: client.form([
                    "grant_type": "authorization_code", "code": "fake-code-99", "code_verifier": "v", "client_id": "id",
                    "redirect_uri": "http://127.0.0.1:1/callback",
                ]), bearer: false))
        #expect(presenterCode.0.statusCode == 200)
        #expect(presenterCode.1?["scope"] == "openid https://www.googleapis.com/auth/userinfo.email")
        client.token = await server.issueAccessToken(for: "sub-8")
        let none = try await client.send(
            client.request("GET", "https://www.googleapis.com/youtube/v3/channels?mine=true&part=snippet"))
        #expect(none.0.statusCode == 200 && none.1?["items"]?.arrayValue?.isEmpty == true)
    }

    @Test func bearerlessRequestsAre401() async throws {
        var client = await seededClient()
        let url = "https://www.googleapis.com/youtube/v3/channels?mine=true&part=snippet"
        let none = try await client.send(client.request("GET", url, bearer: false))
        #expect(none.0.statusCode == 401)
        #expect(none.0.value(forHTTPHeaderField: "WWW-Authenticate")?.contains("invalid_token") == true)
        #expect(
            none.1?["error"]?["errors"]?[0]?["reason"] == "authError"
                && none.1?["error"]?["status"] == "UNAUTHENTICATED")
        let good = client.token
        client.token = "bogus"
        #expect(try await client.send(client.request("GET", url)).0.statusCode == 401)
        client.token = good
        #expect(try await client.send(client.request("GET", url)).0.statusCode == 200)
        await client.server.expireAccessTokensNow()
        #expect(try await client.send(client.request("GET", url)).0.statusCode == 401)
        #expect(try await client.send(client.request("GET", url)).0.statusCode == 200)
        #expect(await client.server.requests.filter { !$0.hasBearer }.count == 1)
        #expect(await client.server.unitsUsed == 2, "rejected requests cost nothing here; Google charges one")
    }

    @Test func quotaCountsUploadsAndUnits() async throws {
        let client = await seededClient()
        let server = client.server
        let channels = "https://www.googleapis.com/youtube/v3/channels?mine=true&part=snippet"
        _ = try await client.send(client.request("GET", channels))
        let total = Int64(512 * 1024)
        let upload = try await client.startUpload(total: total, privacy: "public")
        let quota = await server.quota
        #expect(
            quota.uploadsUsed == 1 && quota.unitsUsed == 1 && quota.uploadsLimit == 100 && quota.unitsLimit == 10_000)

        await server.quotaExceeded()
        let exceeded = try await client.send(client.request("GET", channels))
        #expect(exceeded.0.statusCode == 403 && exceeded.1?["error"]?["errors"]?[0]?["reason"] == "quotaExceeded")
        #expect(try await client.send(client.request("GET", channels)).0.statusCode == 200)

        await server.uploadLimitExceeded()
        let limited = try await client.send(
            client.request(
                "POST", "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status",
                headers: ["Content-Type": "application/json", "X-Upload-Content-Length": "10"],
                body: Data(#"{"snippet":{"title":"x"},"status":{"privacyStatus":"private"}}"#.utf8)))
        #expect(limited.0.statusCode == 400 && limited.1?["error"]?["errors"]?[0]?["reason"] == "uploadLimitExceeded")
        let noLength = try await client.send(
            client.request(
                "POST", "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status",
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"snippet":{"title":"x"},"status":{"privacyStatus":"private"}}"#.utf8)))
        #expect(noLength.0.statusCode == 400)

        await server.retryAfter(seconds: 7)
        await server.respond(status: 503, times: 2)
        let data = randomData(256 * 1024)
        let first = try await client.chunk(upload, data, start: 0, total: total)
        #expect(first.0.statusCode == 503 && first.0.value(forHTTPHeaderField: "Retry-After") == "7")
        let second = try await client.chunk(upload, data, start: 0, total: total)
        #expect(second.0.statusCode == 503 && second.0.value(forHTTPHeaderField: "Retry-After") == nil)
        #expect(try await client.status(upload, total: total).statusCode == 308)
        #expect(try await client.chunk(upload, data, start: 0, total: total).0.statusCode == 308)

        await server.forcePrivate()
        await server.scriptProcessing(uploadStatus: "rejected", reason: "length")
        await server.setProcessingPollsUntilDone(0)
        let done = try await client.chunk(upload, data, start: Int64(data.count), total: total)
        #expect(done.0.statusCode == 201 && done.1?["status"]?["privacyStatus"] == "private")
        let listed = try await client.send(
            client.request("GET", "https://www.googleapis.com/youtube/v3/videos?part=status&id=fake-video-1"))
        #expect(listed.1?["items"]?[0]?["status"]?["uploadStatus"] == "rejected")
        #expect(listed.1?["items"]?[0]?["status"]?["rejectionReason"] == "length")

        await server.forbidThumbnail()
        let forbidden = try await client.upload(
            client.request(
                "POST", "https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=fake-video-1",
                headers: ["Content-Type": "image/png"]), randomData(1000))
        #expect(forbidden.0.statusCode == 403 && forbidden.1?["error"]?["errors"]?[0]?["reason"] == "forbidden")
        #expect(await server.quota.uploadsUsed == 1, "a refused start counts nothing")
        #expect(await server.unitsUsed == 1 + 1 + 1 + 50)
    }

    @Test func unregisteredHostsAndServersFail() async throws {
        let server = FakeYouTubeServer()
        let configuration = server.sessionConfiguration()
        #expect(configuration.httpAdditionalHeaders?[FakeYouTubeURLProtocol.serverHeader] as? String == server.id)
        #expect(FakeYouTubeURLProtocol.canInit(with: URLRequest(url: URL(string: "https://www.googleapis.com/x")!)))
        #expect(!FakeYouTubeURLProtocol.canInit(with: URLRequest(url: URL(string: "http://127.0.0.1:1/callback")!)))
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/channels?mine=true")!)
        request.setValue("no-such-server", forHTTPHeaderField: FakeYouTubeURLProtocol.serverHeader)
        let session = URLSession(configuration: configuration)
        await #expect(throws: URLError.self) { _ = try await session.data(for: request) }
    }
}
