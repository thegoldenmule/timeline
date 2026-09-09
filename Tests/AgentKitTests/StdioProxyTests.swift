import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import AgentKit

/// The stdio proxy's forwarding logic as a library function against the live host, the way
/// `timeline-mcp` drives it: lines in, JSON-RPC messages out, session tracked, DELETE on EOF.
@Suite(.serialized) struct StdioProxyTests {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
        var json: [JSONValue] { all.compactMap { try? ProjectCodec.decode(JSONValue.self, from: Data($0.utf8)) } }
    }

    @Test func forwardsAWholeSessionToTheRunningHost() async throws {
        let services = try await TestServices.make()
        let context = services.toolContext(actor: .human, sessionId: nil)
        let host = MCPServerHost(registry: await EditorTools.standard(context: context), context: context)
        let info = try await host.start()
        defer { Task { await host.stop() } }

        let endpoint = ProxyEndpoint(url: info.url, token: info.token)
        let (input, continuation) = AsyncStream<String>.makeStream()
        let out = Collector()
        let run = Task { await StdioProxy.run(input: input, output: { out.append($0) }, endpoint: endpoint) }
        continuation.yield(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"proxy-test","version":"0"}}}"#
        )
        continuation.yield("")
        continuation.yield(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        continuation.yield(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        continuation.yield(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"project_list","arguments":{}}}"#)
        continuation.yield(
            #"{"jsonrpc":"2.0","id":"str-4","method":"tools/call","params":{"name":"nope","arguments":{}}}"#)
        continuation.finish()
        let summary = await run.value
        #expect(summary.forwarded == 5 && summary.errors == 0 && summary.sessionId != nil)
        let messages = out.json
        #expect(messages.count == 4, "\(out.all)")
        #expect(messages[0]["id"]?.intValue == 1 && messages[0]["result"]?["serverInfo"]?["name"] == "timeline")
        #expect(
            messages[1]["id"]?.intValue == 2
                && messages[1]["result"]?["tools"]?.arrayValue?.count == EditorTools.names.count)
        #expect(
            messages[2]["id"]?.intValue == 3 && messages[2]["result"]?["structuredContent"]?["count"]?.intValue == 1)
        #expect(
            messages[3]["id"] == "str-4"
                && messages[3]["error"]?["message"]?.stringValue?.contains("Unknown tool") == true)
        #expect(out.all.allSatisfy { !$0.contains("\n") })
        // EOF sent DELETE: the session is gone.
        #expect(await host.sessionCount == 0)
        #expect(await host.calls.map(\.tool) == ["project_list"])
    }

    @Test func answersErrorsInsteadOfHanging() async throws {
        let services = try await TestServices.make()
        let context = services.toolContext(actor: .human, sessionId: nil)
        let host = MCPServerHost(registry: await EditorTools.standard(context: context), context: context)
        let info = try await host.start()
        defer { Task { await host.stop() } }

        // Wrong token: HTTP 401 becomes a JSON-RPC error for requests with an id, nothing for notifications.
        let wrong = ProxyEndpoint(url: info.url, token: "nope")
        let (input, continuation) = AsyncStream<String>.makeStream()
        let out = Collector()
        continuation.yield(#"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}"#)
        continuation.yield(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        continuation.finish()
        let summary = await StdioProxy.run(input: input, output: { out.append($0) }, endpoint: wrong)
        #expect(summary.forwarded == 2 && summary.errors == 2 && summary.sessionId == nil)
        #expect(
            out.json.count == 1 && out.json[0]["id"]?.intValue == 7
                && out.json[0]["error"]?["message"]?.stringValue?.contains("HTTP 401") == true)

        // Nothing listening: a connection error, same shape.
        await host.stop()
        let (input2, continuation2) = AsyncStream<String>.makeStream()
        let out2 = Collector()
        continuation2.yield(#"{"jsonrpc":"2.0","id":8,"method":"initialize","params":{}}"#)
        continuation2.finish()
        let dead = await StdioProxy.run(
            input: input2, output: { out2.append($0) }, endpoint: ProxyEndpoint(url: info.url, token: info.token))
        #expect(
            dead.errors == 1 && out2.json.first?["error"]?["message"]?.stringValue?.contains("not reachable") == true)
    }

    @Test func endpointResolvesFromEnvironmentOrConfigFile() throws {
        let fromEnv = try ProxyEndpoint.resolve(
            environment: ["TIMELINE_MCP_URL": "http://127.0.0.1:1/mcp", "TIMELINE_MCP_TOKEN": "t"],
            configurationFile: URL(fileURLWithPath: "/nonexistent/mcp.json"))
        #expect(fromEnv == ProxyEndpoint(url: URL(string: "http://127.0.0.1:1/mcp")!, token: "t"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentkit-proxy-\(UUID().uuidString)/mcp.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let info = MCPConnectionInfo(
            serverName: "timeline", url: URL(string: "http://127.0.0.1:2/mcp")!, token: "tok",
            approvalURL: URL(string: "http://127.0.0.1:2/approval")!)
        try info.writeProxyConfiguration(to: file)
        let fromFile = try ProxyEndpoint.resolve(environment: [:], configurationFile: file)
        #expect(fromFile == ProxyEndpoint(url: info.url, token: "tok"))
        #expect(throws: ProxyEndpoint.ResolutionError.self) {
            try ProxyEndpoint.resolve(
                environment: [:], configurationFile: URL(fileURLWithPath: "/nonexistent/mcp.json"))
        }
        try Data("{}".utf8).write(to: file)
        #expect(throws: ProxyEndpoint.ResolutionError.self) {
            try ProxyEndpoint.resolve(environment: [:], configurationFile: file)
        }
    }

    @Test func parsesSSEBodies() {
        let body = "id: 1_1\ndata: \n\nid: 1_2\nevent: message\ndata: {\"a\":1}\n\ndata: {\"b\":\r\ndata: 2}\n\n"
        #expect(StdioProxy.sseMessages(in: body) == ["{\"a\":1}", "{\"b\":\n2}"])
    }
}
