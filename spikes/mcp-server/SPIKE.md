# Spike: in-process MCP server in Swift (official MCP Swift SDK) + Claude Code

Date: 2026-09-08. Machine: macOS 26.3, M4 Max, Swift 6.3.3, Claude Code 2.1.263.
Location: `spikes/mcp-server/` (throwaway; ~300 lines of Swift). Wall clock: ~35 min.

## Assumption under test

> The official MCP Swift SDK can host a Streamable HTTP MCP server on 127.0.0.1 from a Swift process,
> expose tools with JSON Schema inputs and structured + image results, and Claude Code can attach and
> call the tools; stdio works as a fallback.

**Verdict: validated, with one caveat** - the SDK ships the HTTP *transport* but not an HTTP *listener*;
you bring ~90 lines of swift-nio glue (or Hummingbird/Vapor) to put it on a socket. Details below.

## 1. SDK: version and API shape

- Package: `https://github.com/modelcontextprotocol/swift-sdk`, pinned `exact: "0.12.1"` (latest tag on
  2026-09-08; README still says 0.11.0). swift-tools-version 6.1, platforms macOS 13+. Dependencies it pulls
  in: swift-system, swift-log, swift-async-algorithms, mattt/eventsource, **swift-nio (Core/Posix/HTTP1)**.
- Server API (all `actor`-based, `Sendable` everywhere):
  ```swift
  let server = Server(name:, version:, instructions:, capabilities: .init(tools: .init(listChanged: false)))
  await server.withMethodHandler(ListTools.self) { _ in .init(tools: [Tool...]) }
  await server.withMethodHandler(CallTool.self) { params in CallTool.Result(content:, structuredContent:, isError:) }
  try await server.start(transport: someTransport); await server.waitUntilCompleted()
  ```
- JSON is modelled by the SDK's `Value` enum (`.object/.array/.string/.int/...`, literal-expressible,
  `Value(anyCodable)` throwing init, `.intValue/.stringValue/.objectValue` accessors). Input schemas are just
  `Value` - no schema DSL or macro; you hand-write JSON Schema as nested literals.
- **Tool annotations: supported.** `Tool.Annotations(title:, readOnlyHint:, destructiveHint:, idempotentHint:, openWorldHint:)`.
  Verified in `tools/list` output.
- **structuredContent: supported.** `CallTool.Result(structuredContent: Value?)` plus a throwing generic
  `init(structuredContent: some Codable)`. `Tool.outputSchema` exists too.
- **Image content: supported.** `Tool.Content.image(data: base64, mimeType:, annotations:, _meta:)`; also
  `.audio`, `.resource`, `.resourceLink`.
- Also present (not exercised): request cancellation, progress, logging capability, elicitation, sampling,
  roots, completion, OAuth bearer/protected-resource validators, `Server.currentHTTPContext` (per-request
  HTTP headers inside a handler).

## 2. Transport findings (server side)

| Transport | In SDK 0.12.1? | Notes |
|---|---|---|
| `StdioTransport` | yes | newline-delimited JSON-RPC on fds; complete. |
| `StatelessHTTPServerTransport` | yes | `handleRequest(HTTPRequest) -> HTTPResponse`; plain JSON responses, no session, no SSE, GET/DELETE -> 405. |
| `StatefulHTTPServerTransport` | yes | Same shape; adds `Mcp-Session-Id`, SSE (`.stream`) responses, resumability via `Last-Event-ID`, GET stream for server->client. |
| `InMemoryTransport` | yes | for tests. |
| `NetworkTransport` | yes | raw Network.framework (not Streamable HTTP). |
| HTTP **listener** | **no** | The HTTP transports are framework-agnostic adapters over the SDK's own `HTTPRequest`/`HTTPResponse` types. Nothing in the library binds a port. The repo's own conformance server (`Sources/MCPConformance/Server/HTTPApp.swift`, 432 lines) does it with raw swift-nio. |

So: "self-contained" is only half true. The SDK already depends on swift-nio, so no *new* dependency is
needed, but you write the `ServerBootstrap` + `ChannelInboundHandler` + session map yourself
(`Sources/TimelineMCP/HTTPHost.swift`, ~95 lines here). In a real app this is where you'd choose between
raw NIO (done here), Hummingbird, or Vapor; the transport does not care.

