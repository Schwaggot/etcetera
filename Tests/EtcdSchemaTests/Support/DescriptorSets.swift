import Foundation

@testable import EtcdSchema

/// Hand-encoded FileDescriptorSets for schemas protoc would never emit, such
/// as a tampered cache file or a user schema that redefines a well-known type.
enum DescriptorSets {
    struct Field {
        var name: String
        var number: Int32
        /// FieldDescriptorProto.Type: 3 int64, 5 int32, 9 string, 11 message.
        var type: Int32
        var oneofIndex: Int32? = nil
    }

    struct Message {
        var name: String
        var fields: [Field]
        var oneofs: [String] = []
    }

    static func registry(package: String, messages: [Message]) throws -> SchemaRegistry {
        try SchemaRegistry(descriptorSet: set(package: package, messages: messages))
    }

    static func set(package: String, messages: [Message]) -> Data {
        var file = WireWriter()
        file.string(1, "\(package.replacingOccurrences(of: ".", with: "/"))/hand.proto")
        file.string(2, package)
        for message in messages {
            var proto = WireWriter()
            proto.string(1, message.name)
            for field in message.fields {
                var fieldProto = WireWriter()
                fieldProto.string(1, field.name)
                fieldProto.int32(3, field.number)
                fieldProto.int32(4, 1)  // LABEL_OPTIONAL
                fieldProto.int32(5, field.type)
                if let oneofIndex = field.oneofIndex { fieldProto.int32(9, oneofIndex) }
                proto.message(2, fieldProto)
            }
            for oneof in message.oneofs {
                var oneofProto = WireWriter()
                oneofProto.string(1, oneof)
                proto.message(8, oneofProto)
            }
            file.message(4, proto)
        }
        file.string(12, "proto3")
        var set = WireWriter()
        set.message(1, file)
        return set.data
    }
}

extension WireWriter {
    fileprivate mutating func string(_ number: Int, _ value: String) {
        writeTag(fieldNumber: number, wireType: .lengthDelimited)
        writeLengthDelimited(Array(value.utf8))
    }

    fileprivate mutating func int32(_ number: Int, _ value: Int32) {
        writeTag(fieldNumber: number, wireType: .varint)
        writeVarint(UInt64(bitPattern: Int64(value)))
    }

    fileprivate mutating func message(_ number: Int, _ value: WireWriter) {
        writeTag(fieldNumber: number, wireType: .lengthDelimited)
        writeLengthDelimited(value.bytes)
    }
}
