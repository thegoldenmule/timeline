import Contracts
import Foundation
import Synchronization
import TimelineCore

/// The Claude Code CLI as a sidecar `AgentRuntime`: `claude -p <goal> --output-format stream-json
/// --verbose --strict-mcp-config --mcp-config <inline JSON with the bearer header> --permission-mode
/// dontAsk --allowedTools mcp__<server>__* --max-budget-usd --model --append-system-prompt --settings
/// <inline JSON with a PreToolUse hook>`, cwd set to an app-owned directory holding the Skills folder,
/// `CLAUDECODE` unset in the child environment. `send` continues the conversation with `--resume`.
///
/// The `PreToolUse` hook is a tiny shell script the runtime writes into the working directory; it
/// POSTs the hook payload to the host's `/approval` endpoint and returns `permissionDecision`. It is
/// UX on top of the server-side gate inside the tools, never the gate itself.
public struct ClaudeCodeRuntime: AgentRuntime, Sendable {
    public struct Configuration: Sendable {
        /// The `claude` binary; nil searches `PATH`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`.
        public var executable: URL?
        /// Root of the per-session working directories when the policy names none.
        public var workingDirectoryRoot: URL
        /// Where the Skills folder is materialised (`.claude/skills` under the working directory).
        public var installsSkills: Bool
        /// Seconds the hook may block on an approval before Claude Code gives up on it.
        public var hookTimeoutSeconds: Int
        /// Extra environment for the child; `CLAUDECODE` and `CLAUDE_CODE_ENTRYPOINT` are always removed.
        public var environment: [String: String]
        /// The gate whose requests become `.approvalRequested` events and whose `grant`/`deny` answer `approve`.
        public var approvals: (any ApprovalGate)?
        /// Keep the event stream open after `finished` so `send` can continue the conversation.
        public var multiTurn: Bool
        public var log: (@Sendable (String) -> Void)?