Built-in request validation pipeline (default when `validationPipeline: nil`):
`OriginValidator.localhost()` (**Origin and Host checked**, DNS-rebinding protection), `AcceptHeaderValidator`,
`ContentTypeValidator`, `ProtocolVersionValidator`, `SessionValidator`. So Origin validation did NOT need
to be hand-rolled. Verified: `Origin: http://evil.example` -> 403; `Host: evil.example` -> 421; no Origin
(CLI clients) -> 200.

Gotchas found:
- `JSONRPCMessageKind` (used by the conformance app to spot `initialize`) is `internal`; I sniff
  `"method":"initialize"` with JSONSerialization instead.
- One `Server` instance per session is the SDK's model (Server owns exactly one transport). Shared editor
  state therefore lives outside the Server (here a `FakeProject` actor captured by the handler closures).
- If the transport rejects `initialize` (e.g. bad Origin) after you've created the session, you must tear it
  down yourself - my first version leaked a session; fixed by checking `if case .error = resp`.

## 3. What was built

`Sources/TimelineMCP/` (297 lines total incl. Package.swift):
- `Project.swift` - `FakeProject` actor: 3 clips on tracks V1/A1, `version`, `apply(ops:baseVersion:commandId:)`
  with optimistic concurrency (stale base -> `.stale(current:)`) and idempotency (`commandId -> result` cache,
  checked before the version check so a retry of an already-applied command succeeds even though its base is now stale).
- `Tools.swift` - three `Tool`s with JSON Schema + annotations + outputSchema; `handleCall`; `renderPNG`
  (CoreGraphics + CoreText + ImageIO, no AppKit so it stays off the main actor); stderr call logging.
- `HTTPHost.swift` - NIO listener on 127.0.0.1, per-session `StatefulHTTPServerTransport`, SSE streaming out.
- `main.swift` - `--http <port>` or `--stdio`.

Tools:
| name | annotations | result |
|---|---|---|
| `project_describe` | readOnly, idempotent, !destructive, !openWorld | text (JSON) + `structuredContent {version, tracks, clips}` |
| `timeline_apply` | !readOnly, idempotent, !destructive | `structuredContent {version, changedIds}`; stale -> `isError:true` + `{error:"stale_version", baseVersion, currentVersion, hint}` |
| `look_at` | readOnly, !idempotent | text + `image/png` block (320x80 card with ISO timestamp, ~5 KB) |

## 4. Streamable HTTP transcript (curl, port 8811; `./curl-transcript.sh 8811`, full output in `curl-transcript.txt`)

Common headers: `Content-Type: application/json`, `Accept: application/json, text/event-stream`,
`Origin: http://127.0.0.1:8811`; after init also `Mcp-Session-Id: <sid>`, `MCP-Protocol-Version: 2025-06-18`.

