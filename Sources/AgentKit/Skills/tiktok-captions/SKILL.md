---
name: tiktok-captions
description: Add large, centred, word-timed captions to a talking-head sequence from its transcript, in the style of TikTok and Reels, then check the result visually.
allowed-tools: mcp__timeline__*
---

# TikTok-style captions

Use this when the user asks for "TikTok captions", "Reels captions", "burned-in subtitles", or "word-by-word captions".

## Procedure

1. `project_describe` with `level: "tracks"`. Note `version` (you will pass it as `expectedVersion`), the active sequence's `width`/`height`, and which video clips carry an asset with `hasAudio: true`.
2. If no asset lists `transcript` under `analyses`, run `media_analyze` with `kinds: ["transcript"]` on each speaking asset. It may answer `status: "approval_required"`; tell the user you are waiting for their approval and retry the same call with the returned `approvalToken` once it is granted.
3. `caption_add` with `source: "transcript"`, `maxWordsPerCaption: 3` (2 for very fast speech), and a style sized for the frame: for 1080x1920 use `{"fontSize": 72, "position": "center", "color": "#ffffff", "backgroundColor": "#00000080", "extra": {}}`; for 1920x1080 use `fontSize` 56 and `position` `"bottom"`. Pass the `expectedVersion` from step 1 (or from the last mutation's result).
4. `render_preview` over the first 10 seconds with `count: 4` and look at the frames: captions must be inside the frame, legible, and not covering faces. Adjust the style with `timeline_apply` (`setCaptionStyle` on the caption track) if needed.
5. Report the caption track id, the item count, and the new version. Do not export unless asked; `render_export` needs the user's approval.

## Notes

- Captions are clips on a caption track; `timeline_query` with `kind: "clips"` and the caption `trackId` lists them.
- To fix one caption's text, use `timeline_apply` with `editCaption`; to redo them all, call `caption_add` again with the same `trackId` (it replaces the items in one undo step).
