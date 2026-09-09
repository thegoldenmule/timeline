import Contracts
import Foundation
import TimelineCore

/// `align_audio`: the DAW-render-to-camera alignment, run through the job runner, with a proof image.
enum AlignTools {
    /// Reference recordings longer than this ask for approval (the aligner streams envelopes, but a
    /// 2-hour pass is still seconds of work the user may not expect).
    static let longInputSeconds: Double = 20 * 60

    static let alignAudio = Tool(
        name: "align_audio",
        description:
            "Finds where a target recording (typically a short DAW render) sits inside a reference recording (typically the long camera track): offset of the target's start relative to the reference's start, clock drift in ppm, a confidence in 0...1, and every candidate when the material repeats (status ambiguous). status failed means no alignment rather than a wrong one. The proof image shows the correlation peak and the per-window fit. Apply the result with timeline_apply (moveClip the target clip to referenceClipStart + offset). Long references may require approval.",
        inputSchema: Schema.withDefs(
            Schema.object(
                "Align request.",
                properties: ToolSupport.inputProperties(
                    mutating: false,
                    [
                        "referenceAssetId": Schema.string("The long recording (never retimed)."),
                        "targetAssetId": Schema.string("The recording to place inside the reference."),
                        "parameters": Schema.ref("alignmentParameters", "Tunables; default from the project settings."),
                        "approvalToken": Schema.string("Token from an approval_required result, once granted."),
                    ]), required: ["referenceAssetId", "targetAssetId"]),
            ["alignmentParameters": OperationSchemas.defs["alignmentParameters"]!]),
        outputSchema: Schema.object(
            "Alignment result, or an approval_required envelope.",
            properties: [
                "status": Schema.string("aligned, ambiguous, failed, or approval_required."),
                "offset": Schema.any("Best offset as a rational time with seconds (absent when failed)."),
                "offsetSeconds": Schema.number("Best offset in seconds."),
                "driftPPM": Schema.number("Clock drift, parts per million."),
                "confidence": Schema.number("Verification confidence 0...1."),
                "candidates": Schema.array("All candidates, best first.", items: Schema.any("Candidate.")),
                "elapsedSeconds": Schema.number("Aligner wall time."),
                "referenceAssetId": Schema.string("Reference asset."), "targetAssetId": Schema.string("Target asset."),
                "jobId": Schema.string("Alignment job id."),
                "approvalToken": Schema.string("Present when approval is required."),
            ], required: ["status"], additionalProperties: true),
        annotations: ToolAnnotations(title: "Align audio", readOnly: true, idempotent: true),
        examples: [
            .object([
                "referenceAssetId": "00000000-0000-7000-8000-00000000000e",
                "targetAssetId": "00000000-0000-7000-8000-000000000016",
            ])
        ]
    ) { input, context in
        guard let aligner = context.services.aligner else { throw ToolError.serviceUnavailable("aligner") }
        guard let runner = context.services.jobRunner else { throw ToolError.serviceUnavailable("jobRunner") }
        let resolved = try await ToolSupport.resolve(input, context)
        let reference = try ToolSupport.asset(
            try ToolSupport.requireString(input, "referenceAssetId"), in: resolved.project)
        let target = try ToolSupport.asset(try ToolSupport.requireString(input, "targetAssetId"), in: resolved.project)
        guard reference.hasAudio, target.hasAudio else {
            throw ToolError.invalidInput("Both assets need an audio track")
        }
        let parameters =
            try ToolSupport.decode(input, "parameters", as: AlignmentParameters.self)
            ?? resolved.project.settings.alignment
        // Measured: under 2 s for a 2-hour recording (spikes/audio-align); scale linearly.
        let estimate = Estimate(seconds: max(0.5, reference.duration.seconds / 3600), usd: 0)
        if reference.duration.seconds > longInputSeconds,
            case .required(let request) = await context.checkApproval(
                tool: "align_audio", input: input, estimate: estimate)
        {
            return .approvalRequired(request)
        }
        let referenceSource = AudioSource.file(
            ToolSupport.mediaURL(for: reference, context: context), contentHash: reference.contentHash)
        let targetSource = AudioSource.file(
            ToolSupport.mediaURL(for: target, context: context), contentHash: target.contentHash)
        let job = Job(
            kind: .alignment, memoryClass: .medium, label: "Align \(target.displayName) to \(reference.displayName)"
        ) { jobContext in
            jobContext.report(JobProgress(fraction: 0, stage: "coarse"))
            let alignment = try await aligner.align(
                reference: referenceSource, target: targetSource, parameters: parameters)
            jobContext.report(.done)
            return try JobOutcome(encoding: alignment)
        }
        let handle = await runner.submit(job)
        let outcome = try await handle.wait()
        guard let alignment = try outcome.payload(as: Alignment.self) else {
            return .error(code: "alignFailed", message: "The alignment job returned no result")
        }
        var o: [String: JSONValue] = [
            "status": .string(alignment.status.rawValue), "driftPPM": .number(alignment.driftPPM),
            "confidence": .number(alignment.confidence),
            "candidates": .array(
                alignment.candidates.map { c in
                    .object([
                        "offset": ToolSupport.timeJSON(c.offset), "driftPPM": .number(c.driftPPM),
                        "confidence": .number(c.confidence),
                        "verified": .bool(c.verified), "coarseScore": .number(c.coarseScore),
                        "inlierFraction": .number(c.inlierFraction),
                        "fitMADMs": .number(c.fitMADMs),
                    ])
                }),
            "elapsedSeconds": .number(alignment.elapsedSeconds), "referenceAssetId": .string(reference.id.rawValue),
            "targetAssetId": .string(target.id.rawValue), "jobId": .string(handle.id.rawValue),
            "parametersHash": .string(alignment.parametersHash), "projectId": .string(resolved.projectId.rawValue),
        ]
        if let offset = alignment.offset {
            o["offset"] = ToolSupport.timeJSON(offset)
            o["offsetSeconds"] = .number(offset.seconds)
        }
        var images: [ToolImage] = []
        if let proof = alignment.proof {
            images.append(ToolImage(data: try ToolImages.png(try ToolImages.alignmentProof(proof))))
        }
        let text: String
        switch alignment.status {
        case .aligned:
            text = String(
                format: "Aligned: target starts %.3f s into the reference, drift %.1f ppm, confidence %.2f.",
                alignment.offset?.seconds ?? 0, alignment.driftPPM, alignment.confidence)
        case .ambiguous:
            text = "Ambiguous: \(alignment.candidates.filter(\.verified).count) verified candidates; pick one."
        case .failed:
            text = "No alignment found (confidence \(alignment.confidence))."
        }
        return ToolOutput(structured: .object(o), text: text, images: images)
    }
}
