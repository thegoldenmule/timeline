# Contracts proposals from AgentKit

Status: notes from implementing `AgentKit`, 2026-09-08. Nothing here blocks the module; each item was worked around locally and is proposed for the next `Contracts` change window.

## 1. `AgentFailure.unavailable`

The plan names `AgentFailure.unavailable` for a runtime that is not installed or not logged in; `Contracts` ships only `.cancelled`. AgentKit adds it as an extension (`Sources/AgentKit/MessagesAPIRuntime.swift`); moving it into `Contracts/AgentRuntime.swift` lets fakes and the App share the code string:

```diff
 public struct AgentFailure: Error, Hashable, Sendable, Codable {
     ...
     public static let cancelled = AgentFailure(code: "cancelled", message: "The session was cancelled")
+    /// The runtime is not installed, not logged in, or not implemented.
+    public static let unavailable = AgentFailure(code: "unavailable", message: "The agent runtime is not available")
 }
```

## 2. `ApprovalGate`: query a verdict without consuming the token

The `PreToolUse` hook (`MCPServerHost` `/approval`) needs to wait for the human's answer and then say `allow` or `deny` while leaving the token for the server-side gate to consume. `ApprovalGate` offers `pending()` (so the hook can wait) and `consume(_:)` (which spends the token), but no way to tell a grant from a denial without consuming. AgentKit wraps the app's gate in `RecordingApprovalGate` and records verdicts that pass through the wrapper; a denial issued directly on the underlying gate is invisible to the hook, which then answers `allow` and lets the server-side gate mint a fresh request. A read-only verdict query closes that gap:

```diff
 public protocol ApprovalGate: Sendable {
     ...
     func consume(_ token: ApprovalToken) async -> Bool
+    /// The current state of a token: pending, granted (unconsumed), denied, consumed, or unknown.
+    func status(of token: ApprovalToken) async -> ApprovalTokenStatus
     func pending() async -> [ApprovalRequest]
 }
+
+public enum ApprovalTokenStatus: Hashable, Sendable, Codable {
+    case pending, granted, denied(reason: String?), consumed, unknown
+}
```

`FakeApprovalGate` already tracks every state, so the fake's change is a five-line switch.

## 3. `ToolReceipt` for rejected calls has no `projectId`

The registry fills `projectId` from the input or the output; a rejected `timeline_apply` (stale version) carries neither when the caller relied on the frontmost project. `ToolContext.store(for:)` could return the resolved `ProjectID` alongside the store, or `ToolOutput.editorError` could take an optional `projectId`. Low priority: the receipt still has the tool, session, and args hash.
