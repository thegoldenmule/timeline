# Architecture Patterns for an LLM-Invokable, Testable AI Video Editor

Research report, 2026-09-08. Scope: design patterns that make video-editing features "easy to isolate, test, and invoke with an LLM" for a macOS/Apple Silicon app with a web timeline UI and a local daemon running ffmpeg and calling LLMs.

---

## 1. Agent tool design: what the vendors and MCP actually recommend

**Anthropic's guidance converges on a few rules.** "Building effective agents" frames tools as an *agent-computer interface* deserving the same care as a UI: "keep the format close to what the model has seen naturally occurring in text," document edge cases, and apply "poka-yoke" so misuse is structurally hard ([Anthropic](https://www.anthropic.com/engineering/building-effective-agents)). "Writing effective tools for agents" adds: **consolidate** frequently-chained operations into one call rather than exposing raw CRUD; **namespace** with prefixes (`timeline_*`, `caption_*`); offer a `response_format: "concise" | "detailed"` knob (their example: 72 vs 206 tokens); build in "pagination, range selection, filtering, and/or truncation with sensible default parameter values"; return **actionable error messages** rather than tracebacks; and write descriptions as if "to a new hire," making "implicit context explicit" ([Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents)). Their eval loop is: realistic multi-call tasks, read transcripts, iterate.

