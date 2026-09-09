// timeline-mcp: a stdio MCP proxy that forwards JSON-RPC to the running Timeline app's Streamable
// HTTP endpoint, so `claude mcp add timeline -- timeline-mcp` works. It never opens the database.
// Endpoint from TIMELINE_MCP_URL / TIMELINE_MCP_TOKEN or ~/Library/Application Support/Timeline/mcp.json.
import AgentKit
import Foundation

func log(_ line: String) { FileHandle.standardError.write(Data("[timeline-mcp] \(line)\n".utf8)) }

let endpoint: ProxyEndpoint
do {
    endpoint = try ProxyEndpoint.resolve()
} catch {
    log(String(describing: error))
    exit(2)
}

let (input, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
let reader = Task.detached {
    do {
        for try await line in FileHandle.standardInput.bytes.lines { continuation.yield(line) }
    } catch {
        log("stdin closed: \(error)")
    }
    continuation.finish()
}

let summary = await StdioProxy.run(
    input: input,
    output: { message in
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    },
    endpoint: endpoint, log: log)
reader.cancel()
log("forwarded \(summary.forwarded) message(s), \(summary.errors) error(s)")
exit(summary.errors == summary.forwarded && summary.forwarded > 0 ? 1 : 0)
