import Foundation
import Testing

@testable import EtcdSchema

// The round trip is the contract: protoc's bytes, decoded by our codec
// against the descriptor and re-encoded, must come back byte for byte.
// See SPEC 6.5.

@Suite("Wire round trip against protoc fixtures", .tags(.unit))
struct RoundTripTests {
    @Test("Decoding and re-encoding protoc's bytes is byte-identical", arguments: Fixtures.messageNames)
    func wireRoundTrip(name: String) throws {
        let codec = WireCodec(registry: try Fixtures.registry())
        let bytes = try Fixtures.bytes(name)
        let message = try codec.decode(bytes, as: Fixtures.messageType(name))
        #expect(codec.encode(message) == bytes)
    }

    @Test("An unmodified value survives the JSON edit path unchanged", arguments: Fixtures.messageNames)
    func jsonRoundTripIsFaithful(name: String) throws {
        let bytes = try Fixtures.bytes(name)
        let decoded = try Fixtures.codec().decodeToJSON(bytes, messageName: Fixtures.messageType(name))
        #expect(decoded.roundTrip.isFaithful)
        #expect(decoded.roundTrip.originalLength == bytes.count)
        #expect(decoded.roundTrip.reencodedLength == bytes.count)
    }

    @Test(
        "Decoded values match protoc --decode",
        arguments: Fixtures.messageNames.filter { $0 != "record_new" })
    func matchesProtocDecode(name: String) throws {
        let registry = try Fixtures.registry()
        let message = try WireCodec(registry: registry).decode(Fixtures.bytes(name), as: Fixtures.messageType(name))
        let reference = try Fixtures.text("messages/\(name).decoded.txt")
        #expect(TextFormat.render(message, registry: registry) == reference)
    }

    @Test("Decoding with an older schema keeps the newer fields as unknown, in order")
    func olderSchemaKeepsUnknownFields() throws {
        #expect(try Fixtures.usesNewerSchema("record_new"))
        let codec = WireCodec(registry: try Fixtures.registry())
        let message = try codec.decode(Fixtures.bytes("record_new"), as: "evo.v1.Record")
        #expect(message.value(named: "name") == .single(.string("n")))
        #expect(message.value(named: "id") == .single(.int64(99)))
        #expect(message.unknownFields.map(\.fieldNumber) == [2, 3, 9])
    }

    @Test("A singular message repeated on the wire merges")
    func repeatedSingularMessageMerges() throws {
        let codec = WireCodec(registry: try Fixtures.registry())
        // Nested.inner twice: first {name: "a"}, then {child: {name: "b"}}.
        let bytes = Data([0x12, 0x03, 0x0A, 0x01, 0x61, 0x12, 0x05, 0x12, 0x03, 0x0A, 0x01, 0x62])
        let message = try codec.decode(bytes, as: "fixtures.v1.Nested")
        let inner = try #require(message.value(named: "inner")?.values.first?.message)
        #expect(inner.value(named: "name") == .single(.string("a")))
        #expect(inner.value(named: "child")?.values.first?.message?.value(named: "name") == .single(.string("b")))
    }

    @Test("Groups are skipped and kept verbatim as unknown fields")
    func groupsAreSkipped() throws {
        let codec = WireCodec(registry: try Fixtures.registry())
        // Field 20 start group, a varint inside, field 20 end group, then title.
        let group: [UInt8] = [0xA3, 0x01, 0x08, 0x07, 0xA4, 0x01]
        let bytes = Data(group + [0x0A, 0x01, 0x74])
        let message = try codec.decode(bytes, as: "fixtures.v1.Nested")
        #expect(message.unknownFields == [UnknownField(fieldNumber: 20, raw: Data(group))])
        #expect(message.value(named: "title") == .single(.string("t")))
    }

    @Test("Setting a oneof member clears its siblings")
    func oneofExclusivity() throws {
        let codec = WireCodec(registry: try Fixtures.registry())
        // text then number: the number wins.
        let message = try codec.decode(Data([0x0A, 0x01, 0x61, 0x10, 0x05]), as: "fixtures.v1.Oneofs")
        #expect(message.value(named: "text") == nil)
        #expect(message.value(named: "number") == .single(.int64(5)))
    }
}
