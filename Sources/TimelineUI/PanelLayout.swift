import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// Which way a panel's divider moves it.
public enum PanelAxis: Hashable, Sendable {
    /// A column: it has a width, and it collapses to a rail.
    case horizontal
    /// A row stacked inside a column: it has a height, and it collapses to its own header bar.
    case vertical
}

/// Every panel the editor window can show, in window order. `rightColumn` is a container: it carries the
/// width its two stacked children share and is collapsed exactly when both of them are.
public enum PanelID: String, CaseIterable, Identifiable, Sendable {
    case assistant
    case library
    case rightColumn = "right"
    case inspector
    case activity

    public var id: String { rawValue }

    /// The columns the window lays out left to right. The centre — preview, timeline, status bar — is
    /// not a panel: it is whatever is left over.
    public static let columns: [PanelID] = [.assistant, .library, .rightColumn]
    /// The panels that wear chrome. `rightColumn` is a container and wears none.
    public static let panels: [PanelID] = [.assistant, .library, .inspector, .activity]

    /// What the header and the rail call it. Empty for the container, which is never drawn.
    public var title: String {
        switch self {
        case .assistant: "Assistant"
        case .library: "Library"
        case .inspector: "Inspector"
        case .activity: "Activity"
        case .rightColumn: ""
        }
    }

    public var systemImage: String {
        switch self {
        case .assistant: "sparkles"
        case .library: "rectangle.stack"
        case .inspector: "slider.horizontal.3"
        case .activity: "checklist"
        case .rightColumn: "sidebar.right"
        }
    }

    public var axis: PanelAxis {
        switch self {
        case .inspector, .activity: .vertical
        default: .horizontal
        }
    }

    /// The panels a container owns; empty for everything else.
    public var children: [PanelID] {
        self == .rightColumn ? [.inspector, .activity] : []
    }

    public var defaultSize: CGFloat {
        switch self {
        case .assistant: 340
        case .library: 280
        case .rightColumn: 400
        case .inspector: 260
        case .activity: 0  // always the flexible one when it is open
        }
    }

    public var minSize: CGFloat {
        switch self {
        case .assistant: 280
        case .library: 220
        case .rightColumn: 320
        case .inspector: 140
        case .activity: 160
        }
    }

    public var maxSize: CGFloat {
        switch self {
        case .assistant: 620
        case .library: 480
        case .rightColumn: 700
        case .inspector, .activity: .infinity
        }
    }

    /// Which side of the panel its resize divider sits on: dragging right widens a leading panel and
    /// narrows a trailing one.
    public var resizeSign: CGFloat { self == .rightColumn ? -1 : 1 }

    /// Whether the panel carries a size of its own. The activity panel never does: it is the one that
    /// takes whatever the right column has left, so there is nothing to store or clamp.
    public var storesSize: Bool { self != .activity }

    /// The panel's toggle key. Always used with `[.command, .option]` — see `docs/design/ui-style.md`
    /// on why a bare key equivalent cannot be used anywhere in this window.
    public var shortcut: KeyEquivalent {
        switch self {
        case .assistant: "a"
        case .library: "l"
        case .inspector: "i"
        case .activity: "j"
        case .rightColumn: "0"
        }
    }

    var collapsedKey: String { "panel.\(rawValue).collapsed" }
    var sizeKey: String { "panel.\(rawValue).size" }
}

/// What each panel's width, height, and collapsed flag are, clamped so no panel can squeeze the timeline
/// out of the window, and remembered across launches.
///
/// The model holds every piece of arithmetic the layout needs, so the views hold none and all of it can
/// be tested: `@AppStorage` is a `DynamicProperty` and only works inside a `View`, so this reads and
/// writes `UserDefaults` itself and tests inject a throwaway suite.
@MainActor @Observable
public final class PanelLayoutModel {
    /// The key the library pane used before there were panels. Read once, then left alone.
    static let legacyLibraryKey = "showsLibrary"

