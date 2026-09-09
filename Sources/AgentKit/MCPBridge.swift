import Contracts
import Foundation
import MCP
import TimelineCore

/// Conversions between the editor's `JSONValue`/`Tool`/`ToolOutput` and the MCP SDK's `Value`/`Tool`/
/// `CallTool.Result`. Kept in one place so the wire shape (annotations, `outputSchema`,
/// `structuredContent`, image blocks) is easy to audit against the spike transcript.
public enum MCPBridge {
    public static func value(_ json: JSONValue) -> Value {
        switch json {
        case .null: .null
        case .bool(let b): .bool(b)
        case .number(let n):
            n == n.rounded() && abs(n) < 9.007_199_254_740_992e15 ? .int(Int(n)) : .double(n)
        case .string(let s): .string(s)
        case .array(let a): .array(a.map(value))
        case .object(let o): .object(o.mapValues(value))
        }
    }

    public static func json(_ value: Value) -> JSONValue {
        switch value {
        case .null: .null
        case .bool(let b): .bool(b)
        case .int(let i): .number(Double(i))
        case .double(let d): .number(d)
        case .string(let s): .string(s)
        case .data(let mimeType, let data): .string(data.dataURLEncoded(mimeType: mimeType))
        case .array(let a): .array(a.map(json))
        case .object(let o): .object(o.mapValues(json))
        }
    }

    public static func annotations(_ a: ToolAnnotations) -> MCP.Tool.Annotations {
        MCP.Tool.Annotations(
            title: a.title, readOnlyHint: a.readOnly, destructiveHint: a.destructive, idempotentHint: a.idempotent,
            openWorldHint: a.openWorld)
    }

    /// The MCP description of an editor tool (`tools/list`).
    public static func tool(_ tool: Contracts.Tool) -> MCP.Tool {
        MCP.Tool(
            name: tool.name, title: tool.annotations.title, description: tool.description,
            inputSchema: value(tool.inputSchema), annotations: annotations(tool.annotations),
            outputSchema: tool.outputSchema.map(value))
    }

    /// The MCP result of a tool call: a text block (the tool's text, else the structured JSON), one
    /// image block per image, `structuredContent`, and `isError`.
    public static func result(_ output: ToolOutput) -> CallTool.Result {
        var content: [MCP.Tool.Content] = []
        let text = output.text ?? output.structured.flatMap(compactJSON) ?? ""
        content.append(.text(text: text, annotations: nil, _meta: nil))
        for image in output.images {
            content.append(
                .image(data: image.data.base64EncodedString(), mimeType: image.mimeType, annotations: nil, _meta: nil))
        }
        return CallTool.Result(
            content: content, structuredContent: output.structured.map(value), isError: output.isError ? true : nil)
    }

    /// The editor input of a `tools/call`.
    public static func input(_ arguments: [String: Value]?) -> ToolInput {
        ToolInput((arguments ?? [:]).mapValues(json))
    }

    static func compactJSON(_ json: JSONValue) -> String? {
        (try? ProjectCodec.encode(json)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

extension Data {
    func dataURLEncoded(mimeType: String?) -> String {
        "data:\(mimeType ?? "application/octet-stream");base64,\(base64EncodedString())"
    }
}
