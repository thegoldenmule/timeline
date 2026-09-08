import Contracts
import Foundation
import Synchronization
import TimelineCore

/// Replays scripted events. An `.approvalRequested` event pauses the replay until `approve` answers it;
/// `send` queues the next follow-up script (one per call); the stream ends when the script and every
/// follow-up have been replayed, or on `cancel`.
public final class FakeAgentSession: AgentSession, Sendable {
    public let id: String
    public let goal: String
    public let events: AsyncStream<AgentEvent>

    private struct State {
        var followUps: [[AgentEvent]]
        var userMessages: [String] = []
        var verdicts: [(ApprovalRequest, ApprovalVerdict)] = []
        var awaiting: CheckedContinuation<ApprovalVerdict, Never>?
        var cancelled = false
    }

    private let state: Mutex<State>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let scripts: AsyncStream<[AgentEvent]>
    private let scriptsContinuation: AsyncStream<[AgentEvent]>.Continuation
    private let replay = Mutex<Task<Void, Never>?>(nil)

    init(id: String, goal: String, script: [AgentEvent], followUps: [[AgentEvent]]) {
        self.id = id
        self.goal = goal
        state = Mutex(State(followUps: followUps))
        (events, continuation) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        (scripts, scriptsContinuation) = AsyncStream<[AgentEvent]>.makeStream(bufferingPolicy: .unbounded)
        scriptsContinuation.yield(script)
        if followUps.isEmpty { scriptsContinuation.finish() }
        replay.withLock { $0 = Task { [self] in await self.run() } }
    }

    private func run() async {
        for await script in scripts {
            for event in script {
                if state.withLock({ $0.cancelled }) { return }
                continuation.yield(event)
                if case .approvalRequested(let request) = event {
                    let verdict = await withCheckedContinuation { c in
                        state.withLock { $0.awaiting = c }
                    }
                    state.withLock { $0.verdicts.append((request, verdict)) }
                }
            }
        }
        continuation.finish()
    }

    /// Verdicts given so far, in order.
    public var verdicts: [(request: ApprovalRequest, verdict: ApprovalVerdict)] {
        state.withLock { $0.verdicts.map { ($0.0, $0.1) } }
    }

    public var userMessages: [String] { state.withLock { $0.userMessages } }
    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    public func approve(_ request: ApprovalRequest, verdict: ApprovalVerdict) {
        let waiting = state.withLock { s -> CheckedContinuation<ApprovalVerdict, Never>? in
            let c = s.awaiting
            s.awaiting = nil
            return c
        }
        waiting?.resume(returning: verdict)
    }

    public func send(_ userMessage: String) throws {
        let next: [AgentEvent]? = state.withLock { s in
            guard !s.cancelled else { return nil }
            s.userMessages.append(userMessage)
            return s.followUps.isEmpty ? [] : s.followUps.removeFirst()
        }
        guard let next else { throw AgentFailure.cancelled }
        scriptsContinuation.yield(next)
        if state.withLock({ $0.followUps.isEmpty }) { scriptsContinuation.finish() }
    }

    public func cancel() {
        let waiting = state.withLock { s -> CheckedContinuation<ApprovalVerdict, Never>? in
            s.cancelled = true
            let c = s.awaiting
            s.awaiting = nil
            return c
        }
        waiting?.resume(returning: .deny(reason: "cancelled"))
        scriptsContinuation.finish()
        replay.withLock { $0?.cancel() }
        continuation.yield(.failed(.cancelled))
        continuation.finish()
    }
}

/// Starts `FakeAgentSession`s from one script; records every session started.
public final class FakeAgentRuntime: AgentRuntime, Sendable {
    public struct Start: Sendable {
        public var goal: String
        public var tools: ToolAccess
        public var policy: RuntimePolicy
        public var session: FakeAgentSession
    }

    private struct State {
        var script: [AgentEvent]
        var followUps: [[AgentEvent]]
        var availability: RuntimeAvailability
        var starts: [Start] = []
        var counter = 0
    }

    private let state: Mutex<State>

    public init(
        script: [AgentEvent] = FakeAgentRuntime.defaultScript, followUps: [[AgentEvent]] = [],
        availability: RuntimeAvailability = RuntimeAvailability(installed: true, version: "fake", loggedIn: true)
    ) {
        state = Mutex(State(script: script, followUps: followUps, availability: availability))
    }

    public var sessions: [Start] { state.withLock { $0.starts } }
    public func setAvailability(_ value: RuntimeAvailability) { state.withLock { $0.availability = value } }
    public func setScript(_ script: [AgentEvent], followUps: [[AgentEvent]] = []) {
        state.withLock {
            $0.script = script
            $0.followUps = followUps
        }
    }

    public func availability() async -> RuntimeAvailability { state.withLock { $0.availability } }

    public func startSession(goal: String, tools: ToolAccess, policy: RuntimePolicy) async throws -> any AgentSession {
        let availability = state.withLock { $0.availability }
        guard availability.isUsable else {
            throw AgentFailure(code: "unavailable", message: availability.detail ?? "runtime not usable")
        }
        let session: FakeAgentSession = state.withLock { s in
            s.counter += 1
            let session = FakeAgentSession(
                id: "fake-session-\(s.counter)", goal: goal, script: s.script, followUps: s.followUps)
            s.starts.append(Start(goal: goal, tools: tools, policy: policy, session: session))
            return session
        }
        return session
    }

    /// One turn: text, a `project_describe` call and result, a finish with cost.
    public static let defaultScript: [AgentEvent] = [
        .turnStarted(index: 1),
        .assistantText("Looking at the project."),
        .toolCall(id: "call-1", name: "project_describe", input: ["level": "summary"]),
        .toolResult(id: "call-1", output: ["version": 4, "tracks": ["V1", "A1"]], isError: false),
        .assistantText("Done."),
        .finished(result: "Done.", cost: CostReport(usd: 0.01, turns: 1)),
    ]
}
