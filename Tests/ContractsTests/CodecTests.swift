import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try ProjectCodec.encode(value)
    let back = try ProjectCodec.decode(T.self, from: data)
    #expect(back == value)
    #expect(try ProjectCodec.encode(back) == data)
    return back
}

@Suite struct ContractsCodecTests {
    @Test(arguments: ExportPreset.builtIn) func exportPreset(_ preset: ExportPreset) throws {
        _ = try roundTrip(preset)
    }

    @Test func exportPresetJSONShape() throws {
        let json = try JSONValue(encoding: ExportPreset.reel9x16)
        #expect(json["videoCodec"] == "h264")
        #expect(json["size"]?["fixed"]?["width"] == 1080)
        #expect(json["loudnessTargetLUFS"] == -14)
        #expect(json["frameRate"]?["matchSequence"] != nil)
    }

    @Test func alignment() throws {
        _ = try roundTrip(Alignment.fixture)
        _ = try roundTrip(Alignment.failedFixture)
    }

    @Test func transcriptAndAnalyses() throws {
        _ = try roundTrip(Fixtures.transcript)
        _ = try roundTrip(Fixtures.silence)
        _ = try roundTrip(Fixtures.shots)
        _ = try roundTrip(Fixtures.onsetEnvelope)
        let key = try AnalysisCacheKey.make(
            contentHash: "sha256-abc", kind: .transcript, version: 1, parameters: TranscriptionOptions())
        #expect(key.hasPrefix("sha256-abc/transcript/v1-"))
        #expect(
            try key
                == AnalysisCacheKey.make(
                    contentHash: "sha256-abc", kind: .transcript, version: 1, parameters: TranscriptionOptions()))
    }

    @Test func commandResultEncodesSortedChangedIds() throws {
        let result = CommandResult(
            commandId: "command-1", txnId: "txn-1", status: .applied, version: 12, firstSeq: 11, lastSeq: 12,
            changedIds: ["clip-2", "clip-1"], warnings: ["offline asset"])
        let back = try roundTrip(result)
        #expect(back.replayed.status == .replayed)
        let json = String(decoding: try ProjectCodec.encode(result), as: UTF8.self)
        #expect(json.contains("\"changedIds\":[\"clip-1\",\"clip-2\"]"))
        _ = try roundTrip(CommandResult(commandId: "command-2", status: .noop, version: 12))
    }

    @Test func projectChange() throws {
        let change = ProjectChange(
            txnId: "txn-1", version: 3, changedIds: ["b", "a"], actor: .agent(sessionId: "s1"), label: "Trim clip",
            kind: .edit)
        _ = try roundTrip(change)
        let json = try JSONValue(encoding: change)
        #expect(json["actor"] == "agent:s1")
        #expect(json["changedIds"] == ["a", "b"])
    }

    @Test func progressAndOutcome() throws {
        _ = try roundTrip(JobProgress(fraction: 0.25, message: "encoding", stage: "video", etaSeconds: 12))
        _ = try roundTrip(JobProgress.indeterminate)
        _ = try roundTrip(JobOutcome(urls: [URL(fileURLWithPath: "/tmp/x.mp4")], payload: ["n": 1], warnings: []))
        _ = try roundTrip(StoredEvent(seq: 5, streamVersion: 5, event: ProjectFixtures.exampleEvents()["ClipTrimmed"]!))
    }

    @Test func approvalsAndReceipts() throws {
        let request = Fixtures.approvalRequest()
        _ = try roundTrip(request)
        _ = try roundTrip(ApprovalPolicy.standard)
        let output = ToolOutput.approvalRequired(request)
        #expect(output.isApprovalRequired)
        #expect(!output.isError)
        #expect(output.structured?["approvalToken"] == "tok-1")
        #expect(output.structured?["estimate"]?["seconds"] == 42)
        _ = try roundTrip(output)
        _ = try roundTrip(
            ToolReceipt(
                id: "r1", toolName: "timeline_apply", argsHash: "abc", projectId: "project-1", version: 4,
                txnId: "txn-1",
                actor: .human, startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date(timeIntervalSince1970: 2),
                outcome: .applied))
        let stale = ToolOutput.editorError(.staleVersion(current: 4, changedSince: nil))
        #expect(stale.isError && stale.structured?["error"] == "staleVersion" && stale.structured?["hint"] != nil)
    }

    @Test func agentEventsAndRuntimeDTOs() throws {
        let script = FakeAgentRuntime.defaultScript + [.approvalRequested(Fixtures.approvalRequest()), .raw(["x": 1])]
        _ = try roundTrip(script)
        _ = try roundTrip(Fixtures.runtimePolicy)
        _ = try roundTrip(Fixtures.toolAccess)
        _ = try roundTrip(
            RuntimeAvailability(installed: true, version: "2.1.263", loggedIn: false, detail: "run claude login"))
    }

    @Test func mediaDTOs() throws {
        _ = try roundTrip(LibraryLayout(root: URL(fileURLWithPath: "/tmp/Timeline")))
        let asset = Fixtures.asset()
        _ = try roundTrip(
            ImportResult(
                asset: asset, alreadyInLibrary: false, sourceURL: URL(fileURLWithPath: "/src/a.mov"),
                libraryURL: URL(fileURLWithPath: "/lib/a.mov")))
        _ = try roundTrip(MediaReference(asset: asset, layout: LibraryLayout(root: URL(fileURLWithPath: "/tmp/T"))))
        _ = try roundTrip(
            WaveformPeaks(sampleRate: 48000, hop: 256, startSample: 0, min: [-0.5, -0.1], max: [0.5, 0.1]))
        #expect(
            LibraryLayout(root: URL(fileURLWithPath: "/tmp/T")).artifactDir(contentHash: "sha256-abcdef").path
                == "/tmp/T/Cache/sha256/ab/cd/abcdef")
    }
}
