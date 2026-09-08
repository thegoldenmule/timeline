# Contracts proposals from the App (walking skeleton)

Status: proposals only, 2026-09-08. Raised while wiring `TimelineApp` to the fakes (see
`../walking-skeleton.md`). Nothing here blocked the skeleton; each is a small, reviewable change for
the integration owner to fold in with the matching fake update.

## 1. `AgentEvent.approvalRequested` should carry the gate's request (doc comment only)

`Sources/Contracts/AgentRuntime.swift`, on the `.approvalRequested(ApprovalRequest)` case. Today the
comment on `AgentSession` says approval requests "surface as `.approvalRequested`, and `approve` answers
them; the server-side gate is still the one that decides whether the tool runs." It does not say *which*
`ApprovalRequest` the event carries. The fake's script and `Fixtures.approvalRequest()` mint their own
(`approval-1` / `tok-1`), which happen to collide with the fake gate's first request by coincidence.

The app's approval card needs to `grant` the gate's token. If the runtime forwards a request with a
different `id` and `token`, the app has to guess the pairing (the skeleton matches on `tool` and takes
the gate's latest pending request, which is wrong as soon as two sessions export at once).

Proposed wording, replacing the case's doc comment:

```swift
/// The gate raised a request for a tool this session called: the same value (`id`, `token`) that
/// `ApprovalGate.requests` published and that the tool's `approval_required` output carries as
/// `requestId` / `approvalToken`. The app grants or denies that token on the gate and then calls
/// `approve(_:verdict:)` with this request so the session continues.
case approvalRequested(ApprovalRequest)
```

And on `AgentSession.approve`: "`request` is the one from `.approvalRequested`; the verdict only
resumes the session (or tells the sidecar hook to allow or block the call). Granting the tool is the
gate's `grant`, which the app performs first."

For the sidecar, this means the `PreToolUse` hook (or the stream-json parser, when it sees a tool result
whose `structuredContent.status == "approval_required"`) builds the event from the gate's pending
request looked up by `requestId`, not from its own bookkeeping. No type changes; `FakeAgentSession` is
unchanged. `Fixtures.approvalRequest()` could take the request from a `FakeApprovalGate.check` so the
usage example demonstrates the pairing.

## 2. `ProjectChange` could carry the number of events (optional, low value)

`Project.version` counts events, so consumers that want to know "how far did this transaction move the
version" compute `version - previousChange.version`. Adding `eventCount: Int` to `ProjectChange` would
make that a field. Not needed by the app (it waits on `version` monotonically); noted because the
first headless check assumed one event per transaction and an undo is at least two. A sentence in the
`ProjectStore` doc comment ("`version` advances by the number of events, at least two for undo/redo")
would do as well.