```
POST /mcp  {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}
HTTP/1.1 200 OK   MCP-Session-Id: E5765CCB-...   Content-Type: text/event-stream
id: 1_1            <- priming event (resumability)
data:
id: 1_2
event: message
data: {"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{"listChanged":false}},"instructions":"Fake video editor project...","protocolVersion":"2025-06-18","serverInfo":{"name":"timeline-spike","version":"0.0.1"}}}

POST /mcp  {"jsonrpc":"2.0","method":"notifications/initialized"}
HTTP/1.1 202 Accepted

POST /mcp  {"jsonrpc":"2.0","id":2,"method":"tools/list"}
data: {"id":2,...,"result":{"tools":[{"name":"project_describe","annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":false,"readOnlyHint":true,"title":"Describe project"},"inputSchema":{...},"outputSchema":{...}}, {"name":"timeline_apply",...}, {"name":"look_at",...}]}}

POST /mcp  {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"project_describe","arguments":{}}}
data: {"id":3,...,"result":{"content":[{"type":"text","text":"{\"clips\":[...],\"tracks\":[\"A1\",\"V1\"],\"version\":1}"}],"structuredContent":{"clips":[{"duration":150,"id":"a1","start":0,"track":"A1"},{"duration":90,"id":"c1","start":0,"track":"V1"},{"duration":60,"id":"c2","start":90,"track":"V1"}],"tracks":["A1","V1"],"version":1}}}

POST /mcp  {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"timeline_apply","arguments":{"baseVersion":1,"commandId":"cmd-A","ops":[{"op":"moveClip","clipId":"c1","start":120}]}}}
data: {"id":4,...,"result":{"content":[{"type":"text","text":"Applied. version=2 changedIds=[\"c1\"]"}],"structuredContent":{"changedIds":["c1"],"version":2}}}

POST /mcp  (identical retry, same commandId "cmd-A", baseVersion 1)          <- idempotent
data: {"id":5,...,"result":{...,"structuredContent":{"changedIds":["c1"],"version":2}}}   (version NOT bumped again)

POST /mcp  {"...","params":{"name":"timeline_apply","arguments":{"baseVersion":1,"commandId":"cmd-B","ops":[{"op":"trimClip","clipId":"c2","duration":30}]}}}   <- stale
data: {"id":6,...,"result":{"content":[{"type":"text","text":"{\"baseVersion\":1,\"currentVersion\":2,\"error\":\"stale_version\",\"hint\":\"Call project_describe, recompute ops against currentVersion, retry with a NEW commandId.\"}"}],"isError":true,"structuredContent":{"baseVersion":1,"currentVersion":2,"error":"stale_version","hint":"..."}}}

POST /mcp  {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"look_at","arguments":{}}}
data: {"id":7,...,"result":{"content":[{"type":"text","text":"Viewer frame rendered at 2026-09-08T18:07:33Z (5103 bytes PNG)"},{"type":"image","mimeType":"image/png","data":"iVBORw0KGgoAAAANSUhEUgAAAUAAAABQ..."}]}}

POST /mcp with Origin: http://evil.example  -> HTTP 403 (OriginValidator)
DELETE /mcp with Mcp-Session-Id             -> HTTP 200 (session closed)
```

Server log for the above (`server-http.log`):
```
[timeline-mcp] HTTP listening on http://127.0.0.1:8811/mcp
[timeline-mcp] session E5765CCB created
[timeline-mcp] tools/list
[timeline-mcp] tools/call project_describe args=[:]
[timeline-mcp] tools/call timeline_apply args=["ops": [["clipId": c1, "op": moveClip, "start": 120]], "commandId": cmd-A, "baseVersion": 1]
[timeline-mcp]   -> version 2 changed ["c1"]
[timeline-mcp] tools/call timeline_apply args=[... "commandId": cmd-A, "baseVersion": 1 ...]
[timeline-mcp]   -> version 2 changed ["c1"]                      <- served from idempotency cache
[timeline-mcp] tools/call timeline_apply args=[... "commandId": cmd-B, "baseVersion": 1 ...]
[timeline-mcp]   -> STALE base=1 current=2
[timeline-mcp] tools/call look_at args=[:]
[timeline-mcp] session E5765CCB closed
```

## 5. Claude Code: connected and invoked tools

Run from inside `spikes/mcp-server/` so scope is local to this directory:
```
$ claude mcp add --transport http --scope local timeline-spike http://127.0.0.1:8811/mcp
Added HTTP MCP server timeline-spike with URL: http://127.0.0.1:8811/mcp to local config
$ claude mcp list
timeline-spike: http://127.0.0.1:8811/mcp (HTTP) - ✔ Connected
```

Headless end-to-end (`claude -p` was run with `CLAUDECODE` / `CLAUDE_CODE_ENTRYPOINT` unset because this spike
itself ran inside a Claude Code session, which otherwise refuses to nest; raw output in `claude-p-output.json`):
```
$ claude -p "Use the timeline-spike MCP tools: describe the project, then move clip c1 to start 120, then describe again. Report the versions." \
    --allowedTools "mcp__timeline-spike__*" --output-format json --max-turns 6
is_error: False  turns: 5  duration_ms: 15207  cost_usd: 0.266
RESULT:
| Step | Version |
| First describe | 2 |
| After moveClip c1 -> 120 | 3 |
| Second describe | 3 |
(...it also noticed c1 was already at 120 from the curl run and that c1/c2 overlap on V1.)
```
Server log during that run - the tools really were invoked, with a sensible `baseVersion` and a
client-generated `commandId`:
```
[timeline-mcp] session 09EA4CC3 created          <- `claude mcp list` health check
[timeline-mcp] tools/list
[timeline-mcp] session 80FE6207 created          <- claude -p
[timeline-mcp] tools/list
[timeline-mcp] tools/call project_describe args=[:]
[timeline-mcp] tools/call timeline_apply args=["ops": [["op": moveClip, "clipId": c1, "start": 120]], "commandId": move-c1-to-120-20260908-01, "baseVersion": 2]
[timeline-mcp]   -> version 3 changed ["c1"]
[timeline-mcp] tools/call project_describe args=[:]
```
Cleanup: `claude mcp remove timeline-spike` -> "Removed MCP server "timeline-spike" from local config";
`claude mcp list` and `~/.claude.json` show zero remaining references. Server process stopped.

