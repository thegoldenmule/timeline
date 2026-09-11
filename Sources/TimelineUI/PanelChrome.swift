import CoreGraphics
import Foundation
import SwiftUI

/// The bar every panel wears: the symbol that collapses it, its name, and a trailing slot the panel
/// fills with its own controls. Fixed height, never wraps, never scrolls.
///
/// There is no tap-to-collapse on the bar itself. `MediaLibraryView` records what a stray `TapGesture`
/// does to the controls underneath it; an explicit button is unambiguous and costs nothing.
public struct PanelHeader<Controls: View>: View {
    public let title: String
    public let systemImage: String
    public var isCollapsed: Bool
    public var onToggle: () -> Void
    @ViewBuilder public var controls: Controls

    public init(
        title: String, systemImage: String, isCollapsed: Bool = false, onToggle: @escaping () -> Void,
        @ViewBuilder controls: () -> Controls
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isCollapsed = isCollapsed
        self.onToggle = onToggle
        self.controls = controls()
    }

    public var body: some View {
        HStack(spacing: PanelTheme.controlGap) {
            Button(action: onToggle) {
                Image(systemName: systemImage).font(PanelTheme.caption).frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(isCollapsed ? "Show \(title)" : "Hide \(title)")
            Text(title).font(PanelTheme.panelTitle)
            Spacer(minLength: PanelTheme.rowGap)
            controls
        }
        .padding(.horizontal, PanelTheme.panelInset)
        .frame(height: PanelTheme.barHeight)
        .frame(maxWidth: .infinity)
        .background(PanelTheme.barMaterial)
    }
}

extension PanelHeader where Controls == EmptyView {
    public init(title: String, systemImage: String, isCollapsed: Bool = false, onToggle: @escaping () -> Void) {
        self.init(title: title, systemImage: systemImage, isCollapsed: isCollapsed, onToggle: onToggle) { EmptyView() }
    }
}

/// A collapsed column's place in the window: each panel's symbol over its rotated name, in a strip the
/// width of a rail. Takes a list, so the right column can show both of its panels in one rail when they
/// are both shut.
public struct PanelRail: View {
    public let ids: [PanelID]
    public let layout: PanelLayoutModel

    public init(_ ids: [PanelID], layout: PanelLayoutModel) {
        self.ids = ids
        self.layout = layout
    }

    public var body: some View {
        VStack(spacing: PanelTheme.pageInset) {
            ForEach(ids) { id in
                Button {
                    withAnimation(PanelChromeAnimation.collapse) { layout.setCollapsed(id, false) }
                } label: {
                    VStack(spacing: PanelTheme.sectionGap) {
                        Image(systemName: id.systemImage)
                        // Rotated text reports its *unrotated* bounds to the layout, so the run it needs
                        // is named rather than measured; a longer title truncates instead of overlapping.
                        Text(id.title)
                            .font(PanelTheme.detail)
                            .lineLimit(1)
                            .fixedSize()
                            .rotationEffect(.degrees(90))
                            .frame(width: 14, height: PanelTheme.railTitleRun)
                    }
                }
                .buttonStyle(.borderless)
                .help("Show \(id.title)")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PanelTheme.panelInset)
        .frame(width: PanelTheme.railWidth)
        .frame(maxHeight: .infinity)
        .background(PanelTheme.barMaterial)
    }
}

/// The draggable seam between two panels: a hairline in a hit area wide enough to catch.
///
/// The gesture reads the *global* coordinate space against a base size captured when the drag starts.
/// A local gesture would recompute its translation against a frame that the drag itself is moving, and
/// run away. Every bound lives in `PanelLayoutModel.setSize`, so there is no arithmetic here.
public struct PanelDivider: View {
    public let id: PanelID
    public let layout: PanelLayoutModel
    @State private var base: CGFloat?

    public init(_ id: PanelID, layout: PanelLayoutModel) {
        self.id = id
        self.layout = layout
    }

    private var isDraggable: Bool { !layout.isCollapsed(id) }

    public var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(
                width: id.axis == .horizontal ? PanelTheme.dividerThickness : nil,
                height: id.axis == .vertical ? PanelTheme.dividerThickness : nil
            )
            .overlay(Divider())
            .contentShape(.rect)
            .pointerStyle(isDraggable ? (id.axis == .horizontal ? .columnResize : .rowResize) : nil)
            .gesture(isDraggable ? drag : nil)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = base ?? layout.size(id)
                if base == nil { base = start }
                let moved = id.axis == .horizontal ? value.translation.width : value.translation.height
                layout.setSize(id, start + moved * id.resizeSign)
            }
            .onEnded { _ in base = nil }
    }
}

/// What a panel shows when it has nothing yet: a symbol, a line naming the state, and an optional
/// sentence under it that wraps to the panel's width.
///
/// Not `ContentUnavailableView`: that one has an ideal width of its own and a floor it will not go
/// under, so in a column this narrow its description comes out clipped on both edges rather than
/// wrapped. `fixedSize(horizontal: false, vertical: true)` is what makes the sentence take the width it
/// is offered and only the height it needs.
public struct PanelEmptyState: View {
    public let title: String
    public let systemImage: String
    public var message: String?

    public init(_ title: String, systemImage: String, message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    public var body: some View {
        VStack(spacing: PanelTheme.sectionGap) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(PanelTheme.sectionTitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .font(PanelTheme.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PanelTheme.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// How long a panel takes to fold away. One constant so the header, the rail, and the toolbar agree.
public enum PanelChromeAnimation {
    public static let collapse: Animation = .easeInOut(duration: 0.18)
}

/// A panel: its header over its body when it is open, its rail — or, for a panel stacked inside a
/// column, just its header bar — when it is not. Applies the panel's own size, so no caller writes a
/// frame.
///
/// A stacked panel does not get a rail: a rotated title inside a full-width strip would be nonsense.
public struct PanelChrome<Controls: View, Content: View>: View {
    public let id: PanelID
    public let layout: PanelLayoutModel
    @ViewBuilder public var controls: Controls
    @ViewBuilder public var content: Content

    public init(
        _ id: PanelID, layout: PanelLayoutModel, @ViewBuilder controls: () -> Controls,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.layout = layout
        self.controls = controls()
        self.content = content()
    }

    private func toggle() {
        withAnimation(PanelChromeAnimation.collapse) { layout.toggle(id) }
    }

    public var body: some View {
        if layout.isCollapsed(id) {
            if id.axis == .horizontal {
                PanelRail([id], layout: layout)
            } else {
                PanelHeader(
                    title: id.title, systemImage: id.systemImage, isCollapsed: true, onToggle: { toggle() })
            }
        } else {
            sized
        }
    }

    private var opened: some View {
        VStack(spacing: 0) {
            PanelHeader(title: id.title, systemImage: id.systemImage, onToggle: { toggle() }) { controls }
            Divider()
            // Both a `List` and a `ContentUnavailableView` can end up in here, and the second sizes to
            // its content: without this the panel would shrink to its empty state.
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var sized: some View {
        switch id.axis {
        case .horizontal:
            opened.frame(width: layout.size(id))
        case .vertical:
            if layout.isFlexible(id) {
                opened.frame(maxHeight: .infinity)
            } else {
                opened.frame(height: layout.size(id))
            }
        }
    }
}

extension PanelChrome where Controls == EmptyView {
    public init(_ id: PanelID, layout: PanelLayoutModel, @ViewBuilder content: () -> Content) {
        self.init(id, layout: layout, controls: { EmptyView() }, content: content)
    }
}