    @ObservationIgnored private let defaults: UserDefaults
    private var collapsed: [PanelID: Bool] = [:]
    private var sizes: [PanelID: CGFloat] = [:]
    /// What the window last offered the row of columns, and what the right column last offered its two
    /// stacked panels. Zero until the first layout, which means "do not clamp against it yet".
    private var availableWidth: CGFloat = 0
    private var availableHeight: CGFloat = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for id in PanelID.allCases {
            if let stored = defaults.object(forKey: id.collapsedKey) as? Bool { collapsed[id] = stored }
            if let stored = defaults.object(forKey: id.sizeKey) as? Double { sizes[id] = CGFloat(stored) }
        }
        migrateLegacyLibraryKey()
    }

    /// The library was the one pane that could already be hidden. `object(forKey:)`, not
    /// `bool(forKey:)`: the latter cannot tell a missing key from a stored `false`.
    private func migrateLegacyLibraryKey() {
        guard defaults.object(forKey: PanelID.library.collapsedKey) == nil,
            let shown = defaults.object(forKey: Self.legacyLibraryKey) as? Bool, !shown
        else { return }
        setCollapsed(.library, true)
    }

    // MARK: Collapse

    /// A container is collapsed exactly when every panel inside it is.
    public func isCollapsed(_ id: PanelID) -> Bool {
        let children = id.children
        guard children.isEmpty else { return children.allSatisfy { isCollapsed($0) } }
        return collapsed[id] ?? false
    }

    public func setCollapsed(_ id: PanelID, _ value: Bool) {
        let children = id.children
        guard children.isEmpty else {
            for child in children { setCollapsed(child, value) }
            return
        }
        collapsed[id] = value
        defaults.set(value, forKey: id.collapsedKey)
        reclamp()
    }

    public func toggle(_ id: PanelID) {
        setCollapsed(id, !isCollapsed(id))
    }

    // MARK: Size

    public func size(_ id: PanelID) -> CGFloat {
        sizes[id] ?? id.defaultSize
    }

    /// Clamps into what the window can spare, rounds to a whole point, and remembers it.
    public func setSize(_ id: PanelID, _ value: CGFloat) {
        let clamped = (min(max(value, id.minSize), upperBound(id))).rounded()
        guard clamped != sizes[id] else { return }
        sizes[id] = clamped
        defaults.set(Double(clamped), forKey: id.sizeKey)
    }

    /// What a panel actually occupies along its axis right now: a rail or a header bar when it is
    /// collapsed, its size when it is not.
    public func renderedWidth(_ id: PanelID) -> CGFloat {
        guard !isCollapsed(id) else {
            return id.axis == .horizontal ? PanelTheme.railWidth : PanelTheme.barHeight
        }
        return size(id)
    }

    /// The one panel on its axis that absorbs the remainder. The activity panel normally does; once it
    /// is collapsed the inspector takes over, so the right column is never short.
    public func isFlexible(_ id: PanelID) -> Bool {
        switch id {
        case .activity: !isCollapsed(.activity)
        case .inspector: isCollapsed(.activity) && !isCollapsed(.inspector)
        default: false
        }
    }

    // MARK: Available space

    /// What the window gave the row of columns. Re-clamps every column, so shrinking the window pulls
    /// the panels in rather than squeezing the timeline out.
    public func availableWidthChanged(_ width: CGFloat) {
        guard width != availableWidth else { return }
        availableWidth = width
        reclamp()
    }

    /// The same, for the height the right column hands its two stacked panels.
    public func availableHeightChanged(_ height: CGFloat) {
        guard height != availableHeight else { return }
        availableHeight = height
        reclamp()
    }

    /// How narrow the window may get as it stands. Collapsing a panel lowers it, which is the whole
    /// point: a collapsed panel should let the window shrink, not just free up space inside it.
    public var minimumWindowWidth: CGFloat {
        PanelID.columns.reduce(PanelTheme.centreMinimum) { total, id in
            let occupied = isCollapsed(id) ? PanelTheme.railWidth : id.minSize
            return total + occupied + PanelTheme.dividerThickness
        }
    }

    /// The largest a panel may be without pushing the centre below `PanelTheme.centreMinimum` — or,
    /// for a stacked panel, without pushing its sibling below its own minimum.
    func upperBound(_ id: PanelID) -> CGFloat {
        let available = id.axis == .horizontal ? availableWidth : availableHeight
        guard available > 0 else { return id.maxSize }
        let siblings: CGFloat
        switch id.axis {
        case .horizontal:
            siblings = PanelID.columns.filter { $0 != id }
                .reduce(PanelTheme.centreMinimum) { $0 + renderedWidth($1) + PanelTheme.dividerThickness }
        case .vertical:
            siblings = PanelID.rightColumn.children.filter { $0 != id }
                .reduce(0) { $0 + (isCollapsed($1) ? PanelTheme.barHeight : $1.minSize) + PanelTheme.dividerThickness }
        }
        let slack = available - siblings - PanelTheme.dividerThickness
        return max(id.minSize, min(id.maxSize, slack))
    }

    /// Re-applies every stored size through `setSize`, which is where the clamping lives. Clamping is
    /// idempotent, so one pass settles it.
    private func reclamp() {
        for id in PanelID.allCases where id.storesSize && !isFlexible(id) {
            setSize(id, size(id))
        }
    }
}
