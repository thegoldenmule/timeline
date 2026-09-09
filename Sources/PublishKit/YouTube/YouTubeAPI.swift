import Contracts
import Foundation
import TimelineCore

/// A non-2xx answer from Google, with the `errors[0].reason` of its JSON body
/// (docs/research/11-youtube-upload.md sections 2 and 4).
public struct YouTubeAPIError: Error, Sendable, Hashable, LocalizedError {
    public var status: Int
    public var reason: String?
    public var message: String
    public var retryAfter: TimeInterval?

    public init(status: Int, reason: String? = nil, message: String, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.reason = reason
        self.message = message
        self.retryAfter = retryAfter
    }

    public var isUnauthorized: Bool { status == 401 }
    public var isQuotaExceeded: Bool { status == 403 && reason == "quotaExceeded" }
    public var isUploadLimitExceeded: Bool { status == 400 && reason == "uploadLimitExceeded" }
    public var isConflict: Bool { status == 409 }
    /// 500, 502, 503, 504: query status, back off, resume.
    public var isRetryable: Bool { [500, 502, 503, 504].contains(status) }

    public var errorDescription: String? { "HTTP \(status) \(reason ?? ""): \(message)" }

    /// The `PublishError` this failure means for a publish.
    public func publishError(quotaResetsAt: Date?) -> PublishError {
        if isUnauthorized { return .reauthorizationRequired("the access token was rejected") }
        if isQuotaExceeded { return .quotaExceeded(resetsAt: quotaResetsAt) }
        if isUploadLimitExceeded { return .uploadLimitExceeded }
        if status == 403 { return .forbidden(message) }
        return .uploadFailed(status: status, reason: reason.map { "\($0): \(message)" } ?? message)
    }

    /// Parses Google's error JSON (`{"error": {"code", "message", "errors": [{"reason"}]}}`).
    public static func decode(status: Int, headers: [String: String], body: Data) -> YouTubeAPIError {
        var reason: String?
        var message = "HTTP \(status)"
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                message = error["message"] as? String ?? message
                reason =
                    (error["errors"] as? [[String: Any]])?.first?["reason"] as? String ?? error["status"] as? String
            } else if let error = object["error"] as? String {
                reason = error
                message = object["error_description"] as? String ?? error
            }
        }
        let retryAfter = headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }?.value
        return YouTubeAPIError(
            status: status, reason: reason, message: message, retryAfter: retryAfter.flatMap { TimeInterval($0) })
    }
}

/// Request builders and decoders for the YouTube Data API v3 calls a publish makes, over an injected
/// `URLSession`. Every method takes the bearer token per call; nothing here caches one.
public struct YouTubeAPI: Sendable {
    public static let apiBase = URL(string: "https://www.googleapis.com/youtube/v3/")!
    public static let uploadBase = URL(string: "https://www.googleapis.com/upload/youtube/v3/")!

    /// Quota units per call (docs/research/11-youtube-upload.md section 6).
    public enum Cost {
        public static let channelsList = 1
        public static let videosList = 1
        public static let thumbnailsSet = 50
        public static let captionsInsert = 400
        public static let playlistItemsInsert = 50
        public static let videosDelete = 50
    }

    public struct ChannelInfo: Sendable, Hashable {
        public var id: String
        public var title: String
        /// `snippet.customUrl`, the `@handle`.
        public var handle: String?
        public var avatarURL: URL?
    }

    public struct HTTPResponse: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data

