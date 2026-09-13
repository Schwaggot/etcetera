import EtcdSchema
import EtceteraCore
import Foundation
import SwiftProtobuf

/// `package t; message Item { string name = 1; int32 count = 2; }`
enum TestSchema {
    static func registry() throws -> SchemaRegistry {
        var name = Google_Protobuf_FieldDescriptorProto()
        name.name = "name"
        name.jsonName = "name"
        name.number = 1
        name.label = .optional
        name.type = .string
        var count = Google_Protobuf_FieldDescriptorProto()
        count.name = "count"
        count.jsonName = "count"
        count.number = 2
        count.label = .optional
        count.type = .int32
        var item = Google_Protobuf_DescriptorProto()
        item.name = "Item"
        item.field = [name, count]
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "t.proto"
        file.package = "t"
        file.syntax = "proto3"
        file.messageType = [item]
        var set = Google_Protobuf_FileDescriptorSet()
        set.file = [file]
        return try SchemaRegistry(descriptorSet: set.serializedBytes())
    }

    /// Item { name: "a", count: 2 }
    static let item = Data([0x0A, 0x01, 0x61, 0x10, 0x02])
}

final class FakeSchemaLoader: SchemaLoading, @unchecked Sendable {
    var result: Result<SchemaRegistry, any Error>
    var skipped: [SkippedProtoFile] = []
    private(set) var forces: [Bool] = []

    init(_ result: Result<SchemaRegistry, any Error>) {
        self.result = result
    }

    func schema(for settings: SchemaSettings, profileID: String, force: Bool) async throws -> CompiledSchema {
        forces.append(force)
        return CompiledSchema(registry: try result.get(), skipped: skipped)
    }
}
