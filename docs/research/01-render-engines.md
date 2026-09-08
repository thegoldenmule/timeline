# Rendering / Compositing / Editing Engine Options for an AI-Driven Video Editor

Research date: 2026-09-08. Target: macOS (latest), Apple Silicon; web UI + local Mac helper invoking ffmpeg and LLMs. Stars/dates were pulled live from the GitHub API, npm registry, PyPI, and Homebrew on the research date.

---

## 0. Baseline facts about the local toolchain (verified on this Mac)

- Homebrew core `ffmpeg` is at 9.0.1 stable (this machine has 8.1.1). FFmpeg 8.0 "Huffman" shipped 2025-08-22 with a native `whisper` filter (whisper.cpp) and Vulkan work; 8.1 shipped 2026-03-16; 9.0 "Lei" shipped 2026-08-04. Sources: https://ffmpeg.org/download.html, https://www.phoronix.com/news/FFmpeg-8.0-Released, https://www.phoronix.com/news/FFmpeg-9.0-Released
- **Critical gotcha:** the Homebrew core `ffmpeg` formula is a "slim" build. Its configure line is only `--enable-libsvtav1 --enable-libopus --enable-libx264 --enable-libmp3lame --enable-libdav1d --enable-libvmaf --enable-libvpx --enable-libx265 --enable-openssl --enable-videotoolbox --enable-audiotoolbox`. `drawtext`, `subtitles`, `ass`, `libplacebo`, `whisper` and `dnn_processing` are all ABSENT. `ffmpeg-full` (9.0.1, keg-only) adds `fontconfig freetype frei0r harfbuzz libass libplacebo whisper-cpp`. MLT's own docs confirm "FFmpeg 8's stock Homebrew build lacks the drawtext filter" (https://www.mltframework.org/docs/headlessmacos/). Plan on shipping your own ffmpeg binary or requiring `ffmpeg-full`.
- `xfade` in ffmpeg 8.1.1 exposes 59 transitions: `custom fade wipeleft wiperight wipeup wipedown slideleft slideright slideup slidedown circlecrop rectcrop distance fadeblack fadewhite radial smoothleft smoothright smoothup smoothdown circleopen circleclose vertopen vertclose horzopen horzclose dissolve pixelize diagtl diagtr diagbl diagbr hlslice hrslice vuslice vdslice hblur fadegrays wipetl wipetr wipebl wipebr squeezeh squeezev zoomin fadefast fadeslow hlwind hrwind vuwind vdwind coverleft coverright coverup coverdown revealleft revealright revealup revealdown`, plus `expr` for custom transitions (`ffmpeg -h filter=xfade`; https://ffmpeg.org/ffmpeg-filters.html#xfade).
- VideoToolbox encode (`h264_videotoolbox`, `hevc_videotoolbox`) is 3-24x faster than x264/x265 on M-series and uses ~20% CPU; it lacks `-preset`/`-tune`. https://yre.jp/en/post/m1mac_h265/, https://codetv.dev/blog/hardware-acceleration-ffmpeg-apple-silicon

---

## 1. ffmpeg-based approaches

### Raw ffmpeg `filter_complex`
- **What:** hand- or machine-generated filter graphs (`trim`/`setpts`, `overlay`, `xfade`, `concat`, `amix`, `adelay`, `zoompan`, `colorkey`, `loudnorm`, `sidechaincompress` all present in the slim build).
- **Status/License:** the de facto standard; LGPL/GPL depending on build (`--enable-gpl` for x264/x265).
- **macOS:** excellent; VideoToolbox hw encode/decode, `--enable-neon`.
- **LLM fit:** LLMs are already decent at ffmpeg CLI, and an ecosystem of "ffmpeg skills" for coding agents has appeared (e.g. https://github.com/rendi-api/ffmpeg-cheatsheet, https://github.com/KyaniteLabs/mcp-video). But letting the LLM emit filter_complex directly is brittle: labels, stream counts, timebase mismatches, and xfade's requirement that both inputs share resolution/fps/pixel format. Better: LLM emits a declarative timeline and *your compiler* emits filter_complex.
- **Drawbacks:** no real-time preview; graphs for 20+ clips with overlapping tracks get huge (use chained `xfade` with cumulative offsets or `overlay` with `enable='between(t,..)'`); xfade forces all clips to a canonical format first (`scale`,`fps`,`format`,`settb`).

### Node wrappers
- **fluent-ffmpeg** — 8.2k stars, MIT, **archived 2025-05-22, npm package deprecated** ("Package no longer supported"). Do not adopt. https://github.com/fluent-ffmpeg/node-fluent-ffmpeg, https://github.com/fluent-ffmpeg/node-fluent-ffmpeg/issues/1324
- **ffmpeg-static** — 1.4k stars, GPL-3.0, pushed 2026-03; downloads a static binary at install. Useful for bundling but check which libs the static build includes (drawtext/libass). https://github.com/eugeneware/ffmpeg-static
- **@ffmpeg/ffmpeg (ffmpeg.wasm)** — 17.8k stars, MIT, last release v0.12.15 2025-01-07. Browser-only WASM; "won't perform as good as FFmpeg", even multithreaded, memory-bound (2-4 GB). Not suitable as a primary engine when you have a native Mac helper. https://github.com/ffmpegwasm/ffmpeg.wasm, https://ffmpegwasm.netlify.app/docs/performance/
- **mediaforge** — new (1.0.0, 2026-08-09, MIT) typed TS wrapper around the system binary, positioned as the fluent-ffmpeg successor. Too young to depend on. https://dev.to/globaltechinfo/mediaforge-a-modern-typescript-ffmpeg-wrapper-fluent-ffmpeg-is-dead-long-live-mediaforge-5ajm
- **typed-ffmpeg** — 1.2k stars, MIT, pushed 2026-09-03, v4.5 (2026-08-22). Type-safe filter-graph builder for **Python and TypeScript**, auto-generated per ffmpeg version (5.x-8.x), with JSON serialization of graphs and validation. This is the best current "build a filter_complex programmatically" library. https://github.com/lucemia/typed-ffmpeg

### Python wrappers
- **ffmpeg-python** — 11k stars, Apache-2.0, last commit **2022-07**, pushed 2024-08. Dormant. https://github.com/kkroening/ffmpeg-python
- **MoviePy 2.x** — 14.9k stars, MIT; v2.0 released 2025-01-26 (breaking API), latest v2.2.1 2025-05-21, repo pushed 2026-08. Pure-Python frame pipeline (numpy through ffmpeg pipes) — simple but slow for 4K/60 iPhone footage; fine for prototyping, not a production engine. https://github.com/Zulko/moviepy, https://zulko.github.io/moviepy/getting_started/updating_to_v2.html

### editly (mifi)
- **What:** declarative JSON5 edit spec (clips -> layers: video/image/title/audio/canvas/GL shader) rendered via ffmpeg + node-canvas/Fabric.js + headless-gl. 5.5k stars, MIT. https://github.com/mifi/editly
- **Status:** a new maintainer (bkeepers) was announced 2025-01-17 (https://github.com/mifi/editly/discussions/308); last release is v0.15.0-rc.1 (2025-01-19); last commit 2025-02-20; npm still at 0.14.2 (2022). Effectively stalled again.
- **Drawbacks:** sequential-clip model (no true overlapping multi-track), headless-gl/node-canvas native deps are painful on Apple Silicon. Good as *format inspiration*, not as a dependency.

### Rust / Go
- **rust-ffmpeg / ffmpeg-next** (2k stars, pushed 2026-08) and **video-rs** (419 stars, Apache-2.0, pushed 2026-06) give libav bindings for a Rust helper; **ffmpeg-go** (2.3k, pushed 2024-05) is a Go port of ffmpeg-python. None is a compositing engine; they only help if you want a native daemon instead of spawning the CLI. https://github.com/zmwangx/rust-ffmpeg, https://github.com/oddity-ai/video-rs, https://github.com/u2takey/ffmpeg-go
- **NodeAV** (libavcodec N-API bindings) is what `@mediabunny/server` wraps for zero-copy decode/encode with automatic hw-accel detection on macOS. https://github.com/Vanilagy/mediabunny/blob/main/packages/server/README.md

---

## 2. Programmatic compositing frameworks

### Remotion
- **What:** React components -> video. 58.6k stars; v4.0.522 (2026-09-07), extremely active. https://github.com/remotion-dev/remotion
- **License:** source-available, *not* OSS. Free for individuals, non-profits, and companies of **up to 3 people**; otherwise "Remotion for Creators" ($25/seat/mo) or "Remotion for Automators" ($0.01/render, $100/mo minimum) — and building "video editors, prompt-to-video tools, automated video pipelines, embedding the Remotion Player" is explicitly the Automators tier. Headcount aggregates across client + contractor if the client owns the code. Client-side rendering phones home with the end-user IP for license metering. https://www.remotion.dev/docs/license/faq, https://www.remotion.dev/docs/license/pricing, https://github.com/remotion-dev/remotion/blob/main/LICENSE.md
- **Rendering:** N headless Chromium instances screenshot each frame as PNG/JPEG -> ffmpeg encodes. Real footage: legacy `<OffthreadVideo>` extracts exact frames with ffmpeg outside the browser; the new `<Video>` in `@remotion/media` decodes via **Mediabunny + WebCodecs** into a canvas, with fallback to OffthreadVideo (no reverse playback, no pitch-preserving speed change). `@remotion/web-renderer` (stable since 4.0.491) renders **in the browser** via WebCodecs/Mediabunny, with a subset of CSS/tags. https://www.remotion.dev/docs/offthreadvideo, https://www.remotion.dev/docs/media/video, https://www.remotion.dev/docs/web-renderer
- **LLM fit:** strong for motion graphics/memes/caption overlays (LLMs write React well), weak as the *cut engine*: screenshot-per-frame is slow for long 4K clips (concurrency tuning is fiddly: https://github.com/remotion-dev/remotion/issues/4949), and Remotion is now sponsoring and migrating onto Mediabunny for media handling anyway (https://www.remotion.dev/blog/mediabunny).
- **Drawbacks:** license cost/complexity once the team exceeds 3 or the product is an "automation"; Chrome-screenshot pipeline is CPU-heavy and color management is a known hazard.

### Motion Canvas
- 19k stars, MIT; last release v3.17.2 (2024-12-14); one substantive commit in 2025 and only a docs-domain change in 2026-07; an "Is the repo dead?" issue opened 2025-12-25. Generator-based animation DSL aimed at explainer videos, not footage editing. Not a fit. https://github.com/motion-canvas/motion-canvas, https://github.com/motion-canvas/motion-canvas/issues/1221

### Diffusion Studio core (@diffusionstudio/core) and Diffusion Studio Editor
- **core:** browser compositing engine on Canvas2D + WebCodecs, built on Mediabunny; declarative timeline compositions, layers, captions, rich text, effects, transitions, keyframes, masking, audio ramps, realtime playback + hw-accelerated render. 1.2k stars, **MPL-2.0**, npm 4.0.3 (2025-11-30), last commit 2025-11-18. Requires COOP/COEP headers (SharedArrayBuffer). Free tier adds a "Made with Diffusion Studio" watermark; a one-time license key removes it. Browser-only (no Node). https://github.com/diffusionstudio/core, https://www.npmjs.com/package/@diffusionstudio/core
- **editor (new, very relevant):** "An open-source video editor built for agents. Edits become code, code becomes video." Open-sourced 2026-08-28 by Diffusion HQ (YC F24); 2.6k stars, MPL-2.0, pushed 2026-09-08, v0.204.x. SolidJS + Electron + a **headless (no-DOM) runtime** and a `dapi` CLI for agents (Claude Code/Codex/Cursor) to inspect media, edit, and render; compositions are JSX/SolidJS modules; encoding via Mediabunny; macOS Apple Silicon is the primary download. This is almost exactly the product category you're describing. https://github.com/diffusionstudio/editor, https://diffusion.studio/
- **LLM fit:** high (code-as-timeline, typed API). **Drawbacks:** tiny team (2 employees per Tracxn 2025-09), the core repo's last commit is 10 months old while effort moved to the editor, watermark licensing on core, and "edits are JSX" makes the LLM output harder to validate than a JSON schema.

### Etro.js
- 1.1k stars, **GPL-3.0**, v0.14.1 (2026-08-12), still maintained. Canvas + WebGL layers/effects, `movie.record()` to a Blob in realtime via MediaRecorder; "offline rendering coming soon", audio effects pending. GPL and realtime-only export make it a poor fit. https://github.com/etro-js/etro

### Omniclip
- 1.5k stars, MIT, pushed 2026-09-07; browser NLE on WebCodecs (transitions, effects, text, up to 4K). "Omni Tools" programmatic engine for AI/scripting is announced but early. Good reference implementation of a WebCodecs timeline UI; not a stable library API yet. https://github.com/omni-media/omniclip

### Mediabunny
- 7.1k stars, **MPL-2.0**, v1.56.0 (2026-09-08), pure TypeScript, zero deps, tree-shakable. Demux/mux MP4/MOV/CMAF/MKV/WebM/Ogg/MP3/WAV/ADTS/FLAC/TS/HLS; codecs AVC/HEVC/VP8/VP9/AV1/ProRes + AAC/Opus/MP3/Vorbis/FLAC/AC-3/PCM; microsecond-accurate seeking; Conversion API (transmux/transcode/resize/trim). `@mediabunny/server` brings the same API to Node/Bun/Deno via NodeAV/libav with hw-accel. Sponsored by Remotion ($1k/mo), Diffusion Studio, Screen Studio, Tella, ElevenLabs, Mux. It is the foundation the whole WebCodecs ecosystem is converging on. https://mediabunny.dev/, https://mediabunny.dev/guide/supported-formats-and-codecs, https://github.com/Vanilagy/mediabunny

### WebCodecs state
- Chrome 94+ full; Firefox 130+; **Safari 16.4 had video only, full audio parity only in Safari 26** (2025). Chrome on macOS hardware-decodes HEVC (iPhone footage) via VideoToolbox since 107, and hardware-encodes HEVC since 130. https://www.w3.org/TR/webcodecs/, https://www.captio.work/blog/client-side-video-rendering-2026, https://github.com/StaZhu/enable-chromium-hevc-hardware-decoding
- Implication: a WebCodecs-based *preview* in the web UI is viable today on Chrome; Safari is only now catching up.

### Creatomate / Shotstack (commercial JSON render APIs)
- Shotstack's Edit JSON: `timeline{ soundtrack, background, fonts, tracks[ clips[ asset{type: video|audio|image|title|html|luma}, start, length, fit, scale, position, offset, transition{in,out}, effect, filter, opacity, transform ] ] }` + `output{format, resolution, fps}`. Creatomate uses a similar element/track JSON with keyframe animations. Both prove that a flat "tracks -> clips -> asset + start/length + transition/effect enums" schema is expressive enough for social-video editing and trivially LLM-writable. https://shotstack.io/docs/api/, https://shotstack.io/learn/hello-world/, https://creatomate.com/blog/get-started-with-creatomate-video-generation-api

---

## 3. Traditional NLE engines

### MLT (Shotcut/Kdenlive)
- 1.8k stars, LGPL-2.1, v7.40.0 (2026-06-25), very active (v7.32 2025-05, v7.34 2025-11, v7.36 2025-12). `brew install mlt` works (7.40.0 bottled) but pulls **23 deps incl. Qt 6, OpenCV, frei0r, rubberband** (~heavy). https://github.com/mltframework/mlt, https://www.mltframework.org/
- `melt -profile atsc_1080p_25 in.mp4 -consumer avformat:out.mp4 vcodec=libx264 acodec=aac` renders headless; `-progress2` for logs; `qtext` producer works headless on macOS (Cocoa), `pango` as a no-Qt fallback; verified with melt 7.38 + FFmpeg 8.1 on Apple Silicon (July 2026). https://www.mltframework.org/docs/headlessmacos/
- **MLT XML** is genuinely LLM-emittable: `producer` (media) -> `playlist` (sequence with `entry in/out`) -> `tractor{multitrack{track...} + filter + transition}`; Kdenlive's .kdenlive is MLT XML plus app metadata, and melt renders it directly. https://www.mltframework.org/docs/mltxml/, https://github.com/KDE/kdenlive/blob/master/dev-docs/fileformat.md
- **Pros:** real multi-track compositing, frei0r effects, rubberband time-stretch, luma/dissolve transitions, mature and battle-tested. **Cons:** frame-based timing (profile-dependent), XML verbosity, heavy Homebrew footprint, no browser preview, effects parameters are string-typed and poorly documented for machine generation.

### GStreamer Editing Services (GES)
- GES is bundled in the Homebrew `gstreamer` 1.28.6 formula (old `gst-editing-services` merged), though GStreamer recommends its own .pkg over Homebrew on macOS. `ges-launch-1.0 +clip a.mp4 inpoint=4 duration=2 start=0 layer=0 +effect agingtv +title ...` builds timelines and saves/loads `.xges` XML; `-o` renders with encoding profiles. OTIO ships an `xges` adapter. Powerful but the macOS GStreamer story (plugins, hw-accel via `vtdec`/`vtenc`) is fussier than ffmpeg's. https://gstreamer.freedesktop.org/documentation/gst-editing-services/, https://formulae.brew.sh/formula/gstreamer, https://gstreamer.freedesktop.org/documentation/tools/ges-launch.html

### libopenshot
- 1.6k stars, LGPL-3.0, **v1.0.0 (2026-08-30)** alongside OpenShot 4.0.0; C++/Python(SWIG)/Ruby API; JSON project format; new blend modes and Arm64 pointer fixes in 2026. No Homebrew formula; must build. OpenShot's reputation for stability lags Shotcut/Kdenlive. https://github.com/OpenShot/libopenshot, https://www.openshot.org/blog/2025/12/15/new_openshot_release_340/

### Olive
- 9.1k stars, GPL-3.0, node-based 0.2 rewrite; last code change 2023-09, last repo push 2024-12. Effectively dormant. https://github.com/olive-editor/olive

---

## 4. Interchange / timeline data formats

### OpenTimelineIO (OTIO)
- ASWF project, 2k stars, Apache-2.0, v0.18.1 (2025-11-08/09), Python 3.12 + VFX 2025 platform; C++ core with Python bindings; JS bindings via emscripten are WIP. Schema: `Timeline -> Stack -> Track -> {Clip, Gap, Transition}`; `Clip` has a `MediaReference` (External/ImageSequence/Generator/Missing) and `source_range`; time is `RationalTime(value, rate)`; `Effect` has only `effect_name` + `enabled` + free-form `metadata` (`LinearTimeWarp`, `FreezeFrame` are the only typed effects); `Marker` for annotations. Adapters: otio_json, cmx_3600 EDL, fcp_xml, fcpx_xml, AAF, ALE, kdenlive, xges, hls_playlist, burnins, svg; a third-party write-only **otio-mlt-adapter** (0.3.0, 2021) emits MLT XML for melt. https://github.com/AcademySoftwareFoundation/OpenTimelineIO, https://opentimelineio.readthedocs.io/en/latest/tutorials/otio-serialized-schema.html, https://opentimelineio.readthedocs.io/en/latest/tutorials/adapters.html, https://pypi.org/project/otio-mlt-adapter
- **Verdict as the LLM's canonical model:** OTIO is JSON and its cut/track semantics are exactly right, but it deliberately does *not* model compositing: no transforms/position/scale/opacity, no typed effect parameters, no caption styling, no audio mixing/ducking curves, no keyframes. You would stuff all of that into `metadata`, at which point you have your own schema wearing an OTIO coat. Use OTIO as an **export/import adapter** (to FCPXML/EDL for pros) rather than the working model.

### EDL (CMX 3600), FCPXML
- CMX 3600 EDL is cuts-only, single track — useful only as a super-simple intermediate ("EDL -> render" is how browser-use/video-use works). FCPXML is Apple's versioned XML (1.13 current); FCP refuses files claiming a newer version; OTIO has both fcp_xml (FCP7) and fcpx_xml adapters plus `otio-fcpx-xml-lite-adapter`. Emit FCPXML only as a "send to Final Cut" export. https://github.com/OpenTimelineIO/otio-fcpx-xml-adapter, https://pypi.org/project/otio-fcpx-xml-lite-adapter/, https://cutconvert.com/guides/what-is-fcpxml

### Simple JSON edit specs (editly / Shotstack / Creatomate)
- Flat, enum-heavy, seconds-based, with asset URIs and named transitions/effects. This style is the most reliable for LLM generation with JSON-schema-constrained decoding, and has commercial precedent. Recent agent-editing projects converge on the same idea: video-use (browser-use, 24.4k stars, MIT, created 2026-04) has the LLM emit an **EDL**, renders with ffmpeg, then self-evaluates the render with a filmstrip+waveform composite (https://github.com/browser-use/video-use); Diffusion Studio Editor uses JSX compositions; Kinocut wraps ffmpeg with guardrails behind MCP (https://github.com/KyaniteLabs/mcp-video).

---

## 5. Subtitle / caption rendering

- **libass** (1.2k stars, ISC, 0.17.5 2026-06-24) is the ASS/SSA renderer behind ffmpeg's `subtitles`/`ass` filters. ASS override tags (`\k`/`\kf`/`\ko` karaoke, `\t` animate, `\move`, `\fad`, `\pos`, `\fscx/y`, `\bord`, `\shad`, `\c` colors) cover the whole "TikTok caption" genre: word-by-word highlight, pop/bounce scale, color swap, outline+shadow. Burn-in = `-vf "ass=captions.ass"` (needs libass in the build — see section 0). Soft subs (mov_text / WebVTT) cannot carry styling on social platforms, so burn-in is the norm for shorts. https://github.com/libass/libass, https://www.ffmpeg-micro.com/blog/ffmpeg-subtitles-filter-guide
- Word-level timestamps come from Whisper (faster-whisper, whisper.cpp, or ffmpeg 8's `whisper` filter). Open-source generators that emit styled ASS for ffmpeg: **ai-video-captions** (Hormozi/MrBeast/Karaoke/Bounce styles), **pycaps** (CSS-styled captions in Python), **CaptionsPlease**, **auto-captions**. https://github.com/nicolaigaina/ai-video-captions, https://github.com/francozanardi/pycaps, https://github.com/ozten/CaptionsPlease, https://github.com/nikhil-reddy05/auto-captions
- In a WebCodecs/canvas pipeline you render captions yourself (Canvas2D text with per-word timing), which is easier for pixel-perfect WYSIWYG preview but means two implementations if the final render is ffmpeg. Diffusion Studio core and Remotion both do canvas captions.

---

## 6. Transitions / effects

- **ffmpeg xfade:** 59 built-ins (list in section 0) + `custom`/`expr`. Requires identical size/fps/pixfmt inputs, constant frame rate, and `offset` = cumulative duration minus overlaps. https://ffmpeg.org/ffmpeg-filters.html#xfade, https://www.ffmpeglab.com/articles/ffmpeg-xfade-transitions-guide.html
- **xfade-easing** (122 stars, MIT, pushed 2026-08): adds Penner/CSS easings and **80+ ported gl-transitions** (gl_cube, gl_Swirl, gl_Mosaic, gl_SimplePageCurl...) either as a one-file ffmpeg patch (fast, threaded) or as stock-ffmpeg `expr` strings (works unmodified but single-threaded: 15 s to minutes per HD transition). https://github.com/scriptituk/xfade-easing
- **gl-transitions** (2.1k stars, MIT, v1.71.0, pushed 2026-06): the canonical GLSL transition collection. **ffmpeg-gl-transition** (719 stars, no license file, last push 2024-07) requires building ffmpeg from source with an out-of-tree filter and OpenGL — fragile on macOS where OpenGL is deprecated. Better path: run gl-transitions in the browser (WebGL/WebGPU) for preview and port to xfade/expr or a canvas shader for final. https://github.com/gl-transitions/gl-transitions, https://github.com/transitive-bullshit/ffmpeg-gl-transition
- **libplacebo** filter in ffmpeg supports custom GLSL in mpv `.hook` format over Vulkan; it works on macOS via MoltenVK but only in `ffmpeg-full`, and MoltenVK on Apple Silicon is a support risk. https://github.com/haasn/libplacebo, https://ayosec.github.io/ffmpeg-filters-docs/8.0/Filters/Video/libplacebo.html
- **frei0r** plugins are available to MLT and to `ffmpeg-full` (`frei0r` filter) for 100+ classic effects.
- **Diffusion Studio core / Omniclip / Etro** all do effects as Canvas2D/WebGL passes; Etro exposes GLSL effects directly (GPL).

---

## 7. Recommended architecture for the render layer

**Recommendation: a declarative JSON timeline (your own schema) as the single source of truth, compiled to two backends — a WebCodecs/Canvas preview renderer in the browser (built on Mediabunny) and an ffmpeg `filter_complex` + libass final renderer in the local Mac helper. Keep OTIO/FCPXML/EDL as export adapters. Do not adopt Remotion, MLT, or GES as the core.**

### The schema
Model it on Shotstack/Creatomate rather than OTIO: `tracks[] -> clips[] { id, asset{type: video|audio|image|text|caption|shape, src}, start, duration, in, out, speed, volume/audioCurve, transform{x,y,scale,rotate,opacity}, keyframes[], effects[{name, params}], transitionIn/Out{name, duration, easing} }`, plus `captions[] { words[{text, t0, t1}], style }` and `output{w,h,fps,codec}`. Seconds as decimals, enums for transitions/effects that map 1:1 to xfade names (+ xfade-easing ports) and to canvas shaders. Validate with JSON Schema and feed it to the LLM as a tool schema; the LLM emits *edits* to this document, never ffmpeg strings. This is the pattern that Shotstack productized (https://shotstack.io/docs/api/) and that video-use rediscovered with EDL + self-evaluation (https://github.com/browser-use/video-use).

### Preview (web UI)
Use **Mediabunny** for demux/decode (HEVC iPhone footage decodes in hardware in Chrome on macOS) and draw frames to a Canvas2D/WebGL compositor; run captions and gl-transitions as canvas/WebGL passes. Either build the compositor yourself or start from **@diffusionstudio/core** (MPL-2.0; accept the watermark or buy the one-time key; note its core repo has been quiet since 2025-11 as effort shifted to the Electron editor) or study Omniclip. This gives scrub-accurate, real-time preview without round-tripping to ffmpeg. Ship the UI in Chrome/Electron/Tauri-with-Chromium rather than relying on Safari, whose audio WebCodecs only landed in Safari 26.

### Final render (local Mac helper)
Compile the same JSON to ffmpeg: normalize every clip (`scale/pad/fps/format/settb`), build per-track chains, chain `xfade` (or `overlay` with `enable=between(t,...)` for true overlaps), mix audio with `amix`/`adelay`/`volume` envelopes and `sidechaincompress` for ducking, burn captions with `ass=` (generate ASS with `\k`/`\t` tags from word timings), encode with `hevc_videotoolbox`/`h264_videotoolbox`. Use **typed-ffmpeg** (TS or Python) to build and validate the graph instead of string-concatenating. Bundle your own ffmpeg (or require `brew install ffmpeg-full`) so libass, freetype, libplacebo and the `whisper` filter are present — the stock Homebrew `ffmpeg` lacks all of them. For effects you cannot express in ffmpeg (fancy GLSL transitions, memes with animated text), pre-render those segments/overlays from the browser compositor via WebCodecs (Mediabunny `Output`) as ProRes/PNG-alpha intermediates and hand them to ffmpeg — the "hybrid" that Remotion, Diffusion Studio and video-use all end up doing.

### Why not the alternatives
- **Remotion:** best-in-class motion graphics, but a prompt-to-video editor is squarely "Remotion for Automators" ($0.01/render, $100/mo minimum, IP telemetry) once you exceed 3 people, and its footage path is now Mediabunny anyway — you can use Mediabunny directly under a permissive MPL license. Consider Remotion only as an optional plugin for meme/graphics templates (https://www.remotion.dev/docs/license/pricing).
- **Pure WebCodecs in browser for final render:** fine for 1080p shorts, but long 4K exports are bound by Chrome's single-process memory, no libass, and Safari lag. Keep it as preview + intermediates.
- **MLT/melt:** the strongest OSS NLE core and LLM-emittable XML, but the 23-dependency Qt6/OpenCV Homebrew footprint, frame-based timing, and no in-browser preview make it a second engine you would have to mirror in the UI anyway. Revisit if you need real time-remapping (rubberband) or frei0r effects that ffmpeg-full cannot provide.
- **GES / libopenshot / Olive / Motion Canvas / Etro / editly:** macOS friction, GPL, dormancy, or stalled maintenance as documented above.

### Preview-vs-final consistency risk
Two renderers means two implementations of every transition, caption style and color op. Mitigate by (1) keeping the effect/transition vocabulary small and enum-driven, (2) generating both the canvas shader table and the xfade/ASS mapping from one registry, (3) using the browser render as the *reference* and running an automated "render diff" (frame SSIM at cut points, like video-use's self-eval loop) in CI, and (4) letting the helper use `@mediabunny/server` (NodeAV/libav, hw-accel on macOS) as an escape hatch to run the exact browser compositor headlessly when parity matters more than speed.
