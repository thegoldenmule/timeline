import Contracts
import ContractsTestSupport
import Foundation
import Testing
import TimelineCore

@testable import AgentKit

/// The contract of docs/design/implementation-plan.md: every tool has a strict schema with an example
/// that validates, and every fixture `Command.Operation` validates against `timeline_apply`'s schema.
@Suite struct SchemaContractTests {
    @Test func validatorCoversTheSubsetTheToolsUse() {
        let root: JSONValue = Schema.withDefs(
            Schema.object(
                "root",
                properties: [
                    "name": Schema.string("n", pattern: "^[a-z]+$"),
                    "count": Schema.integer("c", minimum: 0, maximum: 10),
                    "kind": Schema.enum("k", ["a", "b"]),
                    "flag": Schema.bool("f"),
                    "items": Schema.array("i", items: Schema.ref("item"), minItems: 1),
                    "choice": Schema.oneOf("o", [Schema.string("s"), Schema.integer("i")]),
                    "either": Schema.anyOf("a", [Schema.string("s"), Schema.integer("i")]),
                    "fixed": Schema.const("yes", "const"),
                    "bag": Schema.map("m", values: Schema.integer("v")),
                ], required: ["name"]),
            ["item": Schema.object("item", properties: ["id": Schema.string("id")], required: ["id"])])
        let validator = JSONSchemaValidator(root: root)
        let good: JSONValue = [
            "name": "abc", "count": 3, "kind": "a", "flag": true, "items": [["id": "x"]], "choice": 4, "either": "s",
            "fixed": "yes", "bag": ["k": 1],
        ]
        #expect(validator.validate(good).isEmpty)

        let bad: JSONValue = [
            "name": "ABC", "count": 11, "kind": "c", "flag": "no", "items": [], "choice": true, "either": 1.5,
            "fixed": "no", "bag": ["k": "v"], "extra": 1,
        ]
        let messages = validator.validate(bad).map(\.description)
        #expect(messages.contains { $0.hasPrefix("name:") && $0.contains("pattern") })
        #expect(messages.contains { $0.hasPrefix("count:") && $0.contains("maximum") })
        #expect(messages.contains { $0.hasPrefix("kind:") && $0.contains("one of") })
        #expect(messages.contains { $0.hasPrefix("flag:") && $0.contains("expected boolean") })
        #expect(messages.contains { $0.hasPrefix("items:") && $0.contains("at least 1") })
        #expect(messages.contains { $0.hasPrefix("choice:") })
        #expect(messages.contains { $0.hasPrefix("either:") })
        #expect(messages.contains { $0.hasPrefix("fixed:") && $0.contains("constant") })
        #expect(messages.contains { $0.hasPrefix("bag.k:") })
        #expect(messages.contains { $0.hasPrefix("extra:") && $0.contains("unexpected") })
        #expect(validator.validate([:]).map(\.message) == ["missing required property name"])

        // $ref resolution and integer-vs-number typing.
        #expect(validator.resolve(ref: "#/$defs/item") != nil)
        #expect(validator.resolve(ref: "#/$defs/nope") == nil)
        #expect(!validator.validate(["name": "a", "count": 1.5]).isEmpty)
        #expect(validator.validate(["name": "a", "items": [["id": 1]]]).first?.path == "items[0].id")
    }

    @Test func everyToolHasAStrictSchemaAndValidExamples() {
        let tools = EditorTools.all
        #expect(tools.count == 15)
        #expect(Set(tools.map(\.name)).count == tools.count)
        for tool in tools {
            #expect(tool.inputSchema["type"] == "object", "\(tool.name) input is an object schema")
            #expect(tool.inputSchema["additionalProperties"] == .bool(false), "\(tool.name) rejects unknown keys")
            #expect(tool.outputSchema != nil, "\(tool.name) has an outputSchema")
            #expect(!tool.examples.isEmpty, "\(tool.name) has an example")
            #expect(!tool.description.isEmpty)
            if tool.name != "project_list" {
                #expect(tool.inputSchema["properties"]?["projectId"] != nil, "\(tool.name) takes projectId")
            }
            let validator = JSONSchemaValidator(root: tool.inputSchema)
            for (i, example) in tool.examples.enumerated() {
                let violations = validator.validate(example)
                #expect(violations.isEmpty, "\(tool.name) example \(i): \(violations)")
            }
            #expect(descriptionsCoverEveryProperty(tool.inputSchema, path: tool.name).isEmpty)
        }
    }

