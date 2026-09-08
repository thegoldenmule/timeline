import Foundation
import TimelineCore

/// Builders for the hand-maintained JSON Schemas the tools publish. Every property carries a
/// `description`; objects default to `additionalProperties: false` so a misspelt key is a schema
/// error the model can read rather than a silently ignored argument.
public enum Schema {
    public static func object(
        _ description: String? = nil, properties: [String: JSONValue], required: [String] = [],
        additionalProperties: Bool = false
    ) -> JSONValue {
        var o: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": .bool(additionalProperties),
        ]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    /// An object whose values all match `values` (a JSON dictionary).
    public static func map(_ description: String, values: JSONValue) -> JSONValue {
        .object(["type": "object", "description": .string(description), "additionalProperties": values])
    }

    public static func string(_ description: String, pattern: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let pattern { o["pattern"] = .string(pattern) }
        return .object(o)
    }

    public static func `enum`(_ description: String, _ values: [String]) -> JSONValue {
        .object(["type": "string", "description": .string(description), "enum": .array(values.map { .string($0) })])
    }

    public static func const(_ value: String, _ description: String) -> JSONValue {
        .object(["type": "string", "const": .string(value), "description": .string(description)])
    }

    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { o["minimum"] = .number(Double(minimum)) }
        if let maximum { o["maximum"] = .number(Double(maximum)) }
        return .object(o)
    }

    public static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "number", "description": .string(description)]
        if let minimum { o["minimum"] = .number(minimum) }
        if let maximum { o["maximum"] = .number(maximum) }
        return .object(o)
    }

    public static func bool(_ description: String) -> JSONValue {
        .object(["type": "boolean", "description": .string(description)])
    }

    public static func array(_ description: String, items: JSONValue, minItems: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "array", "description": .string(description), "items": items]
        if let minItems { o["minItems"] = .number(Double(minItems)) }
        return .object(o)
    }

    public static func ref(_ name: String, _ description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["$ref": .string("#/$defs/\(name)")]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    public static func oneOf(_ description: String, _ options: [JSONValue]) -> JSONValue {
        .object(["description": .string(description), "oneOf": .array(options)])
    }

    public static func anyOf(_ description: String, _ options: [JSONValue]) -> JSONValue {
        .object(["description": .string(description), "anyOf": .array(options)])
    }

    /// Any JSON value.
    public static func any(_ description: String) -> JSONValue {
        .object(["description": .string(description)])
    }

    /// Adds `$defs` to a schema root.
    public static func withDefs(_ schema: JSONValue, _ defs: [String: JSONValue]) -> JSONValue {
        var s = schema
        s["$defs"] = .object(defs)
        return s
    }
}

/// A validation failure: where and why.
public struct SchemaViolation: Error, Hashable, Sendable, CustomStringConvertible {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path.isEmpty ? "$" : path): \(message)" }
}

/// A JSON Schema validator for the subset the tool schemas use: `type`, `properties`, `required`,
/// `enum`, `const`, `items`, `minItems`, `oneOf`, `anyOf`, `additionalProperties`, `$ref` within the
/// document (`#/$defs/...`), `minimum`, `maximum`, and `pattern`. Anything else is ignored.
public struct JSONSchemaValidator: Sendable {
    public var root: JSONValue

    public init(root: JSONValue) { self.root = root }

    /// Every violation of `value` against `schema` (a sub-schema of `root`, or `root` itself).
    public func validate(_ value: JSONValue, against schema: JSONValue? = nil) -> [SchemaViolation] {
        var violations: [SchemaViolation] = []
        validate(value, schema: schema ?? root, path: "", into: &violations, depth: 0)
        return violations
    }

    public func isValid(_ value: JSONValue, against schema: JSONValue? = nil) -> Bool {
        validate(value, against: schema).isEmpty
    }

    /// Resolves `#/$defs/<name>` (or any `#/a/b/c` pointer) within the root document.
    public func resolve(ref: String) -> JSONValue? {
        guard ref.hasPrefix("#/") else { return nil }
        var current = root
        for segment in ref.dropFirst(2).split(separator: "/") {
            let key = segment.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = current[key] else { return nil }
            current = next
        }
        return current
    }

    // MARK: Implementation

