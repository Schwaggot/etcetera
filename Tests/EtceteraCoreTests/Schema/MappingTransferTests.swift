import EtcdSchema
import Foundation
import Testing

@testable import EtceteraCore

@Suite("Mapping import and export", .tags(.unit))
struct MappingTransferTests {
    let rules = [
        SchemaMappingRule(.prefix("/config/"), message: "app.Config"),
        SchemaMappingRule(.key("/config/root"), message: "app.Root"),
    ]

    @Test("Exported mappings read back unchanged")
    func roundTrip() throws {
        let json = try MappingTransfer.export(rules)
        #expect(json.contains("\"format\" : \"etcetera-mappings\""))
        #expect(json.contains("/config/"))
        #expect(try MappingTransfer.parse(json) == rules)
    }

    @Test("A connection export's mappings import too")
    func fromConnection() throws {
        let profile = ConnectionProfile(
            id: "p1", name: "dev", endpoint: "http://localhost:2379", schema: SchemaSettings(mappings: rules))
        #expect(try MappingTransfer.parse(ConnectionTransfer.export(profile)) == rules)
    }

    @Test("A hand-written file needs only the mappings")
    func minimal() throws {
        let parsed = try MappingTransfer.parse(#"{"mappings": [{"prefix": "/a/", "message": "x.A"}]}"#)
        #expect(parsed == [SchemaMappingRule(.prefix("/a/"), message: "x.A")])
    }

    @Test("Unreadable, empty or newer files are refused with a reason", arguments: [
        ("not json", "These are not etcetera mappings"),
        (#"{"mappings": [{"message": "x.A"}]}"#, "exactly one of prefix or key"),
        (#"{"mappings": []}"#, "no mappings"),
        (#"{"mappings": [{"key": "/a", "message": " "}]}"#, "Mapping 1 has no message"),
        (#"{"version": 99, "mappings": [{"key": "/a", "message": "x.A"}]}"#, "newer version"),
        (#"{"version": 99, "connection": {"endpoint": "http://e:2379"}}"#, "newer version"),
        (#"{"connection": {"endpoint": "http://e:2379"}}"#, "no mappings"),
    ])
    func refused(text: String, reason: String) {
        #expect {
            try MappingTransfer.parse(text)
        } throws: { error in
            (error as? MappingImportError)?.reason.contains(reason) == true
        }
    }

    @Test("Adding keeps existing mappings in place and replaces those with the same pattern")
    func merge() {
        let imported = [
            SchemaMappingRule(.key("/config/root"), message: "app.NewRoot"),
            SchemaMappingRule(.prefix("/config/root"), message: "app.Other"),
        ]
        #expect(MappingTransfer.merge(imported, into: rules) == [
            SchemaMappingRule(.prefix("/config/"), message: "app.Config"),
            SchemaMappingRule(.key("/config/root"), message: "app.NewRoot"),
            SchemaMappingRule(.prefix("/config/root"), message: "app.Other"),
        ])
    }
}
