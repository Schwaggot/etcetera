import Foundation
import Testing

@testable import EtcdSchema

// SPEC 5.5: a mapping can name a field whose value labels the key in the UI.

@Suite("Mapping name field", .tags(.unit))
struct MappingNameFieldTests {
    private func name(_ json: String, field: String?) -> String? {
        SchemaMappingRule(.prefix("/a/"), message: "t.Item", nameField: field).displayName(forValue: Data(json.utf8))
    }

    @Test("A top-level string field names the key")
    func topLevel() {
        #expect(name(#"{"id": "7f3a", "name": "Front door"}"#, field: "name") == "Front door")
    }

    @Test("A dotted path reaches a nested field")
    func nested() {
        #expect(name(#"{"info": {"name": "Port scan"}}"#, field: "info.name") == "Port scan")
    }

    @Test("A snake_case field also matches its lowerCamelCase JSON name")
    func camelCase() {
        #expect(name(#"{"displayName": "DNS"}"#, field: "display_name") == "DNS")
    }

    @Test("Missing, empty, non-string or non-JSON values give no name", arguments: [
        (#"{"id": "1"}"#, "name"),
        (#"{"name": "  "}"#, "name"),
        (#"{"name": 5}"#, "name"),
        (#"{"info": "x"}"#, "info.name"),
        ("not json", "name"),
        (#"["name"]"#, "name"),
    ])
    func noName(json: String, field: String) {
        #expect(name(json, field: field) == nil)
    }

    @Test("Without a name field there is no name")
    func unset() {
        #expect(name(#"{"name": "a"}"#, field: nil) == nil)
    }

    @Test("The name field survives JSON coding and an empty one is dropped")
    func coding() throws {
        let rule = SchemaMappingRule(.key("/a/1"), message: "t.Item", nameField: "info.name")
        let data = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(SchemaMappingRule.self, from: data) == rule)
        let blank = try JSONDecoder().decode(
            SchemaMappingRule.self, from: Data(#"{"prefix": "/a/", "message": "t.Item", "nameField": " "}"#.utf8))
        #expect(blank.nameField == nil)
        let plain = try JSONEncoder().encode(SchemaMappingRule(.prefix("/a/"), message: "t.Item"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("nameField"))
    }
}
