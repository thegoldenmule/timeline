import Contracts
import Foundation
import TimelineCore

extension AgentFailure {
    /// The runtime is not installed, not logged in, or not implemented.
    public static let unavailable = AgentFailure(code: "unavailable", message: "The agent runtime is not available")
}

/// The second `AgentRuntime` behind the same protocol: a Messages-API implementation (SwiftAnthropic
/// or `ClaudeForFoundationModels` on macOS 27) that runs its own tool loop against the registry
/// instead of the CLI. A compiling stub for now: it proves the protocol is implementable twice and
/// gives the app a place to plug an API key in; `startSession` throws `unavailable`.
public struct MessagesAPIRuntime: AgentRuntime, Sendable {
    public struct Configuration: Sendable, Hashable {
        public var apiKey: String?
        public var baseURL: URL
        public var defaultModel: String

        public init(
            apiKey: String? = nil, baseURL: URL = URL(string: "https://api.anthropic.com")!,
            defaultModel: String = "claude-sonnet-4-5"
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.defaultModel = defaultModel
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    public func availability() async -> RuntimeAvailability {
        RuntimeAvailability(
            installed: false, version: nil, loggedIn: configuration.apiKey != nil,
            detail: "Messages API runtime is not implemented yet; use the Claude Code sidecar or MCP only")
    }

    public func startSession(goal: String, tools: ToolAccess, policy: RuntimePolicy) async throws -> any AgentSession {
        throw AgentFailure.unavailable
    }
}
