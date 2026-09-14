import Foundation
import SwiftUI
import Testing
import TimelineCore

@testable import TimelineUI

@Suite("Panel theme")
struct StyleTests {
    @Test func theSpacingScaleIsTheOneTheDocNames() {
        #expect(PanelTheme.hairGap == 2)
        #expect(PanelTheme.rowGap == 4)
        #expect(PanelTheme.controlGap == 6)
        #expect(PanelTheme.sectionGap == 8)
        #expect(PanelTheme.panelInset == 8)
        #expect(PanelTheme.cardInset == 12)
        #expect(PanelTheme.pageInset == 16)

        #expect(PanelTheme.barInsetV == 5)
    }

    @Test func theRadiiAndPanelMetricsAreTheOnesTheDocNames() {
        #expect(PanelTheme.posterRadius == 3)
        #expect(PanelTheme.chipRadius == 6)
        #expect(PanelTheme.bubbleRadius == 8)
        #expect(PanelTheme.cardRadius == 10)
        #expect(PanelTheme.barHeight == 28)
        #expect(PanelTheme.railWidth == 32)
        #expect(PanelTheme.dividerThickness == 8)
        #expect(PanelTheme.centreMinimum == 480)
        #expect(PanelTheme.sheetWidth == 420)
        #expect(PanelTheme.formSheetWidth == 520)
        #expect(PanelTheme.framePreviewHeight == 180)
        #expect(PanelTheme.numberFieldWidth == 72)
    }

    /// The preview's guide draws over a surface that is black in either appearance, so its stroke and
    /// its surround are fixed hues like `letterboxFill` rather than semantic ones. Asserted so the
    /// exception stays a deliberate one (`docs/design/ui-style.md`, Colour and material).
    @Test func theFrameGuideTokensAreTheOnesTheDocNames() {
        #expect(PanelTheme.frameGuideWidth == 1.5)
        let environment = EnvironmentValues()
        let stroke = PanelTheme.frameGuideStroke.resolve(in: environment)
        #expect(abs(stroke.opacity - 0.85) < 0.01)
        let surround = PanelTheme.frameGuideSurround.resolve(in: environment)
        #expect(abs(surround.opacity - 0.1) < 0.01)
        #expect(surround.red == stroke.red)
    }

    /// The two places the chrome and the Metal canvas have to agree. Asserted here so a change to
    /// either side has to be a deliberate change to both; see `docs/design/ui-style.md`.
    @Test func theChromeAndTheTimelineAgreeWhereTheyMust() {
        #expect(PanelTheme.posterRadius == TimelineTheme.controlCornerRadius)
        let layout = TimelineLayout(
            size: CGSize(width: 100, height: 100), secondsPerPoint: 1, scrollSeconds: 0, tracks: [])
        #expect(PanelTheme.barHeight == layout.rulerHeight)
    }

    /// The bridge reads a scene colour as sRGB, because that is what the unmanaged BGRA8 write shows.
    @Test func theSceneColourBridgeKeepsItsChannels() {
        let resolved = PanelTheme.color(SceneColor(0.25, 0.5, 0.75, 0.5)).resolve(in: EnvironmentValues())
        #expect(abs(resolved.red - 0.25) < 0.01)
        #expect(abs(resolved.green - 0.5) < 0.01)
        #expect(abs(resolved.blue - 0.75) < 0.01)
        #expect(abs(resolved.opacity - 0.5) < 0.01)
    }
}

@Suite("Actor label")
struct ActorLabelTests {
    /// Both halves, so nobody later "helpfully" unifies them: the window says Assistant, the wire says
    /// agent, and `Actor.init(_:)` has to keep parsing what `description` writes.
    @Test func theWindowSaysAssistantAndTheWireStillSaysAgent() {
        let actor = Actor.agent(sessionId: "s1")
        #expect(ActorLabel.text(actor) == "Assistant")
        #expect(ActorLabel.text(.human) == "You")
        #expect(ActorLabel.text(.system) == "System")

        #expect(actor.description == "agent:s1")
        #expect(Actor(actor.description) == actor)
        #expect(ActorLabel.detail(actor) == "Assistant session s1")
        #expect(ActorLabel.detail(.human) == nil)
    }
}
