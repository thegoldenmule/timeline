import Contracts
import CoreGraphics
import Foundation
import TimelineCore

/// `publish_youtube`, `publish_status`, `account_status`: the publishing side (publish-plan.md 4.3).
/// A publish is a `.publish` job over `any Publisher`, recorded in the project's publish ledger next to
/// the render it uploads. `publish_youtube` is gated `.always`: the approval card, built from the
/// presentation this file assembles, is the express consent YouTube's policies require (D12). The
/// agent never declares the audience: `madeForKids` stays nil and the output says where to set it (D9).
enum PublishTools {
    /// YouTube API Terms 9.1, shown as the card's last row because for the agent path the card is the click.
    static let certificationSentence =
        "By clicking Upload you certify that the content you are uploading complies with the YouTube Terms of Service"
    static let madeForKidsDetail = "not declared: set the audience in YouTube Studio after upload"
    static let madeForKidsNotice =
        "Made for kids is not declared: set the audience (made for kids or not) in YouTube Studio right after the upload"
    static let connectHint = "Connect a Google account in Settings"
    static let reconnectHint = "Reconnect: the grant expired"
    static let renderHint = "run render_export first"
    static let thumbnailSize = CGSize(width: 1280, height: 720)

    // MARK: publish_youtube

    static let publishYouTube = Tool(
        name: "publish_youtube",
        description:
            "Uploads a finished render to the user's YouTube channel. Always requires approval: the first call returns status approval_required with an approvalToken, a publishId, and the card's summary, details and warnings; the user approves in the app; retry the identical call with approvalToken and the same publishId. Defaults to a private upload; never choose public or unlisted unless the user asked in so many words. Captions come from the sequence's caption tracks; the thumbnail is a frame of the sequence. Waits up to waitSeconds, then answers with the publish status (done, uploading, processing, failed); poll publish_status for the rest. The audience (made for kids) is never set here: tell the user to set it in YouTube Studio right after the upload.",
        inputSchema: Schema.withDefs(
            Schema.object(
                "Publish request.",
                properties: ToolSupport.inputProperties(
                    mutating: false,
                    [
                        "renderId": Schema.string(
                            "A done render from render_export (default: the newest done render of the active sequence)."
                        ),
                        "publishId": Schema.string(
                            "Idempotency key. Reuse the value from an approval_required answer; a retry with an id that already has a publish returns its status instead of uploading again; a failed or cancelled publish with this id is resumed."
                        ),
                        "accountId": Schema.string(
                            "Connected Google account id from account_status (default: the only connected account)."),
                        "title": withLimits(
                            Schema.string("Video title, 1-100 characters, no < or >."), min: 1, max: 100),
                        "description": withLimits(Schema.string("Video description, at most 5000 bytes."), max: 5000),
                        "tags": Schema.array("Tags (at most 500 characters in total).", items: Schema.string("A tag.")),
                        "categoryId": Schema.string(
                            "YouTube category id, e.g. 22 People & Blogs (default), 10 Music, 27 Education."),
                        "privacy": withDefault(
                            Schema.enum(
                                "Never public unless the user asked for it in so many words. Uploads from an unaudited project are private regardless.",
                                PublishPrivacy.allCases.map(\.rawValue)), "private"),
                        "publishAt": withFormat(
                            Schema.string("Schedule (RFC 3339 date-time); requires privacy private."), "date-time"),
                        "containsSyntheticMedia": withDefault(
                            Schema.bool(
                                "YouTube's altered-or-synthetic disclosure. Propose true only for realistic generated or altered content; the human confirms on the card."
                            ), false),
                        "thumbnailAt": Schema.ref(
                            "time", "Timeline time of the frame to use as the thumbnail (rendered at 1280x720 JPEG)."),
                        "captionTrackIds": Schema.array(
                            "Caption tracks of the sequence to upload as subtitle tracks (SRT).",
                            items: Schema.string("A caption track id from project_describe.")),
                        "notifySubscribers": withDefault(
                            Schema.bool("Send the channel's subscribers a notification (default false)."), false),
                        "waitSeconds": withDefault(
                            Schema.integer(
                                "How long to wait before answering with status uploading or processing; poll publish_status after.",
                                minimum: 0, maximum: 600), 120),
                        "approvalToken": Schema.string("Token from the approval_required result, once granted."),
                    ]), required: ["title"]),
            ["time": OperationSchemas.defs["time"]!]),
        outputSchema: Schema.object(
            "Publish status, or the approval_required envelope.",
            properties: statusProperties.merging(
                [
                    "jobId": Schema.string("The publish job id, when this call submitted it."),
                    "approvalToken": Schema.string("Present when approval is required."),
                    "estimate": Schema.any("Estimated seconds and bytes when approval is required."),
                    "summary": Schema.string("The approval card's one line, when approval is required."),
                    "details": Schema.array(
                        "The approval card's rows, when approval is required.",
                        items: Schema.any("{ label, value }.")),
                ], uniquingKeysWith: { a, _ in a }), required: ["status", "publishId"], additionalProperties: true),
        annotations: ToolAnnotations(
            title: "Publish to YouTube", readOnly: false, destructive: false, idempotent: false, openWorld: true),
        examples: [
            .object(["title": "Band rehearsal, 8 Sept"]),
            .object([
                "renderId": "r-1", "publishId": "p-1", "title": "Reel", "privacy": "unlisted",
                "captionTrackIds": ["cap-1"], "thumbnailAt": ["v": 48048, "ts": 24000], "approvalToken": "tok-1",
            ]),
        ]
    ) { input, context in
        // 1. Services.
        guard let publisher = context.services.publishers[.youtube] else {
            throw ToolError.serviceUnavailable("publisher")
        }
        guard let accounts = context.services.accounts[.google] else { throw ToolError.serviceUnavailable("accounts") }
        guard let runner = context.services.jobRunner else { throw ToolError.serviceUnavailable("jobRunner") }

        // 2. The project and its ledgers.
        let resolved = try await ToolSupport.resolve(input, context)
        guard let renderLedger = resolved.store as? any RenderLedger else {
            throw ToolError.serviceUnavailable("render ledger")
        }
        guard let publishLedger = resolved.store as? any PublishLedger else {
            throw ToolError.serviceUnavailable("publish ledger")
        }
        let project = resolved.project
        let projectId = resolved.projectId

        // 3. The account.
        let connected = await accounts.accounts()
        let account: ConnectedAccount
        if let id = ToolSupport.string(input, "accountId") {
            guard let found = connected.first(where: { $0.id == id }) else {
                return .error(
                    code: "notConnected", message: "No connected Google account with id \(id)",
                    details: ["hint": .string(connectHint)])
            }
            account = found
        } else if connected.count == 1, let only = connected.first {
            account = only
        } else if connected.isEmpty {
            return .error(
                code: "notConnected", message: "No Google account is connected", details: ["hint": .string(connectHint)]
            )
        } else {
            return .error(
                code: "invalidInput",
                message: "\(connected.count) Google accounts are connected; pass accountId (see account_status)")
        }
        if case .reauthorizationRequired(let reason) = account.tokenStatus {
            return .error(
                code: "reauthorizationRequired", message: AccountError.reauthorizationRequired(reason).message,
                details: ["hint": .string(reconnectHint)])
        }

        // 4. The idempotency key (D10).
        let publishId = ToolSupport.string(input, "publishId") ?? UUIDv7Generator().next()
        var existing: PublishRecord?
        if let row = try await publishLedger.publish(publishId) {
            if row.status == .done || !row.status.isTerminal {
                return statusOutput(
                    row, jobId: nil, projectId: projectId, account: account, validationWarnings: [])
            }
            existing = row
        }
        let resuming = existing?.session

        // 5. The render.
        let render: RenderRecord
        if let existing {
            guard let row = try await renderLedger.render(existing.renderId) else {
                return .error(
                    code: "renderNotFound", message: "No render with id \(existing.renderId)",
                    details: ["hint": .string(renderHint)])
            }
            render = row
        } else if let id = ToolSupport.string(input, "renderId") {
            guard let row = try await renderLedger.render(id) else {
                return .error(
                    code: "renderNotFound", message: "No render with id \(id)", details: ["hint": .string(renderHint)])
            }
            render = row
        } else {
            let active = try ToolSupport.sequence(input, in: project)
            let rows = try await renderLedger.renders()
            guard let newest = rows.first(where: { $0.sequenceId == active.id && $0.status == .done }) else {
                return .error(
                    code: "renderNotFound", message: "No done render of \(active.name)",
                    details: ["hint": .string(renderHint)])
            }
            render = newest
        }
        guard render.status == .done else {
            return .error(
                code: "renderNotDone", message: "Render \(render.id) is \(render.status.rawValue)",
                details: ["hint": .string(renderHint), "renderId": .string(render.id)])
        }
        guard let fileURL = render.outputURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return .error(
                code: "fileMissing", message: "The file of render \(render.id) is missing",
                details: ["hint": .string(renderHint), "renderId": .string(render.id)])
        }
        let sequence: Sequence
        if let own = project.sequences[render.sequenceId] {
            sequence = own
        } else {
            sequence = try ToolSupport.sequence(input, in: project)
        }

