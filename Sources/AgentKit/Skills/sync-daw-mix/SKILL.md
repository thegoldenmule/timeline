---
name: sync-daw-mix
description: Align a DAW-rendered mix to the camera's scratch audio with align_audio, place it on the timeline, and mute the camera audio.
allowed-tools: mcp__timeline__*
---

# Sync a DAW mix to camera audio

Use this when the user has a separately mixed audio file (band rehearsal, podcast, voice-over) that must line up with the camera recording.

## Procedure

1. `project_describe` (`level: "tracks"`). Identify the camera asset (video with audio) and the mix asset (audio only). If the mix is not imported yet, `media_import` it.
2. `align_audio` with `referenceAssetId` = camera asset, `targetAssetId` = mix asset. Read `status`:
   - `aligned`: use `offset` (a rational time; positive means the mix starts later than the camera recording).
   - `ambiguous`: show the user the candidates (offsets and confidences) and the proof image, ask which one.
   - `failed`: say so; do not guess an offset.
3. Place the mix: one `timeline_apply` batch with `addClip` on an audio track (`addTrack` first if there is none besides the camera's), `at` = the camera clip's `start` + `offset` - the camera clip's `sourceIn` (all rational times; keep the timescale consistent), `sourceIn` 0, `sourceOut` = the mix duration, `mode: "overwrite"`, `link: "none"`.
4. Mute the camera's audio: `setTrackMuted` on the camera audio track, or `setClipAudio` with `muted: true` on the camera audio clip.
5. Report the offset in seconds, the drift in ppm, and the confidence. If drift exceeds 50 ppm, warn that a long recording will slip and suggest `setClipSpeed` on the mix by `1 + driftPPM / 1e6`.