        public init(
            executable: URL? = nil,
            workingDirectoryRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TimelineAgent", isDirectory: true),
            installsSkills: Bool = true, hookTimeoutSeconds: Int = 600, environment: [String: String] = [:],
            approvals: (any ApprovalGate)? = nil, multiTurn: Bool = true, log: (@Sendable (String) -> Void)? = nil
        ) {
            self.executable = executable
            self.workingDirectoryRoot = workingDirectoryRoot
            self.installsSkills = installsSkills
            self.hookTimeoutSeconds = hookTimeoutSeconds
            self.environment = environment
            self.approvals = approvals
            self.multiTurn = multiTurn
            self.log = log
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    // MARK: Availability

    /// `claude --version` and `claude auth status` (JSON with `loggedIn`), with `CLAUDECODE` unset so a
    /// nested launch is never refused.
    public func availability() async -> RuntimeAvailability {
        guard let executable = locateExecutable() else {
            return RuntimeAvailability(installed: false, loggedIn: false, detail: "claude not found on PATH")
        }
        let env = ClaudeCodeRuntime.environment(
            base: ProcessInfo.processInfo.environment, extra: configuration.environment)
        do {
            let version = try await ProcessRunner.run(
                executable, ["--version"], environment: env, timeout: .seconds(20))
            guard version.status == 0 else {
                return RuntimeAvailability(
                    installed: false, loggedIn: false, detail: "claude --version failed: \(version.stderr)")
            }
            let versionString = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ").first.map(String.init)
            let auth = try await ProcessRunner.run(
                executable, ["auth", "status"], environment: env, timeout: .seconds(20))
            let json = try? JSONDecoder().decode(JSONValue.self, from: Data(auth.stdout.utf8))
            let loggedIn = json?["loggedIn"]?.boolValue ?? false
            let detail =
                loggedIn
                ? "\(json?["authMethod"]?.stringValue ?? "auth") \(json?["subscriptionType"]?.stringValue ?? "")"
                    .trimmingCharacters(in: .whitespaces)
                : (auth.stderr.isEmpty ? "not logged in" : auth.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            return RuntimeAvailability(installed: true, version: versionString, loggedIn: loggedIn, detail: detail)
        } catch {
            return RuntimeAvailability(installed: true, loggedIn: false, detail: String(describing: error))
        }
    }

    public func locateExecutable() -> URL? {
        if let executable = configuration.executable {
            return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        candidates += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for dir in candidates {
            let path = "\(dir)/claude"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    // MARK: Sessions

    public func startSession(goal: String, tools: ToolAccess, policy: RuntimePolicy) async throws -> any AgentSession {
        guard let executable = locateExecutable() else {
            throw AgentFailure(code: "unavailable", message: "claude not found; install Claude Code or use MCP only")
        }
        let sessionId = policy.resumeSessionId ?? UUID().uuidString.lowercased()
        let workingDirectory =
            policy.workingDirectory
            ?? configuration.workingDirectoryRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        if configuration.installsSkills { _ = try? SkillsInstaller.install(into: workingDirectory) }
        let hook = try ClaudeCodeRuntime.writeHookScript(
            into: workingDirectory, timeoutSeconds: configuration.hookTimeoutSeconds)
        let launch = Launch(
            executable: executable, workingDirectory: workingDirectory, hookScript: hook, tools: tools, policy: policy,
            sessionId: sessionId,
            environment: ClaudeCodeRuntime.environment(
                base: ProcessInfo.processInfo.environment, extra: configuration.environment, tools: tools),
            hookTimeoutSeconds: configuration.hookTimeoutSeconds)
        let session = ClaudeCodeSession(
            id: sessionId, launch: launch, approvals: configuration.approvals, multiTurn: configuration.multiTurn,
            log: configuration.log)
        session.start(goal: goal, resume: policy.resumeSessionId != nil)
        return session
    }

    /// Everything one `claude` launch needs, so `send` can relaunch with `--resume`.
    struct Launch: Sendable {
        var executable: URL
        var workingDirectory: URL
        var hookScript: URL
        var tools: ToolAccess
        var policy: RuntimePolicy
        var sessionId: String
        var environment: [String: String]
        var hookTimeoutSeconds: Int
    }

    // MARK: Command line

    /// The full argument list. `resume` continues the session instead of starting it.
    public static func arguments(
        goal: String, tools: ToolAccess, policy: RuntimePolicy, sessionId: String, hookScript: URL,
        hookTimeoutSeconds: Int,
        resume: Bool
    ) -> [String] {
        var args = ["-p", goal, "--output-format", "stream-json", "--verbose"]
        if resume {
            args += ["--resume", sessionId]
        } else {
            args += ["--session-id", sessionId]
        }
        args += ["--strict-mcp-config", "--mcp-config", mcpConfig(tools: tools)]
        args += ["--permission-mode", "dontAsk", "--allowedTools"] + allowedTools(tools)
        if let budget = policy.maxBudgetUSD { args += ["--max-budget-usd", String(budget)] }
        if let turns = policy.maxTurns { args += ["--max-turns", String(turns)] }
        if let model = policy.model { args += ["--model", model] }
        if let prompt = policy.systemPromptAppend { args += ["--append-system-prompt", prompt] }
        args += [
            "--settings",
            settings(hookScript: hookScript, serverName: tools.serverName, timeoutSeconds: hookTimeoutSeconds),
        ]
        return args
    }

    /// `mcp__<server>__*`, or one entry per allowed tool.
    public static func allowedTools(_ tools: ToolAccess) -> [String] {
        guard let names = tools.toolNames, !names.isEmpty else { return ["mcp__\(tools.serverName)__*"] }
        return names.map { "mcp__\(tools.serverName)__\($0)" }
    }

    /// The inline `--mcp-config`: one HTTP server with the bearer header.
    public static func mcpConfig(tools: ToolAccess) -> String {
        let config: [String: Any] = [
            "mcpServers": [
                tools.serverName: [
                    "type": "http", "url": tools.endpoint.absoluteString,
                    "headers": ["Authorization": "Bearer \(tools.bearerToken)"],
                ]
            ]
        ]
        return jsonString(config)
    }

    /// The inline `--settings`: a `PreToolUse` hook on this server's tools.
    public static func settings(hookScript: URL, serverName: String, timeoutSeconds: Int) -> String {
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "mcp__\(serverName)__.*",
                        "hooks": [["type": "command", "command": hookScript.path, "timeout": timeoutSeconds]],
                    ]
                ]
            ]
        ]
        return jsonString(settings)
    }

    /// The child's environment: the parent's plus `extra`, minus `CLAUDECODE` and `CLAUDE_CODE_ENTRYPOINT`
    /// (Claude Code refuses to nest), plus the approval endpoint and token for the hook.
    public static func environment(base: [String: String], extra: [String: String] = [:], tools: ToolAccess? = nil)
        -> [String: String]
    {
        var env = base.merging(extra) { _, new in new }
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        if let tools {
            env["TIMELINE_MCP_TOKEN"] = tools.bearerToken
            env["TIMELINE_MCP_URL"] = tools.endpoint.absoluteString
            env["TIMELINE_APPROVAL_URL"] = approvalURL(for: tools.endpoint).absoluteString
        }
        return env
    }

    /// `/approval` next to the MCP path on the same host and port.
    public static func approvalURL(for endpoint: URL) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.path = "/approval"
        components.query = nil
        return components.url!
    }