        public var json: JSONValue? { body.isEmpty ? nil : try? ProjectCodec.decode(JSONValue.self, from: body) }
        public func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        public var isSuccess: Bool { (200..<300).contains(status) }
        public var error: YouTubeAPIError { YouTubeAPIError.decode(status: status, headers: headers, body: body) }
    }

    public let session: URLSession
    public let requestTimeout: TimeInterval

    public init(session: URLSession, requestTimeout: TimeInterval = 120) {
        self.session = session
        self.requestTimeout = requestTimeout
    }

    // MARK: Calls

    /// `channels.list?part=snippet&mine=true`: the channel picked on the consent screen, nil when the
    /// account owns none (Google omits `items`).
    public func myChannel(token: AccessToken) async throws -> ChannelInfo? {
        let request = makeRequest(
            "GET", Self.apiBase.appendingPathComponent("channels"), query: [("part", "snippet"), ("mine", "true")],
            token: token)
        let response = try await send(request)
        guard response.isSuccess else { throw response.error }
        guard let item = response.json?["items"]?.arrayValue?.first, let id = item["id"]?.stringValue else {
            return nil
        }
        let snippet = item["snippet"]
        return ChannelInfo(
            id: id, title: snippet?["title"]?.stringValue ?? "", handle: snippet?["customUrl"]?.stringValue,
            avatarURL: snippet?["thumbnails"]?["default"]?["url"]?.stringValue.flatMap(URL.init(string:)))
    }

    /// `videos.insert?uploadType=resumable`: the session-start request; returns the session URI.
    public func startResumableUpload(
        token: AccessToken, request publishRequest: PublishRequest, totalBytes: Int64, contentType: String
    ) async throws -> URL {
        let metadata = Self.videoResource(for: publishRequest)
        var query = [("uploadType", "resumable"), ("part", Self.parts(for: publishRequest))]
        query.append(("notifySubscribers", publishRequest.notifySubscribers ? "true" : "false"))
        var request = makeRequest("POST", Self.uploadBase.appendingPathComponent("videos"), query: query, token: token)
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(String(totalBytes), forHTTPHeaderField: "X-Upload-Content-Length")
        request.setValue(contentType, forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(publishRequest.fileURL.lastPathComponent, forHTTPHeaderField: "Slug")
        request.httpBody = try ProjectCodec.encode(metadata)
        let response = try await send(request)
        guard response.isSuccess else { throw response.error }
        guard let location = response.header("Location").flatMap(URL.init(string:)) else {
            throw YouTubeAPIError(
                status: response.status, reason: "noLocation", message: "session start without Location")
        }
        return location
    }

    /// `videos.list?part=status,processingDetails&id=`; `uploaded`, `processed`, `failed`, `rejected`, or
    /// `deleted` when the id is unknown.
    public func videoStatus(token: AccessToken, videoId: String) async throws -> RemotePublishStatus {
        let request = makeRequest(
            "GET", Self.apiBase.appendingPathComponent("videos"),
            query: [("part", "status,processingDetails"), ("id", videoId)], token: token)
        let response = try await send(request)
        guard response.isSuccess else { throw response.error }
        guard let item = response.json?["items"]?.arrayValue?.first else {
            return RemotePublishStatus(uploadStatus: "deleted")
        }
        let status = item["status"]
        return RemotePublishStatus(
            uploadStatus: status?["uploadStatus"]?.stringValue ?? "uploaded",
            privacy: status?["privacyStatus"]?.stringValue.flatMap(PublishPrivacy.init(rawValue:)),
            processingStatus: item["processingDetails"]?["processingStatus"]?.stringValue,
            failureReason: status?["failureReason"]?.stringValue,
            rejectionReason: status?["rejectionReason"]?.stringValue)
    }

    /// `thumbnails.set?videoId=` with the image as the body (JPEG or PNG, at most 2 MB).
    public func setThumbnail(token: AccessToken, videoId: String, imageData: Data, contentType: String) async throws {
        var request = makeRequest(
            "POST", Self.uploadBase.appendingPathComponent("thumbnails/set"), query: [("videoId", videoId)],
            token: token)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let response = try await send(request, body: imageData)
        guard response.isSuccess else { throw response.error }
    }

    /// `captions.insert?uploadType=multipart&part=snippet` (`multipart/related`: the snippet JSON, then the
    /// caption file); returns the caption id. A duplicate language + name answers 409.
    public func insertCaption(token: AccessToken, videoId: String, language: String, name: String, body: Data)
        async throws -> String
    {
        let boundary = "timeline-\(UUID().uuidString)"
        var request = makeRequest(
            "POST", Self.uploadBase.appendingPathComponent("captions"),
            query: [("uploadType", "multipart"), ("part", "snippet")], token: token)
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let snippet: JSONValue = [
            "snippet": [
                "videoId": .string(videoId), "language": .string(language), "name": .string(name), "isDraft": false,
            ]
        ]
        var data = Data()
        data.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        data.append(try ProjectCodec.encode(snippet))
        data.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        data.append(body)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response = try await send(request, body: data)
        guard response.isSuccess else { throw response.error }
        guard let id = response.json?["id"]?.stringValue else {
            throw YouTubeAPIError(status: response.status, reason: "noId", message: "caption response without id")
        }
        return id
    }

    /// `playlistItems.insert?part=snippet`; returns the playlist item id.
    public func insertPlaylistItem(token: AccessToken, playlistId: String, videoId: String) async throws -> String {
        var request = makeRequest(
            "POST", Self.apiBase.appendingPathComponent("playlistItems"), query: [("part", "snippet")], token: token)
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = [
            "snippet": [
                "playlistId": .string(playlistId),
                "resourceId": ["kind": "youtube#video", "videoId": .string(videoId)],
            ]
        ]
        request.httpBody = try ProjectCodec.encode(body)
        let response = try await send(request)
        guard response.isSuccess else { throw response.error }
        guard let id = response.json?["id"]?.stringValue else {
            throw YouTubeAPIError(status: response.status, reason: "noId", message: "playlist item without id")
        }
        return id
    }

    /// `videos.delete?id=` (204).
    public func deleteVideo(token: AccessToken, videoId: String) async throws {
        let request = makeRequest(
            "DELETE", Self.apiBase.appendingPathComponent("videos"), query: [("id", videoId)], token: token)
        let response = try await send(request)
        guard response.isSuccess else { throw response.error }
    }

    // MARK: The video resource

    /// The `snippet`, `status`, and (when a recording date is set) `recordingDetails` of `videos.insert`.
    /// `selfDeclaredMadeForKids` is present only when `madeForKids` is not nil (publish-plan.md D9).
    public static func videoResource(for request: PublishRequest) -> JSONValue {
        var snippet: [String: JSONValue] = [
            "title": .string(request.title), "description": .string(request.description),
        ]
        if !request.tags.isEmpty { snippet["tags"] = .array(request.tags.map { .string($0) }) }
        if let category = request.categoryId { snippet["categoryId"] = .string(category) }
        if let language = request.language { snippet["defaultLanguage"] = .string(language) }
        var status: [String: JSONValue] = [
            "privacyStatus": .string(request.privacy.rawValue),
            "containsSyntheticMedia": .bool(request.containsSyntheticMedia),
        ]
        if let publishAt = request.publishAt { status["publishAt"] = .string(GoogleDates.format(publishAt)) }
        if let madeForKids = request.madeForKids { status["selfDeclaredMadeForKids"] = .bool(madeForKids) }
        var resource: [String: JSONValue] = ["snippet": .object(snippet), "status": .object(status)]
        if let recordingDate = request.recordingDate {
            resource["recordingDetails"] = ["recordingDate": .string(GoogleDates.format(recordingDate))]
        }
        return .object(resource)
    }

    public static func parts(for request: PublishRequest) -> String {
        request.recordingDate == nil ? "snippet,status" : "snippet,status,recordingDetails"
    }

    /// The upload's `Content-Type` from the file extension.
    public static func contentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "webm": "video/webm"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }

    // MARK: Plumbing

    func makeRequest(_ method: String, _ url: URL, query: [(String, String)], token: AccessToken?) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        var request = URLRequest(url: components.url!, timeoutInterval: requestTimeout)
        request.httpMethod = method
        if let token { request.setValue(token.authorizationHeader, forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Sends the request; transport failures become `PublishError.network`.
    public func send(_ request: URLRequest, body: Data? = nil) async throws -> HTTPResponse {
        do {
            let (data, response): (Data, URLResponse)
            if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else {
                throw PublishError.network("non-HTTP response from \(request.url?.host() ?? "?")")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as PublishError {
            throw error
        } catch {
            throw PublishError.network(error.localizedDescription)
        }
    }
}
