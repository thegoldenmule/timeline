import Contracts
import ContractsTestSupport
import CoreGraphics
import Foundation
import Testing
import TimelineCore

@testable import TimelineUI

@MainActor
@Suite("Sequence format")
struct SequenceFormatTests {
    private static func clip(_ name: String, _ width: Int, _ height: Int, id: ClipID = "clip-1")
        -> FormatMismatch.ClipSize
    {
        FormatMismatch.ClipSize(clipId: id, assetName: name, size: FrameSize(width: width, height: height))
    }

    // MARK: The mismatch

    /// The number the whole feature turns on: a 16:9 source in a 9:16 frame loses 656 px top and
    /// bottom. `AgentKitTests.OrientationToolTests` asserts the same 656 on the tool side, so the two
    /// halves of the app cannot quietly disagree about what the compositor does.
    @Test func aLandscapeClipInAPortraitFrameIsLetterboxedBySixHundredAndFiftySix() {
        let mismatch = FormatMismatch(
            sequenceSize: FrameSize(width: 1080, height: 1920),
            clips: [SequenceFormatTests.clip("wide.mov", 1920, 1080)])
        #expect(!mismatch.isClean)
        let worst = try? #require(mismatch.worst)
        #expect(worst?.bars == .letterbox(656.25))
        #expect(worst?.barsDescription == ExportText.letterboxed(656))
    }

    /// The user's own case: portrait footage in the landscape frame every project is created in.
    @Test func aPortraitClipInALandscapeFrameIsPillarboxed() {
        let mismatch = FormatMismatch(
            sequenceSize: FrameSize(width: 1920, height: 1080),
            clips: [SequenceFormatTests.clip("IMG_1575.MOV", 2160, 3840)])
        #expect(!mismatch.isClean)
        let worst = try? #require(mismatch.worst)
        // A 9:16 source fitted into 16:9: 607.5 wide, so 656 px of black down each side.
        #expect(worst?.bars == .pillarbox(656.25))
        #expect(worst?.barsDescription == ExportText.pillarboxed(656))
        #expect(mismatch.suggestedSize == FrameSize(width: 2160, height: 3840))
        #expect(mismatch.suggestedSource == "IMG_1575.MOV")
        #expect(mismatch.advice?.contains("2160x3840") == true)
    }

    @Test func matchingShapesAreClean() {
        let mismatch = FormatMismatch(
            sequenceSize: FrameSize(width: 1920, height: 1080),
            clips: [
                SequenceFormatTests.clip("a.mov", 1920, 1080),
                SequenceFormatTests.clip("b.mov", 3840, 2160, id: "clip-2"),
            ])
        #expect(mismatch.isClean)
        #expect(mismatch.worst == nil)
        #expect(mismatch.summary.contains("fills the frame"))
    }

    /// A shape is what agrees, not a pixel count, and the suggestion keeps the largest so matching
    /// never throws resolution away.
    @Test func theSuggestionFollowsTheShapeAndKeepsTheLargestFrame() {
        let mismatch = FormatMismatch(
            sequenceSize: FrameSize(width: 1920, height: 1080),
            clips: [
                SequenceFormatTests.clip("small.mov", 1080, 1920),
                SequenceFormatTests.clip("big.mov", 2160, 3840, id: "clip-2"),
            ])
        #expect(mismatch.suggestedSize == FrameSize(width: 2160, height: 3840))
    }

    /// Two different shapes have no single answer, so the sheet must not invent one.
    @Test func clipsOfTwoShapesSuggestNothing() {
        let mismatch = FormatMismatch(
            sequenceSize: FrameSize(width: 1920, height: 1080),
            clips: [
                SequenceFormatTests.clip("portrait.mov", 1080, 1920),
                SequenceFormatTests.clip("square.mov", 1080, 1080, id: "clip-2"),
            ])
        #expect(mismatch.suggestedSize == nil)
        #expect(mismatch.advice?.contains("not all one shape") == true)
    }

    @Test func anEmptySequenceHasNothingToJudge() {
        let mismatch = FormatMismatch(sequenceSize: FrameSize(width: 1920, height: 1080), clips: [])
        #expect(mismatch.isClean)
        #expect(mismatch.isEmpty)
        #expect(mismatch.advice == nil)
        #expect(mismatch.summary == "1920x1080 · 16:9")
    }

