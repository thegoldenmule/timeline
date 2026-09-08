import Foundation
import MCP

// Usage: TimelineMCP --stdio | TimelineMCP --http <port>
let project = FakeProject()   // shared across sessions: one editor, one document

@Sendable func makeServer() async -> Server {
    let server = Server(name: "timeline-spike", version: "0.0.1",
                        instructions: "Fake video editor project. Use project_describe before timeline_apply.",
                        capabilities: .init(tools: .init(listChanged: false)))
    await server.withMethodHandler(ListTools.self) { _ in log("tools/list"); return .init(tools: toolList) }
    await server.withMethodHandler(CallTool.self) { params in try await handleCall(params, project: project) }
    return server
}

let args = CommandLine.arguments.dropFirst()
if args.first == "--http", let port = args.dropFirst().first.flatMap({ Int($0) }) {
    try await HTTPHost(port: port, factory: makeServer).run()
} else if args.first == "--stdio" {
    let server = await makeServer()
    try await server.start(transport: StdioTransport())
    log("stdio server started")
    await server.waitUntilCompleted()
} else {
    log("usage: TimelineMCP --stdio | --http <port>"); exit(2)
}
