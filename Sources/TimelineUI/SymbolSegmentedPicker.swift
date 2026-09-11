import AppKit
import Foundation
import SwiftUI

/// A symbols-only segmented control that carries a tooltip on every segment.
///
/// SwiftUI's `Picker(.segmented)` draws one of these but offers no way to put a tooltip on an
/// individual segment — `.help` on the item is dropped — and an icon with no name beside it needs one.
/// AppKit has `setToolTip(_:forSegment:)`, so this is the thin wrapper that reaches it.
public struct SymbolSegmentedPicker<Value: Hashable & Sendable>: NSViewRepresentable {
    /// One segment: what it selects, the symbol it draws, and the name that its tooltip and
    /// VoiceOver both use.
    public struct Item: Sendable {
        public var value: Value
        public var symbolName: String
        public var title: String

        public init(value: Value, symbolName: String, title: String) {
            self.value = value
            self.symbolName = symbolName
            self.title = title
        }
    }

    @Binding public var selection: Value
    public let items: [Item]

    public init(selection: Binding<Value>, items: [Item]) {
        self._selection = selection
        self.items = items
    }

    public func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        control.controlSize = .small
        control.segmentCount = items.count
        control.target = context.coordinator
        control.action = #selector(Coordinator.segmentChanged(_:))
        apply(to: control)
        return control
    }

    public func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        apply(to: control)
    }

    private func apply(to control: NSSegmentedControl) {
        if control.segmentCount != items.count { control.segmentCount = items.count }
        for (index, item) in items.enumerated() {
            control.setImage(
                NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title),
                forSegment: index)
            control.setToolTip(item.title, forSegment: index)
        }
        let selected = items.firstIndex { $0.value == selection } ?? -1
        if control.selectedSegment != selected { control.selectedSegment = selected }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    public final class Coordinator: NSObject {
        var parent: SymbolSegmentedPicker

        init(_ parent: SymbolSegmentedPicker) {
            self.parent = parent
        }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard parent.items.indices.contains(index) else { return }
            parent.selection = parent.items[index].value
        }
    }
}
