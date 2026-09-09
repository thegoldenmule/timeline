---
name: publish-to-youtube
description: Export the active sequence and upload it to the user's YouTube channel as a private video through the approval card, with the sequence's captions and a chosen thumbnail frame, then report the URL.
allowed-tools: mcp__timeline__*
---

# Publish to YouTube

Use this when the user says "upload", "publish", "post to YouTube", or "put it on my channel".

## Procedure

1. `account_status`. If `accounts` is empty, stop and tell the user to connect a Google account in Settings. If an account's `tokenStatus` is `reauthorizationRequired`, ask them to reconnect it in Settings and stop. Note the `note` when present: uploads are private until the project passes YouTube's audit.
2. `project_describe` with `level: "tracks"`. Note the active sequence, its caption tracks (tracks with `kind: "caption"`), and a title suggestion: the project name, or the first caption's text when the project name is generic. Confirm the title with the user if you are unsure.
3. `render_export` with `preset: "h264_1080p"` (or `reel9x16` for a vertical sequence). It answers `status: "approval_required"`; tell the user you are waiting for their approval and retry the identical call with the returned `approvalToken` once granted. Keep the `renderId` from the done answer.
4. `publish_youtube` with the `renderId`, the title, `privacy: "private"` unless the user asked for `unlisted` or `public` in so many words, `captionTrackIds` listing every caption track when one exists, `thumbnailAt` at a frame the user liked (use `render_preview` over the sequence to pick a clear one; skip the thumbnail rather than guess), `containsSyntheticMedia: true` only when the content is generated or altered realistic media, and a fresh `publishId` (any unique string, minted once per publish).
5. It answers `status: "approval_required"` with the card's summary, details, and warnings. Tell the user you are waiting for their approval, then retry the same call with the returned `approvalToken` and the same `publishId`. Do not change the title, privacy, or captions between the two calls.
6. If the answer is `uploading` or `processing`, poll `publish_status` with the `publishId` every 30 seconds until its row is `done` or `failed`. Never start again with a new `publishId` after a timeout: the same id resumes the upload.
7. Report the `url`, the `privacy` YouTube reported (it may be private even when unlisted was requested), the `projectVersion` that was published, and remind the user to set the audience (made for kids) in YouTube Studio right after the upload.

## Rules

- Never set `privacy: "public"` on your own; the user must ask for it explicitly.
- Never retry with a new `publishId` after a timeout or a failure: reuse the one from the `approval_required` answer, which resumes a failed or cancelled upload where it stopped.
- The made-for-kids audience is never set by this tool; always tell the user to set it in YouTube Studio.
- `publish_youtube` needs a render from `render_export`; a `renderNotFound` or `renderNotDone` error means step 3 has not finished.
- A `quotaExceeded` error means the day's upload allowance is spent; report the `resetsAt` time and stop.