    /// The rotation rule, end to end through the asset: the encoded probe is landscape and the clip is
    /// not. Reading `probe.width` here instead of `displaySize` is how a portrait project stays
    /// landscape without anything noticing.
    @Test func aRotatedAssetIsJudgedByItsDisplaySize() async throws {
        let f = try await UIFixture.make("three-clips")
        let sequence = f.sequence
        let rotated = Asset(
            id: "rot", contentHash: "sha256-rot", libraryPath: "IMG.MOV", displayName: "IMG.MOV", kind: .video,
            duration: Fixtures.frames(240), hasVideo: true, hasAudio: false,
            probe: Probe(width: 3840, height: 2160, rotation: -90))
        #expect(rotated.displaySize == FrameSize(width: 2160, height: 3840))
        #expect(rotated.orientation == .portrait)

        var assets = f.viewModel.project.assets
        assets[rotated.id] = rotated
        // Every video clip in the fixture points at a landscape asset; the mismatch is read from the
        // assets the clips actually use, so an unused rotated asset changes nothing.
        let mismatch = FormatMismatch(sequence: sequence, assets: assets)
        #expect(mismatch.isClean)
    }

    // MARK: The draft

    @Test func theDraftOpensOnTheRowThatDescribesTheSequence() async throws {
        let f = try await UIFixture.make("three-clips")
        let draft = SequenceFormat(sequence: f.sequence, assets: f.viewModel.project.assets)
        #expect(draft.selection == .preset("Landscape HD"))
        #expect(draft.size == FrameSize(width: 1920, height: 1080))
        #expect(draft.isUnchanged)
        #expect(draft.operation == nil, "an unchanged format sends nothing")
        #expect(draft.canSubmit, "Return on a sheet opened by mistake closes it")
    }

    @Test func aPresetChangesTheFrameAndMakesAnOperation() async throws {
        let f = try await UIFixture.make("three-clips")
        var draft = SequenceFormat(sequence: f.sequence, assets: f.viewModel.project.assets)
        draft.selection = .preset("Portrait HD")
        #expect(draft.size == FrameSize(width: 1080, height: 1920))
        #expect(!draft.isUnchanged)
        #expect(draft.after.width == 1080 && draft.after.height == 1920)
        #expect(draft.after.name == draft.current.name, "a format change is not a rename")
        #expect(draft.after.frameDuration == draft.current.frameDuration)
        #expect(draft.operation != nil)
    }

    @Test func customDimensionsAreValidated() async throws {
        let f = try await UIFixture.make("three-clips")
        var draft = SequenceFormat(sequence: f.sequence, assets: f.viewModel.project.assets)
        draft.selection = .custom

        draft.customWidth = 0
        #expect(draft.validationError != nil)
        #expect(draft.operation == nil)

        draft.customWidth = -1920
        #expect(draft.validationError != nil)

        draft.customWidth = SequenceFormat.maximumDimension + 2
        #expect(draft.validationError != nil)

        draft.customWidth = 1081
        draft.customHeight = 1920
        #expect(draft.validationError == SequenceFormatText.evenDimensions)

        draft.customWidth = 1080
        #expect(draft.validationError == nil)
        #expect(draft.operation != nil)
    }

    @Test func matchMediaFollowsTheFootageAndIsRecommendedOnlyWhenItDisagrees() async throws {
        let f = try await UIFixture.make("three-clips")
        let assets = f.viewModel.project.assets

        // The fixture's footage is landscape and so is its sequence: nothing to match.
        let matching = SequenceFormat(sequence: f.sequence, assets: assets)
        #expect(!matching.canMatchMedia)
        #expect(!matching.recommendsMatchMedia)

        // Stand the sequence on its end and the same clips now want their own frame back.
        var portrait = f.sequence
        portrait.width = 1080
        portrait.height = 1920
        var draft = SequenceFormat(sequence: portrait, assets: assets)
        #expect(draft.canMatchMedia)
        #expect(draft.recommendsMatchMedia)
        draft.selection = .matchMedia
        #expect(draft.size == FrameSize(width: 1920, height: 1080))
        #expect(draft.resultingMismatch.isClean, "matching is the fix, and the sheet can show that")
    }