Note: Claude Code did not send DELETE at the end of `claude -p`; sessions in the SDK's Stateful transport
therefore need the idle-expiry sweep the conformance `HTTPApp` has (omitted here for brevity).

## 6. stdio fallback

`python3 stdio-client.py` (spawns `TimelineMCP --stdio`, newline-delimited JSON-RPC over pipes; output in
`stdio-transcript.txt`): initialize -> initialized -> tools/list (3 tools with annotations) -> project_describe
(structuredContent version 1) -> timeline_apply (version 2, changedIds ["a1"]) -> look_at (image/png, 6552 b64
chars, PNG magic OK). Server exits 0 when stdin closes. Zero code differences besides the transport line; server
logging goes to stderr so stdout stays clean.

## 7. Swift 6 (strict concurrency) issues hit

- None in the SDK's public API - everything is `Sendable`/actors; handler closures are `@Sendable`.
- NIO glue: `ChannelHandlerContext` is not `Sendable`; needed `@preconcurrency import NIO*`,
  `nonisolated(unsafe) let ctx = context`, `@unchecked Sendable` on the handler, and hopping back via
  `eventLoop.execute` for writes. A `var` `HTTPResponseHead` captured in the Task produced a
  `#SendableClosureCaptures` warning; made it a `let`. This is the same pattern the SDK's own conformance app uses.
- `Tool.Content.text(text:annotations:_meta:)` has no default args - verbose; a tiny helper is worth adding.
- `CallTool.Result(structuredContent: someValue)` is ambiguous between the `Value?` init and the throwing
  generic `Codable` init; write `.some(value)` or `try`.
- `NSAttributedString.Key.font` doesn't exist without AppKit/UIKit; use `kCTFontAttributeName as NSAttributedString.Key`.
- `.macOS(.v26)` requires swift-tools-version 6.2 (fine with Swift 6.3.3).

## 8. Build time and size

- Cold `swift build -c release` (SDK + swift-nio + deps, M4 Max): **37 s** wall. Incremental after editing our
  target: **2.3-2.6 s**.
- Binary: 12.1 MB unstripped, **5.1 MB stripped** (statically links NIO, swift-log, swift-system, EventSource).

## 9. Verdict and recommendation

**Assumption holds.** Swift SDK 0.12.1 hosts a spec-compliant Streamable HTTP server (sessions, SSE, resumable
event IDs, Origin/Host validation) that Claude Code connects to and drives via `tools/list`/`tools/call`;
annotations, `structuredContent`, `outputSchema`, and image blocks are all supported and were observed on the
wire; stdio works with the same server object.

Recommendations for the real editor:
1. **Ship both transports.** Stdio is trivial and is what most users will register (`claude mcp add ... -- /path/to/app --mcp-stdio`
   or a tiny launcher that connects to the running app). Streamable HTTP on 127.0.0.1 is the right fit for an
   *already-running* GUI app (Claude Code attaches to the live document; no second process owning the project).
   Both exercised the same handlers here.
2. **Own the HTTP listener.** Use raw swift-nio like the SDK's conformance app (~100 lines, no new deps) or
   Hummingbird if we want routing/middleware later. Add: idle-session expiry sweep, a random ephemeral port
   written to a well-known file (or fixed per-project), and keep the default validation pipeline (Origin/Host).
3. **Keep the SDK version pinned (`exact:`).** 0.x, still moving (0.9 -> 0.12 added the HTTP server transports and
   NIO dependency); API is clean but not stable.
4. Keep editor state in an actor independent of `Server` (one `Server` per HTTP session) and keep the
   `baseVersion`/`commandId` contract - Claude Code used both correctly unprompted.
5. Minor: write a `Tool.Content` text helper, and consider generating input schemas from `Codable` types with
   a small reflection/macro helper rather than hand-written `Value` literals.
