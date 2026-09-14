---
name: tiktok-captions
description: Add large, centred, word-timed captions to a talking-head sequence from its transcript, in the style of TikTok and Reels, then check the result visually.
allowed-tools: mcp__timeline__*
---

# TikTok-style captions

Use this when the user asks for "TikTok captions", "Reels captions", "burned-in subtitles", or "word-by-word captions".

## Procedure

1. `project_describe` with `level: "tracks"`. Note `version` (you will pass it as `expectedVersion`), the active sequence's `width`/`height` and `orientation`, and which video clips carry an asset with `hasAudio: true`.
2. **Check the format before styling anything.** TikTok and Reels are vertical, and captions are sized from the frame, so a sequence in the wrong shape makes every later step wrong. Judge each clip by its `displaySize` and `orientation`, never by the encoded `size`: a portrait phone clip probes as landscape 3840x2160 with `rotation: -90` and displays 2160x3840. If the answer carries a `formatMismatch` entry, or the footage is portrait while the sequence is landscape, say so and offer to resize before captioning — one `timeline_apply` with `setSequenceSettings`, passing the complete settings with the footage's `displaySize` as `width`/`height` and the sequence's existing `name` and `frameDuration` unchanged. Resizing rewrites no clip and is one undo step. Do not resize without asking, and do not change `frameDuration`: the core refuses that once a video or caption track holds clips.
3. If no asset lists `transcript` under `analyses`, run `media_analyze` with `kinds: ["transcript"]` on each speaking asset. It may answer `status: "approval_required"`; tell the user you are waiting for their approval and retry the same call with the returned `approvalToken` once it is granted.
4. `caption_add` with `source: "transcript"`, `maxWordsPerCaption: 3` (2 for very fast speech), and a style sized for the frame: for 1080x1920 use `{"fontSize": 72, "position": "center", "color": "#ffffff", "backgroundColor": "#00000080", "extra": {}}`; for 1920x1080 use `fontSize` 56 and `position` `"bottom"`. Pass the `expectedVersion` from step 1 (or from the last mutation's result).
5. `render_preview` over the first 10 seconds with `count: 4` and look at the frames: captions must be inside the frame, legible, and not covering faces. Adjust the style with `timeline_apply` (`setCaptionStyle` on the caption track) if needed.
6. Report the caption track id, the item count, and the new version. Do not export unless asked; `render_export` needs the user's approval.

## Notes

- Captions are clips on a caption track; `timeline_query` with `kind: "clips"` and the caption `trackId` lists them.
- To fix one caption's text, use `timeline_apply` with `editCaption`; to redo them all, call `caption_add` again with the same `trackId` (it replaces the items in one undo step).