    /// The hook script: the token and URL come from the environment, so the file holds no secret.
    public static func hookScript(timeoutSeconds: Int) -> String {
        """
        #!/bin/sh
        # Written by Timeline (AgentKit). PreToolUse hook: forwards the tool call to the app's approval
        # endpoint and prints its {"hookSpecificOutput": {"permissionDecision": ...}} answer. UX only:
        # the server-side approval gate inside the tools stays authoritative.
        if [ -z "$TIMELINE_APPROVAL_URL" ] || [ -z "$TIMELINE_MCP_TOKEN" ]; then exit 0; fi
        exec /usr/bin/curl -sS --max-time \(timeoutSeconds) -X POST \\
          -H 'Content-Type: application/json' \\
          -H "Authorization: Bearer $TIMELINE_MCP_TOKEN" \\
          --data-binary @- "$TIMELINE_APPROVAL_URL"

        """
    }

    @discardableResult
    public static func writeHookScript(into workingDirectory: URL, timeoutSeconds: Int) throws -> URL {
        let dir = workingDirectory.appendingPathComponent(".timeline", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pretooluse-hook.sh")
        try Data(hookScript(timeoutSeconds: timeoutSeconds).utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func jsonString(_ object: [String: Any]) -> String {
        let data =
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// One conversation with the sidecar. The process for the current turn streams `stream-json` lines
/// into `events`; `send` waits for it to exit and relaunches with `--resume`; `cancel` terminates it.
public final class ClaudeCodeSession: AgentSession, Sendable {
    public let id: String
    public let events: AsyncStream<AgentEvent>

    private struct State {
        var process: Process?
        var turn: Task<Void, Never>?
        var cancelled = false
        var finished = false
        var lastCost: CostReport?
        var claudeSessionId: String?
        var stderr = ""
        var stdoutLines: [String] = []
    }

    private let state: Mutex<State>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let launch: ClaudeCodeRuntime.Launch
    private let approvals: (any ApprovalGate)?
    private let multiTurn: Bool
    private let log: (@Sendable (String) -> Void)?
    private let forwarding = Mutex<Task<Void, Never>?>(nil)

    init(
        id: String, launch: ClaudeCodeRuntime.Launch, approvals: (any ApprovalGate)?, multiTurn: Bool,
        log: (@Sendable (String) -> Void)?
    ) {
        self.id = id
        self.launch = launch
        self.approvals = approvals
        self.multiTurn = multiTurn
        self.log = log
        state = Mutex(State())
        (events, continuation) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        if let approvals {
            let requests = approvals.requests
            forwarding.withLock {
                $0 = Task { [continuation] in
                    for await request in requests { continuation.yield(.approvalRequested(request)) }
                }
            }
        }
    }

    /// The Claude Code session id reported by the `init` line (equals `id` when `--session-id` was honoured).
    public var claudeSessionId: String? { state.withLock { $0.claudeSessionId } }
    public var lastCost: CostReport? { state.withLock { $0.lastCost } }
    /// The raw stream-json lines of every turn so far (for diagnostics and recording fixtures).
    public var transcript: [String] { state.withLock { $0.stdoutLines } }
    public var standardError: String { state.withLock { $0.stderr } }
    public var isRunning: Bool { state.withLock { $0.process?.isRunning ?? false } }

    func start(goal: String, resume: Bool) {
        let task = Task { await self.runTurn(prompt: goal, resume: resume) }
        state.withLock { $0.turn = task }
    }

    private func runTurn(prompt: String, resume: Bool) async {
        let arguments = ClaudeCodeRuntime.arguments(
            goal: prompt, tools: launch.tools, policy: launch.policy, sessionId: id, hookScript: launch.hookScript,
            hookTimeoutSeconds: launch.hookTimeoutSeconds, resume: resume)
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = arguments
        process.environment = launch.environment
        process.currentDirectoryURL = launch.workingDirectory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let shouldRun = state.withLock { s -> Bool in
            guard !s.cancelled else { return false }
            s.process = process
            return true
        }
        guard shouldRun else { return }
        log?("claude \(arguments.map { $0.count > 80 ? String($0.prefix(77)) + "..." : $0 }.joined(separator: " "))")
        do {
            try process.run()
        } catch {
            continuation.yield(.failed(AgentFailure(code: "spawn", message: String(describing: error))))
            finishIfSingleTurn()
            return
        }
        let errTask = Task.detached { [stderr] in
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        var parser = StreamJSONParser(serverName: launch.tools.serverName)
        var sawTerminal = false
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                state.withLock { $0.stdoutLines.append(line) }
                for event in parser.parse(line: line) {
                    if event.isTerminal { sawTerminal = true }
                    if case .finished(_, let cost) = event { state.withLock { $0.lastCost = cost } }
                    continuation.yield(event)
                }
                if let sid = parser.claudeSessionId { state.withLock { $0.claudeSessionId = sid } }
            }
        } catch {
            log?("stdout read failed: \(error)")
        }
        process.waitUntilExit()
        let errText = await errTask.value
        state.withLock { $0.stderr += errText }
        let cancelled = state.withLock { $0.cancelled }
        if !sawTerminal, !cancelled {
            let tail = errText.split(separator: "\n").suffix(5).joined(separator: "\n")
            continuation.yield(
                .failed(
                    AgentFailure(
                        code: "exit-\(process.terminationStatus)",
                        message: tail.isEmpty ? "claude exited with status \(process.terminationStatus)" : tail)))
        }
        finishIfSingleTurn()
    }

    private func finishIfSingleTurn() {
        if !multiTurn { end() }
    }

    /// Ends the event stream (after the current turn) without terminating anything.
    public func end() {
        state.withLock { $0.finished = true }
        forwarding.withLock { $0?.cancel() }
        continuation.finish()
    }

    public func approve(_ request: ApprovalRequest, verdict: ApprovalVerdict) async {
        guard let approvals else { return }
        switch verdict {
        case .approve: await approvals.grant(request.token)
        case .deny(let reason): await approvals.deny(request.token, reason: reason)
        }
    }

    /// Waits for the current turn to finish, then relaunches with `--resume <id>` and the message.
    public func send(_ userMessage: String) async throws {
        let (cancelled, finished, turn) = state.withLock { ($0.cancelled, $0.finished, $0.turn) }
        if cancelled { throw AgentFailure.cancelled }
        if finished { throw AgentFailure(code: "ended", message: "The session's event stream has ended") }
        await turn?.value
        let task = Task { await self.runTurn(prompt: userMessage, resume: true) }
        state.withLock { $0.turn = task }
    }

    public func cancel() async {
        let (process, alreadyCancelled) = state.withLock { s -> (Process?, Bool) in
            let was = s.cancelled
            s.cancelled = true
            return (s.process, was)
        }
        guard !alreadyCancelled else { return }
        if let process, process.isRunning { process.terminate() }
        continuation.yield(.failed(.cancelled))
        end()
    }
}

/// Runs a child process to completion with a timeout, capturing both streams.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    enum Failure: Error { case timedOut }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration)
        async throws
        -> Output
    {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let reader = Task.detached { () -> (String, String) in
            let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (o, e)
        }
        let watchdog = Task.detached {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        let (stdout, stderr) = await reader.value
        process.waitUntilExit()
        watchdog.cancel()
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