**OpenAI's function-calling guide agrees almost verbatim**: "use enums and object structure to make invalid states unrepresentable"; don't make the model fill in values your code already knows; "combine functions that are always called in sequence"; keep "fewer than 20 functions available at the start of a turn" and defer the rest via tool search; enable `strict` mode (`additionalProperties: false`, all fields required, optionals as `null`) ([OpenAI](https://developers.openai.com/api/docs/guides/function-calling)).

**MCP formalizes the contract.** Each tool has `name`, `description`, `inputSchema`, optional `outputSchema`, and behavioral `annotations`: `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`. Results can carry `structuredContent` (which "SHOULD" also be serialized into a text block), errors are signaled with `isError: true` inside the result (so the model can self-correct) rather than as protocol errors, `tools/list` is paginated with cursors, and clients "SHOULD always" keep "a human in the loop with the ability to deny tool invocations" ([MCP spec](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)). The Claude Agent SDK's in-process MCP server exposes exactly this: `tool(name, description, zodShape, handler, {annotations})`, `readOnlyHint: true` lets Claude call tools in parallel, `isError` lets you "compose the message Claude reads," and tool search is on by default so tools are deferred until needed ([Claude Agent SDK custom tools](https://code.claude.com/docs/en/agent-sdk/custom-tools)).

**Code execution against a tool API.** Anthropic's "Code execution with MCP" argues that when a task chains many calls, the model should write a short script against a typed API (tools presented as files like `./servers/video/addCaption.ts`) instead of issuing many tool calls; intermediate data stays in the sandbox, and their example drops from 150k to 2k tokens ("98.7%"). Agents can persist working scripts into a `./skills/` folder ([Anthropic](https://www.anthropic.com/engineering/code-execution-with-mcp)). For a video editor this maps to: a "batch" tool or scripting tool that accepts an *array of operations* against the timeline document.

**Skills package procedures, not capabilities.** Agent Skills are "organized folders of instructions, scripts, and resources" with a `SKILL.md` whose YAML `name`/`description` loads at startup (level 1), whose body loads on relevance (level 2), and whose bundled files/scripts load on demand (level 3); scripts give "deterministic reliability" where code beats tokens ([Anthropic](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)). Remotion ships exactly this for video: `remotion-dev/skills` teaches agents "how TransitionSeries handles frame overlap... how spring() and interpolate() work" and has a `display-captions.md` rule for TikTok-style captions ([Remotion skills](https://www.remotion.dev/docs/ai/skills), [rule file](https://github.com/remotion-dev/skills/blob/main/skills/remotion/rules/display-captions.md)). Recommendation: tools = primitive, schema-checked operations; skills = "how to make a TikTok-style caption edit" recipes that sequence those tools.

## 2. Declarative document + pure operations

**Prior art for "agent emits a document, a compiler renders it."** Shotstack's JSON model is an `Edit` containing a `Timeline` of `Tracks` (layers, top obscures bottom) of `Clips`, each with `start`, `length`, `asset`, `trim`, `transition`, `effect`, `filter`, `volume`, plus an `Output` block ([Shotstack](https://shotstack.io/docs/guide/getting-started/core-concepts/)). Creatomate, JSON2Video and Editframe follow the same shape with richer keyframes/animation (Creatomate) or HTML/CSS elements (Editframe) ([comparison](https://www.wireflow.ai/blog/creatomate-vs-shotstack), [Editframe](https://editframe.com/docs)). OpenTimelineIO is the industry interchange: a `Timeline` holding a `Stack` of `Track`s of `Clip | Gap | Transition | Stack`, media via `ExternalReference`/`MissingReference`, time as `RationalTime` (value/rate) and `TimeRange` (start+duration), serialized as JSON with schema versioning/upgrade on read ([OTIO architecture](https://github.com/AcademySoftwareFoundation/OpenTimelineIO/blob/main/docs/tutorials/architecture.md), [versioning](https://github.com/AcademySoftwareFoundation/OpenTimelineIO/blob/main/docs/tutorials/versioning-schemas.md)). The open-source-cinema survey concludes the "declarative timeline model" is the right agent substrate because OTIO's JSON lets LLMs "read, understand, and generate timelines directly," and that the GUI "transforms into a review interface" ([survey](https://github.com/12georgiadis/open-source-cinema/blob/master/Agent-Driven-Editing-2026.md)). Remotion notably goes the other way for *generation*: LLMs emit React code as a string, validated through Zod structured output with retries ([Remotion](https://www.remotion.dev/docs/ai/generate)); that is right for motion graphics but wrong for a multi-track editor where humans must inspect and drag things.

**Descript is the strongest UX precedent** for a non-timeline view over a timeline: "change the transcript, and Descript updates the underlying media automatically," deletions are non-destructive, and users can switch to the timeline for precise work ([Descript help](https://help.descript.com/hc/en-us/articles/15726742913933-Edit-like-a-doc)). For an agent, transcript words are the natural addressable unit ("cut everything between 'so anyway' and 'the point is'").

**Operations, not raw document mutation.** Give the agent a small command vocabulary (`splitClip`, `moveClip`, `trimClip`, `addCaptionTrack`, `applyTransition`, `addOverlay`) that are *pure functions* `(doc, cmd) -> doc'` with an `invert(doc, cmd) -> cmd⁻¹`. This gives you undo/redo for free, makes every operation a unit test, matches OpenAI's "make invalid states unrepresentable" (a `moveClip` cannot create overlaps if the reducer refuses), and is what Kinocut's "workflow engine" and OpenMontage's locked `edit_decisions` effectively do ([Kinocut](https://github.com/KyaniteLabs/kinocut), [OpenMontage](https://github.com/calesthio/OpenMontage)). Expose a `timeline_apply({ ops: [...], baseVersion })` batch tool so the model can do N edits in one call (the code-execution insight, without a sandbox).

**Reconciling agent and human edits.** Two viable approaches:

- *Optimistic locking*: the document carries a monotonically increasing `version`; every mutating tool takes `baseVersion` and fails with a compact diff ("clip c7 moved by user to 12.4s; reload and retry") when stale. Simple, deterministic, trivially testable, and the error is exactly the "actionable error" Anthropic recommends. Recommended for v1.
- *CRDT*: Yjs `Y.Map`/`Y.Array` merge concurrent changes "without merge conflicts," and `Y.UndoManager({ trackedOrigins })` lets you undo only *your* changes while ignoring another origin (the agent) ([Yjs](https://docs.yjs.dev/), [UndoManager](https://docs.yjs.dev/api/undo-manager)). Automerge adds a git-like full history with branching/merging and has Swift bindings ([Automerge](https://automerge.org/docs/hello/)). CRDTs shine if agent and human edit *simultaneously* during a long render or if you want multi-device sync; otherwise they add complexity and make "what did the agent do?" harder to explain than a versioned op log.

## 3. Testing strategies for video pipelines

- **Determinism.** FFmpeg's `-bitexact`/`-fflags +bitexact` "only writes platform-, build- and time-independent data" so "checksums are reproducible... its primary use is for regression testing" ([FFmpeg codecs docs](https://openwebsite.github.io/ffmpeg/ffmpeg-codecs.html)). FFmpeg's own FATE suite uses `-bitexact` plus the `framecrc`/`framemd5` muxers to hash decoded frames ([FATE](https://ffmpeg.org/fate.html), [fate-run.sh](https://github.com/rvs/ffmpeg/blob/master/tests/fate-run.sh)). Also pin the ffmpeg build, encode tests with lossless or `-c:v rawvideo`, and fix `-r`, `-pix_fmt`, and `-frames:v`.
- **Synthetic fixtures.** `-f lavfi -i testsrc2=size=320x180:rate=30:duration=2`, `color=c=red`, `smptebars`, `sine=frequency=440`, `anullsrc` generate media in-process so the repo ships no binaries ([FFmpeg filters](https://ffmpeg.org/ffmpeg-filters.html)). Generate once into a cache keyed by the lavfi string.
- **Frame snapshot tests.** Compare against goldens with the `ssim`/`psnr` filters (`-lavfi ssim=stats_file=...`), thresholded rather than bit-exact so codec drift does not break CI; `ffmpeg-quality-metrics` wraps this ([tool](https://github.com/slhck/ffmpeg-quality-metrics), [guide](https://ottverse.com/calculate-psnr-vmaf-ssim-using-ffmpeg/)). For single extracted PNGs, `pixelmatch` gives anti-aliasing-aware diffs with `threshold` and a `windowSize` density option that "detects genuine regressions while remaining robust to scattered noise" ([pixelmatch](https://github.com/mapbox/pixelmatch)). Perceptual hashes (pHash/dHash) are a cheap third tier for "did the caption appear in this second at all."
- **Compiler golden tests.** The `timeline -> ffmpeg args` compiler is pure; snapshot the emitted `filter_complex` string and argv for each fixture document. This is the cheapest, highest-value test layer and needs no ffmpeg.
- **Property-based tests on operations.** `fast-check` supports model-based testing with commands for stateful systems ([fast-check](https://fast-check.dev/)); Hypothesis offers `RuleBasedStateMachine` in Python ([Hypothesis](https://hypothesis.readthedocs.io/en/latest/)). Invariants: no overlapping clips on a track, total duration = max clip end, `apply(invert(op))` is identity, `apply(ops)` is order-independent for disjoint clips, serialization round-trips.
- **Schema contract tests.** Zod 4's `z.toJSONSchema()` converts tool schemas to JSON Schema (draft 2020-12/7/OpenAPI targets) so one Zod definition feeds the MCP `inputSchema`, the HTTP validator, and TypeScript types ([Zod](https://zod.dev/json-schema)). Test that every registered tool's schema is strict (no `additionalProperties`), has descriptions on every field, and that example payloads in docs validate.
- **Agent evals.** Anthropic's "Demystifying evals for AI agents" recommends code-based graders where possible, "grade what the agent produced, not the path it took," state-based checks on the environment, `pass@k` vs `pass^k` for reliability, seeding eval sets from manual tests and user failures, and running them in CI; "read the transcripts!" ([Anthropic](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)). For this app the "state" is the timeline document, so graders are pure assertions on JSON (e.g., "a caption track exists, every caption overlaps a transcript word, none exceed 2 lines"). promptfoo (YAML, CLI, CI) or Braintrust (traces + CI gates) can host them ([Braintrust comparison](https://www.braintrust.dev/articles/braintrust-vs-promptfoo)); a scripted fake model that replays recorded tool calls tests the agent loop and UI without spending tokens.
- **UI visual regression.** Playwright's `toHaveScreenshot()` (pixelmatch under the hood, `maxDiffPixels`, per-platform snapshots) covers the timeline canvas ([Playwright](https://playwright.dev/docs/test-snapshots)).

## 4. Local daemon + web UI

**Runtime choice.** File System Access pickers (`showOpenFilePicker`, `showDirectoryPicker`) are Chromium-only; Safari and Firefox implement only the sandboxed OPFS ([caniuse](https://caniuse.com/mdn-api_window_showopenfilepicker), [MDN](https://developer.mozilla.org/en-US/docs/Web/API/File_System_API)). Therefore the **daemon must own the files**: the UI asks the daemon to import a path (via a native dialog if wrapped in Tauri/Electron, or a drag-drop upload to `localhost`), and media is referenced by daemon-issued asset IDs. Options:

- *Node/Bun + TypeScript*: one language for the UI, the tool registry (Zod), the MCP server (`@modelcontextprotocol/sdk`), and the Claude Agent SDK; `Bun.spawn` or `execa` for ffmpeg. Strongest fit given the "one registry, three surfaces" goal.
- *Python/FastAPI*: FastMCP can generate an MCP server from a FastAPI app's OpenAPI spec (`FastMCP.from_fastapi()`), preserving Pydantic schemas ([FastMCP](https://gofastmcp.com/integrations/openapi), [Speakeasy guide](https://www.speakeasy.com/mcp/framework-guides/building-fastapi-server)). Good if you want Whisper/PyTorch analysis in-process.
- *Tauri (Rust) sidecar*: tiny bundles, native WebView, Rust backend; but a Rust tool registry means duplicating schemas across Rust and TS, hurting the single-registry goal ([Tauri vs Electron](https://dev.to/ottoaria/tauri-in-2026-build-cross-platform-desktop-apps-with-web-technologies-better-than-electron-11mo)). Reasonable as a *shell* around a TS daemon.
- *Swift*: best for AVFoundation/VideoToolbox previews but no first-party Claude Agent SDK; treat as a future native shell.

**Transport.** HTTP for commands; SSE or WebSocket for render progress and document-change events; a persistent job queue for renders (jobs carry document hash + settings, so identical requests dedupe and results are cacheable). This mirrors Kinocut's "Video Receipts" (SHA-256 of inputs/outputs, resume cursor) and OpenMontage's checkpointed JSON state ([Kinocut](https://github.com/KyaniteLabs/kinocut), [OpenMontage](https://github.com/calesthio/OpenMontage)).

**One registry, many surfaces.** Define each feature once as `{ name, description, input: ZodSchema, output: ZodSchema, annotations, handler }`. Adapters then generate: (a) HTTP routes `POST /tools/:name` with OpenAPI from `z.toJSONSchema`; (b) an MCP stdio/HTTP server for Claude Code/Claude Desktop (Claude Code speaks both `stdio` and `http`, configured with `claude mcp add --transport http video http://127.0.0.1:PORT/mcp` or a project `.mcp.json` ([Claude Code MCP docs](https://code.claude.com/docs/en/mcp))); (c) `createSdkMcpServer({ tools })` for the embedded Claude Agent SDK agent ([SDK](https://code.claude.com/docs/en/agent-sdk/custom-tools)). FastMCP's OpenAPI-to-MCP and Vercel AI SDK's `tool()`/MCP client support are existing instances of this "single definition, multiple protocols" idea ([FastMCP](https://gofastmcp.com/integrations/openapi), [AI SDK 6](https://vercel.com/blog/ai-sdk-6)).

## 5. Agent runtime

- **Claude Agent SDK** gives you the Claude Code harness (loop, compaction, tool search, hooks, subagents) with in-process MCP tools; permission evaluation order is hooks -> deny rules -> ask rules -> mode -> allow rules -> `canUseTool` callback, which is where "approve this 4K render?" lives, and `PreToolUse` hooks run before everything ([permissions](https://code.claude.com/docs/en/agent-sdk/permissions)). Downside: Claude-only, model drives control flow.
- **Vercel AI SDK 6** is provider-agnostic TypeScript with `ToolLoopAgent`, stable MCP client, and `needsApproval: true | async (input) => boolean` on a tool; the UI sees `approval-requested` parts and calls `addToolApprovalResponse()`; denial reaches the model as a result ([cookbook](https://ai-sdk.dev/cookbook/next/human-in-the-loop)). Best streaming-tool-call React integration.
- **LangGraph** gives explicit graphs, durable checkpoints, and `interrupt()` that "saves the graph state... and waits indefinitely" until `Command(resume=...)` ([LangGraph](https://docs.langchain.com/oss/python/langgraph/interrupts)); heavier, Python-first.
- **Hand-rolled loop** is fine only if the registry already handles schema validation and approval; the SDKs' compaction and tool-search are hard to replicate.

Comparisons agree: "The Agent SDK gives you a finished loop; LangGraph gives you the materials to build one," and Vercel wins for multi-provider TS/React stacks ([Developers Digest](https://www.developersdigest.tech/blog/claude-agent-sdk-vs-langgraph), [dev.to](https://dev.to/muhammad_moeed/claude-agent-sdk-vs-vercel-ai-sdk-6-which-to-pick-in-2026-2jj)).

**Cost control.** Use Anthropic's routing/orchestrator-workers patterns: a cheap model (Haiku-class) for analysis passes (transcript alignment, scene detection summarization, silence classification) and a strong model for creative direction, with expensive renders gated by approval ([Anthropic](https://www.anthropic.com/engineering/building-effective-agents)). OpenMontage's default "$0.50 per-action approval threshold" and pre-execution cost estimates are a good template ([OpenMontage](https://github.com/calesthio/OpenMontage)).

**Claude Code as the agent (via your MCP server) vs embedded agent.** Pros: zero agent code, users already trust and pay for Claude Code, skills/plugins ecosystem, it can also read your repo/scripts. Cons: no control over the system prompt or model routing, approval UX lives in the terminal not the timeline, and users without Claude Code get nothing. Do both: the MCP surface is free once the registry exists, and the embedded agent (Claude Agent SDK) reuses the same tools with a custom `canUseTool` that renders approval cards in the UI.

## 6. Open-source agentic video editors: lessons

- **Kinocut** (196 MCP tools, Python lib, CLI): right about preflight validation that "fails closed," typed parameters instead of ffmpeg flags, hashed receipts and quality checkpoints (thumbnails, LUFS, `blackdetect`); wrong-ish in surface area, 196 flat tools contradicts the "<20 initially visible" guidance and needs tool search ([Kinocut](https://github.com/KyaniteLabs/kinocut)).
- **OpenMontage**: right about layered knowledge (tools -> skills -> deep skills), YAML pipelines with success criteria, mandatory human gates, locking runtime choice in `edit_decisions`, post-render self-review with ffprobe/frame sampling; risky in "no code orchestrator, the assistant IS the orchestrator" and JSON checkpoint fragility ([OpenMontage](https://github.com/calesthio/OpenMontage)).
- **FireRed-OpenStoryline**: LangChain planner, MoviePy/ffmpeg renderer, reusable "Style Skills" (save a workflow, swap media); the timeline is implicit in conversation rather than a first-class inspectable document ([FireRed](https://github.com/FireRedTeam/FireRed-OpenStoryline)).
- **vibevideo-mcp**: React UI + Express MCP + Flask ffmpeg executor; three processes and two languages for one feature set is the anti-pattern the single registry avoids ([vibevideo-mcp](https://github.com/hyepartners-gmail/vibevideo-mcp)).
- **Remotion + LLM**: skills-driven codegen, Zod-validated structured output, `@remotion/captions` `createTikTokStyleCaptions()` paging tokens into word-highlight pages ([Remotion](https://www.remotion.dev/docs/captions/create-tiktok-style-captions)). Worth using as the *caption/overlay renderer* (render to transparent PNG sequence or ProRes 4444, composite with ffmpeg) even if the core compiler is ffmpeg.

## 7. Recommendations

### Module boundaries

```
packages/
  timeline-core/     pure: Document schema (zod), ops + invert, reducer, invariants, selectors
  compiler-ffmpeg/   pure: Document -> {argv, filter_complex, inputs}; no I/O
  media/             ffprobe wrappers, asset store (ids -> paths, hashes), thumbnails, waveform
  analysis/          transcription (whisper), silence/scene detection -> typed annotations
  renderers/         ffmpeg runner (job queue, progress), remotion caption/overlay renderer
  tools/             the registry: features as Tool<In,Out>; adapters: http, mcp, agent-sdk
  agent/             Claude Agent SDK wiring, skills/, model routing, approval policy
  daemon/            HTTP + SSE server, job queue, document store (versioned)
apps/web/            timeline UI; talks only to daemon HTTP/SSE
```

`timeline-core` and `compiler-ffmpeg` import nothing with side effects; everything else depends inward.

### Tool registry (TypeScript)

```ts
import { z } from "zod";

export interface Tool<I extends z.ZodTypeAny, O extends z.ZodTypeAny> {
  name: `${string}_${string}`;            // namespaced: timeline_apply, caption_add
  description: string;                    // "new hire" prose, when to use / not use
  input: I; output: O;
  annotations: { readOnlyHint: boolean; destructiveHint: boolean; idempotentHint: boolean };
  cost?: (input: z.infer<I>, ctx: Ctx) => Promise<CostEstimate>;  // for approval gating
  run: (input: z.infer<I>, ctx: Ctx) => Promise<z.infer<O>>;
}

export const registry = new Map<string, Tool<any, any>>();
export function defineTool<I extends z.ZodTypeAny, O extends z.ZodTypeAny>(t: Tool<I,O>) {
  registry.set(t.name, t); return t;
}

// Adapter: MCP / Agent SDK
export const asSdkTools = () => [...registry.values()].map(t =>
  tool(t.name, t.description, t.input.shape, async (args, extra) => {
    try {
      const out = t.output.parse(await t.run(args, ctxFrom(extra)));
      return { content: [{ type: "text", text: summarize(out) }], structuredContent: out };
    } catch (e) {
      return { content: [{ type: "text", text: toActionableMessage(e) }], isError: true };
    }
  }, { annotations: t.annotations }));

// Adapter: HTTP
app.post("/tools/:name", async (req, res) => { /* validate with t.input, run, return output */ });
// OpenAPI: z.toJSONSchema(t.input) / z.toJSONSchema(t.output)
```

Core tools (keep under ~15 visible; rest deferred): `project_describe` (concise/detailed), `media_import`, `media_analyze` (transcript, scenes, silence), `timeline_apply({ops, baseVersion})`, `timeline_query`, `caption_add`, `transition_add`, `overlay_add` (memes/images/text), `effect_add`, `render_preview` (low-res, fast), `render_export` (approval-gated), `frame_grab` (returns image for the model to look at).

### Worked example: "add animated captions"

1. `analysis/transcribe` yields `Word[] {text, startMs, endMs}` (tested with a fixture transcript; whisper mocked).
2. `timeline-core/captions.ts`: pure `buildCaptionPages(words, {maxWordsPerPage, combineWithinMs}) -> CaptionPage[]` (property tests: pages cover every word, none overlap, ordered) and op `addCaptionTrack(doc, {pages, style})`.
3. `renderers/captions`: `CaptionPage[] + style -> ASS subtitle file` (golden text snapshot) *or* a Remotion composition rendered to a PNG sequence (frame SSIM snapshot against `testsrc2` background).
4. `compiler-ffmpeg`: given a doc with a caption track, emits `subtitles=` or `overlay` filter (golden `filter_complex` string).
5. `tools/caption_add`: input `{ style: enum["tiktok","subtitle","karaoke"], source: "transcript" | {pages}, trackId?, baseVersion }`, `destructiveHint: false`, `idempotentHint: true` (keyed by content hash), returns `{ version, trackId, pageCount, warnings[] }`; contract test validates schema strictness and an example payload; an eval asks the agent to "add TikTok captions to clip 2" and asserts the resulting document state.
6. `skills/tiktok-captions/SKILL.md`: the procedure (transcribe -> trim filler -> `caption_add style=tiktok` -> `frame_grab` two frames to check legibility -> ask before `render_export`).

### Testing pyramid

| Layer | Volume | Tooling | Needs |
|---|---|---|---|
| Pure ops, invariants, compiler goldens | thousands | vitest + fast-check, snapshot of argv/filter_complex | nothing |
| Schema contracts (every tool strict, documented, examples validate) | per tool | zod + `z.toJSONSchema` | nothing |
| Renderer frame snapshots | dozens | ffmpeg `-bitexact`, lavfi sources, `ssim` threshold / pixelmatch | ffmpeg |
| Scripted agent scenarios | dozens | fake model replaying tool calls through the real loop + UI | nothing |
| LLM evals (state-based graders on document JSON, pass^k) | 20-50 tasks, nightly | promptfoo/Braintrust, real model | tokens |
| UI visual regression | key screens | Playwright `toHaveScreenshot` | browser |
| End-to-end export smoke | a few | full render of fixture project, ffprobe assertions | ffmpeg |

The document-as-state design is what makes the top of the pyramid cheap: almost every agent behavior can be asserted as a JSON predicate before a single frame is rendered.