        // 6. The request: the row's on a resume, else built from the input.
        let request: PublishRequest
        if let existing {
            request = existing.request
        } else {
            switch try await buildRequest(
                input, publishId: publishId, account: account, render: render, fileURL: fileURL, sequence: sequence,
                project: project, context: context)
            {
            case .success(let built): request = built
            case .failure(let output): return output
            }
        }

        // 7. Local validation.
        var validationWarnings: [String] = []
        do {
            validationWarnings = try await publisher.validate(request)
        } catch PublishError.invalidRequest(let reason) {
            return .error(code: "invalidRequest", message: reason)
        } catch let error as PublishError {
            return .error(code: "publishError", message: error.message)
        }

        // 8. Quota (D11).
        let quota = await publisher.quota()
        if quota.uploadsRemaining == 0 {
            return .error(
                code: "quotaExceeded", message: PublishError.quotaExceeded(resetsAt: quota.resetsAt).message,
                details: ["resetsAt": ToolSupport.json(quota.resetsAt), "quota": ToolSupport.json(quota)])
        }

        // 9. The card.
        let capabilities = await publisher.capabilities()
        let estimate = await publisher.estimate(request)
        let presentation = presentation(
            for: request, account: account, render: render, capabilities: capabilities,
            validationWarnings: validationWarnings)