    /// The core refuses a frame-rate change once a frame-aligned track holds clips
    /// (`Decide.setSequenceSettings`). The sheet reads the same condition rather than restating it.
    @Test func theFrameRateIsLockedExactlyWhenTheCoreWouldRefuseIt() async throws {
        let populated = try await UIFixture.make("three-clips")
        let withClips = SequenceFormat(
            sequence: populated.sequence, assets: populated.viewModel.project.assets)
        #expect(!withClips.canChangeFrameRate)
        #expect(withClips.frameDuration == withClips.current.frameDuration, "a locked rate cannot be sent")

        let empty = try await UIFixture.make("empty")
        let blank = SequenceFormat(sequence: empty.sequence, assets: empty.viewModel.project.assets)
        #expect(blank.canChangeFrameRate)
    }

    @Test func aChosenRateBecomesAFrameDuration() async throws {
        let f = try await UIFixture.make("empty")
        var draft = SequenceFormat(sequence: f.sequence, assets: f.viewModel.project.assets)
        #expect(draft.canChangeFrameRate)
        draft.rate = Rational(24000, 1001)
        #expect(draft.frameDuration == RationalTime(1001, 24000))
        draft.rate = Rational(25, 1)
        #expect(draft.frameDuration == RationalTime(1, 25))
    }

    // MARK: Through the store

    @Test func applyingTheDraftResizesTheSequenceInOneUndoableTransaction() async throws {
        let f = try await UIFixture.make("three-clips")
        let before = f.sequence.frameSize
        let clipsBefore = f.clips()
        var draft = SequenceFormat(sequence: f.sequence, assets: f.viewModel.project.assets)
        draft.selection = .preset("Portrait HD")
        let live = f.viewModel.history.live.count

        let result = await f.viewModel.apply(try #require(draft.operation))
        #expect(result?.status == .applied)
        #expect(f.sequence.frameSize == FrameSize(width: 1080, height: 1920))
        #expect(f.viewModel.history.live.count == live + 1)
        #expect(f.viewModel.lastError == nil)
        #expect(f.clips().count == clipsBefore.count, "a resize rewrites no clip")
        #expect(f.clips().map(\.start) == clipsBefore.map(\.start))

        #expect(await f.viewModel.undo()?.status == .applied)
        #expect(f.sequence.frameSize == before)
    }

    // MARK: The frame menu

    /// The rows the preview's control and the status bar's control both render.
    @Test func theFrameMenuLeadsWithMatchingTheFootageWhenTheFrameDoesNotFitIt() {
        let mismatch = FormatMismatch(
            sequenceSize: FrameSize(width: 1920, height: 1080),
            clips: [SequenceFormatTests.clip("IMG_1575.MOV", 2160, 3840)])
        let choices = FrameChoices(mismatch: mismatch)
        #expect(choices.hasMismatch)
        #expect(choices.current == FrameSize(width: 1920, height: 1080))
        #expect(choices.label == "1920x1080 · 16:9")

        let first = choices.rows.first
        #expect(first?.kind == .matchFootage)
        #expect(first?.isRecommended == true)
        #expect(first?.size == FrameSize(width: 2160, height: 3840))
        #expect(first?.title.contains("IMG_1575.MOV") == true)

        // The five presets, with the one the project is already in marked, and Custom last.
        #expect(choices.rows.filter { $0.kind == .preset }.count == SequenceFormatPreset.builtIn.count)
        #expect(choices.rows.filter(\.isCurrent).map(\.title) == ["Landscape HD — 1920x1080, 16:9"])
        #expect(choices.rows.last?.kind == .custom)
        #expect(choices.rows.last?.size == nil)
    }

    @Test func theFrameMenuOffersNoMatchRowWhenTheFootageAlreadyFits() {
        let choices = FrameChoices(
            mismatch: FormatMismatch(
                sequenceSize: FrameSize(width: 1080, height: 1920),
                clips: [SequenceFormatTests.clip("a.mov", 1080, 1920)]))
        #expect(!choices.hasMismatch)
        #expect(!choices.rows.contains { $0.kind == .matchFootage })
        #expect(choices.rows.allSatisfy { !$0.isRecommended })
        #expect(choices.rows.first?.kind == .preset)
        #expect(choices.help.contains("1080x1920"))
    }

    /// Footage of two shapes has no single right answer, so the menu offers presets and Custom and
    /// nothing else — the same reason `autoMatch` declines below.
    @Test func theFrameMenuOffersNoMatchRowForMixedFootage() {
        let choices = FrameChoices(
            mismatch: FormatMismatch(
                sequenceSize: FrameSize(width: 1920, height: 1080),
                clips: [
                    SequenceFormatTests.clip("portrait.mov", 1080, 1920),
                    SequenceFormatTests.clip("square.mov", 1080, 1080, id: "clip-2"),
                ]))
        #expect(choices.hasMismatch)
        #expect(!choices.rows.contains { $0.kind == .matchFootage })
    }

    // MARK: Framing the project by itself

    /// A history with one frame change in it, which is what "the user has already framed this" looks
    /// like once the window has been closed and reopened.
    private static func framedHistory() -> History {
        let settings = SequenceSettings(
            name: "Sequence 1", frameDuration: RationalTime(1, 30), width: 1080, height: 1920)
        let event = DomainEvent(
            eventId: "evt-1", txnId: "txn-1", commandId: "cmd-1", actor: .human,
            occurredAt: Date(timeIntervalSince1970: 0),
            payload: .sequenceSettingsChanged(
                .init(sequenceId: "seq-1", before: settings, after: settings)))
        return History(
            transactions: [
                Transaction(
                    id: "txn-1", actor: .human, label: SequenceFormatText.changeLabel, kind: .edit,
                    events: [event])
            ])
    }

    /// Portrait footage landing in a project still at the 1920x1080 creation default: the app sets the
    /// frame rather than offering to. This replaces the dismissible status-bar offer, on the user's own
    /// judgement (`docs/plans/frame-at-edit-time.md`, 4).
    @Test func theFirstImportFramesAProjectNobodyHasFramed() async throws {
        let f = try await UIFixture.make("three-clips")
        let portraitAssets = SequenceFormatTests.standingOnEnd(f.viewModel.project.assets)
        let format = try #require(
            SequenceFormat.autoMatch(
                sequence: f.sequence, assets: portraitAssets, history: f.viewModel.history))
        #expect(format.selection == .matchMedia)
        #expect(format.size == FrameSize(width: 1080, height: 1920))
        #expect(format.resultingMismatch.isClean)
        #expect(format.operation != nil)

        // What the status bar then says: the frame, the clip it followed, and what undo gives back.
        let note = SequenceFormatText.matched(
            format.size, source: format.matchMediaSource, restoring: f.sequence.frameSize)
        #expect(note.contains("1080x1920"))
        #expect(note.contains("1920x1080"))
        #expect(note.lowercased().contains("undo"))
        #expect(!note.lowercased().contains("sequence"))
    }

