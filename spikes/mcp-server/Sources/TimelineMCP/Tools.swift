import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import MCP

func log(_ s: String) { FileHandle.standardError.write(Data("[timeline-mcp] \(s)\n".utf8)) }

let toolList: [Tool] = [
    Tool(name: "project_describe", description: "Summarize the open project: tracks, clips, version.",
         inputSchema: .object(["type": "object", "properties": .object([:]), "additionalProperties": false]),
         annotations: .init(title: "Describe project", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
         outputSchema: .object(["type": "object", "properties": ["version": ["type": "integer"], "tracks": ["type": "array"], "clips": ["type": "array"]]])),
    Tool(name: "timeline_apply",
         description: "Apply timeline edit ops atomically. Requires baseVersion == current version (else error with currentVersion; re-describe and retry). Same commandId is idempotent.",
         inputSchema: .object([
            "type": "object", "required": ["ops", "baseVersion", "commandId"],
            "properties": .object([
                "baseVersion": .object(["type": "integer", "description": "Project version the ops were computed against"]),
                "commandId": .object(["type": "string", "description": "Client-generated unique id; retries with the same id are no-ops"]),
                "ops": .object(["type": "array", "items": .object([
                    "type": "object", "required": ["op", "clipId"],
                    "properties": .object([
                        "op": .object(["type": "string", "enum": ["moveClip", "trimClip"]]),
                        "clipId": .object(["type": "string"]),
                        "start": .object(["type": "integer", "description": "moveClip: new start frame"]),
                        "duration": .object(["type": "integer", "description": "trimClip: new duration in frames"]),
                    ])])]),
            ])]),
         annotations: .init(title: "Apply timeline ops", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false),
         outputSchema: .object(["type": "object", "properties": ["version": ["type": "integer"], "changedIds": ["type": "array"]]])),
    Tool(name: "look_at", description: "Render the current viewer frame as a PNG image (spike: a timestamp card).",
         inputSchema: .object(["type": "object", "properties": .object([:])]),
         annotations: .init(title: "Look at viewer", readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
]

func handleCall(_ params: CallTool.Parameters, project: FakeProject) async throws -> CallTool.Result {
    log("tools/call \(params.name) args=\(params.arguments.map { "\($0)" } ?? "{}")")
    let args = params.arguments ?? [:]
    switch params.name {
    case "project_describe":
        let summary = await project.describe()
        return .init(content: [.text(text: summary.jsonString, annotations: nil, _meta: nil)], structuredContent: .some(summary))

    case "timeline_apply":
        guard let ops = args["ops"]?.arrayValue?.compactMap(\.objectValue),
              let base = args["baseVersion"]?.intValue, let cmd = args["commandId"]?.stringValue else {
            return .init(content: [.text(text: "Missing ops/baseVersion/commandId", annotations: nil, _meta: nil)], isError: true)
        }
        do {
            let r = try await project.apply(ops: ops, baseVersion: base, commandId: cmd)
            log("  -> version \(r.version) changed \(r.changedIds)")
            return try .init(content: [.text(text: "Applied. version=\(r.version) changedIds=\(r.changedIds)", annotations: nil, _meta: nil)], structuredContent: r)
        } catch FakeProject.ApplyError.stale(let current) {
            log("  -> STALE base=\(base) current=\(current)")
            let err: Value = .object(["error": "stale_version", "baseVersion": .int(base), "currentVersion": .int(current),
                                      "hint": "Call project_describe, recompute ops against currentVersion, retry with a NEW commandId."])
            return .init(content: [.text(text: err.jsonString, annotations: nil, _meta: nil)], structuredContent: .some(err), isError: true)
        } catch {
            return .init(content: [.text(text: "Rejected: \(error)", annotations: nil, _meta: nil)], isError: true)
        }

    case "look_at":
        let stamp = ISO8601DateFormatter().string(from: Date())
        let png = renderPNG(text: "viewer @ \(stamp)")
        return .init(content: [
            .text(text: "Viewer frame rendered at \(stamp) (\(png.count) bytes PNG)", annotations: nil, _meta: nil),
            .image(data: png.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
        ])
    default:
        throw MCPError.methodNotFound("Unknown tool: \(params.name)")
    }
}

/// Small Core Graphics PNG: dark card with white text. No AppKit (keeps it off the main actor).
func renderPNG(text: String, width: Int = 320, height: Int = 80) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0.95, green: 0.55, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: 6))
    let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
    let attr = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1)])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = CGPoint(x: 12, y: CGFloat(height) / 2 - 5)
    CTLineDraw(line, ctx)
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
    return out as Data
}

extension Value {
    var jsonString: String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
