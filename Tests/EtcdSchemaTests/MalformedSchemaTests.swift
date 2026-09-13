import Foundation
import Testing

@testable import EtcdSchema

// Schemas protoc would never emit must fail cleanly, not trap later on
// untrusted bytes or JSON. See SPEC 6.5.

@Suite("Schemas protoc would not produce", .tags(.unit, .fuzz))
struct MalformedSchemaTests {
    @Test("A Duration with 64-bit nanos of Int64.min is a projection error, not a trap")
    func sixtyFourBitDurationNanos() throws {
        let registry = try DescriptorSets.registry(package: "google.protobuf", messages: [
            .init(name: "Duration", fields: [.init(name: "seconds", number: 1, type: 3), .init(name: "nanos", number: 2, type: 3)]),
        ])
        // nanos: Int64.min
        let bytes = Data([0x10, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01])
        #expect(throws: ProtoJSONError.self) {
            _ = try ProtobufValueCodec(registry: registry).decodeToJSON(bytes, messageName: "google.protobuf.Duration")
        }
    }

    @Test("A field number outside 1 to 536870911 is rejected when the schema loads",
        arguments: [Int32(-1), 0, 536_870_912])
    func fieldNumberOutOfRange(number: Int32) {
        #expect(throws: SchemaError.self) {
            _ = try DescriptorSets.registry(package: "bad", messages: [
                .init(name: "M", fields: [.init(name: "x", number: number, type: 5)]),
            ])
        }
    }

    @Test("A oneof index naming no oneof is rejected when the schema loads")
    func oneofIndexOutOfRange() {
        #expect(throws: SchemaError.self) {
            _ = try DescriptorSets.registry(package: "bad", messages: [
                .init(name: "M", fields: [
                    .init(name: "a", number: 1, type: 5, oneofIndex: 3), .init(name: "b", number: 2, type: 5, oneofIndex: 3),
                ]),
            ])
        }
    }
}