    private func validate(
        _ value: JSONValue, schema: JSONValue, path: String, into violations: inout [SchemaViolation], depth: Int
    ) {
        guard depth < 64 else {
            violations.append(SchemaViolation(path: path, message: "schema nesting too deep"))
            return
        }
        guard case .object(let s) = schema else {
            if case .bool(let b) = schema, !b { violations.append(SchemaViolation(path: path, message: "rejected")) }
            return
        }
        if let ref = s["$ref"]?.stringValue {
            guard let target = resolve(ref: ref) else {
                violations.append(SchemaViolation(path: path, message: "unresolvable $ref \(ref)"))
                return
            }
            validate(value, schema: target, path: path, into: &violations, depth: depth + 1)
            return
        }
        if let type = s["type"] {
            let allowed: [String] = type.arrayValue?.compactMap(\.stringValue) ?? type.stringValue.map { [$0] } ?? []
            if !allowed.isEmpty, !allowed.contains(where: { matches(value, type: $0) }) {
                violations.append(
                    SchemaViolation(
                        path: path, message: "expected \(allowed.joined(separator: " or ")), got \(typeName(value))"))
                return
            }
        }
        if let const = s["const"], const != value {
            violations.append(SchemaViolation(path: path, message: "expected constant \(render(const))"))
        }
        if let options = s["enum"]?.arrayValue, !options.contains(value) {
            violations.append(
                SchemaViolation(path: path, message: "expected one of \(options.map(render).joined(separator: ", "))"))
        }
        if case .number(let n) = value {
            if let min = s["minimum"]?.numberValue, n < min {
                violations.append(SchemaViolation(path: path, message: "\(n) is below minimum \(min)"))
            }
            if let max = s["maximum"]?.numberValue, n > max {
                violations.append(SchemaViolation(path: path, message: "\(n) is above maximum \(max)"))
            }
        }
        if case .string(let str) = value, let pattern = s["pattern"]?.stringValue {
            if str.range(of: pattern, options: .regularExpression) == nil {
                violations.append(SchemaViolation(path: path, message: "does not match pattern \(pattern)"))
            }
        }
        if case .object(let o) = value {
            let properties = s["properties"]?.objectValue ?? [:]
            for key in (s["required"]?.arrayValue ?? []).compactMap(\.stringValue) where o[key] == nil {
                violations.append(SchemaViolation(path: path, message: "missing required property \(key)"))
            }
            for (key, child) in o {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                if let propertySchema = properties[key] {
                    validate(child, schema: propertySchema, path: childPath, into: &violations, depth: depth + 1)
                } else if let additional = s["additionalProperties"] {
                    if case .bool(false) = additional {
                        violations.append(SchemaViolation(path: childPath, message: "unexpected property"))
                    } else if case .object = additional {
                        validate(child, schema: additional, path: childPath, into: &violations, depth: depth + 1)
                    }
                }
            }
        }
        if case .array(let a) = value {
            if let minItems = s["minItems"]?.intValue, a.count < minItems {
                violations.append(SchemaViolation(path: path, message: "expected at least \(minItems) items"))
            }
            if let items = s["items"] {
                for (i, element) in a.enumerated() {
                    validate(element, schema: items, path: "\(path)[\(i)]", into: &violations, depth: depth + 1)
                }
            }
        }
        if let options = s["oneOf"]?.arrayValue {
            let matching = options.filter { option in
                var inner: [SchemaViolation] = []
                validate(value, schema: option, path: path, into: &inner, depth: depth + 1)
                return inner.isEmpty
            }
            if matching.count != 1 {
                violations.append(
                    SchemaViolation(
                        path: path,
                        message: "expected exactly one of \(options.count) alternatives to match, \(matching.count) did"
                    ))
            }
        }
        if let options = s["anyOf"]?.arrayValue {
            let anyMatches = options.contains { option in
                var inner: [SchemaViolation] = []
                validate(value, schema: option, path: path, into: &inner, depth: depth + 1)
                return inner.isEmpty
            }
            if !anyMatches {
                violations.append(SchemaViolation(path: path, message: "matches none of \(options.count) alternatives"))
            }
        }
    }

    private func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object),
            ("number", .number):
            true
        case ("integer", .number(let n)): n == n.rounded() && n.isFinite
        default: false
        }
    }

    private func typeName(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "boolean"
        case .number(let n): n == n.rounded() ? "integer" : "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    private func render(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): "\"\(s)\""
        case .number(let n): n == n.rounded() ? String(Int64(n)) : String(n)
        case .bool(let b): String(b)
        case .null: "null"
        case .array, .object: (try? ProjectCodec.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
        }
    }
}
