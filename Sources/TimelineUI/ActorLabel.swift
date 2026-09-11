import Foundation
import TimelineCore

/// How an `Actor` is named in the window.
///
/// `Actor.description` is the wire format — `"agent:<sessionId>"` — and `Actor.init(_:)` parses that
/// prefix back, so it cannot be renamed and `TimelineCore` is frozen besides. This is the only thing a
/// view shows: the pane is the Assistant, the session id is a detail, and neither belongs in a list row.
public enum ActorLabel {
    public static func text(_ actor: Actor) -> String {
        switch actor {
        case .human: "You"
        case .agent: "Assistant"
        case .system: "System"
        }
    }

    /// The session behind an assistant's edit, for a `.help` — worth having, never worth showing inline.
    public static func detail(_ actor: Actor) -> String? {
        guard case .agent(let sessionId) = actor else { return nil }
        return "Assistant session \(sessionId)"
    }
}
