# Web UI layer for an AI-driven video editor — research report

Date: 2026-09-08. Target: macOS (latest), Apple Silicon, single user, local ffmpeg + LLM component. Scope: browser UI only (timeline, trim/move/split, waveforms, preview player). Star counts and dates were checked against the GitHub API / npm registry on the date above.

---

## 1. Existing open-source browser editors (fork or study)

| Project | What | License | Stars | Last push | Stack | Verdict |
|---|---|---|---|---|---|---|
| **Diffusion Studio editor** — https://github.com/diffusionstudio/editor | "Open-source video editor built for agents. Edits become code, code becomes video." Public since 2026-08-28 (repo created 2026-07-07). | MPL-2.0 | 2,579 | 2026-09-08 | SolidJS + Vite web UI, Electron desktop shell, Mediabunny for codecs, Koota ECS headless runtime, `dapi` CLI | **Study first.** Closest existing thing to your brief. |
| **OpenReel Video** — https://github.com/Augani/openreel-video | Browser CapCut alternative; multi-track timeline, keyframes, color grading, screen recorder | MIT | 5,040 | 2026-08-29 | React 18, Zustand, WebCodecs, WebGPU, Mediabunny, Three.js, IndexedDB; DOM-based timeline; monorepo `apps/web` (~66k LOC) + `packages/core` (~59k LOC) | Good reference for a React/Zustand/Mediabunny editor; large, opinionated. |
| **OpenCut** — https://github.com/OpenCut-app/OpenCut | 89k-star "open-source CapCut". Being rewritten: Rust core (GPU compositor, wasm bindings), Next.js web, GPUI desktop; classic Next.js app archived 2026-05-17 (https://github.com/opencut-app/opencut-classic). Rewrite roadmap includes an Editor API, MCP server and headless mode. | MIT | 88,997 | 2026-08-10 | Rust + TypeScript, Bun, Moon | Not forkable today: mid-rewrite, external contributions limited. Watch the MCP/headless work. |
| **Omniclip** — https://github.com/omni-media/omniclip | Fully client-side editor: trim/split, transitions, filters, text, up to 4K export, undo/redo, WebRTC collab. 2.0 in development. | MIT | 1,458 | 2026-09-07 | TypeScript, `@benev/slate` (Lit-style components), WebCodecs | Small, readable, MIT. Niche framework limits reuse. |
| **Diffusion Studio core** — https://github.com/diffusionstudio/core | WebCodecs compositing engine (v2.0.0 dropped PixiJS for custom 2D, 49 KB gz) | MPL-2.0 | 1,241 | 2025-11-18 | TS, Mediabunny | Effectively superseded by the editor's `@diffusionstudio/runtime`. |
| **Etro** — https://github.com/etro-js/etro (releases: https://github.com/etro-js/etro/releases) | Canvas layer/effect compositor; v0.14.1 (2026-08-12) | **GPL-3.0** | 1,148 | 2026-09-03 | TS, Canvas/GLSL | Alive, but GPL and MediaRecorder-era design. Skip. |
| **designcombo → OpenVideo react-video-editor** — https://github.com/designcombo/react-video-editor (now `openvideodev/react-video-editor`) | CapCut/Canva clone; Next.js 15, PixiJS v8 engine (`@openvideo/engine-pixi`), Zustand, Tailwind | "Other": free for ≤3 employees, else commercial | 1,792 | 2026-06-30 | The reusable parts (`@openvideo/*`, `@designcombo/timeline` 5.5.8 on npm, built on fabric ^6 + immer — https://www.npmjs.com/package/@designcombo/timeline) are npm-only, not open source | Usable as a look-and-feel reference; not a fork base. |
| **Twick** — https://github.com/ncounterspecialist/twick | React SDK: `@twick/timeline`, `@twick/canvas` (Fabric.js), `@twick/live-player`, browser export via WebCodecs + ffmpeg.wasm, server export via Puppeteer | Sustainable Use License v1.0 (free to build products, no SDK resale) | 534 | 2026-06-04 | React, Fabric.js, WebGL effects | Small community; SUL is not OSI. |
| **Clipchamp** (Microsoft, closed) | Architecture talk: ffmpeg.wasm for demux/mux + WebCodecs for decode/encode — https://www.w3.org/2021/03/media-production-workshop/talks/slides/soeren-balko-clipchamp-webcodecs.pdf | — | — | — | — | Validates the WebCodecs-in-browser preview approach. |
| **Commercial SDKs**: IMG.LY CE.SDK (MAU-priced, WebCodecs client-side — https://img.ly/pricing/), Rendley (~$5k/yr per founder on HN, free watermarked on localhost — https://news.ycombinator.com/item?id=41114628, https://rendley.com/pricing), Pintura video extension (trim/crop only, no multitrack timeline — https://pqina.nl/pintura/video-editor/), Remotion Timeline component ($300 copy-paste source — https://www.remotion.pro/store/timeline) | | | | | | Only Remotion's is cheap; none give you an agent-editable document. |
| Kdenlive/Shotcut web ports | None exist; both are Qt/MLT desktop apps (https://en.wikipedia.org/wiki/Media_Lovin%27_Toolkit). | | | | | n/a |

**Why Diffusion Studio editor matters for you:** it treats a TSX module as the document, mounts it into an ECS, and exposes `dapi media probe|grab|filmstrip|waveform|transcribe`, `dapi capture` (contact sheets), `dapi check` (validate composition) for coding agents (Claude Code, Codex, Cursor) — JSON/JSONL output conventions — and ships a macOS Apple Silicon Electron app (https://diffusion.studio/). The editor and agent tooling are MPL-2.0; paid plans only cover AI credits. Caveats: two months public, SolidJS (small hiring pool), and "code as document" is a design choice you may not want (JSON is easier for constrained LLM tool-calls and for diff/undo).

---

## 2. Timeline component libraries

- **@xzdarcy/react-timeline-editor** — https://github.com/xzdarcy/react-timeline-editor. MIT, 789 stars, v1.0.0 published 2026-01-25 (React ≥18), 42 open issues, last push 2026-01-25. Rows/actions model for *animation* editors; no waveforms, filmstrips, ripple or snapping semantics of an NLE. Sporadically maintained; fine to steal ideas from, not to depend on.
- **vis-timeline** — https://github.com/visjs/vis-timeline. Apache-2.0 OR MIT, 2,551 stars, v8.5.4, pushed 2026-09-07, 303 open issues. A calendar/Gantt timeline (items on groups, zoom by date). Wrong abstraction (Date-based axis, no frame quantisation).
- **@designcombo/timeline** — fabric.js-based, proprietary npm (see §1).
- **Konva / react-konva** — https://github.com/konvajs/konva (Konva 10.3.3, 2026-09-04; react-konva 19.2.4, 2026-05-08; MIT). Retained-mode 2D canvas with hit-testing and drag. Good for a fully-canvas timeline; peaks.js is built on it.
- **PixiJS v8** — https://pixijs.com/blog/pixi-v8-launches. WebGPU with WebGL fallback, v8.16 adds an experimental Canvas renderer; `@pixi/react` v8 for React 19 (https://pixijs.com/blog/pixi-react-v8-live). Better suited for the *preview compositor* than the timeline (OpenVideo uses it as its engine).
- **dnd-kit** — https://github.com/clauderic/dnd-kit. MIT, 17.6k stars, pushed 2026-09-06; the new framework-agnostic `@dnd-kit/react` is 0.5.0 (~June 2026, https://www.npmjs.com/package/@dnd-kit/react) with React 19 support. Good for dragging clips *between tracks / from the media bin*; trimming and scrubbing are better done with raw pointer events.

**Honest conclusion:** there is no maintained, permissively-licensed, drop-in NLE timeline for React. Every serious open editor (OpenReel, OpenCut, Omniclip, Diffusion Studio) wrote its own. The timeline is ~1–2k lines: a virtualised DOM layer (clips as absolutely-positioned divs with CSS transforms, one `<canvas>` per clip for filmstrip/waveform) is the pragmatic choice; go full-canvas (Konva) only if you expect thousands of clips.

---

## 3. Audio waveform rendering

- **wavesurfer.js v7** — https://github.com/katspaugh/wavesurfer.js. BSD-3-Clause (LICENSE file), v7.12.11 released 2026-07-17 (GitHub API), 8.0 in beta. TypeScript, Shadow DOM. Crucially accepts `peaks` ("Pre-computed audio data, arrays of floats for each channel") and `duration` so no decode in the browser, plus `media`, `minPxPerSec`, `splitChannels`, `renderFunction`, `barWidth` (https://raw.githubusercontent.com/katspaugh/wavesurfer.js/main/src/wavesurfer.ts). Designed as a *player*; for a timeline you'll mostly reuse its renderer or draw peaks yourself.
- **peaks.js (BBC)** — https://github.com/bbc/peaks.js, development moved to https://codeberg.org/chrisn/peaks.js. **LGPL-3.0**, v4.0.0 (2025-08-30). Zoomable/scrollable view, segments and points, Konva + waveform-data. Excellent for a standalone audio view; heavy to embed per-clip.
- **waveform-data.js** — https://github.com/bbc/waveform-data.js, v4.5.2 (~2025). Parses audiowaveform `.dat`/`.json`, resamples for zoom levels; usable alone with your own canvas drawing.
- **audiowaveform (BBC)** — https://github.com/bbc/audiowaveform (moved to Codeberg). **GPL-3.0** CLI (fine — it's invoked as a process), 2.2k stars, v1.10.2, `brew install audiowaveform`, emits `.dat` (binary 8/16-bit) / `.json` / PNG from WAV/MP3/FLAC/Ogg/Opus. Feed it `ffmpeg -i clip.mov -vn -ac 1 -f wav -` for video sources.
- **ffmpeg alternatives**: `showwavespic` makes an image, not data (https://publit.io/community/blog/visualizing-sound-creating-audio-waveforms-with-audiowaveform-and-ffmpeg); `ffmpeg-peaks` npm computes peaks from ffmpeg PCM output (https://github.com/dottgonzo/ffmpeg-peaks); `astats` via ffprobe gives per-frame peak levels but is slow to parse. audiowaveform is more precise than showwavespic for interaction.

**Recommendation:** local service generates peaks once per asset (audiowaveform JSON at 2–3 zoom levels, or ffmpeg → PCM → min/max bins in Node/Bun), UI draws them on per-clip canvases (wavesurfer's renderer or ~50 lines of your own). Never decode audio in the browser for waveforms; in-browser `decodeAudioData` on a 30-minute HEVC iPhone clip is slow and memory-hungry.

---

## 4. Preview playback

**(a) Multiple `<video>` elements synced.** Simple, hardware-decoded, works for one video track + audio. But `currentTime` seeks are not frame-accurate by spec, elements drift and need threshold resync (~0.3 s in practice — https://www.bocoup.com/blog/html5-video-synchronizing-playback-of-two-videos, https://blog.swesonga.org/2025/01/25/synchronizing-2-html5-videos/), and compositing overlapping tracks means stacking/clipping DOM videos. Acceptable for an MVP with cuts-only editing; breaks with transitions and picture-in-picture.

**(b) WebCodecs + canvas compositing.** The approach used by Omniclip, OpenReel, Diffusion Studio, IMG.LY, Clipchamp. Support: Chrome 94+, Firefox 130+, Safari 16.4 partial (video only), Safari 26 full with AudioEncoder/AudioDecoder (https://caniuse.com/webcodecs, https://webkit.org/blog/17333/webkit-features-in-safari-26-0/). **Mediabunny** — https://github.com/Vanilagy/mediabunny, MPL-2.0, 7,109 stars, v1.56.0 released 2026-09-08 (weekly cadence) — demuxes MP4/MOV/WebM/MKV/MPEG-TS and wraps WebCodecs; `CanvasSink.getCanvas(t)` returns "the last sample with a timestamp ≤ t", with a `poolSize` ring buffer to bound VRAM and `samplesAtTimestamps` to avoid double-decoding (https://mediabunny.dev/guide/media-sinks). That gives frame-accurate seeking by construction (decode from previous keyframe, present exact frame). You then draw each visible clip into a WebGL/PixiJS/2D canvas with transforms and opacity, and mix audio with Web Audio. Cost: you own the playback clock, A/V sync, and decoder backpressure; decoding several 4K HEVC streams simultaneously will exceed real time, which is why proxies (c) still matter.

**(c) ffmpeg proxy render.** Have the local component transcode every imported asset to a low-res H.264 proxy (e.g. 960×540, `-g 1` all-intra or `-g 5`, CRF ~23) as fragmented MP4. Short GOPs make random seeks cheap ("a keyframe every five frames" is fine in Chrome/Safari — https://www.dmcinfo.com/blog/23297/frame-accurate-video-scrubbing-in-the-client/); the extreme version pre-extracts every frame as JPEG plus frame-aligned WAV (https://jordicenzano.github.io/frame-accurate-scrubbing/). Proxies also normalise codecs (HEVC/ProRes/10-bit → 8-bit H.264) so the browser never sees exotic sources. Full-quality export happens in ffmpeg from the originals anyway. Because everything is local, serve proxies from `localhost` with HTTP range requests — no HLS needed.

**(d) Remotion Player.** https://www.remotion.dev/docs/player — React components rendered per frame; free for individuals/teams ≤3, and free-license users may embed the Player (https://www.remotion.dev/docs/license/faq; https://github.com/remotion-dev/remotion/blob/main/LICENSE.md). It plays `<OffthreadVideo>`/`<Video>` via HTML video under the hood, so it inherits (a)'s sync limits in preview; its strength is programmatic motion graphics, not scrub-accurate multi-track NLE preview. The ready-made Timeline is $300.

**Frame accuracy & rVFC.** `requestVideoFrameCallback` is Baseline 2024 (Chrome, Safari 15.4+, Firefox) — https://developer.mozilla.org/en-US/docs/Web/API/HTMLVideoElement/requestVideoFrameCallback; it reports `mediaTime`/`presentedFrames` but can be one vsync late relative to compositing (https://web.dev/articles/requestvideoframecallback-rvfc). Use it to read the *actual* presented frame for a `<video>`-based player; for true frame stepping use WebCodecs (b).

**HEVC on macOS.** Chrome ≥107 decodes HEVC on macOS via VideoToolbox (hardware only, no DRM), 8-bit WebCodecs HEVC ≥107, 10-bit ≥108, HEVC WebCodecs *encode* on macOS ≥130, up to 8192×4352 on Apple Silicon with ≥131 (https://github.com/StaZhu/enable-chromium-hevc-hardware-decoding; https://bitmovin.com/blog/google-adds-hevc-support-chrome/). Safari has had HEVC since 11 and exposes it via WebCodecs since 16.4 (https://developer.apple.com/forums/thread/729464). So iPhone HEVC and macOS screen recordings play in both browsers on an M-series Mac; ProRes and 4:2:2 10-bit are where Chrome falls over — proxies make that moot.

---

## 5. Thumbnails / filmstrips

- **ffmpeg sprite sheets (recommended):** `ffmpeg -i in.mov -vf "fps=1,scale=160:-1,tile=10x10" -frames:v 1 sheet.jpg` — one request per clip, index by `#xywh` like WebVTT storyboards (https://www.mux.com/articles/extract-thumbnails-from-a-video-with-ffmpeg; https://dev.to/masonwritescode/build-scrub-bar-thumbnail-previews-with-ffmpeg-and-a-webvtt-sprite-3ei2). Generate at import at 1 fps and 0.1 fps; pick by zoom level. Diffusion Studio exposes the same idea to agents as `dapi media filmstrip`.
- **In-browser:** Mediabunny `CanvasSink` with `poolSize` can iterate frames at arbitrary timestamps for on-demand filmstrips; fine for short clips, but it competes with the preview decoder for the same hardware decoder. Use only as fallback while the sprite job runs.

---

## 6. Framework, state, shell

**UI framework.** SolidJS and Svelte 5 benchmark ~50–60% faster than React on heavy DOM churn and ship 5–7 KB runtimes vs React's ~45 KB (https://www.pkgpulse.com/guides/solidjs-vs-svelte-5-vs-react-reactivity-2026). Diffusion Studio chose SolidJS. But a timeline's hot paths (scrubbing, dragging, waveform draw) should bypass the framework entirely (rAF + direct style/canvas writes), after which the framework only re-renders on document commits. Given that, ecosystem wins: **React 19 + TypeScript + Vite**, because Zustand/zundo, dnd-kit, react-konva, `@pixi/react`, Remotion and every reference editor (OpenReel, OpenCut, OpenVideo, Twick) are React, and LLM coding agents produce the most reliable React. Choose Solid only if you intend to fork Diffusion Studio.

**Document state and undo.** Three options:
1. **Zustand + immer `produceWithPatches` + zundo** — zundo 2.3.0 MIT (https://github.com/charkour/zundo), pattern discussed in https://github.com/pmndrs/zustand/issues/464. Store inverse patches per command → undo/redo, plus the *forward* JSON patches are exactly what an agent should emit/receive. Simple, in-process, no CRDT overhead.
2. **Yjs** — 13.6.32 MIT; `Y.UndoManager` with `trackedOrigins` lets the human undo only their own changes while the agent's transactions (tagged with a different origin) stay put (https://docs.yjs.dev/api/undo-manager). Yjs is 10–50× faster than Automerge on large docs (https://www.pkgpulse.com/guides/yjs-vs-automerge-vs-loro-crdt-libraries-2026). Worth it if the agent runs in a separate process editing concurrently while the human drags clips — which is your stated design.
3. **Automerge 3.4.1** (10× memory cut in v3, git-like history — https://github.com/automerge/automerge) or **Loro 1.15.1** (fastest, Rust) — better JSON-shaped ergonomics than Yjs, smaller ecosystems.

Recommendation: start with (1) behind a `applyCommand(cmd)` façade; the command log *is* the agent protocol. If concurrent agent+human editing becomes real, swap the store for Yjs `Y.Map`/`Y.Array` with origin-scoped undo — the command façade doesn't change.

**Shell.** Tauri 2.11.5 (2026-07-01; https://github.com/tauri-apps/tauri) uses WKWebView on macOS (https://v2.tauri.app/reference/webview-versions/) and supports ffmpeg sidecars via `externalBin` with `-aarch64-apple-darwin` suffixes (https://v2.tauri.app/develop/sidecar/), but WKWebView = Safari engine: WebCodecs full only since Safari 26, no rVFC-quality parity with Chrome, and per the WebCodecs survey Safari still lacks `VideoEncoder` (https://webcodecsfundamentals.org/datasets/codec-support-table/). Electron 43.1.0 (2026-07-08, Chromium 155 — https://releases.electronjs.org/) gives you Chrome's WebCodecs/HEVC behaviour deterministically and is what Diffusion Studio ships. **For a single-user local tool, start with "localhost server + Chrome tab":** Bun/Node process spawns ffmpeg/audiowaveform, serves proxies/sprites/peaks over HTTP range requests and the document over WebSocket; the LLM agent talks to the same server. Zero packaging cost, hot reload, DevTools. Wrap in Electron later if you want a dock icon or file associations; avoid Tauri unless you're willing to live with WebKit's WebCodecs.

---

## Recommended UI stack

- React 19 + TypeScript + Vite; Tailwind for chrome.
- Timeline: custom. Virtualised DOM tracks; clips as `transform: translateX()` divs; per-clip `<canvas>` for filmstrip (sprite sheet) and waveform (precomputed peaks); rAF-driven playhead; pointer events for trim/move/split with snapping; dnd-kit only for bin→track drops. Time stored as rational frames (`{n, d}` frame rate) not floats.
- Preview: Mediabunny `CanvasSink` decoding ffmpeg-generated all-intra 540p H.264 proxies, composited onto a WebGL canvas (PixiJS v8 or raw WebGL2) with a Web Audio mixer; rVFC-free because you own the clock. Full-res export via ffmpeg `filter_complex` generated from the document.
- Peaks: audiowaveform JSON (or ffmpeg→PCM binning) from the local service. Thumbnails: ffmpeg `fps,scale,tile` sprite sheets at two densities.
- State: Zustand + immer patches + zundo; command façade; migrate to Yjs with origin-scoped UndoManager if agent/human concurrency demands it.
- Shell: localhost service + Chrome; Electron later.
- Study: Diffusion Studio editor (agent CLI + `check` validator + filmstrip/waveform commands), OpenReel Video (React/Zustand/Mediabunny engine layout), Omniclip (small WebCodecs pipeline).

## Timeline document model (sketch)

Modelled after OpenTimelineIO's Timeline → Stack → Track → Clip tree with rational times and a `metadata` blind-data dict (https://opentimelineio.readthedocs.io/en/latest/tutorials/otio-timeline-structure.html), but flattened with IDs so patches are small and an LLM can target nodes by `id`.

```ts
type Rational = { n: number; d: number };            // frames or seconds as exact fractions
type Time = number;                                  // integer frame index at project fps

interface Project {
  id: string; version: 1;
  settings: { fps: Rational; width: number; height: number; sampleRate: 48000 };
  assets: Record<string, Asset>;                     // media bin
  tracks: Track[];                                   // z-order: index 0 bottom
  markers: Marker[];
  captions: CaptionTrack[];
}
interface Asset {
  id: string; kind: 'video'|'audio'|'image';
  path: string;                                      // original on disk
  proxy?: string; sprite?: { url: string; cols: number; rows: number; fps: number };
  peaks?: string;                                    // audiowaveform json
  duration: Time; fps?: Rational; hasAudio: boolean; codec: string;
  analysis?: { transcript?: string; scenes?: Time[]; silence?: [Time,Time][] }; // agent-produced
}
interface Track { id: string; kind: 'video'|'audio'; name: string; muted: boolean; locked: boolean; clips: Clip[] }
interface Clip {
  id: string; assetId: string;
  start: Time;                                       // position on timeline
  in: Time; out: Time;                               // source range (out exclusive)
  speed?: number;
  transform?: { x: number; y: number; scale: number; rotation: number; opacity: number; anchor?: [number,number] };
  effects: Effect[];                                 // ordered
  transitionIn?: Transition; transitionOut?: Transition;
  audio?: { gain: number; fadeIn: Time; fadeOut: Time };
  label?: string; meta?: Record<string, unknown>;
}
interface Effect { id: string; type: string; params: Record<string, number|string|boolean>; keyframes?: Keyframe[] }
interface Keyframe { t: Time; value: number; easing?: 'linear'|'ease'|'spring' }
interface Transition { type: 'crossfade'|'dip'|'wipe'|string; duration: Time; params?: Record<string, unknown> }
interface CaptionTrack { id: string; lang: string; items: { id: string; start: Time; end: Time; text: string; style?: string }[] }
interface Marker { id: string; t: Time; label: string; color?: string }
```

Operations are a small closed set of **commands** used by both the UI and the agent — `addClip`, `moveClip`, `trimClip{in|out}`, `splitClip(id, t)`, `deleteClip`, `setTransform`, `addEffect`, `setTransition`, `reorderTrack`, `setCaptions` — each producing JSON Patch forward/inverse pairs. Invariants (no overlaps within a track, `in < out ≤ asset.duration`, times on frame boundaries) are validated in one place (mirror Diffusion Studio's `dapi check`). The agent receives the document as JSON plus asset `analysis`, returns commands; the UI applies them through the same reducer, so undo, rendering (ffmpeg filter graph from `Project`) and preview all read one source of truth.
