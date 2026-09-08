import Contracts
import Foundation
import Observation
import TimelineCore

/// Pretty JSON for the UI and the headless summary.
enum PrettyJSON {
    static func string(_ value: JSONValue?) -> String {
        guard let value else { return "null" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "<unencodable>" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Jobs

/// The outcome payload of the demo job.
struct DemoJobResult: Codable, Sendable {
    var asset: String
    var silenceRanges: Int
    var shots: Int
    var peaks: Int
}

/// Submits one job through the runner and mirrors its progress stream.
@MainActor @Observable
final class JobConsole {
    let services: AppServices
    private(set) var label = ""
    private(set) var progress: [JobProgress] = []
    private(set) var isRunning = false
    private(set) var outcome: JobOutcome?
    private(set) var error: String?

    init(services: AppServices) { self.services = services }

    var fraction: Double { progress.last?.fraction ?? 0 }

    /// Analyses the first asset with the fake analyzer and waveform provider, reporting a stage per step.
    @discardableResult
    func runDemoJob(project: Project) async throws -> JobOutcome {
        guard let asset = project.assets.values.sorted(by: { $0.id < $1.id }).first(where: \.hasAudio) else {
            throw ToolError.invalidInput("The project has no asset with audio")
        }
        let media = MediaReference(asset: asset, layout: services.mediaLibrary.layout)
        let analyzer = services.analyzer
        let waveforms = services.waveforms
        let job = Job(kind: .analysis, memoryClass: .small, label: "Analyze \(asset.displayName)") { context in
            context.report(JobProgress(fraction: 0, message: "Detecting silence", stage: "silence"))
            let silence = try await analyzer.detectSilence(media, parameters: SilenceParameters())
            try context.checkCancellation()
            context.report(JobProgress(fraction: 1 / 3, message: "Detecting shots", stage: "shots"))
            let shots = try await analyzer.detectShots(media, parameters: ShotParameters())
            try context.checkCancellation()
            context.report(JobProgress(fraction: 2 / 3, message: "Reading peaks", stage: "peaks"))
            let peaks = try await waveforms.peaks(for: media, range: .zero...asset.duration, samplesPerPixel: 4800)
            try await Task.sleep(for: .milliseconds(200))
            context.report(.done)
            return try JobOutcome(
                encoding: DemoJobResult(
                    asset: asset.displayName, silenceRanges: silence.ranges.count, shots: shots.shots.count,
                    peaks: peaks.count))
        }
        label = job.label
        progress = []
        outcome = nil
        error = nil
        isRunning = true
        defer { isRunning = false }
        let handle = await services.jobRunner.submit(job)
        let mirror = Task { @MainActor [weak self] in
            for await p in handle.progress { self?.progress.append(p) }
        }
        do {
            let result = try await handle.wait()
            await mirror.value
            outcome = result
            return result
        } catch {
            await mirror.value
            self.error = "\(error)"
            throw error
        }
    }
}

// MARK: - Tools

/// Calls registry tools as the human and shows the structured result.
@MainActor @Observable
final class ToolConsole {
    let services: AppServices
    private(set) var lastTool = ""
    private(set) var lastOutput: ToolOutput?
    private(set) var error: String?
    private(set) var isCalling = false

    init(services: AppServices) { self.services = services }

    var structuredText: String { PrettyJSON.string(lastOutput?.structured) }

    @discardableResult
    func call(_ name: String, input: ToolInput = ToolInput()) async throws -> ToolOutput {
        lastTool = name
        error = nil
        isCalling = true
        defer { isCalling = false }
        do {
            let output = try await services.callTool(name, input: input, actor: .human)
            lastOutput = output
            return output
        } catch {
            self.error = "\(error)"
            throw error
        }
    }

    func describeProject() async throws -> ToolOutput {
        try await call("project_describe", input: ToolInput(["level": "summary"]))
    }
}

// MARK: - Agent

/// Runs one agent session: streams its events, executes the tool calls it announces through the
/// registry (the client-side tool loop a Messages-API runtime needs; the CLI sidecar calls the MCP
/// server itself), and turns `.approvalRequested` into an approval card that grants through the gate.
@MainActor @Observable
final class AgentConsole {
    struct Entry: Identifiable, Sendable {
        enum Kind: Sendable {
            case runtime(AgentEvent)
            /// The app ran the tool the runtime announced; `retried` when it carried an approval token.
            case appToolExecution(callId: String, name: String, output: ToolOutput, retried: Bool)
        }

        let id: Int
        let kind: Kind
    }

    struct PendingApproval: Sendable {
        /// What the runtime asked; answering it resumes the session.
        let scripted: ApprovalRequest
        /// What the gate minted for the same tool; granting it is what lets the tool run.
        let gate: ApprovalRequest?
    }

    private struct ToolCall: Sendable {
        var id: String
        var name: String
        var input: ToolInput
    }

    let services: AppServices
    private(set) var entries: [Entry] = []
    private(set) var pending: PendingApproval?
    private(set) var session: (any AgentSession)?
    private(set) var isRunning = false
    private(set) var finished: AgentEvent?
    /// Requests the gate raised while the session ran, from `ApprovalGate.requests`.
    private(set) var gateRequests: [ApprovalRequest] = []
    private(set) var error: String?
    private var awaitingToken: ToolCall?
    private var runTask: Task<Void, Never>?
    private var gateTask: Task<Void, Never>?

    init(services: AppServices) { self.services = services }

    var appToolOutputs: [(callId: String, name: String, output: ToolOutput, retried: Bool)] {
        entries.compactMap {
            if case .appToolExecution(let id, let name, let output, let retried) = $0.kind {
                return (id, name, output, retried)
            }
            return nil
        }
    }

    /// Starts a session and returns once it is streaming; `runToCompletion` waits for the end.
    func start(goal: String) async throws {
        entries = []
        pending = nil
        finished = nil
        error = nil
        gateRequests = []
        awaitingToken = nil
        let requests = services.approvals.requests
        gateTask = Task { @MainActor [weak self] in
            for await request in requests { self?.gateRequests.append(request) }
        }
        let session = try await services.agentRuntime.startSession(
            goal: goal, tools: ToolAccess(endpoint: URL(string: "http://127.0.0.1:0/mcp")!, bearerToken: "skeleton"),
            policy: RuntimePolicy(model: "fake-model", maxBudgetUSD: 1, maxTurns: 4))
        self.session = session
        isRunning = true
        runTask = Task { @MainActor [weak self] in
            for await event in session.events {
                guard let self else { return }
                await self.handle(event, session: session)
            }
            self?.isRunning = false
            self?.gateTask?.cancel()
        }
    }

    func runToCompletion() async {
        await runTask?.value
    }

    /// Grants the gate's request, retries the held tool call with the token, then answers the runtime.
    func approve() async {
        guard let pending, let session else { return }
        if let gate = pending.gate {
            await services.approvals.grant(gate.token)
            if let call = awaitingToken {
                var input = call.input
                input.arguments["approvalToken"] = .string(gate.token.rawValue)
                await execute(call, input: input, session: session, retried: true)
            }
        }
        awaitingToken = nil
        self.pending = nil
        await session.approve(pending.scripted, verdict: .approve)
    }

    func deny() async {
        guard let pending, let session else { return }
        if let gate = pending.gate { await services.approvals.deny(gate.token, reason: "Denied in the app") }
        awaitingToken = nil
        self.pending = nil
        await session.approve(pending.scripted, verdict: .deny(reason: "Denied in the app"))
    }

    func cancel() async {
        await session?.cancel()
    }

    private func append(_ kind: Entry.Kind) {
        entries.append(Entry(id: entries.count, kind: kind))
    }

    private func handle(_ event: AgentEvent, session: any AgentSession) async {
        append(.runtime(event))
        switch event {
        case .toolCall(let id, let name, let input):
            let call = ToolCall(id: id, name: name, input: ToolInput(input.objectValue ?? [:]))
            await execute(call, input: call.input, session: session, retried: false)
        case .approvalRequested(let request):
            let gate = await services.approvals.pending().last { $0.tool == request.tool }
            pending = PendingApproval(scripted: request, gate: gate)
        case .finished, .failed:
            finished = event
        default:
            break
        }
    }

    private func execute(_ call: ToolCall, input: ToolInput, session: any AgentSession, retried: Bool) async {
        do {
            let output = try await services.callTool(
                call.name, input: input, actor: .agent(sessionId: session.id), sessionId: session.id)
            append(.appToolExecution(callId: call.id, name: call.name, output: output, retried: retried))
            if output.isApprovalRequired { awaitingToken = call }
        } catch {
            self.error = "\(call.name): \(error)"
            append(
                .appToolExecution(
                    callId: call.id, name: call.name, output: .error(code: "threw", message: "\(error)"),
                    retried: retried))
        }
    }
}
