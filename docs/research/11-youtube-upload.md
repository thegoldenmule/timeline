# Uploading to YouTube from a native macOS app (YouTube Data API v3)

Research date: 2026-09-09. Scope: how the editor publishes a rendered export to the user's own YouTube channel: OAuth for a desktop app, the resumable upload protocol, the metadata surface, post-upload processing, thumbnails, captions from the app's word-level transcripts, Shorts, quota and policy obligations, file constraints, and existing implementations. Primary sources are Google's API reference, the YouTube Help Center, the API Services Terms and Developer Policies, and Apple's URLSession documentation and DTS forum answers. Each section ends with the implication for this app.

Three things changed recently and contradict most tutorials still in circulation:

1. **`videos.insert` no longer costs 1,600 units.** On 2025-12-04 Google cut the cost "from approximately 1600 units to approximately 100 units", and on 2026-06-01 it moved `videos.insert` and `search.list` into their own quota buckets: each is "100 per day. The quota cost is 1 per call." The 10,000-unit daily pool now covers everything else ([revision history](https://developers.google.com/youtube/v3/revision_history), [quota calculator](https://developers.google.com/youtube/v3/determine_quota_cost)). An unaudited project can therefore upload 100 videos a day and still have 10,000 units for captions, thumbnails, and polling.
2. **Uploads from unaudited projects are locked to private.** "All videos uploaded via the `videos.insert` endpoint from unverified API projects created after 28 July 2020 will be restricted to private viewing mode. To lift this restriction, each API project must undergo an audit to verify compliance with the Terms of Service" ([videos.insert](https://developers.google.com/youtube/v3/docs/videos/insert)). Until the audit passes, `privacyStatus: public` is silently downgraded and `publishAt` scheduling cannot work. The audit is the gating item on the Google side, not quota.
3. **OAuth "Testing" projects expire the user's grant after 7 days** and cap test users at 100 ([Google Auth Platform: app audience](https://support.google.com/cloud/answer/15549945), [OAuth 2.0 refresh-token expiry](https://developers.google.com/identity/protocols/oauth2)). The YouTube scopes are "sensitive", so shipping to real users requires brand verification and a demo video ([verification requirements](https://support.google.com/cloud/answer/13464321)).

---

## 1. Authentication for a desktop app

| Item | Fact | Source |
|---|---|---|
| Client type | "Desktop app" OAuth client; the client secret "is not treated as a secret" for installed apps, and PKCE (`code_verifier` of at least 43 high-entropy characters) is used instead | [OAuth 2.0 for Mobile & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app) |
| Redirect | Loopback: `http://127.0.0.1:PORT` or `http://[::1]:PORT`, the app listens on an ephemeral port. Custom URI schemes still work on macOS but Google is retiring them elsewhere; the copy-paste OOB flow is gone | same |
| Browser | Must be the system browser; embedded web views return `disallowed_useragent` | same |
| Scopes | `videos.insert`, `thumbnails.set`, `playlistItems.insert`, `channels.list` all accept `https://www.googleapis.com/auth/youtube.force-ssl`; `captions.insert` accepts only `youtube.force-ssl` or `youtubepartner`, not `youtube.upload` | [videos.insert](https://developers.google.com/youtube/v3/docs/videos/insert), [captions.insert](https://developers.google.com/youtube/v3/docs/captions/insert), [thumbnails.set](https://developers.google.com/youtube/v3/docs/thumbnails/set) |
| Token lifetime | Refresh tokens last until revoked, six months unused, or the 100-tokens-per-account-per-client cap evicts the oldest; in a project with publishing status Testing they expire after 7 days | [OAuth 2.0 overview](https://developers.google.com/identity/protocols/oauth2) |
| Verification | Sensitive and restricted scopes require OAuth app verification: a homepage on a domain you own, a privacy policy on that domain linked from the consent screen, domain verification, and a demo video showing the OAuth grant and each scope in use; restricted scopes additionally need an annual third-party security assessment (YouTube scopes are sensitive, not restricted) | [verification requirements](https://support.google.com/cloud/answer/13464321) |
| Library | AppAuth-iOS supports macOS 12+ with `OIDRedirectHTTPHandler` running the loopback server; SwiftPM | [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) |

*Implication:* request the single scope `youtube.force-ssl` (captions force it; the Developer Policies III.D.2.b forbid asking for scopes not in use, and this one scope covers the whole upload flow). Store the refresh token in the keychain. During development the project sits in Testing, so expect re-consent weekly; before any external user, publish to production and submit for verification. AppAuth is fine, but the flow is small enough (authorize URL, loopback listener, token POST, refresh POST) that a dependency-free implementation in `Providers` is reasonable.

---

## 2. The resumable upload protocol, end to end

Source for every request below: [Resumable Uploads](https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol), with the `Content-Range` grammar cross-checked against [Cloud Storage resumable uploads](https://docs.cloud.google.com/storage/docs/performing-resumable-uploads) and [Drive uploads](https://developers.google.com/drive/api/guides/manage-uploads), which use the same upload server.

**Step 1: start a session.** The JSON body is the video resource; `part` names the parts the body sets and the parts the final response returns.

```http
POST /upload/youtube/v3/videos?uploadType=resumable&part=snippet,status HTTP/1.1
Host: www.googleapis.com
Authorization: Bearer ACCESS_TOKEN
Content-Length: 312
Content-Type: application/json; charset=UTF-8
X-Upload-Content-Length: 2147483648
X-Upload-Content-Type: video/mp4

{
  "snippet": {
    "title": "Tirana set, night two",
    "description": "Recorded 2026-08-30.",
    "tags": ["live", "synth"],
    "categoryId": "10",
    "defaultLanguage": "en"
  },
  "status": {
    "privacyStatus": "private",
    "selfDeclaredMadeForKids": false,
    "containsSyntheticMedia": false
  }
}
```

```http
HTTP/1.1 200 OK
Location: https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=xa298sd_f&part=snippet,status
Content-Length: 0
```

The `Location` value is the session URI. Persist it, the file path, the total size, and the metadata before sending a byte. `notifySubscribers=false` goes on this URL as a query parameter (default `true`).

**Step 2a: single request.** Simplest and, per Google, usually best: "larger chunks are more efficient"; the Python sample uses `chunksize=-1` (the whole file) and still resumes from the last byte on failure ([Upload a Video](https://developers.google.com/youtube/v3/guides/uploading_a_video)).

```http
PUT https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=xa298sd_f HTTP/1.1
Authorization: Bearer ACCESS_TOKEN
Content-Length: 2147483648
Content-Type: video/mp4

<bytes>
```

**Step 2b: chunked.** Every chunk except the last must be the same size and a multiple of 256 KiB (262,144 bytes); Cloud Storage recommends at least 8 MiB. Non-final chunks get `308 Resume Incomplete`; the final one gets `201 Created` with the video resource.

```http
PUT SESSION_URI HTTP/1.1
Authorization: Bearer ACCESS_TOKEN
Content-Length: 33554432
Content-Type: video/mp4
Content-Range: bytes 0-33554431/2147483648

<bytes>
```

```http
HTTP/1.1 308 Resume Incomplete
Range: bytes=0-33554431
```

Use the `Range` header, not your own arithmetic, to decide the next offset: the server may have persisted fewer bytes than you sent. A `308` with no `Range` header means nothing was persisted. The response may carry a new `Location`; if so, use it for subsequent chunks (Drive documents this; treat it as possible on YouTube). If the total size is unknown at start (it never is for an exported file), the form is `Content-Range: bytes 0-33554431/*`.

**Step 3: query status after an interruption.**

```http
PUT SESSION_URI HTTP/1.1
Authorization: Bearer ACCESS_TOKEN
Content-Length: 0
Content-Range: bytes */2147483648
```

Responses: `308` with `Range: bytes=0-N` (resume at N+1), `308` without `Range` (start at 0), `200`/`201` (the upload had completed; the body is the video resource), `404` (session expired; go back to step 1).

**Step 4: resume.**

```http
PUT SESSION_URI HTTP/1.1
Authorization: Bearer ACCESS_TOKEN
Content-Length: 2113929216
Content-Range: bytes 33554432-2147483647/2147483648

<remaining bytes>
```

**Final response.** `201 Created` (or `200 OK`) with the video resource for the requested parts; `id` is the video id and `status.uploadStatus` is `uploaded` at this point, not `processed`.

```json
{
  "kind": "youtube#video",
  "id": "dQw4w9WgXcQ",
  "snippet": { "title": "Tirana set, night two", "...": "..." },
  "status": { "uploadStatus": "uploaded", "privacyStatus": "private", "..." : "..." }
}
```

**Retries.** On `500`, `502`, `503`, `504` (and connection errors) query status and resume with exponential backoff; honour `Retry-After` when present. The official Python sample caps at 10 retries with `sleep(random() * 2**retry)`. Other `4xx` responses are permanent for that session: `401` means refresh the token and retry the same request, `403 quotaExceeded` means wait for the daily reset (midnight Pacific), `400 uploadLimitExceeded` means the channel's own daily upload allowance is spent ("a YouTube platform restriction and is entirely separate from your Google Cloud project's API quota", [errors](https://developers.google.com/youtube/v3/docs/errors)).

**Session lifetime.** YouTube's page says only that "each resumable session URI has a finite lifetime and eventually expires" and that a `404` means start over; Drive and Cloud Storage document one week for the same upload server. Design for expiry rather than a number: persist the session, and on any `404` from the status query create a new session with the same metadata.

*Implication:* the protocol is four request shapes and one state machine. A whole-file `PUT` with resume-on-failure is the right default on a Mac on Wi-Fi or Ethernet; chunking at 32 MiB buys finer progress and smaller retransmits on flaky links at the cost of one round trip per chunk.

---

## 3. Metadata fields

All from the [video resource reference](https://developers.google.com/youtube/v3/docs/videos) and [videos.insert](https://developers.google.com/youtube/v3/docs/videos/insert) unless noted. The settable fields on insert are exactly: `snippet.title`, `snippet.description`, `snippet.tags[]`, `snippet.categoryId`, `snippet.defaultLanguage`, `localizations.*`, `status.embeddable`, `status.license`, `status.privacyStatus`, `status.publicStatsViewable`, `status.publishAt`, `status.selfDeclaredMadeForKids`, `status.containsSyntheticMedia`, `recordingDetails.recordingDate`.

| Field | Rule | Error when violated |
|---|---|---|
| `snippet.title` | Required. "maximum length of 100 characters and may contain all valid UTF-8 characters except `<` and `>`" | `invalidTitle` (also for empty) |
| `snippet.description` | "maximum length of 5000 bytes", same character rule. Bytes, not characters: emoji and CJK count 3-4 each | `invalidDescription` |
| `snippet.tags[]` | "maximum length of 500 characters"; commas between items count toward the limit, and a tag containing a space is counted with surrounding quotes | `invalidTags` |
| `snippet.categoryId` | String id; must be `assignable` in the channel's region. Fetch with `videoCategories.list?part=snippet&regionCode=US&hl=en` (1 unit) and filter `snippet.assignable == true` ([videoCategories.list](https://developers.google.com/youtube/v3/docs/videoCategories/list)). Assignable ids in the US as of this writing: 1 Film & Animation, 2 Autos & Vehicles, 10 Music, 15 Pets & Animals, 17 Sports, 19 Travel & Events, 20 Gaming, 22 People & Blogs, 23 Comedy, 24 Entertainment, 25 News & Politics, 26 Howto & Style, 27 Education, 28 Science & Technology, 29 Nonprofits & Activism. Id 42 "Shorts" exists but is not assignable | `invalidCategoryId` |
| `snippet.defaultLanguage` | BCP-47 tag of the title and description; `defaultAudioLanguage` is the spoken language (read-only on insert but settable via `videos.update`) | |
| `status.privacyStatus` | `private`, `unlisted`, `public`. Public is downgraded to private until the project is audited | |
| `status.publishAt` | ISO 8601 (`YYYY-MM-DDThh:mm:ss.sZ`); "can be set only if the privacy status of the video is private" and the video "has never been published". YouTube flips it to public at that time | `invalidPublishAt` |
| `status.selfDeclaredMadeForKids` | The COPPA declaration. The API Terms (section 9.1) require an uploading client either to let the user set this before upload or to warn them to set it on youtube.com immediately after | |
| `status.containsSyntheticMedia` | Added 2024-10-30: "allows the channel owner to disclose that a video contains realistic Altered or Synthetic (A/S) content". Maps to the "AI use" toggle in Studio | |
| `status.license` | `youtube` (default) or `creativeCommon` | |
| `status.embeddable` | Boolean, default true | |
| `status.publicStatsViewable` | Boolean, default true | |
| `notifySubscribers` | Query parameter on `videos.insert`, default `true` | |
| `localizations.{lang}.title/description` | Per-language title and description; needs `part=localizations` | |
| `recordingDetails.recordingDate` | ISO 8601; the app has this from the QuickTime creation date | |
| `Slug` header | Optional original filename on the session-start request | `invalidFilename` |

**What must be disclosed as altered or synthetic** ([Disclosing use of altered or synthetic content](https://support.google.com/youtube/answer/14328491)): realistic content that "makes a real person appear to say or do something they didn't do", "alters footage of a real event or place", or "generates a realistic scene that didn't actually occur". Explicitly exempt: "beauty filters", "color adjustments", "voice cloning of one's own voice", "caption creation", "video upscaling", and clearly unrealistic or animated content. Since 2026-05-27 YouTube also auto-labels when its own signals (including C2PA metadata) detect significant photorealistic generation, the label sits directly under the player for long-form and as an overlay on Shorts, and repeat non-disclosure risks removal or Partner Program suspension ([YouTube blog, 2026-05-27](https://blog.youtube/news-and-events/improving-ai-labels-viewers-creators/)).

*Implication:* the app knows which operations it performed. Captions, colour, cuts, transcript-driven edits, upscaling, and the user's own TTS voice do not trigger disclosure; generated b-roll, AI video garnish, synthetic voices of other people, and altered footage of real events do. Compute a default for `containsSyntheticMedia` from the project's provenance (which providers produced which assets), show it to the user, and never send it without their confirmation.

---

## 4. After the upload

**Processing.** Poll `GET https://www.googleapis.com/youtube/v3/videos?part=status,processingDetails&id=VIDEO_ID` (1 unit). `status.uploadStatus` moves `uploaded` -> `processed`, or ends in `failed` (with `status.failureReason`: `codec`, `conversion`, `emptyFile`, `invalidFile`, `tooSmall`, `uploadAborted`) or `rejected` (with `status.rejectionReason`: `claim`, `copyright`, `duplicate`, `inappropriate`, `legal`, `length`, `termsOfUse`, `trademark`, `uploaderAccountClosed`, `uploaderAccountSuspended`). `processingDetails.processingStatus` is `processing`, `succeeded`, `failed`, or `terminated`; `processingProgress` carries `partsTotal`, `partsProcessed`, and `timeLeftMs`; `processingFailureReason` is `uploadFailed`, `transcodeFailed`, `streamingFailed`, or `other`; `thumbnailsAvailability` and `fileDetailsAvailability` say when `thumbnails.set` and `part=fileDetails` are meaningful. `fileDetails` (owner-only) reports what YouTube saw: container, codecs, bitrates, resolution, which is the cheap way to confirm an HDR export was read as HDR ([video resource](https://developers.google.com/youtube/v3/docs/videos)). The `length` rejection is what an unverified channel gets for a video over 15 minutes.

**Thumbnails.** `POST https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=ID` with the image as the body; about 50 units; `image/jpeg` or `image/png`; API maximum 2 MB (Studio on desktop allows 50 MB, the API does not); errors `invalidImage`, `videoNotFound`, `forbidden`, and `429 uploadRateLimitExceeded` when the channel has set too many thumbnails recently ([thumbnails.set](https://developers.google.com/youtube/v3/docs/thumbnails/set)). YouTube resizes to fit "without changing its aspect ratio, which may result in black bars" ([thumbnails](https://developers.google.com/youtube/v3/docs/thumbnails)); the Help Center recommends 16:9 for videos and 9:16 for Shorts, minimum width 640, JPG or PNG ([custom thumbnails](https://support.google.com/youtube/answer/72431)). Custom thumbnails need a phone-verified account (section 7).

**Captions.** `POST https://www.googleapis.com/upload/youtube/v3/captions?uploadType=multipart&part=snippet` (400 units, 100 MB max, scope `youtube.force-ssl`):

```http
POST /upload/youtube/v3/captions?uploadType=multipart&part=snippet HTTP/1.1
Host: www.googleapis.com
Authorization: Bearer ACCESS_TOKEN
Content-Type: multipart/related; boundary=b

--b
Content-Type: application/json; charset=UTF-8

{"snippet":{"videoId":"dQw4w9WgXcQ","language":"en","name":"English","isDraft":false}}
--b
Content-Type: application/octet-stream

1
00:00:00,000 --> 00:00:02,400
Welcome back to the channel.

--b--
```

`snippet.language` is a BCP-47 tag; `snippet.name` is at most 150 characters; `snippet.trackKind` defaults to `standard`; `snippet.isDraft: true` hides the track; a second track with the same language and name returns `409 conflict`, so use `captions.update` (450 units) for replacements. The `sync` parameter (upload untimed text and let YouTube align it) was deprecated 2024-03-13 and stopped working 2024-04-12, so the file must carry timings ([captions.insert](https://developers.google.com/youtube/v3/docs/captions/insert), [captions resource](https://developers.google.com/youtube/v3/docs/captions), [revision history](https://developers.google.com/youtube/v3/revision_history)). Accepted formats: SRT and SBV ("only basic versions... no style info"), WebVTT (positioning supported, styling limited to `<b>`, `<i>`, `<u>`), TTML/DFXP (styling and positioning), SAMI, LRC, MPsub, and the broadcast formats SCC, EBU-STL, and others ([supported caption formats](https://support.google.com/youtube/answer/2734698)). After processing, `snippet.status` is `serving`, `syncing`, or `failed` with `failureReason` `unknownFormat`, `unsupportedFormat`, or `processingFailed`.

**Playlists.** `playlistItems.insert` (50 units) with `snippet.playlistId` and `snippet.resourceId: { kind: "youtube#video", videoId }`; optional `snippet.position`; `playlists.insert` is also 50 units. Listing the user's playlists to pick from is `playlists.list?mine=true` (1 unit) ([playlistItems.insert](https://developers.google.com/youtube/v3/docs/playlistItems/insert)).

*Implication:* the app already has word-level transcripts with 60 ms grid timings (see 04 and the speech spike), so the caption upload is a formatter: group words into cues (about 2 lines, 32-42 characters, 1-7 s), emit SRT for maximum compatibility or WebVTT when positioning matters, and post one track per language. Karaoke-style word highlighting does not survive YouTube's caption pipeline; that is only for burned-in captions rendered by the compositor. Uploading captions costs four times the upload itself; a typical publish (insert 1 + poll 5 + thumbnail 50 + caption 400 + playlist 50) is about 500 units, so the daily pool supports about 20 fully-dressed publishes.

---

## 5. Shorts

There is no Shorts flag in the API and no `#Shorts` requirement. YouTube classifies by shape and length: "Videos uploaded after October 15, 2024 with a square or vertical aspect ratio up to three minutes" are Shorts; to keep a vertical video out of the Shorts feed, "use a wider aspect ratio such as 16:9" ([three-minute Shorts](https://support.google.com/youtube/answer/15424877), [Shorts basics](https://support.google.com/youtube/answer/10059070), which also notes a 1080p maximum for Shorts). The `videoCategory` id 42 "Shorts" is not assignable. `search.list` can filter with `videoDuration=short` and `videoDimension`, but that is discovery, not upload. Shorts thumbnails are 9:16.

*Implication:* a "Publish as Short" preset is an export preset (1080x1920, at most 180 s, 9:16 thumbnail), not an API option. The UI should warn when a portrait export exceeds 3:00 (it becomes an oddly shaped long-form video) and when a square-or-vertical export under 3:00 is meant to be long-form (it will not be).

---

## 6. Quota, terms, and policies

**Quota** ([quota calculator](https://developers.google.com/youtube/v3/determine_quota_cost), [Quota and Compliance Audits](https://developers.google.com/youtube/v3/guides/quota_and_compliance_audits)). Default per project per day: 100 `videos.insert` calls, 100 `search.list` calls, and 10,000 units for everything else. "Every API request, even if invalid, will cost at least one quota point."

| Method | Cost |
|---|---|
| `videos.insert` | 1 call from the 100-call Video Uploads bucket (was about 1,600 units before 2025-12-04) |
| `videos.list` | 1 |
| `videos.update` | 50 |
| `channels.list` | 1 |
| `videoCategories.list`, `i18nLanguages.list` | 1 |
| `thumbnails.set` | 50 |
| `captions.insert` / `captions.update` / `captions.list` | 400 / 450 / 50 |
| `playlists.insert`, `playlistItems.insert` | 50 each |

Failed uploads count against the 100. Chunk `PUT`s to the session URI are not API calls and do not consume quota. More quota requires the [Audit and Quota Extension Form](https://support.google.com/youtube/contact/yt_api_form); the same form is the compliance audit that lifts the private-only restriction, and an audited project can apply for further extensions without a new audit for 12 months. The form asks for the project id, the use case, each endpoint used, how users authorize, how data is stored and deleted, expected daily and peak traffic, and links to the privacy policy and terms; community reports put review at several weeks with follow-up questions.

**Terms of Service** ([API Services Terms](https://developers.google.com/youtube/terms/api-services-terms-of-service), section 9.1): where the user clicks upload, the client must display "By clicking 'upload,' you certify that the content you are uploading complies with the YouTube Terms of Service". A non-child-directed client must either "enable users... to designate their content as Made for Kids via your API Client before they can upload" or "notify users... that if they upload content... that is Made for Kids, then they must immediately go to YouTube on desktop to declare" it. YouTube may "monitor, review and inspect your API Client(s)... at any time and without further notice" (section 6) and may set quotas at any time (section 15).

**Developer Policies** ([Developer Policies](https://developers.google.com/youtube/terms/developer-policies)) most relevant to an editor that uploads for the user:

| Section | Requirement | What it means here |
|---|---|---|
| III.E.3.d | Express user consent before the client acts to "insert, share, update, or delete data or content on the authorizing user's behalf" | The agent tool cannot publish on its own; the human confirms every upload (the `ApprovalPolicy` gate) |
| III.I.2 | Must not "automate or trigger views, uploads, comments, likes, dislikes, or other actions without the user's prior specific and express consent" | No batch or scheduled bulk publishing without a per-item confirmation |
| III.C.3 | Must not "modify user-provided values before sending them to YouTube by truncating, appending, or otherwise altering those values unless the user has explicitly consented" | Show the agent's proposed title and description as editable; do not silently truncate to 100 chars or 5,000 bytes, validate and ask |
| III.D.2.b | Request only scopes currently used | One scope, `youtube.force-ssl` |
| III.E.4.c, III.E.4.g, III.D.2.b.i | Stored API data refreshed or deleted after 30 days; deletion on request or revocation within 7 days | Keep only the video id, URL, and processing status per export; a "Disconnect YouTube" button that deletes tokens and cached channel data |
| III.A.2 | Privacy policy "prominently displayed and easily accessible" explaining what user data is accessed and stored | Needed for OAuth verification anyway |
| III.F.2 | YouTube brand features where YouTube content is shown; "never use YouTube branding images in conjunction with the overall name or description of your application", no "YouTube" or "YT" in the app name | A "Share to YouTube" button with the official icon linking to the uploaded video is correct ([branding guidelines](https://developers.google.com/youtube/terms/branding-guidelines)) |
| III.H | Must not interfere with audits; must provide test accounts on request | Keep a reviewer account and a demo project |
| Required Minimum Functionality | An uploading client must let the user set title, description, and choose public, private, or unlisted | Those three are mandatory UI, not agent-only fields ([RMF](https://developers.google.com/youtube/terms/required-minimum-functionality)) |

*Implication:* quota is no longer the constraint; the audit is. Plan the audit submission as a milestone before public beta, with the privacy policy, homepage, demo video, and OAuth verification done in the same pass.

---

## 7. File constraints and encoding

**Containers and codecs.** Consumer uploads accept ".MOV, .MPEG-1, .MPEG-2, .MPEG4, .MP4, .MPG, .AVI, .WMV, .MPEGPS, .FLV, 3GPP, WebM, DNxHR, ProRes, CineForm, HEVC (H.265)"; audio-only files "can't be uploaded to create a YouTube video" ([supported formats](https://support.google.com/youtube/troubleshooter/2888402)). The `videos.insert` media body accepts `video/*` or `application/octet-stream`, maximum 256 GB; the platform limit is "256 GB or 12 hours, whichever is less" ([upload limits](https://support.google.com/youtube/answer/71673)).

**Recommended encoding** ([upload encoding settings](https://support.google.com/youtube/answer/1722171)): MP4 with the "moov atom at the front of the file (Fast Start)" and "No Edit Lists (or the video might not get processed correctly)"; H.264 High Profile, progressive, 2 consecutive B-frames, closed GOP of half the frame rate, CABAC, VBR, 4:2:0; AAC-LC (or Opus) at 48 kHz, 384 kbps stereo; upload at the recorded frame rate (24, 25, 30, 48, 50, 60), deinterlaced; BT.709 for SDR.

| Resolution | SDR 24-30 fps | SDR 48-60 fps | HDR 24-30 fps | HDR 48-60 fps |
|---|---|---|---|---|
| 2160p | 35-45 Mbps | 53-68 Mbps | 44-56 Mbps | 66-85 Mbps |
| 1440p | 16 Mbps | 24 Mbps | 20 Mbps | 30 Mbps |
| 1080p | 8 Mbps | 12 Mbps | 10 Mbps | 15 Mbps |
| 720p | 5 Mbps | 7.5 Mbps | 6.5 Mbps | 9.5 Mbps |
| 480p | 2.5 Mbps | 4 Mbps | not supported | not supported |

These are H.264 targets; YouTube re-encodes everything, so HEVC at roughly 60-70% of these rates is equivalent. Vertical and square content is fine ("the player automatically adapts itself").

**HDR** ([upload HDR videos](https://support.google.com/youtube/answer/7126552)): transfer "PQ or HLG (Rec. 2100)", primaries "Rec. 2020", matrix "Rec. 2020 non-constant luminance", 10 or 12 bit; recommended codecs "VP9 Profile 2", "AV1", "HEVC/H.265"; ProRes 422/4444, DNxHR HQX, and 10-bit H.264 are accepted "but require very high bitrates". Required metadata is only the transfer function, primaries, and matrix (the `colr` box); PQ content should also carry "SMPTE ST 2086 mastering metadata" and "CEA 861-3 MaxFALL and MaxCLL", and if they are absent YouTube assumes "Sony BVM-X300 mastering display" values. HLG needs no mastering metadata. YouTube performs "automated SDR downconversion" and accepts an optional `.cube` 3D LUT to steer it. Dolby Vision is not mentioned anywhere on the page; Apple's own guidance for iPhone footage is "export an HLG master file... then upload the video file to YouTube" ([Edit HDR video recorded on an iPhone](https://support.apple.com/en-us/102241)), which matches platform decision 2 in the README (HEVC Main10 HLG, never claim Dolby Vision).

*Implication for the exporter:* `AVAssetExportSession` with an HEVC Main10 preset writes the `colr` box (primaries 9, transfer 18 for HLG, matrix 9) from the composition's colour properties, which is exactly what YouTube reads; there is nothing extra to emit for HLG, and the DV RPU the iPhone recorded is dropped anyway. Set `shouldOptimizeForNetworkUse = true` for Fast Start. The "No Edit Lists" line is the one to verify in the export smoke test: AVFoundation writes an `edts` box for AAC priming and for compositions whose tracks do not start at zero, every phone and NLE does the same, and YouTube processes those files, so the sentence targets pathological edit lists rather than priming, but `ffprobe -show_streams` (`start_time`) and an actual test upload with `part=fileDetails,processingDetails` should confirm before the preset is frozen. A PQ export would need `mdcv`/`clli` boxes that `AVAssetExportSession` only writes when the source or the compositor supplies them; HLG avoids the problem and is what the sources are.

---

## 8. Verified-account requirements

Phone verification at [youtube.com/verify](https://www.youtube.com/verify) unlocks "upload videos longer than 15 minutes", "add custom thumbnails", live streaming, and copyright-claim appeals; one phone number verifies at most 2 channels per year ([verify your account](https://support.google.com/youtube/answer/171664)). YouTube calls this tier "intermediate features"; "advanced features" (higher daily upload limits, clickable description links, chapters, RSS upload, monetization) need channel history or ID/video verification ([feature tiers](https://support.google.com/youtube/answer/9890437)). Daily upload limits per channel are enforced but not published; the API surfaces them as `uploadLimitExceeded`, and the thumbnail equivalent is `429 uploadRateLimitExceeded`.

*Implication:* before starting an upload longer than 15 minutes or with a thumbnail, the app cannot query verification status directly (the `channels` resource does not expose it), so handle the outcomes: a `length` rejection on the video and a `403 forbidden` on `thumbnails.set` both get a message that links to youtube.com/verify. Warn pre-emptively for exports over 15:00 on a channel the app has not seen succeed with a long upload before.

---

## 9. Existing implementations and URLSession pitfalls

| Code | State | What to take from it |
|---|---|---|
| [google-api-objectivec-client-for-rest](https://github.com/google/google-api-objectivec-client-for-rest) + [gtm-session-fetcher](https://github.com/google/gtm-session-fetcher) | Maintained, Objective-C, SwiftPM, macOS sample `YouTubeSampleWindowController.m` does `GTLRYouTubeQuery_VideosInsert` with a progress block | `GTMSessionUploadFetcher` speaks the newer `X-Goog-Upload-Protocol: resumable` variant (`X-Goog-Upload-Command: start | upload | finalize | query | cancel`, `X-Goog-Upload-Offset`, `X-Goog-Upload-Chunk-Granularity`, `X-Goog-Upload-Size-Received`), defaults to the whole file as one chunk (`kGTMSessionUploadFetcherStandardChunkSize = LLONG_MAX`), rounds chunks to the server's granularity, and sends a cancel command on `stopFetching`. Heavy for one endpoint, but the reference for edge cases |
| [yt-direct-lite-iOS](https://github.com/youtube/yt-direct-lite-iOS) | Archived 2022-07-27, Objective-C, old client library | Historical only |
| [Python sample](https://developers.google.com/youtube/v3/guides/uploading_a_video) | Current | `MediaFileUpload(chunksize=-1, resumable=True)`, `next_chunk()` loop, retry on `500/502/503/504` and socket errors, `MAX_RETRIES = 10`, `sleep(random() * 2**retry)` |
| [Node sample](https://github.com/googleapis/google-api-nodejs-client/blob/main/samples/youtube/upload.js) | Current | `youtube.videos.insert({ part, notifySubscribers: false, requestBody: { snippet, status }, media: { body: fs.createReadStream(file) } }, { onUploadProgress })` |
| Swift packages | None found that are maintained and YouTube-specific; GitHub has generic URLSession chunked-upload demos aimed at the IETF draft or custom servers | Write it |

**URLSession facts that shape the design.**

- Upload tasks cannot send a byte range of a file: "URLSession does not support uploading a specific range of a file... on resuming an upload, you have to copy the file to remove the bytes that you've uploaded so far" (Quinn, DTS, [thread 656779](https://developer.apple.com/forums/thread/656779), enhancement request rdar://30418199). So a chunked or resumed `PUT` is either `uploadTask(with:from: Data)` with the chunk read through `FileHandle` (a 32 MiB `Data` per request is fine on a Mac) or `uploadTask(withStreamedRequest:)` with an `InputStream` bounded to the range plus the `urlSession(_:task:needNewBodyStream:)` delegate method, which URLSession calls for the initial body and again "if the task needs to resend a request... because of an authentication challenge or other recoverable server error" ([needNewBodyStream](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:neednewbodystream:))). A streamed request with no `Content-Length` goes out chunked; Google's upload server wants a definite length, so set `Content-Length` explicitly on streamed requests.
- `uploadTask(with:fromFile:)` (and the async `upload(for:fromFile:)`, macOS 12+) streams the file from disk with `Content-Length` set from its size and no memory cost; it is the right call for the whole-file `PUT` in step 2a and for a resume where the remaining bytes are copied to a temporary file.
- Background sessions accept only file-based uploads ("Only upload tasks from a file are supported (uploads from data instances or a stream fail after the app exits)", [Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)), forbid completion handlers, and Apple documents relaunch-after-termination only for iOS; on macOS the app is not relaunched and a user quit cancels the transfers ([background(withIdentifier:)](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)), [thread 121487](https://developer.apple.com/forums/thread/121487)). Apple's advice is "fewer, larger transfers" and, since macOS 14, native resumable uploads via `cancelByProducingResumeData()` / `uploadTask(withResumeData:)`, but that implements the IETF `draft-ietf-httpbis-resumable-upload` (`Upload-Incomplete`, `104` responses, `HEAD` for offset), which Google's upload server does not speak ([thread 14853](https://developer.apple.com/forums/thread/14853), [WWDC23 10006](https://developer.apple.com/videos/play/wwdc2023/10006/)).
- Community pitfalls: sending the next chunk from your own byte count instead of the `Range` header; treating a `308` as an error; not persisting the session URI so a crash restarts from zero; letting the access token expire mid-upload (a chunk with a stale bearer gets `401`, refresh and resend the same chunk); assuming `201` means playable (it means `uploaded`).

*Implication:* a default (non-background) `URLSession` owned by the upload job, with the session URI, file, total size, and confirmed offset persisted in the job store so a crash or quit resumes with a status query rather than a restart. Background sessions buy nothing on macOS for a foreground editor and cost temp-file copies on every resume.

---

## Recommendation

**Uploader.** A `YouTubeUploadJob` in `Providers` (the render is already an async job; publishing is the next stage of the same queue), running on a dedicated `URLSession` with a delegate for progress:

1. Validate metadata locally against the limits in section 3 and surface violations as errors, never as silent fixes (policy III.C.3).
2. `POST ...?uploadType=resumable&part=snippet,status[&notifySubscribers=false]` with `X-Upload-Content-Length` and `X-Upload-Content-Type: video/mp4`; persist `Location`.
3. Default strategy: one `uploadTask(with:fromFile:)` `PUT` of the whole file; progress from `urlSession(_:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend:)`. Alternative strategy for flaky links (user setting or automatic after two failures): 32 MiB chunks via `uploadTask(with:from:)`, `Content-Range` on each, next offset from the `Range` header.
4. On any failure or on relaunch: `PUT` with `Content-Range: bytes */TOTAL`, `Content-Length: 0`; act on `308`/`Range`, `200`/`201`, or `404` (new session). Exponential backoff with jitter, 10 attempts, honour `Retry-After`; `401` refreshes the token and retries once; `403 quotaExceeded` and `400 uploadLimitExceeded` fail the job with the reset time.
5. Cancellation: `task.cancel()` inside `withTaskCancellationHandler`; delete the persisted session (there is no documented cancel for the classic protocol; the session simply expires).
6. After `201`: poll `videos.list?part=status,processingDetails,fileDetails` every 15 s with backoff until `processed`, `failed`, or `rejected`; then `thumbnails.set`, `captions.insert` per language, `playlistItems.insert`, in that order, each optional and each reported separately so a 400-unit caption failure does not hide a successful upload.
7. State machine persisted per job: `pending -> sessionCreated(uri) -> uploading(offset) -> uploaded(videoId) -> processing -> published | failed(reason) | rejected(reason)`, so the UI and the agent see the same status.

**Metadata surface.** One `YouTubePublishRequest` value used by the UI sheet and the `youtube_publish` tool:

| Field | UI | Agent tool | Default |
|---|---|---|---|
| `title` (required, at most 100 chars, no `<>`) | editable | proposes | from project name |
| `description` (at most 5,000 bytes) | editable | proposes | chapters generated from markers |
| `tags` (at most 500 chars total) | editable | proposes | empty |
| `categoryId` | picker from `videoCategories.list` (cached per region for 30 days) | proposes an id | `22` People & Blogs |
| `privacyStatus` | required radio (public, unlisted, private) | proposes | `private` until the project is audited, then `unlisted` |
| `publishAt` | date picker, only with private | proposes | none |
| `selfDeclaredMadeForKids` | required toggle with the COPPA explanation | never sets | `false` |
| `containsSyntheticMedia` | toggle pre-filled from provenance, with the exempt list in the help text | proposes with a reason | derived |
| `license`, `embeddable`, `publicStatsViewable`, `notifySubscribers` | advanced disclosure | may set | `youtube`, `true`, `true`, `true` |
| `defaultLanguage`, `recordingDate` | advanced | may set | transcript locale; QuickTime creation date |
| `thumbnail` | image well (JPEG/PNG, at most 2 MB, 16:9 or 9:16) | proposes a frame via `look_at` | poster frame |
| `captions[]` | list of transcript languages to publish, format SRT | proposes | the transcript's locale |
| `playlistId` | picker from `playlists.list?mine=true` | may set | none |

The tool is expensive and irreversible in policy terms, so it goes through the existing `approval_required` path: the agent's call returns an approval card showing the exact title, description, privacy, disclosures, and the certification text from ToS 9.1; the human's confirmation is the express consent the policies require, and the tool retries with the token. A `youtube_status(jobId)` tool reads the persisted state machine. The tool never sets `selfDeclaredMadeForKids`; only the human does.

**Google-side checklist for the developer.**

1. Google Cloud project; enable "YouTube Data API v3".
2. OAuth consent screen: external, app name, support email, logo, homepage and privacy policy on a domain you own and have verified; scope `https://www.googleapis.com/auth/youtube.force-ssl` with the justification "upload videos, set thumbnails, insert caption tracks, add to playlists on the user's own channel".
3. OAuth client of type Desktop app; note the client id (the secret is not secret in a native app; PKCE and loopback are the protection).
4. Publishing status Testing during development (add your own accounts as test users; expect 7-day re-consent); move to In production and submit OAuth verification (demo video of the grant plus each scope in use) before external users.
5. Submit the [YouTube API Services Audit and Quota Extension Form](https://support.google.com/youtube/contact/yt_api_form) for the compliance audit, which lifts the private-only restriction on uploads; request more of the 100-call upload bucket only if a real user needs it. Allow several weeks and keep a reviewer account.
6. In the app: the ToS 9.1 certification sentence next to the upload button, the Made for Kids control, the disconnect-and-delete action (7-day deletion obligation), the privacy policy link, and the YouTube icon used only on the share control.
7. A phone-verified test channel for long uploads and thumbnails, plus a second unverified channel to exercise the `length` rejection and thumbnail `403`.
8. Export smoke test: upload a fixture HLG export with `part=fileDetails,processingDetails` and assert YouTube reports 10-bit BT.2020 HLG; confirm the edit-list behaviour once and record it in the preset.
