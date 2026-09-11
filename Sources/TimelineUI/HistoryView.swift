import Contracts
import Foundation
import SwiftUI
import TimelineCore

/// One row of the history list.
public struct HistoryRow: Identifiable, Hashable, Sendable {
    public var id: TransactionID
    public var label: String
    public var actor: Actor
    public var eventCount: Int
    public var isLive: Bool
    public var isRedoable: Bool
    public var isUndoTarget: Bool
    public var isRedoTarget: Bool
}

extension History {
    /// Edit transactions in log order with their live/undone state; markers (undo/redo) are folded in.
    public var rows: [HistoryRow] {
        let liveSet = Set(live)
        let redoSet = Set(redoStack)
        return transactions.filter { $0.kind == .edit }.map { t in
            HistoryRow(
                id: t.id, label: t.label, actor: t.actor, eventCount: t.events.count, isLive: liveSet.contains(t.id),
                isRedoable: redoSet.contains(t.id), isUndoTarget: live.last == t.id,
                isRedoTarget: redoStack.last == t.id
            )
        }
    }
}

/// Transactions with live/undone state and undo/redo buttons, driven by the store's history fold.
public struct HistoryView: View {
    public let viewModel: TimelineViewModel

    public init(viewModel: TimelineViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.controlGap) {
            HStack {
                Text("History").font(PanelTheme.sectionTitle)
                Spacer()
                Button {
                    Task { await viewModel.undo() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!viewModel.canUndo).help("Undo").keyboardShortcut("z", modifiers: .command)
                Button {
                    Task { await viewModel.redo() }
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!viewModel.canRedo).help("Redo").keyboardShortcut("z", modifiers: [.command, .shift])
            }
            List(viewModel.history.rows) { row in
                HStack {
                    Image(systemName: row.isLive ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(row.isLive ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading) {
                        Text(row.label).strikethrough(!row.isLive)
                            .foregroundStyle(row.isLive ? .primary : .secondary)
                        Text("\(ActorLabel.text(row.actor)) · \(row.eventCount) events").font(PanelTheme.caption)
                            .foregroundStyle(.secondary)
                            .help(ActorLabel.detail(row.actor) ?? "")
                    }
                    Spacer()
                    if row.isUndoTarget { Text("undo").font(PanelTheme.detail).foregroundStyle(.secondary) }
                    if row.isRedoTarget { Text("redo").font(PanelTheme.detail).foregroundStyle(.secondary) }
                }
                .accessibilityIdentifier("history-\(row.id.rawValue)")
            }
            .listStyle(.inset)
        }
        .padding(PanelTheme.panelInset)
    }
}
