import Foundation
import Testing

@testable import EtcdSchema

// Round tripping binary data through text is where corruption happens, so
// these pin the three safeguards in SPEC 5.6.

@Suite("Editing safeguards", .tags(.unit))
struct EditingSafeguardTests {
    let codec: ProtobufValueCodec

    init() throws {
        codec = try Fixtures.codec()
    }

    @Test("An edit keeps unknown fields written by a newer schema")
    func editKeepsUnknownFields() throws {
        let original = try Fixtures.bytes("record_new")
        let edited = try codec.encodeFromJSON(
            #"{"name": "renamed", "id": "99"}"#, messageName: "evo.v1.Record", originalBytes: original)
        let before = try codec.codec.decode(original, as: "evo.v1.Record")
        let after = try codec.codec.decode(edited, as: "evo.v1.Record")
        #expect(after.value(named: "name") == .single(.string("renamed")))
        #expect(after.unknownFields == before.unknownFields)
        // Only the name bytes changed; unknown fields sit in number order.
        var expected = WireWriter()
        expected.writeTag(fieldNumber: 1, wireType: .lengthDelimited)
        expected.writeLengthDelimited(Array("renamed".utf8))
        #expect(edited.starts(with: expected.bytes))
        #expect(edited.count == original.count - 1 + "renamed".utf8.count)
    }

    @Test("Unknown fields inside a nested message survive a JSON edit")
    func nestedUnknownFieldsSurvive() throws {
        // Nested.inner = { name: "a", field 9 = 5 }.
        let original = Data([0x12, 0x05, 0x0A, 0x01, 0x61, 0x48, 0x05])
        let edited = try codec.encodeFromJSON(
            #"{"inner": {"name": "b"}}"#, messageName: "fixtures.v1.Nested", originalBytes: original)
        #expect(edited == Data([0x12, 0x05, 0x0A, 0x01, 0x62, 0x48, 0x05]))
    }

    @Test("Unknown fields inside map values follow their key")
    func mapValueUnknownFieldsFollowKey() throws {
        // by_id { key: 1 value { name: "a", field 9 = 5 } }
        let entry: [UInt8] = [0x08, 0x01, 0x12, 0x05, 0x0A, 0x01, 0x61, 0x48, 0x05]
        let original = Data([0x12, UInt8(entry.count)] + entry)
        let edited = try codec.encodeFromJSON(
            #"{"byId": {"1": {"name": "a"}}}"#, messageName: "fixtures.v1.Maps", originalBytes: original)
        #expect(edited == original)
    }

    /// Nested.Inner { name, field 9 = unknown }.
    private static func inner(_ name: String, unknown: UInt8? = nil) -> [UInt8] {
        var writer = WireWriter()
        writer.writeTag(fieldNumber: 1, wireType: .lengthDelimited)
        writer.writeLengthDelimited(Array(name.utf8))
        if let unknown {
            writer.writeTag(fieldNumber: 9, wireType: .varint)
            writer.writeVarint(UInt64(unknown))
        }
        return writer.bytes
    }

    /// Nested { items: elements }.
    private static func items(_ elements: [[UInt8]]) -> Data {
        var writer = WireWriter()
        for element in elements {
            writer.writeTag(fieldNumber: 3, wireType: .lengthDelimited)
            writer.writeLengthDelimited(element)
        }
        return writer.data
    }

    private func editItems(_ original: [[UInt8]], to names: [String]) throws -> Data {
        let json = #"{"items": ["# + names.map { #"{"name": "\#($0)"}"# }.joined(separator: ", ") + "]}"
        return try codec.encodeFromJSON(json, messageName: "fixtures.v1.Nested", originalBytes: Self.items(original))
    }

    @Test("Unknown fields in a repeated message stay with their element when one is added")
    func repeatedUnknownFieldsSurviveAnAddition() throws {
        let edited = try editItems([Self.inner("a", unknown: 1), Self.inner("b", unknown: 2)], to: ["a", "b", "c"])
        #expect(edited == Self.items([Self.inner("a", unknown: 1), Self.inner("b", unknown: 2), Self.inner("c")]))
    }

    @Test("Unknown fields in a repeated message stay with their element when another is removed")
    func repeatedUnknownFieldsSurviveARemoval() throws {
        let original = [Self.inner("a", unknown: 1), Self.inner("b", unknown: 2), Self.inner("c", unknown: 3)]
        let edited = try editItems(original, to: ["a", "c"])
        #expect(edited == Self.items([Self.inner("a", unknown: 1), Self.inner("c", unknown: 3)]))
    }

    @Test("Unknown fields in a repeated message follow their element when elements are reordered")
    func repeatedUnknownFieldsFollowAReorder() throws {
        let edited = try editItems([Self.inner("a", unknown: 1), Self.inner("b", unknown: 2)], to: ["b", "a"])
        #expect(edited == Self.items([Self.inner("b", unknown: 2), Self.inner("a", unknown: 1)]))
    }

    @Test("An element edited in place keeps its unknown fields, even when others move")
    func editedElementKeepsUnknownFields() throws {
        let original = [Self.inner("a", unknown: 1), Self.inner("b", unknown: 2), Self.inner("c", unknown: 3)]
        let edited = try editItems(original, to: ["c", "a", "x"])
        #expect(edited == Self.items([Self.inner("c", unknown: 3), Self.inner("a", unknown: 1), Self.inner("x", unknown: 2)]))
    }

    @Test("Lookalike elements keep their own unknown fields when one of them is edited in place")
    func lookalikeElementsKeepUnknownFields() throws {
        let edited = try editItems([Self.inner("a", unknown: 1), Self.inner("a", unknown: 2)], to: ["x", "a"])
        #expect(edited == Self.items([Self.inner("x", unknown: 1), Self.inner("a", unknown: 2)]))
    }

    @Test("Removing one of two lookalike elements with different unknown fields is refused")
    func lookalikeRemovalIsRefused() throws {
        #expect {
            _ = try editItems([Self.inner("a", unknown: 1), Self.inner("a", unknown: 2)], to: ["a"])
        } throws: { error in
            (error as? ProtoJSONError)?.path == "items"
        }
        let edited = try editItems([Self.inner("a", unknown: 1), Self.inner("a", unknown: 1)], to: ["a"])
        #expect(edited == Self.items([Self.inner("a", unknown: 1)]))
    }

    @Test("An edit that cannot tell which element owns unknown fields is refused rather than dropping them")
    func ambiguousRepeatedEditIsRefused() throws {
        #expect {
            _ = try editItems([Self.inner("a", unknown: 1), Self.inner("b", unknown: 2)], to: ["x", "y", "z"])
        } throws: { error in
            (error as? ProtoJSONError)?.path == "items"
        }
        // Nothing is lost when the unplaced elements carry no unknown fields.
        let edited = try editItems([Self.inner("a"), Self.inner("b", unknown: 2)], to: ["x", "y", "b"])
        #expect(edited == Self.items([Self.inner("x"), Self.inner("y"), Self.inner("b", unknown: 2)]))
    }

    /// WellKnown { any: { type_url, value: payload } }.
    private static func wellKnownAny(_ typeName: String, _ payload: [UInt8]) -> Data {
        var any = WireWriter()
        any.writeTag(fieldNumber: 1, wireType: .lengthDelimited)
        any.writeLengthDelimited(Array("type.googleapis.com/\(typeName)".utf8))
        any.writeTag(fieldNumber: 2, wireType: .lengthDelimited)
        any.writeLengthDelimited(payload)
        var outer = WireWriter()
        outer.writeTag(fieldNumber: 16, wireType: .lengthDelimited)
        outer.writeLengthDelimited(any.bytes)
        return outer.data
    }

    @Test("Unknown fields inside an Any payload survive an edit that keeps its type")
    func anyPayloadUnknownFieldsSurvive() throws {
        let original = Self.wellKnownAny("fixtures.v1.Nested.Inner", Self.inner("a", unknown: 5))
        #expect(try codec.roundTripCheck(original, messageName: "fixtures.v1.WellKnown").isFaithful)
        let edited = try codec.encodeFromJSON(
            #"{"any": {"@type": "type.googleapis.com/fixtures.v1.Nested.Inner", "name": "b"}}"#,
            messageName: "fixtures.v1.WellKnown", originalBytes: original)
        #expect(edited == Self.wellKnownAny("fixtures.v1.Nested.Inner", Self.inner("b", unknown: 5)))
    }

    @Test("Unknown fields inside an Any payload are not carried over to a different type")
    func anyPayloadUnknownFieldsDropWithTheType() throws {
        let original = Self.wellKnownAny("fixtures.v1.Nested.Inner", Self.inner("a", unknown: 5))
        let edited = try codec.encodeFromJSON(
            #"{"any": {"@type": "type.googleapis.com/fixtures.v1.Nested", "title": "t"}}"#,
            messageName: "fixtures.v1.WellKnown", originalBytes: original)
        #expect(edited == Self.wellKnownAny("fixtures.v1.Nested", [0x0A, 0x01, 0x74]))
    }

    @Test("An unmodified value that does not round trip is detected, even at equal length")
    func unfaithfulRoundTripDetected() throws {
        // packed_ints in the unpacked form: accepted, but re-encoded packed.
        let unpacked = Data([0x08, 0x01, 0x08, 0x02])
        let report = try codec.roundTripCheck(unpacked, messageName: "fixtures.v1.Repeated")
        #expect(!report.isFaithful)
        #expect(report.originalLength == 4)
        #expect(report.reencodedLength == 4)
    }

    @Test("Decode failures never yield a partial message")
    func noPartialDecode() throws {
        let bytes = try Fixtures.bytes("scalars")
        #expect(throws: MessageDecodingError.self) {
            _ = try codec.decodeToJSON(bytes.dropLast(), messageName: "fixtures.v1.Scalars")
        }
    }

    @Test("A decode error names the field path")
    func errorPath() {
        // Nested.inner.name holding invalid UTF-8.
        let bytes = Data([0x12, 0x03, 0x0A, 0x01, 0xFF])
        #expect(throws: MessageDecodingError(messageName: "fixtures.v1.Nested.Inner", path: "inner.name", reason: .malformedUTF8)) {
            _ = try codec.decodeToJSON(bytes, messageName: "fixtures.v1.Nested")
        }
    }

    @Test("An unknown message name is a schema error")
    func unknownMessage() {
        #expect(throws: SchemaError.unknownMessage("nope.X")) {
            _ = try codec.decodeToJSON(Data(), messageName: "nope.X")
        }
    }

    @Test("Field order on encode follows the descriptor, ascending by number")
    func encodeOrder() throws {
        let message = try codec.message(fromJSON: #"{"fEnum": "COLOR_RED", "fInt32": 1}"#, messageName: "fixtures.v1.Scalars")
        #expect(codec.codec.encode(message) == Data([0x18, 0x01, 0x80, 0x01, 0x01]))
    }
}
