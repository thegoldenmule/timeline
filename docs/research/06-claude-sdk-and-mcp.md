# Claude Agent SDK, MCP, Skills, Vision, and Evals

Research date: 2026-09-08. Condensed from the Claude Code guide agent's report.

## Claude Agent SDK (TypeScript / Python)

- Embeddable harness (`@anthropic-ai/claude-agent-sdk`): the Claude Code agent loop in your own process. Built-in tools (Read/Write/Edit/Bash/Glob/Grep/WebSearch/WebFetch), sessions with resume/fork, hooks (pre/post tool), permission modes, `canUseTool` callback for human-in-the-loop approval, subagents, streaming, structured output, cost tracking, skills and plugins loaded from `.claude/`.
- Custom in-process tools: `createSdkMcpServer({ tools: [tool(name, description, zodShape, handler, { annotations })] })`. `readOnlyHint: true` allows parallel calls; return `isError: true` with an actionable message so the model self-corrects. Tool search is on by default, so large tool sets are deferred until relevant.
- Versus Tool Runner (`client.beta.messages.tool_runner`): lower level, you supply every tool, no built-ins, no compaction/session machinery. Versus Managed Agents: Anthropic-hosted sandbox, not embeddable.
- Other languages: run `claude -p --output-format stream-json --mcp-config ...` as a subprocess (relevant for a Swift app).
- Docs: https://code.claude.com/docs/en/agent-sdk-overview.md , https://code.claude.com/docs/en/agent-sdk/custom-tools , https://code.claude.com/docs/en/agent-sdk/permissions , https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-runner.md

## MCP server for the editor

- TypeScript SDK: https://github.com/modelcontextprotocol/typescript-sdk ; Swift SDK (client + server, stdio and Streamable HTTP, pre-1.0): https://github.com/modelcontextprotocol/swift-sdk
- Claude Code attaches with `claude mcp add --transport http video http://127.0.0.1:PORT/mcp` or a project `.mcp.json`. Local servers must bind 127.0.0.1 and validate `Origin`.
- Tool results may include `{ type: "image", source: { type: "base64", media_type: "image/png", data } }` so the model can look at a grabbed frame or contact sheet. Keep results high-signal; default result cap is ~25K tokens.
- Use MCP resources for read-only catalogs (transition presets, caption styles), tool annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`), and elicitation for approvals where the client supports it.
- Debug with `@modelcontextprotocol/inspector`.

## Tool design guidance (applied to 30-60 editing operations)

- Consolidate chained operations; namespace (`timeline_*`, `caption_*`); keep under ~15-20 tools visible at once and defer the rest via tool search.
- Descriptions written for a new hire: what, when, when not, what is not returned. Use enums so invalid states are unrepresentable. Offer `response_format: concise | detailed`.
- Return IDs, durations, versions, warnings, and optionally a thumbnail. Never return raw ffmpeg logs.
- Sources: https://www.anthropic.com/engineering/writing-tools-for-agents , https://www.anthropic.com/engineering/building-effective-agents , https://www.anthropic.com/engineering/code-execution-with-mcp

## Agent Skills

- `SKILL.md` folders with YAML frontmatter (`name`, `description`, optional `allowed-tools`, `context: fork`). Loaded progressively: metadata at startup, body on relevance, bundled scripts on demand. Ideal for procedures such as "TikTok-style captions" that sequence primitive tools. Remotion ships a public example: https://www.remotion.dev/docs/ai/skills
- Docs: https://code.claude.com/docs/en/skills.md

## Vision and model pricing (verify against the pricing page before budgeting)

- Images only, no native video input. Up to 100 images per request; 10 MB per image; JPEG/PNG/GIF/WebP. Send one keyframe per shot plus contact sheets to cut cost.
- Family and list prices reported by the agent (per million tokens, input/output): Fable 5.1 $10/$50, Opus 5 $5/$25, Sonnet 5 $2/$10, Haiku 4.5 $1/$5. Prompt caching cuts repeated timeline-document context to roughly 10% of input price.
- Routing: Haiku-class for analysis passes (scene summaries, silence classification), Sonnet/Opus for creative direction, Fable for hard multi-file planning.
- Docs: https://platform.claude.com/docs/en/build-with-claude/vision.md , https://platform.claude.com/docs/en/models/overview

## Evaluating the agent

- `claude plugin eval` (early access): eval cases with graders (regex, tool_used, file_exists, LLM judge). `/skill-doctor` reports skill usage.
- Practical approach: state-based graders on the timeline JSON after a scripted task, a fake model that replays recorded tool calls to exercise the loop and UI without tokens, and nightly real-model evals (promptfoo or Braintrust). See https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents

## Recommendation

Both surfaces: expose the editor's tool registry as an MCP server (so Claude Code, Claude Desktop, or Cursor can drive it), and embed an agent for in-app use. In a TypeScript app the embedded agent is the Agent SDK in-process; in a Swift app it is either the Claude Code CLI as a sidecar speaking MCP to the app, or the Messages API through a community Swift SDK (an official `ClaudeForFoundationModels` package exists but requires macOS 27).
