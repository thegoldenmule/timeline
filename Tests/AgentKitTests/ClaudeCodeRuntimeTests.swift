import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import AgentKit

/// The sidecar runtime without spending tokens: the command line it builds, the hook it writes, and a
/// fake `claude` shell script that replays recorded turns (with `--resume` for the second one).
@Suite struct ClaudeCodeRuntimeTests {
    static let access = ToolAccess(
        serverName: "timeline", endpoint: URL(string: "http://127.0.0.1:4321/mcp")!, bearerToken: "secret-token")

    @Test func buildsTheDocumentedCommandLine() throws {
        let hook = URL(fileURLWithPath: "/tmp/wd/.timeline/pretooluse-hook.sh")
        let policy = RuntimePolicy(
            model: "claude-sonnet-4-5", maxBudgetUSD: 0.5, maxTurns: 6, systemPromptAppend: "Be brief.")
        let args = ClaudeCodeRuntime.arguments(
            goal: "do it", tools: Self.access, policy: policy, sessionId: "sid", hookScript: hook,
            hookTimeoutSeconds: 600,
            resume: false)
        #expect(args.prefix(5) == ["-p", "do it", "--output-format", "stream-json", "--verbose"])
        #expect(args.contains("--session-id") && args[args.firstIndex(of: "--session-id")! + 1] == "sid")
        #expect(args.contains("--strict-mcp-config"))
        let mcp = args[args.firstIndex(of: "--mcp-config")! + 1]
        let mcpJSON = try JSONSerialization.jsonObject(with: Data(mcp.utf8)) as? [String: Any]
        let server = (mcpJSON?["mcpServers"] as? [String: Any])?["timeline"] as? [String: Any]
        #expect(server?["type"] as? String == "http" && server?["url"] as? String == "http://127.0.0.1:4321/mcp")
        #expect((server?["headers"] as? [String: String])?["Authorization"] == "Bearer secret-token")
        #expect(args[args.firstIndex(of: "--permission-mode")! + 1] == "dontAsk")
        #expect(args[args.firstIndex(of: "--allowedTools")! + 1] == "mcp__timeline__*")
        #expect(args[args.firstIndex(of: "--max-budget-usd")! + 1] == "0.5")
        #expect(args[args.firstIndex(of: "--max-turns")! + 1] == "6")
        #expect(args[args.firstIndex(of: "--model")! + 1] == "claude-sonnet-4-5")
        #expect(args[args.firstIndex(of: "--append-system-prompt")! + 1] == "Be brief.")
        let settings = args[args.firstIndex(of: "--settings")! + 1]
        let settingsJSON = try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any]
        let pre = ((settingsJSON?["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first
        #expect(pre?["matcher"] as? String == "mcp__timeline__.*")
        let command = (pre?["hooks"] as? [[String: Any]])?.first
        #expect(command?["type"] as? String == "command" && command?["command"] as? String == hook.path)
        #expect(command?["timeout"] as? Int == 600)

        let resumed = ClaudeCodeRuntime.arguments(
            goal: "more", tools: Self.access, policy: RuntimePolicy(), sessionId: "sid", hookScript: hook,
            hookTimeoutSeconds: 1, resume: true)
        #expect(resumed.contains("--resume") && !resumed.contains("--session-id") && !resumed.contains("--model"))

        var scoped = Self.access
        scoped.toolNames = ["project_list", "undo"]
        #expect(ClaudeCodeRuntime.allowedTools(scoped) == ["mcp__timeline__project_list", "mcp__timeline__undo"])
    }

    @Test func childEnvironmentDropsClaudeCodeAndCarriesTheHookTarget() {
        let env = ClaudeCodeRuntime.environment(
            base: ["CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "PATH": "/bin", "HOME": "/h"], extra: ["X": "y"],
            tools: Self.access)
        #expect(env["CLAUDECODE"] == nil && env["CLAUDE_CODE_ENTRYPOINT"] == nil)
        #expect(env["PATH"] == "/bin" && env["X"] == "y")
        #expect(env["TIMELINE_MCP_TOKEN"] == "secret-token")
        #expect(env["TIMELINE_APPROVAL_URL"] == "http://127.0.0.1:4321/approval")
        #expect(
            ClaudeCodeRuntime.approvalURL(for: URL(string: "http://127.0.0.1:9/mcp?x=1")!).absoluteString
                == "http://127.0.0.1:9/approval")
    }

    @Test func writesAnExecutableHookScriptWithoutSecrets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ClaudeCodeRuntime.writeHookScript(into: dir, timeoutSeconds: 42)
        #expect(url.path.hasSuffix("/.timeline/pretooluse-hook.sh"))
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        let script = try String(contentsOf: url, encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(
            script.contains("--max-time 42") && script.contains("$TIMELINE_APPROVAL_URL")
                && script.contains("$TIMELINE_MCP_TOKEN"))
        #expect(!script.contains("secret"))
    }

    // MARK: Fake claude

    /// A stand-in `claude`: answers `--version` and `auth status`, records its arguments and environment,
    /// and replays `turn1` (or `turn2` after `--resume`). `FAKE_CLAUDE_SLEEP=1` makes it hang for `cancel`.
    struct FakeClaude {
        var directory: URL
        var executable: URL

        static func make() throws -> FakeClaude {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "fake-claude-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let turn1 = try Transcripts.url("fake-turn1.stream.jsonl").path
            let turn2 = try Transcripts.url("fake-turn2.stream.jsonl").path
            let script = """
                #!/bin/sh
                case "$1" in
                  --version) echo "0.0.0-fake (Claude Code)"; exit 0;;
                  auth) echo '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}'; exit 0;;
                esac
                n=$(ls "\(dir.path)" | grep -c '^args-')
                printf '%s\\n' "$@" > "\(dir.path)/args-$n"
                env | sort > "\(dir.path)/env-$n"
                pwd > "\(dir.path)/cwd-$n"
                if [ -n "$FAKE_CLAUDE_SLEEP" ]; then sleep 30; exit 0; fi
                if [ -n "$FAKE_CLAUDE_CRASH" ]; then echo "boom" >&2; exit 3; fi
                for a in "$@"; do if [ "$a" = "--resume" ]; then cat "\(turn2)"; exit 0; fi; done
                cat "\(turn1)"

                """
            let exe = dir.appendingPathComponent("claude")
            try Data(script.utf8).write(to: exe)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            return FakeClaude(directory: dir, executable: exe)
        }

        func file(_ name: String) throws -> String {
            try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    func runtime(
        _ fake: FakeClaude, approvals: (any ApprovalGate)? = nil, multiTurn: Bool = true, extra: [String: String] = [:]
    )
        -> ClaudeCodeRuntime
    {
        ClaudeCodeRuntime(
            configuration: .init(
                executable: fake.executable, workingDirectoryRoot: fake.directory.appendingPathComponent("work"),
                hookTimeoutSeconds: 7, environment: extra, approvals: approvals, multiTurn: multiTurn))
    }

    @Test func availabilityReadsVersionAndAuthStatus() async throws {
        let fake = try FakeClaude.make()
        defer { fake.cleanup() }
        let availability = await runtime(fake).availability()
        #expect(
            availability
                == RuntimeAvailability(installed: true, version: "0.0.0-fake", loggedIn: true, detail: "claude.ai max"))
        let missing = ClaudeCodeRuntime(configuration: .init(executable: fake.directory.appendingPathComponent("nope")))
        let none = await missing.availability()
        #expect(!none.installed && !none.isUsable)
        let unfound = ClaudeCodeRuntime(configuration: .init(environment: [:]))
        _ = unfound.locateExecutable()  // whatever this machine has; must not crash
    }

    @Test func sessionReplaysATurnResumesAndCancels() async throws {
        let fake = try FakeClaude.make()
        defer { fake.cleanup() }
        let gate = FakeApprovalGate()
        let runtime = runtime(fake, approvals: gate, extra: ["CLAUDECODE": "1"])
        let policy = RuntimePolicy(model: "fake-model", maxBudgetUSD: 0.25, maxTurns: 4, systemPromptAppend: "Short.")
        let session = try await runtime.startSession(goal: "export the reel", tools: Self.access, policy: policy)
        var iterator = session.events.makeAsyncIterator()
        var first: [AgentEvent] = []
        while let event = await iterator.next() {
            first.append(event)
            if event.isTerminal { break }
        }
        #expect(first.contains(.toolCall(id: "toolu_export", name: "render_export", input: ["preset": "reel9x16"])))
        let approval = first.compactMap { event -> ApprovalRequest? in
            if case .approvalRequested(let r) = event { return r }
            return nil
        }.first
        #expect(approval?.token == "tok-fake-1")
        #expect(
            first.last
                == .finished(
                    result: "Waiting for your approval to export.",
                    cost: CostReport(usd: 0.0123, inputTokens: 100, outputTokens: 50, durationSeconds: 1.234, turns: 3))
        )
        let claude = try #require(session as? ClaudeCodeSession)
        #expect(claude.lastCost?.usd == 0.0123)
        #expect(claude.claudeSessionId == "fake-session")
        #expect(claude.transcript.count == 11)

        // The launch: cwd is the app-owned directory with the skills, CLAUDECODE is gone, hook env is set.
        let args = try fake.file("args-0").split(separator: "\n").map(String.init)
        #expect(args.prefix(2) == ["-p", "export the reel"])
        #expect(args.contains("--session-id") && args.contains(session.id) && args.contains("--strict-mcp-config"))
        #expect(
            args.contains("--max-budget-usd") && args.contains("0.25") && args.contains("--model")
                && args.contains("fake-model"))
        let env = try fake.file("env-0")
        #expect(!env.contains("\nCLAUDECODE=") && !env.hasPrefix("CLAUDECODE="))
        #expect(
            env.contains("TIMELINE_MCP_TOKEN=secret-token")
                && env.contains("TIMELINE_APPROVAL_URL=http://127.0.0.1:4321/approval"))
        let cwd = try fake.file("cwd-0").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.contains("session-\(session.id)"))
        let skills = SkillsInstaller.skillsDirectory(in: URL(fileURLWithPath: cwd))
        #expect(FileManager.default.fileExists(atPath: skills.appendingPathComponent("tiktok-captions/SKILL.md").path))
        #expect(
            FileManager.default.isExecutableFile(
                atPath: URL(fileURLWithPath: cwd).appendingPathComponent(".timeline/pretooluse-hook.sh").path))

        // approve() answers through the gate.
        guard
            case .required(let pending) = await gate.check(
                tool: "render_export", input: ToolInput(), estimate: .none, actor: .human, sessionId: nil)
        else {
            Issue.record("expected a request")
            return
        }
        await session.approve(pending, verdict: .approve)
        #expect(await gate.consume(pending.token))
        // The gate's requests were also forwarded as events (the stream stays open between turns).
        let forwarded = await iterator.next()
        #expect(forwarded == .approvalRequested(pending))

        // send() relaunches with --resume and the same session id.
        try await session.send("go on")
        var second: [AgentEvent] = []
        while let event = await iterator.next() {
            second.append(event)
            if event.isTerminal { break }
        }
        #expect(second.contains(.assistantText("Resumed; the export finished.")))
        #expect(second.last == .failed(AgentFailure(code: "error_max_turns", message: "Reached max turns")))
        let resumeArgs = try fake.file("args-1").split(separator: "\n").map(String.init)
        #expect(resumeArgs.prefix(2) == ["-p", "go on"])
        #expect(
            resumeArgs.contains("--resume") && resumeArgs.contains(session.id) && !resumeArgs.contains("--session-id"))

        await session.cancel()
        var rest: [AgentEvent] = []
        while let event = await iterator.next() { rest.append(event) }
        #expect(rest.last == .failed(.cancelled))
        await #expect(throws: AgentFailure.self) { try await session.send("after cancel") }
    }

    @Test func cancelTerminatesARunningProcessAndCrashesAreReported() async throws {
        let fake = try FakeClaude.make()
        defer { fake.cleanup() }
        let hanging = try await runtime(fake, extra: ["FAKE_CLAUDE_SLEEP": "1"]).startSession(
            goal: "hang", tools: Self.access, policy: RuntimePolicy())
        try await Task.sleep(for: .milliseconds(300))
        let claude = try #require(hanging as? ClaudeCodeSession)
        #expect(claude.isRunning)
        await hanging.cancel()
        var events: [AgentEvent] = []
        for await event in hanging.events { events.append(event) }
        #expect(events == [.failed(.cancelled)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(!claude.isRunning)

        let crashing = try await runtime(fake, multiTurn: false, extra: ["FAKE_CLAUDE_CRASH": "1"]).startSession(
            goal: "crash", tools: Self.access, policy: RuntimePolicy())
        var crashed: [AgentEvent] = []
        for await event in crashing.events { crashed.append(event) }
        #expect(crashed == [.failed(AgentFailure(code: "exit-3", message: "boom"))])
        #expect((crashing as? ClaudeCodeSession)?.standardError.contains("boom") == true)
    }

    @Test func messagesAPIRuntimeCompilesAgainstTheProtocol() async throws {
        let runtime: any AgentRuntime = MessagesAPIRuntime(configuration: .init(apiKey: "sk-test"))
        let availability = await runtime.availability()
        #expect(!availability.installed && !availability.isUsable && availability.loggedIn)
        await #expect(throws: AgentFailure.unavailable) {
            try await runtime.startSession(goal: "x", tools: Self.access, policy: RuntimePolicy())
        }
        let runtimes: [any AgentRuntime] = [ClaudeCodeRuntime(), MessagesAPIRuntime()]
        #expect(runtimes.count == 2)
    }
}