        // 10. The gate.
        if case .required(let approval) = await context.checkApproval(
            tool: "publish_youtube", input: input, estimate: estimate, presentation: presentation)
        {
            var out = ToolOutput.approvalRequired(approval)
            var o = out.structured?.objectValue ?? [:]
            o["publishId"] = .string(publishId)
            o["projectId"] = .string(projectId.rawValue)
            out.structured = .object(o)
            out.text =
                "Approval required: \(presentation.summary). Retry the same call with approvalToken \(approval.token.rawValue) and publishId \(publishId) once granted."
            return out
        }

        // 11. The ledger row, the job, and the watcher that completes the row after this call answered.
        if existing != nil {
            _ = try await publishLedger.updatePublish(publishId, PublishUpdate(status: .queued))
        } else {
            _ = try await publishLedger.recordPublish(
                id: publishId, request: request, projectVersion: render.projectVersion)
        }
        let ledger = publishLedger
        let job = publisher.publish(request, publishId: publishId, resuming: resuming) { event in
            switch event {
            case .session(let session):
                _ = try? await ledger.updatePublish(
                    publishId,
                    PublishUpdate(status: .uploading, session: session, bytesSent: session.bytesConfirmed))
            case .uploaded(let remoteId, let remoteURL):
                _ = try? await ledger.updatePublish(
                    publishId, PublishUpdate(status: .processing, remoteId: remoteId, remoteURL: remoteURL))
            case .stage:
                break
            }
        }
        let handle = await runner.submit(job)
        let watcher = Task<Void, Never> {
            do {
                let outcome = try await handle.wait()
                let receipt = (try? outcome.payload(as: PublishReceipt.self)) ?? nil
                _ = try? await ledger.updatePublish(
                    publishId,
                    PublishUpdate(
                        status: .done, clearsSession: true, bytesSent: receipt?.bytesUploaded,
                        remoteId: receipt?.remoteId, remoteURL: receipt?.remoteURL, receipt: receipt))
            } catch is CancellationError {
                _ = try? await ledger.updatePublish(
                    publishId, PublishUpdate(status: .cancelled, error: PublishError.cancelled.message))
            } catch {
                _ = try? await ledger.updatePublish(
                    publishId, PublishUpdate(status: .failed, error: ToolSupport.describe(error)))
            }
        }

