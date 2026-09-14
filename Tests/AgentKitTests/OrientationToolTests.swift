import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import AgentKit

/// What the read side tells an agent about framing. The encoded probe size and the rotated display size
/// are two different facts, and reporting only the first is what let a portrait project be exported
/// landscape without anything noticing.
@Suite struct OrientationToolTests {
    /// A portrait clip shot on a phone: encoded landscape, stood upright by its display matrix. The
    /// numbers are the ones `MediaKitTests.ProbeTests.iphonePortraitHLGProbe` pins against real footage.
    private static func importRotatedPortrait(_ h: ToolTests.Harness) async throws -> Int64 {
        let version = await h.project.version
        let op: JSONValue = [
            "type": "importAsset", "contentHash": "sha256-portrait", "libraryPath": "2026/PHONE_PORTRAIT.MOV",
            "displayName": "PHONE_PORTRAIT.MOV", "kind": "video",
            "duration": try JSONValue(encoding: Fixtures.frames(240)),
            "hasVideo": true, "hasAudio": true,
            "probe": try JSONValue(encoding: Probe(codec: "hvc1", width: 3840, height: 2160, rotation: -90)),
        ]
        let applied = try await h.call(
            "timeline_apply",
            ["expectedVersion": .number(Double(version)), "commandId": "import-portrait", "ops": [op]])
        #expect(!applied.isError, "\(applied)")
        return Int64(try #require(applied.structured?["version"]?.intValue))
    }

    @Test func describeReportsTheRotatedDisplaySizeBesideTheEncodedOne() async throws {
        let h = try await ToolTests.Harness.make()
        _ = try await OrientationToolTests.importRotatedPortrait(h)

        let summary = try await h.call("project_describe", [:])
        let assets = try #require(summary.structured?["assets"]?.arrayValue)
        let portrait = try #require(assets.first { $0["displayName"]?.stringValue == "PHONE_PORTRAIT.MOV" })

        // The encoded size stays, because it is the truth about the file.
        #expect(portrait["size"]?.stringValue == "3840x2160")
        // The display size is the one to frame from, and it is the other way round.
        #expect(portrait["displaySize"]?.stringValue == "2160x3840")
        #expect(portrait["orientation"]?.stringValue == "portrait")
        #expect(portrait["aspect"]?.stringValue == "9:16")
        #expect(portrait["rotation"]?.intValue == -90)

        // An unrotated landscape clip from the fixture reports the same size twice and no rotation key.
        let plain = try #require(assets.first { $0["displayName"]?.stringValue != "PHONE_PORTRAIT.MOV" })
        if plain["size"] != nil {
            #expect(plain["size"] == plain["displaySize"])
            #expect(plain["rotation"] == nil)
        }
    }

    @Test func timelineQueryReportsTheSameAssetFields() async throws {
        let h = try await ToolTests.Harness.make()
        _ = try await OrientationToolTests.importRotatedPortrait(h)
        let found = try await h.call(
            "timeline_query", ["filter": ["kind": "assets", "textContains": "PHONE_PORTRAIT"]])
        #expect(found.structured?["count"]?.intValue == 1)
        let asset = try #require(found.structured?["results"]?[0])
        #expect(asset["displaySize"]?.stringValue == "2160x3840")
        #expect(asset["orientation"]?.stringValue == "portrait")
    }

    @Test func aSequenceReportsItsOrientationAndAspect() async throws {
        let h = try await ToolTests.Harness.make()
        let summary = try await h.call("project_describe", [:])
        let sequence = try #require(summary.structured?["sequences"]?[0])
        #expect(sequence["width"]?.intValue == 1920 && sequence["height"]?.intValue == 1080)
        #expect(sequence["orientation"]?.stringValue == "landscape")
        #expect(sequence["aspect"]?.stringValue == "16:9")
    }

    @Test func aMatchingProjectReportsNoFormatMismatch() async throws {
        let h = try await ToolTests.Harness.make()
        let summary = try await h.call("project_describe", [:])
        #expect(summary.structured?["formatMismatch"] == nil)
        #expect(summary.text?.contains("Format mismatch") != true)
    }

    @Test func resizingTheSequenceRaisesAFormatMismatchNamingTheClipsAndTheBars() async throws {
        let h = try await ToolTests.Harness.make()
        let project = await h.project
        let sequence = try #require(project.activeSequence)
        let version = project.version

        // Stand the sequence on its end without touching the clips, which stay 1920x1080.
        let after = SequenceSettings(
            name: sequence.name, frameDuration: sequence.frameDuration, width: 1080, height: 1920)
        let applied = try await h.call(
            "timeline_apply",
            [
                "expectedVersion": .number(Double(version)), "commandId": "portrait-1",
                "ops": [
                    [
                        "type": "setSequenceSettings", "sequenceId": .string(sequence.id.rawValue),
                        "after": try JSONValue(encoding: after),
                    ]
                ],
            ])
        #expect(!applied.isError, "\(applied)")

        let summary = try await h.call("project_describe", [:])
        let mismatches = try #require(summary.structured?["formatMismatch"]?.arrayValue)
        #expect(mismatches.count == 1)
        let mismatch = try #require(mismatches.first)
        #expect(mismatch["sequenceSize"]?.stringValue == "1080x1920")
        #expect(mismatch["sequenceOrientation"]?.stringValue == "portrait")

        let clips = try #require(mismatch["clips"]?.arrayValue)
        #expect(!clips.isEmpty)
        for clip in clips {
            #expect(clip["orientation"]?.stringValue == "landscape")
            #expect(clip["displaySize"]?.stringValue == "1920x1080")
            // A 16:9 source fitted into a 9:16 frame: 1080 wide, 607 tall, 656 of black above and below.
            #expect(clip["letterboxPixels"]?.intValue == 656)
            #expect(clip["pillarboxPixels"] == nil)
        }

        let note = try #require(mismatch["note"]?.stringValue)
        #expect(note.contains("black bars"))
        #expect(note.contains("setSequenceSettings"))
        // The text summary carries it too, so an agent that reads only the prose still sees it.
        #expect(summary.text?.contains("Format mismatch") == true)
    }

    @Test func aPortraitSequenceHoldingPortraitFootageIsClean() async throws {
        let h = try await ToolTests.Harness.make(fixture: "empty")
        let project = await h.project
        let sequence = try #require(project.activeSequence)
        let after = SequenceSettings(
            name: sequence.name, frameDuration: sequence.frameDuration, width: 2160, height: 3840)
        let applied = try await h.call(
            "timeline_apply",
            [
                "expectedVersion": .number(Double(project.version)), "commandId": "portrait-empty",
                "ops": [
                    [
                        "type": "setSequenceSettings", "sequenceId": .string(sequence.id.rawValue),
                        "after": try JSONValue(encoding: after),
                    ]
                ],
            ])
        #expect(!applied.isError, "\(applied)")
        let summary = try await h.call("project_describe", [:])
        #expect(summary.structured?["formatMismatch"] == nil, "an empty portrait sequence has nothing to mismatch")
        let described = try #require(summary.structured?["sequences"]?[0])
        #expect(described["orientation"]?.stringValue == "portrait")
        #expect(described["aspect"]?.stringValue == "9:16")
    }
}