    /// Every `properties` entry (and `$defs` entry) carries a description, so the model is never guessing.
    func descriptionsCoverEveryProperty(_ schema: JSONValue, path: String) -> [String] {
        var missing: [String] = []
        func walk(_ node: JSONValue, _ path: String) {
            guard case .object(let o) = node else { return }
            for (name, property) in o["properties"]?.objectValue ?? [:] {
                let p = "\(path).\(name)"
                if property["description"] == nil, property["$ref"] == nil, property["oneOf"] == nil,
                    property["anyOf"] == nil
                {
                    missing.append(p)
                }
                walk(property, p)
                for option in (property["oneOf"]?.arrayValue ?? []) + (property["anyOf"]?.arrayValue ?? []) {
                    walk(option, p)
                }
            }
            if let items = o["items"] { walk(items, "\(path)[]") }
            for (name, def) in o["$defs"]?.objectValue ?? [:] { walk(def, "\(path)#\(name)") }
        }
        walk(schema, path)
        return missing
    }

    @Test func everyFixtureOperationValidatesAgainstTheApplySchema() throws {
        let apply = try #require(EditorTools.all.first { $0.name == "timeline_apply" })
        let validator = JSONSchemaValidator(root: apply.inputSchema)
        let operations = ProjectFixtures.exampleOperations()
        #expect(operations.count == Command.Operation.allTypeNames.count)
        for op in operations {
            let json = try JSONValue(encoding: op)
            let specific = try #require(OperationSchemas.schema(forType: op.typeName), "schema for \(op.typeName)")
            let against = validator.validate(json, against: specific)
            #expect(against.isEmpty, "\(op.typeName) against op schema: \(against)")
            let union = validator.validate(json, against: OperationSchemas.operation)
            #expect(union.isEmpty, "\(op.typeName) against the operation union: \(union)")
            let whole = validator.validate(["expectedVersion": 3, "ops": [json]])
            #expect(whole.isEmpty, "\(op.typeName) inside timeline_apply: \(whole)")
            // And the JSON round-trips back into the same operation.
            #expect(try json.decoded(as: Command.Operation.self) == op)
        }
        for type in Command.Operation.allTypeNames {
            #expect(OperationSchemas.schema(forType: type) != nil, "no schema for \(type)")
        }
    }

    @Test func applySchemaRejectsWhatTheDecoderRejects() throws {
        let apply = try #require(EditorTools.all.first { $0.name == "timeline_apply" })
        let validator = JSONSchemaValidator(root: apply.inputSchema)
        let unknownType: JSONValue = ["expectedVersion": 1, "ops": [["type": "explode", "clipId": "c"]]]
        #expect(!validator.validate(unknownType).isEmpty)
        let missingField: JSONValue = ["expectedVersion": 1, "ops": [["type": "moveClip", "clipId": "c"]]]
        #expect(!validator.validate(missingField).isEmpty)
        let badTime: JSONValue = [
            "expectedVersion": 1, "ops": [["type": "splitClip", "clipId": "c", "at": ["v": 1, "ts": 0]]],
        ]
        #expect(!validator.validate(badTime).isEmpty)
        let noVersion: JSONValue = ["ops": [["type": "redo"]]]
        #expect(validator.validate(noVersion).map(\.message) == ["missing required property expectedVersion"])
        let refOK: JSONValue = [
            "expectedVersion": 1,
            "ops": [
                ["type": "splitClip", "clipId": "c", "at": ["v": 1, "ts": 1]],
                ["type": "removeClip", "clipId": ["$ref": 0]],
            ],
        ]
        #expect(validator.validate(refOK).isEmpty)
    }
}