        // 12. Wait, then answer from the row.
        let waitSeconds = input["waitSeconds"]?.intValue ?? 120
        await waitForTerminalRow(publishId, in: ledger, watcher: watcher, seconds: waitSeconds)
        guard let row = try await publishLedger.publish(publishId) else {
            throw ToolError.serviceUnavailable("publish ledger row \(publishId)")
        }
        return statusOutput(
            row, jobId: handle.id, projectId: projectId, account: account, validationWarnings: validationWarnings)
    }

    // MARK: publish_status

    static let publishStatus = Tool(
        name: "publish_status",
        description:
            "Lists the project's publishes (uploads to YouTube) newest first, or one by publishId, with their status, privacy, URL, bytes, and error; plus the day's remaining upload quota and whether public uploads are allowed. Poll it after publish_youtube answered uploading or processing.",
        inputSchema: Schema.object(
            "Status request.",
            properties: ToolSupport.inputProperties(
                mutating: false,
                [
                    "publishId": Schema.string("One publish to report (default: the newest `limit` publishes)."),
                    "limit": withDefault(
                        Schema.integer("How many to list (default 10).", minimum: 1, maximum: 100), 10),
                ])),
        outputSchema: Schema.object(
            "Publishes newest first, quota, capabilities.",
            properties: [
                "publishes": Schema.array(
                    "Publishes, newest first.",
                    items: Schema.object(
                        "One publish.", properties: publishRowProperties,
                        required: ["publishId", "renderId", "status", "requestedPrivacy", "title", "requestedAt"])),
                "count": Schema.integer("Number of publishes listed."),
                "quota": Schema.any("PublishQuota: uploadsUsed, uploadsLimit, unitsUsed, unitsLimit, resetsAt."),
                "capabilities": Schema.any("PublishCapabilities: publicUploadsAllowed and a note."),
                "projectId": Schema.string("The project the call addressed."),
            ], required: ["publishes", "count", "quota", "capabilities", "projectId"]),
        annotations: .readOnly(title: "Publish status"),
        examples: [.object([:]), .object(["publishId": "p-1"]), .object(["limit": 3])]
    ) { input, context in
        guard let publisher = context.services.publishers[.youtube] else {
            throw ToolError.serviceUnavailable("publisher")
        }
        let resolved = try await ToolSupport.resolve(input, context)
        guard let ledger = resolved.store as? any PublishLedger else {
            throw ToolError.serviceUnavailable("publish ledger")
        }
        let rows: [PublishRecord]
        if let id = ToolSupport.string(input, "publishId") {
            guard let row = try await ledger.publish(id) else { throw EditorError.notFound(id: id) }
            rows = [row]
        } else {
            let limit = max(1, min(input["limit"]?.intValue ?? 10, 100))
            rows = Array(try await ledger.publishes().prefix(limit))
        }
        let quota = await publisher.quota()
        let capabilities = await publisher.capabilities()
        let text =
            rows.isEmpty
            ? "No publishes yet. \(quota.uploadsRemaining) upload(s) left today."
            : rows.map { row in
                "\(row.request.title): \(row.status.rawValue)\(row.remoteURL.map { " \($0.absoluteString)" } ?? "")"
            }.joined(separator: "\n") + "\n\(quota.uploadsRemaining) upload(s) left today."
        return ToolOutput(
            structured: .object([
                "publishes": .array(rows.map(publishRow)), "count": .number(Double(rows.count)),
                "quota": ToolSupport.json(quota), "capabilities": ToolSupport.json(capabilities),
                "projectId": .string(resolved.projectId.rawValue),
            ]), text: text)
    }

    // MARK: account_status

    static let accountStatus = Tool(
        name: "account_status",
        description:
            "Reports the connected Google accounts (channel, handle, email, token status) that publish_youtube can upload to, the scopes publishing needs, and what to do when none is usable. Takes no project. Call it before publish_youtube; if no account is connected, stop and ask the user to connect one in Settings.",
        inputSchema: Schema.object("No arguments.", properties: [:]),
        outputSchema: Schema.object(
            "Connected accounts.",
            properties: [
                "configured": Schema.bool("False when no OAuth client is configured (nothing can connect)."),
                "accounts": Schema.array(
                    "Connected accounts.",
                    items: Schema.object(
                        "One account.",
                        properties: [
                            "id": Schema.string("Account id; pass it as accountId to publish_youtube."),
                            "provider": Schema.string("google."),
                            "email": Schema.string("The Google account's email."),
                            "displayName": Schema.string("The Google account's display name."),
                            "channelId": Schema.string("The YouTube channel id."),
                            "channelTitle": Schema.string("The YouTube channel title."),
                            "channelHandle": Schema.string("The channel's @handle."),
                            "tokenStatus": Schema.enum(
                                "valid, expired (refreshes on use), or reauthorizationRequired (reconnect).",
                                ["valid", "expired", "reauthorizationRequired"]),
                            "scopes": Schema.array("Granted scopes.", items: Schema.string("A scope.")),
                            "connectedAt": Schema.string("When the account was connected (ISO-8601)."),
                        ], required: ["id", "provider", "tokenStatus", "scopes", "connectedAt"])),
                "requiredScopes": Schema.array(
                    "Scopes publishing needs.", items: Schema.string("A scope.")),
                "hint": Schema.string("What to do when no account is usable."),
                "note": Schema.string("Present when uploads are forced private (unaudited project)."),
            ], required: ["configured", "accounts", "requiredScopes"]),
        annotations: .readOnly(title: "Account status"), examples: [.object([:])]
    ) { _, context in
        guard let provider = context.services.accounts[.google] else { throw ToolError.serviceUnavailable("accounts") }
        let accounts = await provider.accounts()
        let publisher = context.services.publishers[.youtube]
        let requiredScopes = publisher?.requiredScopes ?? []
        var o: [String: JSONValue] = [
            "configured": .bool(provider.isConfigured),
            "accounts": .array(accounts.map(accountJSON)),
            "requiredScopes": .array(requiredScopes.map { .string($0) }),
        ]
        var lines: [String] = []
        if !provider.isConfigured {
            o["hint"] = .string("No Google OAuth client is configured; publishing is unavailable")
            lines.append("Publishing is not configured.")
        } else if accounts.isEmpty {
            o["hint"] = .string(connectHint)
            lines.append("No Google account is connected. \(connectHint).")
        } else if accounts.contains(where: { $0.tokenStatus.needsReauthorization }) {
            o["hint"] = .string(reconnectHint)
        }
        for account in accounts {
            let who = [account.channelTitle, account.channelHandle.map { "(\($0))" }].compactMap { $0 }
                .joined(separator: " ")
            let status = tokenStatusName(account.tokenStatus)
            lines.append(
                "Connected as \(who.isEmpty ? account.id : who), \(account.email ?? account.id) [\(status)]"
                    + (account.tokenStatus.needsReauthorization ? ": \(reconnectHint)" : ""))
        }
        if let publisher {
            let capabilities = await publisher.capabilities()
            if !capabilities.publicUploadsAllowed {
                let note = capabilities.note ?? PublishCapabilities.unauditedNote
                o["note"] = .string(note)
                lines.append(note + ".")
            }
        }
        return ToolOutput(structured: .object(o), text: lines.joined(separator: "\n"))
    }

    // MARK: Building the request

    /// Either the request, or the error output that explains why it could not be built.
    enum Built {
        case success(PublishRequest)
        case failure(ToolOutput)
    }

    static func buildRequest(
        _ input: ToolInput, publishId: String, account: ConnectedAccount, render: RenderRecord, fileURL: URL,
        sequence: Sequence, project: Project, context: ToolContext
    ) async throws -> Built {
        let title = try ToolSupport.requireString(input, "title")
        let privacyName = ToolSupport.string(input, "privacy") ?? PublishPrivacy.private.rawValue
        guard let privacy = PublishPrivacy(rawValue: privacyName) else {
            throw ToolError.invalidInput("privacy: unknown value \(privacyName)")
        }
        var publishAt: Date?
        if input["publishAt"] != nil, !(input["publishAt"]?.isNull ?? true) {
            guard let date = try? ToolSupport.decode(input, "publishAt", as: Date.self) else {
                return .failure(.error(code: "invalidRequest", message: "publishAt: not an RFC 3339 date-time"))
            }
            guard privacy == .private else {
                return .failure(
                    .error(
                        code: "invalidRequest",
                        message: "publishAt requires privacy private (a scheduled video is private until then)"))
            }
            publishAt = date
        }
        let tags = input["tags"]?.arrayValue?.compactMap(\.stringValue) ?? []

        // Captions from the sequence's caption tracks (D7): timeline-relative cues, never the transcript.
        var captions: [PublishCaptionTrack] = []
        for id in input["captionTrackIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            guard let track = sequence.tracks.first(where: { $0.id.rawValue == id }), track.kind == .caption else {
                throw EditorError.notFound(id: id)
            }
            captions.append(
                PublishCaptionTrack(
                    trackId: track.id, language: track.language ?? "en", name: track.name, format: .srt,
                    cues: CaptionCues.make(from: track, in: sequence)))
        }

        // The thumbnail: one composed frame, written as JPEG under the cache.
        var thumbnail: PublishThumbnail?
        if let at = try ToolSupport.decode(input, "thumbnailAt", as: RationalTime.self) {
            guard let renderer = context.services.renderer else { throw ToolError.serviceUnavailable("renderer") }
            let layout = context.services.mediaLibrary?.layout ?? LibraryLayout.default
            let dir = layout.cacheDir.appendingPathComponent("publish", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let compiled = try await renderer.compile(sequence, assets: project.assets, options: .gesture)
            let image = try await renderer.frame(compiled, at: at, size: thumbnailSize)
            let url = dir.appendingPathComponent("\(publishId)-thumbnail.jpg")
            try ToolImages.jpeg(image, quality: 0.85).write(to: url, options: .atomic)
            thumbnail = PublishThumbnail(fileURL: url, sourceTime: at)
        }

        var width = sequence.width
        var height = sequence.height
        if case .fixed(let w, let h) = render.preset.size {
            width = w
            height = h
        }
        return .success(
            PublishRequest(
                destination: .youtube, accountId: account.id, renderId: render.id, fileURL: fileURL,
                expectedContentHash: render.outputHash, projectVersion: render.projectVersion, title: title,
                description: ToolSupport.string(input, "description") ?? "", tags: tags,
                categoryId: ToolSupport.string(input, "categoryId") ?? "22", language: captions.first?.language,
                privacy: privacy, publishAt: publishAt, madeForKids: nil,
                containsSyntheticMedia: input["containsSyntheticMedia"]?.boolValue ?? false,
                notifySubscribers: input["notifySubscribers"]?.boolValue ?? false, thumbnail: thumbnail,
                captions: captions, durationSeconds: render.receipt?.durationSeconds, width: width, height: height))
    }

    // MARK: The card

    /// Summary, rows in the plan's order, and the warnings the card paints orange (publish-plan.md 4.3 step 9).
    static func presentation(
        for request: PublishRequest, account: ConnectedAccount, render: RenderRecord,
        capabilities: PublishCapabilities, validationWarnings: [String]
    ) -> ApprovalPresentation {
        let channel = [account.channelTitle, account.channelHandle.map { "(\($0))" }].compactMap { $0 }
            .joined(separator: " ")
        var details: [ApprovalDetail] = [
            ApprovalDetail("Channel", channel.isEmpty ? account.id : channel),
            ApprovalDetail("Account", account.email ?? account.id),
            ApprovalDetail("Privacy", request.privacy.rawValue),
        ]
        if let at = request.publishAt { details.append(ApprovalDetail("Scheduled", isoString(at))) }
        details.append(
            ApprovalDetail("File", "\(request.fileURL.lastPathComponent), \(sizeString(of: request.fileURL))"))
        details.append(ApprovalDetail("Render", "\(render.preset.name), project v\(render.projectVersion)"))
        let thumbnail = request.thumbnail.map { thumb in
            thumb.sourceTime.map { "frame at \(secondsString($0)) s" } ?? thumb.fileURL.lastPathComponent
        }
        details.append(ApprovalDetail("Thumbnail", thumbnail ?? "none"))
        let captions =
            request.captions.isEmpty
            ? "none"
            : "\(request.captions.count) track(s): \(request.captions.map(\.language).joined(separator: ", "))"
        details.append(ApprovalDetail("Captions", captions))
        details.append(ApprovalDetail("AI disclosure", request.containsSyntheticMedia ? "declared" : "not declared"))
        details.append(ApprovalDetail("Made for kids", madeForKidsDetail))
        details.append(ApprovalDetail("Certification", certificationSentence))

        var warnings: [String] = []
        if request.privacy != .private {
            warnings.append("Privacy: \(request.privacy.rawValue)")
            if !capabilities.publicUploadsAllowed {
                warnings.append(capabilities.note ?? PublishCapabilities.unauditedNote)
            }
        }
        warnings.append(contentsOf: validationWarnings)
        return ApprovalPresentation(
            summary: "Publish \"\(request.title)\" to YouTube as \(request.privacy.rawValue.capitalized)",
            details: details, warnings: warnings)
    }

    // MARK: Waiting and answering

    /// Polls the ledger row until it is terminal or `seconds` have passed. The watcher keeps running
    /// either way; only this call's wait is bounded (publish-plan.md 4.3 step 12).
    static func waitForTerminalRow(
        _ publishId: String, in ledger: any PublishLedger, watcher: Task<Void, Never>, seconds: Int
    ) async {
        guard seconds > 0 else { return }
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if let row = try? await ledger.publish(publishId), row.status.isTerminal { return }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The tool's answer from a ledger row: status, ids, URLs, privacy, bytes, the receipt when done,
    /// and the warnings (validation, forced private, the made-for-kids notice). Never the session.
    static func statusOutput(
        _ row: PublishRecord, jobId: JobID?, projectId: ProjectID, account: ConnectedAccount,
        validationWarnings: [String]
    ) -> ToolOutput {
        let receipt = row.receipt
        var o: [String: JSONValue] = [
            "status": .string(row.status.rawValue), "publishId": .string(row.id), "renderId": .string(row.renderId),
            "title": .string(row.request.title), "requestedPrivacy": .string(row.request.privacy.rawValue),
            "projectId": .string(projectId.rawValue), "projectVersion": .number(Double(row.projectVersion)),
        ]
        if let jobId { o["jobId"] = .string(jobId.rawValue) }
        if let remoteId = row.remoteId { o["remoteId"] = .string(remoteId) }
        if let url = row.remoteURL { o["url"] = .string(url.absoluteString) }
        if let studio = receipt?.studioURL { o["studioUrl"] = .string(studio.absoluteString) }
        if let privacy = receipt?.privacy { o["privacy"] = .string(privacy.rawValue) }
        o["channelTitle"] = (receipt?.channelTitle ?? account.channelTitle).map { .string($0) } ?? .null
        if let sent = receipt?.bytesUploaded ?? row.bytesSent { o["bytesUploaded"] = .number(Double(sent)) }
        if let total = row.bytesTotal ?? row.session?.totalBytes { o["bytesTotal"] = .number(Double(total)) }
        if let resumed = receipt?.resumedCount ?? row.session?.resumedCount {
            o["resumedCount"] = .number(Double(resumed))
        }
        if let receipt { o["receipt"] = ToolSupport.json(receipt) }
        if row.status == .failed || row.status == .cancelled, let error = row.error { o["error"] = .string(error) }

        var warnings = validationWarnings
        if let receipt, receipt.privacy != receipt.requestedPrivacy {
            warnings.append(
                "Uploaded as \(receipt.privacy.rawValue); \(receipt.requestedPrivacy.rawValue) was requested")
        }
        if let receipt { warnings.append(contentsOf: receipt.warnings.filter { !warnings.contains($0) }) }
        warnings.append(madeForKidsNotice)
        o["warnings"] = .array(warnings.map { .string($0) })

        let title = row.request.title
        let text: String
        switch row.status {
        case .done:
            let privacy = receipt?.privacy.rawValue ?? row.request.privacy.rawValue
            let url = row.remoteURL?.absoluteString ?? receipt?.remoteURL.absoluteString ?? ""
            text = "Published \(title) to YouTube as \(privacy): \(url). \(madeForKidsNotice)."
        case .uploading:
            let fraction = row.session?.fraction ?? 0
            text = "Uploading \(title): \(Int((fraction * 100).rounded()))% (poll publish_status)"
        case .queued: text = "Queued \(title) for upload (poll publish_status)"
        case .processing: text = "Processing \(title) on YouTube (poll publish_status)"
        case .failed: text = "Publish of \(title) failed: \(row.error ?? "unknown error")"
        case .cancelled: text = "Publish of \(title) was cancelled"
        }
        return ToolOutput(structured: .object(o), text: text)
    }

    /// A `publish_status` row: the record without its session.
    static func publishRow(_ row: PublishRecord) -> JSONValue {
        let receipt = row.receipt
        var o: [String: JSONValue] = [
            "publishId": .string(row.id), "renderId": .string(row.renderId), "status": .string(row.status.rawValue),
            "requestedPrivacy": .string(row.request.privacy.rawValue), "title": .string(row.request.title),
            "accountId": .string(row.accountId), "projectVersion": .number(Double(row.projectVersion)),
            "requestedAt": ToolSupport.json(row.requestedAt),
        ]
        if let privacy = receipt?.privacy { o["privacy"] = .string(privacy.rawValue) }
        if let url = row.remoteURL { o["url"] = .string(url.absoluteString) }
        if let remoteId = row.remoteId { o["remoteId"] = .string(remoteId) }
        if let sent = row.bytesSent { o["bytesSent"] = .number(Double(sent)) }
        if let total = row.bytesTotal { o["bytesTotal"] = .number(Double(total)) }
        if let resumed = receipt?.resumedCount ?? row.session?.resumedCount {
            o["resumedCount"] = .number(Double(resumed))
        }
        if let channel = receipt?.channelTitle { o["channelTitle"] = .string(channel) }
        if row.status == .failed || row.status == .cancelled, let error = row.error { o["error"] = .string(error) }
        if let completed = row.completedAt { o["completedAt"] = ToolSupport.json(completed) }
        o["resumable"] = .bool(row.isResumable)
        return .object(o)
    }

    static func accountJSON(_ account: ConnectedAccount) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(account.id), "provider": .string(account.provider.rawValue),
            "tokenStatus": .string(tokenStatusName(account.tokenStatus)),
            "scopes": .array(account.scopes.map { .string($0) }), "connectedAt": ToolSupport.json(account.connectedAt),
        ]
        if let email = account.email { o["email"] = .string(email) }
        if let name = account.displayName { o["displayName"] = .string(name) }
        if let id = account.channelId { o["channelId"] = .string(id) }
        if let title = account.channelTitle { o["channelTitle"] = .string(title) }
        if let handle = account.channelHandle { o["channelHandle"] = .string(handle) }
        return .object(o)
    }

    static func tokenStatusName(_ status: AccountTokenStatus) -> String {
        switch status {
        case .valid: "valid"
        case .expired: "expired"
        case .reauthorizationRequired: "reauthorizationRequired"
        }
    }

    // MARK: Schema pieces

    /// The status fields `publish_youtube` answers with, shared by its done and in-flight answers.
    static let statusProperties: [String: JSONValue] = [
        "status": Schema.enum(
            "done, uploading, processing, queued, failed, cancelled, or approval_required.",
            PublishStatus.allCases.map(\.rawValue) + ["approval_required"]),
        "publishId": Schema.string("The idempotency key of this publish; reuse it on every retry."),
        "renderId": Schema.string("The render that was uploaded."),
        "title": Schema.string("The video title."),
        "remoteId": Schema.string("YouTube video id, once uploaded."),
        "url": Schema.string("https://youtu.be/<id>, once uploaded."),
        "studioUrl": Schema.string("YouTube Studio edit page, once done."),
        "privacy": Schema.string("The privacy YouTube reported after the upload (may differ from requestedPrivacy)."),
        "requestedPrivacy": Schema.string("The privacy that was requested."),
        "channelTitle": Schema.string("The channel uploaded to."),
        "bytesUploaded": Schema.integer("Bytes confirmed so far."),
        "bytesTotal": Schema.integer("File size."),
        "resumedCount": Schema.integer("How many times the upload resumed."),
        "receipt": Schema.any("The PublishReceipt, when done."),
        "error": Schema.string("Why the publish failed, when it did."),
        "warnings": Schema.array(
            "Validation warnings, a forced-private notice, and the made-for-kids reminder.",
            items: Schema.string("Warning.")),
        "projectId": Schema.string("The project the call addressed."),
        "projectVersion": Schema.integer("The project version the render was made from."),
    ]

    static let publishRowProperties: [String: JSONValue] = [
        "publishId": Schema.string("The publish id."),
        "renderId": Schema.string("The render uploaded."),
        "status": Schema.enum("Row status.", PublishStatus.allCases.map(\.rawValue)),
        "requestedPrivacy": Schema.string("The privacy requested."),
        "privacy": Schema.string("The privacy YouTube reported, once done."),
        "title": Schema.string("The video title."),
        "accountId": Schema.string("The account uploaded with."),
        "url": Schema.string("https://youtu.be/<id>, once uploaded."),
        "remoteId": Schema.string("YouTube video id, once uploaded."),
        "bytesSent": Schema.integer("Bytes confirmed so far."),
        "bytesTotal": Schema.integer("File size."),
        "resumedCount": Schema.integer("How many times the upload resumed."),
        "channelTitle": Schema.string("The channel uploaded to, once done."),
        "error": Schema.string("Why it failed, for failed and cancelled rows."),
        "projectVersion": Schema.integer("The project version the render was made from."),
        "requestedAt": Schema.string("When the publish was requested (ISO-8601)."),
        "completedAt": Schema.string("When it reached a terminal state (ISO-8601)."),
        "resumable": Schema.bool(
            "True for a failed or cancelled row that can continue: call publish_youtube with its publishId."),
    ]

    static func withDefault(_ schema: JSONValue, _ value: JSONValue) -> JSONValue {
        var s = schema
        s["default"] = value
        return s
    }

    static func withFormat(_ schema: JSONValue, _ format: String) -> JSONValue {
        var s = schema
        s["format"] = .string(format)
        return s
    }

    static func withLimits(_ schema: JSONValue, min: Int? = nil, max: Int? = nil) -> JSONValue {
        var s = schema
        if let min { s["minLength"] = .number(Double(min)) }
        if let max { s["maxLength"] = .number(Double(max)) }
        return s
    }

    // MARK: Formatting

    static func isoString(_ date: Date) -> String {
        (try? JSONValue(encoding: date))?.stringValue ?? date.formatted(.iso8601)
    }

    static func sizeString(of url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        guard let bytes = size?.int64Value else { return "size unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func secondsString(_ time: RationalTime) -> String {
        String(format: "%.1f", time.seconds)
    }
}
