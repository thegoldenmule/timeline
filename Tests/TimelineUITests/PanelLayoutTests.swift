import CoreGraphics
import Foundation
import Testing

@testable import TimelineUI

/// Runs `body` against a `UserDefaults` suite of its own, so a test never reads or writes the user's
/// real preferences and two tests never see each other's keys.
func withPanelDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "panel-layout-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    try body(defaults)
}

@MainActor
@Suite("Panel layout")
struct PanelLayoutTests {
    /// What the columns and the centre occupy together, dividers included.
    private func occupiedWidth(_ model: PanelLayoutModel) -> CGFloat {
        PanelID.columns.reduce(PanelTheme.centreMinimum) {
            $0 + model.renderedWidth($1) + PanelTheme.dividerThickness
        }
    }

    @Test func aFreshModelIsEveryPanelOpenAtItsDefault() {
        withPanelDefaults { defaults in
            let model = PanelLayoutModel(defaults: defaults)
            for id in PanelID.allCases {
                #expect(!model.isCollapsed(id))
                #expect(model.size(id) == id.defaultSize)
            }
        }
    }

    @Test func sizesAndFlagsSurviveANewModelOverTheSameDefaults() {
        withPanelDefaults { defaults in
            let first = PanelLayoutModel(defaults: defaults)
            first.availableWidthChanged(2400)
            first.setSize(.assistant, 420)
            first.setCollapsed(.library, true)

            let second = PanelLayoutModel(defaults: defaults)
            #expect(second.size(.assistant) == 420)
            #expect(second.isCollapsed(.library))
            #expect(!second.isCollapsed(.assistant))
        }
    }

    @Test func aSizeIsClampedToThePanelsOwnBounds() {
        withPanelDefaults { defaults in
            let model = PanelLayoutModel(defaults: defaults)
            // No width reported yet, so only the panel's own min and max apply.
            model.setSize(.library, 10)
            #expect(model.size(.library) == PanelID.library.minSize)
            model.setSize(.library, 9_000)
            #expect(model.size(.library) == PanelID.library.maxSize)
        }
    }

    /// The bug the split view used to make possible: a pane growing until the timeline had nowhere left.
    @Test func aPanelCannotGrowPastWhatTheCentreNeeds() {
        withPanelDefaults { defaults in
            let model = PanelLayoutModel(defaults: defaults)
            model.availableWidthChanged(1600)
            model.setSize(.assistant, 9_000)
            #expect(model.size(.assistant) < PanelID.assistant.maxSize)
            #expect(occupiedWidth(model) <= 1600)
        }
    }

    @Test func shrinkingTheWindowPullsEveryColumnBackIn() {
        withPanelDefaults { defaults in
            let model = PanelLayoutModel(defaults: defaults)
            model.availableWidthChanged(2400)
            for id in PanelID.columns { model.setSize(id, 9_000) }
            #expect(occupiedWidth(model) <= 2400)

            model.availableWidthChanged(1600)
            #expect(occupiedWidth(model) <= 1600)
            for id in PanelID.columns { #expect(model.size(id) >= id.minSize) }
        }
    }

    @Test func aContainerIsCollapsedOnlyWhenBothItsPanelsAre() {
        withPanelDefaults { defaults in
            let model = PanelLayoutModel(defaults: defaults)
            #expect(!model.isCollapsed(.rightColumn))
            model.setCollapsed(.inspector, true)
            #expect(!model.isCollapsed(.rightColumn))
            model.setCollapsed(.activity, true)
            #expect(model.isCollapsed(.rightColumn))

            model.setCollapsed(.rightColumn, false)
            #expect(!model.isCollapsed(.inspector))
            #expect(!model.isCollapsed(.activity))
        }
    }

    @Test func theInspectorTakesOverAsTheFlexiblePanelWhenActivityCollapses() {
        withPanelDefaults { defaults in
            let model = PanelLayoutModel(defaults: defaults)
            #expect(model.isFlexible(.activity))
            #expect(!model.isFlexible(.inspector))

            model.setCollapsed(.activity, true)
            #expect(!model.isFlexible(.activity))
            #expect(model.isFlexible(.inspector))

            // Both shut: the column is a rail and nothing needs to stretch.
            model.setCollapsed(.inspector, true)
            #expect(!model.isFlexible(.inspector))
        }
    }

    @Test func aCollapsedPanelOccupiesExactlyItsRailOrItsHeader() {
        withPanelDefaults { defaults in
            let model = PanelLayoutModel(defaults: defaults)
            model.setCollapsed(.library, true)
            #expect(model.renderedWidth(.library) == PanelTheme.railWidth)
            model.setCollapsed(.library, false)
            #expect(model.renderedWidth(.library) == model.size(.library))

            model.setCollapsed(.inspector, true)
            #expect(model.renderedWidth(.inspector) == PanelTheme.barHeight)
        }
    }

    @Test func collapsingAPanelLetsTheWindowGetNarrower() {
        withPanelDefaults { defaults in
            let model = PanelLayoutModel(defaults: defaults)
            let open = model.minimumWindowWidth
            #expect(
                open
                    == PanelID.columns.reduce(PanelTheme.centreMinimum) {
                        $0 + $1.minSize + PanelTheme.dividerThickness
                    })

            model.setCollapsed(.assistant, true)
            #expect(model.minimumWindowWidth == open - (PanelID.assistant.minSize - PanelTheme.railWidth))

            for id in PanelID.panels { model.setCollapsed(id, true) }
            #expect(
                model.minimumWindowWidth
                    == PanelTheme.centreMinimum + 3 * (PanelTheme.railWidth + PanelTheme.dividerThickness))
        }
    }

    @Test func aStackedPanelCannotSqueezeItsSibling() {
        withPanelDefaults { defaults in
            let model = PanelLayoutModel(defaults: defaults)
            model.availableHeightChanged(800)
            model.setSize(.inspector, 9_000)
            let left = 800 - model.size(.inspector) - PanelTheme.dividerThickness
            #expect(left >= PanelID.activity.minSize)
        }
    }

    @Test func theLibrarysOldHiddenFlagBecomesACollapsedPanel() {
        withPanelDefaults { defaults in
            defaults.set(false, forKey: PanelLayoutModel.legacyLibraryKey)
            #expect(PanelLayoutModel(defaults: defaults).isCollapsed(.library))
        }
        withPanelDefaults { defaults in
            defaults.set(true, forKey: PanelLayoutModel.legacyLibraryKey)
            #expect(!PanelLayoutModel(defaults: defaults).isCollapsed(.library))
        }
        // The new key wins: once a panel has been toggled, the legacy flag is inert.
        withPanelDefaults { defaults in
            defaults.set(false, forKey: PanelLayoutModel.legacyLibraryKey)
            defaults.set(false, forKey: PanelID.library.collapsedKey)
            #expect(!PanelLayoutModel(defaults: defaults).isCollapsed(.library))
        }
    }
}
