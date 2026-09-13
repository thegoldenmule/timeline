import Foundation
import SwiftUI
import TimelineCore

/// The texts of the rename sheet; public so the app and the tests reference the same strings.
public enum ProjectRenameText {
    public static let title = "Rename project"
    public static let field = "Project name"
    public static let prompt = "Project name"
    /// The whole point of the sheet's copy: the name and the file name are separate facts, and Fork is
    /// the thing that makes a differently named package.
    public static let packageNote =
        "The package on disk keeps its file name. Fork is how you make a differently named package."
    public static let emptyError = "A project name cannot be blank"
    public static let rename = "Rename"
    public static let cancel = "Cancel"

    public static func tooLongError(_ maximum: Int) -> String {
        "A project name is at most \(maximum) characters"
    }

    public static func remaining(_ count: Int) -> String {
        "\(count) character\(count == 1 ? "" : "s") left"
    }
}

/// What the rename sheet edits: the name the store holds and the one being typed over it. The
/// validation lives here rather than in `decide`, which accepts any string — the cap and the blank
/// rejection bind the human path and leave `renameProject` over MCP exactly as it is
/// (`docs/plans/project-rename.md`, decision 2).
public struct ProjectRename: Hashable, Sendable {
    /// Long enough for any real title, short enough that the window title and a library row stay one
    /// line.
    public static let maximumLength = 120

    /// The name in the store when the sheet opened.
    public let current: String
    /// What is in the field.
    public var name: String

    public init(current: String) {
        self.current = current
        self.name = current
    }

    /// What would actually be stored: surrounding whitespace and newlines are not part of a name.
    public var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when committing would change nothing — including a name that differs from the current one
    /// only by the whitespace around it.
    public var isUnchanged: Bool { trimmed == current }

    /// Why this cannot be committed, or nil when it can. An unchanged name is not an error.
    public var validationError: String? {
        if trimmed.isEmpty { return ProjectRenameText.emptyError }
        if trimmed.count > ProjectRename.maximumLength {
            return ProjectRenameText.tooLongError(ProjectRename.maximumLength)
        }
        return nil
    }

    /// An unchanged name may be submitted on purpose: Return on a sheet opened by mistake should close
    /// it, not sit there disabled. It just sends nothing.
    public var canSubmit: Bool { validationError == nil }

    /// How many characters are left before the cap; negative once it is past.
    public var remaining: Int { ProjectRename.maximumLength - trimmed.count }

    /// The one command this sheet sends, or nil when there is nothing to send: an invalid name, or a
    /// name that matches what the store already holds. The no-op is decided here, before the store is
    /// reached; `decide` emitting no events for an identical name is the backstop, not the mechanism.
    public var operation: Command.Operation? {
        guard canSubmit, !isUnchanged else { return nil }
        return .renameProject(.init(name: trimmed))
    }
}

/// The rename sheet: the field, what the name is and is not, and one command on Rename. The project
/// name lives in the event stream, so committing goes through the store like every other edit and lands
/// in the history panel and on the undo stack.
public struct ProjectRenameSheet: View {
    @Binding public var rename: ProjectRename
    /// Applies the rename. Returns the message to show when it failed; nil when it went through, in
    /// which case the caller has dismissed the sheet.
    public let onRename: (ProjectRename) async -> String?
    public let onCancel: () -> Void
    @State private var isRenaming = false
    @State private var submitError: String?

    public init(
        rename: Binding<ProjectRename>, onRename: @escaping (ProjectRename) async -> String?,
        onCancel: @escaping () -> Void
    ) {
        self._rename = rename
        self.onRename = onRename
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionGap) {
            Text(ProjectRenameText.title).font(PanelTheme.sectionTitle)
            TextField(
                ProjectRenameText.field, text: $rename.name, prompt: Text(ProjectRenameText.prompt)
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1)
            .onSubmit(commit)
            .accessibilityIdentifier("rename-field")
            if rename.remaining <= ProjectRename.maximumLength / 2 {
                Text(ProjectRenameText.remaining(rename.remaining))
                    .font(PanelTheme.detail)
                    .foregroundStyle(rename.remaining < 0 ? PanelTheme.danger : Color.secondary)
            }
            Text(ProjectRenameText.packageNote).font(PanelTheme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = rename.validationError ?? submitError {
                Label(error, systemImage: "xmark.octagon").font(PanelTheme.caption)
                    .foregroundStyle(PanelTheme.danger)
                    .accessibilityIdentifier("rename-error")
            }
            HStack(spacing: PanelTheme.controlGap) {
                Spacer(minLength: 0)
                Button(ProjectRenameText.cancel, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(ProjectRenameText.rename, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!rename.canSubmit || isRenaming)
            }
        }
        .padding(PanelTheme.pageInset)
        .frame(width: PanelTheme.sheetWidth)
    }

    private func commit() {
        guard rename.canSubmit, !isRenaming else { return }
        isRenaming = true
        submitError = nil
        let value = rename
        Task {
            submitError = await onRename(value)
            isRenaming = false
        }
    }
}