    /// The four ways the app is told to keep its hands off.
    @Test func itNeverFramesAProjectSomebodyHasAlreadyFramed() async throws {
        let f = try await UIFixture.make("three-clips")
        let portraitAssets = SequenceFormatTests.standingOnEnd(f.viewModel.project.assets)

        // 1. The frame is not the creation default any more, so a decision has been made.
        var moved = f.sequence
        moved.width = 1080
        moved.height = 1350
        #expect(
            SequenceFormat.autoMatch(sequence: moved, assets: portraitAssets, history: f.viewModel.history)
                == nil)

        // 2. The history already holds a frame change — the durable form of "they have set one". This is
        //    also the undo case: the change stays in the log after it is undone, so it is not remade.
        #expect(
            SequenceFormat.autoMatch(
                sequence: f.sequence, assets: portraitAssets, history: SequenceFormatTests.framedHistory())
                == nil)

        // 3. The footage does not agree on one shape, so there is nothing to match.
        var mixed = portraitAssets
        if let id = mixed.keys.sorted(by: { $0.rawValue < $1.rawValue }).first {
            mixed[id] = SequenceFormatTests.resized(mixed[id]!, 1080, 1080)
        }
        #expect(
            SequenceFormat.autoMatch(sequence: f.sequence, assets: mixed, history: f.viewModel.history) == nil)

        // 4. The footage already fills the frame the project is in.
        #expect(
            SequenceFormat.autoMatch(
                sequence: f.sequence, assets: f.viewModel.project.assets, history: f.viewModel.history) == nil)
    }

    /// Stands every video asset on its end, keeping the probe honest about rotation so the display size
    /// is the only thing that answers.
    private static func standingOnEnd(_ assets: [AssetID: Asset]) -> [AssetID: Asset] {
        assets.mapValues { asset in
            guard asset.hasVideo else { return asset }
            return resized(asset, 1080, 1920)
        }
    }

    private static func resized(_ asset: Asset, _ width: Int, _ height: Int) -> Asset {
        var probe = asset.probe
        probe.width = width
        probe.height = height
        probe.rotation = 0
        var copy = asset
        copy.probe = probe
        return copy
    }

    // MARK: The vocabulary

    /// The user's first complaint, as a test: "sequence" is the model's word and must not reach anything
    /// a person reads. The copy enums are public for exactly this reason — a test can hold them.
    @Test func noCopyAUserReadsSaysSequence() {
        var copy: [String] = [
            SequenceFormatText.title, SequenceFormatText.frame, SequenceFormatText.width,
            SequenceFormatText.height, SequenceFormatText.frameRate, SequenceFormatText.apply,
            SequenceFormatText.cancel, SequenceFormatText.custom, SequenceFormatText.matchMedia,
            SequenceFormatText.change, SequenceFormatText.changeLabel, SequenceFormatText.matchLabel,
            SequenceFormatText.note, SequenceFormatText.captionNote, SequenceFormatText.rateLocked,
            SequenceFormatText.evenDimensions, SequenceFormatText.dimensionRange(16, 8192),
            SequenceFormatText.matchMediaLabel(FrameSize(width: 1080, height: 1920), source: "a.mov"),
            SequenceFormatText.matched(
                FrameSize(width: 1080, height: 1920), source: "a.mov",
                restoring: FrameSize(width: 1920, height: 1080)),
            SequenceFormatText.frameHelp(FrameSize(width: 1080, height: 1920), mismatched: true),
            ExportText.title, ExportText.preset, ExportText.size, ExportText.custom, ExportText.width,
            ExportText.height, ExportText.frameRate, ExportText.destination, ExportText.choose,
            ExportText.export, ExportText.cancel, ExportText.fillsFrame, ExportText.projectFrame,
            ExportText.projectRate, ExportText.fitNote, ExportText.changeFrame, ExportText.letterboxBadge,
            ExportText.pillarboxBadge, ExportText.evenDimensions, ExportText.noDestination,
            ExportText.letterboxed(656), ExportText.pillarboxed(656), ExportText.dimensionRange(16, 8192),
            ExportText.boxedTwice("a.mov", "1080x1920", "1920x1080", "1080 × 1920"),
            ExportText.frameMismatch("a.mov", "1080x1920", "1920x1080", "pillarboxed"),
            FrameGuideText.show, FrameGuideText.hide, FrameGuideText.help,
            ExportDraft.matchSequence.name,
        ]
        copy += SequenceFormatPreset.builtIn.map(\.label)
        let mismatch = FormatMismatch(
            sequenceSize: FrameSize(width: 1920, height: 1080),
            clips: [SequenceFormatTests.clip("IMG.MOV", 1080, 1920)])
        copy += [mismatch.summary, mismatch.advice ?? "", FrameChoices(mismatch: mismatch).help]
        copy += FrameChoices(mismatch: mismatch).rows.map(\.title)
        copy += [
            ExportFraming(output: CGSize(width: 1080, height: 1920), sequence: CGSize(width: 1920, height: 1080))
                .summary,
            ExportFraming(output: CGSize(width: 1920, height: 1080), sequence: CGSize(width: 1920, height: 1080))
                .summary,
        ]
        for text in copy {
            #expect(!text.lowercased().contains("sequence"), "user-facing copy says sequence: \(text)")
        }
    }

    @Test func aRefusedFormatLeavesTheSequenceAlone() async throws {
        let f = try await UIFixture.make("three-clips")
        let before = f.sequence.frameSize
        // A frame-rate change with clips present is the one the core refuses.
        let refused = Command.Operation.setSequenceSettings(
            .init(
                sequenceId: .id(f.sequence.id),
                after: SequenceSettings(
                    name: f.sequence.name, frameDuration: RationalTime(1, 25), width: 1080, height: 1920)))
        #expect(await f.viewModel.apply(refused) == nil)
        #expect(f.viewModel.lastError != nil)
        #expect(f.sequence.frameSize == before)
    }
}
