---
name: jump-cut-talking-head
description: Tighten a talking-head recording by cutting silences and pauses into jump cuts, keeping linked audio in sync, then verify the cut.
allowed-tools: mcp__timeline__*
---

# Jump-cut a talking head

Use this when the user asks to "tighten", "remove pauses", "cut the dead air", or "jump cut" a recording.

## Procedure

1. `project_describe` with `level: "tracks"`. Find the main video clip(s) on the first video track, their `assetId`, `start`, `sourceIn`, `sourceOut`, and the current `version`.
2. `media_analyze` on that asset with `kinds: ["silence"]`. The result lists media-time silence ranges (`start`/`end` as rational times). Keep only ranges longer than 0.4 s and inside the clip's `sourceIn`..`sourceOut`.
3. For each silence range, from the LAST to the FIRST (so earlier timeline positions stay valid), issue one `timeline_apply` batch with `mode: "ripple"`:
   - `splitClip` at the timeline time of the silence start: `clip.start + (silence.start - clip.sourceIn)`.
   - `splitClip` on the new right-hand clip (`{"$ref": 0}`) at the timeline time of the silence end.
   - `removeClip` on the middle clip (`{"$ref": 1}`) with `mode: "ripple"`.
   Leave a 2-frame (`{"v": 2002, "ts": 24000}` at 23.976 fps) pad on each side of the speech so words are not clipped. Linked audio follows automatically; never pass `unlinked: true`.
4. Every mutation returns a new `version`; pass it as the next `expectedVersion`. On `staleVersion`, re-read with `project_describe` and recompute from the current clips.
5. `render_preview` at three of the cut points and look at them; optionally `transition_add` a 4-frame `dissolve` where a jump is jarring (needs source handles on both sides, which trimmed clips have).
6. Report how many cuts were made and how much time was removed (old duration minus new `duration` from `project_describe`).

## Notes

- `timeline_query` with `kind: "history"` shows the undo stack; `undo` reverts one batch if the user dislikes a cut.
- Do not export unless asked; `render_export` needs the user's approval.
