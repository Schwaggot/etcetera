import Foundation
import SwiftProtobuf
import Testing

@testable import EtcdSchema

@Suite("Schema registry", .tags(.unit))
struct RegistryTests {
    let registry: SchemaRegistry

    init() throws {
        registry = try Fixtures.registry()
    }

    @Test("Flattens nested types under their fully qualified names")
    func flattensNestedTypes() throws {
        #expect(registry.message(named: "fixtures.v1.Nested.Inner") != nil)
        #expect(registry.message(named: ".fixtures.v1.Nested.Inner") != nil)
        #expect(registry.message(named: "Inner") == nil)
    }

    @Test("Links field types to their messages and enums")
    func linksFieldTypes() throws {
        let nested = try #require(registry.message(named: "fixtures.v1.Nested"))
        let inner = try #require(nested.field(named: "inner"))
        #expect(inner.type == .message)
        #expect(inner.typeName == "fixtures.v1.Nested.Inner")
        let scalars = try #require(registry.message(named: "fixtures.v1.Scalars"))
        let color = try #require(scalars.field(named: "f_enum"))
        #expect(color.type == .enumeration)
        #expect(color.typeName == "fixtures.v1.Color")
    }

    @Test("Recognizes map fields through their entry messages")
    func recognizesMaps() throws {
        let maps = try #require(registry.message(named: "fixtures.v1.Maps"))
        #expect(maps.field(named: "labels")?.isMap == true)
        #expect(maps.field(named: "by_id")?.isMap == true)
        let repeated = try #require(registry.message(named: "fixtures.v1.Repeated"))
        #expect(repeated.field(named: "names")?.isMap == false)
    }

    @Test("Records real oneof membership and proto3 optional presence")
    func oneofsAndPresence() throws {
        let oneofs = try #require(registry.message(named: "fixtures.v1.Oneofs"))
        #expect(oneofs.oneofNames == ["choice"])
        #expect(oneofs.field(named: "text")?.oneofIndex == 0)
        #expect(oneofs.field(named: "inner")?.oneofIndex == 0)
        #expect(oneofs.field(named: "other")?.oneofIndex == nil)
        #expect(oneofs.field(named: "text")?.hasExplicitPresence == true)

        let optionals = try #require(registry.message(named: "fixtures.v1.Optionals"))
        // Synthetic oneofs carry presence only; they are not real oneofs.
        #expect(optionals.oneofNames.isEmpty)
        #expect(optionals.field(named: "maybe_int")?.hasExplicitPresence == true)
        #expect(optionals.field(named: "maybe_int")?.oneofIndex == nil)
        #expect(optionals.field(named: "plain_int")?.hasExplicitPresence == false)

        let legacy = try #require(registry.message(named: "fixtures.v1.Legacy"))
        #expect(legacy.field(named: "a")?.hasExplicitPresence == true)
        #expect(legacy.field(named: "c")?.isRequired == true)
    }

    @Test("Packs repeated scalars by proto3 default and honors packed=false")
    func packing() throws {
        let repeated = try #require(registry.message(named: "fixtures.v1.Repeated"))
        #expect(repeated.field(named: "packed_ints")?.isPacked == true)
        #expect(repeated.field(named: "colors")?.isPacked == true)
        #expect(repeated.field(named: "unpacked_ints")?.isPacked == false)
        #expect(repeated.field(named: "names")?.isPacked == false)
        let legacy = try #require(registry.message(named: "fixtures.v1.Legacy"))
        #expect(legacy.field(named: "b")?.isPacked == false)
    }

    @Test("Honors json_name and finds fields by either name")
    func jsonNames() throws {
        let scalars = try #require(registry.message(named: "fixtures.v1.Scalars"))
        #expect(scalars.field(number: 3)?.jsonName == "fInt32")
        #expect(scalars.field(named: "fInt32")?.number == 3)
        #expect(scalars.field(named: "f_int32")?.number == 3)
    }

    @Test("Keeps declaration order and ascending number order separately")
    func fieldOrders() throws {
        let record = try #require(registry.message(named: "fixtures.v1.Scalars"))
        #expect(record.fields.map(\.number) == Array(1...16))
        #expect(record.fieldsByNumber.map(\.number) == Array(1...16))
    }

    @Test("Resolves enum values by name and number")
    func enums() throws {
        let color = try #require(registry.enumeration(named: "fixtures.v1.Color"))
        #expect(color.name(for: 2) == "COLOR_GREEN")
        #expect(color.number(for: "COLOR_RED") == 1)
        #expect(color.name(for: 9) == nil)
        #expect(!color.isClosed)
    }

    @Test("Includes imported well-known types and lists names sorted")
    func allMessageNames() {
        let names = registry.allMessageNames
        #expect(names.contains("google.protobuf.Timestamp"))
        #expect(names.contains("fixtures.v1.Nested.Inner"))
        #expect(names == names.sorted())
    }

    @Test("A dangling type reference is a typed error")
    func danglingReference() {
        var field = Google_Protobuf_FieldDescriptorProto()
        field.name = "b"
        field.number = 1
        field.type = .message
        field.typeName = ".missing.B"
        var message = Google_Protobuf_DescriptorProto()
        message.name = "A"
        message.field = [field]
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "p.proto"
        file.package = "p"
        file.syntax = "proto3"
        file.messageType = [message]
        var set = Google_Protobuf_FileDescriptorSet()
        set.file = [file]
        #expect(throws: SchemaError.unresolvedType(field: "p.A.b", typeName: ".missing.B")) {
            _ = try SchemaRegistry(fileDescriptorSet: set)
        }
    }

    @Test("Bytes that are not a descriptor set are rejected")
    func garbage() {
        #expect(throws: SchemaError.self) {
            _ = try SchemaRegistry(descriptorSet: Data([0xFF, 0xFF, 0xFF]))
        }
    }
}
